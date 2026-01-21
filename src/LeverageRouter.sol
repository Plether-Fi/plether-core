// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LeverageRouterBase} from "./base/LeverageRouterBase.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title LeverageRouter
/// @notice Leverage router for plDXY-BEAR positions via Morpho Blue.
/// @dev Flash loans USDC from Morpho → swaps to plDXY-BEAR on Curve → stakes → deposits to Morpho as collateral.
///      Requires user to authorize this contract in Morpho before use.
///      Uses Morpho's fee-free flash loans for capital efficiency.
contract LeverageRouter is LeverageRouterBase {

    using SafeERC20 for IERC20;

    /// @notice Emitted when a leveraged plDXY-BEAR position is opened.
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 plDxyBearReceived,
        uint256 debtIncurred,
        uint256 maxSlippageBps
    );

    /// @notice Emitted when a leveraged plDXY-BEAR position is closed.
    event LeverageClosed(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 usdcReturned,
        uint256 maxSlippageBps
    );

    /// @notice StakedToken vault for plDXY-BEAR (used as Morpho collateral).
    IERC4626 public immutable STAKED_PLDXY_BEAR;

    /// @notice Buffer for exchange rate drift protection (1% = 100 bps).
    uint256 public constant EXCHANGE_RATE_BUFFER_BPS = 100;

    /// @notice Deploys LeverageRouter with Morpho market configuration.
    /// @param _morpho Morpho Blue protocol address.
    /// @param _curvePool Curve USDC/plDXY-BEAR pool address.
    /// @param _usdc USDC token address.
    /// @param _plDxyBear plDXY-BEAR token address.
    /// @param _stakedPlDxyBear splDXY-BEAR staking vault address.
    /// @param _marketParams Morpho market parameters for splDXY-BEAR/USDC.
    constructor(
        address _morpho,
        address _curvePool,
        address _usdc,
        address _plDxyBear,
        address _stakedPlDxyBear,
        MarketParams memory _marketParams
    ) LeverageRouterBase(_morpho, _curvePool, _usdc, _plDxyBear) {
        if (_stakedPlDxyBear == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }
        STAKED_PLDXY_BEAR = IERC4626(_stakedPlDxyBear);
        marketParams = _marketParams;

        // Approvals (One-time)
        // 1. Allow Curve pool to take USDC (for opening)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 2. Allow Curve pool to take plDXY-BEAR (for closing)
        PLDXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow StakedToken to take plDXY-BEAR (for staking)
        PLDXY_BEAR.safeIncreaseAllowance(_stakedPlDxyBear, type(uint256).max);
        // 4. Allow Morpho to take splDXY-BEAR (for supplying collateral)
        IERC20(_stakedPlDxyBear).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 5. Allow Morpho to take USDC (for repaying debt and flash loan)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged Position in one transaction.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function openLeverage(
        uint256 principal,
        uint256 leverage,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (principal == 0) {
            revert LeverageRouterBase__ZeroPrincipal();
        }
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (leverage <= DecimalConstants.ONE_WAD) {
            revert LeverageRouterBase__LeverageTooLow();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }

        uint256 loanAmount = (principal * (leverage - DecimalConstants.ONE_WAD)) / DecimalConstants.ONE_WAD;
        if (loanAmount == 0) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        USDC.safeTransferFrom(msg.sender, address(this), principal);

        uint256 totalUSDC = principal + loanAmount;
        uint256 expectedPlDxyBear = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, totalUSDC);

        uint256 minPlDxyBear = (expectedPlDxyBear * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, leverage, maxSlippageBps, minPlDxyBear);

        MORPHO.flashLoan(address(USDC), loanAmount, data);
    }

    /**
     * @notice Close a Leveraged Position in one transaction.
     * @dev Queries actual debt from Morpho to ensure full repayment even if interest accrued.
     * @param collateralToWithdraw Amount of splDXY-BEAR shares to withdraw from Morpho.
     *        NOTE: This is staked token shares, not underlying plDXY-BEAR amount.
     *        Use STAKED_PLDXY_BEAR.previewRedeem() to convert shares to underlying.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) {
            revert LeverageRouterBase__Expired();
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert LeverageRouterBase__SlippageExceedsMax();
        }
        if (!MORPHO.isAuthorized(msg.sender, address(this))) {
            revert LeverageRouterBase__NotAuthorized();
        }

        // Query actual debt and borrow shares from Morpho
        // We need debtToRepay for flash loan amount, and borrowShares for Morpho repayment
        // Using shares-based repayment avoids Morpho edge case when repaying exact totalBorrowAssets
        uint256 debtToRepay = _getActualDebt(msg.sender);
        uint256 borrowShares = _getBorrowShares(msg.sender);

        // Calculate minimum USDC output based on REAL MARKET PRICE
        // Convert staked shares to underlying BEAR amount (shares have 1000x offset)
        uint256 plDxyBearAmount = STAKED_PLDXY_BEAR.previewRedeem(collateralToWithdraw);
        // Apply exchange rate buffer (conservative estimate for drift protection)
        uint256 bufferedDxyBearAmount = (plDxyBearAmount * (10_000 - EXCHANGE_RATE_BUFFER_BPS)) / 10_000;
        // Use get_dy to find real market expectation
        uint256 expectedUSDC = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, bufferedDxyBearAmount);
        uint256 minUsdcOut = (expectedUSDC * (10_000 - maxSlippageBps)) / 10_000;

        if (debtToRepay > 0) {
            // Standard path: flash loan USDC to repay debt (includes borrowShares for shares-based repayment)
            bytes memory data = abi.encode(
                OP_CLOSE, msg.sender, deadline, collateralToWithdraw, borrowShares, maxSlippageBps, minUsdcOut
            );
            // Add 1 bps buffer to cover interest accrual between debt query and repay execution
            // The shares-based repay may convert to slightly more assets due to interest
            uint256 flashLoanAmount = debtToRepay + (debtToRepay / 10_000) + 1;
            MORPHO.flashLoan(address(USDC), flashLoanAmount, data);
        } else {
            // No debt to repay: directly unwind position without flash loan
            _executeCloseNoDebt(msg.sender, collateralToWithdraw, maxSlippageBps, minUsdcOut);
        }

        // Event emitted in _executeClose or _executeCloseNoDebt
    }

    /// @notice Returns the user's current debt in this market (includes accrued interest).
    /// @param user The address to query debt for.
    /// @return debt The actual debt amount in USDC (rounded up).
    function getActualDebt(
        address user
    ) external view returns (uint256 debt) {
        return _getActualDebt(user);
    }

    /// @dev Computes actual debt from Morpho position, rounded up to ensure full repayment.
    function _getActualDebt(
        address user
    ) internal view returns (uint256) {
        bytes32 marketId = _marketId();
        (, uint128 borrowShares,) = MORPHO.position(marketId, user);
        if (borrowShares == 0) {
            return 0;
        }

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = MORPHO.market(marketId);
        if (totalBorrowShares == 0) {
            return 0;
        }

        // Round up to ensure full repayment
        return (uint256(borrowShares) * totalBorrowAssets + totalBorrowShares - 1) / totalBorrowShares;
    }

    /// @dev Returns user's borrow shares from Morpho position.
    /// @dev Used for shares-based repayment to avoid Morpho edge case when repaying exact debt.
    function _getBorrowShares(
        address user
    ) internal view returns (uint256) {
        bytes32 marketId = _marketId();
        (, uint128 borrowShares,) = MORPHO.position(marketId, user);
        return uint256(borrowShares);
    }

    /// @dev Computes market ID from marketParams.
    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(marketParams));
    }

    /// @notice Morpho flash loan callback. Routes to open or close handler.
    /// @param amount Amount of USDC borrowed.
    /// @param data Encoded operation parameters.
    function onMorphoFlashLoan(
        uint256 amount,
        bytes calldata data
    ) external override {
        // Validate caller is Morpho
        _validateLender(msg.sender, address(MORPHO));

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_OPEN) {
            _executeOpen(amount, data);
        } else if (operation == OP_CLOSE) {
            _executeClose(amount, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }
        // Flash loan repayment: Morpho will pull tokens via transferFrom.
        // Constructor grants max approval, so no additional approval needed.
    }

    /// @notice ERC-3156 flash loan callback - not used by LeverageRouter.
    /// @dev Always reverts as LeverageRouter only uses Morpho flash loans.
    function onFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes32) {
        revert FlashLoan__InvalidOperation();
    }

    /// @dev Executes open leverage operation within Morpho flash loan callback.
    /// @param loanAmount Amount of USDC borrowed from Morpho.
    /// @param data Encoded parameters (op, user, deadline, principal, leverage, maxSlippageBps, minPlDxyBear).
    function _executeOpen(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode open-specific data: (op, user, deadline, principal, leverage, maxSlippageBps, minPlDxyBear)
        (, address user,, uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 minPlDxyBear) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        uint256 totalUSDC = principal + loanAmount;

        // 1. Swap ALL USDC -> plDXY-BEAR via Curve
        uint256 plDxyBearReceived = CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, totalUSDC, minPlDxyBear);

        // 2. Stake plDXY-BEAR to get splDXY-BEAR
        uint256 stakedShares = STAKED_PLDXY_BEAR.deposit(plDxyBearReceived, address(this));

        // 3. Supply splDXY-BEAR collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 4. Borrow USDC from Morpho to repay flash loan (no fee with Morpho)
        uint256 debtIncurred = loanAmount;
        MORPHO.borrow(marketParams, debtIncurred, 0, user, address(this));

        // 5. Emit event for off-chain tracking and MEV analysis
        emit LeverageOpened(user, principal, leverage, loanAmount, plDxyBearReceived, debtIncurred, maxSlippageBps);
    }

    /// @dev Executes close leverage operation within Morpho flash loan callback.
    /// @param loanAmount Amount of USDC borrowed from Morpho to repay debt.
    /// @param data Encoded parameters (op, user, deadline, collateralToWithdraw, borrowShares, maxSlippageBps, minUsdcOut).
    function _executeClose(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode close-specific data: (op, user, deadline, collateralToWithdraw, borrowShares, maxSlippageBps, minUsdcOut)
        (
            ,
            address user,,
            uint256 collateralToWithdraw,
            uint256 borrowShares,
            uint256 maxSlippageBps,
            uint256 minUsdcOut
        ) = abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        // 1. Repay user's debt on Morpho using shares (not assets)
        // Using shares-based repayment avoids Morpho edge case that panics when
        // repaying exactly totalBorrowAssets (full market debt)
        if (borrowShares > 0) {
            MORPHO.repay(marketParams, 0, borrowShares, user, "");
        }

        // 2. Withdraw user's splDXY-BEAR collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 3. Unstake splDXY-BEAR to get plDXY-BEAR
        uint256 plDxyBearReceived = STAKED_PLDXY_BEAR.redeem(collateralToWithdraw, address(this), address(this));

        // 4. Swap plDXY-BEAR -> USDC via Curve
        uint256 usdcReceived = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearReceived, minUsdcOut);

        // 5. Flash loan repayment handled by caller (no fee with Morpho)
        if (usdcReceived < loanAmount) {
            revert LeverageRouterBase__InsufficientOutput();
        }

        // 6. Send remaining USDC to user
        uint256 usdcToReturn = usdcReceived - loanAmount;
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // 7. Emit event for off-chain tracking
        emit LeverageClosed(user, loanAmount, collateralToWithdraw, usdcToReturn, maxSlippageBps);
    }

    /// @dev Closes position without flash loan when user has no Morpho debt.
    /// @param user Position owner receiving USDC.
    /// @param collateralToWithdraw Amount of splDXY-BEAR shares to withdraw.
    /// @param maxSlippageBps Maximum slippage for Curve swap.
    /// @param minUsdcOut Minimum USDC to receive after swap.
    function _executeCloseNoDebt(
        address user,
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 minUsdcOut
    ) private {
        // 1. Withdraw user's splDXY-BEAR collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 2. Unstake splDXY-BEAR to get plDXY-BEAR
        uint256 plDxyBearReceived = STAKED_PLDXY_BEAR.redeem(collateralToWithdraw, address(this), address(this));

        // 3. Swap plDXY-BEAR -> USDC via Curve
        uint256 usdcReceived = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearReceived, minUsdcOut);

        // 4. Send all USDC to user (no flash loan to repay)
        if (usdcReceived > 0) {
            USDC.safeTransfer(user, usdcReceived);
        }

        // 5. Emit event for off-chain tracking
        emit LeverageClosed(user, 0, collateralToWithdraw, usdcReceived, maxSlippageBps);
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of opening a leveraged position.
     * @param principal Amount of USDC user will send.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @return loanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC to swap (principal + loan).
     * @return expectedPlDxyBear Expected plDXY-BEAR (based on current curve price).
     * @return expectedDebt Expected debt incurred (equals loan amount, no flash fee with Morpho).
     */
    function previewOpenLeverage(
        uint256 principal,
        uint256 leverage
    ) external view returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedPlDxyBear, uint256 expectedDebt) {
        if (leverage <= DecimalConstants.ONE_WAD) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        loanAmount = (principal * (leverage - DecimalConstants.ONE_WAD)) / DecimalConstants.ONE_WAD;
        totalUSDC = principal + loanAmount;

        // Use get_dy for accurate preview
        expectedPlDxyBear = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, totalUSDC);

        // No flash fee with Morpho
        expectedDebt = loanAmount;
    }

    /**
     * @notice Preview the result of closing a leveraged position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of plDXY-BEAR collateral to withdraw.
     * @return expectedUSDC Expected USDC from swap (based on current curve price).
     * @return flashFee Flash loan fee (always 0 with Morpho).
     * @return expectedReturn Expected USDC returned to user after repaying flash loan.
     */
    function previewCloseLeverage(
        uint256 debtToRepay,
        uint256 collateralToWithdraw
    ) external view returns (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) {
        // Convert staked shares to underlying BEAR amount (shares have 1000x offset)
        uint256 plDxyBearAmount = STAKED_PLDXY_BEAR.previewRedeem(collateralToWithdraw);
        // Use get_dy for accurate preview
        expectedUSDC = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearAmount);

        // No flash fee with Morpho
        flashFee = 0;
        expectedReturn = expectedUSDC > debtToRepay ? expectedUSDC - debtToRepay : 0;
    }

}

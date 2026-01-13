// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LeverageRouterBase} from "./base/LeverageRouterBase.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";

/// @title LeverageRouter
/// @notice Leverage router for DXY-BEAR positions via Morpho Blue.
/// @dev Flash loans USDC from Morpho → swaps to DXY-BEAR on Curve → stakes → deposits to Morpho as collateral.
///      Requires user to authorize this contract in Morpho before use.
///      Uses Morpho's fee-free flash loans for capital efficiency.
contract LeverageRouter is LeverageRouterBase {

    using SafeERC20 for IERC20;

    /// @notice Emitted when a leveraged DXY-BEAR position is opened.
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 dxyBearReceived,
        uint256 debtIncurred,
        uint256 maxSlippageBps
    );

    /// @notice Emitted when a leveraged DXY-BEAR position is closed.
    event LeverageClosed(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 usdcReturned,
        uint256 maxSlippageBps
    );

    /// @notice StakedToken vault for DXY-BEAR (used as Morpho collateral).
    IERC4626 public immutable STAKED_DXY_BEAR;

    /// @notice Deploys LeverageRouter with Morpho market configuration.
    /// @param _morpho Morpho Blue protocol address.
    /// @param _curvePool Curve USDC/DXY-BEAR pool address.
    /// @param _usdc USDC token address.
    /// @param _dxyBear DXY-BEAR token address.
    /// @param _stakedDxyBear sDXY-BEAR staking vault address.
    /// @param _marketParams Morpho market parameters for sDXY-BEAR/USDC.
    constructor(
        address _morpho,
        address _curvePool,
        address _usdc,
        address _dxyBear,
        address _stakedDxyBear,
        MarketParams memory _marketParams
    ) LeverageRouterBase(_morpho, _curvePool, _usdc, _dxyBear) {
        if (_stakedDxyBear == address(0)) revert LeverageRouterBase__ZeroAddress();
        STAKED_DXY_BEAR = IERC4626(_stakedDxyBear);
        marketParams = _marketParams;

        // Approvals (One-time)
        // 1. Allow Curve pool to take USDC (for opening)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 2. Allow Curve pool to take DXY-BEAR (for closing)
        DXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow StakedToken to take DXY-BEAR (for staking)
        DXY_BEAR.safeIncreaseAllowance(_stakedDxyBear, type(uint256).max);
        // 4. Allow Morpho to take sDXY-BEAR (for supplying collateral)
        IERC20(_stakedDxyBear).safeIncreaseAllowance(_morpho, type(uint256).max);
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
        if (principal == 0) revert LeverageRouterBase__ZeroPrincipal();
        if (block.timestamp > deadline) revert LeverageRouterBase__Expired();
        if (leverage <= 1e18) revert LeverageRouterBase__LeverageTooLow();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert LeverageRouterBase__SlippageExceedsMax();
        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert LeverageRouterBase__NotAuthorized();

        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;
        if (loanAmount == 0) revert LeverageRouterBase__LeverageTooLow();

        USDC.safeTransferFrom(msg.sender, address(this), principal);

        uint256 totalUSDC = principal + loanAmount;
        uint256 expectedDxyBear = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC);

        uint256 minDxyBear = (expectedDxyBear * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, leverage, maxSlippageBps, minDxyBear);

        MORPHO.flashLoan(address(USDC), loanAmount, data);
    }

    /**
     * @notice Close a Leveraged Position in one transaction.
     * @param debtToRepay Amount of USDC debt to repay (flash loaned). Can be 0 if no debt.
     * @param collateralToWithdraw Amount of DXY-BEAR collateral to withdraw.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(
        uint256 debtToRepay,
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert LeverageRouterBase__Expired();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert LeverageRouterBase__SlippageExceedsMax();
        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert LeverageRouterBase__NotAuthorized();

        // 1. Calculate minimum USDC output based on REAL MARKET PRICE
        // Convert staked shares to underlying BEAR amount (shares have 1000x offset)
        uint256 dxyBearAmount = STAKED_DXY_BEAR.previewRedeem(collateralToWithdraw);
        // Use get_dy to find real market expectation
        uint256 expectedUSDC = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);
        uint256 minUsdcOut = (expectedUSDC * (10_000 - maxSlippageBps)) / 10_000;

        if (debtToRepay > 0) {
            // Standard path: flash loan USDC to repay debt
            bytes memory data =
                abi.encode(OP_CLOSE, msg.sender, deadline, collateralToWithdraw, maxSlippageBps, minUsdcOut);
            MORPHO.flashLoan(address(USDC), debtToRepay, data);
        } else {
            // No debt to repay: directly unwind position without flash loan
            _executeCloseNoDebt(msg.sender, collateralToWithdraw, maxSlippageBps, minUsdcOut);
        }

        // Event emitted in _executeClose or _executeCloseNoDebt
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
    /// @param data Encoded parameters (op, user, deadline, principal, leverage, maxSlippageBps, minDxyBear).
    function _executeOpen(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode open-specific data: (op, user, deadline, principal, leverage, maxSlippageBps, minDxyBear)
        (, address user,, uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 minDxyBear) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        uint256 totalUSDC = principal + loanAmount;

        // 1. Swap ALL USDC -> DXY-BEAR via Curve
        uint256 dxyBearReceived = CURVE_POOL.exchange(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC, minDxyBear);

        // 2. Stake DXY-BEAR to get sDXY-BEAR
        uint256 stakedShares = STAKED_DXY_BEAR.deposit(dxyBearReceived, address(this));

        // 3. Supply sDXY-BEAR collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 4. Borrow USDC from Morpho to repay flash loan (no fee with Morpho)
        uint256 debtIncurred = loanAmount;
        MORPHO.borrow(marketParams, debtIncurred, 0, user, address(this));

        // 5. Emit event for off-chain tracking and MEV analysis
        emit LeverageOpened(user, principal, leverage, loanAmount, dxyBearReceived, debtIncurred, maxSlippageBps);
    }

    /// @dev Executes close leverage operation within Morpho flash loan callback.
    /// @param loanAmount Amount of USDC borrowed from Morpho to repay debt.
    /// @param data Encoded parameters (op, user, deadline, collateralToWithdraw, maxSlippageBps, minUsdcOut).
    function _executeClose(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode close-specific data: (op, user, deadline, collateralToWithdraw, maxSlippageBps, minUsdcOut)
        (, address user,, uint256 collateralToWithdraw, uint256 maxSlippageBps, uint256 minUsdcOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256));

        // 1. Repay user's debt on Morpho (skip if no debt)
        if (loanAmount > 0) {
            MORPHO.repay(marketParams, loanAmount, 0, user, "");
        }

        // 2. Withdraw user's sDXY-BEAR collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 3. Unstake sDXY-BEAR to get DXY-BEAR
        uint256 dxyBearReceived = STAKED_DXY_BEAR.redeem(collateralToWithdraw, address(this), address(this));

        // 4. Swap DXY-BEAR -> USDC via Curve
        uint256 usdcReceived = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, dxyBearReceived, minUsdcOut);

        // 5. Flash loan repayment handled by caller (no fee with Morpho)
        if (usdcReceived < loanAmount) revert LeverageRouterBase__InsufficientOutput();

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
    /// @param collateralToWithdraw Amount of sDXY-BEAR shares to withdraw.
    /// @param maxSlippageBps Maximum slippage for Curve swap.
    /// @param minUsdcOut Minimum USDC to receive after swap.
    function _executeCloseNoDebt(
        address user,
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 minUsdcOut
    ) private {
        // 1. Withdraw user's sDXY-BEAR collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 2. Unstake sDXY-BEAR to get DXY-BEAR
        uint256 dxyBearReceived = STAKED_DXY_BEAR.redeem(collateralToWithdraw, address(this), address(this));

        // 3. Swap DXY-BEAR -> USDC via Curve
        uint256 usdcReceived = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, dxyBearReceived, minUsdcOut);

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
     * @return expectedDxyBear Expected DXY-BEAR (based on current curve price).
     * @return expectedDebt Expected debt incurred (equals loan amount, no flash fee with Morpho).
     */
    function previewOpenLeverage(
        uint256 principal,
        uint256 leverage
    ) external view returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBear, uint256 expectedDebt) {
        if (leverage <= 1e18) revert LeverageRouterBase__LeverageTooLow();

        loanAmount = (principal * (leverage - 1e18)) / 1e18;
        totalUSDC = principal + loanAmount;

        // Use get_dy for accurate preview
        expectedDxyBear = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC);

        // No flash fee with Morpho
        expectedDebt = loanAmount;
    }

    /**
     * @notice Preview the result of closing a leveraged position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of DXY-BEAR collateral to withdraw.
     * @return expectedUSDC Expected USDC from swap (based on current curve price).
     * @return flashFee Flash loan fee (always 0 with Morpho).
     * @return expectedReturn Expected USDC returned to user after repaying flash loan.
     */
    function previewCloseLeverage(
        uint256 debtToRepay,
        uint256 collateralToWithdraw
    ) external view returns (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn) {
        // Convert staked shares to underlying BEAR amount (shares have 1000x offset)
        uint256 dxyBearAmount = STAKED_DXY_BEAR.previewRedeem(collateralToWithdraw);
        // Use get_dy for accurate preview
        expectedUSDC = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);

        // No flash fee with Morpho
        flashFee = 0;
        expectedReturn = expectedUSDC > debtToRepay ? expectedUSDC - debtToRepay : 0;
    }

}

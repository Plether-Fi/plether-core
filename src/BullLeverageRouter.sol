// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LeverageRouterBase} from "./base/LeverageRouterBase.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title BullLeverageRouter
/// @notice Leverage router for plDXY-BULL positions via Morpho Blue.
/// @dev Uses Morpho flash loans + Splitter minting to acquire plDXY-BULL, then deposits as Morpho collateral.
///      Close operation uses a single plDXY-BEAR flash mint for simplicity and gas efficiency.
///      Uses Morpho's fee-free flash loans for capital efficiency.
///
/// @dev STATE MACHINE - OPEN LEVERAGE:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ openLeverage(principal, leverage)                                       │
///      │   1. Pull USDC from user                                                │
///      │   2. Flash loan additional USDC from Morpho (fee-free)                  │
///      │      └──► onMorphoFlashLoan(OP_OPEN)                                    │
///      │            └──► _executeOpen()                                          │
///      │                  1. Mint plDXY-BEAR + plDXY-BULL pairs via Splitter         │
///      │                  2. Sell plDXY-BEAR on Curve → USDC                       │
///      │                  3. Stake plDXY-BULL → splDXY-BULL                          │
///      │                  4. Deposit splDXY-BULL to Morpho (user's collateral)     │
///      │                  5. Borrow USDC from Morpho to cover flash repayment    │
///      │                  6. Emit LeverageOpened event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
/// @dev STATE MACHINE - CLOSE LEVERAGE (Single Flash Mint):
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ closeLeverage(debtToRepay, collateralToWithdraw)                        │
///      │   1. Flash mint plDXY-BEAR (collateral + extra for debt repayment)        │
///      │      └──► onFlashLoan(OP_CLOSE)                                         │
///      │            └──► _executeClose()                                         │
///      │                  1. Sell extra plDXY-BEAR on Curve → USDC                 │
///      │                  2. Repay user's Morpho debt with USDC from sale        │
///      │                  3. Withdraw user's splDXY-BULL from Morpho               │
///      │                  4. Unstake splDXY-BULL → plDXY-BULL                        │
///      │                  5. Redeem plDXY-BEAR + plDXY-BULL → USDC                   │
///      │                  6. Buy plDXY-BEAR on Curve to repay flash mint           │
///      │                  7. Transfer remaining USDC to user                     │
///      │                  8. Emit LeverageClosed event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
contract BullLeverageRouter is LeverageRouterBase {

    using SafeERC20 for IERC20;

    /// @notice Emitted when a leveraged plDXY-BULL position is opened.
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 plDxyBullReceived,
        uint256 debtIncurred,
        uint256 maxSlippageBps
    );

    /// @notice Emitted when a leveraged plDXY-BULL position is closed.
    event LeverageClosed(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 usdcReturned,
        uint256 maxSlippageBps
    );

    /// @notice SyntheticSplitter for minting/burning token pairs.
    ISyntheticSplitter public immutable SPLITTER;

    /// @notice plDXY-BULL token (collateral for bull positions).
    IERC20 public immutable PLDXY_BULL;

    /// @notice StakedToken vault for plDXY-BULL (used as Morpho collateral).
    IERC4626 public immutable STAKED_PLDXY_BULL;

    /// @notice Protocol CAP price (8 decimals, oracle format).
    uint256 public immutable CAP;

    /// @notice Buffer for exchange rate drift between previewRedeem and redeem (1%).
    /// @dev Protects against DoS attacks via yield donation front-running.
    uint256 public constant EXCHANGE_RATE_BUFFER_BPS = 100;

    /// @notice Deploys BullLeverageRouter with Morpho market configuration.
    /// @param _morpho Morpho Blue protocol address.
    /// @param _splitter SyntheticSplitter contract address.
    /// @param _curvePool Curve USDC/plDXY-BEAR pool address.
    /// @param _usdc USDC token address.
    /// @param _plDxyBear plDXY-BEAR token address.
    /// @param _plDxyBull plDXY-BULL token address.
    /// @param _stakedPlDxyBull splDXY-BULL staking vault address.
    /// @param _marketParams Morpho market parameters for splDXY-BULL/USDC.
    constructor(
        address _morpho,
        address _splitter,
        address _curvePool,
        address _usdc,
        address _plDxyBear,
        address _plDxyBull,
        address _stakedPlDxyBull,
        MarketParams memory _marketParams
    ) LeverageRouterBase(_morpho, _curvePool, _usdc, _plDxyBear) {
        if (_splitter == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }
        if (_plDxyBull == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }
        if (_stakedPlDxyBull == address(0)) {
            revert LeverageRouterBase__ZeroAddress();
        }

        SPLITTER = ISyntheticSplitter(_splitter);
        PLDXY_BULL = IERC20(_plDxyBull);
        STAKED_PLDXY_BULL = IERC4626(_stakedPlDxyBull);
        marketParams = _marketParams;

        // Cache CAP from Splitter (8 decimals)
        CAP = ISyntheticSplitter(_splitter).CAP();

        // Approvals (One-time)
        // 1. Allow Splitter to take USDC (for minting pairs)
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 2. Allow Curve pool to take plDXY-BEAR (for selling during open)
        PLDXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow Curve pool to take USDC (for buying BEAR during close)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 4. Allow StakedToken to take plDXY-BULL (for staking)
        PLDXY_BULL.safeIncreaseAllowance(_stakedPlDxyBull, type(uint256).max);
        // 5. Allow Morpho to take splDXY-BULL (for supplying collateral)
        IERC20(_stakedPlDxyBull).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 6. Allow Morpho to take USDC (for repaying debt and flash loan)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 7. Allow Splitter to take plDXY-BEAR (for redeeming pairs during close)
        PLDXY_BEAR.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 8. Allow Splitter to take plDXY-BULL (for redeeming pairs during close)
        PLDXY_BULL.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 9. Allow plDXY-BEAR to take back tokens (Flash Mint Repayment)
        PLDXY_BEAR.safeIncreaseAllowance(_plDxyBear, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged plDXY-BULL Position in one transaction.
     * @dev Mints pairs via Splitter, sells plDXY-BEAR on Curve, deposits plDXY-BULL to Morpho.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
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
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert LeverageRouterBase__SplitterNotActive();
        }

        uint256 loanAmount = (principal * (leverage - DecimalConstants.ONE_WAD)) / DecimalConstants.ONE_WAD;
        if (loanAmount == 0) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        USDC.safeTransferFrom(msg.sender, address(this), principal);

        uint256 totalUSDC = principal + loanAmount;
        uint256 plDxyBearAmount = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearAmount);
        uint256 minSwapOut = (expectedUsdcFromSale * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, leverage, maxSlippageBps, minSwapOut);

        MORPHO.flashLoan(address(USDC), loanAmount, data);
    }

    /**
     * @notice Close a Leveraged plDXY-BULL Position in one transaction.
     * @dev Uses a single plDXY-BEAR flash mint to unwind positions efficiently.
     *      Queries actual debt from Morpho to ensure full repayment even if interest accrued.
     * @param collateralToWithdraw Amount of splDXY-BULL shares to withdraw from Morpho.
     *        NOTE: This is staked token shares, not underlying plDXY-BULL amount.
     *        Use STAKED_PLDXY_BULL.previewRedeem() to convert shares to underlying.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(
        uint256 collateralToWithdraw,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (collateralToWithdraw == 0) {
            revert LeverageRouterBase__ZeroCollateral();
        }
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
        // We need debtToRepay for calculating BEAR to sell, and borrowShares for Morpho repayment
        // Using shares-based repayment avoids Morpho edge case when repaying exact totalBorrowAssets
        uint256 debtToRepay = _getActualDebt(msg.sender);
        uint256 borrowShares = _getBorrowShares(msg.sender);

        // Convert staked shares to underlying BULL amount (for pair matching)
        uint256 plDxyBullAmount = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // Add buffer for exchange rate drift (protects against yield donation front-running)
        uint256 bufferedBullAmount = plDxyBullAmount + (plDxyBullAmount * EXCHANGE_RATE_BUFFER_BPS / 10_000);

        // Calculate extra BEAR needed to sell for debt repayment
        uint256 extraBearForDebt = 0;
        if (debtToRepay > 0) {
            // Query: how much USDC do we get for 1 BEAR (DecimalConstants.ONE_WAD)?
            uint256 usdcPerBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
            if (usdcPerBear == 0) {
                revert LeverageRouterBase__InvalidCurvePrice();
            }

            // Calculate BEAR needed to sell for debtToRepay USDC
            // Formula: (debt * DecimalConstants.ONE_WAD) / usdcPerBear, with slippage buffer
            extraBearForDebt = (debtToRepay * DecimalConstants.ONE_WAD) / usdcPerBear;
            // Add slippage buffer (extra % to ensure we get enough USDC)
            extraBearForDebt = extraBearForDebt + (extraBearForDebt * maxSlippageBps / 10_000);
        }

        // Total BEAR to flash mint: buffered amount for pair redemption + extra for debt
        uint256 flashAmount = bufferedBullAmount + extraBearForDebt;

        // Encode data for callback (includes borrowShares for shares-based Morpho repayment)
        bytes memory data = abi.encode(
            OP_CLOSE,
            msg.sender,
            deadline,
            collateralToWithdraw,
            debtToRepay,
            borrowShares,
            extraBearForDebt,
            maxSlippageBps
        );

        // Single flash mint handles entire close operation
        IERC3156FlashLender(address(PLDXY_BEAR)).flashLoan(this, address(PLDXY_BEAR), flashAmount, data);

        // Event emitted in _executeClose callback
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

    /// @notice Morpho flash loan callback for USDC flash loans (OP_OPEN only).
    /// @param amount Amount of USDC borrowed.
    /// @param data Encoded open operation parameters.
    function onMorphoFlashLoan(
        uint256 amount,
        bytes calldata data
    ) external override {
        // Validate caller is Morpho
        _validateLender(msg.sender, address(MORPHO));

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_OPEN) {
            _executeOpen(amount, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        // Flash loan repayment: Morpho will pull tokens via transferFrom.
        // Constructor grants max approval, so no additional approval needed.
    }

    /// @notice ERC-3156 flash loan callback for plDXY-BEAR flash mints (OP_CLOSE only).
    /// @param initiator Address that initiated the flash loan (must be this contract).
    /// @param amount Amount of plDXY-BEAR borrowed.
    /// @param fee Flash loan fee (always 0 for SyntheticToken).
    /// @param data Encoded close operation parameters.
    /// @return CALLBACK_SUCCESS on successful execution.
    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        _validateFlashLoan(msg.sender, address(PLDXY_BEAR), initiator);

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_CLOSE) {
            _executeClose(amount, fee, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        return CALLBACK_SUCCESS;
    }

    /// @dev Executes open leverage operation within Morpho flash loan callback.
    /// @param loanAmount Amount of USDC borrowed from Morpho.
    /// @param data Encoded parameters (op, user, deadline, principal, leverage, maxSlippageBps, minSwapOut).
    function _executeOpen(
        uint256 loanAmount,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, principal, leverage, maxSlippageBps, minSwapOut)
        (, address user,, uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 minSwapOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        // 1. Total USDC = Principal + Flash Loan
        uint256 totalUSDC = principal + loanAmount;

        // 2. Mint pairs via Splitter (USDC -> plDXY-BEAR + plDXY-BULL)
        // Splitter.mint expects token amount (18 decimals), not USDC (6 decimals)
        // tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        SPLITTER.mint((totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP);

        // 3. Sell ALL plDXY-BEAR for USDC via Curve
        uint256 plDxyBearBalance = PLDXY_BEAR.balanceOf(address(this));
        uint256 usdcFromSale = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearBalance, minSwapOut);

        // 4. Stake plDXY-BULL to get splDXY-BULL
        uint256 plDxyBullReceived = PLDXY_BULL.balanceOf(address(this));
        uint256 stakedShares = STAKED_PLDXY_BULL.deposit(plDxyBullReceived, address(this));

        // 5. Deposit splDXY-BULL collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 6. Borrow USDC from Morpho to repay flash loan (no fee with Morpho)
        // We already have usdcFromSale, so only borrow the remaining amount needed
        uint256 debtIncurred = loanAmount > usdcFromSale ? loanAmount - usdcFromSale : 0;
        if (debtIncurred > 0) {
            MORPHO.borrow(marketParams, debtIncurred, 0, user, address(this));
        }

        // 7. Emit event for off-chain tracking
        emit LeverageOpened(user, principal, leverage, loanAmount, plDxyBullReceived, debtIncurred, maxSlippageBps);
    }

    /// @dev Executes close leverage operation within plDXY-BEAR flash mint callback.
    /// @param flashAmount Amount of plDXY-BEAR flash minted.
    /// @param flashFee Flash mint fee (always 0).
    /// @param data Encoded parameters (op, user, deadline, collateralToWithdraw, debtToRepay, borrowShares, extraBearForDebt, maxSlippageBps).
    function _executeClose(
        uint256 flashAmount,
        uint256 flashFee,
        bytes calldata data
    ) private {
        // Decode: (op, user, deadline, collateralToWithdraw, debtToRepay, borrowShares, extraBearForDebt, maxSlippageBps)
        (
            ,
            address user,,
            uint256 collateralToWithdraw,
            uint256 debtToRepay,
            uint256 borrowShares,
            uint256 extraBearForDebt,
            uint256 maxSlippageBps
        ) = abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256, uint256));

        // 1. If debt exists, sell extra BEAR for USDC to repay it
        if (debtToRepay > 0 && extraBearForDebt > 0) {
            // Sell extraBearForDebt BEAR → USDC (with slippage protection)
            uint256 minUsdcFromSale = (debtToRepay * (10_000 - maxSlippageBps)) / 10_000;
            uint256 usdcFromSale = CURVE_POOL.exchange(PLDXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt, minUsdcFromSale);
            if (usdcFromSale < debtToRepay) {
                revert LeverageRouterBase__InsufficientOutput();
            }
        }

        // 2. Repay user's debt on Morpho using shares (not assets)
        // Using shares-based repayment avoids Morpho edge case that panics when
        // repaying exactly totalBorrowAssets (full market debt)
        if (borrowShares > 0) {
            MORPHO.repay(marketParams, 0, borrowShares, user, "");
        }

        // 3. Withdraw user's splDXY-BULL collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 4. Unstake splDXY-BULL to get plDXY-BULL
        uint256 plDxyBullReceived = STAKED_PLDXY_BULL.redeem(collateralToWithdraw, address(this), address(this));

        // 5. Redeem pairs via Splitter (plDXY-BEAR + plDXY-BULL → USDC)
        // We have exactly plDxyBullReceived BULL, and (flashAmount - extraBearForDebt) BEAR remaining
        SPLITTER.burn(plDxyBullReceived);

        // 6. Buy back ALL flash-minted BEAR to repay flash mint
        uint256 repayAmount = flashAmount + flashFee;

        // Current BEAR balance (from minting pairs)
        uint256 bearBalance = PLDXY_BEAR.balanceOf(address(this));

        // Need to buy: repayAmount - bearBalance
        if (repayAmount > bearBalance) {
            uint256 bearToBuy = repayAmount - bearBalance;

            // Estimate USDC needed using Curve price discovery
            uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
            if (bearPerUsdc == 0) {
                revert LeverageRouterBase__InvalidCurvePrice();
            }

            // Calculate USDC needed with slippage buffer
            uint256 estimatedUsdcNeeded = (bearToBuy * DecimalConstants.ONE_USDC) / bearPerUsdc;
            uint256 maxUsdcToSpend = estimatedUsdcNeeded + (estimatedUsdcNeeded * maxSlippageBps / 10_000);

            // Verify we have enough USDC
            uint256 usdcBalance = USDC.balanceOf(address(this));
            if (usdcBalance < maxUsdcToSpend) {
                revert LeverageRouterBase__InsufficientOutput();
            }

            // Swap USDC → BEAR with slippage-tolerant min_dy
            uint256 minBearOut = (bearToBuy * (10_000 - maxSlippageBps)) / 10_000;
            CURVE_POOL.exchange(USDC_INDEX, PLDXY_BEAR_INDEX, maxUsdcToSpend, minBearOut);
        }

        // 7. Transfer remaining USDC to user
        uint256 usdcToReturn = USDC.balanceOf(address(this));
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // 8. Sweep excess BEAR to user (from exchange rate buffer)
        uint256 finalBearBalance = PLDXY_BEAR.balanceOf(address(this));
        if (finalBearBalance > repayAmount) {
            PLDXY_BEAR.safeTransfer(user, finalBearBalance - repayAmount);
        }

        // 9. Emit event for off-chain tracking
        emit LeverageClosed(user, debtToRepay, collateralToWithdraw, usdcToReturn, maxSlippageBps);

        // Flash mint repayment happens automatically when callback returns
        // plDXY-BEAR token will burn repayAmount from this contract
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of opening a leveraged plDXY-BULL position.
     * @param principal Amount of USDC user will send.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @return loanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC for minting pairs (principal + loan).
     * @return expectedPlDxyBull Expected plDXY-BULL tokens received.
     * @return expectedDebt Expected Morpho debt (flash repayment - USDC from plDXY-BEAR sale).
     */
    function previewOpenLeverage(
        uint256 principal,
        uint256 leverage
    ) external view returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedPlDxyBull, uint256 expectedDebt) {
        if (leverage <= DecimalConstants.ONE_WAD) {
            revert LeverageRouterBase__LeverageTooLow();
        }

        loanAmount = (principal * (leverage - DecimalConstants.ONE_WAD)) / DecimalConstants.ONE_WAD;
        totalUSDC = principal + loanAmount;
        // Splitter mints at CAP price: tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        expectedPlDxyBull = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        // Use Curve to estimate USDC from selling plDXY-BEAR
        uint256 plDxyBearAmount = expectedPlDxyBull;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, plDxyBearAmount);

        // No flash fee with Morpho
        // Debt = what we need to borrow from Morpho after using sale proceeds
        expectedDebt = loanAmount > expectedUsdcFromSale ? loanAmount - expectedUsdcFromSale : 0;
    }

    /**
     * @notice Preview the result of closing a leveraged plDXY-BULL position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of plDXY-BULL collateral to withdraw.
     * @return expectedUSDC Expected USDC from redeeming pairs.
     * @return usdcForBearBuyback Expected USDC needed to buy back plDXY-BEAR.
     * @return expectedReturn Expected USDC returned to user after all repayments.
     */
    function previewCloseLeverage(
        uint256 debtToRepay,
        uint256 collateralToWithdraw
    ) external view returns (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn) {
        // Convert staked shares to underlying BULL amount
        uint256 plDxyBullAmount = STAKED_PLDXY_BULL.previewRedeem(collateralToWithdraw);

        // Redeeming pairs at CAP: usdc = tokens * CAP / DecimalConstants.USDC_TO_TOKEN_SCALE
        expectedUSDC = (plDxyBullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // Calculate extra BEAR needed to sell for debt repayment (mirrors closeLeverage logic)
        uint256 extraBearForDebt = 0;
        uint256 usdcFromBearSale = 0;
        if (debtToRepay > 0) {
            uint256 usdcPerBear = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, DecimalConstants.ONE_WAD);
            if (usdcPerBear > 0) {
                // Calculate BEAR needed without slippage buffer (conservative estimate)
                extraBearForDebt = (debtToRepay * DecimalConstants.ONE_WAD) / usdcPerBear;
                // Estimate actual USDC from selling this BEAR
                usdcFromBearSale = CURVE_POOL.get_dy(PLDXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt);
            }
        }

        // Total BEAR to buy back includes exchange rate buffer (mirrors closeLeverage logic)
        uint256 bufferedBullAmount = plDxyBullAmount + (plDxyBullAmount * EXCHANGE_RATE_BUFFER_BPS / 10_000);
        uint256 totalBearToBuyBack = bufferedBullAmount + extraBearForDebt;

        // Calculate USDC needed using get_dy for accurate AMM pricing
        usdcForBearBuyback = _estimateUsdcForBearBuyback(totalBearToBuyBack);

        // Net USDC flow:
        // + expectedUSDC (from burning pairs)
        // + usdcFromBearSale (from selling extra BEAR)
        // - debtToRepay (paid to Morpho)
        // - usdcForBearBuyback (to buy back flash-minted BEAR)
        uint256 totalInflows = expectedUSDC + usdcFromBearSale;
        uint256 totalOutflows = debtToRepay + usdcForBearBuyback;

        expectedReturn = totalInflows > totalOutflows ? totalInflows - totalOutflows : 0;
    }

    /// @dev Estimates USDC needed to buy BEAR using binary search on Curve.
    /// @param bearAmount Target plDXY-BEAR amount to acquire.
    /// @return Estimated USDC needed (with slippage margin).
    function _estimateUsdcForBearBuyback(
        uint256 bearAmount
    ) private view returns (uint256) {
        if (bearAmount == 0) {
            return 0;
        }

        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, DecimalConstants.ONE_USDC);
        if (bearPerUsdc == 0) {
            return (bearAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        }

        // Binary search for accurate USDC estimate
        uint256 low = (bearAmount * DecimalConstants.ONE_USDC) / bearPerUsdc;
        uint256 high = low + (low / 5); // Start with 20% buffer

        // Ensure high is sufficient
        uint256 bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, high);
        while (bearAtHigh < bearAmount && high < type(uint128).max) {
            high = high * 2;
            bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, high);
        }

        // Binary search to find minimum USDC
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (low + high) / 2;
            uint256 bearOut = CURVE_POOL.get_dy(USDC_INDEX, PLDXY_BEAR_INDEX, mid);
            if (bearOut >= bearAmount) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high;
    }

}

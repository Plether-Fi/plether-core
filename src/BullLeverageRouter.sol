// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {MarketParams} from "./interfaces/IMorpho.sol";
import {LeverageRouterBase} from "./base/LeverageRouterBase.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title BullLeverageRouter
/// @notice Leverage router for DXY-BULL positions via Morpho Blue.
/// @dev Uses Morpho flash loans + Splitter minting to acquire DXY-BULL, then deposits as Morpho collateral.
///      Close operation uses a single DXY-BEAR flash mint for simplicity and gas efficiency.
///      Uses Morpho's fee-free flash loans for capital efficiency.
///
/// @dev STATE MACHINE - OPEN LEVERAGE:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ openLeverage(principal, leverage)                                       │
///      │   1. Pull USDC from user                                                │
///      │   2. Flash loan additional USDC from Morpho (fee-free)                  │
///      │      └──► onMorphoFlashLoan(OP_OPEN)                                    │
///      │            └──► _executeOpen()                                          │
///      │                  1. Mint DXY-BEAR + DXY-BULL pairs via Splitter         │
///      │                  2. Sell DXY-BEAR on Curve → USDC                       │
///      │                  3. Stake DXY-BULL → sDXY-BULL                          │
///      │                  4. Deposit sDXY-BULL to Morpho (user's collateral)     │
///      │                  5. Borrow USDC from Morpho to cover flash repayment    │
///      │                  6. Emit LeverageOpened event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
/// @dev STATE MACHINE - CLOSE LEVERAGE (Single Flash Mint):
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ closeLeverage(debtToRepay, collateralToWithdraw)                        │
///      │   1. Flash mint DXY-BEAR (collateral + extra for debt repayment)        │
///      │      └──► onFlashLoan(OP_CLOSE)                                         │
///      │            └──► _executeClose()                                         │
///      │                  1. Sell extra DXY-BEAR on Curve → USDC                 │
///      │                  2. Repay user's Morpho debt with USDC from sale        │
///      │                  3. Withdraw user's sDXY-BULL from Morpho               │
///      │                  4. Unstake sDXY-BULL → DXY-BULL                        │
///      │                  5. Redeem DXY-BEAR + DXY-BULL → USDC                   │
///      │                  6. Buy DXY-BEAR on Curve to repay flash mint           │
///      │                  7. Transfer remaining USDC to user                     │
///      │                  8. Emit LeverageClosed event                           │
///      └─────────────────────────────────────────────────────────────────────────┘
///
contract BullLeverageRouter is LeverageRouterBase {
    using SafeERC20 for IERC20;

    // Events
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 dxyBullReceived,
        uint256 debtIncurred,
        uint256 maxSlippageBps
    );

    event LeverageClosed(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 usdcReturned,
        uint256 maxSlippageBps
    );

    // Dependencies
    ISyntheticSplitter public immutable SPLITTER;
    IERC20 public immutable DXY_BULL;
    IERC4626 public immutable STAKED_DXY_BULL; // Staked token (Morpho collateral)

    // Cached from Splitter (immutable)
    uint256 public immutable CAP; // 8 decimals (oracle format)

    constructor(
        address _morpho,
        address _splitter,
        address _curvePool,
        address _usdc,
        address _dxyBear,
        address _dxyBull,
        address _stakedDxyBull,
        MarketParams memory _marketParams
    ) LeverageRouterBase(_morpho, _curvePool, _usdc, _dxyBear) {
        if (_splitter == address(0)) revert LeverageRouterBase__ZeroAddress();
        if (_dxyBull == address(0)) revert LeverageRouterBase__ZeroAddress();
        if (_stakedDxyBull == address(0)) revert LeverageRouterBase__ZeroAddress();

        SPLITTER = ISyntheticSplitter(_splitter);
        DXY_BULL = IERC20(_dxyBull);
        STAKED_DXY_BULL = IERC4626(_stakedDxyBull);
        marketParams = _marketParams;

        // Cache CAP from Splitter (8 decimals)
        CAP = ISyntheticSplitter(_splitter).CAP();

        // Approvals (One-time)
        // 1. Allow Splitter to take USDC (for minting pairs)
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 2. Allow Curve pool to take DXY-BEAR (for selling during open)
        DXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow Curve pool to take USDC (for buying BEAR during close)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 4. Allow StakedToken to take DXY-BULL (for staking)
        DXY_BULL.safeIncreaseAllowance(_stakedDxyBull, type(uint256).max);
        // 5. Allow Morpho to take sDXY-BULL (for supplying collateral)
        IERC20(_stakedDxyBull).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 6. Allow Morpho to take USDC (for repaying debt and flash loan)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 7. Allow Splitter to take DXY-BEAR (for redeeming pairs during close)
        DXY_BEAR.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 8. Allow Splitter to take DXY-BULL (for redeeming pairs during close)
        DXY_BULL.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 9. Allow DXY-BEAR to take back tokens (Flash Mint Repayment)
        DXY_BEAR.safeIncreaseAllowance(_dxyBear, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged DXY-BULL Position in one transaction.
     * @dev Mints pairs via Splitter, sells DXY-BEAR on Curve, deposits DXY-BULL to Morpho.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function openLeverage(uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (principal == 0) revert LeverageRouterBase__ZeroPrincipal();
        if (block.timestamp > deadline) revert LeverageRouterBase__Expired();
        if (leverage <= 1e18) revert LeverageRouterBase__LeverageTooLow();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert LeverageRouterBase__SlippageExceedsMax();
        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert LeverageRouterBase__NotAuthorized();
        if (SPLITTER.currentStatus() != ISyntheticSplitter.Status.ACTIVE) {
            revert LeverageRouterBase__SplitterNotActive();
        }

        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;
        if (loanAmount == 0) revert LeverageRouterBase__LeverageTooLow();

        USDC.safeTransferFrom(msg.sender, address(this), principal);

        uint256 totalUSDC = principal + loanAmount;
        uint256 dxyBearAmount = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);
        uint256 minSwapOut = (expectedUsdcFromSale * (10_000 - maxSlippageBps)) / 10_000;

        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, leverage, maxSlippageBps, minSwapOut);

        MORPHO.flashLoan(address(USDC), loanAmount, data);
    }

    /**
     * @notice Close a Leveraged DXY-BULL Position in one transaction.
     * @dev Uses a single DXY-BEAR flash mint to unwind positions efficiently.
     *      If debt exists, extra BEAR is flash minted and sold for USDC to repay.
     * @param debtToRepay Amount of USDC debt to repay. Can be 0 if no debt.
     * @param collateralToWithdraw Amount of sDXY-BULL collateral to withdraw.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(uint256 debtToRepay, uint256 collateralToWithdraw, uint256 maxSlippageBps, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (collateralToWithdraw == 0) revert LeverageRouterBase__ZeroCollateral();
        if (block.timestamp > deadline) revert LeverageRouterBase__Expired();
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert LeverageRouterBase__SlippageExceedsMax();
        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert LeverageRouterBase__NotAuthorized();

        // Convert staked shares to underlying BULL amount (for pair matching)
        uint256 dxyBullAmount = STAKED_DXY_BULL.previewRedeem(collateralToWithdraw);

        // Calculate extra BEAR needed to sell for debt repayment
        uint256 extraBearForDebt = 0;
        if (debtToRepay > 0) {
            // Query: how much USDC do we get for 1 BEAR (1e18)?
            uint256 usdcPerBear = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, 1e18);
            if (usdcPerBear == 0) revert LeverageRouterBase__InvalidCurvePrice();

            // Calculate BEAR needed to sell for debtToRepay USDC
            // Formula: (debt * 1e18) / usdcPerBear, with slippage buffer
            extraBearForDebt = (debtToRepay * 1e18) / usdcPerBear;
            // Add slippage buffer (extra % to ensure we get enough USDC)
            extraBearForDebt = extraBearForDebt + (extraBearForDebt * maxSlippageBps / 10_000);
        }

        // Total BEAR to flash mint: enough for pair redemption + extra for debt
        uint256 flashAmount = dxyBullAmount + extraBearForDebt;

        // Encode data for callback
        bytes memory data = abi.encode(
            OP_CLOSE, msg.sender, deadline, collateralToWithdraw, debtToRepay, extraBearForDebt, maxSlippageBps
        );

        // Single flash mint handles entire close operation
        IERC3156FlashLender(address(DXY_BEAR)).flashLoan(this, address(DXY_BEAR), flashAmount, data);

        // Event emitted in _executeClose callback
    }

    /**
     * @dev Morpho flash loan callback for USDC flash loans.
     *
     * Routes to the appropriate handler based on operation type:
     * - OP_OPEN (1): USDC flash loan for opening leverage position
     */
    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external override {
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

    /**
     * @dev ERC-3156 flash loan callback for DXY-BEAR flash mints.
     *
     * Routes to:
     * - OP_CLOSE (2): DXY-BEAR flash mint for closing leverage position
     *
     * Lender validation: Must be called by DXY-BEAR token (flash mint)
     */
    function onFlashLoan(address initiator, address, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        _validateFlashLoan(msg.sender, address(DXY_BEAR), initiator);

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_CLOSE) {
            _executeClose(amount, fee, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        return CALLBACK_SUCCESS;
    }

    /**
     * @dev Execute open leverage operation in flash loan callback.
     */
    /// @dev Deadline already validated in entry function, no need to check again.
    function _executeOpen(uint256 loanAmount, bytes calldata data) private {
        // Decode: (op, user, deadline, principal, leverage, maxSlippageBps, minSwapOut)
        (, address user,, uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 minSwapOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        // 1. Total USDC = Principal + Flash Loan
        uint256 totalUSDC = principal + loanAmount;

        // 2. Mint pairs via Splitter (USDC -> DXY-BEAR + DXY-BULL)
        // Splitter.mint expects token amount (18 decimals), not USDC (6 decimals)
        // tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        SPLITTER.mint((totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP);

        // 3. Sell ALL DXY-BEAR for USDC via Curve
        uint256 dxyBearBalance = DXY_BEAR.balanceOf(address(this));
        uint256 usdcFromSale = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, dxyBearBalance, minSwapOut);

        // 4. Stake DXY-BULL to get sDXY-BULL
        uint256 dxyBullReceived = DXY_BULL.balanceOf(address(this));
        uint256 stakedShares = STAKED_DXY_BULL.deposit(dxyBullReceived, address(this));

        // 5. Deposit sDXY-BULL collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 6. Borrow USDC from Morpho to repay flash loan (no fee with Morpho)
        // We already have usdcFromSale, so only borrow the remaining amount needed
        uint256 debtIncurred = loanAmount > usdcFromSale ? loanAmount - usdcFromSale : 0;
        if (debtIncurred > 0) {
            MORPHO.borrow(marketParams, debtIncurred, 0, user, address(this));
        }

        // 7. Emit event for off-chain tracking
        emit LeverageOpened(user, principal, leverage, loanAmount, dxyBullReceived, debtIncurred, maxSlippageBps);
    }

    /**
     * @dev Execute close leverage operation (single DXY-BEAR flash mint callback).
     *
     * Flow:
     * 1. If debt exists: Sell extra DXY-BEAR on Curve → USDC
     * 2. Repay Morpho debt with USDC from sale (if any)
     * 3. Withdraw sDXY-BULL collateral from Morpho
     * 4. Unstake sDXY-BULL → DXY-BULL
     * 5. Redeem DXY-BEAR + DXY-BULL pairs → USDC
     * 6. Buy back all DXY-BEAR on Curve to repay flash mint
     * 7. Transfer remaining USDC to user
     * 8. Emit LeverageClosed event
     */
    /// @dev Deadline already validated in entry function, no need to check again.
    function _executeClose(uint256 flashAmount, uint256 flashFee, bytes calldata data) private {
        // Decode: (op, user, deadline, collateralToWithdraw, debtToRepay, extraBearForDebt, maxSlippageBps)
        (
            ,
            address user,,
            uint256 collateralToWithdraw,
            uint256 debtToRepay,
            uint256 extraBearForDebt,
            uint256 maxSlippageBps
        ) = abi.decode(data, (uint8, address, uint256, uint256, uint256, uint256, uint256));

        // 1. If debt exists, sell extra BEAR for USDC to repay it
        if (debtToRepay > 0 && extraBearForDebt > 0) {
            // Sell extraBearForDebt BEAR → USDC (with slippage protection)
            uint256 minUsdcFromSale = (debtToRepay * (10_000 - maxSlippageBps)) / 10_000;
            uint256 usdcFromSale = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt, minUsdcFromSale);
            if (usdcFromSale < debtToRepay) revert LeverageRouterBase__InsufficientOutput();
        }

        // 2. Repay user's debt on Morpho (if any)
        if (debtToRepay > 0) {
            MORPHO.repay(marketParams, debtToRepay, 0, user, "");
        }

        // 3. Withdraw user's sDXY-BULL collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));

        // 4. Unstake sDXY-BULL to get DXY-BULL
        uint256 dxyBullReceived = STAKED_DXY_BULL.redeem(collateralToWithdraw, address(this), address(this));

        // 5. Redeem pairs via Splitter (DXY-BEAR + DXY-BULL → USDC)
        // We have exactly dxyBullReceived BULL, and (flashAmount - extraBearForDebt) BEAR remaining
        SPLITTER.burn(dxyBullReceived);

        // 6. Buy back ALL flash-minted BEAR to repay flash mint
        uint256 repayAmount = flashAmount + flashFee;

        // Current BEAR balance (from minting pairs)
        uint256 bearBalance = DXY_BEAR.balanceOf(address(this));

        // Need to buy: repayAmount - bearBalance
        if (repayAmount > bearBalance) {
            uint256 bearToBuy = repayAmount - bearBalance;

            // Estimate USDC needed using Curve price discovery
            uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, 1e6);
            if (bearPerUsdc == 0) revert LeverageRouterBase__InvalidCurvePrice();

            // Calculate USDC needed with slippage buffer
            uint256 estimatedUsdcNeeded = (bearToBuy * 1e6) / bearPerUsdc;
            uint256 maxUsdcToSpend = estimatedUsdcNeeded + (estimatedUsdcNeeded * maxSlippageBps / 10_000);

            // Verify we have enough USDC
            uint256 usdcBalance = USDC.balanceOf(address(this));
            if (usdcBalance < maxUsdcToSpend) revert LeverageRouterBase__InsufficientOutput();

            // Swap USDC → BEAR with min_dy = bearToBuy
            CURVE_POOL.exchange(USDC_INDEX, DXY_BEAR_INDEX, maxUsdcToSpend, bearToBuy);
        }

        // 7. Transfer remaining USDC to user
        uint256 usdcToReturn = USDC.balanceOf(address(this));
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // 8. Emit event for off-chain tracking
        emit LeverageClosed(user, debtToRepay, collateralToWithdraw, usdcToReturn, maxSlippageBps);

        // Flash mint repayment happens automatically when callback returns
        // DXY-BEAR token will burn repayAmount from this contract
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of opening a leveraged DXY-BULL position.
     * @param principal Amount of USDC user will send.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @return loanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC for minting pairs (principal + loan).
     * @return expectedDxyBull Expected DXY-BULL tokens received.
     * @return expectedDebt Expected Morpho debt (flash repayment - USDC from DXY-BEAR sale).
     */
    function previewOpenLeverage(uint256 principal, uint256 leverage)
        external
        view
        returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBull, uint256 expectedDebt)
    {
        if (leverage <= 1e18) revert LeverageRouterBase__LeverageTooLow();

        loanAmount = (principal * (leverage - 1e18)) / 1e18;
        totalUSDC = principal + loanAmount;
        // Splitter mints at CAP price: tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        expectedDxyBull = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        // Use Curve to estimate USDC from selling DXY-BEAR
        uint256 dxyBearAmount = expectedDxyBull;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);

        // No flash fee with Morpho
        // Debt = what we need to borrow from Morpho after using sale proceeds
        expectedDebt = loanAmount > expectedUsdcFromSale ? loanAmount - expectedUsdcFromSale : 0;
    }

    /**
     * @notice Preview the result of closing a leveraged DXY-BULL position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of DXY-BULL collateral to withdraw.
     * @return expectedUSDC Expected USDC from redeeming pairs.
     * @return usdcForBearBuyback Expected USDC needed to buy back DXY-BEAR.
     * @return expectedReturn Expected USDC returned to user after all repayments.
     */
    function previewCloseLeverage(uint256 debtToRepay, uint256 collateralToWithdraw)
        external
        view
        returns (uint256 expectedUSDC, uint256 usdcForBearBuyback, uint256 expectedReturn)
    {
        // Convert staked shares to underlying BULL amount
        uint256 dxyBullAmount = STAKED_DXY_BULL.previewRedeem(collateralToWithdraw);

        // Redeeming pairs at CAP: usdc = tokens * CAP / DecimalConstants.USDC_TO_TOKEN_SCALE
        expectedUSDC = (dxyBullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // Calculate extra BEAR needed to sell for debt repayment (mirrors closeLeverage logic)
        uint256 extraBearForDebt = 0;
        uint256 usdcFromBearSale = 0;
        if (debtToRepay > 0) {
            uint256 usdcPerBear = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, 1e18);
            if (usdcPerBear > 0) {
                // Calculate BEAR needed without slippage buffer (conservative estimate)
                extraBearForDebt = (debtToRepay * 1e18) / usdcPerBear;
                // Estimate actual USDC from selling this BEAR
                usdcFromBearSale = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, extraBearForDebt);
            }
        }

        // Total BEAR to buy back: dxyBullAmount + extraBearForDebt (flash fee is negligible)
        // After burn, bearBalance=0, so we need to buy back the full flash amount
        uint256 totalBearToBuyBack = dxyBullAmount + extraBearForDebt;

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

    /**
     * @dev Estimate USDC needed to buy a specific amount of BEAR using binary search.
     */
    function _estimateUsdcForBearBuyback(uint256 bearAmount) private view returns (uint256) {
        if (bearAmount == 0) return 0;

        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, 1e6);
        if (bearPerUsdc == 0) {
            return (bearAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        }

        // Binary search for accurate USDC estimate
        uint256 low = (bearAmount * 1e6) / bearPerUsdc;
        uint256 high = low + (low / 5); // Start with 20% buffer

        // Ensure high is sufficient
        uint256 bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, high);
        while (bearAtHigh < bearAmount && high < type(uint128).max) {
            high = high * 2;
            bearAtHigh = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, high);
        }

        // Binary search to find minimum USDC
        for (uint256 i = 0; i < 20; i++) {
            uint256 mid = (low + high) / 2;
            uint256 bearOut = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, mid);
            if (bearOut >= bearAmount) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high;
    }
}

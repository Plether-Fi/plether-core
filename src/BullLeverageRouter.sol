// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";
import {FlashLoanBase} from "./base/FlashLoanBase.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title BullLeverageRouter
/// @notice Leverage router for DXY-BULL positions via Morpho Blue.
/// @dev Uses flash loans + Splitter minting to acquire DXY-BULL, then deposits as Morpho collateral.
///      Close operation uses nested flash loans (USDC + DXY-BEAR flash mint) to unwind positions.
///
/// @dev STATE MACHINE - OPEN LEVERAGE:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ openLeverage(principal, leverage)                                       │
///      │   1. Pull USDC from user                                                │
///      │   2. Flash loan additional USDC from Lender                             │
///      │      └──► onFlashLoan(OP_OPEN)                                          │
///      │            └──► _executeOpen()                                          │
///      │                  1. Mint DXY-BEAR + DXY-BULL pairs via Splitter         │
///      │                  2. Sell DXY-BEAR on Curve → USDC                       │
///      │                  3. Stake DXY-BULL → sDXY-BULL                          │
///      │                  4. Deposit sDXY-BULL to Morpho (user's collateral)     │
///      │                  5. Borrow USDC from Morpho to cover flash repayment    │
///      │   3. Emit LeverageOpened event                                          │
///      └─────────────────────────────────────────────────────────────────────────┘
///
/// @dev STATE MACHINE - CLOSE LEVERAGE (Nested Flash Loans):
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │ closeLeverage(debtToRepay, collateralToWithdraw)                        │
///      │   1. Flash loan USDC from Lender                                        │
///      │      └──► onFlashLoan(OP_CLOSE)                                         │
///      │            └──► _executeClose()                                         │
///      │                  1. Repay user's Morpho debt with flash loaned USDC     │
///      │                  2. Withdraw user's sDXY-BULL from Morpho               │
///      │                  3. Unstake sDXY-BULL → DXY-BULL                        │
///      │                  4. Flash mint DXY-BEAR (equal to DXY-BULL amount)      │
///      │                     └──► onFlashLoan(OP_CLOSE_REDEEM)  [NESTED]         │
///      │                           └──► _executeCloseRedeem()                    │
///      │                                 1. Redeem DXY-BEAR + DXY-BULL → USDC    │
///      │                                 2. Buy DXY-BEAR on Curve to repay mint  │
///      │                  5. Transfer remaining USDC to user                     │
///      │   2. Emit LeverageClosed event                                          │
///      └─────────────────────────────────────────────────────────────────────────┘
///
contract BullLeverageRouter is FlashLoanBase {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage
    uint256 public constant USDC_INDEX = 0; // USDC index in Curve pool
    uint256 public constant DXY_BEAR_INDEX = 1; // DXY-BEAR index in Curve pool

    // Operation types for flash loan callback
    uint8 private constant OP_OPEN = 1;
    uint8 private constant OP_CLOSE = 2;
    uint8 private constant OP_CLOSE_REDEEM = 3; // Nested flash mint callback for close

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

    // ==========================================
    // TRANSIENT STATE (callback → caller communication)
    // ==========================================
    // These variables pass results from flash loan callbacks back to the
    // initiating function for event emission. Reset after each operation.

    /// @dev Open operation results (set in _executeOpen, read in openLeverage)
    uint256 private _lastDxyBullReceived;
    uint256 private _lastDebtIncurred;

    /// @dev Close operation results (set in _executeClose, read in closeLeverage)
    uint256 private _lastCollateralWithdrawn;
    uint256 private _lastUsdcReturned;

    /// @dev Nested flash loan state (set in _executeClose, read in _executeCloseRedeem)
    /// Required because the nested DXY-BEAR flash mint callback cannot access
    /// the outer USDC flash loan's parameters directly.
    address private _closeUser;
    uint256 private _closeUsdcFlashAmount;
    uint256 private _closeUsdcFlashFee;

    // Dependencies
    IMorpho public immutable MORPHO;
    ISyntheticSplitter public immutable SPLITTER;
    ICurvePool public immutable CURVE_POOL;
    IERC20 public immutable USDC;
    IERC20 public immutable DXY_BEAR;
    IERC20 public immutable DXY_BULL;
    IERC4626 public immutable STAKED_DXY_BULL; // Staked token (Morpho collateral)
    IERC3156FlashLender public immutable LENDER; // USDC flash lender (e.g., Aave or Balancer)
    // Morpho Market ID Configuration (sDXY-BULL as collateral)
    MarketParams public marketParams;

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
        address _lender,
        MarketParams memory _marketParams
    ) {
        MORPHO = IMorpho(_morpho);
        SPLITTER = ISyntheticSplitter(_splitter);
        CURVE_POOL = ICurvePool(_curvePool);
        USDC = IERC20(_usdc);
        DXY_BEAR = IERC20(_dxyBear);
        DXY_BULL = IERC20(_dxyBull);
        STAKED_DXY_BULL = IERC4626(_stakedDxyBull);
        LENDER = IERC3156FlashLender(_lender);
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
        // 6. Allow Morpho to take USDC (for repaying debt)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 7. Allow Lender to take back USDC (Flash Loan Repayment)
        USDC.safeIncreaseAllowance(_lender, type(uint256).max);
        // 8. Allow Splitter to take DXY-BEAR (for redeeming pairs during close)
        DXY_BEAR.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 9. Allow Splitter to take DXY-BULL (for redeeming pairs during close)
        DXY_BULL.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 10. Allow DXY-BEAR to take back tokens (Flash Mint Repayment)
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
    function openLeverage(uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 deadline) external {
        require(principal > 0, "Principal must be > 0");
        require(block.timestamp <= deadline, "Transaction expired");
        require(leverage > 1e18, "Leverage must be > 1x");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "BullLeverageRouter not authorized in Morpho");
        require(SPLITTER.currentStatus() == ISyntheticSplitter.Status.ACTIVE, "Splitter not active");

        // Calculate Flash Loan Amount
        // If User has $1000 and wants 3x ($3000 exposure):
        // We need to mint $3000 worth of pairs.
        // We have $1000. We need to borrow $2000.
        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;
        require(loanAmount > 0, "Leverage too low for principal");

        // Pull User Funds
        USDC.safeTransferFrom(msg.sender, address(this), principal);

        // Calculate minimum USDC output from selling DXY-BEAR using Curve price discovery
        // Splitter mints at CAP price: tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        // For CAP=$2, $1 USDC → 0.5 pairs (0.5e18 of each token)
        uint256 totalUSDC = principal + loanAmount;
        uint256 dxyBearAmount = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);
        uint256 minSwapOut = (expectedUsdcFromSale * (10_000 - maxSlippageBps)) / 10_000;

        // Encode data for callback
        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, minSwapOut);

        // Initiate Flash Loan (Get the extra USDC)
        LENDER.flashLoan(this, address(USDC), loanAmount, data);

        // Emit event for off-chain tracking
        emit LeverageOpened(
            msg.sender, principal, leverage, loanAmount, _lastDxyBullReceived, _lastDebtIncurred, maxSlippageBps
        );
    }

    /**
     * @notice Close a Leveraged DXY-BULL Position in one transaction.
     * @dev Uses nested flash loans: USDC flash loan to repay Morpho, then DXY-BEAR flash mint
     *      to pair with withdrawn DXY-BULL for redemption.
     * @param debtToRepay Amount of USDC debt to repay (flash loaned).
     * @param collateralToWithdraw Amount of DXY-BULL collateral to withdraw.
     * @param maxSlippageBps Maximum slippage tolerance in basis points.
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(uint256 debtToRepay, uint256 collateralToWithdraw, uint256 maxSlippageBps, uint256 deadline)
        external
    {
        require(block.timestamp <= deadline, "Transaction expired");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "BullLeverageRouter not authorized in Morpho");

        // Encode data for callback
        bytes memory data = abi.encode(OP_CLOSE, msg.sender, deadline, collateralToWithdraw, maxSlippageBps);

        // Initiate Flash Loan (to repay Morpho debt)
        LENDER.flashLoan(this, address(USDC), debtToRepay, data);

        // Emit event for off-chain tracking
        emit LeverageClosed(msg.sender, debtToRepay, _lastCollateralWithdrawn, _lastUsdcReturned, maxSlippageBps);
    }

    /**
     * @dev Flash loan callback dispatcher.
     *
     * Routes to the appropriate handler based on operation type:
     * - OP_OPEN (1): USDC flash loan for opening leverage position
     * - OP_CLOSE (2): USDC flash loan for closing leverage (phase 1)
     * - OP_CLOSE_REDEEM (3): DXY-BEAR flash mint for pair redemption (phase 2, nested)
     *
     * Lender validation:
     * - OP_OPEN/OP_CLOSE: Must be called by USDC flash lender
     * - OP_CLOSE_REDEEM: Must be called by DXY-BEAR token (flash mint)
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        _validateInitiator(initiator);

        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_OPEN) {
            // Phase: OPEN - USDC flash loan to mint pairs
            _validateLender(msg.sender, address(LENDER));
            _executeOpen(amount, fee, data);
        } else if (operation == OP_CLOSE) {
            // Phase: CLOSE (1/2) - USDC flash loan to repay Morpho debt
            _validateLender(msg.sender, address(LENDER));
            _executeClose(amount, fee, data);
        } else if (operation == OP_CLOSE_REDEEM) {
            // Phase: CLOSE (2/2) - Nested DXY-BEAR flash mint for pair redemption
            _validateLender(msg.sender, address(DXY_BEAR));
            _executeCloseRedeem(amount, fee, data);
        } else {
            revert FlashLoan__InvalidOperation();
        }

        return CALLBACK_SUCCESS;
    }

    /**
     * @dev Execute open leverage operation in flash loan callback.
     */
    function _executeOpen(uint256 loanAmount, uint256 fee, bytes calldata data) private {
        // Decode: (op, user, deadline, principal, minSwapOut)
        (, address user, uint256 deadline, uint256 principal, uint256 minSwapOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        require(block.timestamp <= deadline, "Transaction expired");

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
        uint256 dxyBullBalance = DXY_BULL.balanceOf(address(this));
        _lastDxyBullReceived = dxyBullBalance;
        uint256 stakedShares = STAKED_DXY_BULL.deposit(dxyBullBalance, address(this));

        // 5. Deposit sDXY-BULL collateral to Morpho on behalf of the USER
        MORPHO.supplyCollateral(marketParams, stakedShares, user, "");

        // 6. Borrow USDC from Morpho to repay flash loan
        // We already have usdcFromSale, so only borrow the remaining amount needed
        uint256 flashRepayment = loanAmount + fee;
        uint256 debtToIncur = flashRepayment > usdcFromSale ? flashRepayment - usdcFromSale : 0;
        _lastDebtIncurred = debtToIncur;
        if (debtToIncur > 0) {
            MORPHO.borrow(marketParams, debtToIncur, 0, user, address(this));
        }
    }

    /**
     * @dev Execute close leverage operation - Phase 1 of 2 (USDC flash loan callback).
     *
     * Flow:
     * 1. Repay Morpho debt with flash loaned USDC
     * 2. Withdraw sDXY-BULL collateral from Morpho
     * 3. Unstake to get DXY-BULL
     * 4. Initiate nested DXY-BEAR flash mint → triggers _executeCloseRedeem
     * 5. After nested callback returns: transfer remaining USDC to user
     */
    function _executeClose(uint256 loanAmount, uint256 fee, bytes calldata data) private {
        // Decode: (op, user, deadline, collateralToWithdraw, maxSlippageBps)
        (, address user, uint256 deadline, uint256 collateralToWithdraw, uint256 maxSlippageBps) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        require(block.timestamp <= deadline, "Transaction expired");

        // 1. Repay user's debt on Morpho (skip if no debt)
        if (loanAmount > 0) {
            MORPHO.repay(marketParams, loanAmount, 0, user, "");
        }

        // 2. Withdraw user's sDXY-BULL collateral from Morpho
        MORPHO.withdrawCollateral(marketParams, collateralToWithdraw, user, address(this));
        _lastCollateralWithdrawn = collateralToWithdraw;

        // 3. Unstake sDXY-BULL to get DXY-BULL
        uint256 dxyBullReceived = STAKED_DXY_BULL.redeem(collateralToWithdraw, address(this), address(this));

        // 4. Store state for nested callback
        _closeUser = user;
        _closeUsdcFlashAmount = loanAmount;
        _closeUsdcFlashFee = fee;

        // 5. Flash mint DXY-BEAR to pair with DXY-BULL for redemption
        // We need equal amounts of DXY-BEAR and DXY-BULL to redeem
        bytes memory redeemData = abi.encode(OP_CLOSE_REDEEM, user, deadline, dxyBullReceived, maxSlippageBps);
        IERC3156FlashLender(address(DXY_BEAR)).flashLoan(this, address(DXY_BEAR), dxyBullReceived, redeemData);

        // After nested callback completes, repay USDC flash loan
        // (USDC should now be in contract from redemption)
        uint256 flashRepayment = loanAmount + fee;
        uint256 usdcBalance = USDC.balanceOf(address(this));
        require(usdcBalance >= flashRepayment, "Insufficient USDC from redemption");

        // 6. Send remaining USDC to user
        uint256 usdcToReturn = usdcBalance - flashRepayment;
        _lastUsdcReturned = usdcToReturn;
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }

        // Clean up transient state
        _closeUser = address(0);
        _closeUsdcFlashAmount = 0;
        _closeUsdcFlashFee = 0;
    }

    /**
     * @dev Execute close redemption - Phase 2 of 2 (nested DXY-BEAR flash mint callback).
     *
     * Flow:
     * 1. Redeem DXY-BEAR + DXY-BULL pairs via Splitter → receive USDC
     * 2. Buy DXY-BEAR on Curve to repay flash mint
     * 3. Return to _executeClose with USDC balance for final distribution
     *
     * Note: Flash mint repayment (burning DXY-BEAR) happens automatically
     * when this callback returns - the token contract handles it.
     */
    function _executeCloseRedeem(uint256 flashMintAmount, uint256 fee, bytes calldata data) private {
        // Decode: (op, user, deadline, dxyBullAmount, maxSlippageBps)
        (, address user, uint256 deadline, uint256 dxyBullAmount, uint256 maxSlippageBps) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        require(block.timestamp <= deadline, "Transaction expired");

        // 1. Redeem pairs via Splitter (DXY-BEAR + DXY-BULL -> USDC)
        // Both tokens should be in equal amounts. This burns both tokens.
        SPLITTER.burn(dxyBullAmount);

        // 2. Buy DXY-BEAR back on Curve to repay flash mint
        // We need flashMintAmount + fee of DXY-BEAR
        uint256 repayAmount = flashMintAmount + fee;

        // Use Curve's get_dy to estimate USDC needed for buying BEAR
        // Since Curve only supports "sell exact input", we estimate and add buffer
        // Query: how much BEAR do we get for 1 USDC?
        uint256 testUsdcAmount = 1e6; // 1 USDC
        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, testUsdcAmount);
        require(bearPerUsdc > 0, "Invalid Curve price");

        // Calculate USDC needed: repayAmount / (BEAR per USDC)
        // Scale properly: repayAmount * testUsdcAmount / bearPerUsdc
        uint256 estimatedUsdcNeeded = (repayAmount * testUsdcAmount) / bearPerUsdc;

        // Add slippage buffer (spend more USDC to ensure we get enough BEAR)
        uint256 maxUsdcToSpend = estimatedUsdcNeeded + (estimatedUsdcNeeded * maxSlippageBps / 10_000);

        // Ensure we don't spend more than we have
        uint256 usdcBalance = USDC.balanceOf(address(this));
        require(usdcBalance >= maxUsdcToSpend, "Insufficient USDC for BEAR buyback");

        // Swap USDC for DXY-BEAR with min_dy = repayAmount (must get at least this much)
        CURVE_POOL.exchange(USDC_INDEX, DXY_BEAR_INDEX, maxUsdcToSpend, repayAmount);

        // Note: Flash mint repayment happens automatically when callback returns
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
        require(leverage > 1e18, "Leverage must be > 1x");

        loanAmount = (principal * (leverage - 1e18)) / 1e18;
        totalUSDC = principal + loanAmount;
        // Splitter mints at CAP price: tokens = usdc * DecimalConstants.USDC_TO_TOKEN_SCALE / CAP
        expectedDxyBull = (totalUSDC * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        // Use Curve to estimate USDC from selling DXY-BEAR
        uint256 dxyBearAmount = expectedDxyBull;
        uint256 expectedUsdcFromSale = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, dxyBearAmount);

        uint256 flashFee = LENDER.flashFee(address(USDC), loanAmount);
        uint256 flashRepayment = loanAmount + flashFee;

        // Debt = what we need to borrow from Morpho after using sale proceeds
        expectedDebt = flashRepayment > expectedUsdcFromSale ? flashRepayment - expectedUsdcFromSale : 0;
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
        // Convert staked shares to underlying BULL amount (shares have 1000x offset)
        uint256 dxyBullAmount = STAKED_DXY_BULL.previewRedeem(collateralToWithdraw);

        // Redeeming pairs at CAP: usdc = tokens * CAP / DecimalConstants.USDC_TO_TOKEN_SCALE
        expectedUSDC = (dxyBullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;

        // Estimate USDC needed to buy back DXY-BEAR for flash mint repayment
        uint256 testUsdcAmount = 1e6; // 1 USDC
        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, testUsdcAmount);
        if (bearPerUsdc > 0) {
            usdcForBearBuyback = (dxyBullAmount * testUsdcAmount) / bearPerUsdc;
        } else {
            // Fallback: use CAP pricing
            usdcForBearBuyback = (dxyBullAmount * CAP) / DecimalConstants.USDC_TO_TOKEN_SCALE;
        }

        // Flash loan fee for USDC debt repayment
        uint256 flashFee = LENDER.flashFee(address(USDC), debtToRepay);
        uint256 totalCosts = debtToRepay + flashFee + usdcForBearBuyback;

        expectedReturn = expectedUSDC > totalCosts ? expectedUSDC - totalCosts : 0;
    }
}

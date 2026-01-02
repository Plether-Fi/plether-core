// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";

/// @notice Leverage router for DXY-BULL positions via Morpho Blue.
/// @dev Uses flash loans + Splitter minting to acquire DXY-BULL, then deposits as Morpho collateral.
///      Close operation uses nested flash loans (USDC + DXY-BEAR flash mint) to unwind positions.
contract BullLeverageRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage
    int128 public constant USDC_INDEX = 0; // USDC index in Curve pool
    int128 public constant DXY_BEAR_INDEX = 1; // DXY-BEAR index in Curve pool

    // Splitter pricing constants (must match SyntheticSplitter)
    // CAP = $2.00 in oracle format (8 decimals)
    // USDC_MULTIPLIER = 10^(18 + 8 - 6) = 1e20 for USDC with 6 decimals
    // tokens = usdcAmount * USDC_MULTIPLIER / CAP
    uint256 public constant CAP = 2e8; // $2.00 in 8 decimal format
    uint256 public constant USDC_MULTIPLIER = 1e20;

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

    // Transient state for passing values between callbacks
    uint256 private _lastDxyBullReceived;
    uint256 private _lastDebtIncurred;
    uint256 private _lastCollateralWithdrawn;
    uint256 private _lastUsdcReturned;

    // Close operation transient state (for nested flash loan)
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

        // Approvals (One-time)
        // 1. Allow Splitter to take USDC (for minting pairs)
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // 2. Allow Curve pool to take DXY-BEAR (for selling)
        DXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow StakedToken to take DXY-BULL (for staking)
        DXY_BULL.safeIncreaseAllowance(_stakedDxyBull, type(uint256).max);
        // 4. Allow Morpho to take sDXY-BULL (for supplying collateral)
        IERC20(_stakedDxyBull).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 5. Allow Morpho to take USDC (for repaying debt)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 6. Allow Lender to take back USDC (Flash Loan Repayment)
        USDC.safeIncreaseAllowance(_lender, type(uint256).max);
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
        // Splitter mints at CAP price: tokens = usdc * USDC_MULTIPLIER / CAP
        // For CAP=$2, $1 USDC → 0.5 pairs (0.5e18 of each token)
        uint256 totalUSDC = principal + loanAmount;
        uint256 dxyBearAmount = (totalUSDC * USDC_MULTIPLIER) / CAP;
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
     * @dev Callback: Handles open, close, and close-redeem operations.
     *      Called by USDC Lender for OP_OPEN and OP_CLOSE.
     *      Called by DXY-BEAR token for OP_CLOSE_REDEEM (nested flash mint).
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(initiator == address(this), "Untrusted initiator");

        // Decode operation type
        uint8 operation = abi.decode(data, (uint8));

        if (operation == OP_OPEN) {
            require(msg.sender == address(LENDER), "Untrusted lender");
            _executeOpen(amount, fee, data);
        } else if (operation == OP_CLOSE) {
            require(msg.sender == address(LENDER), "Untrusted lender");
            _executeClose(amount, fee, data);
        } else if (operation == OP_CLOSE_REDEEM) {
            require(msg.sender == address(DXY_BEAR), "Untrusted lender");
            _executeCloseRedeem(amount, fee, data);
        } else {
            revert("Invalid operation");
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
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
        SPLITTER.mint(totalUSDC);

        // 3. Sell ALL DXY-BEAR for USDC via Curve
        uint256 dxyBearBalance = DXY_BEAR.balanceOf(address(this));
        uint256 usdcFromSale = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, dxyBearBalance, minSwapOut);

        // 4. Stake DXY-BULL to get sDXY-BULL
        uint256 dxyBullBalance = DXY_BULL.balanceOf(address(this));
        _lastDxyBullReceived = dxyBullBalance;
        uint256 stakedShares = STAKED_DXY_BULL.deposit(dxyBullBalance, address(this));

        // 5. Deposit sDXY-BULL to Morpho on behalf of the USER
        MORPHO.supply(marketParams, stakedShares, 0, user, "");

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
     * @dev Execute close leverage operation - first phase (USDC flash loan callback).
     *      Repays Morpho, withdraws DXY-BULL, then initiates DXY-BEAR flash mint.
     */
    function _executeClose(uint256 loanAmount, uint256 fee, bytes calldata data) private {
        // Decode: (op, user, deadline, collateralToWithdraw, maxSlippageBps)
        (, address user, uint256 deadline, uint256 collateralToWithdraw, uint256 maxSlippageBps) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        require(block.timestamp <= deadline, "Transaction expired");

        // 1. Repay user's debt on Morpho
        MORPHO.repay(marketParams, loanAmount, 0, user, "");

        // 2. Withdraw user's sDXY-BULL collateral from Morpho
        (uint256 withdrawnShares,) = MORPHO.withdraw(marketParams, collateralToWithdraw, 0, user, address(this));
        _lastCollateralWithdrawn = withdrawnShares;

        // 3. Unstake sDXY-BULL to get DXY-BULL
        uint256 dxyBullReceived = STAKED_DXY_BULL.redeem(withdrawnShares, address(this), address(this));

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
     * @dev Execute close redemption - second phase (DXY-BEAR flash mint callback).
     *      Redeems DXY-BEAR + DXY-BULL pairs for USDC via Splitter, then buys
     *      DXY-BEAR back on Curve to repay the flash mint.
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
        // Splitter mints at CAP price: tokens = usdc * USDC_MULTIPLIER / CAP
        expectedDxyBull = (totalUSDC * USDC_MULTIPLIER) / CAP;

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
        // Redeeming pairs at CAP: usdc = tokens * CAP / USDC_MULTIPLIER
        expectedUSDC = (collateralToWithdraw * CAP) / USDC_MULTIPLIER;

        // Estimate USDC needed to buy back DXY-BEAR for flash mint repayment
        uint256 testUsdcAmount = 1e6; // 1 USDC
        uint256 bearPerUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, testUsdcAmount);
        if (bearPerUsdc > 0) {
            usdcForBearBuyback = (collateralToWithdraw * testUsdcAmount) / bearPerUsdc;
        } else {
            // Fallback: use CAP pricing
            usdcForBearBuyback = (collateralToWithdraw * CAP) / USDC_MULTIPLIER;
        }

        // Flash loan fee for USDC debt repayment
        uint256 flashFee = LENDER.flashFee(address(USDC), debtToRepay);
        uint256 totalCosts = debtToRepay + flashFee + usdcForBearBuyback;

        expectedReturn = expectedUSDC > totalCosts ? expectedUSDC - totalCosts : 0;
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";
import {FlashLoanBase} from "./base/FlashLoanBase.sol";
import {DecimalConstants} from "./libraries/DecimalConstants.sol";

/// @title ZapRouter
/// @notice Efficient router for acquiring DXY-BULL tokens using flash mints.
/// @dev Flash mints DXY-BEAR → swaps to USDC via Curve → mints pairs → keeps DXY-BULL.
///      For DXY-BEAR, users should swap directly on Curve instead.
contract ZapRouter is FlashLoanBase {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage (caps MEV extraction)
    uint256 public constant USDC_INDEX = 0; // USDC index in Curve pool
    uint256 public constant DXY_BEAR_INDEX = 1; // DXY-BEAR index in Curve pool

    // Immutable Dependencies
    ISyntheticSplitter public immutable SPLITTER;
    IERC20 public immutable DXY_BEAR;
    IERC20 public immutable DXY_BULL;
    IERC20 public immutable USDC;
    ICurvePool public immutable CURVE_POOL;

    // Cached from Splitter (immutable)
    uint256 public immutable CAP; // 8 decimals (oracle format)
    uint256 public immutable CAP_PRICE; // 6 decimals (for Curve price comparison)

    // Action Flags for Flash Loan
    uint256 private constant ACTION_MINT = 0;
    uint256 private constant ACTION_BURN = 1;

    // Transient state for passing swap result from callback to main function
    uint256 private _lastSwapOut;

    // Events
    event ZapMint(
        address indexed user, uint256 usdcIn, uint256 tokensOut, uint256 maxSlippageBps, uint256 actualSwapOut
    );
    event ZapBurn(address indexed user, uint256 tokensIn, uint256 usdcOut);

    constructor(address _splitter, address _dxyBear, address _dxyBull, address _usdc, address _curvePool) {
        SPLITTER = ISyntheticSplitter(_splitter);
        DXY_BEAR = IERC20(_dxyBear);
        DXY_BULL = IERC20(_dxyBull);
        USDC = IERC20(_usdc);
        CURVE_POOL = ICurvePool(_curvePool);

        // Cache CAP from Splitter (8 decimals) and derive 6-decimal version for price checks
        CAP = ISyntheticSplitter(_splitter).CAP();
        CAP_PRICE = CAP / 100; // 8 dec -> 6 dec

        // Pre-approve the Splitter to take our USDC
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // Pre-approve the Curve pool to take DXY-BEAR (for swapping)
        IERC20(_dxyBear).safeIncreaseAllowance(_curvePool, type(uint256).max);
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    /**
     * @notice Buy DXY-BULL using USDC with flash mint efficiency.
     * @dev For DXY-BEAR, swap directly on Curve instead.
     * @param usdcAmount The amount of USDC the user is sending.
     * @param minAmountOut Minimum amount of DXY-BULL tokens to receive.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 100 = 1%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function zapMint(uint256 usdcAmount, uint256 minAmountOut, uint256 maxSlippageBps, uint256 deadline) external {
        require(usdcAmount > 0, "Amount must be > 0");
        require(block.timestamp <= deadline, "Transaction expired");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");
        require(SPLITTER.currentStatus() == ISyntheticSplitter.Status.ACTIVE, "Splitter not active");

        // 1. Get Spot Price
        uint256 priceBear = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, 1e18);
        require(priceBear < CAP_PRICE, "Bear price > Cap");

        // 2. Calculate Bull Price (e.g., $2.00 - $1.10 = $0.90)
        uint256 priceBull = CAP_PRICE - priceBear;

        // 3. Calculate Theoretical Max Borrow
        // Example: $1000 / $0.90 = 1111 Bear Tokens
        uint256 theoreticalFlash = (usdcAmount * 1e18) / priceBull;

        // Apply solvency buffer to cover swap fees (~0.04%) and rounding
        uint256 bufferBps = 100; // 1% buffer
        uint256 flashAmount = (theoreticalFlash * (10000 - bufferBps)) / 10000;

        // 4. Calculate Expected Swap Output (with Price Impact)
        uint256 expectedSwapOut = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, flashAmount);
        uint256 minSwapOut = (expectedSwapOut * (10000 - maxSlippageBps)) / 10000;

        // 5. Initiate Flash Loan
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        bytes memory data = abi.encode(ACTION_MINT, msg.sender, usdcAmount, minSwapOut);

        IERC3156FlashLender(address(DXY_BEAR)).flashLoan(this, address(DXY_BEAR), flashAmount, data);

        // 6. Final Transfer
        uint256 tokensOut = DXY_BULL.balanceOf(address(this));
        require(tokensOut >= minAmountOut, "Slippage too high");
        DXY_BULL.safeTransfer(msg.sender, tokensOut);

        emit ZapMint(msg.sender, usdcAmount, tokensOut, maxSlippageBps, _lastSwapOut);
    }

    // =================================================================
    // ZAP BURN (BULL -> USDC)
    // =================================================================

    /// @notice Sell DXY-BULL tokens for USDC using flash mint efficiency.
    /// @param bullAmount Amount of DXY-BULL to sell.
    /// @param minUsdcOut Minimum USDC to receive (slippage protection).
    /// @param deadline Unix timestamp after which the transaction reverts.
    function zapBurn(uint256 bullAmount, uint256 minUsdcOut, uint256 deadline) external {
        require(bullAmount > 0, "Amount > 0");
        require(block.timestamp <= deadline, "Expired");

        // 1. Pull Bull Tokens from User
        DXY_BULL.safeTransferFrom(msg.sender, address(this), bullAmount);

        // 2. Flash Borrow Matching Bear Tokens
        // To merge and unlock collateral, we need 1 Bear for every 1 Bull.
        uint256 flashAmount = bullAmount;

        // Encode ACTION_BURN
        bytes memory data = abi.encode(ACTION_BURN, msg.sender, bullAmount, minUsdcOut);
        IERC3156FlashLender(address(DXY_BEAR)).flashLoan(this, address(DXY_BEAR), flashAmount, data);

        // 3. Final Check (USDC sent in callback)
        emit ZapBurn(msg.sender, bullAmount, _lastSwapOut);
    }

    // =================================================================
    // FLASH LOAN CALLBACK
    // =================================================================

    /// @dev ERC-3156 flash loan callback. Handles both mint and burn operations.
    function onFlashLoan(address initiator, address, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        _validateFlashLoan(msg.sender, address(DXY_BEAR), initiator);

        // Decode Action Flag First
        (uint256 action, address user, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (uint256, address, uint256, uint256));

        if (action == ACTION_MINT) {
            _handleMint(amount, fee, user, minOut);
        } else {
            _handleBurn(amount, fee, user, minOut);
        }

        return CALLBACK_SUCCESS;
    }

    function _handleMint(uint256 loanAmount, uint256 fee, address user, uint256 minSwapOut) internal {
        // 1. Swap Borrowed Bear -> USDC via Curve
        uint256 swappedUsdc = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, loanAmount, minSwapOut);
        _lastSwapOut = swappedUsdc;

        // Use balance check as source of truth (handles dust/fee-on-transfer edge cases)
        uint256 totalUsdc = USDC.balanceOf(address(this));

        // Calculate mint amount: scale USDC (6 dec) to pairs (18 dec) using CAP
        // Formula: mintAmount = totalUsdc * USDC_TO_TOKEN_SCALE / CAP (inverse of Splitter's usdcNeeded calculation)
        uint256 mintAmount = (totalUsdc * DecimalConstants.USDC_TO_TOKEN_SCALE) / CAP;

        // Note: Splitter is already approved for max in constructor
        SPLITTER.mint(mintAmount);

        // 3. Repay the Flash Loan
        uint256 repayAmount = loanAmount + fee;
        DXY_BEAR.safeIncreaseAllowance(msg.sender, repayAmount);

        // 4. Sweep Dust
        // Check if we successfully minted enough to repay (Safety Check)
        uint256 currentBalance = DXY_BEAR.balanceOf(address(this));
        require(currentBalance >= repayAmount, "Solvency Breach: Not enough Bear minted");

        if (currentBalance > repayAmount) {
            uint256 surplus = currentBalance - repayAmount;
            DXY_BEAR.safeTransfer(user, surplus);
        }
    }

    function _handleBurn(uint256 loanAmount, uint256 fee, address user, uint256 minUsdcOut) internal {
        // State: We have `loanAmount` Bear (Borrowed) + `loanAmount` Bull (From User)

        // 1. Combine to Unlock USDC
        // This burns Bull+Bear and sends USDC to this contract
        SPLITTER.burn(loanAmount);

        // 2. Calculate Debt in Bear (Loan + Fee)
        uint256 debtBear = loanAmount + fee;

        // 3. Buy Debt Bear using USDC
        // FIX: Don't use get_dx (fragile). Estimate using get_dy + Buffer.

        // Step A: Get price for 1 USDC
        // "How much Bear do I get for 1 USDC?"
        uint256 bearFromOneUsdc = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, 1e6);
        require(bearFromOneUsdc > 0, "Pool liquidity error");

        // Step B: Calculate Linear Requirement
        // (Debt / Rate) = USDC needed
        // (18 dec * 6 dec) / 18 dec = 6 dec
        uint256 usdcLinear = (debtBear * 1e6) / bearFromOneUsdc;

        // Step C: Apply Safety Buffer (1%)
        // We swap slightly more USDC to handle slippage/fees and guarantee we get enough Bear.
        // Any excess Bear is swept to user.
        uint256 usdcToSwap = (usdcLinear * 10100) / 10000;

        // Sanity Check: Do we have enough USDC?
        uint256 totalUsdc = USDC.balanceOf(address(this));
        if (usdcToSwap > totalUsdc) {
            usdcToSwap = totalUsdc; // Cap at max available (hoping it's enough)
        }

        // Execute Swap
        CURVE_POOL.exchange(USDC_INDEX, DXY_BEAR_INDEX, usdcToSwap, 0);

        // 4. Repay Loan
        DXY_BEAR.safeIncreaseAllowance(msg.sender, debtBear);

        // Verify we actually bought enough (Solvency Check)
        uint256 bearBalance = DXY_BEAR.balanceOf(address(this));
        require(bearBalance >= debtBear, "Burn Solvency: Not enough Bear bought");

        // 5. Send remaining USDC to User (The Exit)
        uint256 remainingUsdc = USDC.balanceOf(address(this));
        require(remainingUsdc >= minUsdcOut, "Slippage: Burn");
        USDC.safeTransfer(user, remainingUsdc);

        // 6. Sweep Dust Bear
        // Because we added a buffer, we will have a tiny bit of Bear left.
        if (bearBalance > debtBear) {
            DXY_BEAR.safeTransfer(user, bearBalance - debtBear);
        }

        _lastSwapOut = remainingUsdc;
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of a zapMint operation.
     * @param usdcAmount The amount of USDC the user will send.
     * @return flashAmount Amount of DXY-BEAR to flash mint.
     * @return expectedSwapOut Expected USDC from selling flash-minted DXY-BEAR.
     * @return totalUSDC Total USDC for minting pairs (user + swap).
     * @return expectedTokensOut Expected DXY-BULL tokens to receive.
     * @return flashFee Flash mint fee (if any).
     */
    function previewZapMint(uint256 usdcAmount)
        external
        view
        returns (
            uint256 flashAmount,
            uint256 expectedSwapOut,
            uint256 totalUSDC,
            uint256 expectedTokensOut,
            uint256 flashFee
        )
    {
        uint256 priceBear = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, 1e18);
        if (priceBear >= CAP_PRICE) return (0, 0, 0, 0, 0);

        // Calculate Bull Price
        uint256 priceBull = CAP_PRICE - priceBear;

        // Calculate Dynamic Flash Amount
        flashAmount = (usdcAmount * 1e18) / priceBull;

        // Include buffer in preview to match execution
        if (flashAmount > 1e13) flashAmount -= 1e13;

        expectedSwapOut = (flashAmount * priceBear) / 1e18;
        totalUSDC = usdcAmount + expectedSwapOut;

        // Minting pairs: 2 USDC -> 1 Pair (assuming CAP=$2)
        // Formula: (totalUSDC * 1e18) / CAP_PRICE
        // Simplified: (totalUSDC * 1e12) / 2
        expectedTokensOut = (totalUSDC * 1e12) / 2;

        flashFee = IERC3156FlashLender(address(DXY_BEAR)).flashFee(address(DXY_BEAR), flashAmount);
    }
}

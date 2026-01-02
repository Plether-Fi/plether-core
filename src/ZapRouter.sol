// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";

/// @notice ZapRouter for acquiring DXY-BULL tokens efficiently.
/// @dev For DXY-BEAR, users should swap directly on Curve.
contract ZapRouter is IERC3156FlashBorrower {
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

    // Transient state for passing swap result from callback to main function
    uint256 private _lastSwapOut;

    // Events
    event ZapMint(
        address indexed user, uint256 usdcIn, uint256 tokensOut, uint256 maxSlippageBps, uint256 actualSwapOut
    );

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

        bytes memory data = abi.encode(msg.sender, usdcAmount, minSwapOut);

        IERC3156FlashLender(address(DXY_BEAR)).flashLoan(this, address(DXY_BEAR), flashAmount, data);

        // 6. Final Transfer
        uint256 tokensOut = DXY_BULL.balanceOf(address(this));
        require(tokensOut >= minAmountOut, "Slippage too high");
        DXY_BULL.safeTransfer(msg.sender, tokensOut);

        emit ZapMint(msg.sender, usdcAmount, tokensOut, maxSlippageBps, _lastSwapOut);
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(msg.sender == address(DXY_BEAR), "Untrusted lender");
        require(initiator == address(this), "Untrusted initiator");

        // Decode params
        (address user, uint256 userUsdcAmount, uint256 minSwapOut) = abi.decode(data, (address, uint256, uint256));

        // 1. Swap Borrowed Bear -> USDC via Curve
        uint256 swappedUsdc = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, amount, minSwapOut);
        _lastSwapOut = swappedUsdc;

        // Use balance check as source of truth (handles dust/fee-on-transfer edge cases)
        uint256 totalUsdc = USDC.balanceOf(address(this));

        // Calculate mint amount: scale USDC (6 dec) to pairs (18 dec) using CAP
        // Formula: mintAmount = totalUsdc * 1e20 / CAP (inverse of Splitter's usdcNeeded calculation)
        uint256 mintAmount = (totalUsdc * 1e20) / CAP;

        // Note: Splitter is already approved for max in constructor
        SPLITTER.mint(mintAmount);

        // 3. Repay the Flash Loan
        uint256 repayAmount = amount + fee;
        DXY_BEAR.safeIncreaseAllowance(msg.sender, repayAmount);

        // 4. Sweep Dust
        // Check if we successfully minted enough to repay (Safety Check)
        uint256 currentBalance = DXY_BEAR.balanceOf(address(this));
        require(currentBalance >= repayAmount, "Solvency Breach: Not enough Bear minted");

        if (currentBalance > repayAmount) {
            uint256 surplus = currentBalance - repayAmount;
            DXY_BEAR.safeTransfer(user, surplus);
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
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

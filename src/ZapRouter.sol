// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";

/// @notice ZapRouter for acquiring pldxy-bull (M_INV_DXY) tokens efficiently.
/// @dev For pldxy-bear (M_DXY), users should swap directly on Curve.
contract ZapRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage (caps MEV extraction)
    int128 public constant USDC_INDEX = 0; // USDC index in Curve pool
    int128 public constant MDXY_INDEX = 1; // mDXY (pldxy-bear) index in Curve pool

    // Immutable Dependencies
    ISyntheticSplitter public immutable SPLITTER;
    IERC20 public immutable M_DXY; // pldxy-bear
    IERC20 public immutable M_INV_DXY; // pldxy-bull
    IERC20 public immutable USDC;
    ICurvePool public immutable CURVE_POOL;

    // Transient state for passing swap result from callback to main function
    uint256 private _lastSwapOut;

    // Events
    event ZapMint(
        address indexed user, uint256 usdcIn, uint256 tokensOut, uint256 maxSlippageBps, uint256 actualSwapOut
    );

    constructor(address _splitter, address _mDXY, address _mInvDXY, address _usdc, address _curvePool) {
        SPLITTER = ISyntheticSplitter(_splitter);
        M_DXY = IERC20(_mDXY);
        M_INV_DXY = IERC20(_mInvDXY);
        USDC = IERC20(_usdc);
        CURVE_POOL = ICurvePool(_curvePool);

        // Pre-approve the Splitter to take our USDC
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
        // Pre-approve the Curve pool to take mDXY (for swapping)
        IERC20(_mDXY).safeIncreaseAllowance(_curvePool, type(uint256).max);
    }

    /**
     * @notice Buy pldxy-bull (M_INV_DXY) using USDC with flash mint efficiency.
     * @dev For pldxy-bear (M_DXY), swap directly on Curve instead.
     * @param usdcAmount The amount of USDC the user is sending.
     * @param minAmountOut Minimum amount of pldxy-bull tokens to receive.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 100 = 1%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function zapMint(uint256 usdcAmount, uint256 minAmountOut, uint256 maxSlippageBps, uint256 deadline) external {
        require(usdcAmount > 0, "Amount must be > 0");
        require(block.timestamp <= deadline, "Transaction expired");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");

        // 1. Pull USDC from User
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Calculate how much mDXY to Flash Mint
        // We estimate 1:1 price parity for the initial request.
        // 1 Token unit (1e18) roughly equals 1 USDC (1e6).
        // Formula: usdcAmount (6 decimals) -> 18 decimals
        uint256 flashAmount = usdcAmount * 1e12;

        // 3. Calculate minimum swap output based on user's slippage tolerance
        // Expected output at 1:1 parity is usdcAmount
        uint256 minSwapOut = (usdcAmount * (10000 - maxSlippageBps)) / 10000;

        // 4. Initiate Flash Mint of mDXY (pldxy-bear)
        // We borrow mDXY, sell it for USDC, mint pairs, keep mInvDXY, repay mDXY
        bytes memory data = abi.encode(usdcAmount, minSwapOut);

        IERC3156FlashLender(address(M_DXY)).flashLoan(this, address(M_DXY), flashAmount, data);

        // 5. Final Transfer
        // The flash loan callback handles the minting.
        // We just check if we got enough.
        uint256 tokensOut = M_INV_DXY.balanceOf(address(this));
        require(tokensOut >= minAmountOut, "Slippage too high");
        M_INV_DXY.safeTransfer(msg.sender, tokensOut);

        // 6. Emit event for off-chain tracking and MEV analysis
        emit ZapMint(msg.sender, usdcAmount, tokensOut, maxSlippageBps, _lastSwapOut);
    }

    /**
     * @dev The Callback Function called by mDXY token during flashLoan.
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        require(msg.sender == address(M_DXY), "Untrusted lender");
        require(initiator == address(this), "Untrusted initiator");

        // Decode params
        (uint256 userUsdcAmount, uint256 minSwapOut) = abi.decode(data, (uint256, uint256));

        // 1. Sell mDXY (pldxy-bear) for USDC via Curve
        uint256 swappedUsdc = CURVE_POOL.exchange(MDXY_INDEX, USDC_INDEX, amount, minSwapOut);

        // Store for event emission in main function
        _lastSwapOut = swappedUsdc;

        // 2. Mint Real Pairs from Core (userUsdcAmount + swappedUsdc)
        SPLITTER.mint(userUsdcAmount + swappedUsdc);

        // 3. Repay the Flash Loan
        uint256 repayAmount = amount + fee;
        require(M_DXY.balanceOf(address(this)) >= repayAmount, "Insolvent Zap: Swap didn't cover mint cost");
        M_DXY.safeIncreaseAllowance(msg.sender, repayAmount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of a zapMint operation.
     * @param usdcAmount The amount of USDC the user will send.
     * @return flashAmount Amount of mDXY to flash mint.
     * @return expectedSwapOut Expected USDC from selling flash-minted mDXY (at 1:1 parity).
     * @return totalUSDC Total USDC for minting pairs (user + swap).
     * @return expectedTokensOut Expected pldxy-bull tokens to receive.
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
        // Flash mint amount (USDC 6 decimals -> mDXY 18 decimals)
        flashAmount = usdcAmount * 1e12;

        // Expected USDC from swap at 1:1 parity
        expectedSwapOut = usdcAmount;

        // Total USDC for minting = user's USDC + swapped USDC
        totalUSDC = usdcAmount + expectedSwapOut;

        // Flash fee from mDXY token
        flashFee = IERC3156FlashLender(address(M_DXY)).flashFee(address(M_DXY), flashAmount);

        // Minting pairs: totalUSDC (6 decimals) -> tokens (18 decimals)
        // Each USDC mints 1e12 of each token pair
        // But we need to repay flashAmount + flashFee of mDXY
        // So user keeps: totalUSDC * 1e12 - (flashAmount + flashFee) of mDXY... wait no
        // Actually: mint gives us totalUSDC * 1e12 of EACH token
        // We repay flashAmount + flashFee of mDXY
        // User gets all the mInvDXY = totalUSDC * 1e12
        expectedTokensOut = totalUSDC * 1e12;
    }
}

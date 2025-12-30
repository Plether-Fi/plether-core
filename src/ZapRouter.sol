// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {ISyntheticSplitter} from "./interfaces/ISyntheticSplitter.sol";

contract ZapRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Immutable Dependencies
    ISyntheticSplitter public immutable SPLITTER;
    address public immutable M_DXY;
    address public immutable M_INV_DXY;
    IERC20 public immutable USDC;
    ISwapRouter public immutable SWAP_ROUTER;

    // Constants
    uint24 public constant POOL_FEE = 500; // 0.05% Uniswap Pool
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage (caps MEV extraction)

    // Transient state for passing swap result from callback to main function
    uint256 private _lastSwapOut;

    // Events
    event ZapMint(
        address indexed user,
        address indexed tokenReceived,
        uint256 usdcIn,
        uint256 tokensOut,
        uint256 maxSlippageBps,
        uint256 actualSwapOut
    );

    constructor(address _splitter, address _mDXY, address _mInvDXY, address _usdc, address _swapRouter) {
        SPLITTER = ISyntheticSplitter(_splitter);
        M_DXY = _mDXY;
        M_INV_DXY = _mInvDXY;
        USDC = IERC20(_usdc);
        SWAP_ROUTER = ISwapRouter(_swapRouter);

        // Pre-approve the Splitter to take our USDC
        USDC.safeIncreaseAllowance(_splitter, type(uint256).max);
    }

    /**
     * @notice Buy a specific synthetic token using USDC.
     * @param tokenWanted The address of the token the user wants (mDXY or mInvDXY).
     * @param usdcAmount The amount of USDC the user is sending.
     * @param minAmountOut Minimum amount of final tokens to receive (slippage protection).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 100 = 1%).
     *        Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function zapMint(
        address tokenWanted,
        uint256 usdcAmount,
        uint256 minAmountOut,
        uint256 maxSlippageBps,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "Transaction expired");
        require(tokenWanted == M_DXY || tokenWanted == M_INV_DXY, "Invalid token");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");

        // 1. Pull USDC from User
        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Identify which token we need to Flash Mint (The one we DON'T want)
        address tokenToFlash = (tokenWanted == M_DXY) ? M_INV_DXY : M_DXY;

        // 3. Calculate how much to Flash Mint
        // We estimate 1:1 price parity for the initial request.
        // 1 Pair costs 2 USDC (2e6).
        // 1 Token unit (1e18) roughly equals 1 USDC (1e6).
        // Formula: usdcAmount (6 decimals) -> 18 decimals
        uint256 flashAmount = usdcAmount * 1e12;

        // 4. Calculate minimum swap output based on user's slippage tolerance
        // Expected output at 1:1 parity is usdcAmount
        uint256 minSwapOut = (usdcAmount * (10000 - maxSlippageBps)) / 10000;

        // 5. Initiate Flash Mint
        // We borrow the UNWANTED token, sell it, and use proceeds to mint the WANTED token.
        bytes memory data = abi.encode(tokenWanted, usdcAmount, minSwapOut, deadline);

        IERC3156FlashLender(tokenToFlash).flashLoan(this, tokenToFlash, flashAmount, data);

        // 6. Final Transfer
        // The flash loan callback handles the minting.
        // We just check if we got enough.
        uint256 tokensOut = IERC20(tokenWanted).balanceOf(address(this));
        require(tokensOut >= minAmountOut, "Slippage too high");
        IERC20(tokenWanted).safeTransfer(msg.sender, tokensOut);

        // 7. Emit event for off-chain tracking and MEV analysis
        emit ZapMint(msg.sender, tokenWanted, usdcAmount, tokensOut, maxSlippageBps, _lastSwapOut);
    }

    /**
     * @dev The Callback Function called by the SyntheticToken during flashLoan.
     */
    function onFlashLoan(
        address initiator,
        address token, // This is the UNWANTED token (borrowed)
        uint256 amount, // The amount borrowed
        uint256 fee,
        bytes calldata data
    )
        external
        override
        returns (bytes32)
    {
        require(msg.sender == token, "Untrusted lender");
        require(initiator == address(this), "Untrusted initiator");

        // Decode params (includes minSwapOut for MEV protection and deadline)
        (, uint256 userUsdcAmount, uint256 minSwapOut, uint256 deadline) =
            abi.decode(data, (address, uint256, uint256, uint256));

        // 1. Sell the Borrowed Token for USDC on Uniswap
        IERC20(token).safeIncreaseAllowance(address(SWAP_ROUTER), amount);

        uint256 swappedUsdc = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(USDC),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: deadline,
                amountIn: amount,
                amountOutMinimum: minSwapOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Store for event emission in main function
        _lastSwapOut = swappedUsdc;

        // 2. Mint Real Pairs from Core (userUsdcAmount + swappedUsdc)
        SPLITTER.mint(userUsdcAmount + swappedUsdc);

        // 3. Repay the Flash Loan
        uint256 repayAmount = amount + fee;
        require(IERC20(token).balanceOf(address(this)) >= repayAmount, "Insolvent Zap: Swap didn't cover mint cost");
        IERC20(token).safeIncreaseAllowance(msg.sender, repayAmount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

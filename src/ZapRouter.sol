// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./interfaces/ISyntheticSplitter.sol";

// Uniswap V3 Router Interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract ZapRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Immutable Dependencies
    ISyntheticSplitter public immutable splitter;
    address public immutable mDXY;
    address public immutable mInvDXY;
    IERC20 public immutable usdc;
    ISwapRouter public immutable swapRouter;

    // Constants
    uint24 public constant POOL_FEE = 500; // 0.05% Uniswap Pool

    constructor(address _splitter, address _mDXY, address _mInvDXY, address _usdc, address _swapRouter) {
        splitter = ISyntheticSplitter(_splitter);
        mDXY = _mDXY;
        mInvDXY = _mInvDXY;
        usdc = IERC20(_usdc);
        swapRouter = ISwapRouter(_swapRouter);

        // Pre-approve the Splitter to take our USDC
        usdc.approve(_splitter, type(uint256).max);
    }

    /**
     * @notice Buy a specific synthetic token using USDC.
     * @param tokenWanted The address of the token the user wants (mDXY or mInvDXY).
     * @param usdcAmount The amount of USDC the user is sending.
     * @param minAmountOut Minimum amount of tokens to receive (Slippage protection).
     */
    function zapMint(address tokenWanted, uint256 usdcAmount, uint256 minAmountOut) external {
        require(tokenWanted == mDXY || tokenWanted == mInvDXY, "Invalid token");

        // 1. Pull USDC from User
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Identify which token we need to Flash Mint (The one we DON'T want)
        address tokenToFlash = (tokenWanted == mDXY) ? mInvDXY : mDXY;

        // 3. Calculate how much to Flash Mint
        // We estimate 1:1 price parity for the initial request.
        // 1 Pair costs 2 USDC (2e6).
        // 1 Token unit (1e18) roughly equals 1 USDC (1e6).
        // Formula: usdcAmount (6 decimals) -> 18 decimals
        uint256 flashAmount = usdcAmount * 1e12;

        // 4. Initiate Flash Mint
        // We borrow the UNWANTED token, sell it, and use proceeds to mint the WANTED token.
        // We pass the user's usdcAmount in the data so the callback knows how much to combine.
        bytes memory data = abi.encode(tokenWanted, usdcAmount);

        IERC3156FlashLender(tokenToFlash).flashLoan(this, tokenToFlash, flashAmount, data);

        // 5. Final Transfer
        // The flash loan callback handles the minting.
        // We just check if we got enough.
        uint256 balance = IERC20(tokenWanted).balanceOf(address(this));
        require(balance >= minAmountOut, "Slippage too high");
        IERC20(tokenWanted).safeTransfer(msg.sender, balance);
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

        // Decode params
        (, uint256 userUsdcAmount) = abi.decode(data, (address, uint256));

        // 1. Sell the Borrowed Token for USDC on Uniswap
        IERC20(token).approve(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: address(usdc),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0, // In prod, calculate this!
            sqrtPriceLimitX96: 0
        });

        uint256 swappedUsdc = swapRouter.exactInputSingle(params);

        // 2. Combine User USDC + Swapped USDC
        uint256 totalCollateral = userUsdcAmount + swappedUsdc;

        // 3. Mint Real Pairs from Core
        // This gives us 'mintedAmount' of mDXY AND 'mintedAmount' of mInvDXY
        splitter.mint(totalCollateral);

        // 4. Repay the Flash Loan
        // We now have real tokens. We use the 'unwanted' side to pay back the loan.
        // We must have at least 'amount + fee' (fee is 0).
        uint256 repayAmount = amount + fee;
        uint256 currentUnwantedBalance = IERC20(token).balanceOf(address(this));

        require(currentUnwantedBalance >= repayAmount, "Insolvent Zap: Swap didn't cover mint cost");

        // Approve repayment
        IERC20(token).approve(msg.sender, repayAmount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

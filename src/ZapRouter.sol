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
     * @param minAmountOut Minimum amount of tokens to receive (Slippage protection).
     */
    function zapMint(address tokenWanted, uint256 usdcAmount, uint256 minAmountOut) external {
        require(tokenWanted == M_DXY || tokenWanted == M_INV_DXY, "Invalid token");

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
        IERC20(token).safeIncreaseAllowance(address(SWAP_ROUTER), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: address(USDC),
            fee: POOL_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0, // In prod, calculate this!
            sqrtPriceLimitX96: 0
        });

        uint256 swappedUsdc = SWAP_ROUTER.exactInputSingle(params);

        // 2. Combine User USDC + Swapped USDC
        uint256 totalCollateral = userUsdcAmount + swappedUsdc;

        // 3. Mint Real Pairs from Core
        // This gives us 'mintedAmount' of mDXY AND 'mintedAmount' of mInvDXY
        SPLITTER.mint(totalCollateral);

        // 4. Repay the Flash Loan
        // We now have real tokens. We use the 'unwanted' side to pay back the loan.
        // We must have at least 'amount + fee' (fee is 0).
        uint256 repayAmount = amount + fee;
        uint256 currentUnwantedBalance = IERC20(token).balanceOf(address(this));

        require(currentUnwantedBalance >= repayAmount, "Insolvent Zap: Swap didn't cover mint cost");

        // Approve repayment
        IERC20(token).safeIncreaseAllowance(msg.sender, repayAmount);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

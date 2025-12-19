// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

// Morpho Blue Interface (Minimal)
interface IMorpho {
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata data
    ) external returns (uint256 assetsDeposited, uint256 sharesIssued);

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesIssued);
}

// Uniswap Interface
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

// Morpho Structs
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm; // Interest Rate Model
    uint256 lltv; // Liquidation LTV
}

contract LeverageRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Dependencies
    IMorpho public immutable morpho;
    ISwapRouter public immutable swapRouter;
    IERC20 public immutable usdc;
    IERC20 public immutable mDXY;
    IERC3156FlashLender public immutable lender; // e.g., Aave or Balancer

    // Morpho Market ID Configuration
    MarketParams public marketParams;

    constructor(
        address _morpho,
        address _swapRouter,
        address _usdc,
        address _mDXY,
        address _lender,
        MarketParams memory _marketParams
    ) {
        morpho = IMorpho(_morpho);
        swapRouter = ISwapRouter(_swapRouter);
        usdc = IERC20(_usdc);
        mDXY = IERC20(_mDXY);
        lender = IERC3156FlashLender(_lender);
        marketParams = _marketParams;

        // Approvals (One-time)
        // 1. Allow SwapRouter to take USDC
        usdc.approve(_swapRouter, type(uint256).max);
        // 2. Allow Morpho to take mDXY
        mDXY.approve(_morpho, type(uint256).max);
        // 3. Allow Lender to take back USDC (Repayment)
        usdc.approve(_lender, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged Position in one transaction.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param minMDXY Minimum mDXY received from swap (Slippage).
     */
    function openLeverage(uint256 principal, uint256 leverage, uint256 minMDXY) external {
        require(leverage > 1e18, "Leverage must be > 1x");

        // 1. Pull User Funds
        usdc.safeTransferFrom(msg.sender, address(this), principal);

        // 2. Calculate Flash Loan Amount
        // If User has $1000 and wants 3x ($3000 exposure):
        // We need to buy $3000 worth of mDXY.
        // We have $1000. We need to borrow $2000.
        // Formula: Loan = Principal * (Lev - 1)
        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;

        // 3. Encode data for callback
        bytes memory data = abi.encode(principal, minMDXY, msg.sender);

        // 4. Initiate Flash Loan (Get the extra USDC)
        // NOTE: We are flash loaning USDC, not mDXY
        lender.flashLoan(this, address(usdc), loanAmount, data);
    }

    /**
     * @dev Callback: We now have Principal + Loan in USDC.
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount, // Loan Amount
        uint256 fee,
        bytes calldata data
    )
        external
        override
        returns (bytes32)
    {
        require(msg.sender == address(lender), "Untrusted lender");
        require(initiator == address(this), "Untrusted initiator");

        (uint256 principal, uint256 minMDXY, address user) = abi.decode(data, (uint256, uint256, address));

        // 1. Total Capital = User Principal + Flash Loan
        uint256 totalUSDC = principal + amount;

        // 2. Swap ALL USDC -> mDXY
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(mDXY),
            fee: 500, // 0.05% Pool
            recipient: address(this), // Keep mDXY here to supply to Morpho
            deadline: block.timestamp,
            amountIn: totalUSDC,
            amountOutMinimum: minMDXY,
            sqrtPriceLimitX96: 0
        });

        uint256 mDXYReceived = swapRouter.exactInputSingle(params);

        // 3. Supply mDXY to Morpho on behalf of the USER
        // Note: User must have called `morpho.setAuthorization(address(this), true)` beforehand!
        morpho.supply(
            marketParams,
            mDXYReceived,
            0,
            user, // The position belongs to the User directly
            ""
        );

        // 4. Borrow USDC from Morpho on behalf of the USER
        // We borrow exactly enough to pay back the flash loan (+ fee)
        uint256 debtToIncur = amount + fee;

        morpho.borrow(
            marketParams,
            debtToIncur,
            0,
            user, // Debt is assigned to User
            address(this) // Money comes to Router to pay Flash Loan
        );

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

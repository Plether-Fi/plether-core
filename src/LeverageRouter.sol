// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

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
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
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

    // Operation types for flash loan callback
    uint8 private constant OP_OPEN = 1;
    uint8 private constant OP_CLOSE = 2;

    // Events
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 mDXYReceived,
        uint256 debtIncurred
    );

    event LeverageClosed(address indexed user, uint256 debtRepaid, uint256 collateralWithdrawn, uint256 usdcReturned);

    // Transient state for passing values from callback to main function
    uint256 private _lastMDXYReceived;
    uint256 private _lastDebtIncurred;
    uint256 private _lastCollateralWithdrawn;
    uint256 private _lastUsdcReturned;

    // Dependencies
    IMorpho public immutable MORPHO;
    ISwapRouter public immutable SWAP_ROUTER;
    IERC20 public immutable USDC;
    IERC20 public immutable M_DXY;
    IERC3156FlashLender public immutable LENDER; // e.g., Aave or Balancer
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
        MORPHO = IMorpho(_morpho);
        SWAP_ROUTER = ISwapRouter(_swapRouter);
        USDC = IERC20(_usdc);
        M_DXY = IERC20(_mDXY);
        LENDER = IERC3156FlashLender(_lender);
        marketParams = _marketParams;
        // Approvals (One-time)
        // 1. Allow SwapRouter to take USDC (for opening)
        USDC.safeIncreaseAllowance(_swapRouter, type(uint256).max);
        // 2. Allow SwapRouter to take mDXY (for closing)
        M_DXY.safeIncreaseAllowance(_swapRouter, type(uint256).max);
        // 3. Allow Morpho to take mDXY (for supplying collateral)
        M_DXY.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 4. Allow Morpho to take USDC (for repaying debt)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 5. Allow Lender to take back USDC (Flash Loan Repayment)
        USDC.safeIncreaseAllowance(_lender, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged Position in one transaction.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param minMDXY Minimum mDXY received from swap (Slippage).
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function openLeverage(uint256 principal, uint256 leverage, uint256 minMDXY, uint256 deadline) external {
        require(block.timestamp <= deadline, "Transaction expired");
        require(leverage > 1e18, "Leverage must be > 1x");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "LeverageRouter not authorized in Morpho");
        // 1. Pull User Funds
        USDC.safeTransferFrom(msg.sender, address(this), principal);
        // 2. Calculate Flash Loan Amount
        // If User has $1000 and wants 3x ($3000 exposure):
        // We need to buy $3000 worth of mDXY.
        // We have $1000. We need to borrow $2000.
        // Formula: Loan = Principal * (Lev - 1)
        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;
        // 3. Encode data for callback (operation type, user, deadline, and operation-specific data)
        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, minMDXY);
        // 4. Initiate Flash Loan (Get the extra USDC)
        // NOTE: We are flash loaning USDC, not mDXY
        LENDER.flashLoan(this, address(USDC), loanAmount, data);

        // 5. Emit event for off-chain tracking and MEV analysis
        emit LeverageOpened(msg.sender, principal, leverage, loanAmount, _lastMDXYReceived, _lastDebtIncurred);
    }

    /**
     * @notice Close a Leveraged Position in one transaction.
     * @param debtToRepay Amount of USDC debt to repay (flash loaned).
     * @param collateralToWithdraw Amount of mDXY collateral to withdraw (0 for max).
     * @param minUsdcOut Minimum USDC to receive after swap (Slippage).
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(uint256 debtToRepay, uint256 collateralToWithdraw, uint256 minUsdcOut, uint256 deadline)
        external
    {
        require(block.timestamp <= deadline, "Transaction expired");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "LeverageRouter not authorized in Morpho");

        // 1. Encode data for callback (operation type, user, deadline, and operation-specific data)
        bytes memory data = abi.encode(OP_CLOSE, msg.sender, deadline, collateralToWithdraw, minUsdcOut);

        // 2. Flash loan USDC to repay the debt
        LENDER.flashLoan(this, address(USDC), debtToRepay, data);

        // 3. Emit event for off-chain tracking
        emit LeverageClosed(msg.sender, debtToRepay, _lastCollateralWithdrawn, _lastUsdcReturned);
    }

    /**
     * @dev Callback: Handles both open and close operations.
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
        require(msg.sender == address(LENDER), "Untrusted lender");
        require(initiator == address(this), "Untrusted initiator");

        // Decode common fields
        (uint8 operation, address user, uint256 deadline) = abi.decode(data, (uint8, address, uint256));

        if (operation == OP_OPEN) {
            _executeOpen(amount, fee, user, deadline, data);
        } else if (operation == OP_CLOSE) {
            _executeClose(amount, fee, user, deadline, data);
        } else {
            revert("Invalid operation");
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /**
     * @dev Execute open leverage operation in flash loan callback.
     */
    function _executeOpen(uint256 loanAmount, uint256 fee, address user, uint256 deadline, bytes calldata data)
        private
    {
        // Decode open-specific data: (op, user, deadline, principal, minMDXY)
        (,,, uint256 principal, uint256 minMDXY) = abi.decode(data, (uint8, address, uint256, uint256, uint256));

        // 1. Total Capital = User Principal + Flash Loan
        uint256 totalUSDC = principal + loanAmount;

        // 2. Swap ALL USDC -> mDXY
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(M_DXY),
            fee: 500, // 0.05% Pool
            recipient: address(this),
            deadline: deadline,
            amountIn: totalUSDC,
            amountOutMinimum: minMDXY,
            sqrtPriceLimitX96: 0
        });
        uint256 mDXYReceived = SWAP_ROUTER.exactInputSingle(params);
        _lastMDXYReceived = mDXYReceived;

        // 3. Supply mDXY to Morpho on behalf of the USER
        MORPHO.supply(marketParams, mDXYReceived, 0, user, "");

        // 4. Borrow USDC from Morpho to repay flash loan
        uint256 debtToIncur = loanAmount + fee;
        _lastDebtIncurred = debtToIncur;
        MORPHO.borrow(marketParams, debtToIncur, 0, user, address(this));
    }

    /**
     * @dev Execute close leverage operation in flash loan callback.
     */
    function _executeClose(uint256 loanAmount, uint256 fee, address user, uint256 deadline, bytes calldata data)
        private
    {
        // Decode close-specific data: (op, user, deadline, collateralToWithdraw, minUsdcOut)
        (,,, uint256 collateralToWithdraw, uint256 minUsdcOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        // 1. Repay user's debt on Morpho
        MORPHO.repay(marketParams, loanAmount, 0, user, "");

        // 2. Withdraw user's collateral from Morpho
        (uint256 withdrawnAssets,) = MORPHO.withdraw(marketParams, collateralToWithdraw, 0, user, address(this));
        _lastCollateralWithdrawn = withdrawnAssets;

        // 3. Swap mDXY -> USDC
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(M_DXY),
            tokenOut: address(USDC),
            fee: 500, // 0.05% Pool
            recipient: address(this),
            deadline: deadline,
            amountIn: withdrawnAssets,
            amountOutMinimum: minUsdcOut,
            sqrtPriceLimitX96: 0
        });
        uint256 usdcReceived = SWAP_ROUTER.exactInputSingle(params);

        // 4. Repay flash loan (loanAmount + fee)
        uint256 flashRepayment = loanAmount + fee;
        require(usdcReceived >= flashRepayment, "Insufficient USDC from swap");

        // 5. Send remaining USDC to user
        uint256 usdcToReturn = usdcReceived - flashRepayment;
        _lastUsdcReturned = usdcToReturn;
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }
    }
}

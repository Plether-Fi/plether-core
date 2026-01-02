// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {IMorpho, MarketParams} from "./interfaces/IMorpho.sol";

contract LeverageRouter is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant MAX_SLIPPAGE_BPS = 100; // 1% maximum slippage (caps MEV extraction)
    int128 public constant USDC_INDEX = 0; // USDC index in Curve pool
    int128 public constant DXY_BEAR_INDEX = 1; // DXY-BEAR index in Curve pool

    // Operation types for flash loan callback
    uint8 private constant OP_OPEN = 1;
    uint8 private constant OP_CLOSE = 2;

    // Events
    event LeverageOpened(
        address indexed user,
        uint256 principal,
        uint256 leverage,
        uint256 loanAmount,
        uint256 dxyBearReceived,
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

    // Transient state for passing values from callback to main function
    uint256 private _lastDxyBearReceived;
    uint256 private _lastDebtIncurred;
    uint256 private _lastCollateralWithdrawn;
    uint256 private _lastUsdcReturned;

    // Dependencies
    IMorpho public immutable MORPHO;
    ICurvePool public immutable CURVE_POOL;
    IERC20 public immutable USDC;
    IERC20 public immutable DXY_BEAR; // Underlying token
    IERC4626 public immutable STAKED_DXY_BEAR; // Staked token (Morpho collateral)
    IERC3156FlashLender public immutable LENDER; // e.g., Aave or Balancer
    // Morpho Market ID Configuration
    MarketParams public marketParams;

    constructor(
        address _morpho,
        address _curvePool,
        address _usdc,
        address _dxyBear,
        address _stakedDxyBear,
        address _lender,
        MarketParams memory _marketParams
    ) {
        MORPHO = IMorpho(_morpho);
        CURVE_POOL = ICurvePool(_curvePool);
        USDC = IERC20(_usdc);
        DXY_BEAR = IERC20(_dxyBear);
        STAKED_DXY_BEAR = IERC4626(_stakedDxyBear);
        LENDER = IERC3156FlashLender(_lender);
        marketParams = _marketParams;

        // Approvals (One-time)
        // 1. Allow Curve pool to take USDC (for opening)
        USDC.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 2. Allow Curve pool to take DXY-BEAR (for closing)
        DXY_BEAR.safeIncreaseAllowance(_curvePool, type(uint256).max);
        // 3. Allow StakedToken to take DXY-BEAR (for staking)
        DXY_BEAR.safeIncreaseAllowance(_stakedDxyBear, type(uint256).max);
        // 4. Allow Morpho to take sDXY-BEAR (for supplying collateral)
        IERC20(_stakedDxyBear).safeIncreaseAllowance(_morpho, type(uint256).max);
        // 5. Allow Morpho to take USDC (for repaying debt)
        USDC.safeIncreaseAllowance(_morpho, type(uint256).max);
        // 6. Allow Lender to take back USDC (Flash Loan Repayment)
        USDC.safeIncreaseAllowance(_lender, type(uint256).max);
    }

    /**
     * @notice Open a Leveraged Position in one transaction.
     * @param principal Amount of USDC user sends.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function openLeverage(uint256 principal, uint256 leverage, uint256 maxSlippageBps, uint256 deadline) external {
        require(principal > 0, "Principal must be > 0");
        require(block.timestamp <= deadline, "Transaction expired");
        require(leverage > 1e18, "Leverage must be > 1x");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "LeverageRouter not authorized in Morpho");

        // 1. Calculate Flash Loan Amount
        // If User has $1000 and wants 3x ($3000 exposure):
        // We need to buy $3000 worth of DXY-BEAR.
        // We have $1000. We need to borrow $2000.
        // Formula: Loan = Principal * (Lev - 1)
        uint256 loanAmount = (principal * (leverage - 1e18)) / 1e18;
        require(loanAmount > 0, "Leverage too low for principal");

        // 2. Pull User Funds
        USDC.safeTransferFrom(msg.sender, address(this), principal);

        // 3. Calculate minimum DXY-BEAR output based on REAL MARKET PRICE
        // Use get_dy to find real market expectation, NOT 1:1 assumption
        uint256 totalUSDC = principal + loanAmount;
        uint256 expectedDxyBear = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC);

        uint256 minDxyBear = (expectedDxyBear * (10000 - maxSlippageBps)) / 10000;

        // 4. Encode data for callback (operation type, user, deadline, and operation-specific data)
        bytes memory data = abi.encode(OP_OPEN, msg.sender, deadline, principal, minDxyBear);

        // 5. Initiate Flash Loan (Get the extra USDC)
        // NOTE: We are flash loaning USDC, not DXY-BEAR
        LENDER.flashLoan(this, address(USDC), loanAmount, data);

        // 6. Emit event for off-chain tracking and MEV analysis
        emit LeverageOpened(
            msg.sender, principal, leverage, loanAmount, _lastDxyBearReceived, _lastDebtIncurred, maxSlippageBps
        );
    }

    /**
     * @notice Close a Leveraged Position in one transaction.
     * @param debtToRepay Amount of USDC debt to repay (flash loaned).
     * @param collateralToWithdraw Amount of DXY-BEAR collateral to withdraw.
     * @param maxSlippageBps Maximum slippage tolerance in basis points (e.g., 50 = 0.5%).
     * Capped at MAX_SLIPPAGE_BPS (1%) to limit MEV extraction.
     * @param deadline Unix timestamp after which the transaction reverts.
     */
    function closeLeverage(uint256 debtToRepay, uint256 collateralToWithdraw, uint256 maxSlippageBps, uint256 deadline)
        external
    {
        require(block.timestamp <= deadline, "Transaction expired");
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, "Slippage exceeds maximum");
        require(MORPHO.isAuthorized(msg.sender, address(this)), "LeverageRouter not authorized in Morpho");

        // 1. Calculate minimum USDC output based on REAL MARKET PRICE
        // Use get_dy to find real market expectation
        uint256 expectedUSDC = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, collateralToWithdraw);
        uint256 minUsdcOut = (expectedUSDC * (10000 - maxSlippageBps)) / 10000;

        // 2. Encode data for callback (operation type, user, deadline, and operation-specific data)
        bytes memory data = abi.encode(OP_CLOSE, msg.sender, deadline, collateralToWithdraw, minUsdcOut);

        // 3. Flash loan USDC to repay the debt
        LENDER.flashLoan(this, address(USDC), debtToRepay, data);

        // 4. Emit event for off-chain tracking and MEV analysis
        emit LeverageClosed(msg.sender, debtToRepay, _lastCollateralWithdrawn, _lastUsdcReturned, maxSlippageBps);
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

        // Decode common fields and validate deadline
        (uint8 operation, address user, uint256 deadline) = abi.decode(data, (uint8, address, uint256));
        require(block.timestamp <= deadline, "Transaction expired");

        if (operation == OP_OPEN) {
            _executeOpen(amount, fee, user, data);
        } else if (operation == OP_CLOSE) {
            _executeClose(amount, fee, user, data);
        } else {
            revert("Invalid operation");
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /**
     * @dev Execute open leverage operation in flash loan callback.
     */
    function _executeOpen(uint256 loanAmount, uint256 fee, address user, bytes calldata data) private {
        // Decode open-specific data: (op, user, deadline, principal, minDxyBear)
        (,,, uint256 principal, uint256 minDxyBear) = abi.decode(data, (uint8, address, uint256, uint256, uint256));

        uint256 totalUSDC = principal + loanAmount;

        // 1. Swap ALL USDC -> DXY-BEAR via Curve
        uint256 dxyBearReceived = CURVE_POOL.exchange(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC, minDxyBear);
        _lastDxyBearReceived = dxyBearReceived;

        // 2. Stake DXY-BEAR to get sDXY-BEAR
        uint256 stakedShares = STAKED_DXY_BEAR.deposit(dxyBearReceived, address(this));

        // 3. Supply sDXY-BEAR to Morpho on behalf of the USER
        MORPHO.supply(marketParams, stakedShares, 0, user, "");

        // 4. Borrow USDC from Morpho to repay flash loan
        uint256 debtToIncur = loanAmount + fee;
        _lastDebtIncurred = debtToIncur;
        MORPHO.borrow(marketParams, debtToIncur, 0, user, address(this));
    }

    /**
     * @dev Execute close leverage operation in flash loan callback.
     */
    function _executeClose(uint256 loanAmount, uint256 fee, address user, bytes calldata data) private {
        // Decode close-specific data: (op, user, deadline, collateralToWithdraw, minUsdcOut)
        (,,, uint256 collateralToWithdraw, uint256 minUsdcOut) =
            abi.decode(data, (uint8, address, uint256, uint256, uint256));

        // 1. Repay user's debt on Morpho
        MORPHO.repay(marketParams, loanAmount, 0, user, "");

        // 2. Withdraw user's sDXY-BEAR collateral from Morpho
        (uint256 withdrawnShares,) = MORPHO.withdraw(marketParams, collateralToWithdraw, 0, user, address(this));
        _lastCollateralWithdrawn = withdrawnShares;

        // 3. Unstake sDXY-BEAR to get DXY-BEAR
        uint256 dxyBearReceived = STAKED_DXY_BEAR.redeem(withdrawnShares, address(this), address(this));

        // 4. Swap DXY-BEAR -> USDC via Curve
        uint256 usdcReceived = CURVE_POOL.exchange(DXY_BEAR_INDEX, USDC_INDEX, dxyBearReceived, minUsdcOut);

        // 5. Repay flash loan (loanAmount + fee)
        uint256 flashRepayment = loanAmount + fee;
        require(usdcReceived >= flashRepayment, "Insufficient USDC from swap");

        // 6. Send remaining USDC to user
        uint256 usdcToReturn = usdcReceived - flashRepayment;
        _lastUsdcReturned = usdcToReturn;
        if (usdcToReturn > 0) {
            USDC.safeTransfer(user, usdcToReturn);
        }
    }

    // ==========================================
    // VIEW FUNCTIONS (for frontend)
    // ==========================================

    /**
     * @notice Preview the result of opening a leveraged position.
     * @param principal Amount of USDC user will send.
     * @param leverage Multiplier (e.g. 3x = 3e18).
     * @return loanAmount Amount of USDC to flash loan.
     * @return totalUSDC Total USDC to swap (principal + loan).
     * @return expectedDxyBear Expected DXY-BEAR (based on current curve price).
     * @return expectedDebt Expected debt incurred (loan + flash fee).
     */
    function previewOpenLeverage(uint256 principal, uint256 leverage)
        external
        view
        returns (uint256 loanAmount, uint256 totalUSDC, uint256 expectedDxyBear, uint256 expectedDebt)
    {
        require(leverage > 1e18, "Leverage must be > 1x");

        loanAmount = (principal * (leverage - 1e18)) / 1e18;
        totalUSDC = principal + loanAmount;

        // Use get_dy for accurate preview
        expectedDxyBear = CURVE_POOL.get_dy(USDC_INDEX, DXY_BEAR_INDEX, totalUSDC);

        uint256 flashFee = LENDER.flashFee(address(USDC), loanAmount);
        expectedDebt = loanAmount + flashFee;
    }

    /**
     * @notice Preview the result of closing a leveraged position.
     * @param debtToRepay Amount of USDC debt to repay.
     * @param collateralToWithdraw Amount of DXY-BEAR collateral to withdraw.
     * @return expectedUSDC Expected USDC from swap (based on current curve price).
     * @return flashFee Flash loan fee.
     * @return expectedReturn Expected USDC returned to user after repaying flash loan.
     */
    function previewCloseLeverage(uint256 debtToRepay, uint256 collateralToWithdraw)
        external
        view
        returns (uint256 expectedUSDC, uint256 flashFee, uint256 expectedReturn)
    {
        // Use get_dy for accurate preview
        expectedUSDC = CURVE_POOL.get_dy(DXY_BEAR_INDEX, USDC_INDEX, collateralToWithdraw);

        flashFee = LENDER.flashFee(address(USDC), debtToRepay);
        uint256 totalRepayment = debtToRepay + flashFee;
        expectedReturn = expectedUSDC > totalRepayment ? expectedUSDC - totalRepayment : 0;
    }
}

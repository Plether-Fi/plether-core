// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./ICfdEngine.sol";
import {ICfdVault} from "./ICfdVault.sol";
import {IHousePool} from "./IHousePool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HousePool
/// @notice Tranched house pool. Senior tranche gets fixed-rate yield with last-loss protection.
///         Junior tranche absorbs first loss but captures surplus revenue.
contract HousePool is ICfdVault, IHousePool, Ownable2Step {

    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    ICfdEngine public immutable engine;

    address public orderRouter;
    address public seniorVault;
    address public juniorVault;

    uint256 public seniorPrincipal;
    uint256 public juniorPrincipal;

    uint256 public lastReconcileTime;
    uint256 public seniorRateBps;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);

    modifier onlyVault() {
        require(msg.sender == seniorVault || msg.sender == juniorVault, "HousePool: Not a vault");
        _;
    }

    constructor(
        address _usdc,
        address _engine
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        engine = ICfdEngine(_engine);
        lastReconcileTime = block.timestamp;
        seniorRateBps = 800; // 8% APY default
    }

    // ==========================================
    // ADMIN (set-once pattern)
    // ==========================================

    function setOrderRouter(
        address _router
    ) external onlyOwner {
        require(orderRouter == address(0), "HousePool: Router already set");
        orderRouter = _router;
    }

    function setSeniorVault(
        address _vault
    ) external onlyOwner {
        require(seniorVault == address(0), "HousePool: Senior vault already set");
        seniorVault = _vault;
    }

    function setJuniorVault(
        address _vault
    ) external onlyOwner {
        require(juniorVault == address(0), "HousePool: Junior vault already set");
        juniorVault = _vault;
    }

    function setSeniorRate(
        uint256 _rateBps
    ) external onlyOwner {
        _reconcile();
        seniorRateBps = _rateBps;
        emit SeniorRateUpdated(_rateBps);
    }

    // ==========================================
    // ICfdVault INTERFACE
    // ==========================================

    /// @notice Total USDC held by the pool, backing all open positions
    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Transfers USDC from the pool. Callable by CfdEngine (PnL/funding) or OrderRouter (keeper bounties).
    function payOut(
        address recipient,
        uint256 amount
    ) external {
        require(msg.sender == address(engine) || msg.sender == orderRouter, "HousePool: Unauthorized");
        usdc.safeTransfer(recipient, amount);
    }

    // ==========================================
    // TRANCHE DEPOSITS & WITHDRAWALS
    // ==========================================

    function depositSenior(
        uint256 amount
    ) external onlyVault {
        _reconcile();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        seniorPrincipal += amount;
    }

    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _reconcile();
        require(amount <= getMaxSeniorWithdraw(), "HousePool: Exceeds max senior withdraw");
        seniorPrincipal -= amount;
        usdc.safeTransfer(receiver, amount);
    }

    function depositJunior(
        uint256 amount
    ) external onlyVault {
        _reconcile();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        juniorPrincipal += amount;
    }

    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _reconcile();
        require(amount <= getMaxJuniorWithdraw(), "HousePool: Exceeds max junior withdraw");
        juniorPrincipal -= amount;
        usdc.safeTransfer(receiver, amount);
    }

    // ==========================================
    // WITHDRAWAL LIMITS
    // ==========================================

    /// @notice Returns USDC not reserved for worst-case position payouts (max of bull/bear liability)
    function getFreeUSDC() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 bullMax = engine.globalBullMaxProfit();
        uint256 bearMax = engine.globalBearMaxProfit();
        uint256 maxLiability = bullMax > bearMax ? bullMax : bearMax;
        return bal > maxLiability ? bal - maxLiability : 0;
    }

    /// @notice Max USDC the senior tranche can withdraw (limited by free USDC)
    function getMaxSeniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        return free < seniorPrincipal ? free : seniorPrincipal;
    }

    /// @notice Max USDC the junior tranche can withdraw (subordinated behind senior)
    function getMaxJuniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        uint256 subordinated = free > seniorPrincipal ? free - seniorPrincipal : 0;
        return subordinated < juniorPrincipal ? subordinated : juniorPrincipal;
    }

    // ==========================================
    // RECONCILIATION (Revenue & Loss Waterfall)
    // ==========================================

    /// @notice Distributes revenue (senior yield first, junior gets surplus) or absorbs losses
    ///         (junior first-loss, senior last-loss). Called before any deposit/withdrawal.
    function reconcile() external {
        _reconcile();
    }

    function _reconcile() internal {
        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (claimedEquity == 0) {
            lastReconcileTime = block.timestamp;
            return;
        }

        uint256 bal = usdc.balanceOf(address(this));
        uint256 pendingFees = engine.accumulatedFeesUsdc();
        uint256 distributable = bal > pendingFees ? bal - pendingFees : 0;

        if (distributable > claimedEquity) {
            _distributeRevenue(distributable - claimedEquity);
        } else if (distributable < claimedEquity) {
            _absorbLoss(claimedEquity - distributable);
        }

        lastReconcileTime = block.timestamp;
    }

    function _distributeRevenue(
        uint256 revenue
    ) internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;
        uint256 seniorYield = (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);

        if (seniorYield > revenue) {
            seniorYield = revenue;
        }

        seniorPrincipal += seniorYield;

        uint256 juniorSurplus = revenue - seniorYield;
        juniorPrincipal += juniorSurplus;

        emit Reconciled(seniorPrincipal, juniorPrincipal, int256(revenue));
    }

    function _absorbLoss(
        uint256 loss
    ) internal {
        if (loss <= juniorPrincipal) {
            juniorPrincipal -= loss;
        } else {
            uint256 seniorLoss = loss - juniorPrincipal;
            juniorPrincipal = 0;
            seniorPrincipal = seniorPrincipal > seniorLoss ? seniorPrincipal - seniorLoss : 0;
        }

        emit Reconciled(seniorPrincipal, juniorPrincipal, -int256(loss));
    }

}

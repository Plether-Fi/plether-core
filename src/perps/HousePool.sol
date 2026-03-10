// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title HousePool
/// @notice Tranched house pool. Senior tranche gets fixed-rate yield with last-loss protection.
///         Junior tranche absorbs first loss but captures surplus revenue.
/// @custom:security-contact contact@plether.com
contract HousePool is ICfdVault, IHousePool, Ownable2Step, Pausable {

    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    ICfdEngine public immutable ENGINE;

    address public orderRouter;
    address public seniorVault;
    address public juniorVault;

    uint256 public seniorPrincipal;
    uint256 public juniorPrincipal;
    uint256 public unpaidSeniorYield;
    uint256 public seniorHighWaterMark;

    uint256 public lastReconcileTime;
    uint256 public seniorRateBps;
    uint256 public markStalenessLimit = 120;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    uint256 public pendingSeniorRate;
    uint256 public seniorRateActivationTime;

    uint256 public pendingMarkStalenessLimit;
    uint256 public markStalenessLimitActivationTime;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    error HousePool__NotAVault();
    error HousePool__RouterAlreadySet();
    error HousePool__SeniorVaultAlreadySet();
    error HousePool__JuniorVaultAlreadySet();
    error HousePool__Unauthorized();
    error HousePool__ExceedsMaxSeniorWithdraw();
    error HousePool__ExceedsMaxJuniorWithdraw();
    error HousePool__MarkPriceStale();
    error HousePool__TimelockNotReady();
    error HousePool__NoProposal();

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);
    event MarkStalenessLimitUpdated(uint256 newLimit);
    event SeniorRateProposed(uint256 newRateBps, uint256 activationTime);
    event SeniorRateFinalized();
    event MarkStalenessLimitProposed(uint256 newLimit, uint256 activationTime);
    event MarkStalenessLimitFinalized();

    modifier onlyVault() {
        if (msg.sender != seniorVault && msg.sender != juniorVault) {
            revert HousePool__NotAVault();
        }
        _;
    }

    constructor(
        address _usdc,
        address _engine
    ) Ownable(msg.sender) {
        USDC = IERC20(_usdc);
        ENGINE = ICfdEngine(_engine);
        lastReconcileTime = block.timestamp;
        seniorRateBps = 800; // 8% APY default
    }

    // ==========================================
    // ADMIN (set-once pattern)
    // ==========================================

    function setOrderRouter(
        address _router
    ) external onlyOwner {
        if (orderRouter != address(0)) {
            revert HousePool__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    function setSeniorVault(
        address _vault
    ) external onlyOwner {
        if (seniorVault != address(0)) {
            revert HousePool__SeniorVaultAlreadySet();
        }
        seniorVault = _vault;
    }

    function setJuniorVault(
        address _vault
    ) external onlyOwner {
        if (juniorVault != address(0)) {
            revert HousePool__JuniorVaultAlreadySet();
        }
        juniorVault = _vault;
    }

    function proposeSeniorRate(
        uint256 _rateBps
    ) external onlyOwner {
        pendingSeniorRate = _rateBps;
        seniorRateActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit SeniorRateProposed(_rateBps, seniorRateActivationTime);
    }

    function finalizeSeniorRate() external onlyOwner {
        if (seniorRateActivationTime == 0) {
            revert HousePool__NoProposal();
        }
        if (block.timestamp < seniorRateActivationTime) {
            revert HousePool__TimelockNotReady();
        }
        _reconcile();
        seniorRateBps = pendingSeniorRate;
        pendingSeniorRate = 0;
        seniorRateActivationTime = 0;
        emit SeniorRateUpdated(seniorRateBps);
        emit SeniorRateFinalized();
    }

    function cancelSeniorRateProposal() external onlyOwner {
        pendingSeniorRate = 0;
        seniorRateActivationTime = 0;
    }

    function proposeMarkStalenessLimit(
        uint256 _limit
    ) external onlyOwner {
        pendingMarkStalenessLimit = _limit;
        markStalenessLimitActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit MarkStalenessLimitProposed(_limit, markStalenessLimitActivationTime);
    }

    function finalizeMarkStalenessLimit() external onlyOwner {
        if (markStalenessLimitActivationTime == 0) {
            revert HousePool__NoProposal();
        }
        if (block.timestamp < markStalenessLimitActivationTime) {
            revert HousePool__TimelockNotReady();
        }
        markStalenessLimit = pendingMarkStalenessLimit;
        pendingMarkStalenessLimit = 0;
        markStalenessLimitActivationTime = 0;
        emit MarkStalenessLimitUpdated(markStalenessLimit);
        emit MarkStalenessLimitFinalized();
    }

    function cancelMarkStalenessLimitProposal() external onlyOwner {
        pendingMarkStalenessLimit = 0;
        markStalenessLimitActivationTime = 0;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ==========================================
    // ICfdVault INTERFACE
    // ==========================================

    /// @notice Total USDC held by the pool, backing all open positions
    function totalAssets() external view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Transfers USDC from the pool. Callable by CfdEngine (PnL/funding) or OrderRouter (keeper bounties).
    function payOut(
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != orderRouter) {
            revert HousePool__Unauthorized();
        }
        USDC.safeTransfer(recipient, amount);
    }

    // ==========================================
    // TRANCHE DEPOSITS & WITHDRAWALS
    // ==========================================

    function depositSenior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        _reconcile();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        if (seniorPrincipal > 0) {
            seniorHighWaterMark = (seniorHighWaterMark * (seniorPrincipal + amount)) / seniorPrincipal;
        } else {
            seniorHighWaterMark += amount;
        }
        seniorPrincipal += amount;
    }

    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        if (amount == 0) {
            return;
        }
        _reconcile();
        if (amount > getMaxSeniorWithdraw()) {
            revert HousePool__ExceedsMaxSeniorWithdraw();
        }
        seniorHighWaterMark = seniorHighWaterMark * (seniorPrincipal - amount) / seniorPrincipal;
        seniorPrincipal -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    function depositJunior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        _reconcile();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        juniorPrincipal += amount;
    }

    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _reconcile();
        if (amount > getMaxJuniorWithdraw()) {
            revert HousePool__ExceedsMaxJuniorWithdraw();
        }
        juniorPrincipal -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    // ==========================================
    // WITHDRAWAL LIMITS
    // ==========================================

    /// @notice Returns USDC not reserved for worst-case position payouts (max of bull/bear liability)
    function getFreeUSDC() public view returns (uint256) {
        uint256 bal = USDC.balanceOf(address(this));
        uint256 bullMax = ENGINE.globalBullMaxProfit();
        uint256 bearMax = ENGINE.globalBearMaxProfit();
        uint256 maxLiability = bullMax > bearMax ? bullMax : bearMax;
        uint256 pendingFees = ENGINE.accumulatedFeesUsdc();
        uint256 reserved = maxLiability + pendingFees;
        int256 unrealizedFunding = ENGINE.getUnrealizedFundingPnl();
        if (unrealizedFunding > 0) {
            reserved += uint256(unrealizedFunding);
        }
        return bal > reserved ? bal - reserved : 0;
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
    function reconcile() external onlyVault {
        _reconcile();
    }

    function _reconcile() internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;
        lastReconcileTime = block.timestamp;

        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (claimedEquity == 0) {
            return;
        }

        if (elapsed > 0 && seniorPrincipal > 0) {
            uint256 yieldInc = (seniorPrincipal * seniorRateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
            unpaidSeniorYield += yieldInc;
        }

        uint256 bullMax = ENGINE.globalBullMaxProfit();
        uint256 bearMax = ENGINE.globalBearMaxProfit();
        if (bullMax + bearMax > 0) {
            if (block.timestamp - ENGINE.lastMarkTime() > markStalenessLimit) {
                return;
            }
        }

        uint256 bal = USDC.balanceOf(address(this));
        uint256 pendingFees = ENGINE.accumulatedFeesUsdc();
        uint256 cashMinusFees = bal > pendingFees ? bal - pendingFees : 0;

        int256 mtm = ENGINE.getVaultMtmAdjustment();
        uint256 distributable;
        if (mtm >= 0) {
            distributable = cashMinusFees > uint256(mtm) ? cashMinusFees - uint256(mtm) : 0;
        } else {
            distributable = cashMinusFees + uint256(-mtm);
        }

        if (distributable > claimedEquity) {
            _distributeRevenue(distributable - claimedEquity);
        } else if (distributable < claimedEquity) {
            _absorbLoss(claimedEquity - distributable);
        }
    }

    function _distributeRevenue(
        uint256 revenue
    ) internal {
        uint256 remaining = revenue;

        if (remaining > 0 && seniorPrincipal < seniorHighWaterMark) {
            uint256 deficit = seniorHighWaterMark - seniorPrincipal;
            uint256 restore = remaining < deficit ? remaining : deficit;
            seniorPrincipal += restore;
            remaining -= restore;
        }

        uint256 seniorPayout = unpaidSeniorYield;
        if (seniorPayout > remaining) {
            seniorPayout = remaining;
        }
        seniorPrincipal += seniorPayout;
        unpaidSeniorYield -= seniorPayout;
        remaining -= seniorPayout;

        if (seniorPrincipal > seniorHighWaterMark) {
            seniorHighWaterMark = seniorPrincipal;
        }

        juniorPrincipal += remaining;

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
            if (seniorPrincipal > seniorLoss) {
                seniorPrincipal -= seniorLoss;
            } else {
                seniorPrincipal = 0;
                unpaidSeniorYield = 0;
            }
        }

        emit Reconciled(seniorPrincipal, juniorPrincipal, -int256(loss));
    }

}

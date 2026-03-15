// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {HousePoolAccountingLib} from "./libraries/HousePoolAccountingLib.sol";
import {HousePoolWaterfallAccountingLib} from "./libraries/HousePoolWaterfallAccountingLib.sol";
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

    struct VaultLiquidityView {
        uint256 totalAssetsUsdc;
        uint256 freeUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 seniorPrincipalUsdc;
        uint256 juniorPrincipalUsdc;
        uint256 unpaidSeniorYieldUsdc;
        uint256 seniorHighWaterMarkUsdc;
        bool markFresh;
        bool oracleFrozen;
        bool degradedMode;
    }

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
    error HousePool__SeniorImpaired();
    error HousePool__DegradedMode();

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

    /// @param _usdc USDC token address used as collateral
    /// @param _engine CfdEngine that manages positions and PnL
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

    /// @notice Set the OrderRouter address (one-time, immutable after set)
    function setOrderRouter(
        address _router
    ) external onlyOwner {
        if (orderRouter != address(0)) {
            revert HousePool__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    /// @notice Set the senior tranche vault address (one-time, immutable after set)
    function setSeniorVault(
        address _vault
    ) external onlyOwner {
        if (seniorVault != address(0)) {
            revert HousePool__SeniorVaultAlreadySet();
        }
        seniorVault = _vault;
    }

    /// @notice Set the junior tranche vault address (one-time, immutable after set)
    function setJuniorVault(
        address _vault
    ) external onlyOwner {
        if (juniorVault != address(0)) {
            revert HousePool__JuniorVaultAlreadySet();
        }
        juniorVault = _vault;
    }

    /// @notice Propose a new senior yield rate, subject to 48h timelock
    function proposeSeniorRate(
        uint256 _rateBps
    ) external onlyOwner {
        pendingSeniorRate = _rateBps;
        seniorRateActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit SeniorRateProposed(_rateBps, seniorRateActivationTime);
    }

    /// @notice Finalize the proposed senior rate after timelock expires
    function finalizeSeniorRate() external onlyOwner {
        if (seniorRateActivationTime == 0) {
            revert HousePool__NoProposal();
        }
        if (block.timestamp < seniorRateActivationTime) {
            revert HousePool__TimelockNotReady();
        }
        if (_markIsFreshForReconcile()) {
            _reconcile();
        } else {
            _accrueSeniorYieldOnly();
        }
        seniorRateBps = pendingSeniorRate;
        pendingSeniorRate = 0;
        seniorRateActivationTime = 0;
        emit SeniorRateUpdated(seniorRateBps);
        emit SeniorRateFinalized();
    }

    /// @notice Cancel the pending senior rate proposal
    function cancelSeniorRateProposal() external onlyOwner {
        pendingSeniorRate = 0;
        seniorRateActivationTime = 0;
    }

    /// @notice Propose a new mark-price staleness limit, subject to 48h timelock
    function proposeMarkStalenessLimit(
        uint256 _limit
    ) external onlyOwner {
        pendingMarkStalenessLimit = _limit;
        markStalenessLimitActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit MarkStalenessLimitProposed(_limit, markStalenessLimitActivationTime);
    }

    /// @notice Finalize the proposed staleness limit after timelock expires
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

    /// @notice Cancel the pending staleness limit proposal
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
    /// @param recipient Address to receive USDC
    /// @param amount USDC amount to transfer (6 decimals)
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

    /// @notice Deposit USDC into the senior tranche. Reverts if senior is impaired (below high-water mark).
    /// @param amount USDC to deposit (6 decimals)
    function depositSenior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        _reconcile();
        _requireFreshMark();
        if (seniorPrincipal < seniorHighWaterMark && seniorPrincipal > 0) {
            revert HousePool__SeniorImpaired();
        }
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        if (seniorPrincipal == 0) {
            seniorHighWaterMark = amount;
            seniorPrincipal = amount;
            return;
        }
        seniorHighWaterMark += amount;
        seniorPrincipal += amount;
    }

    /// @notice Withdraw USDC from the senior tranche. Scales high-water mark and unpaid yield proportionally.
    /// @param amount USDC to withdraw (6 decimals)
    /// @param receiver Address to receive USDC
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        if (amount == 0) {
            return;
        }
        _requireWithdrawalsLive(_getHousePoolStatusSnapshot());
        _reconcile();
        _requireFreshMark();
        if (amount > getMaxSeniorWithdraw()) {
            revert HousePool__ExceedsMaxSeniorWithdraw();
        }
        HousePoolWaterfallAccountingLib.WaterfallState memory state = _getWaterfallState();
        HousePoolWaterfallAccountingLib.WaterfallState memory nextState =
            HousePoolWaterfallAccountingLib.scaleSeniorOnWithdraw(state, amount);
        _setWaterfallState(nextState);
        USDC.safeTransfer(receiver, amount);
    }

    /// @notice Deposit USDC into the junior tranche.
    /// @param amount USDC to deposit (6 decimals)
    function depositJunior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        _reconcile();
        _requireFreshMark();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        juniorPrincipal += amount;
    }

    /// @notice Withdraw USDC from the junior tranche. Limited to free USDC above senior's claim.
    /// @param amount USDC to withdraw (6 decimals)
    /// @param receiver Address to receive USDC
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        _requireWithdrawalsLive(_getHousePoolStatusSnapshot());
        _reconcile();
        _requireFreshMark();
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
    /// @return Free USDC available for withdrawals (6 decimals)
    function getFreeUSDC() public view returns (uint256) {
        return _getWithdrawalSnapshot().freeUsdc;
    }

    /// @notice Max USDC the senior tranche can withdraw (limited by free USDC)
    /// @return Withdrawable senior USDC, capped at seniorPrincipal (6 decimals)
    function getMaxSeniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        return free < seniorPrincipal ? free : seniorPrincipal;
    }

    /// @notice Max USDC the junior tranche can withdraw (subordinated behind senior)
    /// @return Withdrawable junior USDC, capped at juniorPrincipal (6 decimals)
    function getMaxJuniorWithdraw() public view returns (uint256) {
        uint256 free = getFreeUSDC();
        uint256 subordinated = free > seniorPrincipal ? free - seniorPrincipal : 0;
        return subordinated < juniorPrincipal ? subordinated : juniorPrincipal;
    }

    function getVaultLiquidityView() external view returns (VaultLiquidityView memory viewData) {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);

        viewData.totalAssetsUsdc = USDC.balanceOf(address(this));
        viewData.freeUsdc = withdrawalSnapshot.freeUsdc;
        viewData.withdrawalReservedUsdc = withdrawalSnapshot.reserved;
        viewData.seniorPrincipalUsdc = seniorPrincipal;
        viewData.juniorPrincipalUsdc = juniorPrincipal;
        viewData.unpaidSeniorYieldUsdc = unpaidSeniorYield;
        viewData.seniorHighWaterMarkUsdc = seniorHighWaterMark;
        viewData.markFresh = !policy.required
            || HousePoolAccountingLib.isMarkFresh(statusSnapshot.lastMarkTime, policy.maxStaleness, block.timestamp);
        viewData.oracleFrozen = statusSnapshot.oracleFrozen;
        viewData.degradedMode = statusSnapshot.degradedMode;
    }

    // ==========================================
    // RECONCILIATION (Revenue & Loss Waterfall)
    // ==========================================

    /// @notice Distributes revenue (senior yield first, junior gets surplus) or absorbs losses
    ///         (junior first-loss, senior last-loss). Called before any deposit/withdrawal.
    function reconcile() external onlyVault {
        _reconcile();
    }

    function _requireFreshMark() internal view {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);
        if (!policy.required) {
            return;
        }
        if (!HousePoolAccountingLib.isMarkFresh(statusSnapshot.lastMarkTime, policy.maxStaleness, block.timestamp)) {
            revert HousePool__MarkPriceStale();
        }
    }

    function _reconcile() internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;

        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (claimedEquity == 0) {
            lastReconcileTime = block.timestamp;
            return;
        }

        if (!_markIsFreshForReconcile()) {
            return;
        }

        lastReconcileTime = block.timestamp;

        HousePoolAccountingLib.ReconcileSnapshot memory snapshot = _getReconcileSnapshot();
        HousePoolWaterfallAccountingLib.ReconcilePlan memory plan = HousePoolWaterfallAccountingLib.planReconcile(
            seniorPrincipal, juniorPrincipal, snapshot.distributable, seniorRateBps, elapsed
        );
        unpaidSeniorYield += plan.yieldAccrued;

        if (plan.isRevenue) {
            _distributeRevenue(plan.deltaUsdc);
        } else if (plan.deltaUsdc > 0) {
            _absorbLoss(plan.deltaUsdc);
        }
    }

    function _getWithdrawalSnapshot()
        internal
        view
        returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot)
    {
        return HousePoolAccountingLib.buildWithdrawalSnapshot(_getHousePoolInputSnapshot());
    }

    function _getReconcileSnapshot() internal view returns (HousePoolAccountingLib.ReconcileSnapshot memory snapshot) {
        return HousePoolAccountingLib.buildReconcileSnapshot(_getHousePoolInputSnapshot());
    }

    function _markIsFreshForReconcile() internal view returns (bool) {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);
        if (!policy.required) {
            return true;
        }

        return HousePoolAccountingLib.isMarkFresh(statusSnapshot.lastMarkTime, policy.maxStaleness, block.timestamp);
    }

    function _getHousePoolInputSnapshot() internal view returns (ICfdEngine.HousePoolInputSnapshot memory snapshot) {
        return ENGINE.getHousePoolInputSnapshot(markStalenessLimit);
    }

    function _getHousePoolStatusSnapshot() internal view returns (ICfdEngine.HousePoolStatusSnapshot memory snapshot) {
        return ENGINE.getHousePoolStatusSnapshot();
    }

    function _requireWithdrawalsLive(
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal pure {
        if (statusSnapshot.degradedMode) {
            revert HousePool__DegradedMode();
        }
    }

    function _accrueSeniorYieldOnly() internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;
        lastReconcileTime = block.timestamp;
        if (elapsed == 0 || seniorPrincipal == 0) {
            return;
        }

        unpaidSeniorYield += HousePoolWaterfallAccountingLib.accrueSeniorYield(seniorPrincipal, seniorRateBps, elapsed);
    }

    function _distributeRevenue(
        uint256 revenue
    ) internal {
        _setWaterfallState(HousePoolWaterfallAccountingLib.distributeRevenue(_getWaterfallState(), revenue));

        emit Reconciled(seniorPrincipal, juniorPrincipal, int256(revenue));
    }

    function _absorbLoss(
        uint256 loss
    ) internal {
        _setWaterfallState(HousePoolWaterfallAccountingLib.absorbLoss(_getWaterfallState(), loss));

        emit Reconciled(seniorPrincipal, juniorPrincipal, -int256(loss));
    }

    function _getWaterfallState() internal view returns (HousePoolWaterfallAccountingLib.WaterfallState memory state) {
        state.seniorPrincipal = seniorPrincipal;
        state.juniorPrincipal = juniorPrincipal;
        state.unpaidSeniorYield = unpaidSeniorYield;
        state.seniorHighWaterMark = seniorHighWaterMark;
    }

    function _setWaterfallState(
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal {
        seniorPrincipal = state.seniorPrincipal;
        juniorPrincipal = state.juniorPrincipal;
        unpaidSeniorYield = state.unpaidSeniorYield;
        seniorHighWaterMark = state.seniorHighWaterMark;
    }

}

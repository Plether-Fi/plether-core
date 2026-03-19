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
    uint256 public accountedAssets;

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
    error HousePool__ZeroAddress();
    error HousePool__ZeroStaleness();
    error HousePool__InvalidSeniorRate();
    error HousePool__NoExcessAssets();
    error HousePool__ExcessAmountTooHigh();

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);
    event MarkStalenessLimitUpdated(uint256 newLimit);
    event SeniorRateProposed(uint256 newRateBps, uint256 activationTime);
    event SeniorRateFinalized();
    event MarkStalenessLimitProposed(uint256 newLimit, uint256 activationTime);
    event MarkStalenessLimitFinalized();
    event ExcessAccounted(uint256 amountUsdc, uint256 accountedAssetsUsdc);
    event ExcessSwept(address indexed recipient, uint256 amountUsdc);
    event ProtocolInflowAccounted(address indexed caller, uint256 amountUsdc, uint256 accountedAssetsUsdc);

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
        if (_router == address(0)) {
            revert HousePool__ZeroAddress();
        }
        if (orderRouter != address(0)) {
            revert HousePool__RouterAlreadySet();
        }
        orderRouter = _router;
    }

    /// @notice Set the senior tranche vault address (one-time, immutable after set)
    function setSeniorVault(
        address _vault
    ) external onlyOwner {
        if (_vault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        if (seniorVault != address(0)) {
            revert HousePool__SeniorVaultAlreadySet();
        }
        seniorVault = _vault;
    }

    /// @notice Set the junior tranche vault address (one-time, immutable after set)
    function setJuniorVault(
        address _vault
    ) external onlyOwner {
        if (_vault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        if (juniorVault != address(0)) {
            revert HousePool__JuniorVaultAlreadySet();
        }
        juniorVault = _vault;
    }

    /// @notice Propose a new senior yield rate, subject to 48h timelock
    function proposeSeniorRate(
        uint256 _rateBps
    ) external onlyOwner {
        if (_rateBps > 10_000) {
            revert HousePool__InvalidSeniorRate();
        }
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
        ENGINE.syncFunding();
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        if (_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            _reconcile(accountingSnapshot);
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
        if (_limit == 0) {
            revert HousePool__ZeroStaleness();
        }
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

    /// @notice Pause deposits into both tranches
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause deposits into both tranches
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==========================================
    // ICfdVault INTERFACE
    // ==========================================

    /// @notice Canonical economic USDC backing recognized by the pool.
    ///         Unsolicited positive transfers are ignored until explicitly accounted,
    ///         while raw-balance shortfalls still reduce the effective backing.
    function totalAssets() public view returns (uint256) {
        uint256 raw = USDC.balanceOf(address(this));
        return raw < accountedAssets ? raw : accountedAssets;
    }

    /// @notice Raw USDC balance currently held by the pool, including unsolicited transfers.
    function rawAssets() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Raw USDC held above canonical accounted assets.
    function excessAssets() public view returns (uint256) {
        uint256 raw = rawAssets();
        return raw > accountedAssets ? raw - accountedAssets : 0;
    }

    /// @notice Explicitly converts unsolicited USDC into accounted protocol assets.
    ///         Syncs funding first so the added depth applies only going forward.
    function accountExcess() external onlyOwner {
        uint256 amount = excessAssets();
        if (amount == 0) {
            revert HousePool__NoExcessAssets();
        }
        ENGINE.syncFunding();
        accountedAssets += amount;
        emit ExcessAccounted(amount, accountedAssets);
    }

    /// @notice Sweeps unsolicited USDC that has not been accounted into protocol economics.
    function sweepExcess(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) {
            revert HousePool__ZeroAddress();
        }
        if (amount > excessAssets()) {
            revert HousePool__ExcessAmountTooHigh();
        }
        USDC.safeTransfer(recipient, amount);
        emit ExcessSwept(recipient, amount);
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
        accountedAssets -= amount;
        USDC.safeTransfer(recipient, amount);
    }

    /// @notice Accounts a legitimate protocol-owned inflow into canonical vault assets.
    /// @dev Only the engine or order router may use this path. Unlike `accountExcess()`, this does
    ///      not require raw excess to exist: it is the explicit accounting hook for endogenous
    ///      protocol gains and may also be used to restore canonical accounting after a raw-balance
    ///      shortfall has already reduced effective assets through `totalAssets() = min(raw, accounted)`.
    function recordProtocolInflow(
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != orderRouter) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }
        accountedAssets += amount;
        emit ProtocolInflowAccounted(msg.sender, amount, accountedAssets);
    }

    // ==========================================
    // TRANCHE DEPOSITS & WITHDRAWALS
    // ==========================================

    /// @notice Deposit USDC into the senior tranche. Reverts if senior is impaired (below high-water mark).
    /// @param amount USDC to deposit (6 decimals)
    function depositSenior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        ENGINE.syncFunding();
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        if (seniorPrincipal < seniorHighWaterMark && seniorPrincipal > 0) {
            revert HousePool__SeniorImpaired();
        }
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accountedAssets += amount;
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
        ENGINE.syncFunding();
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _requireWithdrawalsLive(statusSnapshot);
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        if (amount > getMaxSeniorWithdraw()) {
            revert HousePool__ExceedsMaxSeniorWithdraw();
        }
        HousePoolWaterfallAccountingLib.WaterfallState memory state = _getWaterfallState();
        HousePoolWaterfallAccountingLib.WaterfallState memory nextState =
            HousePoolWaterfallAccountingLib.scaleSeniorOnWithdraw(state, amount);
        _setWaterfallState(nextState);
        accountedAssets -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    /// @notice Deposit USDC into the junior tranche.
    /// @param amount USDC to deposit (6 decimals)
    function depositJunior(
        uint256 amount
    ) external onlyVault whenNotPaused {
        ENGINE.syncFunding();
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accountedAssets += amount;
        juniorPrincipal += amount;
    }

    /// @notice Withdraw USDC from the junior tranche. Limited to free USDC above senior's claim.
    /// @param amount USDC to withdraw (6 decimals)
    /// @param receiver Address to receive USDC
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external onlyVault {
        ENGINE.syncFunding();
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _requireWithdrawalsLive(statusSnapshot);
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        if (amount > getMaxJuniorWithdraw()) {
            revert HousePool__ExceedsMaxJuniorWithdraw();
        }
        juniorPrincipal -= amount;
        accountedAssets -= amount;
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

    /// @notice Returns tranche principals and withdrawal caps as if reconcile ran right now.
    /// @dev Read-only preview for ERC4626 consumers that need same-tx parity with reconcile-first vault flows.
    function getPendingTrancheState()
        external
        view
        returns (
            uint256 seniorPrincipalUsdc,
            uint256 juniorPrincipalUsdc,
            uint256 maxSeniorWithdrawUsdc,
            uint256 maxJuniorWithdrawUsdc
        )
    {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolWaterfallAccountingLib.WaterfallState memory state =
            _previewReconciledWaterfallState(accountingSnapshot, statusSnapshot);
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);

        seniorPrincipalUsdc = state.seniorPrincipal;
        juniorPrincipalUsdc = state.juniorPrincipal;

        uint256 free = withdrawalSnapshot.freeUsdc;
        maxSeniorWithdrawUsdc = free < seniorPrincipalUsdc ? free : seniorPrincipalUsdc;

        uint256 subordinated = free > seniorPrincipalUsdc ? free - seniorPrincipalUsdc : 0;
        maxJuniorWithdrawUsdc = subordinated < juniorPrincipalUsdc ? subordinated : juniorPrincipalUsdc;
    }

    function isWithdrawalLive() external view returns (bool) {
        ICfdEngine.HousePoolStatusSnapshot memory status = _getHousePoolStatusSnapshot();
        if (status.degradedMode) {
            return false;
        }
        ICfdEngine.HousePoolInputSnapshot memory accounting = _getHousePoolInputSnapshot();
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accounting);
        if (
            policy.required
                && !HousePoolAccountingLib.isMarkFresh(status.lastMarkTime, policy.maxStaleness, block.timestamp)
        ) {
            return false;
        }
        return true;
    }

    /// @notice Snapshot of pool liquidity, tranche principals, and oracle health for frontend consumption
    /// @return viewData Struct containing balances, reserves, and status flags
    function getVaultLiquidityView() external view returns (VaultLiquidityView memory viewData) {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);

        viewData.totalAssetsUsdc = totalAssets();
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
        ENGINE.syncFunding();
        _reconcile(_getHousePoolInputSnapshot());
    }

    function _requireFreshMark(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view {
        HousePoolAccountingLib.MarkFreshnessPolicy memory policy =
            HousePoolAccountingLib.getMarkFreshnessPolicy(accountingSnapshot);
        if (!policy.required) {
            return;
        }
        if (!HousePoolAccountingLib.isMarkFresh(statusSnapshot.lastMarkTime, policy.maxStaleness, block.timestamp)) {
            revert HousePool__MarkPriceStale();
        }
    }

    function _reconcile(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot
    ) internal {
        uint256 elapsed = block.timestamp - lastReconcileTime;

        uint256 claimedEquity = seniorPrincipal + juniorPrincipal;
        if (claimedEquity == 0) {
            lastReconcileTime = block.timestamp;
            return;
        }

        if (!_markIsFreshForReconcile(accountingSnapshot, _getHousePoolStatusSnapshot())) {
            return;
        }

        lastReconcileTime = block.timestamp;

        HousePoolAccountingLib.ReconcileSnapshot memory snapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
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

    function _previewReconciledWaterfallState(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (HousePoolWaterfallAccountingLib.WaterfallState memory state) {
        state = _getWaterfallState();

        if (state.seniorPrincipal + state.juniorPrincipal == 0) {
            return state;
        }

        if (!_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            return state;
        }

        uint256 elapsed = block.timestamp - lastReconcileTime;
        HousePoolAccountingLib.ReconcileSnapshot memory snapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
        HousePoolWaterfallAccountingLib.ReconcilePlan memory plan = HousePoolWaterfallAccountingLib.planReconcile(
            state.seniorPrincipal, state.juniorPrincipal, snapshot.distributable, seniorRateBps, elapsed
        );
        state.unpaidSeniorYield += plan.yieldAccrued;

        if (plan.isRevenue) {
            return HousePoolWaterfallAccountingLib.distributeRevenue(state, plan.deltaUsdc);
        }
        if (plan.deltaUsdc > 0) {
            return HousePoolWaterfallAccountingLib.absorbLoss(state, plan.deltaUsdc);
        }
        return state;
    }

    function _markIsFreshForReconcile(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
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

    function _getHousePoolSnapshots()
        internal
        view
        returns (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        )
    {
        accountingSnapshot = _getHousePoolInputSnapshot();
        statusSnapshot = _getHousePoolStatusSnapshot();
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

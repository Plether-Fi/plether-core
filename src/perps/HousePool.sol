// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {ICfdEngine} from "./interfaces/ICfdEngine.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {ITrancheVaultBootstrap} from "./interfaces/ITrancheVaultBootstrap.sol";
import {HousePoolAccountingLib} from "./libraries/HousePoolAccountingLib.sol";
import {HousePoolFreshnessLib} from "./libraries/HousePoolFreshnessLib.sol";
import {HousePoolPendingLivePlanLib} from "./libraries/HousePoolPendingLivePlanLib.sol";
import {HousePoolPendingPreviewLib} from "./libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolReconcilePlanLib} from "./libraries/HousePoolReconcilePlanLib.sol";
import {HousePoolSeedLifecycleLib} from "./libraries/HousePoolSeedLifecycleLib.sol";
import {HousePoolTrancheGateLib} from "./libraries/HousePoolTrancheGateLib.sol";
import {HousePoolWaterfallAccountingLib} from "./libraries/HousePoolWaterfallAccountingLib.sol";
import {HousePoolWithdrawalPreviewLib} from "./libraries/HousePoolWithdrawalPreviewLib.sol";
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

    struct PendingAccountingState {
        HousePoolWaterfallAccountingLib.WaterfallState waterfall;
        uint256 unassignedAssets;
        uint256 seniorSupply;
        uint256 juniorSupply;
    }

    struct HousePoolContext {
        ICfdEngine.HousePoolInputSnapshot accountingSnapshot;
        ICfdEngine.HousePoolStatusSnapshot statusSnapshot;
        PendingAccountingState pendingState;
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
    uint256 public unassignedAssets;
    uint256 public pendingRecapitalizationUsdc;
    uint256 public pendingTradingRevenueUsdc;

    uint256 public lastReconcileTime;
    uint256 public lastSeniorYieldCheckpointTime;
    uint256 public seniorRateBps;
    uint256 public markStalenessLimit = 60;
    bool public override(ICfdVault, IHousePool) isTradingActive;
    bool public seniorSeedInitialized;
    bool public juniorSeedInitialized;

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
    error HousePool__PendingBootstrap();
    error HousePool__NoUnassignedAssets();
    error HousePool__BootstrapSharesZero();
    error HousePool__SeedAlreadyInitialized();
    error HousePool__TradingActivationNotReady();

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
    event RecapitalizationInflowAccounted(address indexed caller, uint256 amountUsdc, uint256 seniorRestorationUsdc);
    event TradingRevenueInflowAccounted(
        address indexed caller, uint256 amountUsdc, uint256 seniorAssignedUsdc, uint256 juniorAssignedUsdc
    );
    event UnassignedAssetsAssigned(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event SeedPositionInitialized(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event TradingActivated();

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
        lastSeniorYieldCheckpointTime = block.timestamp;
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

    /// @notice Finalize the proposed senior rate after timelock expires.
    /// @dev Syncs funding first. If the mark is stale, the new rate is applied without accruing stale-window senior yield.
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
            if (seniorPrincipal == 0) {
                lastReconcileTime = block.timestamp;
            }
            _applyPendingBucketsLive(accountingSnapshot, statusSnapshot);
            lastSeniorYieldCheckpointTime = block.timestamp;
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

    function isSeedLifecycleComplete() public view returns (bool) {
        return HousePoolSeedLifecycleLib.isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized);
    }

    function hasSeedLifecycleStarted() public view override(ICfdVault, IHousePool) returns (bool) {
        return HousePoolSeedLifecycleLib.hasSeedLifecycleStarted(seniorSeedInitialized, juniorSeedInitialized);
    }

    function canAcceptOrdinaryDeposits() public view override(ICfdVault, IHousePool) returns (bool) {
        return HousePoolSeedLifecycleLib.canAcceptOrdinaryDeposits(
            seniorSeedInitialized, juniorSeedInitialized, isTradingActive
        );
    }

    function canAcceptTrancheDeposits(
        bool isSenior
    ) public view override returns (bool) {
        (
            ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
            ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        HousePoolContext memory ctx = _buildHousePoolContext(accountingSnapshot, statusSnapshot);
        return HousePoolTrancheGateLib.trancheDepositsAllowed(
            canAcceptOrdinaryDeposits(),
            paused(),
            unassignedAssets,
            _markIsFreshForReconcile(accountingSnapshot, statusSnapshot),
            ctx.pendingState.unassignedAssets,
            isSenior,
            ctx.pendingState.waterfall.seniorPrincipal,
            ctx.pendingState.waterfall.seniorHighWaterMark
        );
    }

    function canIncreaseRisk() public view override(ICfdVault, IHousePool) returns (bool) {
        return HousePoolSeedLifecycleLib.canIncreaseRisk(seniorSeedInitialized, juniorSeedInitialized, isTradingActive);
    }

    function activateTrading() external onlyOwner {
        if (!HousePoolSeedLifecycleLib.tradingActivationReady(seniorSeedInitialized, juniorSeedInitialized)) {
            revert HousePool__TradingActivationNotReady();
        }
        isTradingActive = true;
        emit TradingActivated();
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

    /// @notice Accounts a governance recapitalization inflow and routes it toward senior restoration when possible.
    /// @dev This narrows the cases that fall into generic unassigned accounting when a seeded senior tranche exists.
    function recordRecapitalizationInflow(
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE)) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }

        accountedAssets += amount;
        pendingRecapitalizationUsdc += amount;
        emit RecapitalizationInflowAccounted(msg.sender, amount, 0);
    }

    /// @notice Accounts LP-owned trading revenue and directly attaches it to seeded claimants when no live principal exists.
    /// @dev Used for realized trader losses / spread capture paths whose economic owner is LP equity rather than protocol fees.
    function recordTradingRevenueInflow(
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE)) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }

        accountedAssets += amount;
        if (seniorPrincipal + juniorPrincipal == 0) {
            pendingTradingRevenueUsdc += amount;
        }
        emit TradingRevenueInflowAccounted(msg.sender, amount, 0, 0);
    }

    /// @notice Explicitly bootstraps quarantined LP assets into a tranche by minting matching shares.
    /// @dev Prevents later LPs from implicitly capturing value that arrived while no claimant shares existed.
    function assignUnassignedAssets(
        bool toSenior,
        address receiver
    ) external onlyOwner {
        if (receiver == address(0)) {
            revert HousePool__ZeroAddress();
        }

        HousePoolContext memory ctx = _syncAndBuildHousePoolContext();
        _requireFreshMark(ctx.accountingSnapshot, ctx.statusSnapshot);
        _reconcile(ctx.accountingSnapshot);

        uint256 amount = unassignedAssets;
        if (amount == 0) {
            revert HousePool__NoUnassignedAssets();
        }

        address targetVault = toSenior ? seniorVault : juniorVault;
        if (targetVault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        uint256 shares = ITrancheVaultBootstrap(targetVault).previewDeposit(amount);
        if (shares == 0) {
            revert HousePool__BootstrapSharesZero();
        }

        if (toSenior) {
            if (seniorPrincipal == 0) {
                seniorPrincipal = amount;
                seniorHighWaterMark = amount;
            } else {
                seniorPrincipal += amount;
                seniorHighWaterMark += amount;
            }
        } else {
            juniorPrincipal += amount;
        }
        unassignedAssets = 0;
        ITrancheVaultBootstrap(targetVault).bootstrapMint(shares, receiver);
        emit UnassignedAssetsAssigned(toSenior, receiver, amount, shares);
    }

    /// @notice Seeds a tranche with a permanent minimum share supply backed by real USDC.
    /// @dev Syncs funding first so the new seed depth only affects funding prospectively, then mints
    ///      bootstrap shares to ensure a tranche never becomes ownerless in steady state.
    function initializeSeedPosition(
        bool toSenior,
        uint256 amount,
        address receiver
    ) external onlyOwner {
        if (amount == 0) {
            revert HousePool__BootstrapSharesZero();
        }
        if (receiver == address(0)) {
            revert HousePool__ZeroAddress();
        }

        address targetVault = toSenior ? seniorVault : juniorVault;
        if (targetVault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        if (toSenior ? seniorSeedInitialized : juniorSeedInitialized) {
            revert HousePool__SeedAlreadyInitialized();
        }

        uint256 shares = ITrancheVaultBootstrap(targetVault).previewDeposit(amount);
        if (shares == 0) {
            revert HousePool__BootstrapSharesZero();
        }

        ENGINE.syncFunding();
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        accountedAssets += amount;
        if (toSenior) {
            _checkpointSeniorYieldBeforePrincipalMutation(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
            seniorPrincipal += amount;
            seniorHighWaterMark += amount;
            seniorSeedInitialized = true;
        } else {
            juniorPrincipal += amount;
            juniorSeedInitialized = true;
        }
        ITrancheVaultBootstrap(targetVault).bootstrapMint(shares, receiver);
        ITrancheVaultBootstrap(targetVault).configureSeedPosition(receiver, shares);
        emit SeedPositionInitialized(toSenior, receiver, amount, shares);
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
        _requireNoPendingBootstrap();
        if (seniorPrincipal < seniorHighWaterMark && seniorPrincipal > 0) {
            revert HousePool__SeniorImpaired();
        }
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accountedAssets += amount;
        if (seniorPrincipal == 0) {
            _checkpointSeniorYieldBeforePrincipalMutation(accountingSnapshot, statusSnapshot);
            seniorHighWaterMark = amount;
            seniorPrincipal = amount;
            return;
        }
        _checkpointSeniorYieldBeforePrincipalMutation(accountingSnapshot, statusSnapshot);
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
        _requireNoPendingBootstrap();
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
        if (!_withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot())) {
            return 0;
        }
        return HousePoolWithdrawalPreviewLib.seniorWithdrawCap(getFreeUSDC(), seniorPrincipal);
    }

    /// @notice Max USDC the junior tranche can withdraw (subordinated behind senior)
    /// @return Withdrawable junior USDC, capped at juniorPrincipal (6 decimals)
    function getMaxJuniorWithdraw() public view returns (uint256) {
        if (!_withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot())) {
            return 0;
        }
        return HousePoolWithdrawalPreviewLib.juniorWithdrawCap(getFreeUSDC(), seniorPrincipal, juniorPrincipal);
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
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            _buildWithdrawalSnapshot(ctx.accountingSnapshot, ctx.pendingState.unassignedAssets, true);
        if (!_withdrawalsLive(ctx.accountingSnapshot, ctx.statusSnapshot)) {
            seniorPrincipalUsdc = ctx.pendingState.waterfall.seniorPrincipal;
            juniorPrincipalUsdc = ctx.pendingState.waterfall.juniorPrincipal;
            return (seniorPrincipalUsdc, juniorPrincipalUsdc, 0, 0);
        }
        seniorPrincipalUsdc = ctx.pendingState.waterfall.seniorPrincipal;
        juniorPrincipalUsdc = ctx.pendingState.waterfall.juniorPrincipal;

        maxSeniorWithdrawUsdc =
            HousePoolWithdrawalPreviewLib.seniorWithdrawCap(withdrawalSnapshot.freeUsdc, seniorPrincipalUsdc);
        maxJuniorWithdrawUsdc = HousePoolWithdrawalPreviewLib.juniorWithdrawCap(
            withdrawalSnapshot.freeUsdc, seniorPrincipalUsdc, juniorPrincipalUsdc
        );
    }

    function isWithdrawalLive() external view returns (bool) {
        return _withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
    }

    /// @notice Snapshot of pool liquidity, tranche principals, and oracle health for frontend consumption
    /// @return viewData Struct containing balances, reserves, and status flags
    function getVaultLiquidityView() external view returns (VaultLiquidityView memory viewData) {
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            _buildWithdrawalSnapshot(accountingSnapshot, unassignedAssets, false);
        viewData.totalAssetsUsdc = totalAssets();
        viewData.freeUsdc = withdrawalSnapshot.freeUsdc;
        viewData.withdrawalReservedUsdc = withdrawalSnapshot.reserved;
        viewData.seniorPrincipalUsdc = seniorPrincipal;
        viewData.juniorPrincipalUsdc = juniorPrincipal;
        viewData.unpaidSeniorYieldUsdc = unpaidSeniorYield;
        viewData.seniorHighWaterMarkUsdc = seniorHighWaterMark;
        viewData.markFresh = HousePoolFreshnessLib.markFresh(accountingSnapshot, statusSnapshot, block.timestamp);
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
        if (!HousePoolFreshnessLib.markFresh(accountingSnapshot, statusSnapshot, block.timestamp)) {
            revert HousePool__MarkPriceStale();
        }
    }

    function _reconcile(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot
    ) internal {
        uint256 yieldElapsed =
            block.timestamp > lastSeniorYieldCheckpointTime ? block.timestamp - lastSeniorYieldCheckpointTime : 0;
        bool markFresh = _markIsFreshForReconcile(accountingSnapshot, _getHousePoolStatusSnapshot());
        if (markFresh) {
            HousePoolReconcilePlanLib.ReconcilePlan memory plan = HousePoolReconcilePlanLib.planReconcile(
                HousePoolPendingPreviewLib.PendingAccountingState({
                    waterfall: _getWaterfallState(),
                    unassignedAssets: unassignedAssets,
                    seniorSupply: _seniorShareSupply(),
                    juniorSupply: _juniorShareSupply()
                }),
                HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot),
                _pendingBucketAssets(),
                seniorRateBps,
                yieldElapsed,
                markFresh
            );

            lastReconcileTime = block.timestamp;
            lastSeniorYieldCheckpointTime = block.timestamp;

            _setWaterfallState(plan.state.waterfall);
            unassignedAssets = plan.state.unassignedAssets;

            uint256 juniorRevenueWithoutOwners = HousePoolReconcilePlanLib.juniorRevenueWithoutOwners(plan);
            if (juniorRevenueWithoutOwners > 0) {
                juniorPrincipal -= juniorRevenueWithoutOwners;
                unassignedAssets += juniorRevenueWithoutOwners;
            }
        }

        _applyPendingBucketsLive(accountingSnapshot, _getHousePoolStatusSnapshot());
    }

    function _getWithdrawalSnapshot()
        internal
        view
        returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot)
    {
        return _buildWithdrawalSnapshot(_getHousePoolInputSnapshot(), unassignedAssets, false);
    }

    function _buildHousePoolContext(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (HousePoolContext memory ctx) {
        ctx.accountingSnapshot = accountingSnapshot;
        ctx.statusSnapshot = statusSnapshot;
        ctx.pendingState = _previewPendingAccountingState(accountingSnapshot, statusSnapshot);
    }

    function _syncAndBuildHousePoolContext() internal returns (HousePoolContext memory ctx) {
        ENGINE.syncFunding();
        return _buildCurrentHousePoolContext();
    }

    function _buildCurrentHousePoolContext() internal view returns (HousePoolContext memory ctx) {
        return _buildHousePoolContext(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
    }

    function _previewPendingAccountingState(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (PendingAccountingState memory pendingState) {
        pendingState.waterfall = _getWaterfallState();
        pendingState.unassignedAssets = unassignedAssets;
        pendingState.seniorSupply = _seniorShareSupply();
        pendingState.juniorSupply = _juniorShareSupply();

        if (_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            HousePoolAccountingLib.ReconcileSnapshot memory snapshot =
                HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
            uint256 pendingAssets = _pendingBucketAssets();
            if (pendingAssets > 0) {
                snapshot.distributable =
                    snapshot.distributable > pendingAssets ? snapshot.distributable - pendingAssets : 0;
            }
            pendingState.unassignedAssets = _normalizeUnassignedAssets(snapshot.distributable);
            if (pendingState.waterfall.seniorPrincipal + pendingState.waterfall.juniorPrincipal == 0) {
                pendingState.unassignedAssets = snapshot.distributable;
            } else {
                uint256 elapsed = block.timestamp > lastSeniorYieldCheckpointTime
                    ? block.timestamp - lastSeniorYieldCheckpointTime
                    : 0;
                uint256 distributableToClaims = snapshot.distributable > pendingState.unassignedAssets
                    ? snapshot.distributable - pendingState.unassignedAssets
                    : 0;
                HousePoolWaterfallAccountingLib.ReconcilePlan memory plan = HousePoolWaterfallAccountingLib.planReconcile(
                    pendingState.waterfall.seniorPrincipal,
                    pendingState.waterfall.juniorPrincipal,
                    distributableToClaims,
                    seniorRateBps,
                    elapsed
                );
                pendingState.waterfall.unpaidSeniorYield += plan.yieldAccrued;

                if (plan.isRevenue) {
                    uint256 juniorBefore = pendingState.waterfall.juniorPrincipal;
                    pendingState.waterfall =
                        HousePoolWaterfallAccountingLib.distributeRevenue(pendingState.waterfall, plan.deltaUsdc);
                    if (pendingState.juniorSupply == 0 && pendingState.waterfall.juniorPrincipal > juniorBefore) {
                        pendingState.unassignedAssets += pendingState.waterfall.juniorPrincipal - juniorBefore;
                        pendingState.waterfall.juniorPrincipal = juniorBefore;
                    }
                } else if (plan.deltaUsdc > 0) {
                    pendingState.waterfall =
                        HousePoolWaterfallAccountingLib.absorbLoss(pendingState.waterfall, plan.deltaUsdc);
                }
            }
        }

        _applyPendingBucketsPreview(pendingState);
    }

    function _markIsFreshForReconcile(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
        return HousePoolFreshnessLib.markIsFreshForReconcile(accountingSnapshot, statusSnapshot, block.timestamp);
    }

    function _withdrawalsLive(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
        return HousePoolFreshnessLib.withdrawalsLive(accountingSnapshot, statusSnapshot, block.timestamp);
    }

    function _normalizeUnassignedAssets(
        uint256 distributableUsdc
    ) internal view returns (uint256 normalized) {
        normalized = unassignedAssets;
        if (normalized > distributableUsdc) {
            normalized = distributableUsdc;
        }
    }

    function _juniorShareSupply() internal view returns (uint256) {
        if (juniorVault == address(0)) {
            return 0;
        }
        return IERC20(juniorVault).totalSupply();
    }

    function _seniorShareSupply() internal view returns (uint256) {
        if (seniorVault == address(0)) {
            return 0;
        }
        return IERC20(seniorVault).totalSupply();
    }

    function _requireNoPendingBootstrap() internal view {
        if (HousePoolSeedLifecycleLib.hasPendingBootstrap(unassignedAssets)) {
            revert HousePool__PendingBootstrap();
        }
    }

    function _buildWithdrawalSnapshot(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        uint256 reservedUnassignedAssets,
        bool isProjected
    ) internal view returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot) {
        snapshot = HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);
        if (!isProjected) {
            uint256 pendingAssets = _pendingBucketAssets();
            snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, pendingAssets);
        }
        snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, reservedUnassignedAssets);
    }

    function _checkpointSeniorYieldBeforePrincipalMutation(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal {
        uint256 elapsed =
            block.timestamp > lastSeniorYieldCheckpointTime ? block.timestamp - lastSeniorYieldCheckpointTime : 0;
        if (elapsed == 0) {
            return;
        }

        if (seniorPrincipal == 0) {
            lastSeniorYieldCheckpointTime = block.timestamp;
            return;
        }

        if (_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            unpaidSeniorYield += HousePoolWaterfallAccountingLib.accrueSeniorYield(
                seniorPrincipal, seniorRateBps, elapsed
            );
        }

        lastSeniorYieldCheckpointTime = block.timestamp;
    }

    function _applyPendingBucketsLive(
        ICfdEngine.HousePoolInputSnapshot memory accountingSnapshot,
        ICfdEngine.HousePoolStatusSnapshot memory statusSnapshot
    ) internal {
        if (pendingRecapitalizationUsdc == 0 && pendingTradingRevenueUsdc == 0) {
            return;
        }

        HousePoolPendingLivePlanLib.PendingLivePlan memory plan = HousePoolPendingLivePlanLib.planApplyPendingBuckets(
            _copyPendingAccountingState(
                PendingAccountingState({
                    waterfall: _getWaterfallState(),
                    unassignedAssets: unassignedAssets,
                    seniorSupply: _seniorShareSupply(),
                    juniorSupply: _juniorShareSupply()
                })
            ),
            seniorPrincipal,
            pendingRecapitalizationUsdc,
            pendingTradingRevenueUsdc
        );
        pendingRecapitalizationUsdc = 0;
        pendingTradingRevenueUsdc = 0;

        if (plan.seniorPrincipalChanged) {
            _checkpointSeniorYieldBeforePrincipalMutation(accountingSnapshot, statusSnapshot);
            plan.state.waterfall.unpaidSeniorYield = unpaidSeniorYield;
        }

        _setWaterfallState(plan.state.waterfall);
        unassignedAssets = plan.state.unassignedAssets;
    }

    function _applyPendingBucketsPreview(
        PendingAccountingState memory state
    ) internal view {
        HousePoolPendingPreviewLib.PendingAccountingState memory previewState = _copyPendingAccountingState(state);
        HousePoolPendingPreviewLib.applyPendingBucketsPreview(
            previewState, pendingRecapitalizationUsdc, pendingTradingRevenueUsdc
        );
        state.waterfall = previewState.waterfall;
        state.unassignedAssets = previewState.unassignedAssets;
    }

    function _applyRecapitalizationIntent(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        HousePoolPendingPreviewLib.PendingAccountingState memory previewState = _copyPendingAccountingState(state);
        HousePoolPendingPreviewLib.applyRecapitalizationIntent(previewState, amount);
        state.waterfall = previewState.waterfall;
        state.unassignedAssets = previewState.unassignedAssets;
    }

    function _routeSeededRevenue(
        PendingAccountingState memory state,
        uint256 amount
    ) internal pure {
        HousePoolPendingPreviewLib.PendingAccountingState memory previewState = _copyPendingAccountingState(state);
        HousePoolPendingPreviewLib.routeSeededRevenue(previewState, amount);
        state.waterfall = previewState.waterfall;
        state.unassignedAssets = previewState.unassignedAssets;
    }

    function _copyPendingAccountingState(
        PendingAccountingState memory state
    ) internal pure returns (HousePoolPendingPreviewLib.PendingAccountingState memory copiedState) {
        copiedState = HousePoolPendingPreviewLib.PendingAccountingState({
            waterfall: state.waterfall,
            unassignedAssets: state.unassignedAssets,
            seniorSupply: state.seniorSupply,
            juniorSupply: state.juniorSupply
        });
    }

    function _pendingBucketAssets() internal view returns (uint256) {
        return pendingRecapitalizationUsdc + pendingTradingRevenueUsdc;
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

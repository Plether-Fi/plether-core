// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngineProtocolLens} from "./CfdEngineProtocolLens.sol";
import {HousePoolEngineViewTypes} from "./interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineCore} from "./interfaces/ICfdEngineCore.sol";
import {ICfdEngineProtocolLens} from "./interfaces/ICfdEngineProtocolLens.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {IPerpsLPActions} from "./interfaces/IPerpsLPActions.sol";
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
contract HousePool is ICfdVault, IHousePool, IPerpsLPActions, Ownable2Step, Pausable {

    using SafeERC20 for IERC20;

    struct VaultLiquidityView {
        uint256 totalAssetsUsdc;
        uint256 freeUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 pendingRecapitalizationUsdc;
        uint256 pendingTradingRevenueUsdc;
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
        HousePoolEngineViewTypes.HousePoolInputSnapshot accountingSnapshot;
        HousePoolEngineViewTypes.HousePoolStatusSnapshot statusSnapshot;
        PendingAccountingState pendingState;
    }

    struct PoolConfig {
        uint256 seniorRateBps;
        uint256 markStalenessLimit;
        uint256 seniorFrozenLpFeeBps;
        uint256 juniorFrozenLpFeeBps;
    }

    IERC20 public immutable USDC;
    ICfdEngineCore public immutable ENGINE;
    ICfdEngineProtocolLens public immutable ENGINE_PROTOCOL_LENS;

    address public orderRouter;
    address public seniorVault;
    address public juniorVault;
    address public pauser;

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
    PoolConfig internal poolConfig;
    uint256 public constant MAX_FROZEN_LP_FEE_BPS = 1000;
    bool public override(ICfdVault, IHousePool) isTradingActive;
    bool public seniorSeedInitialized;
    bool public juniorSeedInitialized;

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    PoolConfig public pendingPoolConfig;
    uint256 public poolConfigActivationTime;

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
    error HousePool__InvalidFrozenLpFee();
    error HousePool__NoExcessAssets();
    error HousePool__ExcessAmountTooHigh();
    error HousePool__PendingBootstrap();
    error HousePool__NoUnassignedAssets();
    error HousePool__BootstrapSharesZero();
    error HousePool__SeedAlreadyInitialized();
    error HousePool__TradingActivationNotReady();
    error HousePool__UnauthorizedPauser();
    error HousePool__OracleFrozen();

    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    event SeniorRateUpdated(uint256 newRateBps);
    event MarkStalenessLimitUpdated(uint256 newLimit);
    event PoolConfigProposed(
        uint256 seniorRateBps,
        uint256 markStalenessLimit,
        uint256 seniorFrozenLpFeeBps,
        uint256 juniorFrozenLpFeeBps,
        uint256 activationTime
    );
    event PoolConfigFinalized();
    event FrozenLpFeesUpdated(uint256 seniorFeeBps, uint256 juniorFeeBps);
    event ExcessAccounted(uint256 amountUsdc, uint256 accountedAssetsUsdc);
    event ExcessSwept(address indexed recipient, uint256 amountUsdc);
    event ProtocolInflowAccounted(address indexed caller, uint256 amountUsdc, uint256 accountedAssetsUsdc);
    event ClaimantInflowAccounted(
        address indexed caller,
        ICfdVault.ClaimantInflowKind kind,
        ICfdVault.ClaimantInflowCashMode cashMode,
        uint256 amountUsdc
    );
    event UnassignedAssetsAssigned(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event SeedPositionInitialized(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    event TradingActivated();
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

    modifier onlyPauserOrOwner() {
        if (msg.sender != owner() && msg.sender != pauser) {
            revert HousePool__UnauthorizedPauser();
        }
        _;
    }

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
        ENGINE = ICfdEngineCore(_engine);
        ENGINE_PROTOCOL_LENS = ICfdEngineProtocolLens(address(new CfdEngineProtocolLens(_engine)));
        lastReconcileTime = block.timestamp;
        lastSeniorYieldCheckpointTime = block.timestamp;
        poolConfig = PoolConfig({
            seniorRateBps: 800, markStalenessLimit: 60, seniorFrozenLpFeeBps: 25, juniorFrozenLpFeeBps: 75
        });
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

    /// @notice Propose a new pool config, subject to a 48h timelock.
    function proposePoolConfig(
        PoolConfig calldata newConfig
    ) external onlyOwner {
        _validatePoolConfig(newConfig);
        pendingPoolConfig = newConfig;
        poolConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit PoolConfigProposed(
            newConfig.seniorRateBps,
            newConfig.markStalenessLimit,
            newConfig.seniorFrozenLpFeeBps,
            newConfig.juniorFrozenLpFeeBps,
            poolConfigActivationTime
        );
    }

    /// @notice Finalizes the proposed pool config after the timelock expires.
    /// @dev If the senior rate changes and the mark is stale, the new rate is applied without accruing stale-window senior yield.
    function finalizePoolConfig() external onlyOwner {
        if (poolConfigActivationTime == 0) {
            revert HousePool__NoProposal();
        }
        if (block.timestamp < poolConfigActivationTime) {
            revert HousePool__TimelockNotReady();
        }
        PoolConfig memory currentConfig = poolConfig;
        PoolConfig memory nextConfig = pendingPoolConfig;
        if (nextConfig.seniorRateBps != currentConfig.seniorRateBps) {
            _checkpointSeniorYieldBeforeRateChange();
        }
        poolConfig = nextConfig;
        delete pendingPoolConfig;
        poolConfigActivationTime = 0;

        if (nextConfig.seniorRateBps != currentConfig.seniorRateBps) {
            emit SeniorRateUpdated(nextConfig.seniorRateBps);
        }
        if (nextConfig.markStalenessLimit != currentConfig.markStalenessLimit) {
            emit MarkStalenessLimitUpdated(nextConfig.markStalenessLimit);
        }
        if (
            nextConfig.seniorFrozenLpFeeBps != currentConfig.seniorFrozenLpFeeBps
                || nextConfig.juniorFrozenLpFeeBps != currentConfig.juniorFrozenLpFeeBps
        ) {
            emit FrozenLpFeesUpdated(nextConfig.seniorFrozenLpFeeBps, nextConfig.juniorFrozenLpFeeBps);
        }
        emit PoolConfigFinalized();
    }

    /// @notice Cancel the pending pool config proposal.
    function cancelPoolConfigProposal() external onlyOwner {
        delete pendingPoolConfig;
        poolConfigActivationTime = 0;
    }

    /// @notice Updates the dedicated emergency pauser.
    /// @dev The owner retains unpause authority and may still pause directly.
    function setPauser(
        address newPauser
    ) external onlyOwner {
        emit PauserUpdated(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pause deposits into both tranches
    function pause() external onlyPauserOrOwner {
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
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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
    /// @dev This admits previously quarantined excess into canonical pool accounting going forward.
    function accountExcess() external onlyOwner {
        uint256 amount = excessAssets();
        if (amount == 0) {
            revert HousePool__NoExcessAssets();
        }
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

    /// @notice Transfers USDC from the pool for protocol-authorized settlement or keeper payments.
    /// @param recipient Address to receive USDC
    /// @param amount USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != orderRouter && msg.sender != ENGINE.settlementModule()) {
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
        if (msg.sender != address(ENGINE) && msg.sender != orderRouter && msg.sender != ENGINE.settlementModule()) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }
        accountedAssets += amount;
        emit ProtocolInflowAccounted(msg.sender, amount, accountedAssets);
    }

    /// @notice Records claimant-owned value into the tranche claimant path.
    /// @dev Revenue and recapitalization remain distinct economic buckets, but share one API.
    function recordClaimantInflow(
        uint256 amount,
        ICfdVault.ClaimantInflowKind kind,
        ICfdVault.ClaimantInflowCashMode cashMode
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != ENGINE.settlementModule()) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }

        if (kind == ICfdVault.ClaimantInflowKind.Recapitalization && msg.sender != address(ENGINE)) {
            revert HousePool__Unauthorized();
        }

        if (cashMode == ICfdVault.ClaimantInflowCashMode.CashArrived) {
            accountedAssets += amount;
        }

        if (kind == ICfdVault.ClaimantInflowKind.Recapitalization) {
            _recordPendingClaimantInflow(kind, amount);
        } else if (seniorPrincipal + juniorPrincipal == 0) {
            _recordPendingClaimantInflow(kind, amount);
        }

        emit ClaimantInflowAccounted(msg.sender, kind, cashMode, amount);
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

        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        _requireBootstrapOracleLive(ctx.statusSnapshot);
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
    /// @dev Mints bootstrap shares so a tranche never becomes ownerless in steady state.
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

        _requireBootstrapOracleLive(_getHousePoolStatusSnapshot());

        uint256 shares = ITrancheVaultBootstrap(targetVault).previewDeposit(amount);
        if (shares == 0) {
            revert HousePool__BootstrapSharesZero();
        }

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
    ) external override(IHousePool, IPerpsLPActions) onlyVault whenNotPaused {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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
    ) external override(IHousePool, IPerpsLPActions) onlyVault {
        if (amount == 0) {
            return;
        }
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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
    ) external override(IHousePool, IPerpsLPActions) onlyVault whenNotPaused {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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
    ) external override(IHousePool, IPerpsLPActions) onlyVault {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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

    function seniorRateBps() public view returns (uint256) {
        return poolConfig.seniorRateBps;
    }

    function markStalenessLimit() public view returns (uint256) {
        return poolConfig.markStalenessLimit;
    }

    function seniorFrozenLpFeeBps() public view returns (uint256) {
        return poolConfig.seniorFrozenLpFeeBps;
    }

    function juniorFrozenLpFeeBps() public view returns (uint256) {
        return poolConfig.juniorFrozenLpFeeBps;
    }

    function isOracleFrozen() public view override returns (bool) {
        return ENGINE.isOracleFrozen();
    }

    function frozenLpFeeBps(
        bool isSenior
    ) public view override returns (uint256) {
        if (!isOracleFrozen()) {
            return 0;
        }
        return isSenior ? poolConfig.seniorFrozenLpFeeBps : poolConfig.juniorFrozenLpFeeBps;
    }

    /// @notice Snapshot of pool liquidity, tranche principals, and oracle health for frontend consumption
    /// @return viewData Struct containing balances, reserves, and status flags
    function getVaultLiquidityView() external view returns (VaultLiquidityView memory viewData) {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            _buildWithdrawalSnapshot(accountingSnapshot, unassignedAssets, false);
        viewData.totalAssetsUsdc = totalAssets();
        viewData.freeUsdc = withdrawalSnapshot.freeUsdc;
        viewData.withdrawalReservedUsdc = withdrawalSnapshot.reserved;
        viewData.pendingRecapitalizationUsdc = pendingRecapitalizationUsdc;
        viewData.pendingTradingRevenueUsdc = pendingTradingRevenueUsdc;
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
        _reconcile(_getHousePoolInputSnapshot());
    }

    function _requireFreshMark(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view {
        if (!HousePoolFreshnessLib.markFresh(accountingSnapshot, statusSnapshot, block.timestamp)) {
            revert HousePool__MarkPriceStale();
        }
    }

    function _requireBootstrapOracleLive(
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal pure {
        if (statusSnapshot.oracleFrozen) {
            revert HousePool__OracleFrozen();
        }
    }

    function _reconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot
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
                _pendingClaimantBucketAssets(),
                poolConfig.seniorRateBps,
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

        _applyPendingClaimantBucketsLive(accountingSnapshot, _getHousePoolStatusSnapshot());
    }

    function _getWithdrawalSnapshot()
        internal
        view
        returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot)
    {
        return _buildWithdrawalSnapshot(_getHousePoolInputSnapshot(), unassignedAssets, false);
    }

    function _buildHousePoolContext(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (HousePoolContext memory ctx) {
        ctx.accountingSnapshot = accountingSnapshot;
        ctx.statusSnapshot = statusSnapshot;
        ctx.pendingState = _previewPendingAccountingState(accountingSnapshot, statusSnapshot);
    }

    function _buildCurrentHousePoolContext() internal view returns (HousePoolContext memory ctx) {
        return _buildHousePoolContext(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
    }

    function _previewPendingAccountingState(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (PendingAccountingState memory pendingState) {
        pendingState.waterfall = _getWaterfallState();
        pendingState.unassignedAssets = unassignedAssets;
        pendingState.seniorSupply = _seniorShareSupply();
        pendingState.juniorSupply = _juniorShareSupply();

        bool markFresh = _markIsFreshForReconcile(accountingSnapshot, statusSnapshot);
        if (markFresh) {
            uint256 yieldElapsed =
                block.timestamp > lastSeniorYieldCheckpointTime ? block.timestamp - lastSeniorYieldCheckpointTime : 0;
            HousePoolReconcilePlanLib.ReconcilePlan memory plan = HousePoolReconcilePlanLib.planReconcile(
                HousePoolPendingPreviewLib.PendingAccountingState({
                    waterfall: pendingState.waterfall,
                    unassignedAssets: pendingState.unassignedAssets,
                    seniorSupply: pendingState.seniorSupply,
                    juniorSupply: pendingState.juniorSupply
                }),
                HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot),
                _pendingClaimantBucketAssets(),
                poolConfig.seniorRateBps,
                yieldElapsed,
                markFresh
            );

            pendingState = PendingAccountingState({
                waterfall: plan.state.waterfall,
                unassignedAssets: plan.state.unassignedAssets,
                seniorSupply: plan.state.seniorSupply,
                juniorSupply: plan.state.juniorSupply
            });

            uint256 juniorRevenueWithoutOwners = HousePoolReconcilePlanLib.juniorRevenueWithoutOwners(plan);
            if (juniorRevenueWithoutOwners > 0) {
                pendingState.waterfall.juniorPrincipal -= juniorRevenueWithoutOwners;
                pendingState.unassignedAssets += juniorRevenueWithoutOwners;
            }
        }

        _applyPendingClaimantBucketsPreview(pendingState);
    }

    function _markIsFreshForReconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
        return HousePoolFreshnessLib.markIsFreshForReconcile(accountingSnapshot, statusSnapshot, block.timestamp);
    }

    function _withdrawalsLive(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
        return HousePoolFreshnessLib.withdrawalsLive(accountingSnapshot, statusSnapshot, block.timestamp);
    }

    function _validatePoolConfig(
        PoolConfig memory config
    ) internal pure {
        if (config.seniorRateBps > 10_000) {
            revert HousePool__InvalidSeniorRate();
        }
        if (config.markStalenessLimit == 0) {
            revert HousePool__ZeroStaleness();
        }
        if (config.seniorFrozenLpFeeBps > MAX_FROZEN_LP_FEE_BPS || config.juniorFrozenLpFeeBps > MAX_FROZEN_LP_FEE_BPS)
        {
            revert HousePool__InvalidFrozenLpFee();
        }
    }

    function _checkpointSeniorYieldBeforeRateChange() internal {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        if (_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            _reconcile(accountingSnapshot);
            return;
        }
        uint256 staleCheckpointTime = statusSnapshot.lastMarkTime > lastSeniorYieldCheckpointTime
            ? statusSnapshot.lastMarkTime
            : lastSeniorYieldCheckpointTime;
        if (seniorPrincipal == 0) {
            lastReconcileTime = staleCheckpointTime;
        }
        _applyPendingClaimantBucketsLive(accountingSnapshot, statusSnapshot);
        lastSeniorYieldCheckpointTime = staleCheckpointTime;
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
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        uint256 reservedUnassignedAssets,
        bool isProjected
    ) internal view returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot) {
        snapshot = HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);
        if (!isProjected) {
            uint256 pendingAssets = _pendingClaimantBucketAssets();
            snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, pendingAssets);
        }
        snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, reservedUnassignedAssets);
    }

    function _checkpointSeniorYieldBeforePrincipalMutation(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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
                seniorPrincipal, poolConfig.seniorRateBps, elapsed
            );
        }

        lastSeniorYieldCheckpointTime = block.timestamp;
    }

    function _applyPendingClaimantBucketsLive(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal {
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets = _getPendingClaimantBuckets();
        if (claimantBuckets.recapitalizationUsdc == 0 && claimantBuckets.revenueUsdc == 0) {
            return;
        }

        HousePoolPendingLivePlanLib.PendingLivePlan memory plan =
            HousePoolPendingLivePlanLib.planApplyPendingClaimantBuckets(
                _copyPendingAccountingState(
                    PendingAccountingState({
                        waterfall: _getWaterfallState(),
                        unassignedAssets: unassignedAssets,
                        seniorSupply: _seniorShareSupply(),
                        juniorSupply: _juniorShareSupply()
                    })
                ),
                seniorPrincipal,
                HousePoolPendingPreviewLib.ClaimantPendingBuckets({
                    recapitalizationUsdc: claimantBuckets.recapitalizationUsdc, revenueUsdc: claimantBuckets.revenueUsdc
                })
            );
        _clearPendingClaimantBuckets();

        if (plan.seniorPrincipalChanged) {
            _checkpointSeniorYieldBeforePrincipalMutation(accountingSnapshot, statusSnapshot);
            plan.state.waterfall.unpaidSeniorYield = unpaidSeniorYield;
        }

        _setWaterfallState(plan.state.waterfall);
        unassignedAssets = plan.state.unassignedAssets;
    }

    function _applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state
    ) internal view {
        HousePoolPendingPreviewLib.PendingAccountingState memory previewState = _copyPendingAccountingState(state);
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets = _getPendingClaimantBuckets();
        HousePoolPendingPreviewLib.applyPendingClaimantBucketsPreview(
            previewState,
            HousePoolPendingPreviewLib.ClaimantPendingBuckets({
                recapitalizationUsdc: claimantBuckets.recapitalizationUsdc, revenueUsdc: claimantBuckets.revenueUsdc
            })
        );
        state.waterfall = previewState.waterfall;
        state.unassignedAssets = previewState.unassignedAssets;
    }

    function _getPendingClaimantBuckets()
        internal
        view
        returns (HousePoolPendingPreviewLib.ClaimantPendingBuckets memory buckets)
    {
        buckets.recapitalizationUsdc = pendingRecapitalizationUsdc;
        buckets.revenueUsdc = pendingTradingRevenueUsdc;
    }

    function _clearPendingClaimantBuckets() internal {
        pendingRecapitalizationUsdc = 0;
        pendingTradingRevenueUsdc = 0;
    }

    function _recordPendingClaimantInflow(
        ICfdVault.ClaimantInflowKind kind,
        uint256 amount
    ) internal {
        if (kind == ICfdVault.ClaimantInflowKind.Recapitalization) {
            pendingRecapitalizationUsdc += amount;
        } else {
            pendingTradingRevenueUsdc += amount;
        }
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

    function _pendingClaimantBucketAssets() internal view returns (uint256) {
        return pendingRecapitalizationUsdc + pendingTradingRevenueUsdc;
    }

    function _getHousePoolInputSnapshot()
        internal
        view
        returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot)
    {
        return ENGINE_PROTOCOL_LENS.getHousePoolInputSnapshot(poolConfig.markStalenessLimit);
    }

    function _getHousePoolStatusSnapshot()
        internal
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot)
    {
        return ENGINE_PROTOCOL_LENS.getHousePoolStatusSnapshot();
    }

    function _getHousePoolSnapshots()
        internal
        view
        returns (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        )
    {
        accountingSnapshot = _getHousePoolInputSnapshot();
        statusSnapshot = _getHousePoolStatusSnapshot();
    }

    function _requireWithdrawalsLive(
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
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

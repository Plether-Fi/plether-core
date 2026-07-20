// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineProtocolLens} from "@plether/perps/interfaces/ICfdEngineProtocolLens.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPerpsLPActions} from "@plether/perps/interfaces/IPerpsLPActions.sol";
import {ITrancheVaultBootstrap} from "@plether/perps/interfaces/ITrancheVaultBootstrap.sol";
import {HousePoolAccountingLib} from "@plether/perps/libraries/HousePoolAccountingLib.sol";
import {HousePoolFreshnessLib} from "@plether/perps/libraries/HousePoolFreshnessLib.sol";
import {HousePoolPendingLivePlanLib} from "@plether/perps/libraries/HousePoolPendingLivePlanLib.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {HousePoolReconcilePlanLib} from "@plether/perps/libraries/HousePoolReconcilePlanLib.sol";
import {HousePoolSeedLifecycleLib} from "@plether/perps/libraries/HousePoolSeedLifecycleLib.sol";
import {HousePoolTrancheGateLib} from "@plether/perps/libraries/HousePoolTrancheGateLib.sol";
import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";
import {HousePoolWithdrawalPreviewLib} from "@plether/perps/libraries/HousePoolWithdrawalPreviewLib.sol";

/// @title HousePool
/// @notice Tranched house pool. Senior tranche gets a junior-funded target coupon with last-loss protection.
///         Junior tranche pays senior carry, absorbs first loss, and captures surplus revenue.
/// @dev Maintains a canonical accounted-asset boundary separate from the raw USDC balance, reserves trader and
///      unassigned claims from LP withdrawals, and prices the two ERC4626 tranche vaults through a senior-first
///      waterfall. Ordinary LP deposits and new trader risk remain disabled until both seed positions exist and
///      the owner activates trading.
/// @custom:security-contact contact@plether.com
contract HousePool is IHousePool, IPerpsLPActions, Ownable2Step, Pausable {

    using SafeERC20 for IERC20;

    /// @dev In-memory projection of tranche accounting after applying a reconcile plan.
    struct PendingAccountingState {
        /// @dev Projected senior principal, junior principal, and senior high-water mark.
        HousePoolWaterfallAccountingLib.WaterfallState waterfall;
        /// @dev Projected ownerless canonical assets, denominated in USDC with 6 decimals.
        uint256 unassignedAssets;
        /// @dev Current senior-vault share supply.
        uint256 seniorSupply;
        /// @dev Current junior-vault share supply.
        uint256 juniorSupply;
    }

    /// @dev Engine snapshots and derived pending state used to keep preview and live accounting aligned.
    struct HousePoolContext {
        /// @dev Engine values used for liquidity and waterfall accounting.
        HousePoolEngineViewTypes.HousePoolInputSnapshot accountingSnapshot;
        /// @dev Engine mark timestamp and runtime-mode flags.
        HousePoolEngineViewTypes.HousePoolStatusSnapshot statusSnapshot;
        /// @dev Projected tranche accounting after applying currently settleable value.
        PendingAccountingState pendingState;
        /// @dev Pending claimant value that remains unsettled and reserved, in 6-decimal USDC.
        uint256 residualPendingClaimantAssets;
    }

    /// @notice USDC token held as pool collateral and used for all accounting amounts.
    IERC20 public immutable USDC;
    /// @notice CfdEngine authorized to settle pool cash flows and provide protocol state.
    ICfdEngineCore public immutable ENGINE;
    /// @notice Accounting lens deployed for engine snapshots consumed by this pool.
    ICfdEngineProtocolLens public immutable ENGINE_PROTOCOL_LENS;

    /// @notice Senior ERC4626 vault authorized to mutate pool tranche accounting.
    address public seniorVault;
    /// @notice Junior ERC4626 vault authorized to mutate pool tranche accounting.
    address public juniorVault;
    /// @notice Account authorized to pause deposits alongside the owner; may be the zero address.
    address public pauser;

    /// @notice Stored senior-tranche claim in USDC (6 decimals), before any pending reconcile preview.
    uint256 public seniorPrincipal;
    /// @notice Stored junior-tranche claim in USDC (6 decimals), before any pending reconcile preview.
    uint256 public juniorPrincipal;
    /// @notice Protected senior claim watermark in USDC (6 decimals), including paid coupon ratchets.
    uint256 public seniorHighWaterMark;
    /// @notice Canonical recognized asset ledger in USDC (6 decimals); `totalAssets()` also caps it by raw cash.
    uint256 public accountedAssets;
    /// @notice Canonical assets without a safe share-owner path, reserved until explicit assignment (6 decimals).
    uint256 public unassignedAssets;
    /// @notice Unsettled claimant recapitalization intent reserved from withdrawals (6-decimal USDC).
    uint256 public pendingRecapitalizationUsdc;
    /// @notice Unsettled claimant trading revenue reserved from withdrawals (6-decimal USDC).
    uint256 public pendingTradingRevenueUsdc;

    /// @notice Deployment time or Unix timestamp of the most recent mark-fresh waterfall reconcile.
    uint256 public lastReconcileTime;
    /// @notice Unix timestamp through which the junior-funded senior coupon clock has been checkpointed.
    uint256 public lastSeniorCouponCheckpointTime;
    /// @dev Active governed pool configuration.
    PoolConfig internal poolConfig;
    /// @notice Maximum configurable frozen-oracle LP fee, in basis points (10%).
    uint256 public constant MAX_FROZEN_LP_FEE_BPS = 1000;
    /// @notice Minimum ordinary tranche deposit or delayed-deposit request, in 6-decimal USDC (1 USDC).
    uint256 public constant MIN_TRANCHE_DEPOSIT_USDC = 1e6;
    /// @notice Whether the owner has activated live trading after both seed positions were initialized.
    bool public override isTradingActive;
    /// @notice Whether the senior tranche's permanent seed position has been initialized.
    bool public seniorSeedInitialized;
    /// @notice Whether the junior tranche's permanent seed position has been initialized.
    bool public juniorSeedInitialized;

    /// @notice Delay between proposing and finalizing pool configuration changes, in seconds.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    /// @notice Most recently proposed pool configuration awaiting finalization.
    /// @dev Rate and fee fields use basis points; `markStalenessLimit` uses seconds. Consult
    ///      `poolConfigActivationTime` to distinguish an active proposal from the zero-value default getter.
    PoolConfig public pendingPoolConfig;
    /// @notice Earliest Unix timestamp at which the pending configuration may be finalized, or zero if none.
    uint256 public poolConfigActivationTime;

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

    /// @notice Deploys a pool and its dedicated engine-accounting lens with the default pool configuration.
    /// @dev Makes the deployer owner, initializes both reconcile clocks, and configures an 8% annual senior
    ///      target rate, a 60-second live mark limit, and 25/75-bps senior/junior frozen-oracle LP fees.
    ///      Deployment neither initializes tranche vaults nor activates trading.
    /// @param _usdc USDC token address used as 6-decimal collateral
    /// @param _engine CfdEngine that manages positions, liabilities, and PnL
    constructor(
        address _usdc,
        address _engine
    ) Ownable(msg.sender) {
        USDC = IERC20(_usdc);
        ENGINE = ICfdEngineCore(_engine);
        ENGINE_PROTOCOL_LENS = ICfdEngineProtocolLens(address(new CfdEngineProtocolLens(_engine)));
        lastReconcileTime = block.timestamp;
        lastSeniorCouponCheckpointTime = block.timestamp;
        poolConfig = PoolConfig({
            seniorRateBps: 800, markStalenessLimit: 60, seniorFrozenLpFeeBps: 25, juniorFrozenLpFeeBps: 75
        });
    }

    // ==========================================
    // ADMIN (set-once pattern)
    // ==========================================

    /// @notice Sets the senior tranche vault address once.
    /// @dev Only the owner may call. The address cannot be zero and cannot be changed after it is set.
    /// @param _vault Senior tranche ERC4626 vault address
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

    /// @notice Sets the junior tranche vault address once.
    /// @dev Only the owner may call. The address cannot be zero and cannot be changed after it is set.
    /// @param _vault Junior tranche ERC4626 vault address
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
    /// @dev Only the owner may call. A valid proposal supersedes any existing proposal and restarts the timelock.
    ///      The annual senior rate is capped at 10,000 bps, mark staleness must be nonzero, and each frozen LP
    ///      fee is capped by `MAX_FROZEN_LP_FEE_BPS`.
    /// @param newConfig Pool configuration to validate and stage; fee and rate fields are in basis points and
    ///        `markStalenessLimit` is in seconds
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
    /// @dev Only the owner may call. Senior-rate changes require a fresh mark under the current staleness limit
    ///      and checkpoint the old coupon rate before the new rate becomes active. Clears the pending proposal
    ///      and emits field-specific update events for values that changed.
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
            _requireRateChangeMarkFresh(_getHousePoolStatusSnapshot());
            _checkpointSeniorCouponBeforeRateChange();
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

    /// @notice Cancels the pending pool config proposal.
    /// @dev Only the owner may call. Also succeeds when no proposal is active.
    function cancelPoolConfigProposal() external onlyOwner {
        delete pendingPoolConfig;
        poolConfigActivationTime = 0;
    }

    /// @notice Updates the dedicated emergency pauser.
    /// @dev Only the owner may call. The owner retains pause and unpause authority; setting zero clears the role.
    /// @param newPauser Account allowed to pause alongside the owner, or the zero address to clear the role
    function setPauser(
        address newPauser
    ) external onlyOwner {
        emit PauserUpdated(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pauses immediate and delayed deposits into both tranches.
    /// @dev Callable by the owner or dedicated pauser. Does not pause withdrawals, reconciliation, or trading.
    function pause() external onlyPauserOrOwner {
        _pause();
    }

    /// @notice Unpauses immediate and delayed deposits into both tranches.
    /// @dev Only the owner may call.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ==========================================
    // IHousePool INTERFACE
    // ==========================================

    /// @notice Canonical economic USDC backing recognized by the pool.
    ///         Unsolicited positive transfers are ignored until explicitly accounted,
    ///         while raw-balance shortfalls still reduce the effective backing.
    /// @return Canonical pool backing, equal to the lesser of raw USDC and `accountedAssets` (6 decimals)
    function totalAssets() public view returns (uint256) {
        uint256 raw = USDC.balanceOf(address(this));
        return raw < accountedAssets ? raw : accountedAssets;
    }

    /// @notice Returns true once both tranche seed positions have been initialized.
    /// @return True when both the senior and junior seed flags are set
    function isSeedLifecycleComplete() public view returns (bool) {
        return HousePoolSeedLifecycleLib.isSeedLifecycleComplete(seniorSeedInitialized, juniorSeedInitialized);
    }

    /// @notice Returns true after either tranche seed position has been initialized.
    /// @return True when at least one tranche seed flag is set
    function hasSeedLifecycleStarted() public view override returns (bool) {
        return HousePoolSeedLifecycleLib.hasSeedLifecycleStarted(seniorSeedInitialized, juniorSeedInitialized);
    }

    /// @notice Returns whether the seed and trading lifecycle permits ordinary tranche deposits.
    /// @dev This lifecycle-only predicate requires both seed positions and owner-activated trading. It does not
    ///      check pause, mark freshness, unassigned assets, open positions, or senior impairment.
    /// @return True when both seed flags and `isTradingActive` are set
    function canAcceptOrdinaryDeposits() public view override returns (bool) {
        return HousePoolSeedLifecycleLib.canAcceptOrdinaryDeposits(
            seniorSeedInitialized, juniorSeedInitialized, isTradingActive
        );
    }

    /// @notice Returns whether a delayed deposit request may be accepted for a tranche.
    /// @dev Requires the ordinary lifecycle to be active, deposits to be unpaused, any required mark to satisfy the
    ///      applicable freshness policy, no live or projected unassigned assets, and no projected senior impairment.
    ///      The current gate is symmetric across both tranches, so `isSenior` does not change the result.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return True when the shared delayed-deposit gate is open
    function canAcceptTrancheDeposits(
        bool isSenior
    ) public view override returns (bool) {
        return _canAcceptTrancheDeposits(isSenior, false);
    }

    /// @notice Returns whether an immediate ERC4626 deposit may be accepted for a tranche.
    /// @dev Applies the delayed-deposit gate and additionally requires that the engine report no open positions.
    ///      The current tranche gate is otherwise symmetric across senior and junior.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return True when an immediate deposit is currently permitted
    function canAcceptInstantTrancheDeposits(
        bool isSenior
    ) public view override returns (bool) {
        return _canAcceptTrancheDeposits(isSenior, true);
    }

    function _canAcceptTrancheDeposits(
        bool,
        bool requireNoOpenPositions
    ) internal view returns (bool) {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        if (requireNoOpenPositions && accountingSnapshot.hasOpenPositions) {
            return false;
        }
        HousePoolContext memory ctx = _buildHousePoolContext(accountingSnapshot, statusSnapshot);
        return HousePoolTrancheGateLib.trancheDepositsAllowed(
            canAcceptOrdinaryDeposits(),
            paused(),
            unassignedAssets,
            _markIsFreshForReconcile(accountingSnapshot, statusSnapshot),
            ctx.pendingState.unassignedAssets + ctx.residualPendingClaimantAssets,
            ctx.pendingState.waterfall.seniorPrincipal,
            ctx.pendingState.waterfall.seniorHighWaterMark
        );
    }

    /// @notice Returns whether the seed and trading lifecycle allows new trader risk.
    /// @dev Requires both seed positions and owner-activated trading; other engine risk checks are separate.
    /// @return True when the lifecycle gate for risk-increasing actions is open
    function canIncreaseRisk() public view override returns (bool) {
        return HousePoolSeedLifecycleLib.canIncreaseRisk(seniorSeedInitialized, juniorSeedInitialized, isTradingActive);
    }

    /// @notice Enables live trading after both tranche seed positions are initialized.
    /// @dev Only the owner may call. Sets `isTradingActive` and emits `TradingActivated`; it does not itself
    ///      validate liquidity or oracle freshness. Repeated calls leave the flag set and emit the event again.
    function activateTrading() external onlyOwner {
        if (!HousePoolSeedLifecycleLib.tradingActivationReady(seniorSeedInitialized, juniorSeedInitialized)) {
            revert HousePool__TradingActivationNotReady();
        }
        isTradingActive = true;
        emit TradingActivated();
    }

    /// @notice Returns the literal USDC balance held by the pool, including unsolicited transfers.
    /// @return Raw token balance in 6-decimal USDC
    function rawAssets() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Returns raw USDC held above the canonical accounted-asset ledger.
    /// @return Unrecognized excess in 6-decimal USDC, floored at zero
    function excessAssets() public view returns (uint256) {
        uint256 raw = rawAssets();
        return raw > accountedAssets ? raw - accountedAssets : 0;
    }

    /// @notice Explicitly converts unsolicited USDC into accounted protocol assets.
    /// @dev Only the owner may call. Admits the entire current excess, checkpoints engine carry indexes before
    ///      changing pool depth, and moves no tokens. Reverts when there is no excess.
    function accountExcess() external onlyOwner {
        uint256 amount = excessAssets();
        if (amount == 0) {
            revert HousePool__NoExcessAssets();
        }
        _checkpointEngineCarryIndexes();
        accountedAssets += amount;
        emit ExcessAccounted(amount, accountedAssets);
    }

    /// @notice Sweeps unsolicited USDC that has not been accounted into protocol economics.
    /// @dev Only the owner may call. Transfers at most `excessAssets()` and does not change `accountedAssets`.
    /// @param recipient Address receiving swept excess USDC
    /// @param amount Excess USDC amount to sweep (6 decimals)
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

    /// @notice Transfers USDC from the pool for protocol-authorized settlement.
    /// @dev Callable only by the engine or its current settlement sidecar. Decreases `accountedAssets` by the
    ///      amount and transfers the same raw USDC; the operation reverts atomically if either balance is short.
    /// @param recipient Address to receive USDC
    /// @param amount USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != ENGINE.settlementSidecar()) {
            revert HousePool__Unauthorized();
        }
        accountedAssets -= amount;
        USDC.safeTransfer(recipient, amount);
    }

    /// @notice Accounts a legitimate protocol-owned inflow into canonical pool assets.
    /// @dev Only the engine or settlement sidecar may use this path. Unlike `accountExcess()`, this does
    ///      not require raw excess to exist: it is the explicit accounting hook for endogenous
    ///      protocol gains and may also be used to restore canonical accounting after a raw-balance
    ///      shortfall has already reduced effective assets through `totalAssets() = min(raw, accounted)`.
    ///      This function does not transfer or verify raw USDC, so the authorized caller must ensure the inflow
    ///      is legitimately backed. A zero amount is a no-op and emits no event.
    /// @param amount USDC amount to add to canonical accounted assets (6 decimals)
    function recordProtocolInflow(
        uint256 amount
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != ENGINE.settlementSidecar()) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }
        accountedAssets += amount;
        emit ProtocolInflowAccounted(msg.sender, amount, accountedAssets);
    }

    /// @notice Records claimant-owned value into the tranche claimant path.
    /// @dev Revenue and recapitalization remain distinct economic buckets, but share one API. The engine or
    ///      settlement sidecar may record revenue; recapitalization is engine-only. `CashArrived` increments
    ///      `accountedAssets`, whereas `AlreadyRetained` only routes ownership. This function never transfers or
    ///      verifies raw USDC. Recapitalization is queued for claimant routing; revenue is explicitly queued when
    ///      both stored tranche principals are zero. A zero amount is a no-op.
    /// @param amount USDC amount to route through claimant accounting (6 decimals)
    /// @param kind Economic source bucket for the claimant inflow
    /// @param cashMode Whether the inflow arrived with this call or was already retained by the pool
    function recordClaimantInflow(
        uint256 amount,
        IHousePool.ClaimantInflowKind kind,
        IHousePool.ClaimantInflowCashMode cashMode
    ) external {
        if (msg.sender != address(ENGINE) && msg.sender != ENGINE.settlementSidecar()) {
            revert HousePool__Unauthorized();
        }
        if (amount == 0) {
            return;
        }

        if (kind == IHousePool.ClaimantInflowKind.Recapitalization && msg.sender != address(ENGINE)) {
            revert HousePool__Unauthorized();
        }

        if (cashMode == IHousePool.ClaimantInflowCashMode.CashArrived) {
            accountedAssets += amount;
        }

        if (kind == IHousePool.ClaimantInflowKind.Recapitalization) {
            _recordPendingClaimantInflow(kind, amount);
        } else if (seniorPrincipal + juniorPrincipal == 0) {
            _recordPendingClaimantInflow(kind, amount);
        }

        emit ClaimantInflowAccounted(msg.sender, kind, cashMode, amount);
    }

    /// @notice Explicitly bootstraps quarantined LP assets into a tranche by minting matching shares.
    /// @dev Only the owner may call. Requires non-frozen oracle mode and the applicable mark-freshness policy,
    ///      reconciles first, assigns the entire resulting `unassignedAssets` balance to the selected tranche,
    ///      and asks its configured vault to mint matching shares. No USDC moves and this does not initialize the
    ///      tranche seed-lifecycle flag. Prevents later LPs from implicitly capturing previously ownerless value.
    /// @param toSenior True to assign assets to senior, false to junior
    /// @param receiver Account receiving bootstrap tranche shares
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
    /// @dev Only the owner may call, once per tranche and only outside oracle-frozen mode. Pulls USDC from the
    ///      owner, increases canonical assets and selected principal, mints shares through the configured vault,
    ///      and locks those shares as its seed floor. Senior seeding also raises the high-water mark. This action
    ///      does not activate trading; both seeds must exist before `activateTrading()` can do so.
    /// @param toSenior True to seed senior, false to seed junior
    /// @param amount Nonzero USDC amount supplied by the owner for the seed (6 decimals)
    /// @param receiver Account receiving permanent seed shares
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

        _checkpointEngineCarryIndexes();
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        accountedAssets += amount;
        if (toSenior) {
            _checkpointSeniorCouponBeforePrincipalMutation();
            seniorPrincipal += amount;
            seniorHighWaterMark += amount;
            seniorSeedInitialized = true;
        } else {
            _checkpointSeniorCouponBeforePrincipalMutation();
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

    /// @notice Deposits USDC into the senior tranche and raises its protected high-water mark.
    /// @dev Only a configured tranche vault may call. Requires at least `MIN_TRANCHE_DEPOSIT_USDC`, an unpaused
    ///      pool, satisfaction of the applicable mark-freshness policy, no pending unassigned-asset bootstrap,
    ///      and unimpaired senior principal after reconciliation. Checkpoints engine carry, pulls USDC from the
    ///      calling vault, and increases both canonical assets and senior principal.
    /// @param amount USDC to deposit (6 decimals)
    function depositSenior(
        uint256 amount
    ) external override(IHousePool, IPerpsLPActions) onlyVault whenNotPaused {
        _requireMinimumTrancheDeposit(amount);
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        _requireNoPendingBootstrap();
        if (seniorPrincipal < seniorHighWaterMark) {
            revert HousePool__SeniorImpaired();
        }
        _checkpointEngineCarryIndexes();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accountedAssets += amount;
        if (seniorPrincipal == 0) {
            _checkpointSeniorCouponBeforePrincipalMutation();
            seniorHighWaterMark = amount;
            seniorPrincipal = amount;
            return;
        }
        _checkpointSeniorCouponBeforePrincipalMutation();
        seniorHighWaterMark += amount;
        seniorPrincipal += amount;
    }

    /// @notice Withdraws USDC from the senior tranche and scales its high-water mark proportionally.
    /// @dev Only a configured tranche vault may call. Reconciles first, requires withdrawals to be outside
    ///      degraded mode and satisfy the applicable mark-freshness policy, and caps the amount by current free
    ///      USDC and senior principal. Checkpoints engine carry, decreases canonical assets, and transfers USDC
    ///      to `receiver`.
    ///      A zero amount is a no-op after caller authorization.
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
        _checkpointEngineCarryIndexes();
        HousePoolWaterfallAccountingLib.WaterfallState memory state = _getWaterfallState();
        HousePoolWaterfallAccountingLib.WaterfallState memory nextState =
            HousePoolWaterfallAccountingLib.scaleSeniorOnWithdraw(state, amount);
        _setWaterfallState(nextState);
        accountedAssets -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    /// @notice Deposits USDC into the junior tranche.
    /// @dev Only a configured tranche vault may call. Requires at least `MIN_TRANCHE_DEPOSIT_USDC`, an unpaused
    ///      pool, satisfaction of the applicable mark-freshness policy, no pending unassigned-asset bootstrap,
    ///      and unimpaired senior principal after reconciliation. Checkpoints engine carry, pulls USDC from the
    ///      calling vault, and increases both canonical assets and junior principal.
    /// @param amount USDC to deposit (6 decimals)
    function depositJunior(
        uint256 amount
    ) external override(IHousePool, IPerpsLPActions) onlyVault whenNotPaused {
        _requireMinimumTrancheDeposit(amount);
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        _reconcile(accountingSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);
        _requireNoPendingBootstrap();
        if (seniorPrincipal < seniorHighWaterMark) {
            revert HousePool__SeniorImpaired();
        }
        _checkpointEngineCarryIndexes();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        accountedAssets += amount;
        juniorPrincipal += amount;
    }

    /// @notice Withdraws USDC from the junior tranche, limited to free USDC above senior's claim.
    /// @dev Only a configured tranche vault may call. Reconciles first, requires withdrawals to be outside
    ///      degraded mode and satisfy the applicable mark-freshness policy, and preserves enough free liquidity
    ///      to cover current senior principal. Checkpoints engine carry, decreases canonical assets and junior
    ///      principal, and transfers USDC to `receiver`.
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
        _checkpointEngineCarryIndexes();
        juniorPrincipal -= amount;
        accountedAssets -= amount;
        USDC.safeTransfer(receiver, amount);
    }

    // ==========================================
    // WITHDRAWAL LIMITS
    // ==========================================

    /// @notice Returns canonical USDC not reserved for protocol or exceptional claimant obligations.
    /// @dev Starts from `totalAssets()` and reserves the larger directional position liability, realized trader
    ///      claims, supplemental engine reserves, pending claimant inflows, and unassigned assets. This accounting
    ///      view does not itself apply degraded-mode or mark-freshness liveness gates.
    /// @return Free USDC available to the tranche withdrawal waterfall (6 decimals)
    function getFreeUSDC() public view returns (uint256) {
        return _getWithdrawalSnapshot().freeUsdc;
    }

    /// @notice Returns the current stored senior principal that pool liquidity permits withdrawing.
    /// @dev Returns zero when degraded mode or the applicable mark-freshness policy disables withdrawals.
    /// @return Withdrawable senior USDC, capped by free USDC and `seniorPrincipal` (6 decimals)
    function getMaxSeniorWithdraw() public view returns (uint256) {
        if (!_withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot())) {
            return 0;
        }
        return HousePoolWithdrawalPreviewLib.seniorWithdrawCap(getFreeUSDC(), seniorPrincipal);
    }

    /// @notice Returns the current stored junior principal that pool liquidity permits withdrawing.
    /// @dev Returns zero when withdrawals are not live and otherwise reserves current senior principal ahead of
    ///      junior. Does not preview pending reconciliation; use `getPendingTrancheState()` for that purpose.
    /// @return Withdrawable junior USDC, capped by residual free USDC and `juniorPrincipal` (6 decimals)
    function getMaxJuniorWithdraw() public view returns (uint256) {
        if (!_withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot())) {
            return 0;
        }
        return HousePoolWithdrawalPreviewLib.juniorWithdrawCap(getFreeUSDC(), seniorPrincipal, juniorPrincipal);
    }

    /// @notice Returns tranche principals and withdrawal caps as if reconcile ran right now.
    /// @dev Read-only preview for ERC4626 consumers that need same-transaction parity with reconcile-first vault
    ///      flows. Includes elapsed senior coupon and any settleable claimant buckets. Mark-dependent waterfall
    ///      changes apply only when the applicable mark is fresh. Residual claimant value and unassigned assets
    ///      remain reserved; both withdrawal caps are zero whenever withdrawals are not live.
    /// @return seniorPrincipalUsdc Simulated senior principal after reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after reconcile (6 decimals)
    /// @return maxSeniorWithdrawUsdc Simulated senior withdrawal cap after reconcile (6 decimals)
    /// @return maxJuniorWithdrawUsdc Simulated junior withdrawal cap after reconcile (6 decimals)
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
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot = _buildWithdrawalSnapshot(
            ctx.accountingSnapshot, ctx.pendingState.unassignedAssets, ctx.residualPendingClaimantAssets
        );
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

    /// @notice Returns tranche principals for deposit pricing as if the deposit-side reconcile ran now.
    /// @dev When mark-dependent reconciliation is permitted, deposit-side pricing intentionally excludes
    ///      conservative unrealized trader MtM while retaining realized pool losses. Trader-claim liabilities,
    ///      coupon accrual, and settleable claimant-bucket routing remain part of the projection.
    /// @return seniorPrincipalUsdc Simulated senior principal after deposit reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after deposit reconcile (6 decimals)
    function getPendingDepositTrancheState()
        external
        view
        returns (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc)
    {
        HousePoolContext memory ctx = _buildCurrentHousePoolDepositContext();
        seniorPrincipalUsdc = ctx.pendingState.waterfall.seniorPrincipal;
        juniorPrincipalUsdc = ctx.pendingState.waterfall.juniorPrincipal;
    }

    /// @notice Returns whether a reconcile triggered by deposit finalization would leave senior impaired.
    /// @dev Uses the standard conservative reconcile snapshot, including withdrawal-side unrealized MtM, because
    ///      the subsequent pool deposit performs that reconcile before accepting assets.
    /// @return True when projected senior principal is below its projected high-water mark
    function isSeniorImpairedAfterPendingDepositReconcile() external view returns (bool) {
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        return ctx.pendingState.waterfall.seniorPrincipal < ctx.pendingState.waterfall.seniorHighWaterMark;
    }

    /// @notice Returns whether withdrawals are live under current mark freshness and runtime mode.
    /// @dev This is a status gate only: a true result does not guarantee nonzero liquidity, unlocked vault shares,
    ///      or satisfaction of the vault's holder cooldown.
    /// @return True when the engine is not degraded and any required mark is sufficiently fresh
    function isWithdrawalLive() external view returns (bool) {
        return _withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
    }

    /// @notice Returns the configured annualized senior target coupon rate.
    /// @return Annual coupon rate in basis points
    function seniorRateBps() public view returns (uint256) {
        return poolConfig.seniorRateBps;
    }

    /// @notice Returns the pool-configured live mark staleness limit used by reconcile and withdrawal policy.
    /// @dev The engine staleness limit may make the effective live limit more restrictive; frozen mode uses the
    ///      engine's separate frozen-window policy.
    /// @return Pool mark staleness limit in seconds
    function markStalenessLimit() public view returns (uint256) {
        return poolConfig.markStalenessLimit;
    }

    /// @notice Returns the configured senior LP fee for oracle-frozen entry and exit.
    /// @return Configured senior frozen-oracle fee in basis points
    function seniorFrozenLpFeeBps() public view returns (uint256) {
        return poolConfig.seniorFrozenLpFeeBps;
    }

    /// @notice Returns the configured junior LP fee for oracle-frozen entry and exit.
    /// @return Configured junior frozen-oracle fee in basis points
    function juniorFrozenLpFeeBps() public view returns (uint256) {
        return poolConfig.juniorFrozenLpFeeBps;
    }

    /// @notice Returns whether the engine reports frozen-oracle mode.
    /// @return True when the engine's market calendar reports the oracle-frozen window
    function isOracleFrozen() public view override returns (bool) {
        return ENGINE.isOracleFrozen();
    }

    /// @notice Returns the active frozen-oracle LP fee for a tranche, or zero outside frozen mode.
    /// @dev TrancheVault applies this same-tranche fee to ERC4626 entry and exit quotes; it is retained for
    ///      incumbent LPs rather than paid to the protocol treasury.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return Active fee in basis points, or zero when the oracle is not frozen
    function frozenLpFeeBps(
        bool isSenior
    ) public view override returns (uint256) {
        if (!isOracleFrozen()) {
            return 0;
        }
        return isSenior ? poolConfig.seniorFrozenLpFeeBps : poolConfig.juniorFrozenLpFeeBps;
    }

    /// @notice Returns the minimum assets accepted by ordinary immediate or delayed tranche deposits.
    /// @return Minimum deposit in 6-decimal USDC (1 USDC)
    function minTrancheDepositUsdc() external pure override returns (uint256) {
        return MIN_TRANCHE_DEPOSIT_USDC;
    }

    /// @notice Returns current pool liquidity, stored tranche principals, and engine health for frontends.
    /// @dev Principal fields are stored values rather than pending-reconcile projections. `freeUsdc` and
    ///      `withdrawalReservedUsdc` include unassigned and pending claimant reservations.
    /// @return viewData Balances and reserves in 6-decimal USDC, plus current mark and runtime status flags
    function getPoolLiquidityView() external view returns (PoolLiquidityView memory viewData) {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot = _getHousePoolInputSnapshot();
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        HousePoolAccountingLib.WithdrawalSnapshot memory withdrawalSnapshot =
            _buildWithdrawalSnapshot(accountingSnapshot, unassignedAssets, _pendingClaimantBucketAssets());
        viewData.totalAssetsUsdc = totalAssets();
        viewData.freeUsdc = withdrawalSnapshot.freeUsdc;
        viewData.withdrawalReservedUsdc = withdrawalSnapshot.reserved;
        viewData.pendingRecapitalizationUsdc = pendingRecapitalizationUsdc;
        viewData.pendingTradingRevenueUsdc = pendingTradingRevenueUsdc;
        viewData.seniorPrincipalUsdc = seniorPrincipal;
        viewData.juniorPrincipalUsdc = juniorPrincipal;
        viewData.seniorHighWaterMarkUsdc = seniorHighWaterMark;
        viewData.markFresh = HousePoolFreshnessLib.markFresh(accountingSnapshot, statusSnapshot, block.timestamp);
        viewData.oracleFrozen = statusSnapshot.oracleFrozen;
        viewData.degradedMode = statusSnapshot.degradedMode;
    }

    // ==========================================
    // RECONCILIATION (Revenue & Loss Waterfall)
    // ==========================================

    /// @notice Reconciles canonical pool value through the senior/junior waterfall.
    /// @dev Only a configured tranche vault may call. Checkpoints the senior coupon, capped by available junior
    ///      principal; with a sufficiently fresh required mark, restores impaired senior principal before routing
    ///      surplus to junior and applies losses junior-first, senior-last. If the required mark is stale, skips
    ///      mark-dependent revenue/loss repricing but still advances the coupon checkpoint and may route
    ///      already-funded pending claimant buckets. Updates `lastReconcileTime` only for a mark-fresh reconcile.
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

    function _requireRateChangeMarkFresh(
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view {
        if (!HousePoolAccountingLib.isMarkFresh(
                statusSnapshot.lastMarkTime, poolConfig.markStalenessLimit, block.timestamp
            )) {
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

    function _requireMinimumTrancheDeposit(
        uint256 amount
    ) internal pure {
        if (amount < MIN_TRANCHE_DEPOSIT_USDC) {
            revert HousePool__DepositTooSmall();
        }
    }

    function _checkpointEngineCarryIndexes() internal {
        ENGINE.checkpointCarryIndexes();
    }

    function _reconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot
    ) internal {
        uint256 couponElapsed =
            block.timestamp > lastSeniorCouponCheckpointTime ? block.timestamp - lastSeniorCouponCheckpointTime : 0;
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        bool markFresh = _markIsFreshForReconcile(accountingSnapshot, statusSnapshot);
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets = _getPendingClaimantBuckets();
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets =
            _settleablePendingClaimantBuckets(reconcileSnapshot, claimantBuckets);
        bool allowRevenueContinuation = seniorPrincipal + juniorPrincipal != 0;
        HousePoolReconcilePlanLib.ReconcilePlan memory plan = HousePoolReconcilePlanLib.planReconcile(
            HousePoolPendingPreviewLib.PendingAccountingState({
                waterfall: _getWaterfallState(),
                unassignedAssets: unassignedAssets,
                seniorSupply: _seniorShareSupply(),
                juniorSupply: _juniorShareSupply()
            }),
            reconcileSnapshot,
            _pendingClaimantBucketAssets(settleableClaimantBuckets),
            poolConfig.seniorRateBps,
            couponElapsed,
            markFresh
        );

        if (couponElapsed > 0) {
            lastSeniorCouponCheckpointTime = block.timestamp;
        }

        _setWaterfallState(plan.state.waterfall);
        unassignedAssets = plan.state.unassignedAssets;

        if (markFresh) {
            lastReconcileTime = block.timestamp;

            uint256 juniorRevenueWithoutOwners = HousePoolReconcilePlanLib.juniorRevenueWithoutOwners(plan);
            if (juniorRevenueWithoutOwners > 0) {
                juniorPrincipal -= juniorRevenueWithoutOwners;
                unassignedAssets += juniorRevenueWithoutOwners;
            }
        }

        _applyPendingClaimantBucketsLive(settleableClaimantBuckets, claimantBuckets, allowRevenueContinuation);
    }

    function _getWithdrawalSnapshot()
        internal
        view
        returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot)
    {
        return _buildWithdrawalSnapshot(_getHousePoolInputSnapshot(), unassignedAssets, _pendingClaimantBucketAssets());
    }

    function _buildHousePoolContext(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (HousePoolContext memory ctx) {
        return _buildHousePoolContext(accountingSnapshot, statusSnapshot, true);
    }

    function _buildHousePoolContext(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        bool useWithdrawalMtm
    ) internal view returns (HousePoolContext memory ctx) {
        ctx.accountingSnapshot = accountingSnapshot;
        ctx.statusSnapshot = statusSnapshot;
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot = useWithdrawalMtm
            ? HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot)
            : HousePoolAccountingLib.buildDepositReconcileSnapshot(accountingSnapshot);
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets = _getPendingClaimantBuckets();
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets =
            _settleablePendingClaimantBuckets(reconcileSnapshot, claimantBuckets);
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory residualClaimantBuckets =
            HousePoolPendingPreviewLib.subtractClaimantBuckets(claimantBuckets, settleableClaimantBuckets);
        ctx.residualPendingClaimantAssets = _pendingClaimantBucketAssets(residualClaimantBuckets);
        bool allowRevenueContinuation = seniorPrincipal + juniorPrincipal != 0;
        ctx.pendingState = _previewPendingAccountingState(
            accountingSnapshot,
            statusSnapshot,
            reconcileSnapshot,
            settleableClaimantBuckets,
            claimantBuckets,
            allowRevenueContinuation
        );
    }

    function _buildCurrentHousePoolContext() internal view returns (HousePoolContext memory ctx) {
        return _buildHousePoolContext(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot());
    }

    function _buildCurrentHousePoolDepositContext() internal view returns (HousePoolContext memory ctx) {
        return _buildHousePoolContext(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot(), false);
    }

    function _previewPendingAccountingState(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets,
        bool allowRevenueContinuation
    ) internal view returns (PendingAccountingState memory pendingState) {
        pendingState.waterfall = _getWaterfallState();
        pendingState.unassignedAssets = unassignedAssets;
        pendingState.seniorSupply = _seniorShareSupply();
        pendingState.juniorSupply = _juniorShareSupply();

        bool markFresh = _markIsFreshForReconcile(accountingSnapshot, statusSnapshot);
        uint256 couponElapsed =
            block.timestamp > lastSeniorCouponCheckpointTime ? block.timestamp - lastSeniorCouponCheckpointTime : 0;
        HousePoolReconcilePlanLib.ReconcilePlan memory plan = HousePoolReconcilePlanLib.planReconcile(
            HousePoolPendingPreviewLib.PendingAccountingState({
                waterfall: pendingState.waterfall,
                unassignedAssets: pendingState.unassignedAssets,
                seniorSupply: pendingState.seniorSupply,
                juniorSupply: pendingState.juniorSupply
            }),
            reconcileSnapshot,
            _pendingClaimantBucketAssets(settleableClaimantBuckets),
            poolConfig.seniorRateBps,
            couponElapsed,
            markFresh
        );

        pendingState = PendingAccountingState({
            waterfall: plan.state.waterfall,
            unassignedAssets: plan.state.unassignedAssets,
            seniorSupply: plan.state.seniorSupply,
            juniorSupply: plan.state.juniorSupply
        });

        if (markFresh) {
            uint256 juniorRevenueWithoutOwners = HousePoolReconcilePlanLib.juniorRevenueWithoutOwners(plan);
            if (juniorRevenueWithoutOwners > 0) {
                pendingState.waterfall.juniorPrincipal -= juniorRevenueWithoutOwners;
                pendingState.unassignedAssets += juniorRevenueWithoutOwners;
            }
        }

        _applyPendingClaimantBucketsPreview(
            pendingState, settleableClaimantBuckets, claimantBuckets, allowRevenueContinuation
        );
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

    function _checkpointSeniorCouponBeforeRateChange() internal {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        if (_markIsFreshForReconcile(accountingSnapshot, statusSnapshot)) {
            _reconcile(accountingSnapshot);
            return;
        }
        _checkpointSeniorCouponBeforePrincipalMutation();
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets = _getPendingClaimantBuckets();
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets =
            _settleablePendingClaimantBuckets(reconcileSnapshot, claimantBuckets);
        bool allowRevenueContinuation = seniorPrincipal + juniorPrincipal != 0;
        _applyPendingClaimantBucketsLive(settleableClaimantBuckets, claimantBuckets, allowRevenueContinuation);
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
        uint256 reservedPendingClaimantAssets
    ) internal pure returns (HousePoolAccountingLib.WithdrawalSnapshot memory snapshot) {
        snapshot = HousePoolAccountingLib.buildWithdrawalSnapshot(accountingSnapshot);
        snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, reservedPendingClaimantAssets);
        snapshot = HousePoolWithdrawalPreviewLib.reserveAssets(snapshot, reservedUnassignedAssets);
    }

    function _checkpointSeniorCouponBeforePrincipalMutation() internal {
        uint256 couponElapsed =
            block.timestamp > lastSeniorCouponCheckpointTime ? block.timestamp - lastSeniorCouponCheckpointTime : 0;
        if (couponElapsed == 0) {
            return;
        }

        if (seniorPrincipal == 0) {
            lastSeniorCouponCheckpointTime = block.timestamp;
            return;
        }

        if (_juniorShareSupply() > 0) {
            (HousePoolWaterfallAccountingLib.WaterfallState memory state,) = HousePoolWaterfallAccountingLib.paySeniorCoupon(
                _getWaterfallState(), poolConfig.seniorRateBps, couponElapsed
            );
            _setWaterfallState(state);
        }

        lastSeniorCouponCheckpointTime = block.timestamp;
    }

    function _applyPendingClaimantBucketsLive(
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets,
        bool allowRevenueContinuation
    ) internal {
        if (_pendingClaimantBucketAssets(settleableClaimantBuckets) == 0) {
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
                HousePoolPendingPreviewLib.ClaimantPendingBuckets({
                    recapitalizationUsdc: settleableClaimantBuckets.recapitalizationUsdc,
                    revenueUsdc: settleableClaimantBuckets.revenueUsdc
                }),
                claimantBuckets,
                allowRevenueContinuation
            );
        _decreasePendingClaimantBuckets(settleableClaimantBuckets);

        _setWaterfallState(plan.state.waterfall);
        unassignedAssets = plan.state.unassignedAssets;
    }

    function _applyPendingClaimantBucketsPreview(
        PendingAccountingState memory state,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets,
        bool allowRevenueContinuation
    ) internal pure {
        HousePoolPendingPreviewLib.PendingAccountingState memory previewState = _copyPendingAccountingState(state);
        HousePoolPendingPreviewLib.applyPendingClaimantBucketsPreview(
            previewState,
            HousePoolPendingPreviewLib.ClaimantPendingBuckets({
                recapitalizationUsdc: settleableClaimantBuckets.recapitalizationUsdc,
                revenueUsdc: settleableClaimantBuckets.revenueUsdc
            }),
            claimantBuckets,
            allowRevenueContinuation
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

    function _decreasePendingClaimantBuckets(
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets
    ) internal {
        pendingRecapitalizationUsdc -= claimantBuckets.recapitalizationUsdc;
        pendingTradingRevenueUsdc -= claimantBuckets.revenueUsdc;
    }

    function _recordPendingClaimantInflow(
        IHousePool.ClaimantInflowKind kind,
        uint256 amount
    ) internal {
        if (kind == IHousePool.ClaimantInflowKind.Recapitalization) {
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
        return _pendingClaimantBucketAssets(_getPendingClaimantBuckets());
    }

    function _pendingClaimantBucketAssets(
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets
    ) internal pure returns (uint256) {
        return HousePoolPendingPreviewLib.claimantBucketAssets(claimantBuckets);
    }

    function _settleablePendingClaimantBuckets(
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot,
        HousePoolPendingPreviewLib.ClaimantPendingBuckets memory claimantBuckets
    ) internal pure returns (HousePoolPendingPreviewLib.ClaimantPendingBuckets memory settleableClaimantBuckets) {
        return HousePoolPendingPreviewLib.capClaimantBuckets(claimantBuckets, reconcileSnapshot.distributable);
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

    function _getWaterfallState() internal view returns (HousePoolWaterfallAccountingLib.WaterfallState memory state) {
        state.seniorPrincipal = seniorPrincipal;
        state.juniorPrincipal = juniorPrincipal;
        state.seniorHighWaterMark = seniorHighWaterMark;
    }

    function _setWaterfallState(
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal {
        seniorPrincipal = state.seniorPrincipal;
        juniorPrincipal = state.juniorPrincipal;
        seniorHighWaterMark = state.seniorHighWaterMark;
    }

    }

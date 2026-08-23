// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
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
import {HousePoolRedemptionMathLib} from "@plether/perps/libraries/HousePoolRedemptionMathLib.sol";
import {HousePoolSeedLifecycleLib} from "@plether/perps/libraries/HousePoolSeedLifecycleLib.sol";
import {HousePoolSeniorCapacityLib} from "@plether/perps/libraries/HousePoolSeniorCapacityLib.sol";
import {HousePoolTrancheGateLib} from "@plether/perps/libraries/HousePoolTrancheGateLib.sol";
import {HousePoolWaterfallAccountingLib} from "@plether/perps/libraries/HousePoolWaterfallAccountingLib.sol";
import {HousePoolWithdrawalPreviewLib} from "@plether/perps/libraries/HousePoolWithdrawalPreviewLib.sol";

/// @dev Pool-only queue hooks implemented by both asynchronous tranche vaults.
interface ITrancheVaultEpochSettlement {

    function getMaturedRedeemHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 remainingShares);

    function fundRedeemEpoch(
        uint256 epochId,
        uint256 shares,
        uint256 assets
    ) external;

    function refundRedeemEpochRemainder(
        uint256 epochId,
        uint256 expectedShares
    ) external returns (uint256 shares);

    function getMaturedDepositHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 assets);

    function quoteDepositFromState(
        uint256 assets,
        uint256 pricingAssets,
        uint256 pricingSupply,
        uint256 feeBps
    ) external view returns (uint256 shares);

    /// @dev A zero `shares` value rejects the epoch into its refundable state without moving its escrowed assets.
    function finalizeDepositEpochFromPool(
        uint256 epochId,
        uint256 shares
    ) external returns (uint256 assets);

}

/// @title HousePool
/// @notice Tranched house pool. Senior tranche gets a junior-funded target coupon with last-loss protection.
///         Junior tranche pays senior carry, absorbs first loss, and captures surplus revenue.
/// @dev Maintains a canonical accounted-asset boundary separate from the raw USDC balance, reserves trader and
///      unassigned claims from LP withdrawals, and prices the two asynchronous tranche vaults through a senior-first
///      waterfall. Ordinary LP deposits and new trader risk remain disabled until both seed positions exist and
///      the owner activates trading.
/// @custom:security-contact contact@plether.com
contract HousePool is IHousePool, IPerpsLPActions, Ownable2Step, Pausable, ReentrancyGuardTransient {

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

    /// @dev Frozen pricing inputs and aggregate output for one tranche's redemption phase.
    struct RedemptionPhase {
        uint256 pricingPrincipal;
        uint256 pricingSupply;
        uint256 budget;
        uint256 fundedShares;
        uint256 fundedAssets;
        uint256 processedEpochs;
        bool backlog;
    }

    /// @dev Frozen pricing inputs and aggregate output for one tranche's deposit phase.
    struct DepositPhase {
        uint256 pricingAssets;
        uint256 pricingSupply;
        uint256 acceptedAssets;
        uint256 mintedShares;
        uint256 processedEpochs;
        bool backlog;
    }

    /// @notice A configured vault returned data or moved funds inconsistently with its advertised queue head.
    error HousePool__VaultSettlementInvariant();

    /// @notice Emitted after one permissionless, atomic LP epoch clearing pass.
    event LpEpochSettled(
        uint256 indexed cutoffEpoch,
        uint256 seniorRedeemAssets,
        uint256 juniorRedeemAssets,
        uint256 juniorDepositAssets,
        uint256 seniorDepositAssets,
        bool seniorBacklog,
        bool juniorBacklog,
        bool entriesDeferred
    );

    /// @notice USDC token held as pool collateral and used for all accounting amounts.
    IERC20 public immutable USDC;
    /// @notice CfdEngine authorized to settle pool cash flows and provide protocol state.
    ICfdEngineCore public immutable ENGINE;
    /// @notice Accounting lens deployed for engine snapshots consumed by this pool.
    ICfdEngineProtocolLens public immutable ENGINE_PROTOCOL_LENS;

    /// @notice Senior asynchronous vault authorized to mutate pool tranche accounting.
    address public seniorVault;
    /// @notice Junior asynchronous vault authorized to mutate pool tranche accounting.
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
    /// @notice Accepted senior delayed-deposit assets not yet cancelled or finalized (6-decimal USDC).
    uint256 public override reservedSeniorDepositAssetsUsdc;
    /// @notice Explicit terminal LP deficit captured by the most recent mark-fresh reconcile (6-decimal USDC).
    uint256 public override terminalDeficitUsdc;

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
    /// @notice Duration shared by delayed LP deposit and redemption epochs.
    uint256 public constant LP_EPOCH_DURATION = 1 hours;
    /// @notice Maximum nonempty epochs examined in any tranche phase of one coordinated settlement.
    uint256 public constant MAX_LP_EPOCHS_PER_PHASE = 16;
    /// @notice Whether the owner has activated live trading after both seed positions were initialized.
    bool public override isTradingActive;
    /// @notice Whether the senior tranche's permanent seed position has been initialized.
    bool public seniorSeedInitialized;
    /// @notice Whether the junior tranche's permanent seed position has been initialized.
    bool public juniorSeedInitialized;

    /// @notice Delay between proposing and finalizing pool configuration changes, in seconds.
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    /// @notice Most recently proposed pool configuration awaiting finalization.
    /// @dev Rate, fee, and share fields use basis points; `markStalenessLimit` uses seconds and maximum senior
    ///      exposure uses 6-decimal USDC. Consult `poolConfigActivationTime` to distinguish an active proposal from
    ///      the zero-value default getter.
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

    modifier onlySeniorVault() {
        if (msg.sender != seniorVault) {
            revert HousePool__NotSeniorVault();
        }
        _;
    }

    /// @notice Deploys a pool and its dedicated engine-accounting lens with the default pool configuration.
    /// @dev Makes the deployer owner, initializes both reconcile clocks, and configures an 8% annual senior
    ///      target rate, a 60-second live mark limit, and 25/75-bps senior/junior frozen-oracle LP fees. Senior
    ///      capacity starts at neutral unbounded sentinels that governance must replace before trading activation.
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
            seniorRateBps: 800,
            markStalenessLimit: 60,
            seniorFrozenLpFeeBps: 25,
            juniorFrozenLpFeeBps: 75,
            maxSeniorExposureUsdc: type(uint256).max,
            maxSeniorShareBps: 10_000
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
    ///      fee is capped by `MAX_FROZEN_LP_FEE_BPS`. Senior-capacity proposals must replace both constructor-only
    ///      unbounded sentinels; zero limits are permitted to close senior admission.
    /// @param newConfig Pool configuration to validate and stage; fee, rate, and share fields are in basis points,
    ///        `markStalenessLimit` is in seconds, and maximum senior exposure is in 6-decimal USDC
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
            newConfig.maxSeniorExposureUsdc,
            newConfig.maxSeniorShareBps,
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
        if (
            nextConfig.maxSeniorExposureUsdc != currentConfig.maxSeniorExposureUsdc
                || nextConfig.maxSeniorShareBps != currentConfig.maxSeniorShareBps
        ) {
            emit SeniorCapacityUpdated(nextConfig.maxSeniorExposureUsdc, nextConfig.maxSeniorShareBps);
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

    /// @notice Returns the current shared LP epoch id.
    /// @return Current Unix timestamp divided by the one-hour LP epoch duration.
    function currentLpEpoch() public view override returns (uint256) {
        return block.timestamp / LP_EPOCH_DURATION;
    }

    /// @notice Returns the activation timestamp for a shared LP epoch.
    /// @param epochId Shared LP epoch id.
    /// @return Epoch start timestamp in Unix seconds.
    function lpEpochStart(
        uint256 epochId
    ) public pure override returns (uint256) {
        return epochId * LP_EPOCH_DURATION;
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
    ///      Senior requests additionally require at least one minimum deposit of remaining governed capacity.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return True when the shared delayed-deposit gate is open
    function canAcceptTrancheDeposits(
        bool isSenior
    ) public view override returns (bool) {
        return _canAcceptTrancheDeposits(isSenior);
    }

    function _canAcceptTrancheDeposits(
        bool isSenior
    ) internal view returns (bool) {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        if (_entryStatusBlocked(accountingSnapshot, statusSnapshot)) {
            return false;
        }
        HousePoolContext memory ctx = _buildHousePoolContext(accountingSnapshot, statusSnapshot);
        if (isSenior
                ? ctx.pendingState.waterfall.seniorPrincipal == 0 && ctx.pendingState.seniorSupply != 0
                : ctx.pendingState.waterfall.juniorPrincipal == 0 && ctx.pendingState.juniorSupply != 0) {
            return false;
        }
        bool commonGateOpen = HousePoolTrancheGateLib.trancheDepositsAllowed(
            canAcceptOrdinaryDeposits(),
            paused(),
            unassignedAssets,
            _markIsFreshForReconcile(accountingSnapshot, statusSnapshot),
            ctx.pendingState.unassignedAssets + ctx.residualPendingClaimantAssets,
            ctx.pendingState.waterfall.seniorPrincipal,
            ctx.pendingState.waterfall.seniorHighWaterMark
        );
        if (!commonGateOpen) {
            return false;
        }
        return !isSenior || _seniorDepositCapacity(ctx.pendingState.waterfall) >= MIN_TRANCHE_DEPOSIT_USDC;
    }

    /// @notice Returns whether the seed and trading lifecycle allows new trader risk.
    /// @dev Requires both seed positions and owner-activated trading; other engine risk checks are separate.
    /// @return True when the lifecycle gate for risk-increasing actions is open
    function canIncreaseRisk() public view override returns (bool) {
        return HousePoolSeedLifecycleLib.canIncreaseRisk(seniorSeedInitialized, juniorSeedInitialized, isTradingActive);
    }

    /// @notice Enables live trading after both tranche seed positions are initialized.
    /// @dev Only the owner may call. Requires finite governed senior limits and compliant seeded protected exposure.
    ///      It does not itself validate oracle freshness. Repeated calls leave the flag set and emit the event again.
    function activateTrading() external onlyOwner {
        if (!HousePoolSeedLifecycleLib.tradingActivationReady(seniorSeedInitialized, juniorSeedInitialized)) {
            revert HousePool__TradingActivationNotReady();
        }
        if (poolConfig.maxSeniorExposureUsdc == type(uint256).max || poolConfig.maxSeniorShareBps >= 10_000) {
            revert HousePool__SeniorCapacityNotConfigured();
        }
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        if (!_seniorCommitmentsWithinLimits(ctx.pendingState.waterfall)) {
            revert HousePool__ExceedsSeniorDepositCapacity();
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
        if (toSenior) {
            _requireSeniorDepositCapacity(amount, _getWaterfallState());
        }

        address targetVault = toSenior ? seniorVault : juniorVault;
        if (targetVault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        uint256 shares = ITrancheVaultBootstrap(targetVault).quoteBootstrapDeposit(amount);
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

        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot = _getHousePoolStatusSnapshot();
        _requireBootstrapOracleLive(statusSnapshot);
        if (toSenior) {
            _reconcile(_getHousePoolInputSnapshot());
        }

        uint256 shares = ITrancheVaultBootstrap(targetVault).quoteBootstrapDeposit(amount);
        if (shares == 0) {
            revert HousePool__BootstrapSharesZero();
        }

        _checkpointEngineCarryIndexes();
        _checkpointSeniorCouponBeforePrincipalMutation();
        if (toSenior) {
            _requireSeniorDepositCapacity(amount, _getWaterfallState());
        }
        USDC.safeTransferFrom(msg.sender, address(this), amount);

        accountedAssets += amount;
        if (toSenior) {
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

    /// @notice Reserves governed capacity for a delayed senior deposit request.
    /// @dev Uses the same conservative pending accounting projection as final admission. The exact configured senior
    ///      vault is the only authorized caller.
    function reserveSeniorDeposit(
        uint256 amount
    ) external override(IHousePool, IPerpsLPActions) onlySeniorVault whenNotPaused {
        _requireMinimumTrancheDeposit(amount);
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        _requireSeniorDepositCapacity(amount, ctx.pendingState.waterfall);
        reservedSeniorDepositAssetsUsdc += amount;
    }

    /// @notice Releases capacity after a delayed senior deposit request is cancelled.
    /// @dev Deliberately remains callable while deposits are paused so escrowed funds retain an exit path.
    function releaseSeniorDepositReservation(
        uint256 amount
    ) external override(IHousePool, IPerpsLPActions) onlySeniorVault {
        if (amount > reservedSeniorDepositAssetsUsdc) {
            revert HousePool__InsufficientSeniorDepositReservation();
        }
        reservedSeniorDepositAssetsUsdc -= amount;
    }

    /// @notice Clears matured LP epochs using Router-bound mark data whenever open positions require atomic refresh.
    /// @dev No-position and oracle-frozen settlement remain permissionless from the cached mark. With live or FAD-only
    ///      open positions, the caller must be the Router and its exact Engine-cached mark must not predate the epoch.
    function settleLpEpoch(
        uint256 expectedMarkPrice,
        uint256 expectedPublishTime
    ) external override nonReentrant returns (IHousePool.LpEpochSettlementResult memory result) {
        (
            HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
            HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
        ) = _getHousePoolSnapshots();
        uint256 cutoffEpoch = block.timestamp / LP_EPOCH_DURATION;
        if (accountingSnapshot.hasOpenPositions && !statusSnapshot.oracleFrozen) {
            if (
                msg.sender != ENGINE.orderRouter() || ENGINE.lastMarkPrice() != expectedMarkPrice
                    || statusSnapshot.lastMarkTime != expectedPublishTime
            ) {
                revert HousePool__Unauthorized();
            }
            if (expectedPublishTime / LP_EPOCH_DURATION < cutoffEpoch) {
                revert HousePool__MarkPriceStale();
            }
        }
        return _settleLpEpoch(accountingSnapshot, statusSnapshot, cutoffEpoch);
    }

    /// @dev Shared bounded settlement body. The caller supplies exactly one Engine snapshot pair and epoch cutoff.
    function _settleLpEpoch(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot,
        uint256 cutoffEpoch
    ) internal returns (IHousePool.LpEpochSettlementResult memory result) {
        if (seniorVault == address(0) || juniorVault == address(0)) {
            revert HousePool__ZeroAddress();
        }
        _requireWithdrawalsLive(statusSnapshot);
        _requireFreshMark(accountingSnapshot, statusSnapshot);

        _reconcile(accountingSnapshot, statusSnapshot);
        _checkpointEngineCarryIndexes();

        result.cutoffEpoch = cutoffEpoch;
        RedemptionPhase memory juniorPhase;
        juniorPhase.pricingPrincipal = juniorPrincipal;
        juniorPhase.pricingSupply = _juniorShareSupply();
        uint256 freeUsdc =
            _buildWithdrawalSnapshot(accountingSnapshot, unassignedAssets, _pendingClaimantBucketAssets()).freeUsdc;

        RedemptionPhase memory seniorPhase = RedemptionPhase({
            pricingPrincipal: seniorPrincipal,
            pricingSupply: _seniorShareSupply(),
            budget: _min(freeUsdc, seniorPrincipal),
            fundedShares: 0,
            fundedAssets: 0,
            processedEpochs: 0,
            backlog: false
        });
        seniorPhase = _fundRedemptionPhase(
            seniorVault, result.cutoffEpoch, seniorPhase, _settlementFeeBps(true, statusSnapshot.oracleFrozen)
        );
        if (seniorPhase.fundedAssets > 0) {
            HousePoolWaterfallAccountingLib.WaterfallState memory nextState =
                HousePoolWaterfallAccountingLib.scaleSeniorOnWithdraw(
                    _getWaterfallState(), seniorPhase.fundedAssets, seniorPhase.fundedShares, seniorPhase.pricingSupply
                );
            _setWaterfallState(nextState);
            accountedAssets -= seniorPhase.fundedAssets;
            freeUsdc -= seniorPhase.fundedAssets;
        }
        result.seniorFundedShares = seniorPhase.fundedShares;
        result.seniorFundedAssets = seniorPhase.fundedAssets;
        result.seniorProcessedEpochs = seniorPhase.processedEpochs;
        result.seniorBacklog = seniorPhase.backlog;

        bool seniorWorkCapHit = seniorPhase.processedEpochs == MAX_LP_EPOCHS_PER_PHASE && seniorPhase.backlog
            && seniorPhase.fundedAssets < seniorPhase.budget;
        if (seniorWorkCapHit) {
            result.juniorBacklog = _hasMaturedRedeemHead(juniorVault, result.cutoffEpoch);
            result.entriesDeferred = _hasMaturedDepositHead(result.cutoffEpoch);
            _emitLpEpochSettled(result, 0);
            return result;
        }

        if (seniorPhase.backlog) {
            juniorPhase.backlog = _hasMaturedRedeemHead(juniorVault, result.cutoffEpoch);
        } else {
            uint256 ratioCap = HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(
                seniorPrincipal, seniorHighWaterMark, juniorPrincipal, poolConfig.maxSeniorShareBps
            );
            juniorPhase.budget = _min(freeUsdc, _min(juniorPrincipal, ratioCap));
            juniorPhase = _fundRedemptionPhase(
                juniorVault, result.cutoffEpoch, juniorPhase, _settlementFeeBps(false, statusSnapshot.oracleFrozen)
            );
            if (juniorPhase.fundedAssets > 0) {
                juniorPrincipal -= juniorPhase.fundedAssets;
                accountedAssets -= juniorPhase.fundedAssets;
            }
        }
        result.juniorFundedShares = juniorPhase.fundedShares;
        result.juniorFundedAssets = juniorPhase.fundedAssets;
        result.juniorProcessedEpochs = juniorPhase.processedEpochs;
        result.juniorBacklog = juniorPhase.backlog;

        bool juniorWorkCapHit = juniorPhase.processedEpochs == MAX_LP_EPOCHS_PER_PHASE && juniorPhase.backlog
            && juniorPhase.fundedAssets < juniorPhase.budget;
        if (juniorWorkCapHit) {
            result.entriesDeferred = _hasMaturedDepositHead(result.cutoffEpoch);
            _emitLpEpochSettled(result, 0);
            return result;
        }

        if (paused()) {
            result.entriesDeferred = _hasMaturedDepositHead(result.cutoffEpoch);
            _emitLpEpochSettled(result, 0);
            return result;
        }
        if (!_entriesMaySettle(accountingSnapshot, statusSnapshot)) {
            result.entriesDeferred = _hasMaturedDepositHead(result.cutoffEpoch);
            _emitLpEpochSettled(result, 0);
            return result;
        }

        DepositPhase memory juniorDepositPhase;
        juniorDepositPhase.pricingAssets = juniorPrincipal;
        juniorDepositPhase.pricingSupply = _juniorShareSupply();
        bool juniorActivationDeferred = juniorDepositPhase.pricingAssets == 0 && juniorDepositPhase.pricingSupply != 0;
        if (!juniorActivationDeferred) {
            juniorDepositPhase = _settleDepositPhase(juniorVault, result.cutoffEpoch, juniorDepositPhase, 0, false);
        }
        result.juniorDepositAssets = juniorDepositPhase.acceptedAssets;
        result.juniorDepositShares = juniorDepositPhase.mintedShares;
        if (juniorDepositPhase.backlog) {
            result.entriesDeferred = true;
            _emitLpEpochSettled(result, juniorDepositPhase.processedEpochs);
            return result;
        }

        DepositPhase memory seniorDepositPhase;
        seniorDepositPhase.pricingAssets = seniorPrincipal;
        seniorDepositPhase.pricingSupply = _seniorShareSupply();
        bool seniorActivationDeferred = seniorDepositPhase.pricingAssets == 0 && seniorDepositPhase.pricingSupply != 0;
        if (!seniorActivationDeferred) {
            seniorDepositPhase = _settleDepositPhase(seniorVault, result.cutoffEpoch, seniorDepositPhase, 0, true);
        }
        result.seniorDepositAssets = seniorDepositPhase.acceptedAssets;
        result.seniorDepositShares = seniorDepositPhase.mintedShares;
        result.entriesDeferred = seniorDepositPhase.backlog
            || ((juniorActivationDeferred || seniorActivationDeferred) && _hasMaturedDepositHead(result.cutoffEpoch));

        _emitLpEpochSettled(result, juniorDepositPhase.processedEpochs + seniorDepositPhase.processedEpochs);
    }

    function _fundRedemptionPhase(
        address vaultAddress,
        uint256 cutoffEpoch,
        RedemptionPhase memory phase,
        uint256 feeBps
    ) internal returns (RedemptionPhase memory) {
        ITrancheVaultEpochSettlement vault = ITrancheVaultEpochSettlement(vaultAddress);
        while (phase.processedEpochs < MAX_LP_EPOCHS_PER_PHASE) {
            (uint256 epochId, uint256 remainingShares) = vault.getMaturedRedeemHead(cutoffEpoch);
            if (remainingShares == 0) {
                break;
            }

            uint256 fullHeadAssets = HousePoolRedemptionMathLib.netAssetsForShares(
                remainingShares, phase.pricingPrincipal, phase.pricingSupply, 1, 1000, feeBps
            );
            if (fullHeadAssets == 0) {
                // A prior burn can make the next head valuable under the canonical post-burn state even when the
                // phase's frozen quote rounds to zero. Leave it queued for a fresh settlement rather than refunding it.
                if (phase.fundedShares != 0) {
                    break;
                }
                uint256 supplyBeforeRefund = IERC20(vaultAddress).totalSupply();
                uint256 escrowSharesBeforeRefund = IERC20(vaultAddress).balanceOf(vaultAddress);
                uint256 poolAssetsBeforeRefund = rawAssets();
                uint256 vaultAssetsBeforeRefund = USDC.balanceOf(vaultAddress);
                if (vault.refundRedeemEpochRemainder(epochId, remainingShares) != remainingShares) {
                    revert HousePool__VaultSettlementInvariant();
                }
                if (IERC20(vaultAddress).totalSupply() != supplyBeforeRefund) {
                    revert HousePool__VaultSettlementInvariant();
                }
                if (IERC20(vaultAddress).balanceOf(vaultAddress) != escrowSharesBeforeRefund) {
                    revert HousePool__VaultSettlementInvariant();
                }
                if (rawAssets() != poolAssetsBeforeRefund) {
                    revert HousePool__VaultSettlementInvariant();
                }
                if (USDC.balanceOf(vaultAddress) != vaultAssetsBeforeRefund) {
                    revert HousePool__VaultSettlementInvariant();
                }
                phase.processedEpochs += 1;
                continue;
            }
            if (phase.fundedAssets >= phase.budget) {
                break;
            }

            (uint256 fundedShares, uint256 fundedAssets) = HousePoolRedemptionMathLib.maxSharesForNetBudget(
                phase.budget - phase.fundedAssets,
                remainingShares,
                phase.pricingPrincipal,
                phase.pricingSupply,
                1,
                1000,
                feeBps
            );
            if (fundedShares == 0 || fundedAssets == 0) {
                break;
            }

            uint256 supplyBefore = IERC20(vaultAddress).totalSupply();
            uint256 escrowAssetsBefore = USDC.balanceOf(vaultAddress);
            USDC.safeTransfer(vaultAddress, fundedAssets);
            vault.fundRedeemEpoch(epochId, fundedShares, fundedAssets);
            if (USDC.balanceOf(vaultAddress) != escrowAssetsBefore + fundedAssets) {
                revert HousePool__VaultSettlementInvariant();
            }
            uint256 supplyAfter = IERC20(vaultAddress).totalSupply();
            if (supplyAfter > supplyBefore) {
                revert HousePool__VaultSettlementInvariant();
            }
            if (supplyBefore - supplyAfter != fundedShares) {
                revert HousePool__VaultSettlementInvariant();
            }
            phase.fundedShares += fundedShares;
            phase.fundedAssets += fundedAssets;
            phase.processedEpochs += 1;
            if (fundedShares < remainingShares) {
                break;
            }
        }
        phase.backlog = _hasMaturedRedeemHead(vaultAddress, cutoffEpoch);
        return phase;
    }

    function _settleDepositPhase(
        address vaultAddress,
        uint256 cutoffEpoch,
        DepositPhase memory phase,
        uint256 feeBps,
        bool isSenior
    ) internal returns (DepositPhase memory) {
        ITrancheVaultEpochSettlement vault = ITrancheVaultEpochSettlement(vaultAddress);
        while (phase.processedEpochs < MAX_LP_EPOCHS_PER_PHASE) {
            (uint256 epochId, uint256 epochAssets) = vault.getMaturedDepositHead(cutoffEpoch);
            if (epochAssets == 0) {
                break;
            }
            if (isSenior && !_seniorCommitmentsWithinLimits(_getWaterfallState())) {
                break;
            }

            // Quote the cumulative batch and mint only its marginal delta so retained-fee pricing is split-neutral.
            uint256 cumulativeShares = vault.quoteDepositFromState(
                phase.acceptedAssets + epochAssets, phase.pricingAssets, phase.pricingSupply, feeBps
            );
            uint256 shares = _saturatingSubtract(cumulativeShares, phase.mintedShares);
            if (shares == 0) {
                uint256 rawBeforeRejection = rawAssets();
                uint256 supplyBeforeRejection = IERC20(vaultAddress).totalSupply();
                uint256 rejectedAssets = vault.finalizeDepositEpochFromPool(epochId, 0);
                if (
                    rejectedAssets != epochAssets || rawAssets() != rawBeforeRejection
                        || IERC20(vaultAddress).totalSupply() != supplyBeforeRejection
                ) {
                    revert HousePool__VaultSettlementInvariant();
                }
                if (isSenior) {
                    if (epochAssets > reservedSeniorDepositAssetsUsdc) {
                        revert HousePool__VaultSettlementInvariant();
                    }
                    reservedSeniorDepositAssetsUsdc -= epochAssets;
                }
                phase.processedEpochs += 1;
                continue;
            }

            uint256 rawBefore = rawAssets();
            uint256 supplyBefore = IERC20(vaultAddress).totalSupply();
            uint256 settledAssets = vault.finalizeDepositEpochFromPool(epochId, shares);
            uint256 supplyAfter = IERC20(vaultAddress).totalSupply();
            if (
                settledAssets != epochAssets || rawAssets() != rawBefore + epochAssets || supplyAfter < supplyBefore
                    || supplyAfter - supplyBefore != shares
            ) {
                revert HousePool__VaultSettlementInvariant();
            }

            accountedAssets += epochAssets;
            if (isSenior) {
                if (epochAssets > reservedSeniorDepositAssetsUsdc) {
                    revert HousePool__VaultSettlementInvariant();
                }
                reservedSeniorDepositAssetsUsdc -= epochAssets;
                seniorPrincipal += epochAssets;
                seniorHighWaterMark += epochAssets;
            } else {
                juniorPrincipal += epochAssets;
            }
            phase.acceptedAssets += epochAssets;
            phase.mintedShares += shares;
            phase.processedEpochs += 1;
        }
        phase.backlog = _hasMaturedDepositHead(vaultAddress, cutoffEpoch);
        return phase;
    }

    function _entriesMaySettle(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal view returns (bool) {
        if (_entryStatusBlocked(accountingSnapshot, statusSnapshot)) {
            return false;
        }
        uint256 pendingClaimantAssets = _pendingClaimantBucketAssets();
        uint256 projectedUnassignedAssets = unassignedAssets;
        if (pendingClaimantAssets > type(uint256).max - projectedUnassignedAssets) {
            return false;
        }
        projectedUnassignedAssets += pendingClaimantAssets;
        return HousePoolTrancheGateLib.trancheDepositsAllowed(
            canAcceptOrdinaryDeposits(),
            paused(),
            unassignedAssets,
            _markIsFreshForReconcile(accountingSnapshot, statusSnapshot),
            projectedUnassignedAssets,
            seniorPrincipal,
            seniorHighWaterMark
        );
    }

    function _entryStatusBlocked(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal pure returns (bool) {
        return statusSnapshot.oracleFrozen || statusSnapshot.degradedMode
            || HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot).deficit != 0;
    }

    function _settlementFeeBps(
        bool isSenior,
        bool oracleFrozen
    ) internal view returns (uint256) {
        if (!oracleFrozen) {
            return 0;
        }
        return isSenior ? poolConfig.seniorFrozenLpFeeBps : poolConfig.juniorFrozenLpFeeBps;
    }

    function _hasMaturedRedeemHead(
        address vaultAddress,
        uint256 cutoffEpoch
    ) internal view returns (bool) {
        (, uint256 remainingShares) = ITrancheVaultEpochSettlement(vaultAddress).getMaturedRedeemHead(cutoffEpoch);
        return remainingShares != 0;
    }

    function _hasMaturedDepositHead(
        uint256 cutoffEpoch
    ) internal view returns (bool) {
        return _hasMaturedDepositHead(seniorVault, cutoffEpoch) || _hasMaturedDepositHead(juniorVault, cutoffEpoch);
    }

    function _hasMaturedDepositHead(
        address vaultAddress,
        uint256 cutoffEpoch
    ) internal view returns (bool) {
        (, uint256 assets) = ITrancheVaultEpochSettlement(vaultAddress).getMaturedDepositHead(cutoffEpoch);
        return assets != 0;
    }

    function _emitLpEpochSettled(
        IHousePool.LpEpochSettlementResult memory result,
        uint256 depositProcessedEpochs
    ) internal {
        if (result.seniorProcessedEpochs == 0 && result.juniorProcessedEpochs == 0 && depositProcessedEpochs == 0) {
            revert HousePool__NoLpEpochProgress();
        }
        emit LpEpochSettled(
            result.cutoffEpoch,
            result.seniorFundedAssets,
            result.juniorFundedAssets,
            result.juniorDepositAssets,
            result.seniorDepositAssets,
            result.seniorBacklog,
            result.juniorBacklog,
            result.entriesDeferred
        );
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _juniorSettlementCapacity(
        uint256 freeUsdc,
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal view returns (uint256) {
        uint256 ratioCap = HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(
            state.seniorPrincipal, state.seniorHighWaterMark, state.juniorPrincipal, poolConfig.maxSeniorShareBps
        );
        return _min(freeUsdc, _min(state.juniorPrincipal, ratioCap));
    }

    function _saturatingSubtract(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a > b ? a - b : 0;
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

    /// @notice Returns stored-state capacity available to matured junior redemption demand.
    /// @dev Returns zero when settlement is not live or matured senior demand is queued ahead of junior. Otherwise it
    ///      does not reserve dormant senior principal: free cash, junior principal, and the protected-senior share
    ///      covenant independently cap the result. Does not preview pending reconciliation.
    /// @return Junior funding capacity in USDC, before controller-specific queue limits
    function getMaxJuniorWithdraw() public view returns (uint256) {
        if (!_withdrawalsLive(_getHousePoolInputSnapshot(), _getHousePoolStatusSnapshot())) {
            return 0;
        }
        if (seniorVault != address(0) && _hasMaturedRedeemHead(seniorVault, currentLpEpoch())) {
            return 0;
        }
        return _juniorSettlementCapacity(getFreeUSDC(), _getWaterfallState());
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
        if (seniorVault == address(0) || !_hasMaturedRedeemHead(seniorVault, currentLpEpoch())) {
            maxJuniorWithdrawUsdc = _juniorSettlementCapacity(withdrawalSnapshot.freeUsdc, ctx.pendingState.waterfall);
        }
    }

    /// @notice Returns tranche principals for deposit pricing under the canonical terminal-NAV reconcile.
    /// @dev Entry and exit project the same signed, collateral-capped terminal price delta, trader claims, coupon
    ///      accrual, realized value, and settleable claimant-bucket routing from one Engine snapshot.
    /// @return seniorPrincipalUsdc Simulated senior principal after deposit reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after deposit reconcile (6 decimals)
    function getPendingDepositTrancheState()
        external
        view
        returns (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc)
    {
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        seniorPrincipalUsdc = ctx.pendingState.waterfall.seniorPrincipal;
        juniorPrincipalUsdc = ctx.pendingState.waterfall.juniorPrincipal;
    }

    /// @notice Returns whether a reconcile triggered by deposit finalization would leave senior impaired.
    /// @dev Uses the same signed terminal-NAV snapshot that settlement reconciles before accepting assets.
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

    /// @notice Returns the governed protected senior-exposure ceiling.
    function maxSeniorExposureUsdc() public view returns (uint256) {
        return poolConfig.maxSeniorExposureUsdc;
    }

    /// @notice Returns the governed maximum senior share of committed tranche capital.
    function maxSeniorShareBps() public view returns (uint256) {
        return poolConfig.maxSeniorShareBps;
    }

    /// @notice Returns additional senior admission capacity after conservative pending reconciliation.
    /// @dev Accepted reservations consume capacity. Residual capacity below the ordinary 1-USDC minimum is reported
    ///      as zero so vault maximum-entry views cannot quote an amount that execution rejects.
    function getSeniorDepositCapacity() public view override returns (uint256) {
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        uint256 capacity = _seniorDepositCapacity(ctx.pendingState.waterfall);
        return capacity >= MIN_TRANCHE_DEPOSIT_USDC ? capacity : 0;
    }

    /// @notice Returns whether projected protected exposure plus every accepted reservation fits active limits.
    function areSeniorDepositReservationsWithinLimits() public view override returns (bool) {
        HousePoolContext memory ctx = _buildCurrentHousePoolContext();
        return _seniorCommitmentsWithinLimits(ctx.pendingState.waterfall);
    }

    /// @notice Returns the configured senior LP exit fee for oracle-frozen settlement.
    /// @return Configured senior frozen-oracle fee in basis points
    function seniorFrozenLpFeeBps() public view returns (uint256) {
        return poolConfig.seniorFrozenLpFeeBps;
    }

    /// @notice Returns the configured junior LP exit fee for oracle-frozen settlement.
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
    /// @dev TrancheVault applies this same-tranche fee to exit quotes; entry requests and activations are unavailable
    ///      while the oracle is frozen. The fee is retained for incumbent LPs rather than paid to the protocol treasury.
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
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
        viewData.currentTerminalDeficitUsdc = reconcileSnapshot.deficit;
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

    function _requireSeniorDepositCapacity(
        uint256 amount,
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal view {
        if (amount > _seniorDepositCapacity(state)) {
            revert HousePool__ExceedsSeniorDepositCapacity();
        }
    }

    function _seniorDepositCapacity(
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal view returns (uint256) {
        return HousePoolSeniorCapacityLib.depositCapacity(
            state.seniorPrincipal,
            state.seniorHighWaterMark,
            state.juniorPrincipal,
            reservedSeniorDepositAssetsUsdc,
            poolConfig.maxSeniorExposureUsdc,
            poolConfig.maxSeniorShareBps
        );
    }

    function _seniorCommitmentsWithinLimits(
        HousePoolWaterfallAccountingLib.WaterfallState memory state
    ) internal view returns (bool) {
        return HousePoolSeniorCapacityLib.commitmentsWithinLimits(
            state.seniorPrincipal,
            state.seniorHighWaterMark,
            state.juniorPrincipal,
            reservedSeniorDepositAssetsUsdc,
            poolConfig.maxSeniorExposureUsdc,
            poolConfig.maxSeniorShareBps
        );
    }

    function _checkpointEngineCarryIndexes() internal {
        ENGINE.checkpointCarryIndexes();
    }

    function _reconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot
    ) internal {
        _reconcile(accountingSnapshot, _getHousePoolStatusSnapshot());
    }

    function _reconcile(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot,
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory statusSnapshot
    ) internal {
        uint256 couponElapsed =
            block.timestamp > lastSeniorCouponCheckpointTime ? block.timestamp - lastSeniorCouponCheckpointTime : 0;
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
            terminalDeficitUsdc = reconcileSnapshot.deficit;
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
        ctx.accountingSnapshot = accountingSnapshot;
        ctx.statusSnapshot = statusSnapshot;
        HousePoolAccountingLib.ReconcileSnapshot memory reconcileSnapshot =
            HousePoolAccountingLib.buildReconcileSnapshot(accountingSnapshot);
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
        if (config.maxSeniorExposureUsdc == type(uint256).max) {
            revert HousePool__InvalidMaxSeniorExposure();
        }
        if (config.maxSeniorShareBps >= 10_000) {
            revert HousePool__InvalidMaxSeniorShareBps();
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Two-tranche USDC pool that acts as counterparty to CFD traders.
///         Senior tranche earns a junior-funded target coupon; junior absorbs first-loss and excess profit.
/// @dev Unless stated otherwise, monetary amounts use 6-decimal USDC, rates use a 10,000 basis-point denominator,
///      and timestamps or durations use seconds.
interface IHousePool {

    /// @notice Economic destination used when routing claimant-owned value into the tranche waterfall.
    enum ClaimantInflowKind {
        /// @notice Trading, carry, or spread revenue owned by tranche claimants.
        Revenue,
        /// @notice Owner-funded value intended to recapitalize realized protocol bad debt.
        Recapitalization
    }

    /// @notice Whether claimant inflow accounting should recognize newly arrived cash.
    enum ClaimantInflowCashMode {
        /// @notice Matching USDC has already arrived and canonical accounted assets must increase.
        CashArrived,
        /// @notice Matching USDC is already included in canonical pool assets and only ownership routing changes.
        AlreadyRetained
    }

    /// @notice Pool cash, claimant-reservation, tranche-principal, and runtime-status snapshot.
    /// @param totalAssetsUsdc Canonical pool backing, capped by raw USDC custody.
    /// @param freeUsdc Assets above maximum position liability, trader claims, pending claimant value, unassigned
    ///        assets, and any supplemental reserve.
    /// @param withdrawalReservedUsdc Aggregate amount reserved ahead of tranche withdrawals.
    /// @param pendingRecapitalizationUsdc Unsettled recapitalization value awaiting claimant routing.
    /// @param pendingTradingRevenueUsdc Unsettled trading revenue awaiting claimant routing.
    /// @param seniorPrincipalUsdc Stored value attributed to senior tranche claimants.
    /// @param juniorPrincipalUsdc Stored value attributed to junior tranche claimants.
    /// @param seniorHighWaterMarkUsdc Protected senior entitlement restored before revenue reaches junior claimants.
    /// @param markFresh Whether the cached mark satisfies the currently applicable HousePool freshness policy.
    /// @param oracleFrozen Whether the engine reports recurring or override-driven frozen-oracle policy.
    /// @param degradedMode Whether the engine's adjusted-insolvency latch is active.
    struct PoolLiquidityView {
        uint256 totalAssetsUsdc;
        uint256 freeUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 pendingRecapitalizationUsdc;
        uint256 pendingTradingRevenueUsdc;
        uint256 seniorPrincipalUsdc;
        uint256 juniorPrincipalUsdc;
        uint256 seniorHighWaterMarkUsdc;
        bool markFresh;
        bool oracleFrozen;
        bool degradedMode;
    }

    /// @notice Governed senior coupon, live-mark, and frozen-oracle LP fee configuration.
    /// @param seniorRateBps Annualized simple senior target coupon rate in basis points.
    /// @param markStalenessLimit HousePool component of the live cached-mark age limit, in seconds.
    /// @param seniorFrozenLpFeeBps Senior vault entry/exit fee while the oracle is frozen, in basis points.
    /// @param juniorFrozenLpFeeBps Junior vault entry/exit fee while the oracle is frozen, in basis points.
    struct PoolConfig {
        uint256 seniorRateBps;
        uint256 markStalenessLimit;
        uint256 seniorFrozenLpFeeBps;
        uint256 juniorFrozenLpFeeBps;
    }

    /// @notice A tranche-accounting mutation was called by an address other than either configured vault.
    error HousePool__NotAVault();
    /// @notice Legacy one-time router configuration was attempted after a router had already been set.
    error HousePool__RouterAlreadySet();
    /// @notice The owner attempted to replace the configured senior vault.
    error HousePool__SeniorVaultAlreadySet();
    /// @notice The owner attempted to replace the configured junior vault.
    error HousePool__JuniorVaultAlreadySet();
    /// @notice A pool settlement or inflow hook was called by neither the engine nor its settlement sidecar.
    error HousePool__Unauthorized();
    /// @notice A requested senior withdrawal exceeds the current senior cap.
    error HousePool__ExceedsMaxSeniorWithdraw();
    /// @notice A requested junior withdrawal exceeds the current subordinated junior cap.
    error HousePool__ExceedsMaxJuniorWithdraw();
    /// @notice An operation requiring fresh mark-dependent accounting received a stale cached mark.
    error HousePool__MarkPriceStale();
    /// @notice Pool configuration finalization was requested before its activation timestamp.
    error HousePool__TimelockNotReady();
    /// @notice Pool configuration finalization was requested without an active proposal.
    error HousePool__NoProposal();
    /// @notice A tranche deposit would proceed while projected senior principal is below its high-water mark.
    error HousePool__SeniorImpaired();
    /// @notice A withdrawal was attempted while engine degraded mode is latched.
    error HousePool__DegradedMode();
    /// @notice A required vault, receiver, or excess-sweep recipient address is zero.
    error HousePool__ZeroAddress();
    /// @notice A proposed live mark-staleness limit is zero.
    error HousePool__ZeroStaleness();
    /// @notice A proposed annual senior coupon exceeds 10,000 basis points.
    error HousePool__InvalidSeniorRate();
    /// @notice A proposed senior or junior frozen LP fee exceeds the configured maximum.
    error HousePool__InvalidFrozenLpFee();
    /// @notice The owner attempted to account excess when raw USDC does not exceed canonical accounted assets.
    error HousePool__NoExcessAssets();
    /// @notice An excess sweep exceeds currently unaccounted raw USDC.
    error HousePool__ExcessAmountTooHigh();
    /// @notice An ordinary deposit was attempted while ownerless assets still require explicit bootstrap assignment.
    error HousePool__PendingBootstrap();
    /// @notice Explicit bootstrap assignment was requested when no unassigned assets remain.
    error HousePool__NoUnassignedAssets();
    /// @notice Bootstrap or seed pricing produced zero shares, or a seed amount was zero.
    error HousePool__BootstrapSharesZero();
    /// @notice The selected tranche's permanent seed position was already initialized.
    error HousePool__SeedAlreadyInitialized();
    /// @notice Trading activation was requested before both tranche seeds were initialized.
    error HousePool__TradingActivationNotReady();
    /// @notice A caller other than the owner or configured pauser attempted to pause.
    error HousePool__UnauthorizedPauser();
    /// @notice Bootstrap or seed initialization was attempted while the oracle was frozen.
    error HousePool__OracleFrozen();
    /// @notice An ordinary tranche deposit or delayed request is below the pool minimum.
    error HousePool__DepositTooSmall();

    /// @notice Legacy event describing a mark-dependent waterfall reconciliation.
    /// @param seniorPrincipal Resulting senior principal in USDC.
    /// @param juniorPrincipal Resulting junior principal in USDC.
    /// @param delta Signed value reconciled: positive for revenue and negative for loss, in USDC.
    event Reconciled(uint256 seniorPrincipal, uint256 juniorPrincipal, int256 delta);
    /// @notice Emitted when finalized governance changes the annual senior target coupon.
    /// @param newRateBps New annual rate in basis points.
    event SeniorRateUpdated(uint256 newRateBps);
    /// @notice Emitted when finalized governance changes the pool's live mark-age component.
    /// @param newLimit New age limit in seconds.
    event MarkStalenessLimitUpdated(uint256 newLimit);
    /// @notice Emitted when a validated pool configuration is staged behind the timelock.
    /// @param seniorRateBps Proposed annual senior coupon in basis points.
    /// @param markStalenessLimit Proposed live mark-age limit in seconds.
    /// @param seniorFrozenLpFeeBps Proposed senior frozen-oracle fee in basis points.
    /// @param juniorFrozenLpFeeBps Proposed junior frozen-oracle fee in basis points.
    /// @param activationTime Earliest Unix timestamp at which the proposal can be finalized.
    event PoolConfigProposed(
        uint256 seniorRateBps,
        uint256 markStalenessLimit,
        uint256 seniorFrozenLpFeeBps,
        uint256 juniorFrozenLpFeeBps,
        uint256 activationTime
    );
    /// @notice Emitted after the active pool configuration is replaced by a matured proposal.
    event PoolConfigFinalized();
    /// @notice Emitted when finalized governance changes either frozen-oracle tranche fee.
    /// @param seniorFeeBps New senior frozen-oracle fee in basis points.
    /// @param juniorFeeBps New junior frozen-oracle fee in basis points.
    event FrozenLpFeesUpdated(uint256 seniorFeeBps, uint256 juniorFeeBps);
    /// @notice Emitted when the owner admits all currently unsolicited raw USDC into canonical accounting.
    /// @param amountUsdc Newly recognized excess in USDC.
    /// @param accountedAssetsUsdc Canonical accounted-asset ledger after recognition, in USDC.
    event ExcessAccounted(uint256 amountUsdc, uint256 accountedAssetsUsdc);
    /// @notice Emitted when the owner transfers unaccounted excess USDC out of the pool.
    /// @param recipient Recipient of the excess.
    /// @param amountUsdc Amount swept without changing canonical accounted assets, in USDC.
    event ExcessSwept(address indexed recipient, uint256 amountUsdc);
    /// @notice Emitted when an authorized integration recognizes a legitimate protocol-owned inflow.
    /// @param caller Authorized engine or settlement sidecar that recorded the inflow.
    /// @param amountUsdc Amount added to canonical accounted assets, in USDC.
    /// @param accountedAssetsUsdc Canonical accounted-asset ledger after the addition, in USDC.
    event ProtocolInflowAccounted(address indexed caller, uint256 amountUsdc, uint256 accountedAssetsUsdc);
    /// @notice Emitted when claimant-owned revenue or recapitalization is routed into pool accounting.
    /// @param caller Authorized engine or settlement sidecar that recorded the inflow.
    /// @param kind Revenue or recapitalization ownership bucket.
    /// @param cashMode Whether canonical accounted assets increased or cash was already retained.
    /// @param amountUsdc Routed claimant value in USDC.
    event ClaimantInflowAccounted(
        address indexed caller, ClaimantInflowKind kind, ClaimantInflowCashMode cashMode, uint256 amountUsdc
    );
    /// @notice Emitted when all quarantined ownerless assets are assigned to a tranche and matching shares are minted.
    /// @param toSenior True when assets were assigned to senior, false for junior.
    /// @param receiver Account receiving bootstrap vault shares.
    /// @param amountUsdc Principal assigned to the tranche, in USDC.
    /// @param sharesMinted Vault shares minted to `receiver`.
    event UnassignedAssetsAssigned(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    /// @notice Emitted when a permanent real-cash seed position is initialized for a tranche.
    /// @param toSenior True when the senior tranche was seeded, false for junior.
    /// @param receiver Account receiving the permanently floored seed shares.
    /// @param amountUsdc Owner-supplied seed principal in USDC.
    /// @param sharesMinted Vault shares minted and registered as the seed floor.
    event SeedPositionInitialized(
        bool indexed toSenior, address indexed receiver, uint256 amountUsdc, uint256 sharesMinted
    );
    /// @notice Emitted when the owner activates trading after both tranche seeds exist.
    event TradingActivated();
    /// @notice Emitted when the dedicated emergency pauser changes.
    /// @param previousPauser Previously configured pauser.
    /// @param newPauser Newly configured pauser, which may be zero.
    event PauserUpdated(address indexed previousPauser, address indexed newPauser);

    /// @notice Canonical economic USDC backing recognized by the pool (6 decimals).
    ///         Ignores unsolicited positive token transfers until explicitly accounted, but
    ///         still reflects raw-balance shortfalls if assets leave the pool unexpectedly.
    /// @return Lesser of raw pool USDC and the canonical accounted-asset ledger
    function totalAssets() external view returns (uint256);

    /// @notice Transfers USDC from the pool to a recipient.
    /// @dev Callable only by the engine or its current settlement sidecar. Decreases canonical accounted assets and
    ///      transfers the same raw amount atomically.
    /// @param recipient Address to receive USDC
    /// @param amount USDC amount to transfer (6 decimals)
    function payOut(
        address recipient,
        uint256 amount
    ) external;

    /// @notice Increases canonical pool assets to recognize a legitimate protocol-owned inflow.
    /// @dev This is the controlled accounting path for endogenous protocol gains that should
    ///      increase economic pool depth. It does not require raw excess to be present and may
    ///      also be used to restore canonical accounting after a raw-balance shortfall has already
    ///      reduced `totalAssets()` via the `min(rawBalance, accountedAssets)` boundary.
    ///      Reverts if the caller is unauthorized. A zero amount is a no-op and emits no event.
    /// @param amount USDC amount to add to canonical accounted assets (6 decimals)
    function recordProtocolInflow(
        uint256 amount
    ) external;

    /// @notice Records claimant-owned value that should ultimately flow through the tranche waterfall.
    /// @dev Callable only by the engine or settlement sidecar; recapitalization is further restricted to the engine.
    ///      `CashArrived` increments canonical accounted assets but does not transfer tokens, so the caller must have
    ///      already delivered the matching USDC. `AlreadyRetained` only routes ownership for value already held by
    ///      the pool. Revenue is quarantined when no tranche principal exists; recapitalization is always queued for
    ///      explicit waterfall reconciliation.
    /// @param amount USDC amount to route through claimant accounting (6 decimals)
    /// @param kind Economic source bucket for the claimant inflow
    /// @param cashMode Whether to recognize newly arrived cash or only route value already in canonical pool assets
    function recordClaimantInflow(
        uint256 amount,
        ClaimantInflowKind kind,
        ClaimantInflowCashMode cashMode
    ) external;

    /// @notice Pool-configured live mark-age limit used outside oracle-frozen mode.
    /// @dev The effective live limit can be tightened by the engine's own limit. FAD-only periods still use live
    ///      policy; the engine's separate `fadMaxStaleness` applies only while the oracle is frozen.
    /// @return Pool live mark-age limit in seconds
    function markStalenessLimit() external view returns (uint256);

    /// @notice Returns true once both tranche seed positions exist.
    /// @return Whether both senior and junior seed flags are set
    function isSeedLifecycleComplete() external view returns (bool);

    /// @notice Total USDC attributed to the senior tranche (6 decimals)
    /// @return Stored senior principal before any pending-reconcile projection
    function seniorPrincipal() external view returns (uint256);

    /// @notice Total USDC attributed to the junior tranche (6 decimals)
    /// @return Stored junior principal before any pending-reconcile projection
    function juniorPrincipal() external view returns (uint256);

    /// @notice Senior high-water mark used to block dilutive recapitalizing deposits.
    /// @return Protected senior entitlement in USDC restored before revenue flows to junior
    function seniorHighWaterMark() external view returns (uint256);

    /// @notice Accounted LP assets currently quarantined pending explicit bootstrap / assignment (6 decimals)
    /// @return Ownerless canonical assets reserved from ordinary LP withdrawals and deposits
    function unassignedAssets() external view returns (uint256);

    /// @notice Pulls USDC from a configured vault and adds it to senior principal.
    /// @dev Reconciles first and requires a configured vault caller, an unpaused pool, the minimum deposit, applicable
    ///      freshness for any required mark, no pending bootstrap, and unimpaired senior principal. Checkpoints engine
    ///      carry and raises the senior high-water mark. End users ordinarily call the senior ERC4626 vault instead.
    /// @param amount USDC amount to deposit (6 decimals)
    function depositSenior(
        uint256 amount
    ) external;

    /// @notice Removes senior principal and transfers USDC to a receiver for a configured vault.
    /// @dev Reconciles first, requires live withdrawals and any required mark to satisfy active freshness policy,
    ///      enforces the senior withdrawal cap, checkpoints carry, and scales the high-water mark pro rata. Zero is a
    ///      no-op after authorization.
    /// @param amount USDC amount to withdraw (6 decimals)
    /// @param receiver Address receiving withdrawn USDC
    function withdrawSenior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Pulls USDC from a configured vault and adds it to junior principal.
    /// @dev Applies the same vault, reconcile, pause, minimum-size, conditional freshness, bootstrap,
    ///      senior-impairment, and carry gates as the senior deposit path. End users ordinarily call the junior ERC4626
    ///      vault instead.
    /// @param amount USDC amount to deposit (6 decimals)
    function depositJunior(
        uint256 amount
    ) external;

    /// @notice Removes junior principal and transfers USDC to a receiver for a configured vault.
    /// @dev Reconciles first, requires live withdrawals and any required mark to satisfy active freshness policy,
    ///      preserves free cash sufficient to cover current senior principal, and checkpoints carry before reducing
    ///      pool depth.
    /// @param amount USDC amount to withdraw (6 decimals)
    /// @param receiver Address receiving withdrawn USDC
    function withdrawJunior(
        uint256 amount,
        address receiver
    ) external;

    /// @notice Explicitly bootstraps quarantined LP assets into a tranche and mints matching shares.
    /// @dev Owner only, outside oracle-frozen mode and with any required mark satisfying active freshness policy.
    ///      Reconciles, assigns the entire unassigned balance, and asks the selected configured vault to mint shares.
    ///      No USDC moves and the tranche seed-lifecycle flag is not initialized by this action.
    /// @param toSenior True to assign assets to senior, false to junior
    /// @param receiver Account receiving bootstrap tranche shares
    function assignUnassignedAssets(
        bool toSenior,
        address receiver
    ) external;

    /// @notice Seeds a tranche with permanent share-backed minimum ownership using real USDC.
    /// @dev Owner only, once per tranche and outside oracle-frozen mode. Pulls real USDC from the owner, increases
    ///      canonical assets and principal, checkpoints engine carry, mints shares, and registers the receiver's
    ///      permanent share floor. Senior seeding also raises its high-water mark. Both seeds are required before
    ///      separate trading activation.
    /// @param toSenior True to seed senior, false to seed junior
    /// @param amount Nonzero USDC amount supplied by the owner for the seed (6 decimals)
    /// @param receiver Nonzero account receiving permanent seed shares
    function initializeSeedPosition(
        bool toSenior,
        uint256 amount,
        address receiver
    ) external;

    /// @notice Returns current stored senior principal that pool liquidity permits withdrawing.
    /// @dev Returns zero when degraded mode or applicable mark freshness disables withdrawals. Does not preview a
    ///      pending reconciliation; use `getPendingTrancheState` for reconcile-first parity.
    /// @return Withdrawable senior USDC capped by free cash and stored senior principal
    function getMaxSeniorWithdraw() external view returns (uint256);

    /// @notice Returns current stored junior principal that pool liquidity permits withdrawing.
    /// @dev Returns zero when withdrawals are not live, otherwise reserves current senior principal ahead of junior.
    ///      Does not preview a pending reconciliation.
    /// @return Withdrawable junior USDC capped by residual free cash and stored junior principal
    function getMaxJuniorWithdraw() external view returns (uint256);

    /// @notice Read-only tranche state as if `reconcile()` ran immediately with current inputs.
    /// @dev Includes elapsed senior coupon and settleable claimant buckets. Mark-dependent repricing applies only when
    ///      the applicable mark is fresh; residual claimant value and unassigned assets remain reserved. Withdrawal
    ///      caps are zero whenever withdrawals are not live.
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
        );

    /// @notice Read-only tranche principals for deposit pricing.
    /// @dev Projects the deposit-side reconcile, which intentionally excludes conservative unrealized trader MtM while
    ///      retaining realized losses. Trader claims, coupon accrual, and settleable claimant routing remain included.
    ///      Immediate vault deposits are disabled while positions are open; delayed epochs may finalize after delay.
    /// @return seniorPrincipalUsdc Simulated senior principal after reconcile (6 decimals)
    /// @return juniorPrincipalUsdc Simulated junior principal after reconcile (6 decimals)
    function getPendingDepositTrancheState()
        external
        view
        returns (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc);

    /// @notice Whether pending deposit finalization would hit the senior impairment gate after reconcile.
    /// @dev Uses the standard conservative reconcile snapshot, including withdrawal-side unrealized MtM.
    /// @return Whether projected senior principal is below its projected high-water mark
    function isSeniorImpairedAfterPendingDepositReconcile() external view returns (bool);

    /// @notice Reconciles canonical pool value through the senior/junior waterfall.
    /// @dev Callable only by a configured vault. Checkpoints the junior-funded senior coupon. With a fresh required
    ///      mark, restores senior impairment before routing revenue to junior and applies losses junior-first. With a
    ///      stale required mark, skips mark-dependent repricing but can still route already-funded pending claimant
    ///      buckets and advance the coupon checkpoint.
    function reconcile() external;

    /// @notice Returns whether the protocol-level withdrawal status gate is open.
    /// @dev A true result does not guarantee nonzero pool liquidity, unlocked vault shares, or an elapsed holder cooldown.
    /// @return Whether the engine is not degraded and any required mark is sufficiently fresh
    function isWithdrawalLive() external view returns (bool);

    /// @notice Returns true after either tranche seed position has been initialized.
    /// @return Whether the senior or junior seed flag is set
    function hasSeedLifecycleStarted() external view returns (bool);

    /// @notice Returns whether the lifecycle permits ordinary tranche deposits.
    /// @dev Requires both seeds and owner-activated trading only; does not check pause, freshness, unassigned assets,
    ///      open positions, or senior impairment.
    /// @return Whether both seed flags and the trading-active flag are set
    function canAcceptOrdinaryDeposits() external view returns (bool);

    /// @notice Returns whether a delayed deposit request may be accepted for a tranche.
    /// @dev Requires the ordinary lifecycle, an unpaused pool, applicable mark freshness, no live or projected
    ///      unassigned assets, and no projected senior impairment. The current gate is symmetric across tranches.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return Whether a delayed deposit request currently passes the shared tranche gate
    function canAcceptTrancheDeposits(
        bool isSenior
    ) external view returns (bool);

    /// @notice Returns whether an immediate ERC4626 deposit may be accepted for a tranche.
    /// @dev Applies the delayed-deposit gate and additionally requires that the engine report no open positions. The
    ///      current gate is otherwise symmetric across tranches.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return Whether an immediate ERC4626 deposit currently passes all pool gates
    function canAcceptInstantTrancheDeposits(
        bool isSenior
    ) external view returns (bool);

    /// @notice Returns whether the seed and trading lifecycle allows new trader risk.
    /// @dev Requires both seeds and owner-activated trading; degraded, oracle, and other engine gates are separate.
    /// @return Whether the lifecycle risk-increase gate is open
    function canIncreaseRisk() external view returns (bool);

    /// @notice Returns whether live trading has been activated.
    /// @return Owner-controlled trading-activation flag
    function isTradingActive() external view returns (bool);

    /// @notice Returns whether the engine reports frozen-oracle mode.
    /// @dev This can be active during the recurring frozen interval or on an admin-configured all-day override.
    /// @return Whether frozen-oracle policy is active
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns the active frozen-oracle LP fee for a tranche, or zero outside frozen mode.
    /// @dev TrancheVault applies this same-tranche fee to ERC4626 entry and exit quotes; the fee is retained for
    ///      incumbent LPs rather than paid to protocol treasury.
    /// @param isSenior True for senior tranche, false for junior tranche
    /// @return Active tranche fee in basis points, or zero when the oracle is not frozen
    function frozenLpFeeBps(
        bool isSenior
    ) external view returns (uint256);

    /// @notice Minimum assets accepted by ordinary ERC4626 tranche deposit/mint flows (6 decimals).
    /// @dev The same floor applies to delayed deposit requests.
    /// @return Minimum accepted asset amount (1 USDC)
    function minTrancheDepositUsdc() external view returns (uint256);

}

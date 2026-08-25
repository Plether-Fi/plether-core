# Emergency Response and Circuit Breaker Guide

This guide is the operator-facing source of truth for Plether perps emergency containment. It describes the controls
that exist today, what each control actually stops, what deliberately remains live, and how an off-chain monitor and
guardian should decide when to use them.

The safety objective is **contain risk expansion without disabling risk reduction or already-funded user exits**.
The protocol therefore does not provide a global stop switch.

## Safety properties

- New trading risk and new LP capital can be stopped together in one atomic guardian transaction.
- A guardian can add restrictions but cannot remove them, change configuration, set prices, or move funds.
- Governance owns recovery and must unpause each component deliberately.
- Trader closes and liquidations remain available through a discretionary pause. This is intentional: an emergency
  operator must not be able to trap traders in open positions.
- LP redemption requests, eligible redemption funding, and funded claims are not disabled by the composite pause.
- Automatic oracle, solvency, freshness, and accounting gates can still make an otherwise unpaused action
  unavailable. "Not paused" never means "guaranteed to succeed."

## Current control inventory

| Control | Activation | What it stops | What remains live | Recovery |
|---|---|---|---|---|
| Composite emergency pause | `EmergencyPauseCoordinator.triggerEmergencyPause(reasonHash,evidenceHash)` by the configured guardian | New opens/increases, every pending open covered by the new persistent cutoff, new LP deposit requests, and deposit activation | Close commits/execution, liquidations, mark refresh, redemption requests, eligible LP settlement/redemption funding, and funded claims | Governance unpauses RouterAdmin and HousePool separately |
| Router risk-off pause | `OrderRouterAdmin.pause()` by its owner or configured pauser | New opens/increases; permanently invalidates pending opens through `riskOffOrderCutoff` | Closes, liquidations, mark refresh, LP settlement, refunds, and claims | RouterAdmin owner calls `unpause()`; the historical cutoff never decreases |
| HousePool entry pause | `HousePool.pause()` by its owner or configured pauser | New Senior and Junior deposit requests and deposit activation | Redemption requests, eligible redemption funding, reconciliation, deposit/redemption claims, and trading | HousePool owner calls `unpause()` |
| Engine degraded mode | Automatically latches when a close or liquidation reveals insufficient adjusted solvency | New opens, position-backed LP redemption funding, and new LP entry through the pool entry gate | Closes, liquidations, mark refresh, recapitalization, redemption requests, and already-funded claims | Engine owner may clear it only after the on-chain solvency check passes |
| Oracle/FAD close-only policy | Automatically derived from the oracle regime and calendar | Opens in FAD or `oracleFrozen`; oracle-dependent actions also fail closed when their price policy is not satisfied | Policy-valid closes, liquidations, mark refresh, and frozen-market LP settlement | Automatic when a valid regime returns; configuration changes remain timelocked |
| LP freshness and accounting gates | Automatically evaluated from canonical Engine and HousePool state | LP settlement/redemption funding when withdrawals are not live; deposit activation on stale marks, deficits, impairment, unassigned assets, or unavailable Senior capacity | Unrelated trading and any claim whose assets or shares were already funded | Automatic after canonical state becomes eligible |

The production recommendation is to use the coordinator for emergency containment. Directly pausing only RouterAdmin
or only HousePool is supported for governance operations, but creates a partial containment state that the operator
must understand and monitor.

## Action matrix

"Available" below means that the named breaker does not prohibit the action. Normal authorization, balance, queue,
epoch, oracle, and invariant checks still apply.

| Protocol action | Composite pause | Engine degraded | Oracle/freshness effect | Important consequence |
|---|---|---|---|---|
| Commit an open or increase | Stopped | Stopped | FAD, frozen, or invalid policy can stop it | No new trading risk is admitted |
| Execute an open covered by the cutoff | Permanently invalid; refundable | Blocked while degraded | Not relevant after cutoff invalidation | Unpause never revives the order |
| Commit or execute a close/reduce | Available | Available | Requires the applicable close policy; frozen closes use the bounded stale regime | There is no discretionary close-off breaker |
| Liquidate | Available | Available | Requires the applicable liquidation oracle policy | Liquidation must remain a risk-reduction path |
| Refresh the Engine mark | Available | Available | Requires a policy-valid oracle update | Needed to restore freshness and LP liveness |
| Recapitalize the clearing layer | Available | Available | Not disabled by the composite pause | Supports degraded-mode recovery |
| Request an LP deposit | Stopped | Stopped by entry preflight | Frozen/stale/deficit and other entry gates can stop it | Applies to both Senior and Junior |
| Activate a pending LP deposit | Stopped/deferred | Stopped/deferred | Entry gates must all pass | Pausing does not automatically make a matured deposit cancellable |
| Claim shares from an activated deposit | Available | Available | No new NAV decision is made at claim time | Already-finalized user property remains claimable |
| Cancel a pending deposit | Available only under its existing cancellation rules | State-dependent | State-dependent | Pool pause itself does not create a new cancellation right |
| Request an LP redemption | Available | Available | Request creation does not require live withdrawal funding | Shares enter the normal epoch queue |
| Cancel an unmatured redemption request | Available under normal epoch rules | Available under normal rules | No special emergency override | Maturity/funding can make cancellation unavailable |
| Settle an LP epoch / fund redemptions | Available | Stopped while withdrawals are not live | Requires the applicable fresh or frozen settlement path | Composite pause is entry-only on the LP side |
| Claim a funded redemption or refund | Available | Available | No fresh NAV decision is required for an already-funded claim | The guardian cannot confiscate or freeze it |
| Clean up invalidated opens | Available and expected | Available | No Pyth payload is required | Refunds margin and bounty to internal settlement; cleanup is bounded and lazy |
| Unpause or clear degraded mode | Guardian cannot | Governance only after solvency | Not automatic for manual pauses | Recovery is deliberately separated from detection |

## When the guardian should trigger composite containment

The monitor should page and prepare a transaction for every suspicious observation, but it should reserve the
composite pause for evidence that protocol integrity, custody, price correctness, or authority may be compromised.
Except during an actively exploited condition, confirm the signal from an independent RPC or data source at the same
block before signing. Evidence collection must not delay containment when the failure is already credible.

### Trigger immediately after minimal independent confirmation

- **Custody or escrow deficit:** Pool custody, Pool asset-boundary, tranche asset escrow, tranche share escrow, seed
  floor, or Senior reservation checks report a real deficit.
- **NAV/accounting integrity failure:** Terminal NAV caps, lots, entry basis, active-empty state, mark domain, or
  aggregate snapshot disagree with canonical Engine state.
- **Binding or queue integrity failure:** A deployed component is bound to an unexpected peer, or canonical queue
  endpoints/state are structurally inconsistent.
- **Arithmetic or temporal impossibility:** A future cached mark or arithmetic-domain fault is confirmed against
  direct contract reads.
- **Oracle integrity compromise:** A signed feed is demonstrably wrong, manipulated, bound to the wrong source, or
  materially diverges from independent trusted markets beyond the incident policy. Routine staleness or low
  confidence alone is not proof of compromise because those states already fail closed.
- **Authority compromise:** There is credible evidence that an admin, keeper, deployment, or signing system is
  executing unauthorized risk-increasing actions or that its keys are compromised.
- **Active exploit or unexplained asset movement:** Transactions are changing collateral, claims, positions, or NAV
  commitments in a way that cannot be reconciled to documented protocol flows.

The recommended stable reason families for the future signer are `CUSTODY_DEFICIT`, `ACCOUNTING_INVARIANT`,
`BINDING_OR_QUEUE_INTEGRITY`, `ORACLE_INTEGRITY`, `AUTHORITY_COMPROMISE`, `ENGINE_INSOLVENCY`, and
`UNKNOWN_UNSAFE_STATE`. Hash the stable reason together with a versioned schema; put the incident bundle hash in
`evidenceHash`.

### Trigger after investigation or repeated corroboration

- The Engine enters degraded mode unexpectedly, the cause is unknown, or solvency cannot be restored promptly.
  Degraded mode already blocks new risk, but composite containment additionally invalidates pending opens and makes
  the incident boundary explicit.
- A terminal deficit persists or changes unexpectedly. The deficit is a serious economic warning, but its mere
  existence is not the same as a broken accounting invariant.
- Required dependency reads fail across independent RPC providers and operators cannot establish a safe canonical
  state. A single Lens or RPC failure is an observability problem, not proof that the protocol is corrupt.
- Oracle confidence, liveness, or cross-source divergence stays abnormal long enough that the configured fail-closed
  policy no longer gives operators sufficient assurance.
- Keeper infrastructure is unavailable while a risk-increasing queue or incident-cleanup backlog is becoming unsafe.
  A brief keeper outage is not enough: triggering risk-off permanently invalidates covered opens.

### Do not trigger solely for these normal states

- `NoMaturedWork`, `AdditionsStillOpen`, or `ObservationCanStillShrink`.
- `NoFreeCash`, matured Senior precedence, Senior capacity exhaustion, or Senior impairment.
- A normal deposit deferral caused by lifecycle state, unassigned assets, capacity, or activation not yet confirmed.
- The scheduled FAD or `oracleFrozen` regime, ordinary mark staleness, or a low-confidence oracle update that the
  on-chain policy correctly rejects.
- Expected bounded queue progress, a non-head request, or a temporary backlog.
- One incomplete `SettlementMonitorLens` response or one failed RPC call.
- `PoolPaused` or `RouterAdminPaused` when it matches a known incident or governance operation.

The monitor must inspect `criticalFaultMask`, dependency masks, operational blockers, warnings, and deposit-deferral
masks independently. A critical fault makes the composite observation incomplete, so watching only a
`completeObservationDigest` can miss the exact condition that should page the guardian.

### Monitor-to-action map

This is the default policy for the current `SettlementMonitorViewTypes` enums. Every signal pages or records
according to its row; none gives the Lens permission to transact by itself.

| Monitor signal | Default off-chain response | Composite pause policy |
|---|---|---|
| `BindingMismatch` | Page immediately; compare immutable/runtime bindings and deployment manifest | Trigger when a direct read confirms an unexpected production binding |
| `RequestWindowMismatch`, `RequestWindowFormula`, `QueueEndpoint`, `ObservedEpochState` | Page immediately; reproduce from direct vault/queue reads at the same block | Trigger when confirmed and the affected request/queue state cannot be proven safe |
| `NavCapMismatch`, `NavLotsMismatch`, `NavEntryBasisMismatch`, `NavActiveEmptyMismatch`, `NavMarkDomain`, `NavSnapshotMismatch` | Page immediately; reconcile NAV-book commitments against canonical Engine state | Trigger after minimal independent confirmation |
| `PoolCustodyDeficit`, `PoolAssetBoundaryMismatch` | Page immediately; reconcile raw token custody, accounted assets, and claimant buckets | Trigger after minimal independent confirmation |
| `SeniorAssetEscrowDeficit`, `SeniorShareEscrowDeficit`, `JuniorAssetEscrowDeficit`, `JuniorShareEscrowDeficit` | Page immediately; reconcile vault balances and pending/funded totals | Trigger after minimal independent confirmation |
| `SeniorSeedFloor`, `JuniorSeedFloor`, `SeniorReservationExceedsEscrow` | Page immediately; verify protected balances and reservations directly | Trigger after minimal independent confirmation |
| `FutureCachedMark`, `ArithmeticDomain` | Page immediately; verify block time, mark state, and every contributing read | Trigger when direct reads confirm an impossible canonical state |
| `EngineDegraded` blocker or `TerminalDeficit` warning | Page and diagnose solvency/cause; continue protective keepers | Trigger if unexpected, unexplained, persistent, or accompanied by another integrity signal |
| `WithdrawalsNotLive`, `CachedMarkStale`, `RequiredOracleInvalid`, `OracleBeforeEpochBoundary` | Route or wait according to the documented settlement policy | Do not trigger solely from this blocker |
| `RequiredDependencyUnknown` or a dependency-mask bit | Retry a block-pinned direct read through independent providers | Trigger only if state remains unknowable and cannot be conservatively established |
| `NoMaturedWork`, `AdditionsStillOpen`, `NoFreeCash`, `MaturedSeniorPrecedence`, `ObservationCanStillShrink` | Record as normal queue/liveness state | Do not trigger solely from this warning |
| `PoolPaused`, `RouterAdminPaused`, `OracleFrozen` | Verify the state matches the incident/calendar record | Do not trigger solely from this warning |
| Any `DepositDeferral` bit | Explain why entry is deferred and monitor persistence | Do not trigger solely from a deferral; escalate only the underlying confirmed fault |

## Guardian runbook

### Before signing

1. Pin reads to an explicit block number and record its block hash, chain id, contract addresses, runtime code hashes,
   active configuration digest, and monitor observation.
2. Re-read the suspected condition through at least one independent RPC. For oracle incidents, preserve the raw
   signed update and independent market evidence.
3. Confirm that the coordinator is bound to the expected RouterAdmin and HousePool, is configured as pauser on both,
   and has the expected guardian.
4. Simulate `triggerEmergencyPause(reasonHash,evidenceHash)` at the pinned state. Zero hashes are valid when the
   incident is urgent or the evidence archive is not ready.
5. Check whether either component is already paused. The coordinator is idempotent, but the prior state belongs in
   the incident record.

### Trigger and verify

1. Submit the coordinator transaction from the guardian. Do not send two independent pause transactions when atomic
   containment is available.
2. Confirm finality according to the incident policy, then verify:
   - `EmergencyPauseTriggered` was emitted by the expected coordinator;
   - RouterAdmin and HousePool both report paused;
   - `riskOffOrderCutoff` equals or exceeds the order tail covered by the incident transaction; and
   - the event's reason, evidence, previous-state, and new-state fields match the signed intent.
3. Page governance and publish the incident boundary. Never describe pending opens at or below the cutoff as
   executable, even after a later unpause.

### Operate while contained

- Keep close, liquidation, mark-refresh, redemption, funded-claim, and recapitalization infrastructure running.
- Run permissionless risk-off cleanup for invalidated opens. Global cleanup handles at most 64 orders per call and
  account cleanup at most 32, so continue until the intended queue range is clean.
- Treat refunded open margin and bounty as internal settlement balances, not immediate wallet transfers. Later valid
  liabilities may consume those balances under normal clearinghouse rules.
- Continue monitoring custody, NAV commitments, oracle state, degraded mode, queue progress, and funded user claims.
- Do not use the incident as justification to block protective paths at the infrastructure layer unless a concrete
  transaction would itself violate a confirmed safety invariant.

### Governance recovery

The guardian must never auto-unpause. Governance should recover only after all of these are true:

1. The root cause is identified, fixed or isolated, and independently reviewed.
2. Contract bindings, custody, escrow, queues, and NAV commitments reconcile at current state.
3. Oracle source and configuration are validated against independent evidence.
4. Healthy observations remain consistent across the agreed number of blocks and providers.
5. The state of every cutoff-invalidated open and any remaining cleanup backlog is understood.
6. Degraded mode, if active, passes the Engine's on-chain solvency check before being cleared.
7. Governance chooses and documents the order of component recovery. Unpausing cannot and must not reset the
   historical `riskOffOrderCutoff`.
8. The guardian is rotated or disabled if its signer, monitor, or surrounding infrastructure was implicated.

## Hard limitations and non-goals

- **The guardian cannot stop traders from closing or reducing positions.** This is an intentional authority limit,
  not an omission. A close may still revert because its oracle, authorization, balance, or invariant requirements do
  not pass; the guarantee is that no discretionary pause bit can disable the close path.
- The composite pause cannot stop liquidations, mark refresh, LP redemption requests, eligible redemption funding,
  funded claims, deposit-share claims, or recapitalization.
- HousePool pause is an LP-entry pause, not a withdrawal freeze. Engine degraded mode or the canonical
  oracle/freshness gate can independently stop new redemption funding, while already-funded claims remain live.
- The monitor is advisory and cannot actuate a breaker. The coordinator does not verify Lens output, reason hashes,
  or evidence hashes on-chain.
- Triggering is economically consequential: every covered pending open is permanently invalid and refunded. Later
  unpause admits only new orders.
- Invalidated opens are cleaned lazily and in bounded batches. The pause does not compact the queue in the trigger
  transaction.
- A matured pending deposit does not become freely cancellable merely because HousePool is paused.
- There is no LP request-off, LP settlement-off, claim-off, arbitrary queue quarantine, emergency price setter, or
  global protocol freeze.
- Calendar and oracle-policy configuration remain governed/timelocked; the guardian cannot invent or override a
  price regime during an incident.
- The coordinator protects only the immutable RouterAdmin and HousePool to which it was deployed. Incorrect bindings
  or missing pauser assignments make the call revert atomically.
- If governance itself is compromised, the guardian can add restrictions but cannot prevent the owner from using
  the owner's existing recovery or configuration authorities. Key security and governance controls remain part of
  the threat model.

## Off-chain monitor and guardian architecture

The next-stage service should separate five responsibilities:

1. **Observer:** performs block-pinned, multi-provider reads and decodes every monitor mask.
2. **Corroborator:** compares direct contract state, independent RPCs, and external oracle evidence.
3. **Policy engine:** classifies the observation as alert-only, prepare/simulate, guardian containment, or governance
   recovery. It must use versioned, reviewed rules rather than an opaque score.
4. **Guardian signer:** holds only the coordinator trigger authority and signs the exact simulated calldata. It has no
   unpause or configuration key.
5. **Incident keeper:** cleans invalidated opens and keeps protective protocol paths operating after containment.

The signer should require a payload containing the reason schema version, reason family, evidence digest, observed
block number/hash, chain id, coordinator address, component bindings, observation/configuration digests, and
simulation result. The service should alert on every decision and transaction, rate-limit duplicate submissions,
handle reorgs explicitly, and verify post-transaction state before declaring containment successful.

Future circuit breakers must be designed separately rather than inferred from the current coordinator. Plausible
follow-ups are LP request-off, LP settlement-off for confirmed settlement-accounting corruption, and bounded queue
quarantine. Each would remove a currently preserved liveness property, so it needs its own trigger threshold,
least-authority role, expiry/recovery semantics, and proof that user funds cannot be trapped unnecessarily. A
claim-off or discretionary trader-close pause should be treated as a much more dangerous design and is intentionally
absent.

## Canonical references

- `EmergencyPauseCoordinator.sol`: composite guardian authority and incident event.
- `OrderRouterAdmin.sol`: Router pause, ownership, and persistent risk-off cutoff.
- `HousePool.sol`: LP-entry pause, settlement, and withdrawal gates.
- `CfdEngine.sol`: degraded-mode latch and solvency-gated recovery.
- `SettlementMonitorLens.sol` and `SettlementMonitorViewTypes.sol`: advisory observations and fault masks.
- `DEPLOYMENT.md`: deployment wiring and transaction-level containment procedure.
- `SECURITY.md`: trust boundaries, invariants, and security assumptions.

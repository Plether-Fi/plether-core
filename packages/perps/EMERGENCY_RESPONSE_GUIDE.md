# Emergency Response and Circuit Breaker Guide

This guide explains the on-chain containment controls, the actions they leave available, and the operator response
to an incident. The contracts enforce the restrictions; monitoring and the suggested response policy below are
off-chain responsibilities. Deployment wiring is covered in [Deployment](DEPLOYMENT.md).

The safety objective is **contain the affected transition without disabling risk reduction or already-funded user
exits**. Plether therefore provides granular breakers, not a global protocol stop.

## Safety properties

- The guardian has three fixed actions: trading-risk plus LP-entry risk-off, LP-settlement-only hold, and atomic full
  containment. It cannot supply an arbitrary restriction mask.
- The guardian can add restrictions but cannot remove them, change configuration, set prices, move funds, or invoke
  arbitrary targets.
- Manual restrictions have no automatic expiry. Governance must release each component deliberately.
- Trader closes/reductions and liquidations are deliberately unpausable. An emergency operator must not be able to
  trap traders in open positions.
- Deposit-share claims and already-funded redemption claims are deliberately unpausable because they make no new NAV
  or funding decision.
- Automatic oracle, solvency, freshness, accounting, authorization, balance, and queue gates can still make an
  otherwise unpaused action unavailable. "Allowed by the breaker" is not a repair or execution guarantee.

## Control inventory

| Guardian action | Restrictions added | Governance recovery |
| --- | --- | --- |
| `triggerEmergencyPause(reasonHash,evidenceHash)` | Router risk-off plus HousePool entry pause | RouterAdmin owner calls `unpause()`; HousePool owner separately calls `unpause()` |
| `triggerLpEpochSettlementHold(reasonHash,evidenceHash)` | HousePool LP epoch settlement hold | HousePool owner calls `unpauseLpEpochSettlement()` |
| `triggerFullContainment(reasonHash,evidenceHash)` | All three restrictions, atomically | Release each component separately through its owner |

Each component owner or configured pauser may also activate its own `pause()` or `pauseLpEpochSettlement()` directly.
The deploy script installs the coordinator as both pausers; its owner sets the guardian. Do not assign the guardian
directly as both pausers and assume the calls will be atomic. Coordinator calls skip restrictions already active;
a failure in any required downstream action reverts all changes made by that call.

Router risk-off permanently invalidates pending opens through the inclusive `riskOffOrderCutoff` captured from the
committed order tail. Unpause permits later commits but never revives a covered order. New protection creation and
replacement are also blocked. Closes, protection cancellation and valid trigger/retry processing remain available.
HousePool entry pause stops new LP deposits and their activation, while the separate settlement hold stops all
`settleLpEpoch` calls and new Senior commitments. Neither control stops already-funded claims.

Automatic gates remain independent of those manual controls:

- Engine degraded mode latches when a close or liquidation leaves raw `E < L`, where
  `E = max(HousePool.totalAssets() - trader claims, 0)` and `L` is maximum directional liability. It blocks new risk,
  LP entry, and all LP epoch settlement. The Engine owner can call `clearDegradedMode()` once raw `E >= L`.
  Restoring the separate settlement-buffer target is not required to clear the latch.
- FAD and `oracleFrozen` block opens. Other oracle-dependent actions still need policy-valid prices. Frozen replay
  cannot repair a cached Engine mark that has exceeded the frozen freshness limit; see
  [Oracle synchronization](ORACLE_SYNCHRONIZATION.md).
- Freshness, solvency, custody, accounting, queue, and capacity gates can reject unpaused actions. Releasing a manual
  restriction does not bypass any of them.

The unified incident event uses fixed bits: RouterAdmin risk-off `1`, HousePool entry pause `2`, and LP epoch
settlement hold `4`. The restrictions requested by risk-off plus entry are `3`, while full containment requests `7`.
The event's previous/new masks describe the complete observed state, not only the requested action. For example, a
risk-off action taken while settlement is already held emits a new mask of `7`, not `3`.

Use the narrowest action that contains the credible failure. Direct owner actions remain available for governance
operations, but operators must record and monitor any partial restriction state.

## Action matrix

"Allowed" means the breaker itself does not prohibit the action. Normal protocol checks still apply.

| Protocol action | Risk-off + entry | Settlement-only | Full containment | Important consequence |
|---|---|---|---|---|
| Commit an open/increase | Stopped | Allowed | Stopped | Risk-off permanently invalidates covered pending opens |
| Execute an open covered by cutoff | Permanently invalid; refundable | Allowed unless another gate blocks it | Permanently invalid; refundable | Later unpause never revives the order |
| Commit/execute a close or reduction | Allowed | Allowed | Allowed | No discretionary close-off breaker exists |
| Create/replace protection or attach it to a new open | Stopped | Allowed | Stopped | Existing protection is not cancelled merely by a pause |
| Cancel, trigger, or retry existing protection | Allowed | Allowed | Allowed | Position, oracle, and queue checks still apply |
| Liquidate | Allowed | Allowed | Allowed | Liquidation remains a risk-reduction path |
| Refresh Engine/oracle mark | Allowed | Allowed | Allowed | A valid refresh may be needed before recovery |
| Recapitalize or reconcile | Allowed | Allowed | Allowed | These paths support investigation and recovery |
| Request a Senior deposit / reserve capacity | Stopped | Stopped | Stopped | New binding commitments cannot be created during a settlement hold |
| Request a Junior deposit | Stopped | Allowed | Stopped | Junior escrow may accumulate while settlement is held |
| Activate a pending LP deposit | Stopped | Stopped | Stopped | Settlement is the only activation path |
| Claim activated deposit shares | Allowed | Allowed | Allowed | No new NAV decision occurs at claim time |
| Cancel a pending deposit | Existing rules only | Existing Senior commitments refundable; Junior rules unchanged | Existing Senior commitments refundable; Junior rules unchanged | The settlement hold opens a Senior escrow exit |
| Request an LP redemption | Allowed | Allowed | Allowed | Shares continue entering the epoch queue |
| Cancel a redemption | Existing rules only | Existing rules only | Existing rules only | Maturity/funding rules remain authoritative |
| Settle an epoch / fund redemptions | Allowed if automatic gates pass | Stopped | Stopped | Both cached and atomic-refresh routes fail while held |
| Claim a funded redemption/refund | Allowed | Allowed | Allowed | Previously escrowed user property remains claimable |
| Clean invalidated opens | Allowed and expected | Allowed | Allowed and expected | Cleanup is oracle-free, bounded, and lazy |
| Release restrictions | Guardian cannot | Guardian cannot | Guardian cannot | Governance owns recovery; there is no timer |

## Choosing the minimum containment action

Except during an active exploit, corroborate a signal at the same block through an independent RPC or data source
before signing. Evidence collection must not delay containment when the failure is already credible.

### Use settlement-only hold

Use `triggerLpEpochSettlementHold` when the suspected failure is isolated to a new epoch-clearing decision and current
evidence does not indicate compromised trading, custody, or LP request admission. Realistic triggers include:

- a confirmed mismatch between expected and simulated deposit activation or redemption funding;
- inconsistent settlement phase ordering, funded amounts, burns/mints, HWM/principal changes, or epoch-head movement;
- a confirmed defect in the redemption-budget math or its stateless sidecar;
- a settlement-specific oracle-boundary, route-selection, payload, or atomic-rollback defect;
- structurally inconsistent LP queue state where allowing another settlement could make recovery harder; or
- an unknown settlement dependency that remains unreadable across independent providers and for which exact
  route-specific simulation cannot establish safety.

Settlement-only is not a general response to price volatility or queue delay. It permits new Junior deposit requests,
so operators and frontends must disclose that Junior assets may accumulate in escrow without an activation date.
Existing Senior commitments may be refunded while the hold remains active.

### Use risk-off plus LP-entry pause

Use `triggerEmergencyPause` when new market risk or new LP admission is unsafe but settled queue processing is still
trusted. Examples include:

- a confirmed wrong/manipulated oracle, unexpected oracle binding, or compromised pricing signer;
- credible compromise of an admin, trader-account, deployment, or signing system executing unauthorized
  risk-increasing actions;
- unexpected degraded mode or insolvency whose cause is not promptly understood; or
- an active exploit affecting new opens/increases or LP entry while settlement accounting remains reconciled.

This action is economically irreversible for covered opens because it records a persistent inclusive cutoff. Do not
use it merely to gain investigation time when settlement-only containment is sufficient.

### Use full containment

Use `triggerFullContainment` when the incident crosses domains, the affected domain cannot be isolated confidently,
or an active exploit makes one atomic transaction preferable to sequential actions. Examples include:

- confirmed custody, asset-boundary, escrow, seed-floor, or Senior-reservation deficits;
- confirmed Terminal NAV cap/lot/entry-basis/mark-domain/snapshot disagreement;
- unexpected cross-contract bindings or unexplained asset/NAV movement;
- compromised governance or operational authority with uncertain reachable paths; or
- simultaneous trading-risk and settlement-integrity evidence.

Full containment atomically applies Router risk-off, HousePool entry pause, and the settlement hold. Any downstream
failure reverts every change made by the call while preserving restrictions that were already active.

Recommended stable reason families are `CUSTODY_DEFICIT`, `ACCOUNTING_INVARIANT`,
`BINDING_OR_QUEUE_INTEGRITY`, `SETTLEMENT_INTEGRITY`, `ORACLE_INTEGRITY`, `AUTHORITY_COMPROMISE`,
`ENGINE_INSOLVENCY`, and `UNKNOWN_UNSAFE_STATE`. Hash the reason with a versioned schema and put the incident-bundle
hash in `evidenceHash`.

### Do not trigger solely for normal or self-contained states

- `NoMaturedWork`, `AdditionsStillOpen`, `ObservationCanStillShrink`, expected FIFO progress, or a temporary backlog.
- `NoFreeCash`, matured Senior precedence, capacity exhaustion, Senior impairment, or an ordinary deposit deferral.
- Scheduled FAD/`oracleFrozen`, normal mark staleness, or a low-confidence update correctly rejected on-chain.
- One incomplete `SettlementMonitorLens` response or one failed RPC call.
- A known active `PoolPaused`, `RouterAdminPaused`, or `LpEpochSettlementPaused` state.
- An expected settlement revert caused by a documented lifecycle, oracle, authorization, balance, or capacity check.

## Monitoring semantics and action map

The Lens is advisory. It never authorizes or actuates a breaker, and the coordinator never reads it. Inspect
`criticalFaultMask`, dependency masks, operational blockers, warnings, and deposit-deferral masks independently; a
critical fault makes the composite observation incomplete, so watching only `completeObservationDigest` can miss the
condition that should page the guardian.

An active, successfully read settlement hold is an intentional complete observation:

- `status.lpEpochSettlementPaused` is true;
- `OperationalBlocker.LpEpochSettlementPaused` explains that neither settlement route is currently executable;
- `DepositDeferral.LpEpochSettlementPaused` explains why pending deposits cannot activate; and
- the cached-versus-atomic required path remains visible for recovery planning.

A reverted or malformed hold-state read is different: Pool dependency state is unknown, the observation is
incomplete, and `completeObservationDigest` is zero. `LpEpochKeeper` must stop before payload decoding, Pyth fee
quoting, or transaction broadcast when the hold is active.

| Monitor signal | Default off-chain response | Minimum action policy |
|---|---|---|
| `BindingMismatch` | Compare immutable/runtime bindings and deployment manifest immediately | Full containment when direct reads confirm unexpected production wiring |
| Queue/epoch structural faults | Reproduce from direct vault/queue reads at the same block | Settlement-only when isolated; full containment if ownership/custody is uncertain |
| NAV aggregate faults | Reconcile book commitments against canonical Engine state | Full containment after minimal confirmation |
| Pool/vault custody or escrow deficits | Reconcile token balances, accounted assets, claimant buckets, and reservations | Full containment after minimal confirmation |
| Future cached mark or arithmetic-domain fault | Verify time, mark, and contributing reads | Settlement-only if isolated to settlement; otherwise full containment |
| `EngineDegraded` or terminal-deficit warning | Diagnose raw solvency while protective keepers remain active; settlement-buffer depletion without `E < L` is not degraded mode | Risk-off or full containment if unexpected, persistent, or accompanied by integrity evidence |
| `WithdrawalsNotLive`, stale mark, invalid required oracle, pre-boundary oracle | Route or wait under documented policy | No breaker solely from this blocker |
| `LpEpochSettlementPaused` blocker/deferral | Verify it matches the incident record; continue observing route and queues | No new trigger solely because the requested hold is active |
| Unknown dependency | Retry block-pinned direct reads through independent providers | Trigger only if safe state cannot be established; choose the smallest affected domain |
| Normal queue warnings or any ordinary deposit deferral | Record and explain liveness state | No breaker solely from the warning/deferral |

## Guardian runbook

### Before signing

1. Pin reads to a block number and record its block hash, chain id, contract addresses/code hashes, configuration
   digest, monitor observation, and exact proposed containment action.
2. Re-read the condition through an independent RPC. Preserve raw signed oracle updates and external market evidence
   for oracle incidents.
3. Confirm coordinator bindings, shared pauser assignments, and guardian identity.
4. Simulate exactly one of `triggerEmergencyPause`, `triggerLpEpochSettlementHold`, or `triggerFullContainment`. Zero
   reason/evidence hashes are valid when metadata is not ready.
5. Record the pre-existing Router pause, Pool entry pause, settlement hold, and cutoff. Coordinator actions are
   idempotent, but prior state remains important evidence.

### Trigger and verify

1. Submit the selected coordinator call from the guardian. Use full containment instead of separate transactions
   when all restrictions are required atomically.
2. Confirm `EmergencyContainmentTriggered` from the expected coordinator and verify its action, reason/evidence,
   cutoff, and previous/new restriction masks.
3. Read the three restriction states directly and confirm they match the signed action. For risk-off/full actions,
   ensure `riskOffOrderCutoff` covers the intended order tail.
4. Page governance and publish the incident boundary. Never describe cutoff-invalidated opens as executable after
   recovery, and never promise that a held deposit will activate on a particular date.

### Operate while contained

- Keep close, liquidation, mark-refresh, redemption-request, cancellation, funded-claim, and recapitalization
  infrastructure running.
- If risk-off is active, run permissionless invalidated-open cleanup until the intended bounded queue range is clean.
- If settlement is held, stop settlement broadcasts but continue block-pinned observation of both the locked batch
  and newer request accumulation. Warn depositors that settlement and activation are unavailable.
- Treat refunded open margin/bounty as internal settlement, not an immediate wallet transfer.
- Continue monitoring custody, NAV commitments, oracle state, degraded mode, queues, and funded claims.

### Governance recovery

The guardian has no release authority and restrictions have no expiry. Governance should recover only after:

1. the root cause is identified, fixed or isolated, and independently reviewed;
2. bindings, custody, escrow, queues, NAV commitments, and the redemption-math sidecar reconcile;
3. oracle source/configuration and exact post-recovery settlement route are validated;
4. healthy observations remain consistent across the chosen blocks/providers;
5. every cutoff-invalidated open, queued LP request, and cleanup backlog is understood;
6. degraded mode, if active, passes its raw `E >= L` on-chain solvency check; settlement-buffer restoration is
   independently required before new risk or LP redemption funding, not before clearing the latch;
7. the held epoch is simulated through the exact cached or atomic-refresh route on a fork that models the intended
   governance releases; an ordinary live simulation still reverts while the hold is active. Repeat the exact live
   simulation after release and before broadcasting settlement; and
8. governance documents release order and rotates/disables an implicated guardian.

Unpausing cannot reset `riskOffOrderCutoff`. Releasing the settlement hold only restores eligibility to attempt
settlement; it does not repair state or guarantee success.

## Limits and operational ownership

The coordinator has no global-freeze, arbitrary-mask, emergency-price, fund-transfer, or arbitrary-call function.
It cannot block closes/reductions or already-funded claims. Under a settlement-only hold, Junior deposits and LP
redemption requests can continue accumulating under normal admission/cancellation rules. Existing Senior
commitments may be refunded.

The coordinator constructor checks nonzero, distinct code-bearing targets, not their membership in the intended
stack. Verify the immutable RouterAdmin/HousePool bindings and both pauser assignments independently. Missing
pauser authority can revert an action that needs a new downstream restriction. A compromised governance owner still
has its owner authorities; the guardian cannot constrain it.

Reason/evidence hashes and monitor digests are advisory metadata, not on-chain proofs. This repository supplies the
controls and observability, not an automated observer, signer, or incident keeper service. An operator service needs
block-pinned evidence, independent corroboration, reorg handling, duplicate-action control, and post-transaction
verification. Recovery remains a deliberate governance action.

## Canonical references

- [EmergencyPauseCoordinator](src/EmergencyPauseCoordinator.sol): fixed guardian actions and incident event.
- [OrderRouterAdmin](src/OrderRouterAdmin.sol): Router pause, ownership, and persistent risk-off cutoff.
- [HousePool](src/HousePool.sol): LP-entry pause, independent settlement hold, and settlement gates.
- [CfdEngine](src/CfdEngine.sol): degraded mode and solvency-gated recovery.
- [SettlementMonitorLens](src/SettlementMonitorLens.sol) and
  [monitor view types](src/interfaces/SettlementMonitorViewTypes.sol): advisory observations and fault masks.
- [Deployment](DEPLOYMENT.md): coordinator wiring and release verification.
- [Security model](SECURITY.md): trust boundaries and assumptions.

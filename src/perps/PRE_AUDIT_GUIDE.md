# Perps Pre-Audit Guide

This document is the shortest path for an auditor to reconstruct intended behavior without inferring policy from multiple modules.

Read this with:

- [`README.md`](README.md) for the product overview
- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md) for normative accounting semantics
- [`SECURITY.md`](SECURITY.md) for trust assumptions and protocol invariants
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md) for custody and mutation boundaries
- [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md) for product-facing vs internal surfaces

## Audit Priorities

If reviewing quickly, focus on these questions in order:

1. Does a path use the canonical planner output rather than recomputing different economics at execution time?
2. Does the path move value only across the intended custody domains?
3. Does the path use the correct oracle regime and failure policy for the current market state?
4. Does the path preserve bounded queue behavior and deferred-liability seniority?

## Policy Spec

### Privileged caller table

| Contract | Privileged caller set | Notes |
|----------|------------------------|-------|
| `CfdEngine` settlement host hooks | `settlementModule` only | settlement module itself is engine-gated |
| `CfdEngine.processOrderTyped` / `liquidatePosition` / fee bookkeeping | `orderRouter` only | router is the external execution boundary |
| `MarginClearinghouse` operator paths | `engine`, `orderRouter`, `settlementModule` | router for queue escrow, engine/module for settlement |
| `HousePool.payOut` / `recordProtocolInflow` | `engine`, `orderRouter`, `settlementModule` | payout/inflow authority is intentionally narrow |
| `HousePool.recordClaimantInflow` | `engine`, `settlementModule` | claimant-owned revenue/recap routing only |

Any new helper/module contract that can reach these sets should be treated as security-critical and explicitly access-controlled.

### Order lifecycle state machine

`Pending -> Executed`

- keeper executes a valid FIFO head
- margin reservations are consumed/released
- router bounty escrow is distributed

`Pending -> Failed`

- typed user-invalid execution
- protocol-state invalidation
- slippage failure
- expiry
- liquidation cleanup

`Pending -> Pending`

- stale oracle revert
- live-market MEV ordering block
- frozen-market ineligibility for the attempted action

`Failed/Executed -> terminal`

- no requeue
- no user cancellation path
- queue pointers and reservations must be unlinked exactly once

### Failure-policy table

| Condition | Outcome | Bounty policy | Queue effect |
|-----------|---------|---------------|--------------|
| Open/close executes successfully | `Executed` | clearer paid from escrow | dequeue |
| Typed `UserInvalid` open | `Failed` | clearer paid | dequeue |
| Typed `ProtocolStateInvalidated` open | `Failed` | trader refunded into clearinghouse settlement | dequeue |
| Terminal invalid close | `Failed` | clearer paid | dequeue |
| Slippage failure on open | `Failed` | clearer paid under the current terminal-failure policy | dequeue |
| Slippage failure on close | `Failed` | clearer paid | dequeue |
| Expired open order | `Failed` | trader refunded into clearinghouse settlement | dequeue |
| Expired close order | `Failed` | clearer paid from escrow under the current terminal-close policy | dequeue |
| Stale oracle | blocked, not terminal | no distribution | keep pending |
| Live-market publish-time ordering failure | blocked, not terminal | no distribution | keep pending |
| Close-only ineligibility for queued open | blocked, not terminal | no distribution | keep pending |

### Bounty-flow table

| Bounty type | Source of funds | Custody while pending | Success path | Illiquid path | Terminal failure path |
|-------------|-----------------|-----------------------|--------------|---------------|-----------------------|
| Order execution bounty | Trader free settlement, then bounded close fallback from active position margin | `OrderRouter` escrow | clearinghouse credit for the clearer | n/a | clearer payment or trader refund via clearinghouse credit depending on failure category/policy |
| Liquidation bounty | Capped from canonical liquidation value derived from reachable collateral and carry-adjusted equity | planned in engine, then serviced through the liquidation settlement path | immediate keeper clearinghouse credit if cash is available after the settlement path | deferred keeper credit senior claim | n/a |

### Oracle regime table

| Regime | Entry condition | Allowed actions | Core checks |
|--------|-----------------|----------------|-------------|
| Live market | oracle not frozen, mark fresh enough | opens, closes, liquidations | staleness, `block.number > commitBlock`, `publishTime > commitTime`, `publishTime >= lastMarkTime` |
| Friday gap / runway live-close regime | market not frozen but special weekend/runway timing | live rules still apply | same live checks |
| Frozen / FAD close-only regime | oracle frozen but within allowed stale window | closes and liquidations only | relaxed publish-ordering rule, frozen-window stale limits |
| Over-stale frozen regime | oracle frozen beyond allowed stale window | no execution | revert/block |
| Degraded mode | post-terminal insolvency latch | risk-reducing and protective actions only | opens blocked, protective transitions allowed |

## Source Of Truth By Quantity

| Quantity | Economic owner | Storage/source of truth | Mutators | Counts as reachable collateral? | Counts toward solvency? | Counts toward LP withdrawal reserve? | Counts toward tranche reconcile? |
|----------|----------------|-------------------------|----------|---------------------------------|-------------------------|-------------------------------------|----------------------------------|
| Free settlement | Trader | `MarginClearinghouse.balanceUsdc(accountId)` | clearinghouse deposit/withdraw, engine settle/seize | yes, action-dependent | yes, via action-specific view | no | no |
| Active position margin | Trader until terminal settlement outcome | clearinghouse locked bucket + engine position mirror | engine open/close/liquidation, bounded router close-bounty sourcing | yes for terminal paths, no for ordinary withdraw | yes, via risk/equity view | no | no |
| Other locked margin | Trader, but reserved to queued intents until an explicit terminal path unlocks it | clearinghouse reservations | router commit/release/consume | no for ordinary close reachability; only available where terminal settlement explicitly unlocks/consumes it | indirectly and only through explicit terminal settlement plans | no | no |
| Committed order margin | Trader but reserved to one order | clearinghouse reservation keyed by `orderId` | router commit/execute/fail | no | no | no | no |
| Router execution bounty escrow | Trader-funded keeper escrow | `OrderRouter` balance + order record | router commit/distribute/refund/forfeit | no | no | no | no |
| Deferred trader credit | Trader senior claim on vault liquidity | `CfdEngine.deferredTraderCreditUsdc` | engine create/service | no | yes, as senior liability | yes | yes |
| Deferred keeper credit | Keeper senior claim on vault liquidity | `CfdEngine.deferredKeeperCreditUsdc` | engine create/service | no | yes, as senior liability | yes | yes |
| Unsettled carry | Protocol-recorded carry debt on an account | `CfdEngine.unsettledCarryUsdc[accountId]` | engine carry-checkpoint paths | no | yes, as carry drag on account equity | no | no |
| Accumulated protocol fees | Protocol/treasury | `CfdEngine.accumulatedFeesUsdc` + canonical pool cash | engine accrual, owner withdraw | no | reduces net physical assets | yes | yes |
| Accumulated bad debt | Protocol loss / LP impairment | `CfdEngine.accumulatedBadDebtUsdc` | engine realization, bad debt clear path | n/a | yes, as realized deficit | yes | yes |
| Canonical pool assets | LP/protocol backing | `HousePool.totalAssets()` and accounting ledger | pool deposit/withdraw/accounting hooks | base physical solvency cash | yes | yes | yes |
| Excess assets | no owner until admitted | `HousePool.excessAssets()` | pool account/sweep paths | no | no | no | no |

Reachability note:
- Generic reachability excludes `CommittedOrder` and `ReservedSettlement` buckets.
- Terminal reachability may include those buckets, but only where the close/liquidation settlement plan explicitly consumes or unlocks them.
- Carry, withdraw checks, margin-basis changes, and non-terminal open/modify risk paths must use the generic basis.

## Liveness vs Safety Choices

### Frozen oracle close-only behavior

- Liveness problem: risk-reducing users and keepers still need an exit path when live oracle updates stop.
- Chosen tradeoff: opens are blocked, but closes and liquidations may proceed inside explicit frozen/FAD windows.
- New risk: execution may rely on older marks than the live regime would permit.
- Protecting invariant: frozen execution has its own tighter stale window and remains close-only.

### Deferred trader credit servicing

- Liveness problem: profitable closes and liquidation payouts should not revert only because the vault is temporarily illiquid.
- Chosen tradeoff: record senior deferred trader/keeper credit claims instead of reverting the state transition.
- New risk: payout servicing becomes asynchronous and must respect seniority.
- Protecting invariant: deferred liabilities remain senior in withdrawal, solvency, and reconciliation accounting.

### Fail-soft liquidation bounty servicing

- Liveness problem: liquidation should not fail solely because immediate vault cash is unavailable.
- Chosen tradeoff: keeper bounty may become deferred keeper credit.
- New risk: keeper payment timing becomes state-dependent.
- Protecting invariant: liquidation still completes, and the keeper credit claim remains senior until paid.

### Bounded queue cleanup

- Liveness problem: terminal cleanup must not become unbounded in global historical order count.
- Chosen tradeoff: per-account bounded queue traversal and explicit prune paths.
- New risk: queue behavior is more state-machine dense.
- Protecting invariant: terminal cleanup and close-intent projection traverse only account-local pending queues.

### Binding queued orders

- Liveness problem: allowing arbitrary user cancellations would turn the queue into an option-like mechanism.
- Chosen tradeoff: queued orders are binding until executed, expired, or failed by policy.
- New risk: user flexibility is reduced once committed.
- Protecting invariant: failure policy is explicit and terminal paths clean up escrow/reservations exactly once.

### Stale-mark close bounty commits

- Liveness problem: a trader with no free settlement may still need to queue a risk-reducing close that sources the fixed router bounty from active margin.
- Chosen tradeoff: close-bounty reservation may use the latest stored mark price even when it is stale, as long as a mark exists.
- New risk: commit-time close-bounty reservation may use an older mark than live execution would accept.
- Protecting invariant: this path only supports risk-reducing close commits and still excludes queued reservations from generic collateral reachability.

## Transaction Narratives

### Profitable close with immediate payout

1. Trader has a live position and commits a close.
2. Router escrows the close execution bounty, using free settlement first when a fresh carry-checkpoint mark exists and otherwise using the bounded active-margin fallback.
3. Keeper executes the FIFO head under the current oracle regime.
4. Planner computes canonical close settlement, including fees and pending carry.
5. Engine realizes carry and applies the close using the planner's exact loss/gain result.
6. Clearinghouse unlocks/consumes the relevant trader buckets.
7. If vault cash is available, the trader receives immediate settlement.
8. Router bounty escrow is distributed and the order becomes terminal.

### Losing partial close

1. Trader commits a reduce-only close.
2. Router escrows the execution bounty and preserves the residual position path.
3. Keeper executes.
4. Planner computes canonical carry-adjusted loss and partial-close remaining margin.
5. Engine consumes close loss from free settlement, then allowed unlocked margin buckets, then shortfall if needed.
6. Position remains open with reduced size and updated margin.
7. LPs receive realized carry/trading inflow; no separate loss recomputation occurs at execution time.

### Liquidation with positive residual

1. Keeper calls liquidation on an under-maintenance account.
2. Planner computes carry-adjusted liquidation equity using only physically reachable collateral.
3. Keeper bounty is capped by carry-adjusted positive equity.
4. Terminal residual plan seizes reachable collateral, pays the bounty, and computes any fresh trader payout.
5. Existing deferred trader credit is not treated as reachable collateral; it remains only as a senior claim unless negative residual netting consumes it.
6. If cash is available, fresh payout is immediate; otherwise it becomes deferred.
7. Position is removed and queue cleanup runs on the liquidated account's local pending-order queue only.

### Liquidation with bad debt and deferred netting

1. Keeper calls liquidation on an account whose reachable collateral cannot cover losses.
2. Planner computes carry-adjusted negative equity.
3. Keeper bounty is capped by reachable collateral when equity is non-positive.
4. Terminal residual plan consumes all physically reachable collateral.
5. Existing same-account deferred trader credit is netted exactly once against remaining terminal shortfall.
6. Any leftover deficit becomes realized bad debt.
7. `degradedMode` may latch if post-op solvency falls below the required boundary.

## Read-Surface Canonicality

- `PerpsPublicLens` is the canonical product-facing read layer.
- `CfdEngineAccountLens` and `CfdEngineProtocolLens` are audit/operator/diagnostic surfaces.
- Engine getters are runtime internals unless explicitly documented as part of the product or audit-facing read surface.
- When in doubt, prefer `PerpsPublicLens` for integrations and the richer lenses only for diagnostics, tests, and audit review.

## Invariants Auditors Should Keep In Mind

1. Preview/live parity: canonical close and liquidation planner outputs should match live settlement semantics.
2. Physical-first solvency: physical cash and mathematical claims are distinct objects.
3. Deferred-liability seniority: deferred trader and keeper credit claims remain senior until serviced.
4. Carry-aware risk: pending carry reduces relevant equity before realization on guard and risk checks.
5. Bounded queue behavior: cleanup and close-intent projection are account-local.
6. Escrow conservation: execution bounty escrow is distributed, refunded, forfeited, or left claimable exactly once.
7. No speculative LP asset inflation: unrealized trader losses are not counted as spendable LP assets.

## Test Map

Use the suites below as the highest-signal audit companions.

| Theme | Primary suites |
|-------|----------------|
| Carry | `test/perps/CfdEngine.t.sol`, `test/perps/CfdEnginePlanRegression.t.sol`, `test/perps/MarginClearinghouse.t.sol` |
| Deferred claim modes | `test/perps/DeferredClaimsMatrix.t.sol`, `test/perps/CfdEngine.t.sol` |
| Liquidation | `test/perps/CfdEngine.t.sol`, `test/perps/OrderRouter.t.sol`, `test/perps/invariant/PerpDeferredCreditInvariant.t.sol` |
| Payout modes | `test/perps/PayoutModesMatrix.t.sol`, `test/perps/CfdEngine.t.sol` |
| Deferred liabilities | `test/perps/CfdEngine.t.sol`, `test/perps/invariant/PerpDeferredCreditInvariant.t.sol` |
| FIFO / expiry / queue | `test/perps/OrderRouter.t.sol` |
| Frozen oracle / FAD | `test/perps/OrderRouter.t.sol` |
| LP reserve / withdrawals | `test/perps/MarginClearinghouse.t.sol`, `test/perps/CfdEngine.t.sol`, `test/perps/HousePool.t.sol` |
| HousePool snapshot parity | `test/perps/HousePoolSnapshotParity.t.sol`, `test/perps/PerpsReadParity.t.sol` |
| Router policy matrix | `test/perps/OrderRouterPolicyMatrix.t.sol` |
| Stale-mark / reconcile behavior | `test/perps/HousePool.t.sol`, `test/perps/CfdEngine.t.sol`, `test/perps/AuditV2.t.sol`, `test/perps/AuditV3.t.sol` |
| Audit-history regressions | `test/perps/AuditCurrentFindingsVerification.t.sol`, `test/perps/AuditFindings.t.sol`, `test/perps/AuditV2.t.sol`, `test/perps/AuditV3.t.sol` |

Historical or obsolete regression names that still mention legacy spread/funding are audit-history artifacts, not live accounting concepts. When those names appear, trust the surrounding comments and the current accounting docs rather than the historical label.

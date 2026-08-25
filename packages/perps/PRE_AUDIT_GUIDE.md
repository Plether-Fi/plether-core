# Perps Pre-Audit Guide

This document is the shortest path for an auditor to reconstruct intended behavior without inferring policy from multiple components.

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
4. Does the path preserve bounded queue behavior and trader-claim seniority?
5. Does every position/pledge/claim mutation atomically synchronize the matching `TerminalNavBookV2` curve from canonical Engine and clearinghouse state?

## Test Taxonomy

Treat test files as belonging to one of three buckets:

1. `spec`: asserts intended product or accounting behavior sourced from `ACCOUNTING_SPEC.md`, `README.md`, or the policy tables below.
2. `invariant`: asserts properties that must hold across many action sequences and internal implementations.
3. `regression`: preserves a deliberately chosen edge case, legacy fix, or historical bug repro.

Rules:

- Every new non-trivial test should state its bucket and the source-of-truth rule it is asserting.
- `spec` tests should prefer parity or end-state economics over mirroring internal implementation steps.
- `invariant` tests should avoid asserting incidental storage details when a stronger economic property is available.
- `regression` tests must not be the only place that defines correctness for a behavior; pair them with a `spec` or `invariant` test when the behavior is normative.
- Tests that only describe current behavior should be prefixed `legacy_`, `current_behavior_`, or `obsolete_` unless the behavior is explicitly intended by spec.

### Test Review Checklist

Before trusting a test as a source of truth, ask:

1. Would this still be correct if the implementation were rewritten but the economics stayed the same?
2. Is the assertion derived from a spec rule, or only from observed current code behavior?
3. Does the test compare two equivalent policy paths (`fresh` vs `stale stored-mark`, `preview` vs `live`) rather than hard-coding one path's internals?
4. Is the test preserving stale state (`should not advance`, `should remain unchanged`) where the spec actually requires a checkpoint or recomputation?
5. If this test disagrees with docs/spec, is the disagreement intentional and documented?

## Policy Spec

### Privileged caller table

| Contract | Privileged caller set | Notes |
|----------|------------------------|-------|
| `CfdEngine` settlement host hooks | `settlementSidecar` only | settlement sidecar itself is engine-gated |
| `TerminalNavBookV2.authenticateEngineState` / `syncFromEngine` | immutable bound `CfdEngine` only | two-step mutation protocol: authenticate canonical pre-transition state, then require that authenticated hash still matches the stored commitment and derive the post-transition curve or removal from canonical Engine and clearinghouse state; `syncFromEngine` is the sole curve mutation endpoint; no caller-supplied curve, owner, repair, or migration path |
| `CfdEngine.processOrderTyped` / `liquidatePosition` / fee bookkeeping | `orderRouter` only | router is the external execution boundary |
| `MarginClearinghouse` operator paths | `engine`, `settlementSidecar` | broad settlement mutations only |
| `MarginClearinghouse` reservation paths | `engine`, `orderRouter` | router can reserve/release queued margin and execution-bounty buckets, but cannot perform broad settlement |
| `MarginClearinghouse.releaseInvalidatedOrderReserves` | Engine-reported `orderRouter` only | exact risk-off reclassification; authorization reads the Engine's Router binding, while the transition performs no Engine mutation, carry checkpoint, Terminal NAV synchronization, or token movement |
| `HousePool.payOut` / `recordProtocolInflow` | `engine`, `settlementSidecar` | payout/inflow authority is intentionally narrow |
| `HousePool.recordClaimantInflow` | `engine`, `settlementSidecar` | claimant-owned revenue/recap routing only |
| `HousePool.reserveSeniorDeposit` / `releaseSeniorDepositReservation` | configured `seniorVault` only | direct LPs and the Junior vault cannot reserve or release pending Senior-entry capacity; activation happens only through synchronized settlement |
| `HousePool.reconcile` | either configured tranche vault | retained vault integration hook; end users enter and claim through `TrancheVault` |
| `OrderRouter.settleLpEpoch(bytes[])` | permissionless | validates one PoolReconcile mark and atomically invokes coordinated LP entry activation and redemption funding |
| `HousePool.settleLpEpoch(uint256,uint256)` | configured Engine `orderRouter` when live positions exist; otherwise permissionless | binds the Router's exact mark/time for live settlement; `(0,0)` is the mark-independent or frozen cached-mark fallback |
| `SettlementMonitorLens` views | permissionless | read-only, bounded, fail-soft settlement diagnostics; no settlement, pause, or circuit-breaker authority |
| `SettlementMonitorLensSidecar` diagnostic builders | constructor-bound `SettlementMonitorLens` facade only | code-size implementation detail; external callers cannot obtain facade-attributed health from fabricated queue masks, integrations must use the facade rather than treating the sidecar as a second canonical surface, and constructor-set binding getters remain publicly readable; there are no setters or delegatecall paths |
| `EmergencyPauseCoordinator.triggerEmergencyPause` | configured guardian only | atomically pauses new open commits and LP entry; advisory reason/evidence hashes are not Lens authorization; no unpause, pricing, configuration, fund movement, or arbitrary call |
| `EmergencyPauseCoordinator.setGuardian` | coordinator owner only | rotate or disable containment authority; the guardian cannot rotate itself |
| `OrderRouter.clearRiskOffOrder` | permissionless | oracle-free cleanup of one permanently invalidated open; full internal refund to trader, no clearer bounty |
| `OrderRouterLiquidationBatchSidecar.executeLiquidationBatch` | immutable deploying Router delegatecall context only | stateless size split; direct calls revert, binding has no setter, and Router self-only item callbacks remain the mutation boundary |

Any new helper/sidecar contract that can reach these sets should be treated as security-critical and explicitly access-controlled.

### Order lifecycle state machine

`Pending -> Executed`

- keeper executes a valid FIFO head
- margin reservations are consumed/released
- clearinghouse-reserved bounty value is distributed

`Pending -> Failed`

- typed user-invalid execution
- protocol-state invalidation
- slippage failure
- expiry
- persistent risk-off invalidation for a pre-cutoff open
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
| Open/close executes successfully | `Executed` | keeper paid from reservation | dequeue |
| Typed `UserInvalid` open | `Failed` | keeper paid | dequeue |
| Typed `ProtocolStateInvalidated` open | `Failed` | keeper paid from reserved bounty | dequeue |
| Terminal invalid close | `Failed` | keeper paid | dequeue |
| Slippage failure on open | `Failed` | keeper paid under the current terminal-failure policy | dequeue |
| Slippage failure on close | `Failed` | keeper paid | dequeue |
| Expired open order | `Failed` | keeper paid from reserved bounty | dequeue |
| Expired close order | `Failed` | keeper paid from reservation under the current terminal-close policy | dequeue |
| Risk-off open at or below persistent cutoff | `Failed` | full bounty returned to trader's internal settlement; clearer unpaid | dequeue |
| Stale oracle | blocked, not terminal | no distribution | keep pending |
| Live-market publish-time ordering failure | blocked, not terminal | no distribution | keep pending |
| Close-only ineligibility for queued open | blocked, not terminal | no distribution | keep pending |

### Bounty-flow table

| Bounty type | Source of funds | Custody while pending | Success path | Illiquid path | Terminal failure path |
|-------------|-----------------|-----------------------|--------------|---------------|-----------------------|
| Order execution bounty | Eligible trader free settlement; never active PnL pledge | `MarginClearinghouse` reserved settlement bucket plus router order record | clearinghouse credit for the keeper | n/a | persistent risk-off cleanup refunds the trader internally; every other ordinary terminal failure pays the keeper |
| Liquidation charge | Dedicated liquidation-charge reserve, capped by the canonical planned charge | clearinghouse liquidation reserve | Default: 50% keeper clearinghouse credit; 0% protocol-treasury clearinghouse credit; exact 50% remainder to HousePool claimant revenue | n/a | n/a |

### Oracle regime table

| Regime | Entry condition | Allowed actions | Core checks |
|--------|-----------------|----------------|-------------|
| Live market | oracle not frozen, mark fresh enough | opens, closes, liquidations | staleness, `block.number > commitBlock`, `commitTime < publishTime <= block.timestamp`, `publishTime >= lastMarkTime` |
| FAD-only / runway live-close regime | FAD active, oracle not frozen | live close-only rules | same live checks; signed VPI and no frozen-close spread |
| Frozen close-only regime | oracle frozen but within allowed stale window | closes and liquidations only | relaxed publish-ordering rule and frozen-window stale limits; voluntary closes use signed VPI plus fixed LP-owned spread, liquidations unchanged |
| Over-stale frozen regime | oracle frozen beyond allowed stale window | no execution | revert/block |
| Degraded mode | post-terminal insolvency latch | risk-reducing and protective actions only | opens blocked, protective transitions allowed |

## Source Of Truth By Quantity

| Quantity | Economic owner | Storage/source of truth | Mutators | Counts as reachable collateral? | Counts toward solvency? | Counts toward LP withdrawal reserve? | Counts toward tranche reconcile? |
|----------|----------------|-------------------------|----------|---------------------------------|-------------------------|-------------------------------------|----------------------------------|
| Free settlement | Trader | `MarginClearinghouse.balanceUsdc(account)` | clearinghouse deposit/withdraw, engine settle/seize | yes, action-dependent | yes, via action-specific view | no | no |
| PnL pledge / active position margin | Trader until exact price settlement | `pnlPledgeUsdc` + engine position mirror | engine/settlement-sidecar open, close, liquidation, claim service | yes only for the account's price-loss cap and health | yes, via risk/equity view | no | yes, only through the capped terminal curve |
| Other locked margin | Trader, reserved to typed non-price obligations | clearinghouse typed reserves | router and engine/sidecar typed reservation paths | only for its matching action; never generic price-loss reachability | no direct pool asset | no | no |
| Committed order margin | Trader but reserved to one order | clearinghouse reservation keyed by `orderId` | router commit/execute/fail | no | no | no | no |
| Execution bounty reserve | Trader-funded keeper reserve | `MarginClearinghouse` reserved settlement bucket + router order record | router commit/distribute/forfeit through engine/clearinghouse | no | no | no | no |
| Liquidation-charge reserve | Trader, dedicated to the active position charge | `MarginClearinghouse.liquidationReserveUsdc` | engine/settlement sidecar | liquidation charge only | no separate pool asset | no | no |
| VPI rebate reserve | Trader, dedicated to `max(-vpiAccrued, 0)` | protected sub-balance of clearinghouse action reserve | engine/settlement sidecar | matching VPI clawback only; excluded from price-risk collateral, with underfunding treated as independent delinquency | no separate pool asset | no | no |
| Trader claim balance | Trader senior claim on pool liquidity | `CfdEngine.traderClaimBalanceUsdc` | engine create/service | same-account price-risk health and one-time price-loss netting only; never cash/action collateral | yes, as senior liability | yes | yes |
| Keeper bounty credit | Keeper margin credit | `MarginClearinghouse.balanceUsdc(keeper)` | engine/clearinghouse bounty settlement | no | no pool liability | no | no |
| Unsettled carry | Protocol-recorded carry obligation on an account | `CfdEngine.unsettledCarryUsdc[account]` | engine carry-checkpoint paths | eligible free settlement only; never PnL pledge or claim | only the remainder uncovered after projected free-settlement collection affects health | no | no |
| Treasury protocol fees | Protocol/treasury | Treasury account in `MarginClearinghouse`; `MarginClearinghouse.balanceUsdc(CfdEngine.protocolTreasury())` reports that balance | cash-collected execution and liquidation fee routing, settlement top-ups, treasury clearinghouse withdraw | no | yes, as clearinghouse-custodied protocol margin | no | no |
| Signed terminal price delta | LP marked ownership adjustment | `TerminalNavBookV2` queried through the authenticated Engine snapshot | Engine-only atomic, state-derived `syncFromEngine(...)` | n/a | not the endpoint admission reserve | cannot fund cash redemption | yes, identically for deposit activation and redemption pricing |
| Canonical pool assets | LP/protocol backing | `HousePool.totalAssets()` and accounting ledger | synchronized LP activation/funding plus accounting hooks | base physical solvency cash | yes | yes | yes |
| Pending LP deposit assets | Request controller | USDC in `TrancheVault` request escrow plus per-controller/per-epoch accounting | request, eligible cancellation, or pool-authorized activation | no | no | no | no, until activated |
| Activated LP deposit shares | Request controller | Shares in `TrancheVault` claim escrow plus claimable epoch accounting | atomic Router epoch settlement, then controller/operator claim | no | no separate asset claim | no | yes, through outstanding share supply |
| Pending LP redemption shares | Request controller; still exposed to tranche P&L | `TrancheVault` request/epoch queue; shares held by vault escrow and still in supply | request path plus pool-authorized settlement callback | no | no separate asset claim before funding | no | yes, through outstanding share supply |
| Funded LP redemption assets | Request controller | USDC held in `TrancheVault` claim escrow and claimable epoch accounting | atomic Router epoch settlement, then controller/operator claim | no | no longer part of pool | no | no |
| Excess assets | no owner until admitted | `HousePool.excessAssets()` | pool account/sweep paths | no | no | no | no |

Reachability note:
- Price-loss reachability is exactly same-account nettable claim plus PnL pledge, capped by the terminal curve.
- `CommittedOrder`, execution-bounty, liquidation-charge, VPI, and generic action reserves cannot enlarge that price cap.
- Each typed reserve may be consumed only for its matching obligation; bounded liquidation cleanup may separately forfeit abandoned order bounties.
- Negative lifetime VPI must be fully covered by its dedicated reserve. Underfunding independently blocks withdrawal
  and makes the account liquidatable; overfunding never increases price collateral.
- Carry checks first project collection from eligible free settlement. A fully covered amount does not worsen exact
  price-risk health; any uncovered remainder blocks withdrawal and makes the position liquidatable. PnL pledge plus
  same-account claim cannot offset it.

## Liveness vs Safety Choices

### Frozen oracle close-only behavior

- Liveness problem: risk-reducing users and keepers still need an exit path when live oracle updates stop.
- Chosen tradeoff: opens are blocked, but closes and liquidations may proceed inside explicit frozen/FAD windows.
- New risk: execution may rely on older marks than the live regime would permit, and the fixed spread does not scale with staleness inside that window.
- Pricing rule: voluntary closes keep normal signed VPI and the lifetime rebate clamp. During `oracleFrozen`, the fixed `frozenCloseSpreadBps` replaces the Pyth adverse-confidence price shift; live/FAD-only closes and liquidations retain adverse-confidence pricing.
- Ownership rule: paid spread belongs only to LPs and never credits protocol treasury. `frozenCloseSpreadBps` defaults to `50`, is 48-hour timelocked, must be nonzero, and is capped at `1,000` bps.
- Liveness rule: partial closes must fully settle separate action charges, including frozen spread, but price loss above the account cap is written off. Terminal full closes may waive an uncollectible action remainder. Neither creates a protocol liability or terminal deficit. Liquidations do not assess the spread.
- Protecting invariant: frozen execution remains close-only, and close preview preserves `frozenSpreadUsdc == frozenSpreadPaidUsdc + frozenSpreadWaivedUsdc`.

### Trader claim balance servicing

- Liveness problem: profitable closes and liquidation payouts should not revert only because the HousePool is temporarily illiquid.
- Chosen tradeoff: record senior trader claim balances instead of reverting the state transition.
- New risk: payout servicing becomes asynchronous and must respect seniority.
- Protecting invariant: trader claim liabilities remain senior in withdrawal, solvency, and reconciliation accounting.

### Synchronized LP epoch clearing

- Request-id derivation: let `t = block.timestamp`, `e = floor(t / 3,600)`, and `b = (e + 1) * 3,600`. Senior and
  Junior deposits and redemptions all use `requestId = e + 1` when `t < b - 300` and `requestId = e + 2` when
  `t >= b - 300`. Exact cutoff equality rolls forward without adding a new revert. The mutation paths derive the id
  through the vault's shared helper, while `getRequestEpochWindow()` exposes the canonical target and its next future
  change time.
- Boundary separation: the cutoff controls admission to a request epoch only. Maturity remains
  `currentEpoch >= requestId`, and a live-position settlement still needs a `PoolReconcile` basket whose earliest
  publish time is at or after the round-hour boundary. The cutoff does not bind price or freeze protocol state.
- Liveness problem: reserving the full dormant Senior NAV blocks Junior liquidity even when no Senior holder requested
  an exit.
- Chosen tradeoff: one permissionless Router call validates a post-boundary pool-accounting mark and reaches the
  Router-only `HousePool` coordinator in the same transaction. HousePool reconciles once, funds eligible matured Senior
  demand, then Junior demand, then activates Junior and Senior deposits. Pending shares remain exposed to P&L; funded
  assets move to claim escrow and are irrevocable.
- Protecting invariants: bounded processing cannot fall through to Junior while an eligible matured Senior head
  remains; same-transaction deposits do not finance withdrawals; every claimable asset is escrow-backed; claims do
  not reprice and remain callable independently of request pauses. Pool pause defers entries but does not block
  reconciled funding of matured exits. A no-progress pass reverts so permissionless callers cannot retain reconcile or
  carry checkpoints without advancing a queue. Oracle, Engine, pool, and vault writes share the same rollback frame.
  No request included at or after `b - 300` may increase the locked `e + 1` epoch, but cancellation may shrink it and
  removing its final request must preserve the ordered, acyclic queue links. After `b`, new requests may legitimately
  join numeric epoch `e + 2`, now the imminent epoch, until its own cutoff.

### Exact symmetric Terminal NAV

- Ownership problem: entry and exit share pricing must not apply different marked-liability assumptions.
- Chosen rule: both use `physicalAssets - totalTraderClaims + terminalLpPriceDelta`, with the signed delta computed from whole lots, exact entry cost, and account-capped collectible loss.
- Liquidity separation: a positive marked receivable affects share ownership but cannot fund redemption cash before collection; endpoint max liability remains the withdrawal/admission reserve.
- Protecting invariant: a current terminal deficit blocks deposit activation, and every position/pledge/claim transition synchronizes the account curve atomically.

### Clearinghouse liquidation-charge servicing

- Liveness problem: liquidation should not fail solely because immediate pool cash is unavailable.
- Chosen tradeoff: the total charge settles from the dedicated liquidation reserve through the clearinghouse, with independently
  rounded-down shares credited to the keeper and protocol treasury according to `keeperShareBps` and
  `protocolShareBps`; the exact remainder is transferred to LP claimant revenue.
- New risk: liquidation rewardability and LP fee collection depend on correct reserve funding and maintenance.
- Protecting invariant: the total charge is capped by the dedicated reserve; the configured shares sum to at most
  `10_000` bps, and the keeper, protocol, and LP allocations conserve the collected amount without consuming
  pre-existing pool cash. The default allocation is 50% keeper, 0% protocol, and 50% LP.

### Bounded queue cleanup

- Liveness problem: terminal cleanup must not become unbounded in global historical order count.
- Chosen tradeoff: per-account bounded queue traversal and explicit prune paths.
- New risk: queue behavior is more state-machine dense.
- Protecting invariant: terminal cleanup and close-intent projection traverse only account-local pending queues.

### Binding queued orders

- Liveness problem: allowing arbitrary user cancellations would turn the queue into an option-like mechanism.
- Chosen tradeoff: queued orders are binding until executed, expired, or failed by policy. The sole administrative
  exception is a persistent risk-off cutoff for opens that existed when RouterAdmin paused.
- New risk: user flexibility is reduced once committed.
- Protecting invariant: cutoff-invalid opens can never execute after unpause; their oracle-free terminal cleanup
  returns the exact remaining margin and bounty to free internal settlement without carry/NAV mutation or clearer pay.

### Atomic guardian containment

- Liveness problem: independent Router and HousePool pause transactions leave a race and partial-containment window.
- Chosen tradeoff: one immutable-bound coordinator pauses new trading risk and LP entry atomically, while closes,
  liquidations, redemption requests/funding, and funded claims remain available.
- New risk: the guardian can deny new opens and deposits, and physical order cleanup still consumes protocol-keeper
  gas because the trader receives the entire reserved bounty.
- Protecting invariant: the guardian can only add restrictions. It cannot unpause, configure, price, move funds, or
  make arbitrary calls; governance owns recovery. Lens observations and incident hashes remain advisory.
- LP limitation: HousePool pause does not itself unlock a matured deposit cancellation. Existing post-maturity escape
  conditions or later activation after recovery remain necessary.
- Follow-ups: LP request-off, LP settlement-off, and corrupted-queue quarantine are deliberately out of scope.

### Stale-mark close bounty commits

- Liveness problem: a trader with no free settlement may still need to queue a risk-reducing close that sources the fixed router bounty from active margin.
- Chosen tradeoff: close-bounty reservation may use the latest stored mark price even when it is stale, as long as a mark exists.
- New risk: commit-time close-bounty reservation may use an older mark than live execution would accept.
- Protecting invariant: this path only supports risk-reducing close commits and still excludes queued reservations from generic collateral reachability.

## Transaction Narratives

### Profitable close with immediate payout

1. Trader has a live position and commits a close.
2. Router reserves the close execution bounty from eligible free settlement without reclassifying PnL pledge.
3. Keeper executes the FIFO head under the current oracle regime.
4. Planner computes canonical close settlement, including signed VPI, fees, pending carry, and the fixed LP-owned spread if `oracleFrozen`.
5. Engine realizes carry and applies the close using the planner's exact loss/gain result.
6. Clearinghouse unlocks/consumes the relevant trader buckets.
7. If pool cash is available, the trader receives immediate settlement.
8. Clearinghouse-reserved bounty value is distributed and the order becomes terminal.

### Losing partial close

1. Trader commits a reduce-only close.
2. Router reserves the execution bounty and preserves the residual position path.
3. Keeper executes.
4. Planner allocates exact entry cost to the closed lots, nets same-account claim, consumes PnL pledge up to the pre-close cap, and reports any excess price loss as a diagnostic write-off.
5. Carry, VPI, execution fee, and any frozen spread use the separate action path; an uncollectible action remainder rejects the partial close, but uncollateralized price loss does not.
6. Engine retains any PnL pledge required to conserve the residual marked curve and atomically installs the remaining lots, entry cost, and collectible cap.
7. LPs receive only physically collected price/action inflow; the write-off creates no asset, claim, or deficit.

### Underfunded frozen full close

1. Trader commits a full close while `oracleFrozen`.
2. Planner applies normal signed VPI with the lifetime rebate clamp, then assesses the fixed spread on the full reduced notional.
3. Terminal price settlement consumes same-account claim plus PnL pledge up to the account cap; action charges use gain withholding, protected VPI reserve, spendable action reserve, and eligible free settlement.
4. The retained or collected spread is booked as LP revenue; it is never routed to protocol treasury.
5. Any uncollectible spread is exposed as `frozenSpreadWaivedUsdc` and creates no protocol liability or terminal deficit.
6. Price loss above the precommitted cap is emitted as `PriceLossWrittenOff`, creates no debt accumulator, and the full close removes the account curve.

### Liquidation with positive residual

1. Keeper calls liquidation on an under-maintenance account.
2. Planner computes exact price PnL, carry/action obligations, and health from typed account buckets.
3. Total liquidation charge is capped by the dedicated liquidation reserve.
4. Settlement credits the configured reserve shares to the keeper and protocol
   treasury, routes the exact rounding remainder to LPs, and computes any fresh trader payout or explicit subsidy
   shortfall.
5. Existing same-account trader claim is not generic collateral; it may net exactly once against that account's price loss.
6. If cash is available, fresh payout is immediate; otherwise it becomes a trader claim.
7. Position is removed and queue cleanup runs on the liquidated account's local pending-order queue only.

### Liquidation with price-loss write-off and trader-claim netting

1. Keeper calls liquidation on an account whose claim plus PnL pledge cannot cover exact marked price loss.
2. Planner computes the collectible price amount and the diagnostic excess separately from carry/action charges.
3. Total liquidation charge is capped by its dedicated reserve and allocated using the configured keeper and protocol
   shares, with LPs receiving the exact remainder.
4. Existing same-account trader claim is netted exactly once, then PnL pledge is transferred to HousePool.
5. Price loss above that cap emits `PriceLossWrittenOff` and creates neither protocol debt nor LP deficit.
6. The VPI reserve and other action sources settle only their typed obligations; an uncollectible terminal action remainder is waived.
7. The position and terminal curve are removed, and `degradedMode` may latch only from the actual post-op physical solvency state.

## Read-Surface Canonicality

- `PerpsPublicLens` is the canonical product-facing read layer.
- `SettlementMonitorLens` is the canonical bounded keeper/security view for an explicitly observed LP epoch. The
  argument does not select what the Router settles: eligible FIFO heads remain authoritative. Its route, oracle,
  queue, custody, and invariant outputs are observations rather than authorization. Simulate the exact route-specific
  call before broadcasting: direct `HousePool` settlement for `CachedMark`, or `OrderRouter` with the exact Oracle
  payload and value for `AtomicOracleRefresh`. Construction validates required one-time core wiring and health
  rechecks reciprocal bindings.
- Review `getSettlementStatus(observedEpoch)` operational blocker/warning/deposit-deferral masks separately from
  `getSettlementHealth()` critical-fault/dependency-failure masks. Within status,
  `executionPathDependencyMask` contains only read failures that prevent route selection, while
  `dependencyFailureMask` covers every unknown status input. The Senior deposit-deferral mask describes pending
  activation and reservation-limit state rather than new-request admission capacity. Poll status routinely;
  `getSettlementObservation(observedEpoch)` is a checkpoint/alert read with a roughly 6 KB ABI return and about
  0.8–1.3 million gas of representative `eth_call` execution.
- Treat the canonical matured-head getters as route authority. Auxiliary queue lifecycle, membership, neighbor-link,
  and endpoint reads harden health classification but cannot replace a known canonical route; impossible canonical
  head pairs are critical. Verify `ActivationNotConfirmed` against
  `HousePool.canSettleDepositEntries()` and canonical redemption evidence. The Pool projection must include zero-asset
  epochs that retain pending claimants; the Lens must remain conservative while matured Senior redemptions can change
  principal/HWM rounding and while matured Junior redemptions can reduce Senior capacity. Live settlement must recheck
  both gates after funding. Include the zero-fee rebootstrap/redemption regression that creates one-atom impairment
  and the same-epoch Junior-redemption/Senior-reservation regression. Do not treat the view as new-request admission
  capacity.
- Runtime wiring checks pin the Engine planner address and code hash, probe its carry-index and market-calendar ABIs,
  and require seed receiver/floor pairs to be consistently absent or present. Review the creation-input size regression as well as
  EIP-170 runtime sizes because the facade embeds the sidecar creation code.
- `getPoolReconcileOracleStatus()` diagnoses only current readable feeds and requires the updated
  `PletherOracle.getLatestPoolReconcilePrice()` return ABI; an older oracle is reported as an unknown Oracle
  dependency. `observationComplete` requires every Oracle dependency read even on cached/no-work routes, while
  current Oracle policy validity is required only for atomic-refresh routing. `getSettlementObservation(...)` and
  `observableConfigDigest()` provide advisory block-pinned comparison hashes that the Router does not enforce.
  `completeObservationDigest` equals `observationDigest` only when `observationComplete` and is otherwise zero; it is
  still unauthenticated. Because confidence describes the neutral pre-cap basket while the returned mark may be
  capped, `confidence / markPrice` cannot always reproduce the configured confidence-ratio decision.
- `CfdEngineAccountLens` and `CfdEngineProtocolLens` are audit/operator/diagnostic surfaces.
- Engine getters are runtime internals unless explicitly documented as part of the product or audit-facing read surface.
- When in doubt, prefer `PerpsPublicLens` for integrations and the richer lenses only for diagnostics, tests, and audit review.

## Invariants Auditors Should Keep In Mind

1. Preview/live parity: canonical close and liquidation planner outputs should match live settlement semantics.
2. Physical-first solvency: physical cash and mathematical claims are distinct objects.
3. Trader-claim seniority: trader claim balances remain senior until settled.
4. Carry isolation: project pending carry from eligible free settlement first; only an uncovered remainder blocks
   withdrawal or makes the position liquidatable, and exact price-risk backing cannot offset it.
5. Bounded queue behavior: cleanup and close-intent projection are account-local.
6. Reservation conservation: clearinghouse-reserved execution bounty value and admin-held ETH refund claims are each distributed, refunded, forfeited, or left claimable exactly once.
7. Exact symmetric NAV: deposits and redemptions use the same signed terminal delta; marked trader losses count only to the account cap and never as spendable withdrawal cash.
8. Frozen-spread conservation: assessed spread equals LP-paid spread plus terminally waived spread; live/FAD-only closes and all liquidations assess zero.
9. Terminal-curve parity: after every successful transition, the bound Engine has atomically called the book's sole mutation endpoint and every account curve matches live lots, exact entry cost, side, and `pnlPledge + nettable claim` cap.
10. Monitor epistemics: a failed dependency read must remain distinguishable from healthy zero state, every Oracle
    dependency is required for a complete composite even if its feed policy is not required by the selected route,
    cutoff totals are maximum membership because cancellations may shrink them, and bounded aggregate checks do not
    prove per-account curve or radix-node parity.

## Test Map

Use the suites below as the highest-signal audit companions.

| Theme | Primary suites |
|-------|----------------|
| Carry | `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/CfdEnginePlanRegression.t.sol`, `packages/perps/test/perps/MarginClearinghouse.t.sol` |
| Trader claim modes | `packages/perps/test/perps/TraderClaimsMatrix.t.sol`, `packages/perps/test/perps/CfdEngine.t.sol` |
| Liquidation | `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/invariant/PerpTraderClaimInvariant.t.sol` |
| Payout modes | `packages/perps/test/perps/PayoutModesMatrix.t.sol`, `packages/perps/test/perps/CfdEngine.t.sol` |
| Trader claim liabilities | `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/invariant/PerpTraderClaimInvariant.t.sol` |
| Economic conservation | `packages/perps/test/perps/invariant/PerpEconomicConservationInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpAccountingInvariant.t.sol` |
| Multi-account isolation | `packages/perps/test/perps/invariant/PerpMultiAccountInvariant.t.sol` |
| FIFO / expiry / queue | `packages/perps/test/perps/OrderRouter.t.sol` |
| Atomic emergency pause / persistent risk-off refunds | `packages/perps/test/perps/EmergencyPauseCoordinator.t.sol`, `packages/perps/test/perps/OrderRouterRiskOff.t.sol`, `packages/perps/test/perps/EmergencyRiskOffGas.t.sol`, `packages/perps/test/perps/TimelockPause.t.sol`, `packages/perps/test/perps/LiquidationBatch.t.sol`, `packages/perps/test/perps/invariant/EmergencyRiskOffInvariant.t.sol`, `test/scripts/ArbitrumSepoliaReleaseDefaults.t.sol` |
| Frozen oracle / FAD | `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/invariant/PerpOracleBoundaryInvariant.t.sol` |
| Oracle refresh / ETH refunds | `packages/perps/test/perps/invariant/PerpOraclePathInvariant.t.sol` |
| Fee accounting | `packages/perps/test/perps/invariant/PerpFeeFlowInvariant.t.sol` |
| Open/close/liquidation preview parity | `packages/perps/test/perps/invariant/PerpPreviewInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpClosePreviewParityInvariant.t.sol`, `packages/perps/test/perps/PreviewExecutionDifferential.t.sol` |
| LP reserve / withdrawals | `packages/perps/test/perps/MarginClearinghouse.t.sol`, `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/HousePool.t.sol` |
| HousePool snapshot parity | `packages/perps/test/perps/HousePoolSnapshotParity.t.sol`, `packages/perps/test/perps/PerpsReadParity.t.sol` |
| Exact terminal NAV / close conservation | `packages/perps/test/perps/TerminalNavBookV2.t.sol`, `packages/perps/test/perps/TerminalNavCloseConservation.t.sol`, `packages/perps/test/perps/TerminalNavIntegrationSecurity.t.sol` |
| HousePool lifecycle / cooldown | `packages/perps/test/perps/invariant/PerpHousePoolLifecycleInvariant.t.sol` |
| Governed senior capacity / delayed reservations | `packages/perps/test/perps/SeniorCapacity.t.sol`, `packages/perps/test/perps/FrozenLpFeePolicy.t.sol`, `packages/perps/test/perps/invariant/GovernedSeniorCapacityInvariant.t.sol` |
| Router policy matrix | `packages/perps/test/perps/OrderRouterPolicyMatrix.t.sol` |
| Stale-mark / reconcile behavior | `packages/perps/test/perps/HousePool.t.sol`, `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/AuditV2.t.sol`, `packages/perps/test/perps/AuditV3.t.sol` |
| Settlement monitor / cutoff observation | `packages/perps/test/perps/SettlementMonitorLens.t.sol`, `packages/perps/test/perps/LpRequestCutoff.t.sol` |
| Audit-history regressions | `packages/perps/test/perps/AuditCurrentFindingsVerification.t.sol`, `packages/perps/test/perps/AuditFindings.t.sol`, `packages/perps/test/perps/AuditV2.t.sol`, `packages/perps/test/perps/AuditV3.t.sol` |

Historical or obsolete regression names that still mention legacy spread labels are audit-history artifacts, not live accounting concepts. When those names appear, trust the surrounding comments and the current accounting docs rather than the historical label.

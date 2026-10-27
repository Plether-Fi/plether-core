# Security Assumptions And Known Limitations - Perps

This document describes the trust model, protocol invariants, failure-containment design, and known limitations for the Plether perps system.

It is written as an audit-facing companion to:

- [`README.md`](README.md) for the high-level product and architecture story
- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md) for the canonical accounting model
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md) for the custody and state-boundary map
- [`test/perps/TEST_MAP.md`](test/perps/TEST_MAP.md) for executable evidence, independent models, and test limitations

## Security Model In One Page

The perps system is built around a few core security choices:

- bounded trader payouts through a capped market price,
- delayed-order execution through a keeper-run FIFO router with caller-pinned deadlines, configuration, execution
  regimes, and financial bounds,
- strict separation between trader custody, router intent records, engine accounting, and LP capital,
- permanent account-scoped client-id resolution and authenticated terminal receipts in an immutable lifecycle Book,
- exact-shape failure classification: only known typed policy failures are terminal, while unknown, panic,
  out-of-gas, empty, and malformed failures preserve retryability,
- exact symmetric LP NAV that counts only account-capped collectible marked losses as receivables and never as
  withdrawal cash before collection,
- liability-scaled settlement headroom for risk-increasing admission and LP redemption funding,
- fail-soft terminal settlement through trader claim balances,
- degraded-mode containment if a terminal transition reveals insolvency.

The protocol is intentionally non-upgradeable. Admins can tune risk parameters and pause certain entrypoints, but they cannot swap logic or rewrite deployed code.

## Review guide

Start with the [accounting quantities and views](ACCOUNTING_SPEC.md#reading-the-accounting-model), then use the
[architecture map](INTERNAL_ARCHITECTURE_MAP.md) to identify custody, state ownership, and callers. For each path,
review these questions in order:

1. Does execution apply the canonical planner's economics, including projected carry, rather than recomputing a
   different settlement result?
2. Does value cross only the intended custody boundaries, with each reserve used for its permitted obligation?
3. Do the oracle regime, pinned order bounds, and [failure policy](#queue-failure-handling) agree with the path?
4. Are queue traversal and cleanup bounded, trader claims protected, and reservations resolved exactly once?
5. Does every change to lots, exact entry cost, side, PnL pledge, or nettable claim atomically synchronize the
   affected terminal curve? Credit-only free-settlement funding changes none of those inputs.
6. Do failed calls restore the entire affected accounting frame, while deliberately isolated batch items retain
   already completed work?

The [transaction walkthroughs](#transaction-walkthroughs) below connect these checks to settlement flows. The
[invariant tables](#critical-protocol-invariants) define the properties to trace; the
[test map](test/perps/TEST_MAP.md) identifies exact test entrypoints, execution profiles, and gaps.

Distinguish specification examples, sequence invariants, and focused regressions when reading tests. A test name or
folder does not establish model independence. Preview/live parity can miss an error shared by both implementations;
look for independent arithmetic or economic end-state assertions. Synthetic-state fixtures establish local behavior,
not that the fixture is reachable through the public lifecycle. Historical finding names and passing examples do not
define policy or establish the absence of defects.

## Upgradeability And Admin Surface

All perps contracts are non-upgradeable.

- No proxy patterns.
- Runtime logic is fixed at deployment.
- Core constructor parameters such as `CAP_PRICE` are immutable.
- `OrderLifecycleBook` is independently predeployed and immutable-bound to the predicted Router and its exact Engine,
  Clearinghouse, and HousePool dependencies. The Router constructor validates all four bindings before accepting it.
  `CfdOrderPolicyEvaluator` and `OrderRouterExecutionSidecar` are separately deployed stateless code dependencies
  fixed by a fresh Router; none has an upgrade setter.
- `OrderRouter`'s configured `PletherOracle` address can be rotated only through `OrderRouterAdmin`'s 72-hour timelocked oracle config flow. Feed ids, basket weights, base prices, inversion flags, and the Pyth endpoint are fixed on each `PletherOracle` instance, so changing them requires deploying a new oracle and timelocking the router onto it.

### Timelocked admin state

The following parameter families are owner-controlled behind a 72-hour propose/finalize delay.
Engine risk controls live in `CfdEngineAdmin`, and router risk controls live in `OrderRouterAdmin`, with each deployed admin contract applying finalized values onto its host contract:

Both admins expose `activeConfigVersion`, initialized to one. `CfdEngineAdmin` increments it only after successful
risk, calendar, or freshness finalization; `OrderRouterAdmin` increments it only after successful Router or Oracle
configuration finalization. The versions are execution-authority inputs, not timestamps or proposal counters.

`CfdEngine` dependencies (`CfdEnginePlanner`, `CfdEngineSettlementSidecar`, `CfdEngineAdmin`) are deployed separately and wired once via `setDependencies(...)`. That wiring is owner-only and one-time. The engine rejects a settlement sidecar or admin bound to another engine and rejects a no-code admin address; selecting and verifying the intended `CfdEngineAdmin` bytecode remains a deployment responsibility.

`TerminalNavBookV2` is also deployed separately and wired once through `setTerminalNavBook(...)` before any exposure.
The Engine accepts only an empty book immutably bound to itself with matching `CAP_PRICE` and the canonical `1e20`
size quantum.

| Parameter | Contract | Guard |
|-----------|----------|-------|
| `EngineRiskConfig` (`riskParams`, `executionFeeBps`, `frozenCloseSpreadBps`, `settlementBufferBps`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 72-hour timelock |
| `EngineCalendarConfig` (`fadDayOverrides`, `fadRunwaySeconds`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 72-hour timelock |
| `EngineFreshnessConfig` (`fadMaxStaleness`, `engineMarkStalenessLimit`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 72-hour timelock |
| `seniorRateBps` | `HousePool` | `onlyOwner`, 72-hour timelock |
| `markStalenessLimit` | `HousePool` | `onlyOwner`, 72-hour timelock |
| `seniorFrozenLpFeeBps`, `juniorFrozenLpFeeBps` | `HousePool` | `onlyOwner`, 72-hour timelock; each fee is capped at `1,000` bps |
| `maxSeniorExposureAssets`, `maxSeniorShareBps` | `HousePool` | `onlyOwner`, 72-hour timelock; finalized values must be finite and below 100%, respectively |
| Junior `maintenanceFeeAprBps`, `maintenanceFeeRecipient` | `TrancheVault` | current `HousePool.owner()` only, 72-hour timelock; fee is capped at `10,000` bps (100%) nominal APR |
| `RouterConfig` (`maxExecutionWindowSeconds`, staleness limits, confidence policy, historical settlement window, component skew, opening minimum, bounty rates/limits, pending-order cap, minimum execution gas, cleanup cap) | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 72-hour timelock |
| `OracleConfig` (`pletherOracle`) | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 72-hour timelock |

Each successful Engine/Router finalization therefore changes
`OrderLifecycleBook.currentExecutionConfigHash()`. Proposal, cancellation, pause/unpause, and failed finalization do
not advance these versions.

The release-script `frozenCloseSpreadBps` default is `50` bps (0.50%). Both construction and timelocked updates reject zero and values above the `1,000` bps (10%) hard cap.

The constructor `settlementBufferBps` default is `25` bps (0.25%). Timelocked updates accept the inclusive range
`0..1,000` bps; zero disables the additional headroom without changing raw solvency or degraded-mode semantics.

### Owner-funded recapitalization

`CfdEngine.recapitalizePool(amountAssets)` is an immediate, owner-only, non-reentrant recovery action.
The engine owner approves the engine to pull USDG from its own wallet directly into the configured HousePool.
The engine checkpoints carry against the old pool depth, verifies the exact token balance increase, and records
`Recapitalization` with `CashArrived` atomically. Existing excess cannot substitute for the incoming transfer.
The pool queues claimant allocation for normal reconciliation; no shares are minted and degraded mode is not
automatically cleared. Funding remains available with stale marks, frozen markets, and LP pause or settlement holds.
`CfdEngineAdmin` retains its configuration-only role.

### One-time wiring

These are one-time configuration setters rather than mutable governance knobs:

| Setter | Contract |
|--------|----------|
| `setDependencies(planner, settlementSidecar, admin)` | `CfdEngine` |
| `setTerminalNavBook(address)` | `CfdEngine` |
| `setPool(address)` | `CfdEngine` |
| `setOrderRouter(address)` | `CfdEngine` |
| `setEngine(address)` | `MarginClearinghouse` |
| `setSeniorVault(address)` | `HousePool` |
| `setJuniorVault(address)` | `HousePool` |

The Router additionally fixes the Engine, Engine lens, HousePool, keeper sidecar, policy evaluator, execution
sidecar, and predeployed lifecycle Book at construction. The lifecycle Book is the eighth and final Router constructor
dependency; it fixes the predicted Router plus the Engine, Clearinghouse, and HousePool and accepts mutations only
from that Router. The Router rejects missing Book code or any mismatched immutable binding. These are constructor
bindings, not entries in the mutable setter table. The stateful position-protection Book remains Router-created.

Not every one-time setter validates reciprocal interfaces: `CfdEngine.setOrderRouter`,
`MarginClearinghouse.setEngine`, and the two HousePool vault setters accept a nonzero address without proving the
expected binding, and `CfdEngine.setDependencies` does not validate the planner implementation. Deployment must
verify these addresses, runtime bytecode, and reciprocal bindings before funding. One-time wiring cannot repair a
wrong address later.

`SettlementMonitorLens` construction validates the required core wiring and reciprocal bindings before fixing its
constructor bindings. `getSettlementHealth()` checks those bindings again at runtime, and the observable configuration digest
records the planner, settlement-sidecar, admin, Oracle/Pyth, vault, terminal NAV book, and asset identities for off-chain drift
comparison. This is detection only; the monitor cannot repair wiring or authorize a replacement.

`EmergencyPauseCoordinator` is independently immutable-bound to the exact RouterAdmin and HousePool. Deployment
installs it as both components' pauser. It does not trust or call the Lens: monitoring output, `reasonHash`, and
`evidenceHash` are advisory incident evidence, and only the configured guardian may trigger containment.

`HousePool` is also immutable-bound to a separately deployed, stateless `HousePoolRedemptionMathSidecar`. Construction
requires code and the exact implementation id. The sidecar exposes only pure redemption-budget calculations: it has no
storage, setter, delegatecall, upgrade path, custody, or settlement authority.

`OrderLifecycleBook`, `OrderRouterLiquidationBatchSidecar`, and `OrderRouter` are deployed as one consecutive
three-`CREATE` sequence. From the nonce immediately before the Book deployment, the Router address is predicted two
nonces ahead. The lifecycle Book is created first with that Router and the exact Engine, Clearinghouse, and HousePool;
the sidecar is created second with the same Router; and the Router is created third with no intervening
nonce-consuming operation. The Router constructor rejects a lifecycle Book without code or with any mismatched core
binding, rejects a sidecar with no code or one whose immutable `ROUTER()` does not equal `address(this)`, and exposes the
accepted address through `liquidationBatchSidecar()`. The sidecar has no mutable storage or upgrade setter and its
public/protected-open commit, active-oracle configuration, mark-refresh/protection-trigger, LP-epoch settlement, and liquidation selectors are valid
only under delegatecall where `address(this)` is that exact Router. Direct calls and delegatecalls from a foreign host
revert. Router self-callbacks remain self-only, so an external caller cannot use the sidecar to bypass Router
authorization or reentrancy guards. HousePool remains the canonical settlement-policy boundary, so delegated atomic
refresh cannot bypass its independent LP-epoch settlement hold.

V3 order execution instead uses the separately deployed reusable
`OrderRouterExecutionSidecar` fixed by the Router. It records its own deployment address only to reject direct
stateful calls; another contract can delegate it into that contract's own context, but cannot thereby impersonate the
protocol Router. Book, Clearinghouse, and Engine caller checks authenticate the actual Router address. `OrderRouterExecutionSidecar` also creates and permanently binds an `OrderRecoverySidecar` for expiry, invalid-order
cleanup, and non-Engine terminal receipts. The recovery module rejects direct calls; item helpers additionally require
an external Router self-call. All three delegated modules have no mutable storage or upgrade setter. Order item callbacks are Router-self-only and delegate back to the same fixed
execution sidecar, so an external caller cannot use a sidecar to bypass Router authorization or reentrancy guards.

This release requires a fresh, internally compatible stack. It does not migrate legacy Router queue storage into the
Book and must not be mixed with an already-wired Engine or a legacy Router ABI. A nonce-sequence failure leaves
unusable immutable-bound Book/sidecar deployments; neither may be rebound. Deployment must verify every constructor
and reciprocal binding before admitting margin, orders, or LP exposure.

### Instant owner controls

The owner can act immediately to:

- pause and unpause new `OrderRouter` opens and protection creation/replacement through `OrderRouterAdmin`,
- pause and unpause `HousePool`,
- pause and unpause `HousePool` LP epoch settlement independently,
- install or replace the common coordinator pauser on `OrderRouterAdmin` and `HousePool`,
- rotate or disable the coordinator guardian,
- set the protocol treasury account; existing balances remain withdrawable by their original accounts,
- initialize tranche seeds and activate trading after the lifecycle/capacity gates pass,
- admit unaccounted pool excess, sweep that excess, or assign unowned accounted assets through the guarded bootstrap
  path; these powers do not permit withdrawal of existing claimant backing,
- recapitalize the pool from the owner's wallet, clear degraded mode once raw solvency is restored, and rescue
  accidentally transferred non-settlement tokens from the Clearinghouse,
- initiate an ownership transfer, which the pending owner must explicitly accept through the `Ownable2Step` flow.

The owner cannot:

- change deployed logic,
- change `CAP_PRICE`,
- rewrite historical state,
- directly seize arbitrary user funds,
- bypass the core solvency and withdrawal accounting model.

## Critical Capability Boundaries

Several perps contracts intentionally expose narrow but high-authority capability surfaces.

- `OrderRouter` is the external execution boundary and can reach engine order/liquidation paths plus a narrow clearinghouse reservation surface. Router-sourced protocol value must credit the treasury account through clearinghouse accounting rather than calling `HousePool` inflow hooks.
- `OrderLifecycleBook` accepts registration and finalization only from its immutable Router. It permanently owns
  client-id resolution and compact outcomes but owns no funds and cannot execute an order. It is predeployed against
  a predicted Router, and that Router validates the Book's Router, Engine, Clearinghouse, and HousePool bindings in
  its constructor.
- `PositionProtectionBook` is created by and immutable-bound to the Router and Engine. It owns retained protection
  state, direct actions/views, the separate trigger-bounty lifecycle, and Router-only lifecycle hooks; it does not carry keeper or
  liquidation orchestration.
- `OrderRouterExecutionSidecar` is a fixed, stateless Router delegate dependency. It orchestrates Oracle, evaluator,
  Engine, Clearinghouse, and lifecycle Book calls under the Router's address, but it cannot be called directly to
  obtain Router authority. Its self-call item boundary and ABI forwarding are security-critical.
- `OrderRecoverySidecar` runs expiry, bounded invalid-order cleanup, reservation-mismatch recovery, and non-Engine
  terminal receipts through the execution sidecar. Its immutable address and delegate/self-call checks are part of
  the Router execution trust boundary.
- `CfdOrderPolicyEvaluator` is permissionless and stateless. It is not a custody authority; the Router sidecar pins
  its address, validates exact return shape, and compares selected assessed mode/account/position fields against live
  pre/post state.
- The separately predeployed `OrderRouterLiquidationBatchSidecar` carries stateless public/protected-open commit, mark-refresh/protection-trigger,
  single-liquidation, liquidation-batch, and LP-epoch orchestration to preserve Router deploy-size headroom. The Router
  is the only valid execution context for those helpers. Under `delegatecall`, they read integrations through external
  Router getters, never access Router storage by assumed layout, and change Router-owned state only through authorized external self/item
  calls. The Router remains `address(this)` and the direct-event address, Engine/HousePool see the Router as caller, and
  the Router entrypoint's `msg.sender` is preserved; the Book-trigger route authenticates keeper/refund identity through
  its trailing payload.
- `CfdEngineSettlementSidecar` is engine-gated, but any external function added there is automatically security-critical because it can reach engine-owned settlement hooks.
- `TerminalNavBookV2` accepts curve mutations only from its immutable-bound Engine. It has no owner, repair, or
  migration path. Engine wiring validates the bound Engine, price cap, size quantum, and completely empty book before
  accepting it once.
- `MarginClearinghouse` broad operator paths trust only `engine` and `settlementSidecar` to move trader custody across settlement and seizure buckets; router access is limited to reservation lifecycle paths needed for queued orders.
- Ordinary and protection close execution bounties are zero. Ordinary close commitment collects applicable carry and creates an
  authenticated Active zero Order record without moving free settlement or pledge into an execution reserve. Nonzero
  close-bounty configuration and nonzero close-commitment bounty are rejected; FIFO and queued-exposure checks still
  govern admission.
- Negative lifetime VPI is protected by a dedicated sub-balance of action reserve. Generic action collection must not
  cross the combined floor of protected execution bounties plus `max(-vpiAccrued, 0)`.
- `HousePool.payOut(...)` and `HousePool.recordClaimantInflow(...)` trust only `engine` and `settlementSidecar`; unsolicited raw pool cash must be admitted through owner-governed excess accounting, and protocol fees stay in treasury clearinghouse margin.

### Caller and dependency matrix

| Surface | Authorized caller/context | Security effect and failure rule |
|---------|---------------------------|----------------------------------|
| `OrderLifecycleBook.registerPending(...)` / `finalize(...)` | Immutable Router only | Permanently binds identity or terminal outcome; Book finalization is last and any failure rolls back the whole item |
| `OrderRouterExecutionSidecar.executeOrder(...)` / `executeOrderBatch(...)` | Productive protocol use is delegatecall from the Router that fixed this sidecar | Runs with the host's storage/address; direct calls are rejected, and a different delegate host does not gain the configured Router's authority |
| `OrderRecoverySidecar` stateful entrypoints | Delegatecall through the fixed execution sidecar; item helpers also require Router self-call | Preserves per-item rollback for expiry, config cleanup, mismatch recovery, and externally settled receipts |
| Prepared-item callback | Router external self-call only, then delegatecall to the fixed sidecar | Creates one rollback frame per order and preserves earlier batch progress on retryable item failure |
| Router reservation settlement callbacks | Router external self-call only | Release/refund reservation, pay/refund/forfeit the exact bounty, unlink and delete the live Router record |
| `CfdOrderPolicyEvaluator.assessOrder(...)` | Permissionless static call from the execution sidecar | Rebuilds Engine state and invokes its configured planner; typed policy failures may be terminal, unknown or malformed behavior may not be classified as terminal |
| `MarginClearinghouse.releaseOrderReservationForTerminalCleanup(...)` | Current Router only | Releases one reservation without a carry checkpoint inside the item rollback frame |
| `CfdEngine.processOrderTyped(...)` | Configured Router only | Applies the canonical plan; only exact known typed reverts are eligible for terminal classification |
| `MarginClearinghouse.reserveCommittedOrderMargin(...)` | Engine or Engine-reported Router | Locks margin to one order; terminal release is Router-only |
| Clearinghouse reserved-settlement lock / unlock | Engine, Router, or Router-created protection Book; unlock also permits settlement sidecar | Narrow action-reserve access; generic release preserves bounty and negative-VPI floors |
| Clearinghouse bounty-ledger mutations | Router for `Order`; protection Book for `ProtectionTrigger` | Each caller owns its reservation kind; close `Order` records are zero |
| `HousePool.payOut(...)` / `recordClaimantInflow(...)` | Engine or settlement sidecar; recapitalization inflow is Engine-only | Payout and ownership-routing authority does not extend to the Router |
| `HousePool.reserveSeniorDeposit(...)` / `releaseSeniorDepositReservation(...)` | Configured Senior vault only | Reserves or releases pending Senior-entry capacity |
| `HousePool.reconcile()` | Either configured tranche vault | Internal integration hook; users enter and claim through the vault |
| `HousePool.settleLpEpoch(...)` | Configured Router when positions exist outside frozen mode; otherwise permissionless | Live route binds the Router's exact mark/time; every route respects the settlement hold |

The no-carry release methods change reservation buckets only. Carry remains derived from canonical Engine indexes and
is assessed by the planner/Engine. On a retryable order item failure, the self-call revert restores the released
reservation, so a classifier cannot strand value between custody buckets.

Practical rule:

- any new external function on `OrderRouter`, `OrderLifecycleBook`, `OrderRouterExecutionSidecar`, or
  `OrderRecoverySidecar`, `CfdEngineSettlementSidecar`, and any new helper/sidecar that can reach these caller sets, must be treated as
  security-critical and reviewed like a core custody or settlement change.

## Critical Protocol Invariants

These are the highest-value properties an auditor should expect to hold.

### Solvency and containment

| Invariant | Description |
|-----------|-------------|
| Buffered entry solvency | With `P = pool.totalAssets()`, `C = totalTraderClaimBalance`, `E = max(P-C, 0)`, `L = max(globalLongMaxProfit, globalShortMaxProfit)`, and `B = ceil(L * settlementBufferBps / 10_000)`, every risk-increasing open/increase requires post-op `E >= L + B` |
| Degraded containment | If a close or liquidation leaves raw post-op `E < L`, `degradedMode` latches and blocks further risk expansion while still permitting protective transitions; `B` is deliberately excluded |
| Bounded price liability | Position price PnL is bounded by size, exact entry cost, and the price interval from zero to `CAP_PRICE`; returned collateral and separate action settlement are accounted for independently |
| Withdrawal firewall | Synchronized LP redemption funding is limited to conservative free cash after a base reserve of `C + L + B` plus any pool-level reservations |
| Matured Senior priority | A settlement cannot fund Junior redemptions while any eligible matured Senior demand remains unaccounted for |
| Funded-claim backing | Every claimable LP asset is held one-for-one in vault escrow and cannot be reused by `HousePool` |
| Trader claim liabilities are senior | Trader claim balance remains a senior claim on pool liquidity until serviced; keeper bounties are not pool liabilities |
| Explicit terminal deficit | Signed terminal liabilities above physical assets and collectible terminal receivables are persisted on fresh reconcile and block LP entry |

### Position and engine accounting

| Invariant | Description |
|-----------|-------------|
| Single direction per account | An account address holds at most one live directional position at a time |
| Margin sufficiency | Opens and withdraw-facing checks use explicit initial/maintenance/FAD margin policy surfaces |
| Side symmetry | Side-local cached accounting stays consistent with the live position set |
| Total margin conservation | `sides[LONG].totalMargin + sides[SHORT].totalMargin == sum(pos.margin)` across all live positions |
| Preview/live parity | Close and liquidation preview math should match live execution semantics |
| Frozen-spread conservation | For a valid frozen voluntary close, assessed spread equals LP-paid spread plus terminally waived spread; none is credited to protocol treasury |
| Exact-lot basis | Every live position uses whole 100-token lots and exact entry cost is conserved across increases and partial closes |
| Terminal-book parity | Each account curve matches its live side, lots, exact entry cost, and `pnlPledge + same-account claim` cap after every successful mutation |

### Router and reservation accounting

| Invariant | Description |
|-----------|-------------|
| Global FIFO | Price-dependent execution starts from the current global queue head; oracle-free invalid-order cleanup may remove a specific order without executing later valid orders |
| Binding intents | Users cannot cancel queued orders once committed |
| Permanent idempotency | `(account, clientOrderId)` is bound forever to one full intent hash; exact replay returns the original id before current-state validation and conflicting reuse reverts |
| Bounded authority | Every fresh order pins a nonzero target, deadline, mode mask, config hash, and inclusive financial limits; zero maxima are real zero allowances rather than unbounded sentinels |
| Configuration authority | The Book digest binds execution-critical identities and finalized Engine/Router config versions; execution against a different digest fails terminally |
| Retryable uncertainty | Unknown selectors, panic, out-of-gas, empty/malformed revert data, malformed success data, and mark-ordering failures never become guessed terminal policy failures |
| Terminal evidence | Every terminal transition finalizes one authenticated Book receipt after economic settlement; a receipt failure rolls back that item |
| Single terminal owner | Router records are fully deleted terminally, while the Book retains permanent client identity, lifecycle outcome, and the full-receipt hash |
| Bounty conservation | Clearinghouse-reserved opening and protection-trigger bounty value is conserved until distributed or absorbed, and is excluded from close-loss reachability while reserved; close records have zero amount |
| Zero ordinary close bounty | Ordinary and protection close attempts create authenticated Active Order records with zero amount. Nonzero close-bounty configuration and nonzero close-commitment bounty are rejected; no pledge is reclassified into a close escrow |
| Close queue admission | No pledge-specific empty-queue rule applies. FIFO, queued exposure, per-account capacity, position, carry, and financial bounds still govern close commitment |
| VPI reserve conservation | Every live negative lifetime-VPI balance has equal dedicated action-reserve backing; only an exact clawback, equivalent withholding, or lower surviving target may consume or release it |
| Reservation source of truth | Clearinghouse records own committed order margin, its active FIFO, all bounty classifications, and account bounty totals; Router and protection views compose these records |
| Protection post-lock safety | Existing-position protection uses exact entry basis and only PnL pledge plus same-account claim for price equity; free/action reserves are excluded, uncovered carry and underfunded negative VPI fail closed, and equality at the stricter initial/active threshold is rejected |
| Delegated Router isolation | The separately predeployed, exactly Router-bound keeper sidecar is delegate-only, storage-layout-independent, and cannot directly write Router storage; the Router remains `address(this)`, downstream caller, and direct-event address |
| Earliest lot gate | Router commit rejects non-100-token-multiple opens and closes before reserving value or assigning an order id |
| Economic close granularity | Partial close intents must meet the engine notional floor; only full residual closes may be smaller |
| Bounded cleanup | Queue cleanup, liquidation cleanup, and close-intent position projection are account-local and intentionally bounded |
| Credit-only funding | Exact token receipt increases beneficiary settlement only; no Engine hook, carry checkpoint, reserve allocation, or payer authority |
| Carry-safe reservation resolution | Opening-bounty release does not checkpoint carry. Ordinary close commitment still collects applicable carry with zero bounty; retryable item rollback restores the order and its authenticated zero record |

### HousePool and LP accounting

| Invariant | Description |
|-----------|-------------|
| Canonical asset boundary | Pool depth is based on `min(rawAssets, accountedAssets)`, not raw token balance alone |
| Economic depth | Carry, skew capacity, and VPI use canonical assets minus outstanding trader claims, floored at zero; physical custody and solvency inputs remain gross |
| Symmetric terminal NAV | LP entry and exit pricing use the same signed exact terminal price delta and waterfall snapshot |
| Receivable/cash separation | Positive marked receivables are capped by account PnL pledge and nettable same-account claim, and never increase physical redemption funding before collection |
| High-water-mark protection | Senior impairment must be restored before junior extracts surplus |
| Bounded new senior exposure | Counted admission exposure (`E + R`) cannot exceed the smaller absolute and senior-share headrooms |
| Junior covenant | Junior redemption funding retains enough Junior capital to back active protected Senior exposure plus accepted pending Senior reservations (`E + R`) under the configured share limit |
| Shared cutoff routing | Both tranches and both request directions use the same five-minute cutoff; exact equality rolls to the later epoch without a cutoff-specific revert |
| Locked-epoch additions | For boundary `b`, no request at or after `b - 300` may increase locked epoch `e + 1`, including after it matures; cancellation may still shrink it, while requests after `b` may join the new imminent numeric epoch `e + 2` until its own cutoff |
| Shared accounting inputs | Reconcile, synchronized redemption funding, deposit finalization, and LP status views consume the same canonical engine snapshot |
| Activation-aged cooldown | A deposit lot's cooldown begins only on successful activation; a later wallet claim preserves that timestamp and cannot shorten a newer receiver cooldown |
| Claim-escrow routing isolation | Direct redemption consumes one authorized controller's finalized deposit entitlement, preserves that controller on the destination request, and cannot capture another controller's lot |
| Share-escrow conservation | The routed amount decreases `depositClaimEscrowShares` and increases `pendingRedeemEscrowShares` equally without a token transfer; terminal cleanup may separately burn aggregate claim-share dust and checkpoint/mint Junior fee shares, after which vault share custody still equals the sum of both escrow counters |

### Coverage map

The tables above define intended safety properties. Their executable evidence, model independence, fixture limits,
and execution lanes are indexed in [`test/perps/TEST_MAP.md`](test/perps/TEST_MAP.md). Test coverage is evidence to
review against this specification; it is not proof that vulnerabilities are absent. Historical reports are linked in
[Audit evidence](#audit-evidence); implementation and validation history remain in Git.

## Trust Assumptions

### Pyth Network

The protocol assumes Pyth provides timely and correct FX feed data for the basket components.

Mitigations:

- delayed-order execution that settles against the first unique Pyth tick strictly after the recorded `commitTime` while the oracle is live, subject to the acknowledged [Arbitrum and Pyth clock alignment limitation](#arbitrum-and-pyth-clock-alignment),
- distinct staleness thresholds for order execution, liquidation, engine-side guards, and HousePool freshness,
- shared normalized basket-price construction across execution paths,
- timelocked rotation of the router's `PletherOracle` address if the Pyth endpoint or basket-feed set must be replaced,
- Oracle deployment and Router deployment/rotation reject Pyth endpoints without deployed code; this guards against
  empty-address misconfiguration, while governance remains responsible for selecting the correct Pyth implementation,
- conservative weighted basket confidence propagation, a timelocked aggregate pre-cap confidence limit, and side-adverse pricing for execution, equity checks, and liquidation, except that oracle-frozen voluntary closes replace the adverse price shift with the fixed frozen-close spread,
- component publish-time skew limits so a basket cannot mix fresh and stale legs,
- live current baskets parse signed prices for every component within a caller-independent window of at most 15
  seconds; component times cannot regress, equal-time marks cannot change price, and the newest component time
  advances the protection clock,
- live LP epoch reconciliation also requires every component to be published at or after the current epoch boundary,
- frozen-oracle regime for close liveness during genuine market closure.

Risks:

- compromised or stale feeds distort the basket price,
- unavailable historical update data can delay live order execution until a keeper supplies the commit-window tick or the order expires,
- frozen-market execution is intentionally liveness-first for risk reduction,
- exponent normalization truncates on scale-down,
- the basket-only confidence gate deliberately favors liveness over an individual-feed hard ceiling: a low-weight component with a wide confidence interval can pass when its weighted contribution keeps aggregate basket confidence within the configured limit,
- all live execution still depends on external oracle availability.

### USDG

The protocol assumes standard ERC-20 behavior and practical dollar parity from USDG.

Risks:

- blacklist risk,
- upgrade risk at the token level,
- collateral centralization risk,
- no mitigation inside the core perps design.

### OpenZeppelin and other dependencies

The system relies on the pinned dependency versions in this repository. Review the exact versions and their use in
this stack; an audit of a library does not establish the safety of its integration.

## Internal Trust Boundaries

### Owner

The owner can tune risk and liveness configuration and activate pauses, but cannot arbitrarily rewrite custody state.

### Guardian and emergency coordinator

`OrderRouterAdmin` retains its owner-controlled risk-off state. `HousePool` retains separate owner-controlled LP-entry
and LP-settlement states. Normal deployment installs one `EmergencyPauseCoordinator` as both components' pauser;
governance owns the coordinator and assigns its guardian.

- Only the guardian may invoke its three fixed actions: `triggerEmergencyPause` applies Router risk-off plus LP-entry
  pause, `triggerLpEpochSettlementHold` applies only the settlement hold, and `triggerFullContainment` applies all
  three restrictions atomically. There is no caller-supplied mask.
- Each transaction skips already-active restrictions; any downstream failure rolls back every change made by that
  call while preserving pre-existing state. `EmergencyContainmentTriggered` records the selected action, incident
  hashes, cutoff, and previous/new restriction masks.
- The coordinator can only add restrictions. It cannot unpause, change child configuration, set prices, move funds,
  or call arbitrary targets. Restrictions have no expiry. Governance retains direct owner-only recovery and role
  assignment.
- Router pause records an inclusive, monotonic order-id cutoff. Pending opens at or below it are permanently invalid,
  including after unpause; later orders are unaffected.
- Cleanup is permissionless and oracle-independent. It returns all remaining committed margin and execution bounty to
  the trader's free internal settlement, pays the caller nothing, and defers carry checkpointing to the trader's next
  ordinary margin mutation. The protocol incident keeper therefore funds cleanup gas. The terminal Book receipt uses
  reason `RiskOff`, execution mode and price source `None`, the cleaner as executor, and the account as bounty
  recipient with disposition `RefundedToAccount` when the bounty is nonzero. A zero bounty instead has disposition
  `None` and a zero recipient.
- Liquidation applies the same risk-off refund before forfeiting unaffected queued bounties, so cleanup-first and
  liquidation-first keeper ordering cannot change whether the invalidated-open reservation is refunded. Refunded free
  settlement remains ordinary trader capital and may still satisfy legitimate liquidation obligations. Liquidation
  reuses the exact single-order Clearinghouse reversal for each invalidated open; this is bounded by the 32-order
  account cap and remains inside one rollback frame.
- HousePool pause blocks LP entry only. Redemptions, synchronized redemption funding, and funded claims remain live.
  It does not itself unlock cancellation of a matured deposit; that request still needs an existing rejection,
  projected wipe, Senior impairment, or explicit settlement hold for a committed Senior request, or later activation
  after recovery.
- The independent settlement hold makes every synchronized epoch call revert before mutation, including direct
  cached/no-position and Router atomic-refresh routes. It stops new Senior requests and reservations while allowing
  existing Senior commitments to be refunded. Junior requests, redemptions, trading,
  recapitalization/reconciliation, and already-funded claims remain live.
- Trader closes/reductions, liquidations, and already-funded claims are deliberately outside guardian authority.
  Redemption-request-off, a global all-LP-request freeze, corrupted-queue quarantine, emergency pricing, and a
  global protocol freeze do not exist. Actions containing the LP-entry restriction do stop new deposit requests.
- A breaker is containment, not repair. Its release only restores eligibility to attempt the path and does not prove
  accounting, oracle, custody, liquidity, or queue health or guarantee transaction success.

### Keepers

Keepers are permissionless executors.

- They execute queued orders with oracle data.
- They trigger liquidations.
- They receive clearinghouse-reserved execution bounties or liquidation bounties depending on the path.
- They are not trusted with user intent beyond what the delayed-order model reveals.

### Position protection and Router keeper sidecar

The Router-created position-protection Book owns the retained OCO lifecycle and uses only narrow clearinghouse/Router
capabilities. It is stateful and distinct from the separately predeployed `OrderRouterLiquidationBatchSidecar`.
Router `delegatecall` uses
that sidecar only as a stateless bytecode carrier for public/protected-open commits, atomic protection-cancellation
close commits, mark refresh/protection-trigger resolution, single and batch
liquidation, atomic-refresh LP-epoch settlement, and the active-oracle forwarding step inside an authenticated Router
configuration finalization. The Router retains admin authentication and applies its storage fields in the original
before/after ordering. Delegated functions reject direct and foreign-context calls and must not read or write Router
storage slots by assumed layout.

The attached parent open is a caller-authored public V3 intent and must carry the same nonzero configuration hash and
financial bounds as an ordinary open. Only Router-authenticated triggered or retried close attempts may carry
`expectedConfigHash == bytes32(0)`. Zero is an internal unpinned marker, not a public wildcard: attempt creation runs
through the exactly Router-bound keeper sidecar or Router-only Book retry hooks plus Router-only registration hooks.
Fresh external V3 commits reject a zero hash and remain bound to the exact digest they supplied. Internal protection
close attempts skip only config-digest equality; their typed execution modes, deadlines, financial policy, lifecycle
evidence, and observed receipt digest remain enforced.

An owner may atomically replace an `Armed` protection with a caller-authored full close through
`cancelPositionProtectionAndCommitClose`. Ownership, armed status, exact live side/size, and an empty account queue
are checked before cancellation. The Router releases the unused trigger bounty without checkpointing carry before
ordinary close commitment. All commitment carry is then collected and recorded by the canonical close path, including
its gross-debit and action-charge bounds; any commitment failure rolls back the entire operation. The Book-only
Router host preserves public V3 admission,
configuration pinning, timing, mode and financial bounds. A returned historical replay id is rejected, so cancellation
cannot succeed without a fresh close. This path is available during frozen markets, Router pause, and degraded mode,
but does not bypass any execution limit. The resulting ordinary close has no protection-attempt marker; its later
failure or expiry does not rearm protection. Pending-open, triggered, and latched protections cannot use this action.
New automatic triggers still require live oracle policy and a publication newer than arming.

Triggering is irreversible. `Triggered` means the Book has exactly one current live child; `Latched` means the trigger
evidence and account trade lock remain but no child is live. A non-liquidation terminal child failure relatches only
when the protected position still has the exact recorded account, side, and size; otherwise the protection fails and
releases the active lock. Retry is permissionless and validates the latest child/reverse mapping so an old or spoofed
callback cannot replace the current attempt. It does not re-evaluate the threshold, and a recovered price cannot cancel
the close mandate.

The Router registers every generated close as a protection attempt in `OrderLifecycleBook`. A matching failed
attempt settles its authenticated zero Order record, pays no caller, and relatches the protection. A mismatched
position terminally fails it with the same zero-bounty outcome. Retry requires the exact protected position and
creates a fresh zero Order record without another trader debit. Decode older receipts with the ABI of their emitting deployment; current zero-bounty receipts use no retained-bounty disposition.
Expired reservation-mismatch recovery uses the same exact-position relatch decision before deleting the child. The
old order remains terminal with an `ExpiredReservationMismatch` receipt; disputed reservations retain their existing
quarantine/ownership rules. Relatching neither repairs the ledger nor invents a refund, and receipt failure rolls back
both recovery and the protection transition. Fresh retry eligibility does not bypass any remaining accounting checks.

Existing-position protection creation remains available in degraded mode because it adds no exposure. Router pause,
frozen-oracle policy, freshness, position/queue checks, and post-lock collateral admission still apply. Attached opening
orders retain the ordinary degraded-mode restriction on new risk.

When existing-position protection locks its trigger bounty, admission is checked after the lock.
The Book calls the Engine-configured planner's canonical `isExactPriceRiskLiquidatable(...)` predicate rather than
duplicating it. Inputs use `positionEntryCostAssetAtoms`; price collateral is only `position.margin` (the PnL pledge) plus
that account's trader claim. Free settlement and generic action, order, liquidation, VPI, and protection reserves cannot
rescue the test. Nonzero uncovered carry or a VPI reserve below `max(-vpiAccrued, 0)` rejects independently, and price
equity must be strictly greater than `max(initMargin, active maintenance/FAD margin)`.

### Engine and router vs clearinghouse

`MarginClearinghouse` grants broad operator authority only to the configured engine and settlement module, while the router address sourced from the engine boundary can reach only narrow reservation lifecycle paths.

The broad operators can:

- lock and unlock margin,
- settle USDG balances,
- seize settlement into protocol-authorized flows.

The router reservation paths can:

- reserve and release queued-order margin and execution bounty buckets,
- route reserved execution bounty value through engine-approved payout, refund, or forfeiture paths.

Those actors cannot:

- create negative balances,
- withdraw seized user funds to arbitrary third-party recipients,
- bypass clearinghouse bucket accounting.

### Credit-only funding and bridge destination calls

`MarginClearinghouse.depositFor(account, amount)` is permissionless funding from the caller's own token allowance.
It requires a nonzero beneficiary, positive amount, and exact receipt of the requested settlement token amount before
crediting that beneficiary's free settlement. It grants the payer no trading, withdrawal, or reserve-management
permission and does not require a beneficiary signature or deployed beneficiary code.

This path makes no Engine calls and cannot checkpoint carry, allocate position margin, change the mark, or alter the
terminal-NAV book. Existing carry remains due under normal health projections and subsequent account actions. Owner
`deposit` / `depositMargin` and withdrawals retain their existing checks and carry behavior. Indexers must treat
`DepositFor` as payer metadata for the accompanying `Deposit`, not a second credit.

Across funding uses an existing destination handler rather than a per-intent custody contract. The reviewed route
must bind the destination chain, SpokePool, handler, canonical USDG, clearinghouse, and trading-account beneficiary.
Its balance-based approval and `depositFor` calldata must use that exact token/clearinghouse/account. The explicit
call sequence then clears the allowance and emits the unique quote identifier through the pinned Across EventEmitter.
The fallback recipient must equal the beneficiary; a provider response cannot introduce a different recipient or extend
the approved call targets. Handler code and SpokePool proxy/implementation code are external trust dependencies;
verify their runtime hashes and the EIP-1967 implementation slot against the reviewed release. The handler callback
is permissionless and the handler is shared: funds must arrive with the atomic fill/callback, not through a standalone
transfer intended for later custody or recovery.

Source and destination evidence remain separate. Provider status, an unrelated clearinghouse deposit, or a wallet
token balance does not establish this intent's credit. Require its canonical fill, exact quote marker, and matching
confirmed `Deposit`/`DepositFor` events with the handler as payer, the intended beneficiary, token, and amount. A failed
destination call that returns tokens to the beneficiary is `needs-deposit`, not trading-ready margin. The application
must not resend a source payment merely because destination credit is pending or unavailable.

Token-binding validation does not prove that a clearinghouse implements `depositFor`; verify compatible deployed
code and a real credit probe. Existing immutable deployments are unchanged, and active V3 trading/AA compatibility
is a separate release requirement. Control of an undeployed trading-account beneficiary remains an application
assumption. This integration adds no per-intent factory or bridge-specific KMS signing/flush worker. Provider
availability and activation gates are described in [`BRIDGE_FUNDING.md`](BRIDGE_FUNDING.md).

## Oracle And Execution Security

### Delayed-order model

The router uses delayed commit/execute semantics rather than same-tx market execution.

A stale stored mark does not by itself prevent a close commitment. Commitment still checks the position, queued
exposure, applicable carry and partial-close health, and the caller's financial bounds, then records a zero bounty.
It does not promise an executable oracle price: live execution still needs valid updates and passes FIFO, timing,
slippage, and risk checks.

Security properties:

- every fresh request pins a nonzero account-scoped client id, target, deadline, execution-mode mask, exact active
  configuration digest, and explicit financial bounds before any reservation is created,
- the account/client-id mapping is permanent and hashes the chain, Router, account, and every request field; exact
  replay is a side-effect-free resolution even after terminal settlement, while conflicting reuse reverts,
- trader intent is committed before keeper execution,
- live-market execution uses Pyth's unique historical parse over `(commitTime, commitTime + orderSettlementWindow]`, capped at `block.timestamp`, so settlement is bound to the first tick after the recorded `commitTime` rather than the keeper's reveal-time tick; this is timestamp ordering, subject to the clock limitation below,
- the unique historical parse rejects skipped ticks because the parsed update must prove its previous publish time is no later than the order's `commitTime`,
- batch execution may reuse a parsed historical basket only for later FIFO orders whose `commitTime` is strictly before the cached tick and falls within its proven coverage,
- the neutral pre-cap basket is accepted only when `basketConfidence * 10_000 <= basketPrice * basketMaxConfidenceRatioBps`; equality passes, each weighted component contribution is floored before summation, and no independent component-confidence ceiling applies,
- confidence configuration is validated at proposal and oracle application: ratio <= 10,000 bps, multiplier <= 30,000
  bps, and their product < 100,000,000; accepted adjustments cannot consume the entire raw basket value,
- successful order execution quotes are strictly positive, including historical-cache reuse; a downward adjustment
  that exhausts the capped execution base reverts the execution call and preserves pending orders and protections,
- aggregate basket confidence is included in live/FAD execution and all liquidation prices instead of being treated only as metadata; oracle-frozen voluntary closes retain aggregate confidence-width validation but replace the adverse price shift with the fixed frozen-close spread,
- FIFO execution prevents later orders from bypassing earlier ones,
- partial-close size floors prevent dust closes from occupying global FIFO slots,
- binding order semantics and the lack of a user cancellation path prevent traders from turning queued intents into
  free options,
- the stateless evaluator reads a settlement snapshot with the Engine's live `settlementBufferBps` and calls the
  configured Engine planner before mutation. Planning and Engine execution enforce the configured buffer on opens
  and increases. Closes and liquidations may consume that headroom; raw post-settlement insolvency is contained by
  degraded mode. The execution sidecar checks selected assessment fields against actual pre/post state,
- the execution sidecar reserves a fixed post-Engine gas tail and finalizes the lifecycle Book only after economic
  settlement and Router-record deletion,
- batch execution also limits every item self-call and retains an outer gas tail, while Router and Oracle ETH refunds
  cap recipient-call gas and defer rejected refunds; a later gas-burning prepared item or refund recipient therefore
  cannot roll back an already finalized batch prefix,
- When historical data is unavailable, both execution entrypoints return
  `HistoricalPriceUnavailable` when the supplied payload has no qualifying historical tick. Single-order execution
  preserves earlier terminal cleanup and leaves the target pending without updating the mark. The Oracle refunds or
  defers the forwarded funding; the Router refunds only the excess, so each allocation is returned once.
- Unexpected historical parser errors still revert single-order execution and stop the batch with `OracleFailure`,
  preserving finalized predecessors and refunding the failed call's unspent funding. `HistoricalPriceUnavailable` means the supplied payload contains no
  qualifying update for at least one feed; it does not prove no such history exists elsewhere.
- Other Oracle/Pyth preparation failures and the resulting Engine mark update remain in the outer batch frame.
  A revert at that boundary reverts the complete batch; keepers that require a strict durable-progress boundary must bound
  `maxOrderId` and separate pre-oracle cleanup from price-dependent execution.

Deferred ETH belongs to the credited beneficiary. `OrderRouterAdmin.claimBalanceTo(recipient)` and
`PletherOracle.claimEthRefundTo(recipient)` let that beneficiary send its full credit to a nonzero payable recipient,
including when the beneficiary contract itself cannot receive ETH. Both debit only `msg.sender` before the
transfer; a failed transfer reverts and preserves the credit. The existing self-claim methods remain available.
Directed claims emit `EthRefundClaimedTo(beneficiary, recipient, amount)`; the Oracle's legacy self-claim event remains
unchanged. A beneficiary contract must be capable of invoking the claim API to redirect its refund.

### Known limitation: live basket component selection

A caller supplies signed Pyth updates for each feed in a current live basket. The oracle checks signatures through
Pyth, per-feed publish-time ordering, freshness, confidence, and the permitted gap between component publish times.
It cannot establish from those supplied updates that each component is the newest Pyth report available off-chain.
A caller may therefore choose an older, still-valid signed component within the allowed window and obtain a
different basket mark. This applies to live mark refresh, liquidation, and LP epoch settlement; historical order
execution has its separate post-commit parse and governed component-gap limit (default five seconds).

Liquidation or LP epoch settlement can consume the selected mark in the same transaction, so a later update cannot
undo an action already settled. Requiring simultaneous feed timestamps would impede feeds that publish at different
times; tightening the window reduces, but does not eliminate, caller choice. See
[ORACLE_SYNCHRONIZATION.md](ORACLE_SYNCHRONIZATION.md) for the tested policy and evidence boundaries.

### Arbitrum and Pyth clock alignment

`OrderRouter` records `commitTime` from Arbitrum `block.timestamp`. `PletherOracle` selects the first unique
eligible Pyth basket after that timestamp. These checks do not prove that the price first became publicly
observable after the trader submitted the order. If the sequencer timestamp trails an already-observed Pyth
update, that update may qualify. References to "post-commit" ticks describe this timestamp rule, not a
guarantee about when the trader first learned the price.

The implementation adds no fixed delay to compensate for this clock mismatch. A qualifying tick can already be
known at submission, so integrations must not describe the historical-price rule as a guarantee of an unknown future
price. Whether a particular mismatch creates an economic advantage depends on the observed timestamps, order, and
settlement path.

### Queue failure handling

An order starts `Pending`. Successful execution makes it `Executed`; an authenticated terminal rejection makes it
`Failed`. Both terminal states unlink the live queue record and settle its reservation exactly once, while the
lifecycle Book retains the permanent outcome and receipt hash. Neither state can reuse or requeue the same id.
Retryable failure leaves the same order `Pending`; users cannot cancel a queued intent.

Terminal classification is deliberately allow-listed:

- slippage-invalid orders fail terminally,
- expired orders fail terminally,
- configuration mismatch fails terminally before oracle/Engine execution,
- exact-shape typed planner rejections, execution-mode violations, and financial-constraint violations fail
  terminally and record selector/category/code/constraint evidence,
- ordinary open failure pays the executor from its reserved bounty; ordinary close failure settles its zero Order
  record and pays no executor,
- when the exact protected position remains after a registered protection-attempt failure, cleanup settles that
  attempt's zero record, pays no executor, and moves `Triggered -> Latched`; retry creates a fresh zero record,
- terminal-invalid closes move no bounty value. The separate protection-trigger bounty is paid only on trigger,
- open-order refunds and keeper payouts credit clearinghouse settlement rather than sending direct wallet USDG transfers,
- persistent risk-off cancellation is administrative invalidation, precedes expiry, needs no oracle, and fully refunds
  the trader's order plus attached `PendingOpen` protection reserves internally in one no-checkpoint clearinghouse
  release without paying the cleanup caller; its receipt records no price source and, for a nonzero order bounty,
  `RefundedToAccount`,
- liquidation cleanup records each remaining order as `AccountLiquidated` and preserves the original keeper as
  receipt executor. Unpaid opening bounties may be forfeited to treasury; zero close records move no value,
- close-only, same-block/MEV, historical-price availability, insufficient gas, and mark-price ordering remain
  nonterminal,
- an unknown selector, panic, out-of-gas, empty or malformed revert, or malformed success payload is never decoded as
  a business-policy failure. The item frame reverts, restoring any no-carry reservation release and leaving the order
  pending.

`executeOrder(...)` and `executeOrderBatch(...)` expose machine-readable `ExecutionResult` and `BatchResult` values
for completed calls. Each batch item uses an external Router self-call and a delegatecall back to the fixed sidecar,
so a prepared-item failure can stop the batch without rolling back already finalized predecessors. Oracle/Pyth
preparation is deliberately outside that item frame and is batch-atomic: if it reverts, the complete call reverts.
For an ordinary pending order there is no separate requeue operation: retry means calling execution again against the
same FIFO head. A terminal protection attempt is different: it has been permanently removed and receipted, so a
separate permissionless Book retry appends a new order id at the current FIFO tail.

### Pinned financial policy and configuration

The external V3 request sets inclusive maxima for execution bounty, execution notional, gross account debit, assessed
action charge, explicit fees, and post-position size, plus inclusive minima for post-settlement balance and
post-position equity and an inclusive maximum post-leverage. Zero is an actual zero allowance, not an unbounded sentinel. A field
that is separately required nonzero cannot use zero; integrations use the field type's maximum to express no
practical ceiling. In particular, a fresh external request, including an attached protection parent, must supply the
current nonzero execution-config hash. Only Router-authenticated TP/SL triggered or retried close attempts use zero as
the internal unpinned marker. A terminal full close skips only the post-position equity and leverage checks because no
position survives. Gross account debit
includes settlement value lost or charged, consumed trader-claim value, and the
reserved execution bounty; post-settlement balance means total internal settlement custody, including locked value.

`currentExecutionConfigHash()` binds the schema and chain; lifecycle Book, Router, Engine, Clearinghouse, HousePool,
execution sidecar, evaluator, and Oracle; both admin identities and monotonic active versions; the Engine planner and
settlement sidecar; protocol treasury; terminal NAV book; and HousePool mark staleness. It excludes dynamic
market/runtime values such as price, depth, position skew, FAD/frozen mode, Router/HousePool pause state, the LP
settlement hold, and the risk-off cutoff. It also excludes the immutable HousePool redemption-math sidecar because
that module affects only LP redemption budgeting, not order execution. This division is intentional: identity and
finalized policy drift produces terminal `ConfigMismatch` for config-pinned external orders, while execution mode and
economics must fit the separately pinned request bounds. The internal TP/SL close-attempt marker skips the
hash-equality check but still records the observed digest in its terminal receipt.

The request ABI and permanent intent-hash domain are V3. The receipt and execution-config domains are V5;
receipts authenticate the original submission limit, execution duration, commitment time, and resolved deadline. Cross-version digest or receipt-hash equality must never
be used as a compatibility signal.

Execution deadline equality passes. Expiry begins only when `block.timestamp > executionDeadline`. Fresh commitment
requires `block.timestamp <= submitBy` and a positive execution duration no greater than `maxExecutionWindowSeconds`.
The lifecycle Book resolves and retains `executionDeadline = commitTimestamp + executionWindowSeconds` exactly once.
Exact replay returns the original id and timing even after either deadline; timing changes under that id conflict.

The Book's execution-authority digest is separate from `SettlementMonitorLens.observableConfigDigest()` and its
observation digests. Monitor digests remain advisory drift evidence and are never accepted by the Router as an order
authorization or settlement commitment.

### Terminal receipt boundary

The lifecycle Book authenticates receipt identity against its pending intent and actual reserved bounty, records a
compact permanent outcome, deletes pending policy, and emits the full `OrderFinalized` receipt. The full receipt
includes identity and expected/observed config, status/reason/mode, executor, adverse execution price, neutral mark,
pool depth, oracle time, whether the price reached the Engine, bounty recipient/disposition, typed failure evidence,
and normalized economics fields. Its hash additionally commits to chain, Book, Router, terminal block, and terminal
time. For queued orders removed by account liquidation, the receipt's state-only economics use the state observed
after liquidation in both summary slots; Engine liquidation events remain the source for the position transition,
while the order receipt records any forfeited opening bounty and zero close-bounty movement.

At registration, `IntentRegistered` emits the complete `OrderRequest` preimage alongside its canonical hash and the
actual reserved bounty. Terminal verification therefore needs only canonical chain logs plus the Book's permanent
compact outcome; it does not rely on an agent retaining private request data.

Expiry and configuration mismatch are pre-oracle terminal paths: their receipts use `PriceSource.None`, zero
execution price and oracle publish time, and `priceReachedEngine == false`, even though they may report the stored
neutral mark and current pool depth as context. Risk-off uses the same no-price convention. Any terminal receipt with
a zero bounty must use `BountyDisposition.None` and the zero recipient. Mixed disposition values and the retained
bounty amount are absent from the current receipt ABI; decode historical receipts with their archived ABI. The Book
checks the authenticated zero record and receipt components exactly. Enum consumers, receipt decoders, internal
interfaces and storage require the compatible fresh stack.

Book finalization occurs last and is fail closed. If identity, status/reason, bounty, or event construction cannot be
finalized, the enclosing item reverts: Engine/Clearinghouse/Router changes are not allowed to persist without their
canonical lifecycle evidence. Full receipts are log data; only the compact outcome and hash remain in storage.

### Oracle regimes

The protocol distinguishes two states around market closure:

- `FAD window`: elevated margins and close-only risk policy while markets are still plausibly live,
- `oracle frozen`: relaxed staleness and relaxed publish-ordering rules once feeds are genuinely offline.

LP actions intentionally stay live across that split:

- `FAD` alone keeps ordinary LP pricing,
- `oracle frozen` keeps eligible synchronized redemption settlement live. Ordinary entry and exit remain
  asynchronous: a request does not lock a price, rate, or fee. Funded redemptions apply the then-active surcharge
  (default `25 bps` Senior, `75 bps` Junior), retain it in the same tranche for incumbents, and place only net assets into
  claim escrow. Deposit activation is deferred until the live symmetric-NAV entry gate passes; withdrawal funding is
  not blocked merely because entries are deferred.

Voluntary close pricing follows the same regime boundary but is separate from LP entry/exit fees:

- live and FAD-only close/reduce execution uses normal signed VPI with the lifetime rebate clamp, retains Pyth adverse-confidence pricing, and assesses no frozen-close spread,
- `oracle frozen` keeps that same signed VPI treatment, waives the Pyth adverse-confidence price shift for voluntary closes, and assesses a fixed spread on reduced notional instead,
- the spread is LP-owned and never protocol-treasury revenue,
- partial closes must settle required separate charges, while price loss beyond the account's collectible cap is a
  diagnostic write-off; an uncollectible spread portion on a terminal full close is waived without creating a
  protocol liability or terminal deficit,
- liquidation pricing and settlement retain adverse-confidence pricing and do not assess the spread.

This is a deliberate trade-off: preserve close and liquidation liveness during real closures without weakening live-market MEV protections.

## Accounting And Solvency Security

### Exact symmetric LP NAV

LP entry and exit pricing consume the same authenticated terminal snapshot. The Engine stores whole 100-token lots
and exact entry cost, while `TerminalNavBookV2` aggregates each account's LP-side marked price PnL. A positive LP
receivable is capped by that account's `pnlPledgeAssets + traderClaimBalanceAssets`. Liquidation, order and action
reserves cannot inflate it. A negative value is the exact marked price amount LPs owe the trader within the bounded
market. Ordinary and protection close attempts have zero bounty and no collectible escrow component.

Security consequences:

- new LPs receive the same marked-liability discount borne by existing LPs and do not inherit old trader obligations
  at a higher deposit NAV,
- losing-trader value above the account-specific collectible cap is excluded, preventing phantom receivables,
- marked receivables affect ownership pricing but remain unavailable to fund redemptions until physically collected,
- carry, VPI, fees, frozen spread, and liquidation charges stay outside the pre-close price book,
- realized partial-close price gains either replenish the surviving position's PnL pledge or become a nettable
  same-account trader claim; full-close price gains are free-settlement payouts or trader claims,
- gross negative lifetime VPI is backed by a dedicated nonwithdrawable reserve equal to `max(-vpiAccrued, 0)`; together
  with protected execution bounties it forms the action-reserve floor that generic charges cannot consume,
- opens/increases must fully fund any higher VPI target. Close and liquidation paths consume the reserve for realized
  clawback and leave the exact residual target protected; only genuinely excess or equivalently replaced value is
  released,
- new close-time action rebates use only pool cash free after protecting existing trader claims. Unfunded value is
  waived rather than claim-backed, and neither anticipated VPI nor its reserve inflates terminal `K` or symmetric NAV,
- a current terminal deficit blocks deposit activation,
- the Engine fails closed if the terminal book is absent or inconsistent, an open-position mark is unavailable, or an
  account mutation is in progress. `HousePool` independently rejects or defers LP actions under its configured mark-age
  and oracle-frozen policy.

Ordinary LP entry remains asynchronous: assets are funded into request escrow, a complete pending Junior deposit is
cancellable before maturity, and an accepted Senior deposit is a firm commitment. Senior refunds require epoch
rejection, projected terminal wipe, Senior impairment, or an explicit LP settlement hold. Shares are
minted only after synchronized `HousePool` settlement fixes the batch price. ERC-4626 `deposit` and `mint` only claim
already activated shares. The one-hour cooldown is timestamped at that successful activation, not at claim. A claim is
therefore an administrative transfer that propagates the source activation timestamp with
`max(receiverTimestamp, activationTimestamp)`; it neither restarts an elapsed cooldown nor weakens a newer receiver
cooldown. During a frozen entry state the request remains deferred, its activation timestamp remains zero, and
redemptions can still use the separate conservative cash-reserve path.

The additive `IAsyncTrancheVaultClaimableRedeem` surface permits the controller or an approved operator to consume
shares from one finalized deposit lot directly into a redemption request after that lot's activation-aged cooldown.
The destination controller cannot be changed. This path advances the same per-position claimed/consumed entitlement
accounting as an ordinary share claim, but moves no ERC-20 shares: it atomically reclassifies the amount from
`depositClaimEscrowShares` to `pendingRedeemEscrowShares`. The routed-share reclassification itself changes neither
custody nor supply; consuming the epoch's final entitlement may also burn allocation dust and materialize accrued
Junior fee shares under the existing terminal-claim rules. The final state still satisfies
`balanceOf(vault) == depositClaimEscrowShares + pendingRedeemEscrowShares`.
Partial routes remain subject to the ordinary minimum redemption estimate; the source lot's complete remaining
entitlement may exit below that threshold so terminal dust cannot be stranded.
It emits the dedicated `ClaimableDepositRedeemRequest` event rather than the canonical `RedeemRequest`, so indexers can
distinguish escrow-sourced requests from wallet-sourced requests. If the resulting request is later cancelled or its
terminal remainder is refunded, any shares delivered back to a wallet restart that receiver's cooldown at the return
time.

Atomic Engine-to-book synchronization is a critical trust boundary. Any path that changes position lots, exact entry
cost, side, PnL pledge, or same-account claim must finish by installing the matching curve or removing it. The
optimistic old-curve hash and monotonic book version protect against stale mutation plans; they are not a substitute
for invariant and differential testing of every settlement path.

A settlement pass that advances no queue item reverts, rolling back both waterfall reconciliation and engine carry
checkpoints. This prevents per-block no-op checkpoint grief. Senior coupon arithmetic still floors independently at
each settlement that advances real epoch work, so sub-micro-USDG rounding remains execution-frequency dependent; the
hourly aggregation of requests bounds that residual rather than making coupon accrual mathematically remainder-exact.

Async allocation uses per-controller floor rounding against immutable epoch totals. Splitting a request among more
controllers cannot increase aggregate entitlement. Ordinary deposit claims and direct deposit-to-redeem routing share
the same exact-share consumption and terminal-dust accounting, so neither path can reuse an entitlement consumed by
the other. Once all controllers reach terminal state, deposit-share dust is burned; funded-redemption share dust is
booked in the epoch's claimed-share counter; funded asset dust returns raw to `HousePool` without restoring
`accountedAssets` and therefore becomes excess; and refundable-share dust moves to the permanent seed account without
resetting its cooldown. These terminal sweeps prevent stranded escrow without allowing the final caller to capture
another controller's rounding remainder.

### Settlement-liability buffer

The settlement buffer protects a governed amount of physical headroom above the maximum directional payout envelope:

```text
P = HousePool.totalAssets()
C = totalTraderClaimBalance
E = max(P - C, 0)
L = max(bullMaxProfit, bearMaxProfit)
B = ceil(L * settlementBufferBps / 10_000)
```

Open and increase admission requires post-op `E >= L + B`. The LP cash firewall includes the same `B`, producing a
base reserve of `C + L + B`. The rate defaults to `25` bps and is bounded by governance to `0..1,000` bps inclusive.

This is a liquidity-headroom policy, not another economic liability. It is excluded from terminal NAV, yield,
raw degraded-mode detection, and all custody or clearinghouse reserve buckets. Closes, liquidations, and triggered
protection closes remain live and may consume it. Attached protection uses its parent open's admission result;
standalone protection changes on an existing position add no exposure and do not independently invoke the gate.

Consequently, `L <= E < L + B` is solvent but unavailable for new risk and LP redemption funding. Raw degraded mode
still latches only at `E < L` and may be cleared at `E >= L`; the full buffer need not be restored before clearing.

### LP-capital carry

The perps system uses LP-capital carry instead of a side-to-side rate mechanism.

- carry base: `max(positionMaxProfitAssets - activePositionMarginAssets, 0)`
- utilization denominator: `max(pool.totalAssets() - totalTraderClaimBalanceAssets, 0)`; a positive base at zero depth
  uses full utilization. Claim creation, consumption, and payment checkpoint both side indexes before changing depth
- accrual clock: wall-clock time
- stale/frozen behavior: carry does not pause during stale or frozen oracle windows
- claim/bounty credits: first collect available margin and free settlement, retain unpaid carry in `unsettledCarryAssets`,
  then apply the full incoming credit. The credit can fund retained arrears at a later checkpoint, including at the same
  timestamp; it is not collected or waived in this call. Claim liquidity checks run after collection, and any failure
  rolls back the collection and credit
- realization points: open, close, add margin, pool-asset changes, risk-parameter changes, and owner clearinghouse
  `deposit` / `depositMargin` / withdraw paths before the carry base/rate denominator changes. Owner deposits may
  collect realized carry from post-deposit settlement in the same transaction; withdrawals realize carry before
  reducing settlement. Credit-only `depositFor` makes no carry checkpoint and leaves accrued carry due
- destination: realized carry becomes LP trading revenue
- collection priority: active position margin first, then free settlement; all other locked buckets and trader claims
  remain protected during carry collection
- projection: planners and account views share `projectCarryLoss` for post-carry buckets. Its output must not alias
  raw custody; ledger diagnostics retain raw values. The planner updates side margin, borrowing bases, carry indexes,
  arrears and pool revenue together, using carry accrued against live depth even for hypothetical trade simulations
- health: project margin consumption before evaluating exact price risk. Fully paid carry is not delinquency, but a
  reduced pledge may breach maintenance. Carry uncovered by both margin and free settlement independently blocks
  withdrawal and makes the account liquidatable; claims cannot fund carry. Stored arrears alone are not delinquency
  when a subsequent credit has made backing available; health projects collection from the current buckets
- terminal settlement: first realize projected carry through the shared collector, then apply price settlement against
  reduced pledge. Only unpaid carry enters existing action recovery/waiver; count direct collection once in receipts,
  financial bounds and LP revenue
- NAV authentication: collection that changes margin is bracketed before collection. Per-account nested brackets
  authenticate and synchronize only at the outer boundary, preserve independent keeper mutations, and roll back on
  downstream failure. Intermediate terminal-NAV reads remain blocked by the existing transient guard

Close and liquidation security depends on using the planner's canonical carry-adjusted settlement outputs directly in the live executor rather than recomputing a second carry-blind kernel.

Security implication: oracle freshness still gates execution and LP accounting freshness, but not carry accrual.

### Trader claim liabilities

Terminal transitions are fail-soft when the HousePool lacks immediate cash.

- profitable closes can leave senior trader claim balances,
- trader claim balances are beneficiary-balance based rather than FIFO queue based,
- they remain part of reserve and solvency accounting until paid,
- terminal full-close settlement may waive an uncollectible frozen-close spread, but that waived amount is neither a trader claim nor a protocol liability.

This preserves risk reduction and liquidation liveness under temporary cash shortfall.

### Explicit netting boundary

Same-account trader claim balance is price-risk backing, not generic cash or action collateral.

- open/increase, trader-withdraw, close, and liquidation health use the exact same-account price-risk cap:
  `pnlPledgeAssets + traderClaimBalanceAssets`; VPI never adds to or subtracts from this price-risk equity,
- the separately funded VPI reserve backs only that account's typed VPI obligation: overfunding never adds price
  collateral, while backing below `max(-vpiAccrued, 0)` independently blocks withdrawal and sets the account lens's
  liquidation flag; close planning returns a typed failure and liquidation planning reverts on that reserve mismatch,
- the terminal book includes the claim in that same account's collectible price-loss cap,
- terminal settlement paths may explicitly net the same-account claim once against that account's exact price loss,
- the claim is not withdrawable cash and cannot fund carry, VPI, execution fees, frozen spread, liquidation charges,
  order margin, or other action obligations,
- when a claim is physically paid while its beneficiary has a live position, the credit goes directly to PnL pledge
  and the curve cap is resynchronized; crediting free settlement would allow withdrawal and double use,
- this avoids accidentally reusing a pool IOU as immediately spendable account cash.

## HousePool And LP-Specific Risks

### Canonical asset boundary

`HousePool` distinguishes:

- `rawAssets`,
- `accountedAssets`,
- `excessAssets`,
- `totalAssets() = min(rawAssets, accountedAssets)`.

Security purpose:

- unsolicited donations do not silently change economic depth,
- raw-balance shortfalls reduce effective backing immediately,
- all LP accounting works from a controlled economic boundary.

### Seed and senior-capacity lifecycle gate

The protocol blocks normal live operation until governance finalizes a finite absolute senior limit and a senior-share
limit below 100%, both tranche seeds exist within those limits, and trading is explicitly activated. Initial trading
activation also requires no stored or projected unassigned assets and no residual pending claimant assets.

This prevents partially initialized or uncapped live state and ambiguous ownership of early revenue flows.

### LP request cutoff and monitoring boundary

For `e = floor(block.timestamp / 3,600)` and next round-hour boundary `b = (e + 1) * 3,600`, every Senior deposit,
Junior deposit, Senior redemption, and Junior redemption targets `e + 1` before `b - 300` and `e + 2` at or after
`b - 300`. Equality deliberately belongs to the later epoch. The cutoff's incremental effect on an otherwise-valid
request is a one-epoch delay, not asset loss or a new revert; ordinary request gates remain active. Sequencer
inclusion time is authoritative, so a pending transaction may land on either side.

This creates a five-minute **maximum-membership** quiet period for the epoch about to mature. It is not an immutable
settlement snapshot:

- eligible cancellations can reduce deposit or redemption totals in the locked epoch,
- trading, closes, liquidations, claims, carry, and pool accounting can change NAV,
- governance configuration may change if an already-matured proposal is finalized,
- oracle state and confidence can change, and
- cancellation in one tranche or direction can change phase budgets or pricing.

Monitoring must therefore simulate current state and treat cutoff-time request totals as upper bounds. In particular,
the conservative case assumes all redemptions remain and no helpful deposits activate. Cancelling Senior redemptions
may expose more Junior funding, while cancelling Junior deposits can change later activation amounts or prices without
invalidating an accepted Senior commitment. Indexing,
alerting, sequencer publication, and transaction inclusion also consume part of the nominal five minutes, so the
operational reaction window is shorter. `SettlementMonitorLens` reads an explicitly observed epoch so a monitor can
keep following the closed batch after the request target rolls forward. That argument does not select what the Router
settles; eligible FIFO heads remain authoritative. `observableConfigDigest()` and the `observationDigest` returned by
`getSettlementObservation(observedEpoch)` help detect off-chain drift. `completeObservationDigest` repeats that hash
only when `observationComplete` and is otherwise zero, but it remains unauthenticated. None is a trusted batch commitment
and the Router does not accept or enforce them. This cutoff and lens add no signature, challenge period, or trading
freeze; the independently controlled HousePool settlement hold is a separate manual circuit breaker.

### Settlement-monitor trust boundary

`SettlementMonitorLens` is a read-only, bounded operator/security surface. `getSettlementStatus(observedEpoch)`
separates operational blockers, warnings, and deposit deferrals; `getSettlementHealth()` separately reports critical
faults and dependency-read failures. A reverted or malformed dependency read is unknown state, never a healthy zero.
Its checks can detect observable wiring, epoch-window, NAV aggregate, pool-backing, vault-escrow, and seed-floor
failures, but they do not enumerate accounts, radix nodes, or unbounded queues and cannot prove per-account
terminal-curve parity. `executionPathDependencyMask` is the narrow subset of status read failures that makes the
cached-mark versus atomic-refresh route unknown; `dependencyFailureMask` remains the complete status read-failure
set. Canonical matured-head getters are the sole route evidence: auxiliary lifecycle, link, membership, or endpoint
corruption degrades health without replacing a route that is still known, while impossible canonical head pairs are
critical. Projected deposit deferrals combine the tranche-neutral
`HousePool.canSettleDepositEntries()` pre-redemption projection with canonical redemption evidence, so residual
pending claimants remain visible even when an epoch's queued assets are zero. The Lens does not confirm either
tranche's activation while matured Senior funding can still change principal/HWM rounding. Junior funding protects
accepted Senior reservations and cannot displace their activation. HousePool rechecks the exact gates after redemption funding.
Senior HWM scales with net principal removed, so healthy withdrawals cannot create impairment through virtual-offset
pricing or retained fees; conservative rounding can preserve an existing impairment. The view does not
quote new-request capacity. The facade constructor rejects a Router whose immutable settlement pool differs from
`Engine.pool()` and deploys a code-size sidecar whose diagnostic builders accept only the constructor-bound
facade; its public `MONITOR()` binding remains readable, dependency bindings stay internal, and it has no setter or
delegatecall path. That
sidecar is a monitor-bound implementation detail, not another trusted public result surface.

The observable configuration digest commits the canonical Engine admin's nonzero `uint64` active configuration
version. Every successful Engine configuration finalization changes that version, including calendar-only updates
and identical reapplications; proposals, cancellations, and reverted finalizations do not. This provides a bounded
commitment to active calendar changes without enumerating override days. An unavailable or invalid admin/version
read makes the configuration digest zero and the composite observation incomplete with a zero complete digest.

The monitor reads `lpEpochSettlementPaused` fail-soft. A successful active read is intentional state rather than a
critical fault: it sets the explicit status flag, `OperationalBlocker.LpEpochSettlementPaused`, and
`DepositDeferral.LpEpochSettlementPaused`, while preserving cached-versus-atomic route classification for recovery.
A reverted or malformed hold read makes the Pool dependency unknown and the composite observation incomplete.
`LpEpochKeeper` rejects an active hold before decoding update data, quoting Pyth fees, or broadcasting.

The sidecar pins the Engine planner address and code hash at construction and probes the planner's canonical
carry-index and market-calendar ABIs before treating wiring as healthy. Seed receiver/floor settings must be consistently zero/zero or
nonzero/nonzero. Because the facade embeds the sidecar's creation code, EIP-3860 creation-input size is a release
constraint in addition to each contract's EIP-170 runtime limit.

Normal monitoring should poll the lighter `getSettlementStatus(observedEpoch)` view. The composite
`getSettlementObservation(observedEpoch)` also reads health, oracle, and configuration data; reserve it for
checkpoints and alert investigation and measure its RPC gas budget against the deployment. The Senior deposit-deferral mask
describes pending activation gates, not how much new Senior capital can be admitted; use the vault admission view for
request eligibility and `HousePool.getSeniorDepositCapacity()` for mathematical headroom.

`getPoolReconcileOracleStatus()` describes feeds readable at the observation block. It cannot certify a future Hermes
payload or the fee and publish times used by a later transaction. It requires the updated
`PletherOracle.getLatestPoolReconcilePrice()` return ABI; an older configured oracle causes a fail-soft Oracle
dependency failure rather than fabricated zero-valued feed health. Every Oracle dependency read must succeed for
`observationComplete`, even when the execution route is cached mark or no work; Oracle `policyValid` is required for
completeness only when atomic refresh is the selected route. Thus an older Oracle ABI always leaves
`completeObservationDigest == 0`, while a readable but currently stale or low-confidence feed need not invalidate a
cached/no-work checkpoint. Reported confidence is for the neutral pre-cap basket, but the returned mark can be capped,
so recomputing the ratio against `markPrice` is not always an independent policy check. Likewise, the reported
required execution path is advisory rather than an authoritative `canSettle` result. Keepers must quote and simulate
the exact route-specific call: direct `HousePool.settleLpEpoch(uint256,uint256)` with zero ETH for `CachedMark`, or
`OrderRouter.settleLpEpoch(bytes[])` with the exact `msg.value` for `AtomicOracleRefresh`. The selected contract and
EVM rollback frame remain the execution authority.

Cached-mark staleness is reported through `markFresh`, mark age, and the selected execution route. The legacy
`CachedMarkStale` blocker bit is reserved and no longer emitted. The selected route enforces freshness; failures
of its required oracle policy or dependencies remain operational blockers.

### Freshness-gated LP actions

When marks are stale and freshness is required:

- live open-position epoch settlement is available only through `OrderRouter.settleLpEpoch(bytes[])`, which validates a
  `PoolReconcile` Pyth basket and installs the exact Engine mark before the Router-only HousePool callback,
- the basket's earliest component publish time must be at or after the current round-hour boundary, so a still-fresh
  pre-boundary tick cannot price a newly matured batch,
- stale, low-confidence, future, divergent, or out-of-order data reverts the whole call; already-funded claims remain
  live and pending requests remain queued,
- no pending epoch bucket advances on a rejected live call; only claims funded by an earlier successful settlement
  remain independently callable,
- fresh oracle publication is the recovery path.

Exception: once the protocol enters `oracle frozen`, eligible synchronized settlement remains live under fixed
stale-price surcharges instead of hard-blocking immediately. Deposit activation keeps the ordinary lifecycle,
bootstrap, and Senior-impairment gates. Claims never reprice or reassess the fee fixed when a request was funded.
Direct cached-mark settlement is otherwise limited to the no-open-position case, where NAV is mark independent.

Pool pause blocks new deposit requests and deposit activation, but it does not block redemption requests or reconciled
funding of already-matured redemptions. The settlement result marks entries deferred, and already-funded claims remain
live.

The independent settlement hold blocks both funding and activation by reverting the canonical epoch transition. It
also blocks new Senior requests and reservations and permits pending Senior commitments to be refunded. Junior
deposit and redemption requests, reconciliation, and funded claims remain live. It has no automatic expiry and only
the HousePool owner can release it.

### Junior maintenance-fee dilution

The optional maintenance fee applies only to Junior. The generic Junior constructor permits a zero rate with a zero
or valid nonzero recipient; this release deploys at `0 bps` with the deployment-time protocol treasury as recipient.
The current HousePool owner may configure it through a 72-hour delay, subject to a `10,000 bps` (100%) nominal-APR cap.
Finalization must checkpoint elapsed fees to the old recipient before changing the rate or recipient; enabling from
zero starts prospectively.

The fee mints ordinary Junior shares and never transfers USDG or mutates tranche principal, the Senior HWM, reserves,
claim escrows, or waterfall accounting. Security review must distinguish raw ERC-20 supply from effective pricing
supply (`raw + pending fee shares`). Every Junior conversion, preview, and settlement price uses effective supply,
while raw supply remains the conservation quantity for actually issued balances. Pending deposits are excluded until
activation; pending redemption shares remain exposed until funding burns them.

Accrual uses completed Unix hours and is bounded to 8,760 charged hours per crystallization, with older backlog
forgiven. It continues during settlement holds, oracle freezes, losses, and zero NAV. A held, no-progress, or reverted
settlement must roll back both minting and checkpoint state without forgiving elapsed time. Minted zero-NAV shares are
worthless at that instant but share in recovery; this is intentional and must be reflected in incident analysis.
There is no public checkpoint, fee-specific guardian control, performance test, Junior HWM, equalization, cost basis,
or privileged cash-withdrawal path. The recipient redeems through the same asynchronous LP flow as every holder.
The current Settlement Monitor uses schema/domain V6. Its observable configuration includes the active fee rate and
recipient, Engine settlement-buffer policy, and Engine admin configuration version. A failed or malformed required
read makes the digest unavailable rather than silently assuming a zero fee, buffer, or version. This monitor domain is
separate from the lifecycle Book's V5 execution-config and receipt domains.

### Senior coupon model

Senior coupon is funded from existing junior NAV and capped by available junior principal.

This removes unpaid senior-coupon debt queues while making the cost of the fixed senior product explicit for junior LPs.

### Senior exposure limits and passive overage

Active protected senior exposure is `E = max(projected senior principal, projected senior high-water mark)`. Counted
admission exposure is `C = E + R`, where `R` is the gross USDG reserved in unfinalized senior deposit epochs. The
absolute and share admission tests use `C`, and the Junior redemption-funding covenant protects the same committed
exposure `C`.
Governance sets both an absolute USDG limit and a maximum share of senior-plus-junior claimant capital. The high-water
term prevents an impaired principal balance from falsely reopening capacity while its restoration entitlement remains.

Senior deposit reservations are firm once accepted. They consume quoted headroom when requested and settle even if
later coupon accrual or a cap reduction makes the current reservation book overlimit. New Senior admission then closes.
Junior redemption funding protects `R` as well as active exposure, so it cannot consume the backing committed to
pending Seniors. Integrators should present accepted Senior requests as binding commitments, subject to ordinary
activation gates and the documented safety and settlement-hold refund paths.

The covenant also limits Junior redemption funding; using committed `E + R`, the pool retains enough projected Junior
principal that the configured Senior share still holds after the fill.
This is an LP-liquidity restriction, not an extra source of cash or a guarantee that losses cannot impair senior.

Coupon, loss allocation, revenue restoration, and privileged claimant recapitalization remain higher-priority
accounting rules. They may passively move the pool above a configured limit, but the protocol does not haircut active
senior shares, suppress coupon already payable from junior, or misroute loss to force compliance. Instead, new senior
capacity closes until funded Senior redemptions, Junior deposits, or subsequent revenue cure the state. The engine-authorized
`recordClaimantInflow(..., Recapitalization, ...)` path is deliberately exempt when restoring protected senior claims;
it cannot mint new senior LP shares, and excess value continues through the canonical claimant/unassigned routing.

## Liquidation Security

### Full liquidation only

Liquidations always close the entire position.

Trade-off:

- simpler accounting and fewer liquidation games,
- no partial-liquidation recovery path for oversized positions.

### Reachability and bounty bounds

- liquidation accounting is constrained by actually reachable collateral,
- the proportional liquidation charge has a floor but is capped by the dedicated liquidation reserve; the pool does
  not fund an additional bounty subsidy when that reserve is insufficient,
- the collected charge is conserved across a bounded, timelocked allocation where
  `keeperShareBps + protocolShareBps <= 10_000`: the keeper and protocol treasury each receive their independently
  rounded-down configured shares as clearinghouse credit, and LPs receive the exact remainder, including rounding dust,
  as claimant revenue,
- residual trader value is preserved when positive,
- same-account trader claim balance is not generic liquidation collateral, but it is included in that account's
  terminal collectible cap and netted once against exact price loss,
- uncollateralized position price loss above the PnL cap is reported as a diagnostic write-off and is not socialized
  as LP debt or terminal deficit.

### Queue interaction during liquidation

Liquidation performs bounded account-local cleanup of that account's pending orders.

This preserves terminal liveness without requiring an unbounded global queue scan.

Before liquidation, cutoff-invalid opens receive the same full internal risk-off refund and `RiskOff` receipt as
standalone cleanup. An isolated inner frame then authenticates reservations and runs the Engine health/settlement
path. If the account is healthy, the inner frame rolls back while retaining valid outer risk-off refunds. Only the
exact direct Engine solvent failure receives that classification; other errors propagate.

If the account remains liquidatable, every other pending order is terminally recorded as `AccountLiquidated`;
unpaid opening bounty may go to treasury, while a close has zero bounty and `None` disposition. Historical mixed
disposition ordinals remain decodable but are not ordinary close outcomes. The executor is the original keeper, not
the Router self-call address. Router records are deleted within the same rollback frame as reservation settlement
and Book finalization; other accounts retain relative FIFO order.

Batch liquidation validates and pays for one shared Pyth snapshot, updates the neutral mark once, and isolates each
account in its own rollback frame. Solvent and positionless accounts are skipped without losing prior successes, while
the returned cursor leaves any low-gas or empty-revert item unattempted so a keeper can resume safely.

## Transaction walkthroughs

These walkthroughs show settlement order and the checks worth tracing. Exact formulas and source-of-truth balances
remain in [ACCOUNTING_SPEC.md](ACCOUNTING_SPEC.md); external call signatures and read surfaces are in
[CANONICAL_ENTRYPOINTS.md](CANONICAL_ENTRYPOINTS.md).

### Buffered open or increase

1. The trader commits a bounded intent, reserving its order margin and opening bounty. Commitment does not guarantee
   that execution will pass current risk checks.
2. At the FIFO head, the keeper supplies eligible oracle data. The planner projects carry, trade economics, and
   post-operation directional liability from one snapshot.
3. Admission requires post-operation effective assets `E >= L + B`, using the
   [settlement buffer](#settlement-liability-buffer); equality passes. Apply-time settlement rechecks the target.
4. The Engine applies the plan and synchronizes the account curve. The Router settles the bounty and finalizes the
   receipt. Attached TP/SL protection inherits its parent open's risk decision rather than adding a second gate.

### Profitable full close

1. Commitment collects applicable carry and records an Active zero close bounty without creating a close escrow.
2. The keeper executes the FIFO head under the current oracle regime. The planner computes price PnL, signed VPI,
   fees, remaining carry, and any frozen-close spread; the Engine applies those results.
3. Typed settlement consumes or releases the account buckets. A fresh payout uses available pool cash after
   protecting existing trader claims; otherwise eligible unpaid price value becomes a trader claim.
4. The position and its terminal curve are removed. The zero bounty settles without a recipient, and the Book
   finalizes the order. If receipt finalization fails, the item rolls back with its economics.

### Losing partial close

1. The trader commits the reduction with the ordinary FIFO, queued-exposure, carry, health, and financial checks.
   The close bounty is zero.
2. At execution, the planner allocates exact entry cost to closed lots. Carry is collected from pledge first and
   free settlement second before price loss uses the reduced pledge and nettable same-account claim.
3. Price loss above the collectible cap is a diagnostic write-off. Separate action charges must still be collectible;
   an unfunded required action remainder rejects the partial close.
4. The Engine preserves any pledge needed for the residual marked curve and atomically installs the remaining lots,
   entry cost, and cap. LP revenue includes physically collected value only; the write-off creates no asset or debt.

### Underfunded frozen full close

1. The frozen oracle policy validates the close. Normal signed VPI and its lifetime clamp still apply; the fixed
   LP-owned spread replaces the adverse-confidence price shift on this voluntary close.
2. Price settlement uses same-account claim and PnL pledge up to the collectible cap. Separate action obligations use
   their eligible gain withholding, protected VPI backing, spendable action reserve, free settlement, and committed
   order margin according to the canonical plan; those sources do not enlarge the price-loss cap.
3. Collected spread belongs to LPs. Any terminally uncollectible spread is recorded as `frozenSpreadWaivedAssets`, and
   excess price loss is recorded as `PriceLossWrittenOff`; neither creates a new liability or deficit.
4. The Engine removes the position and curve. Terminal close liveness does not waive oracle validation, FIFO,
   timing, slippage, or caller-pinned financial bounds.

### Liquidation

1. The Router refunds cutoff-invalid opens before entering the isolated liquidation frame. Inside that frame it
   authenticates reservations, settles zero close records, and invokes the planner's health/settlement checks.
   A healthy-account result rolls back the inner frame while valid preceding risk-off refunds remain.
2. For a liquidatable account, carry and exact price PnL use the typed collateral rules. Same-account claim nets
   against price loss once; PnL pledge pays the remaining collectible loss. Excess price loss is written off.
3. The dedicated liquidation reserve caps the charge. Keeper and treasury receive their configured floor-rounded
   shares as clearinghouse credits; the exact remainder goes to LPs. There is no pool-funded bounty subsidy.
4. Positive fresh trader payout uses available pool cash or becomes a trader claim. Uncollectible terminal action
   obligations follow their waiver rules. The Engine removes the position and curve and checks actual post-operation
   solvency for degraded mode.
5. Bounded account-local cleanup finalizes remaining orders as `AccountLiquidated`; unaffected opening bounties may
   be forfeited and zero close records move no value. Other accounts retain their relative FIFO order.

## Known Limitations

### Oracle and market-closure limitations

- frozen-oracle windows prioritize close liveness over live-market-style freshness guarantees,
- oracle-frozen voluntary close/reduce execution applies normal signed VPI plus a fixed LP-owned notional spread; normal live and FAD-only closes apply signed VPI without that spread,
- a fixed spread deliberately does not increase with mark staleness inside the permitted frozen window,
- full-close liveness takes priority over collecting an otherwise uncollectible spread; partial closes retain
  all-or-nothing rules for required charges but do not fail solely on uncollateralized price loss above the PnL cap,
- the recurring FX calendar follows New York daylight-saving transitions on-chain; unscheduled provider closures and
  holiday hours still require governance-configured UTC-day overrides,
- the current post-2007 US daylight-saving rule is compiled into the planner; a future legal or provider schedule
  change at an intraday boundary requires a coordinated engine/planner/oracle deployment,
- execution remains dependent on fresh keeper infrastructure and oracle publication outside frozen windows.

### Router and keeper limitations

- users cannot manually cancel queued intents,
- account-scoped client ids are permanent; a terminal or config-invalidated id cannot be reused for a replacement
  request, so clients must generate and persist unique ids,
- bounded cleanup means heavily expired queues may take multiple keeper calls to clear,
- stale cached marks can understate opening notional and execution bounties at commitment. The bounty floor/cap,
  trader's bound, and per-account order cap limit individual commitments but cannot guarantee profitable cleanup.
  Execution validates oracle data separately. Commitment does not require a fresh stored mark, so an idle period
  does not by itself require a keeper refresh before the trader may submit an open,
- ordinary failed closes require unpaid cleanup. The protocol keeper must fund gas
  for permissionless oracle-free expiry; bounded deadlines and queues do not guarantee a positive keeper incentive
  or prevent repeated fresh invalid submissions,
- failed protection-attempt cleanup is deliberately unpaid; each retry creates a fresh zero-bounty close record.
  The separate trigger reward is paid once on the original trigger. Liveness depends on keepers processing the
  terminal attempt and separately appending a retry, and operators
  must alert on prolonged `Latched` state without a live child,
- per-account pending-order caps bound each account's queue and liquidation cleanup traverses that local queue,
- the Router, its independently predeployed lifecycle Book, constructor-created protection Book, and fixed sidecars
  form one non-upgradeable stack that must be reviewed together. Externalizing the lifecycle Book plus keeper and execution paths saves
  Router initcode/runtime bytes but increases review coupling: a
  change to either Book or any delegated path requires rechecking direct-call rejection, external-getter assumptions,
  Router caller/event context, and every affected EIP-170 size. Admin and protection-Book creation code remain embedded in
  Router initcode; lifecycle-Book and sidecar creation inputs must be gated independently under EIP-3860,
- known typed planner/policy failures, slippage, expiry, and config mismatch are terminal for the affected order. A
  current registered protection attempt may relatch for a fresh child when the exact protected position remains; other
  orders have no terminal retry lane,
  while uncertain dependency failures deliberately retain the FIFO head and can block later orders until a successful
  retry or a different terminal rule such as expiry/risk-off/liquidation applies,
- complete terminal economics are event-backed; on-chain storage retains only the compact outcome and receipt hash,
  so historical consumers require reliable log indexing,
- the lifecycle Book has no migration or repair authority. A binding/invariant fault requires containment and a
  fresh compatible stack.

Changes to the Router-created protection Book require a fresh compatible stack and updated client, keeper, and
indexer bindings. The deployment scripts do not migrate old protection or order-attempt state.

### LP accounting limitations

- exact terminal NAV is only as current as its authenticated mark; live open-position epoch settlement requires an
  atomically validated post-boundary mark, while frozen exits deliberately use the cached stale-window mark,
- a positive marked receivable is not cash, so share NAV can exceed immediately redeemable liquidity,
- `TerminalNavBookV2` is intentionally non-upgradeable and has no owner repair path; a book/Engine invariant failure
  requires containment and a fresh-stack deployment rather than an in-place edit,
- `oracleFrozen` keeps eligible synchronized LP settlement live under fixed tranche-local frozen fees rather than a
  separate stale-action gate for exits; redemption funding is allowed to proceed while entry activation is deferred,
- each bounded live backlog pass pays a Pyth update fee and may use a later valid post-boundary mark than the previous
  pass; atomicity binds one call, not an arbitrarily large backlog,
- senior coupon payments are capped by available junior principal,
- governance can prospectively reduce senior limits below live exposure, closing new senior entry and potentially
  reducing Junior redemption-funding capacity until the covenant is cured; it cannot force existing Senior capital out,
- accepted senior reservations are grandfathered against later cap or accounting changes; an explicit settlement hold,
  projected terminal wipe, Senior impairment, or epoch rejection allows escrow recovery,
- wallet shares remain governed by the latest applicable activation timestamp, so voluntarily combining a newer lot
  with an older wallet balance preserves the newer lot's remaining cooldown. Administrative claims do not manufacture
  a claim-time delay, and the direct route can consume an independently aged source lot without mixing it into the
  wallet. Redemption cancellation or terminal refund still begins a new cooldown when shares return to a wallet.

### LP claim and allocation limitations

- Deposit/mint share claims, redemption cancellation, and refundable-share claims require `receiver == controller`,
  including zero-share acknowledgements. An approved operator may act for that controller. Funded USDG claims and
  pending-deposit USDG refunds have separate receiver rules.
- Partial deposit claims or funded-redemption claims can revert at rounding boundaries even when the full remainder
  is claimable. A tiny asset-denominated deposit claim can round to zero shares. Clients should offer full-remainder
  claims and preserve the entitlement display after a failed partial claim.
- Per-controller flooring can produce zero entitlement for a dust-sized request. A full-balance redemption bypasses
  the minimum request size and can burn shares for zero assets if its allocation rounds down to zero.
- Funding an epoch in several passes can produce rounding differences and residual share refunds compared with one
  pass. Unfunded shares also continue to participate in ordinary tranche profit, loss, and fees between calls.
- Zero-payout epochs can consume bounded settlement work and delay later epochs. Regular keeper processing is still
  required; insufficient cash or persistent Senior demand can independently defer Junior funding.
- Terminal allocation dust follows fixed ownership rules: deposit-share dust is burned, funded-asset dust returns to
  HousePool as excess, and refundable-share dust goes to the seed receiver. It is not awarded to the final caller.
- An impaired Senior withdrawal may retain less than one extra USDG atom of high-water-mark protection per funded
  pass because of conservative rounding. This can accumulate across passes and does not describe a universal bound
  on all LP allocation dust.

### Rounding limitations

- **Position carry rounding:** Converting a position's carry-index delta to six-decimal USDG rounds down.
  The checkpoint advances even when the result is zero, without retaining the fractional remainder. Each such
  conversion can discard less than one USDG atom (`0.000001 USDG`). User-triggered checkpoints, including
  zero-amount withdrawals, can therefore reduce LP carry revenue; an interval whose entire accrual is below one atom
  contributes no collectible carry. Practical savings depend on borrow size, utilization, checkpoint frequency, and
  transaction costs. The implementation does not persist fractional carry.
- **Zero-share Junior maintenance-fee checkpoints:** With a nonzero maintenance-fee rate and sufficiently
  small raw Junior share supply, the fee for completed chargeable hours can round down to zero shares. The checkpoint
  boundary still advances, so those hours do not accumulate toward a later fee mint. Mint/burn activity can trigger
  these checkpoints. The implementation does not retain fractional fee shares or defer zero-share checkpoints.

### VPI limitations

- liquidation does not compute a fresh VPI delta, but the gross negative accrued VPI clawback is settled from its
  dedicated reserve or equivalent withheld trader gain before residual planning,
- VPI depends on live canonical assets net of outstanding trader claims. Claim payment alone cannot change depth,
- zero economic depth blocks opens/increases after projected carry collection. Protective closes create no fresh VPI
  charge or rebate at zero depth, but retain the lifetime clamp and recovery of previously accrued negative VPI,
- voluntary closes use the same signed VPI curve and lifetime rebate clamp in live, FAD-only, and oracle-frozen regimes,
- frozen-market stale-price protection is a fixed notional spread that leaves VPI unchanged and replaces, rather than compounds with, the Pyth adverse-confidence price shift for oracle-frozen voluntary closes only,
- the lifetime clamp intentionally zeroes otherwise extractable rebate-only round trips,
- partial-close VPI release is a bounded linear approximation.

### Clearinghouse limitations

- settlement uses USDG only; each account has one directional position and separate typed collateral buckets,
- the owner may rescue accidentally transferred non-settlement ERC-20 tokens through `rescueToken`; settlement USDG
  is always excluded, including uncredited direct transfers, and rescue does not alter account balances or margin,
- **Settlement-USDG recovery limitation:** Direct USDG transfers to the clearinghouse outside its
  deposit APIs do not credit a margin account and remain unrecoverable through the current APIs, including by the
  owner. They are not allocated to HousePool or LPs. The clearinghouse has no aggregate credited-balance counter
  with which to distinguish recoverable surplus from funds backing account obligations.
  Integrations must use the supported `deposit`, `depositMargin`, or `depositFor` APIs to fund margin accounts,
- non-USDG collateral pricing and staleness policy are intentionally out of scope.

## Emergency Procedures

The canonical operator capability matrix, trigger policy, containment procedure, recovery criteria, and off-chain
guardian design requirements live in [EMERGENCY_RESPONSE_GUIDE.md](EMERGENCY_RESPONSE_GUIDE.md). Read that guide
before automating any response from `SettlementMonitorLens`.

### Emergency containment

1. Corroborate the unsafe observation from block-pinned direct reads and an independent provider when time permits.
2. Choose the minimum fixed action: risk-off plus LP entry for new-risk incidents, settlement-only for an isolated
   epoch-clearing concern, or full containment when domains overlap or cannot be isolated safely.
3. Simulate the exact coordinator call and verify `EmergencyContainmentTriggered`, its masks/action, all targeted
   states, and the permanent cutoff when risk-off is included.
4. Keep closes, liquidations, mark refresh, redemption requests, eligible cancellations, funded claims, and recovery
   infrastructure operating. Stop settlement broadcasts only while settlement is held.
5. Governance investigates and releases components deliberately; the guardian never auto-unpauses and no timer does.

Monitoring should page operators before applying a breaker. A confirmed isolated settlement defect may justify the
settlement-only hold; a NAV/custody invariant or cross-domain failure warrants full containment while preserving
protective exits. Oracle-read
failure is transient until corroborated; queue backlog, Senior priority, capacity, and insufficient free cash are
liveness states rather than accounting corruption. `SettlementMonitorLens` cannot pause anything itself. A critical
fault also makes the composite observation incomplete, so automation must inspect masks individually rather than
watching only the complete-observation digest.

### Suspected oracle issue

1. Distinguish a confirmed correctness/integrity problem from routine staleness or low confidence that the on-chain
   policy already rejects.
2. For a credible cross-domain integrity incident, use full containment. Use settlement-only only when independent
   evidence isolates the failure to epoch clearing and continued trading/request admission is safe.
3. Preserve protective flows and archive the raw signed update plus independent market evidence.
4. Governance resumes only after feed bindings, behavior, and canonical accounting are understood.

### Keeper outage

1. Orders accumulate in the queue.
2. Users cannot manually cancel them.
3. Restart keeper infrastructure.
4. Expect bounded cleanup rather than instant queue drain.

### Explicit terminal-deficit cascade

This runbook concerns actual negative terminal LP equity or trader payout claims that physical cash cannot currently
service. A terminal price-loss write-off above an account's collectible cap and a waived terminal action remainder
create neither condition; the current accounting model has no accumulated-debt ledger to clear.

1. Let closes and liquidations continue.
2. Prevent further risk expansion via degraded mode when `E < L`, or through the ordinary `E >= L + B` admission
   gate when raw solvency remains intact; use admin pause if additional containment is needed.
3. Consider stricter risk settings to accelerate cleanup.
4. Recapitalize or clear positions.
5. Clear degraded mode only after raw solvency `E >= L` is genuinely restored; buffer restoration is not required
   for clearing, although new risk remains blocked until `E >= L + B`.

## Asset Isolation

Core perps LP capital must remain pure, immediately accessible USDG.

The protocol explicitly rejects embedding third-party yield or lending-market exposure into the core `HousePool` because that would:

- turn bounded solvency into an external liquidity assumption,
- create crisis-time liquidity mismatch,
- import external smart-contract and credit-loss contagion,
- weaken confidence in immediate trader payout capacity.

If yield overlays are desired, they should sit above the base protocol as opt-in wrappers rather than inside the core clearing layer.

## Decimal Reference

| Quantity | Decimals |
|----------|----------|
| USDG | 6 |
| Position size | 18 |
| Oracle / basket price | 8 |
| PnL | 6 |
| TrancheVault offset | 3 |

## Audit evidence

Checked-in historical reports:

- [SC Audit Studio pre-audit report](../../audits/plether-pre-audit-report.pdf)
- [Collaborative audit report, May 12, 2026](../../audits/plether-collaborative-audit-report-2026-05-12.pdf)

Each report applies to its stated scope and reviewed revision. Subsequent changes to order execution, accounting,
LP settlement, and deployment wiring require review against the exact release commit. These reports and historical
Sepolia artifacts do not establish that the current immutable stack is audited, deployed, or production-ready.

Historical finding dispositions and command results remain in Git and the associated pull requests. For current
executable coverage and its limitations, use [the test map](test/perps/TEST_MAP.md). No document in this directory
substitutes for matching deployed bytecode, configuration, and dependency bindings to a reviewed release.

## Security Contact

For responsible disclosure:

`contact@plether.com`

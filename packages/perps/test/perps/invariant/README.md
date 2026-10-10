# Perps Invariant Suites

This directory contains handler-driven Foundry invariant campaigns and bounded state-machine fuzz tests for the
perps system. Coverage descriptions below refer to the assertions and actor domains in each harness. Executable suites live in
`properties/`; deployment fixtures, handlers, mocks, and reference ledgers are kept alongside that directory.

## Evidence and failure handling

- **Independent reference models** compute expected state from initial conditions and action inputs. The claim,
  fee, ETH refund, VPI/frozen-spread, and waterfall campaigns below have explicit bounded domains; none proves every interaction.
- **Reconciliation** checks agreement among observed storage, custody, snapshots, and tracked ownership. In particular,
  `PerpAccountingHandler` keeps observed claim mirrors for batch/account reconciliation. Those mirrors are separate
  from `PerpGhostLedger` and are not an independent oracle for the correctness of claim amounts.
- **Differential checks** compare previews/planners with execution or other public views. Shared production arithmetic
  can make both sides agree on the same error; these checks complement the independent models.
- Every invariant campaign inherits `fail_on_revert = true` from the default Foundry profile. An unexpected outer
  handler revert therefore fails validation under default, quick, CI, audit, and coverage profiles. Expected protocol business
  rejections remain caught within adversarial actions and are counted by selector; strict handling therefore also
  exposes a reverted ghost assertion or arithmetic failure. `PerpAccountingHandler` classifies caught bytes by action
  domain, custom-error selector, and ABI length (including exact planner error codes). Unknown errors, empty data,
  `Error(string)`, and `Panic(uint256)` fail validation. Returned `EngineFailure` or `ReceiptFailure` pending outcomes
  also fail. Deterministic injection tests cover both thrown and returned failures. The bounded models additionally
  classify exact expected rejections or retain sticky unexpected-failure counters. The main/adversarial Router
  handlers classify commit error payloads and reject internal pending failures. Oracle rejection expectations include
  the current live/frozen policy and timestamp precedence. LP lifecycle handlers distinguish state-qualified
  frozen/capacity rejection and exact `NoLpEpochProgress` from all other failures. Positive value-conservation
  fixtures require their setup calls to succeed and distinguish the intentional slippage rejection from a successful
  close. Snapshot scenarios persist outcome counters after restoring economic state.
- `OracleSynchronizationHandler` is a narrower exception to execution-error classification: it catches every first
  execution error while checking mark rollback, then ignores retry errors. Its resolution count includes every
  nonreverting response, not just successful fills. `fail_on_revert` still rejects setup/commit failures outside
  these catches. This campaign is stored-feed consistency evidence, not proof of sustained successful execution.
- Deterministic reachability and deliberately perturbed accounting tests establish that the new models exercise
  successful transitions and detect incorrect balances. More runs cannot replace these checks.

## Campaign entrypoints

There are 23 invariant entrypoints. Each retained campaign has a domain name describing its checks; reconciliation
and parity names do not claim independent economic modeling. The 17 former `invariant_job1`/`invariant_job2` pairs
called the same `_assertAllInvariants()` body with identical setup, targets and configuration. Each second wrapper
was removed and both baseline entries map to the retained, renamed entrypoint. Assertion bodies, actor domains,
profile budgets and seed selection are unchanged.

The prior CI run produced identical per-selector metrics for every pair. A separate fixed-seed replay of one pair
also produced identical full handler call traces; the prior full CI traces were compacted, so that exact-history
comparison is limited to the replay. Additional exploration uses the configured depth, runs and separate seeds.
This cleanup removes duplicate execution without changing economic expectations.

## Reachability and fault sensitivity

Successful setup is asserted before fault injection; the following negative controls perturb the deployed subject
or its dependency response while retaining the reference model. They must fail the normal reconciliation assertion.

| Subject | Reachable transition | Negative control |
| --- | --- | --- |
| Claims and base withdrawal reserve | Deferred and immediate full closes, claim consumption, live-position claim settlement | Add one atom to per-account or aggregate Engine claim storage; the reserve model also detects the aggregate mutation |
| Fee custody and payout | Repeated open/close/treasury-withdraw cycles | Add/remove one atom of treasury credit, or burn one atom of the paid wallet balance |
| VPI and frozen spread | Positive/negative VPI, frozen partial/full close, thaw | Add one atom of unmodeled pool cash |
| LP waterfall | Junior loss, Senior impairment/restoration, coupon accrual, recapitalization | Add one atom of unmodeled pool cash |
| Bounty custody and payment | Fund protection, trigger it, then execute its close | Add one atom to the actual reservation aggregate, or remove one atom of actual execution-keeper credit |
| Shared accounting handler | Execute a real queued order, then reject the sixth pending commit | Inject unknown/empty/built-in errors or malformed planner codes; return internal Engine/receipt failures |
| Explicit preview/live scenarios | Successful close, liquidation, and paired roundtrip | Inject an unexpected open failure and verify its counter survives snapshot rollback |

The properties use counters to distinguish successful comparisons from intentional no-op or invalid-preview cases.
A counter does not turn a rejected action into evidence for successful settlement. Random action coverage remains
bounded by each handler's actor set and input range.

## Independent campaigns

- `properties/PerpIndependentClaimInvariant.t.sol`: persistent three-account claim creation, same-account price-loss
  consumption, immediate payout, and all-or-nothing claim settlement at zero/own-claim/global-minus-one/exact/surplus
  pool liquidity. Checks settlement and PnL-pledge credits, pool cash, aggregate claims, and the base Engine withdrawal reserve from input-derived position liabilities plus
  claims and an independently rounded buffer (excluding real-vault epoch reserves). Uses funded full closes,
  fixed time, zero VPI, and a mock HousePool; it does not model partial-close health, Router policy, carry, or LP NAV.
- `properties/PerpFeeFlowInvariant.t.sol`: independent amount and wallet ledger for funded live-market opens and full
  closes, with actual queued Router execution and unique oracle updates. Covers gain/loss/flat outcomes and rounding;
  zero VPI/carry and ample liquidity exclude fee waivers, deferred-claim priority, and liquidation charges.
- `properties/PerpVpiFrozenAccountingInvariant.t.sol`: persistent nonzero-VPI opens/increases and partial/full closes,
  lifetime clamp and reserve tracking, and successful nonzero frozen-spread settlement across freeze/thaw. Computes
  expected quadratic costs and cash independently at a fixed mark with zero carry. Calls the Engine as its configured
  Router; the Router oracle/degraded authorization matrix is covered separately in `../matrices/`.
- `properties/PerpWaterfallReferenceInvariant.t.sol`: persistent real-pool Junior-first losses, Senior impairment,
  revenue restoration, coupon ratcheting, and recapitalization priority with an input-derived cash/principal/HWM
  model. Both seeded tranches retain their owners. Router authorization and the Engine-only recapitalization inflow
  are explicit harness boundaries; issuance/redemption, carry, VPI, deferred claims, and raw-cash shortage remain
  outside this model. Existing lifecycle and capacity campaigns cover those LP queue paths separately.

- `properties/OracleEthConservationInvariant.t.sol`: persistent independent ETH accounting across three actors,
  Oracle refunds, Admin refunds and paid Pyth fees. Three 1-ETH actor budgets are funded only at setup; expected
  parse/update fees, immediate refunds and both claim ledgers advance from scenario inputs and callback modes.
  A deterministic prelude reaches all eleven families (ordinary/shared/mixed execution, frozen/FAD close,
  unavailable history with/without a completed prefix, outer rollback, caught item failure, paused cleanup and
  zero-fee surplus), all five rollback kinds, rejected/gas-burning/reentrant callbacks and both directions of
  cross-ledger claims. Rollback hashes are before/after reconciliation; finalized receipts establish that a prefix
  executed before rollback, without supplying expected ETH amounts. Fees are bounded to 0–1 gwei and surplus to
  0–5 gwei. Every bounded scenario creates fresh traders, drains its queue and closes opened positions; ETH debt
  and counters persist, but this is not a general persistent USDC model. Prices are fixed, frozen/FAD predicates
  mocked, and real Pyth verification, liquidation, LP flow and forced ETH are outside the domain. Bounded callback
  gas makes both properties production-compiler gates in PR, post-merge and audit lanes.

## Suites

- `PerpAccountingInvariant.t.sol`
  - Catches hidden-collateral and split-accounting bugs
  - Verifies clearinghouse-reserved execution bounty value reconciles with live orders
  - Verifies liquidated accounts cannot keep pending orders, live reserves, or recover value later
  - Verifies ghost-tracked committed margin and reserved execution bounty stay aligned with protocol state
  - Verifies a stricter per-order committed-margin state machine across commit, execution, terminal failure, and liquidation
  - Verifies pending-order and margin-order FIFO queues keep consistent head/tail pointers, links, counts, and ordering

- `PerpPreviewInvariant.t.sol`
  - Catches view-layer drift between previews and core engine/accounting state
  - Verifies empty positions preview as inactive
  - Verifies liquidation reachable collateral previews match clearinghouse accounting
  - Verifies liquidation previews exclude clearinghouse-reserved execution reservation from reachable collateral
  - Verifies generic position views expose physical reachable collateral separately from trader claim netting
  - Verifies degraded-mode trigger flags behave as transition flags rather than persistent state flags

- `PerpTraderClaimInvariant.t.sol`
  - Catches trader claim and liquidity-gating bugs
  - Verifies trader claim status matches engine storage and current HousePool liquidity
  - Verifies observed per-account claim mirrors reconcile with engine totals; independent claim amounts are checked by the dedicated reference campaign
  - Verifies close and liquidation previews use all-or-nothing immediate vs trader claim gating

- `PerpOracleBoundaryInvariant.t.sol`
  - Catches stale-threshold, frozen-window, and FAD-boundary drift
  - Verifies oracle-frozen boundary logic matches the intended weekend/admin-day formula
  - Verifies house-pool freshness limits switch correctly between weekday and frozen-oracle modes
  - Verifies maintenance margin switches cleanly between weekday and FAD settings

- `PerpMultiAccountInvariant.t.sol`
  - Catches cross-account contamination bugs under overlapping commits, executions, liquidations, and claims
  - Verifies per-account pending counts and margin-order counts aggregate cleanly into live global order ownership
  - Verifies trader claim obligations remain isolated per account while still reconciling globally

- `PerpFeeFlowInvariant.t.sol`
  - Catches fee accrual, custody, and withdrawal drift
  - Verifies independently calculated execution fees reconcile with accumulated and withdrawn treasury value
  - Verifies the canonical protocol accounting snapshot includes the same live treasury fee balance
  - Verifies the live fee balance remains clearinghouse-custodied

- `PerpEconomicConservationInvariant.t.sol`
  - Catches protocol-wide ledger drift and conservation bugs
  - Verifies known actor and protocol balances conserve total USDC supply
  - Verifies clearinghouse custody matches tracked account balances
  - Verifies the compact per-account ledger view stays aligned with clearinghouse buckets, router order reserves, trader claims, and pending order counts
  - Verifies the expanded per-account ledger snapshot stays aligned with typed locked-margin buckets, collateral, position-health, and settlement-reachability views
  - Verifies tracked per-account settlement, reservation, and trader claims aggregate cleanly into protocol custody and obligation buckets
  - Verifies deposit/withdraw transitions preserve monotonic reachability expectations
  - Verifies no orphaned account-risk state remains once an account has no position and no pending orders
  - Verifies the expanded account ledger snapshot fully subsumes compact, collateral, and position views
  - Verifies per-account settlement buckets reconcile with clearinghouse storage
  - Verifies the canonical protocol accounting snapshot stays aligned with accessors and house-pool snapshots
  - Verifies house-pool input/status snapshots stay aligned with physical assets, exact terminal NAV, trader claim liabilities, and engine status
  - Verifies withdrawal reserves include maximum directional liability, trader claims, and the liability-scaled
    settlement buffer
  - Verifies terminal price loss never exceeds same-account claim plus PnL-pledge collection; any excess is a diagnostic write-off rather than protocol debt or terminal deficit
  - Verifies observed claim mirrors stay complete across processed accounts and reconcile with engine totals

- `PerpValueConservationInvariant.t.sol`
  - Catches adversarial value-category transitions in the full perps stack
  - Fuzzes terminal close execution, signed terminal-NAV LP pricing, timed carry checkpoints, and recapitalization/revenue reconciliation
  - Verifies active margin, LP share value, historical carry, and pending claimant revenue cannot move owners without an intended settlement path

- `PerpClosePreviewParityInvariant.t.sol`
  - Catches drift between close previews and canonical-depth simulations
  - Independently checks valid partial-close residual health from whole lots, exact remaining entry basis, capped
    mark, remaining PnL pledge, and same-account claims, strictly above the floored maintenance/FAD requirement
  - Treats liquidation/VPI reserves as separate buckets; `minBountyUsdc` is not a residual pledge floor
  - Executes a reachable claim-backed partial close whose remaining pledge is below the minimum liquidation bounty,
    checking actual size, pledge, claims, exact entry basis, separate liquidation reserve, and authenticated receipt
  - When a full close is valid, restricts invalid canonical partial closes to `PartialActionChargeUncollectible`
    or `PartialCloseUnhealthy`; the legacy `DustPosition` ABI value must not be emitted
  - Verifies fresh payout is either immediately credited or added to the remaining existing trader claim, with the
    two fresh-payout modes mutually exclusive
  - Samples partial-close previews for non-reversion; this is not a carry-accrual or payout-funding assertion.
    Timed carry conservation is covered separately by `PerpValueConservationInvariant.t.sol`

- `PerpExplicitAccountingInvariant.t.sol`
  - Runs isolated snapshot/revert scenarios, preserving mismatch/outcome counters but not economic state between calls;
    depth is the number of independent scenarios, not a persistent trading history
  - Seeds a successful close, liquidation, and paired roundtrip comparison; unexpected setup failures remain visible
    after snapshot rollback, while invalid previews are counted as skipped scenarios
  - Exercises preview/live parity for successful closes and liquidations against
    the full deployed accounting stack
  - Verifies paired Long/Short round trips conserve LP, trader, and protocol value
  - Verifies the same round trips conserve physical protocol cash

- `PerpHousePoolLifecycleInvariant.t.sol`
  - Catches seed-lifecycle, vault-cap, cooldown, and raw/canonical asset drift
  - Verifies trading and ordinary deposits cannot activate before both tranche
    seeds exist
  - Verifies seed floors, withdrawal caps, and share-transfer cooldown
    propagation
  - Verifies raw assets split into canonical assets plus excess
  - Verifies asynchronous USDC/share escrow conservation, request/claim capacity, direct routing from deposit-claim
    escrow into redemption, and held-settlement rollback
  - Also contains `PerpHousePoolMaintenanceFeeInvariantTest`, a companion campaign with a nonzero Junior fee:
    effective supply includes pending dilution, fee materialization credits only the configured recipient, and
    fee-only checkpoints preserve pool economics and escrows. It checks effective-supply deposit/redemption pricing,
    redemption-before-deposit ordering, fee accrual during settlement holds, and raw supply across known holders

- `OracleSynchronizationInvariant.t.sol`
  - Reconciles every tracked MockPyth stored-feed timestamp against the installed Engine mark after a nonreverting
    Router resolution, and checks caught execution failures do not retain a changed mark timestamp
  - Uses two feeds, fresh alternating-side traders, ±1% prices and 1–10 second delays; positions accumulate
  - Seeds one nonreverting resolution, but does not decode terminal status or classify caught execution/retry
    errors. It therefore does not establish sustained successful fills or independent accounting correctness
  - Shared action logic is in `handlers/OracleSynchronizationHandler.sol`; executable property is in `properties/`

- `PerpOraclePathInvariant.t.sol`
  - Catches state drift across successful and rejected mark-refresh paths
  - Verifies the stored mark equals the last successful capped oracle update
  - Verifies failed ETH refunds remain beneficiary-claimable rather than
    becoming router-admin custody
  - Verifies configurable execution and liquidation staleness limits remain
    positive

- `PerpTerminalNavBruteForceInvariant.t.sol`
  - Reconstructs terminal price PnL by exhaustively enumerating canonical Engine
    positions, exact entry bases, clearinghouse PnL pledges, and Engine claims
  - Proves the tracked account set is exhaustive against Engine side aggregates
    before comparing it with the production NAV book
  - Seeds opposing positions plus a partial-close residual with exact-basis dust
    and a same-account deferred claim; separately verifies liquidation removal
  - Verifies the radix result at both price endpoints, the live mark, and every
    account-derived break-even and collateral-cap transition with adjacent and
    radix-boundary interior marks

- `GovernedSeniorCapacityInvariant.t.sol`
  - Fuzzes cutoff-routed Senior/Junior deposit and redemption request/cancel/settle/claim transitions across multiple
    actors
  - Derives every expected request id from `getRequestEpochWindow()` and drives timestamps on both sides of the
    exact five-minute cutoff instead of assuming a fixed activation delay
  - Records pre-cutoff and cutoff-window reachability and verifies successful requests use the advertised future
    target; requests at or after an epoch's cutoff cannot increase that locked epoch
  - Verifies every successful senior admission or finalization leaves active plus
    reserved exposure within both governed limits
  - Verifies successful junior withdrawals preserve the active senior-share covenant
  - Reconciles the pool reservation counter with unfinalized epoch assets and checks
    vault escrow plus per-user pending-asset accounting

- `EmergencyRiskOffInvariant.t.sol`
  - Uses bounded `testFuzz_*` transition sequences, plus direct authority and liquidation tests
  - Verifies monotonic risk-off cutoffs, permanent open invalidation, unpaid non-head cleanup, and exact internal
    margin/bounty refunds across pause and recovery cycles
  - Verifies queued closes and liquidations remain reachable, and repeated held LP settlement attempts preserve
    accounting until owner release

- `ProtectionBountyStateMachine.t.sol`
  - Uses a bounded `testFuzz_*` campaign with an independent three-account bounty ledger and additional random steps
  - Exercises attached parents, pre-trigger protection cancellation, successful and reverted triggers, expiry,
    relatching, retry, execution, risk-off refunds, and liquidation of armed, triggered, and latched protection
  - Reconciles reserved, paid, refunded, and forfeited bounty value across separate order/protection namespaces,
    including numeric-id collisions, retained attempt bounties, parent margin, and exact-once keeper credits

## Coverage boundaries

The stateful suites are high-signal conformance checks, not a complete proof of
the accounting specification.

- Most older campaigns retain zero VPI. The dedicated persistent VPI/frozen campaign adds funded nonzero-VPI and
  frozen-spread settlement. Combined nonzero-VPI, unpaid carry, deferred claims, and stressed LP lifecycle histories
  are not covered by one independent model; dedicated direct tests cover assessed/paid/waived spread allocation.
- `PerpHousePoolLifecycleInvariant.t.sol` covers the active vault lifecycle,
  seed floors, cooldowns, caps, escrow routing, settlement holds, and excess accounting. Its maintenance-fee companion
  covers active Junior dilution and settlement pricing. The separate
  `GovernedSeniorCapacityInvariant.t.sol` covers the bounded pending senior
  request/cancel/finalize/claim state machine, reservation conservation, and
  stateful reachability on both sides of the shared request cutoff; it does not
  model every possible epoch or governance transition. Epoch reservations and pending claims are reconciled against
  observed queue/share state; the independent base Engine withdrawal-reserve model excludes those real-vault
  reservations.
- Degraded transition flags and post-operation balances are checked by
  `PerpPreviewInvariant.t.sol`; preview/live degraded settlement parity is
  additionally exercised by `PerpExplicitAccountingInvariant.t.sol`.
- The stateful suites align protocol accounting views and withdrawal-reserve
  composition, but they do not prove the asymptotic complexity of endpoint
  aggregation or independently prove every projected admission branch.
- The bounded persistent waterfall model covers Junior-first loss, Senior restoration, coupon ratcheting, and
  recapitalization priority. It does not combine every waterfall transition with pending epoch/share transactions;
  the lifecycle/capacity suites and domain-specific accounting tests remain complementary evidence.
- FIFO structure and reservation ownership are statefully checked. Binding
  order-field immutability and the first unique strictly post-commit historical
  Pyth tick are covered by `../spec/trader/OrderRouterCommitment.t.sol` and
  `../spec/oracle/OrderRouterExecutionFreshness.t.sol`, not a dedicated invariant. Protection cancellation is separate from queued-order cleanup: ordinary FIFO orders have no user
  cancellation path. `ProtectionBountyStateMachine.t.sol` checks the protection/attempt reservation state machine.
- Timed carry ownership is checked with snapshot-isolated scenarios, while utilization-rate arithmetic
  and simultaneous carry on both sides remain direct-test/model properties.
- Oracle/FAD boundary invariants do not span the complete two-axis authorization
  matrix formed by the oracle/calendar state and the degraded-mode latch.
- Committed margin tracks per-order ownership and reconciles reservations, but parts of the older ghost ledger
  still observe production reservation deltas. That evidence is weaker than the independent bounty/claim/fee models.
  The current protocol has clearinghouse-held bounty reservations and directly credited keeper rewards; it has no
  deferred-keeper-credit or stored protocol-bad-debt bucket to model. Uncollectible price tails are diagnostic
  writeoffs and are checked as such.
- Account-capped price collection, failed full-close value safety, and preview/live terminal
  parity are statefully exercised. No single invariant quantifies over every
  valid insolvent terminal path and every risk-increasing entry point.
- Whole-lot PnL/max-profit arithmetic and exact entry-cost conservation are
  unit- and fuzz-tested. `TerminalNavBookV2.t.sol`,
  `TerminalNavCloseConservation.t.sol`, and
  `TerminalNavIntegrationSecurity.t.sol` provide focused book, split-close, and
  symmetric-pricing evidence. `PerpTerminalNavBruteForceInvariant.t.sol`
  independently reproduces the aggregate over the invariant harness's bounded,
  completeness-checked actor domain; this remains stateful differential evidence,
  not a formal proof over an unbounded production account set.

## Harness Pieces

- `BasePerpInvariantTest.sol`
  - Shared invariant deployment harness using a deterministic mock HousePool
  - Suites inheriting `../BasePerpTest.sol` instead exercise the full HousePool/vault stack. Both harness families
    use `LegacyOrderRouterHarness` for test-only scalar-call adapters over production bounded-request logic; those
    adapters are not production Router entrypoints

- `handlers/PerpAccountingHandler.sol`
  - Stateful fuzz actor that performs deposits, withdrawals, order commits, execution, liquidation, payout claims, and HousePool mode changes

- `ghost/PerpGhostLedger.sol`
  - Tracks liquidation observations and committed-margin ownership for the adversarial accounting handler. Per-order
    reservation transitions also reconcile against production state; this is not a fully independent economic model.

- `handlers/PerpClaimModelHandler.sol`
  - Independent expected claims and position lifecycle; expected balances never synchronize from Engine storage

- `handlers/PerpOracleHandler.sol` and `handlers/PerpFeeHandler.sol`
  - Dedicated oracle/calendar and protocol-fee fuzz actors; several full-stack suites define their handlers locally

- `mocks/MockInvariantHousePool.sol`
  - Deterministic test HousePool whose token balance can be seeded or set directly to vary Engine/sidecar payout
    liquidity; it does not model the production tranche waterfall

## Typical Commands

Run from the repository root. The package root selects the perps test tree and compiler configuration:

```bash
forge test --root packages/perps --match-contract PerpIndependentClaimInvariantTest
forge test --root packages/perps --match-contract PerpVpiFrozenAccountingInvariantTest
forge test --root packages/perps --match-contract PerpWaterfallReferenceInvariantTest
forge test --root packages/perps --match-contract PerpAccountingInvariantTest
forge test --root packages/perps --match-contract PerpPreviewInvariantTest
forge test --root packages/perps --match-contract PerpTraderClaimInvariantTest
forge test --root packages/perps --match-contract PerpOracleBoundaryInvariantTest
forge test --root packages/perps --match-contract PerpMultiAccountInvariantTest
forge test --root packages/perps --match-contract PerpFeeFlowInvariantTest
forge test --root packages/perps --match-contract PerpEconomicConservationInvariantTest
forge test --root packages/perps --match-contract PerpValueConservationInvariantTest
forge test --root packages/perps --match-contract PerpClosePreviewParityInvariantTest
forge test --root packages/perps --match-contract PerpExplicitAccountingInvariantTest
forge test --root packages/perps --match-contract PerpHousePoolLifecycleInvariantTest
forge test --root packages/perps --match-contract PerpHousePoolMaintenanceFeeInvariantTest
forge test --root packages/perps --match-contract PerpOraclePathInvariantTest
forge test --root packages/perps --match-contract PerpTerminalNavBruteForceInvariantTest
forge test --root packages/perps --match-contract GovernedSeniorCapacityInvariantTest
forge test --root packages/perps --match-contract EmergencyRiskOffInvariantTest
forge test --root packages/perps --match-contract ProtectionBountyStateMachineTest
```

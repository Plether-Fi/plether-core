# Perps Invariant Suites

This directory contains handler-driven Foundry invariant campaigns and bounded state-machine fuzz tests for the
perps system. Coverage descriptions below refer to the assertions and actor domains in each harness.

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
  - Verifies trader claim ghost accounting stays fully model-derived and reconciles with engine totals
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
  - Verifies a handler-side fee model tracks accumulated and withdrawn fees
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
  - Verifies ghost-tracked trader claims match engine storage and totals

- `PerpValueConservationInvariant.t.sol`
  - Catches adversarial value-category transitions in the full perps stack
  - Fuzzes terminal close execution, signed terminal-NAV LP pricing, timed carry checkpoints, and recapitalization/revenue reconciliation
  - Verifies active margin, LP share value, historical carry, and pending claimant revenue cannot move owners without an intended settlement path

- `PerpClosePreviewParityInvariant.t.sol`
  - Catches drift between close previews and canonical-depth simulations
  - Verifies valid sampled partial closes preserve the minimum residual-margin floor
  - When a full close is valid, restricts invalid sampled partial closes to `PartialCloseUnderwater` or `DustPosition`
  - Verifies fresh payout is either immediately credited or added to the remaining existing trader claim, with the
    two fresh-payout modes mutually exclusive
  - Note: the currently named carry-accrual invariant performs no time warp or
    carry assertion; timed carry conservation is covered by
    `PerpValueConservationInvariant.t.sol`

- `PerpExplicitAccountingInvariant.t.sol`
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

- The current invariant harnesses use a zero VPI factor. Unit, fuzz, differential,
  and matrix tests cover nonzero VPI arithmetic and lifetime clamps, but the
  stateful invariant family does not yet exercise nonzero VPI.
- The stateful invariant family does not currently drive a successful
  oracle-frozen voluntary close with a nonzero frozen spread. Dedicated
  frozen-close tests cover assessed/paid/waived allocation.
- `PerpHousePoolLifecycleInvariant.t.sol` covers the active vault lifecycle,
  seed floors, cooldowns, caps, escrow routing, settlement holds, and excess accounting. Its maintenance-fee companion
  covers active Junior dilution and settlement pricing. The separate
  `GovernedSeniorCapacityInvariant.t.sol` covers the bounded pending senior
  request/cancel/finalize/claim state machine, reservation conservation, and
  stateful reachability on both sides of the shared request cutoff; it does not
  model every possible epoch or governance transition.
- Degraded transition flags and post-operation balances are checked by
  `PerpPreviewInvariant.t.sol`; preview/live degraded settlement parity is
  additionally exercised by `PerpExplicitAccountingInvariant.t.sol`.
- The stateful suites align protocol accounting views and withdrawal-reserve
  composition, but they do not prove the asymptotic complexity of endpoint
  aggregation or independently prove every projected admission branch.
- The complete senior/junior waterfall - junior-first loss, senior high-water
  restoration, coupon ratcheting, and recapitalization priority - is covered by
  direct `HousePool.t.sol` tests rather than a dedicated stateful invariant.
- FIFO structure and reservation ownership are statefully checked. Binding
  order-field immutability and the first unique strictly post-commit historical
  Pyth tick are covered by direct `OrderRouter.t.sol` tests, not a dedicated
  invariant. Protection cancellation is separate from queued-order cleanup: ordinary FIFO orders have no user
  cancellation path. `ProtectionBountyStateMachine.t.sol` checks the protection/attempt reservation state machine.
- Timed carry ownership is statefully checked, while utilization-rate arithmetic
  and simultaneous carry on both sides remain direct-test/model properties.
- Oracle/FAD boundary invariants do not span the complete two-axis authorization
  matrix formed by the oracle/calendar state and the degraded-mode latch.
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
  - Independent ghost model for liquidation snapshots, committed margin ownership, and execution bounty reservation tracking

- `handlers/PerpOracleHandler.sol` and `handlers/PerpFeeHandler.sol`
  - Dedicated oracle/calendar and protocol-fee fuzz actors; several full-stack suites define their handlers locally

- `mocks/MockInvariantHousePool.sol`
  - Deterministic test HousePool whose token balance can be seeded or set directly to vary Engine/sidecar payout
    liquidity; it does not model the production tranche waterfall

## Typical Commands

Run from the repository root. The package root selects the perps test tree and compiler configuration:

```bash
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

# Perps Invariant Suites

This directory contains stateful Foundry invariant suites for the perps system.

## Suites

- `PerpAccountingInvariant.t.sol`
  - Catches hidden-collateral and split-accounting bugs
  - Verifies clearinghouse-reserved execution bounty value reconciles with live orders
  - Verifies liquidated accounts cannot keep pending orders, live reserves, or recover value later
  - Verifies ghost-tracked committed margin and reserved execution bounty stay aligned with protocol state
  - Verifies a stricter per-order committed-margin state machine across commit, execution, cancellation, failure, and liquidation
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
  - Verifies stale live marks do not silently keep advancing weekday carry policy

- `PerpMultiAccountInvariant.t.sol`
  - Catches cross-account contamination bugs under overlapping commits, cancels, executions, liquidations, and claims
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
  - Verifies withdrawal reserves use maximum directional liability, trader claims, and the supplemental slot
  - Verifies terminal price loss never exceeds same-account claim plus PnL-pledge collection; any excess is a diagnostic write-off rather than protocol debt or terminal deficit
  - Verifies ghost-tracked trader claims match engine storage and totals

- `PerpValueConservationInvariant.t.sol`
  - Catches adversarial value-category transitions in the full perps stack
  - Fuzzes terminal close execution, signed terminal-NAV LP pricing, timed carry checkpoints, and recapitalization/revenue reconciliation
  - Verifies active margin, LP share value, historical carry, and pending claimant revenue cannot move owners without an intended settlement path

- `PerpClosePreviewParityInvariant.t.sol`
  - Catches drift between close previews and canonical-depth simulations
  - Verifies valid partial closes conserve exact entry cost, PnL pledge, and residual terminal curves
  - Restricts partial-close invalidity to documented shape and separate action-charge failures; price loss above the account cap is write-off eligible
  - Verifies the immediate-payout versus trader-claim split uses adjusted pool cash
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
  - Fuzzes immediate senior and junior deposits, delayed senior request/cancel/
    finalize/claim transitions, and both tranche withdrawals across multiple actors
  - Verifies every successful senior admission or finalization leaves active plus
    reserved exposure within both governed limits
  - Verifies successful junior withdrawals preserve the active senior-share covenant
  - Reconciles the pool reservation counter with unfinalized epoch assets and checks
    vault escrow plus per-user pending-asset accounting

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
  seed floors, cooldowns, caps, and excess accounting. The separate
  `GovernedSeniorCapacityInvariant.t.sol` covers the bounded pending senior
  request/cancel/finalize/claim state machine and reservation conservation; it
  does not model every possible epoch or governance transition.
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
  invariant.
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

- `handlers/PerpAccountingHandler.sol`
  - Stateful fuzz actor that performs deposits, withdrawals, order commits, execution, liquidation, payout claims, and HousePool mode changes

- `ghost/PerpGhostLedger.sol`
  - Independent ghost model for liquidation snapshots, committed margin ownership, and execution bounty reservation tracking

- `mocks/MockInvariantHousePool.sol`
  - Deterministic test HousePool that can force router payout success or failure and directly control available HousePool liquidity

## Typical Commands

```bash
forge test --match-contract PerpAccountingInvariantTest
forge test --match-contract PerpPreviewInvariantTest
forge test --match-contract PerpTraderClaimInvariantTest
forge test --match-contract PerpOracleBoundaryInvariantTest
forge test --match-contract PerpMultiAccountInvariantTest
forge test --match-contract PerpFeeFlowInvariantTest
forge test --match-contract PerpEconomicConservationInvariantTest
forge test --match-contract PerpValueConservationInvariantTest
forge test --match-contract PerpClosePreviewParityInvariantTest
forge test --match-contract PerpExplicitAccountingInvariantTest
forge test --match-contract PerpHousePoolLifecycleInvariantTest
forge test --match-contract PerpOraclePathInvariantTest
forge test --match-contract PerpTerminalNavBruteForceInvariantTest
```

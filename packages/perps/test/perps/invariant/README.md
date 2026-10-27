# Perps invariant suites

These suites exercise sequences of actions and compare the resulting state with accounting rules, reference
models, or other protocol views. Start with the [protocol overview](../../../README.md) and
[accounting specification](../../../ACCOUNTING_SPEC.md); use the [test map](../TEST_MAP.md) to find individual
boundary cases. This directory is a guide to test evidence, not a separate protocol specification.

## How to read a campaign

A Foundry campaign has three parts: a fixture deploys contracts and initial balances, a handler generates actions,
and an `invariant_*` function checks the resulting state. Read `setUp()` and `targetSelector()` as well as the
assertion: they determine which actions, actors, and configurations the campaign can reach.

- **Independent models** advance expected state from initial conditions and action inputs. Production values are
  compared with that state; they must not silently replace the model's expectations.
- **Reconciliation** compares observed balances, ownership records, queues, and public snapshots. It can expose
  disagreement without independently establishing that every amount is economically correct.
- **Parity** compares previews or planners with execution. Shared arithmetic can make both agree on the same error.
- **Fault controls** deliberately corrupt a value and require the ordinary checker to fail. These establish checker
  sensitivity; they do not establish that the corrupted state is reachable through public calls.

The package [Foundry configuration](../../../foundry.toml) sets `fail_on_revert = true`. Unexpected outer handler
reverts fail a campaign. Handlers may catch expected protocol rejections, so their rejection classifiers and outcome
counters are also part of the test. The accounting handler rejects unknown, empty, built-in and malformed errors,
and treats internal Engine/receipt failures as unexpected. Dedicated tests inject such failures to check this behavior.

Successful-transition counters and deterministic setup histories prevent a run consisting entirely of rejected
calls from being mistaken for settlement coverage. More runs or greater depth do not expand a handler's actor set,
action set, or economic assumptions.

## Independent accounting models

| Suite | What it checks | Main limits |
| --- | --- | --- |
| [Independent claims](properties/PerpIndependentClaimInvariant.t.sol) | Claim creation, price-loss consumption, immediate payout, all-claim liquidity gating, and the Engine withdrawal reserve against an input-driven ledger | Three actors, funded full closes, fixed time, zero carry/VPI, mock pool. Real-vault epoch reserves and partial-close health are outside this model. |
| [Fee flows](properties/PerpFeeFlowInvariant.t.sol) | Independently calculated execution fees, clearinghouse treasury custody and withdrawals through queued Router trades | Funded live opens/full closes with ample liquidity and zero carry/VPI. Liquidation charges and stressed fee waivers are separate tests. |
| [VPI and frozen spread](properties/PerpVpiFrozenAccountingInvariant.t.sol) | Persistent opens/increases, partial/full closes, lifetime VPI limits, backing reserves, frozen spreads and thaw | Fixed mark, zero carry, mock pool. Calls the Engine with Router authority; it does not test Router/Pyth authorization. |
| [Waterfall](properties/PerpWaterfallReferenceInvariant.t.sol) | Junior-first loss, Senior impairment/restoration, coupon ratcheting and recapitalization against a cash/principal/high-water-mark ledger | Real pool with fixed seed owners. No pending share transactions, carry, VPI, claims or raw-cash shortage. |
| [Mixed trader/LP accounting](properties/PerpMixedAccountingInvariant.t.sol) | Public V3 orders, custody, exact entry basis, carry, claims, VPI, fees, reservations and Junior LP entitlements in one persistent history | Four reusable traders, two Junior controllers and fixed seed owners. See the domain below. |
| [Oracle ETH conservation](properties/OracleEthConservationInvariant.t.sol) | Pyth fees, immediate refunds and separate Oracle/Admin refund claims from input-derived ETH budgets | Three actors funded with 1 ETH each; fixed prices and mocked calendar predicates. Each scenario drains its queue; ETH debts and counters persist. No liquidation, LP flow or forced ETH. |

The ETH campaign covers successful execution, completed batch prefixes, unavailable history, rollback, rejected or
gas-burning callbacks, reentry attempts and both refund ledgers. Its bounded callback gas makes it a production
compiler gate, including in the otherwise faster PR test lane.

### Mixed campaign domain

The mixed campaign seeds 500,000 USDG in each tranche, enables 500-bps carry, VPI and frozen spreads, and disables
Junior maintenance dilution. Trading uses public `OrderRequest` objects and authenticated terminal receipts.
Generated opens start from 17–500 lots and are clipped to a 500-lot queued-exposure cap per trader. There are at most
five pending orders per trader, twenty globally, and two LP epochs. These are harness limits, not production limits.

Commitment, single/batch execution, expiry, replay, slippage failure and risk-off cleanup are separate actions.
Pending orders remain live across collateral, carry, price and LP transitions. A separate input history tracks the
first authored oracle tick in each order's settlement window; later accounting marks do not replace that fill.
The mock oracle does not verify real Pyth signatures.

The model tracks each account's settlement, exact entry cost, carry arrears, claims, VPI reserves, margin/bounty
reservations and generation, plus treasury/keeper entitlements and Junior share/request/claim escrows. Ordinary
and protection-generated close orders reserve zero execution bounty; the positive protection trigger reward is a
separate obligation. Recorded mock-token cash shocks are explicit external flows in the conservation equations.

Mandatory setup histories reach both VPI signs, deferred claims, claim-supported partial closes, unpaid carry,
rejected withdrawals, held/retried LP settlement, cancellations and repeated liquidation at the same address.
The following companion files reuse that model for focused histories:

| Companion | Additional coverage |
| --- | --- |
| [Pending orders](properties/PerpMixedPendingOrders.t.sol) | FIFO ownership, exact replay, expiry, missing historical ticks, risk-off cleanup, zero-free closes and terminal consumption of queued margin |
| [Liquidation](properties/PerpMixedLiquidation.t.sol) | Both directions, claim-first price loss, diagnostic write-offs, carry recovery/waiver, immediate/deferred gains, keeper credit and cleanup without disturbing another account |
| [LP lifecycle](properties/PerpMixedLpLifecycle.t.sol) | Partial funding and claims, independent share pricing, worthless-share refunds, per-controller entitlements, terminal dust and delayed carry checkpoints |
| [Trader/LP interaction](properties/PerpMixedInteraction.t.sol) | Pending trader commitments across partial LP claims, further funding and held/retried settlement |

The mixed model does not combine every governance setting, Senior request lifecycle or Junior maintenance fee.
Its external keeper is flat; it does not generate carry-bearing keeper accounts or corrupt/quarantined reservations.
Dedicated policy, LP and corruption tests supply that separate evidence.

### Reference helpers

These are ordinary `.sol` helpers, not standalone invariant campaigns:

| Helper | Independent expectation | Companion tests |
| --- | --- | --- |
| [CarryReferenceLedger](ghost/CarryReferenceLedger.sol) | Side clocks/indexes, account accrual floors, protected funds, collection, arrears and recovery; physical cash is distinguished from withheld gains and VPI offsets | [CarryReferenceLedger.t.sol](../accounting/carry/CarryReferenceLedger.t.sol), [HistoricalOpenCarry.t.sol](../accounting/carry/HistoricalOpenCarry.t.sol) |
| [CloseReferenceMath](ghost/CloseReferenceMath.sol) | Exact basis, claim-first price loss, partial-close residual health, eligible charge sources, rebates and payout destinations | [CloseReferenceMath.t.sol](../accounting/close/CloseReferenceMath.t.sol) |
| [LiquidationReferenceMath](ghost/LiquidationReferenceMath.sol) | Post-carry health and terminal allocation for the mixed fixture's fixed fee configuration | [LiquidationReferenceMath.t.sol](../accounting/liquidation/LiquidationReferenceMath.t.sol) |
| [MarketCalendarReference](ghost/MarketCalendarReference.sol) | Gregorian/DST market calendar with no administrative overrides | [MarketCalendarReference.t.sol](../accounting/liquidation/MarketCalendarReference.t.sol) |
| [PendingOrderReferenceLedger](ghost/PendingOrderReferenceLedger.sol) | Input-driven identity, deadlines, FIFO membership, remaining reservations and terminal dispositions | [PendingOrderReferenceLedger.t.sol](properties/PendingOrderReferenceLedger.t.sol) |
| [WaterfallReferenceMath](ghost/WaterfallReferenceMath.sol) | Cash, Senior principal/high-water mark and Junior residual allocation | [Waterfall campaign](properties/PerpWaterfallReferenceInvariant.t.sol) and mixed LP tests |

Carry golden vectors are checked in and generated offline by
[generate-perps-carry-vectors.py](../../../../../scripts/generate-perps-carry-vectors.py); Solidity tests do not run
Python or FFI. Model-only arithmetic tests are paired with real Engine or Router histories, whose fixture
boundaries still apply.

## Reconciliation, policy and parity campaigns

| Suite | Checks and interpretation |
| --- | --- |
| [General and adversarial protocol](properties/PerpInvariant.t.sol) | Protocol solvency, positions and custody; adversarial queue progress, terminal outcomes, pending stops and reservation ownership. The file contains separate ordinary and adversarial campaigns. |
| [Accounting](properties/PerpAccountingInvariant.t.sol) | Per-order margin/bounty ownership, account/global FIFO structure, liquidation cleanup, legal residual withdrawals and address reuse. Parts of its ghost ledger observe production deltas. |
| [Economic conservation](properties/PerpEconomicConservationInvariant.t.sol) | Known-actor token conservation, clearinghouse custody, settlement buckets, claim totals, withdrawal reserves and public snapshots. Observed claim mirrors reconcile amounts; the independent claim campaign establishes separate amount expectations. |
| [Multiple accounts](properties/PerpMultiAccountInvariant.t.sol) | Per-account ownership/counts and global claim/order reconciliation under overlapping activity |
| [Trader claims](properties/PerpTraderClaimInvariant.t.sol) | Observed claims and actual settlement at aggregate-liquidity boundaries, including success/failure sensitivity controls |
| [Account previews](properties/PerpPreviewInvariant.t.sol) | Account/liquidation views, reachable collateral, protected reservations and degraded transition flags against canonical state |
| [Close previews](properties/PerpClosePreviewParityInvariant.t.sol) | Preview/simulation agreement, independent residual-health checks and mutually exclusive immediate/deferred fresh payout. Partial-preview sampling alone does not establish timed carry conservation. |
| [Explicit accounting](properties/PerpExplicitAccountingInvariant.t.sol) | Close/liquidation preview parity and paired roundtrip value/cash conservation. Economic state resets after each scenario; outcome/mismatch counters survive. Depth counts separate scenarios, not one persistent history. |
| [Value conservation](properties/PerpValueConservationInvariant.t.sol) | Snapshot-isolated close, LP pricing, carry checkpoint and recapitalization/revenue scenarios in the full stack; this is not one persistent economic history |
| [Terminal NAV enumeration](properties/PerpTerminalNavBruteForceInvariant.t.sol) | Enumerates tracked positions, exact bases, pledges and claims, reconciles actor completeness to Engine side aggregates, then compares the NAV book at endpoints and account-derived boundaries. It is bounded differential evidence. |
| [LP lifecycle](properties/PerpHousePoolLifecycleInvariant.t.sol) | Seeding, caps, cooldowns, asynchronous escrows, claim routing and settlement holds. A second maintenance-fee campaign checks Junior dilution, effective-supply pricing, fee recipient and escrow conservation. |
| [Governed Senior capacity](properties/GovernedSeniorCapacityInvariant.t.sol) | Multi-actor request/cancel/settle/claim histories, both sides of the request cutoff, active/reserved Senior exposure, Junior withdrawal covenant and escrows |
| [Oracle calendar boundaries](properties/PerpOracleBoundaryInvariant.t.sol) | Weekday, frozen and FAD maintenance/freshness transitions. The full calendar/degraded-state authorization matrix lives separately in [matrices](../matrices/). |
| [Oracle refresh paths](properties/PerpOraclePathInvariant.t.sol) | Accepted/rejected mark refreshes, monotonic installed state, policy boundaries and refund custody |
| [Oracle synchronization](properties/OracleSynchronizationInvariant.t.sol) | Stored-feed coverage, authenticated execution, keeper/treasury credits and complete rollback/retry. Two feeds, fresh alternating-side traders, ±1% prices, 1–10 second delays and zero VPI bound the domain. |

## Bounded state machines

[EmergencyRiskOffInvariant.t.sol](properties/EmergencyRiskOffInvariant.t.sol) uses ordinary `testFuzz_*` sequences
and direct tests for monotonic cutoffs, permanent open invalidation, reservation refunds, reachable closes and
liquidations, and held LP settlement. It is not a handler-driven `invariant_*` campaign.

[ProtectionBountyStateMachine.t.sol](properties/ProtectionBountyStateMachine.t.sol) uses a three-account independent
bounty ledger for attached parents, cancellation, trigger/retry, expiry, risk-off and liquidation. It distinguishes
protection rewards from zero-bounty close attempts and checks exact-once payment. Protection cancellation does not
imply a cancellation API for ordinary FIFO orders.

The other `.t.sol` files in `properties/` include deterministic regressions and pure reference tests. Their location
or filename does not give them invariant depth; only `invariant_*` functions use that setting.

## Harness layout

- [BasePerpInvariantTest](BasePerpInvariantTest.sol) deploys real Engine/Router/clearinghouse components with a
  [mock HousePool](mocks/MockInvariantHousePool.sol) whose liquidity can be controlled. It does not model the tranche waterfall.
- [BasePerpTest](../BasePerpTest.sol) supplies the real HousePool/vault stack for full-stack suites. Both fixture
  families use mock USDG/Pyth and test-only scalar adapters in `LegacyOrderRouterHarness`; those adapters are not
  production entrypoints.
- [handlers](handlers/) contains generated actions and expected-state updates. Some suites define their handlers
  in the property file. [MixedLpTestHarness](support/MixedLpTestHarness.sol) adds reusable LP scenarios.
- [PerpGhostLedger](ghost/PerpGhostLedger.sol) tracks generations, wallet flows, liquidation observations and order
  reservations for the adversarial accounting handler. It is not a wholly independent economic model.

## Running a campaign

Run from the repository root with Foundry and Solc 0.8.35 installed. `--offline` requires the compiler to be cached.
Use the `--root` argument so Forge reads the package's profiles rather than the repository integration profile.

```bash
# List the executable functions in this directory.
forge test --offline --root packages/perps \
  --match-path 'test/perps/invariant/properties/*.t.sol' --list

# A focused independent claim campaign, including its deterministic controls.
FOUNDRY_PROFILE=quick forge test --offline --root packages/perps \
  --match-contract '^PerpIndependentClaimInvariantTest$' -vv

# Persistent coupled trader/LP history with an explicit CI seed.
FOUNDRY_PROFILE=ci FOUNDRY_FUZZ_SEED=0xdeadbeef forge test --offline --root packages/perps \
  --match-contract '^PerpMixedAccountingInvariantTest$' -vv
```

The default/quick profile uses 256 fuzz cases and 16 invariant runs at depth 128. CI uses 2,000 cases and 32 runs at
depth 256; audit uses 20,000 cases and 256 runs at depth 1,000. These are configured defaults; environment overrides
can change them. Use the [recorded runners and replay instructions](../TEST_MAP.md#running-and-replaying) for
complete suite selection, production compiler gates, multiple seeds and saved failure corpora.

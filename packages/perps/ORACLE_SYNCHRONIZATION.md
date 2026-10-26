# Oracle pricing and synchronization

Plether uses different price paths for delayed orders and current-state operations. Both validate signed Pyth data,
but a historical order fill must not be replaced by a newer price just because that price is now stored by Pyth.
This guide describes the current [`PletherOracle`](src/PletherOracle.sol) implementation and its Router integration.

| Operation | Price source | Fee quote |
| --- | --- | --- |
| Live/FAD delayed order | Unique signed post-commit historical basket | `getOrderExecutionFee(updateData)` |
| Live mark refresh, liquidation, protection trigger or LP reconciliation | Complete signed current basket, or valid replay of the accepted basket | `getUpdateFee(updateData)` |
| Oracle-frozen operation | Stored Engine mark, subject to frozen age limits and operation-specific adjustments | Zero Pyth fee |

**FAD** is the protocol's heightened-risk calendar window; it is not synonymous with an oracle freeze. FAD alone
still uses signed historical prices for delayed orders. See [Accounting specification](ACCOUNTING_SPEC.md) for
calendar and frozen-close economics, and [Order timing](CANONICAL_ENTRYPOINTS.md#order-timing) for commitment/deadline rules.

## Accepted live basket

The Oracle stores the accepted live basket; only the configured Router can update it. For each nonempty live update:

1. Set a caller-independent cutoff at `block.timestamp - min(LIVE_TICK_LOOKBACK, modeMaxStaleness)`.
   `LIVE_TICK_LOOKBACK` is 15 seconds.
2. Parse a signed price for **every configured feed** between that cutoff and the current timestamp.
3. Require each component to be at least as new as its previously accepted value. Validate positive prices,
   component age/divergence, aggregate confidence and basket ordering.
4. Accept the entire basket together. Its publish time is the newest component time; an equal-time basket cannot
   change the aggregate price.

Pyth's mutable stored latest prices cannot change this accepted basket or its views. An empty live payload replays
it at zero fee only if it still passes the selected policy; an uninitialized basket cannot be replayed.
The Router installs the neutral Engine mark before settlement, protection activation, or its excess-ETH refund.

| Check | Rule |
| --- | --- |
| Historical component divergence | `maxComponentPublishTimeDivergence` (default 5 seconds). |
| Live liquidation component divergence | `liquidationStalenessLimit`. |
| Other live component divergence | `orderExecutionStalenessLimit`. The parsing window also bounds possible gaps. |
| Live PoolReconcile age | Smaller of Engine and HousePool mark-age limits; Engine limit if the Pool limit is zero. |
| Live PoolReconcile publication floor | Even the oldest component must be published in the current LP epoch. |

Read `pythFeedIds`, applicable policy limits and `LIVE_TICK_LOOKBACK()` at one block. Supply all feeds in one bundle;
a missing or too-old component rejects it. Passing the time window does not establish that a caller selected the
unique latest price for every component. See the
[live basket component selection limitation](SECURITY.md#known-limitation-live-basket-component-selection).

## Historical order execution

Outside a freeze, the Oracle calls `parsePriceFeedUpdatesUnique` for each configured feed in
`(commitTime, min(commitTime + orderSettlementWindow, block.timestamp)]`. It then calls `updatePriceFeeds` on the
**same payload**, and verifies that each stored feed timestamp covers its corresponding parsed component.
The fill and neutral mark come from the parsed historical basket, even if Pyth storage already has newer data.
Execution prices include the applicable side-adverse confidence adjustment.

The Engine does not rewind a newer cached mark to execute an older eligible fill. It also rejects a different
clamped mark at the same publish time. Protection arming records the Engine oracle time; activation requires a later
signed tick and later block. A protection attached to an open fails and refunds its own trigger reward if it cannot
safely arm after the parent fill; the valid parent fill remains executed.

### Batch reuse

The Router starts each execution call with an empty in-memory historical cache and only populates it after a
successful parse and synchronization. Reuse for a later order requires all components to follow that order's commit,
fit its historical window and satisfy cache coverage. Otherwise the Router requests a new historical resolution.
If the supplied payload has no qualifying post-commit update, the order stays pending.

Public Router execution accepts no caller-supplied cache. The Oracle's lower-level batch helper does accept one, but
its stored-feed coverage check authenticates timestamps, **not arbitrary cached prices**. External consumers must
not treat that helper as an authenticated price source for untrusted cache contents.

## Frozen operation

During `oracleFrozen`, current paths and delayed closes replay the Engine's stored mark subject to
`fadMaxStaleness`. They do not parse live data or compare component timestamps. Voluntary closes use the separate
frozen spread policy; liquidation applies a deterministic adverse shift based on the configured maximum basket
confidence ratio. New protection triggering is unavailable while frozen; the Book rejects activation with
`ConditionalTriggerFrozen`. Already-triggered protection close attempts follow ordinary close policy.

Install a final live mark before the scheduled freeze and verify its allowed age. A stale frozen mark cannot be
repaired from Pyth storage or a new live payload during the freeze. A settlement monitor selecting
`AtomicOracleRefresh` does not override that policy; its transaction remains blocked if frozen replay is stale.

## Fees and refunds

Quote at the same pinned block as other preflight reads, then simulate the exact Router calldata and ETH value.

- `getOrderExecutionFee` returns twice Pyth's payload fee outside a freeze: one parse plus one stored-feed update.
  It rejects empty data. The Router's internal proven batch-cache reuse costs zero without making a new quote.
- `getUpdateFee` returns one Pyth fee for a nonempty live update, zero for empty or frozen replay. A zero quote does
  not imply a valid replay basket exists.
- For `N` candidate orders sharing a payload, `N * getOrderExecutionFee(payload)` is a conservative batch funding
  bound. Cleanup and proven cache reuse consume no Pyth fee. State or fee changes require a fresh simulation.

`PriceSnapshot.updateFee` reports funding allocated to a resolution. On successful historical resolution it is two
fees; on frozen/reused resolution it is zero. When historical parsing returns `ok=false`, it still reports the two-fee
allocation even though the Oracle refunds or defers that amount. The Router subtracts that allocation from its own
refund to avoid paying twice.

Failed Oracle refunds accumulate in `PletherOracle.claimableEth(recipient)`; failed Router refunds use RouterAdmin's
claim ledger. Consumers must expose both claim paths. Direct historical Oracle callers should send the exact quote:
success does not refund overpayment. ETH sent to a reused lower-level cache also remains in the Oracle without a
refund credit. Prefer the Router entrypoints.

## Failure behavior

| Condition | Result |
| --- | --- |
| Exact Pyth `PriceFeedNotFoundWithinRange()` | With Router unavailable-history policy, leaves the order pending and refunds/defers historical funding. It means the supplied payload lacks a qualifying update, not that none exists elsewhere. |
| Other historical parser error | Wrapped as `PletherOracle__HistoricalParserFailure`; single execution reverts, while a batch stops with `OracleFailure`, preserving finalized predecessors. |
| `PletherOracle__StoredFeedBehind(...)`, insufficient funding or failed cache coverage | Reverts the transaction, including earlier batch progress. |
| Retryable Engine/receipt item failure | Leaves that item pending; prior finalized items and applicable outer oracle work remain. |

A successful RPC response or gas estimate can still return `Pending`. Verify the lifecycle result and receipt, not
only transaction success. [Entrypoints](CANONICAL_ENTRYPOINTS.md#keepers) describes cleanup and execution surfaces.

## Release qualification

For an oracle-synchronization candidate, retain evidence from one immutable source commit:

1. Run normal CI, all four production-codegen deep shards, formatting, package boundaries and full runtime/creation-input
   size checks. Production gas/size gates must use production compiler settings.
2. Capture signed six-feed data with `scripts/capture-oracle-sync-fixture.py`; replay baseline/candidate scenarios
   with `scripts/run-oracle-sync-fork.py FIXTURE OUTPUT`. Run the signed-data fork tests listed in
   [TEST_MAP](test/perps/TEST_MAP.md). Separately exercise unequal component times and missing feeds: the pinned
   live-basket fixture has equal component times. Missing/skipped fixtures or a frozen test window do not qualify a
   live price path.
3. Run synchronization, ETH-conservation and gas suites against the candidate's pinned keeper version and gas cap.
   Verify expected lifecycle progress and refund completion; do not raise the cap or remove gas reserves to make a
   failing gate pass.
4. Export with `scripts/export-perps-release.py`, including fixture/test evidence, ABI hashes and full creation inputs.
   Dirty-source output is not an immutable release bundle.
5. Deploy and verify a separate inactive candidate using [Deployment](DEPLOYMENT.md). Run the read-only
   `VerifyPerpsArbitrumSepolia.verifyOracleSynchronization()` with `ORACLE_SYNC_FIXTURE` and
   `PERPS_EXECUTION_CONFIG_HASH` in addition to its normal deployment environment. Candidate qualification does not
   include seeding or activation.
6. Treat activation as a separate release gate: matching consumers, funding readiness and a reviewed plan for
   existing-stack obligations are required. A failed candidate is left inactive; it is not a migration rollback tool.

## Verification and monitoring

Use matching release ABIs and verify chain, addresses, runtime hashes, reciprocal bindings and configuration hash.
The current request domain is V3; receipt/configuration domains are V5. Old deployments require their archived ABIs;
non-upgradeable contracts cannot gain these semantics through a Router-only replacement.

[TEST_MAP](test/perps/TEST_MAP.md) identifies synchronization, gas, refund-conservation and signed-data fork tests.
Release qualification must include real target-chain payloads with unequal component times and missing components.
An equal-time mock or fixture does not prove representative live-basket availability. See
[Deployment](DEPLOYMENT.md) for the release export and candidate verification flow.

After a successful live Router update, read `getAcceptedBasketMark()` and the Engine mark at one pinned block and
check price/time agreement. Track historical and frozen provenance separately: historical execution may advance the
Engine without advancing the accepted live basket, and frozen replay uses the Engine mark directly. Do not infer
accepted-basket coverage from Pyth stored timestamps. Record transaction identity, both marks and policy mode when
investigating a mismatch or stale-basket alert.

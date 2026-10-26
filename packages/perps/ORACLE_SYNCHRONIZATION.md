# Historical synchronization and live basket watermark

Live mark refresh, liquidation, and LP reconciliation use a Router-owned accepted basket. For each nonempty
live update, the Oracle sets a caller-independent cutoff at `block.timestamp - min(15, modeMaxStaleness)` and
parses a signed price for every configured feed within that window. Each component must be at least as new as
its previously accepted price. The aggregate is accepted only after all component age, divergence, confidence, and mark-ordering
checks pass. Pyth's mutable stored latest prices cannot change a current basket or view. The Router installs the
neutral Engine mark before settlement, protection activation, or any excess-ETH refund callback. A live empty payload
replays the unchanged accepted basket at zero fee if it still passes the selected policy. An uninitialized basket
cannot be read or replayed.

Historical order-execution components use `maxComponentPublishTimeDivergence` (5 seconds by default). Live
Liquidation baskets use `liquidationStalenessLimit` for component-time divergence; live OrderExecution, MarkRefresh,
and PoolReconcile baskets use `orderExecutionStalenessLimit`. PoolReconcile freshness is separate: component age
uses the smaller of the Engine and HousePool mark-age limits, or the Engine limit when the HousePool limit is zero.
For nonempty live updates, the parsing lookback of `min(15, modeMaxStaleness)` also bounds component gaps. Frozen
reads reuse the Engine mark and do not compare component times. See the accepted
[live basket component selection limitation](SECURITY.md#known-limitation-live-basket-component-selection).

The basket publish time is the newest component time so protection activation can observe a move in any component.
Equal-time baskets cannot change the mark price. Pool reconciliation additionally requires the oldest component to
be published in the current LP epoch before the Router may settle that epoch.

For live payload construction, read the indexed `pythFeedIds`, the mode's freshness limit, and
`LIVE_TICK_LOOKBACK()` at one block. Submit recent signed data for every feed in one payload; a missing component
or a component older than the cutoff is rejected. Empty data replays the accepted basket when it remains fresh.
The companion `plether-app` oracle worker must send complete live bundles and report rejected cutoffs and
last-complete-basket age. This repository does not contain that worker. Validate its live behavior with signed
target-chain data before activation.

The Engine rejects a different clamped price at the same publish time. Position protection records the Engine
oracle time when armed and requires a later signed activation tick and a later block. Its public wall-clock arming
time remains available for display. An attached protection that cannot safely arm after its parent fill fails and
refunds its own bounty without reverting the valid fill.

During the oracle-frozen window, current paths and delayed closes replay the Engine's stored mark at zero Pyth fee,
subject to `fadMaxStaleness`. Frozen liquidation uses a deterministic adverse shift from the configured maximum
basket confidence ratio; voluntary closes retain their frozen spread policy. Operators must install a final live
mark before the market closes and verify that it will remain within the frozen age limit. A stale mark cannot be
repaired from mutable Pyth storage during the freeze.

Historical order resolution now pays for `parsePriceFeedUpdatesUnique` and `updatePriceFeeds` on the **same signed payload**. It checks each configured stored feed against its corresponding parsed timestamp before returning. The fill and neutral mark still come from the unique historical tick. A newer stored price never substitutes for that tick.

Historical fills can use an older eligible post-commit tick without rewinding a newer cached Engine mark.

This requires a fresh complete stack: the execution sidecar is immutable and the Engine's Router binding is one-time. The candidate release stays inactive. Existing positions, queues, protections, balances, claims and LP obligations are not migrated.

## Consumer integration

For a new order resolution, call the new oracle's `getOrderExecutionFee(updateData)` at the same block as other preflight reads. Outside frozen policy it returns twice Pyth's update fee and rejects empty data unless a proven historical batch cache is reused. Frozen execution returns zero. `getUpdateFee(updateData)` quotes one Pyth parse fee for a nonempty live update and zero for empty or frozen replay. FAD alone does not enable the zero-fee path. Consumers must not fall back to the generic quote when the new selector is absent.

Single execution forwards the quoted amount. For a batch of N candidate orders using one payload, N times the execution quote is a conservative funding bound; cleanup and synchronized cache reuse consume no Pyth fee. Re-simulate before submission because policy, queue and fee state may change. Keep the keeper's outcome-aware gas preflight: a successful RPC call or estimate that returns Pending is not successful execution.

`PriceSnapshot.updateFee` reports funding forwarded for the resolution, not unconditionally consumed fees. Successful new historical resolution reports two fees; frozen resolution and replay report zero; historical batch reuse reports zero. On unavailable history with `ok=false`, it reports two fees even though both are refunded/deferred by the oracle. Router accounting subtracts that allocation from its final refund, preventing double payment. Direct historical callers should supply the exact quote; successful historical calls do not refund overpayment. Frozen direct calls refund excess ETH.

Failed immediate oracle refunds remain in `oracle.claimableEth(recipient)`. Failed Router refunds are recorded by RouterAdmin. Index and expose both existing claim paths; do not infer that an unavailable parse consumed the quoted funding.

Public Router execution accepts no cache. Its in-memory cache starts empty and is populated only after successful resolution and synchronization. Reuse for a later order requires the oldest signed component time in that cached basket to follow the later order's commit. If it does not, the Router quotes a fresh historical resolution; an unavailable post-commit feed leaves that order pending. The permissionless oracle cache helper still accepts unauthenticated prices: its coverage check proves only that stored timestamps cover the supplied basket timestamp. External consumers must not treat that helper as an authenticated quote for arbitrary cache contents.

## Failure and compatibility rules

`PletherOracle__StoredFeedBehind(feedId, storedPublishTime, requiredPublishTime)` means synchronization or cache coverage failed. Synchronization errors, insufficient fees and failed coverage revert the whole transaction, including previous batch progress. Only Pyth's exact `PriceFeedNotFoundWithinRange()` error follows the unavailable-history path; it means no qualifying update was found in the supplied payload, not that history is unavailable elsewhere. Other parser errors revert with `PletherOracle__HistoricalParserFailure`; batches stop with `OracleFailure`, preserve finalized predecessors, and refund the reverted call's funding through the Router. Caught later item failures retain synchronized mark updates and consumed fees according to the existing lifecycle policy.

Import the matching release ABIs and verify chain, addresses, runtime hashes, Engine/Router/Oracle bindings and execution-config hash. The batch cache tuple now includes `oldestPublishTime`; the snapshot tuple is unchanged. The combined current fresh-stack cleanup also changes order receipt and configuration ABIs and uses V5 receipt/config hash domains. Regenerate consumers from the final release build; the request/intent domain remains V3. New deployment addresses change the configuration hash; invalidate old reviews and require fresh review plus explicit user confirmation. Keep existing worker repair and bounded UI recovery.

## Release qualification

1. Run normal CI, all four production-codegen deep shards, formatting, package boundaries and full creation-input/runtime size gates on one immutable source commit.
2. Capture a signed six-feed fixture with `scripts/capture-oracle-sync-fixture.py`. Run `scripts/run-oracle-sync-fork.py FIXTURE OUTPUT` to replay identical baseline/candidate historical scenarios. Run `LiveBasketWatermarkForkTest` with the pinned Hermes fixture to verify initial acceptance, the fixed 15-second live cutoff, rejection of stale signed data, and subsequent advancement in real Pyth. Separately capture real payloads with unequal feed times and missing components; the pinned live fixture has equal feed times and does not establish representative-gap liveness. These checks require a configured Arbitrum Sepolia RPC and real signed Pyth data; local equal-time mocks do not qualify the timing bound. A missing fixture, frozen window, already-covered mark or skipped test fails qualification.
3. Run `OracleSynchronizationTest`, `OracleSynchronizationGasTest`, and both synchronization/ETH conservation invariant suites under production settings; their exact paths and evidence limits are listed in [TEST_MAP.md](test/perps/TEST_MAP.md). Gas tests use the app revision/cap in the candidate's `keeper-evidence.json`: 30,000,000 gas for single/batch execution. Require actual expected lifecycle progress and refund completion. Preserve `minEngineGas`, EIP-150 checks, the 1,000,000 post-engine reserve and 250,000 evaluator-return reserve. Do not raise limits to make a failing gate pass.
4. Export the immutable build with `scripts/export-perps-release.py`. Include test/fork logs, fixture and gas evidence, ABI hashes and full creation-input checks. Dirty-source outputs cannot count as an immutable release bundle.
5. Use the existing complete-stack deployment and verification flow. Write addresses/receipts to a separate candidate manifest, not the active deployment record. Do not bootstrap, seed or activate trading. Invoke `VerifyPerpsArbitrumSepolia.verifyOracleSynchronization()` with `ORACLE_SYNC_FIXTURE` and `PERPS_EXECUTION_CONFIG_HASH` in addition to the existing deployment environment. It never broadcasts.
6. Activation is a separate gate requiring matching keeper/frontend versions, funding readiness and a reviewed plan for existing-stack obligations. A failed candidate stays inactive; it is not a migration rollback mechanism.

## Monitoring contract

At one pinned block after each current Router update, read `getAcceptedBasketMark()` and the Engine mark. Require the
accepted mark's price and time to equal the Engine mark. A historical order may advance the Engine mark without
advancing the accepted live basket; record that provenance separately. Do not infer current-basket coverage from
Pyth's stored-feed timestamps, which historical execution still changes. The settlement monitor classifies an
uninitialized accepted basket or stale frozen mark as a known oracle-policy blocker. Record transaction identity,
accepted mark, Engine mark, and policy mode for any violation; block qualification pending investigation.

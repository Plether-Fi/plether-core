# Atomic historical oracle synchronization

Historical order resolution now pays for `parsePriceFeedUpdatesUnique` and `updatePriceFeeds` on the **same signed payload**. It checks each configured stored feed against its corresponding parsed timestamp before returning. The fill and neutral mark still come from the unique historical tick. A newer stored price never substitutes for that tick.

This requires a fresh complete stack: the execution sidecar is immutable and the Engine's Router binding is one-time. The candidate release stays inactive. Existing positions, queues, protections, balances, claims and LP obligations are not migrated.

## Consumer integration

For a new order resolution, call the new oracle's `getOrderExecutionFee(updateData)` at the same block as other preflight reads. Outside frozen policy it returns twice `getUpdateFee(updateData)`; frozen execution returns one fee. The generic quote remains correct for mark refresh, liquidation and LP settlement. FAD alone does not enable the single-fee path. Consumers must not fall back to the generic quote when the new selector is absent.

Single execution forwards the quoted amount. For a batch of N candidate orders using one payload, N times the execution quote is a conservative funding bound; cleanup and synchronized cache reuse consume no Pyth fee. Re-simulate before submission because policy, queue and fee state may change. Keep the keeper's outcome-aware gas preflight: a successful RPC call or estimate that returns Pending is not successful execution.

`PriceSnapshot.updateFee` reports funding forwarded for the resolution, not unconditionally consumed fees. Successful new historical resolution reports two fees; frozen resolution reports one; reuse reports zero. On unavailable history with `ok=false`, it reports two fees even though both are refunded/deferred by the oracle. Router accounting subtracts that allocation from its final refund, preventing double payment. Direct oracle execution callers must continue supplying the exact quote; successful direct calls do not refund overpayment.

Failed immediate oracle refunds remain in `oracle.claimableEth(recipient)`. Failed Router refunds are recorded by RouterAdmin. Index and expose both existing claim paths; do not infer that an unavailable parse consumed the quoted funding.

Public Router execution accepts no cache. Its in-memory cache starts empty and is populated only after successful resolution and synchronization. The permissionless oracle cache helper still accepts unauthenticated prices: its coverage check proves only that stored timestamps cover the supplied basket timestamp. External consumers must not treat that helper as an authenticated quote for arbitrary cache contents.

## Failure and compatibility rules

`PletherOracle__StoredFeedBehind(feedId, storedPublishTime, requiredPublishTime)` means synchronization or cache coverage failed. Synchronization errors, insufficient fees and failed coverage revert the whole transaction, including previous batch progress. Only a reverted historical parser follows the existing unavailable-history path. Caught later item failures retain synchronized mark updates and consumed fees according to the existing lifecycle policy.

Import the matching release ABIs and verify chain, addresses, runtime hashes, Engine/Router/Oracle bindings and execution-config hash. The order/receipt and snapshot/cache tuple layouts are unchanged. New deployment addresses change the existing configuration hash domain; invalidate old reviews and require fresh review plus explicit user confirmation. Keep existing worker repair and bounded UI recovery.

## Release qualification

1. Run normal CI, all four production-codegen deep shards, formatting, package boundaries and full creation-input/runtime size gates on one immutable source commit.
2. Capture a signed six-feed fixture with `scripts/capture-oracle-sync-fixture.py`. Run `scripts/run-oracle-sync-fork.py FIXTURE OUTPUT` to replay identical baseline/candidate scenarios. This pins block/hash, untouched Pyth storage, signed bytes/checksum, unique windows and exact fill/mark equality. A missing fixture, frozen window, already-covered mark or skipped test fails qualification.
3. Run `OracleSynchronizationTest` and the synchronization invariant under production settings. Gas tests use the app revision/cap in the candidate's `keeper-evidence.json`: 30,000,000 gas for single/batch execution. Require actual expected lifecycle progress and refund completion. Preserve `minEngineGas`, EIP-150 checks, the 1,000,000 post-engine reserve and 250,000 evaluator-return reserve. Do not raise limits to make a failing gate pass.
4. Export the immutable build with `scripts/export-perps-release.py`. Include test/fork logs, fixture and gas evidence, ABI hashes and full creation-input checks. Dirty-source outputs cannot count as an immutable release bundle.
5. Use the existing complete-stack deployment and verification flow. Write addresses/receipts to a separate candidate manifest, not the active deployment record. Do not bootstrap, seed or activate trading. Invoke `VerifyPerpsArbitrumSepolia.verifyOracleSynchronization()` with `ORACLE_SYNC_FIXTURE` and `PERPS_EXECUTION_CONFIG_HASH` in addition to the existing deployment environment. It never broadcasts.
6. Activation is a separate gate requiring matching keeper/frontend versions, funding readiness and a reviewed plan for existing-stack obligations. A failed candidate stays inactive; it is not a migration rollback mechanism.

## Monitoring contract

At one pinned block, read the Engine mark and all six configured Pyth feeds:

`coverageLag = max(0, lastMarkTime - min(component.publishTime))`

Require zero lag after every execution that installs a mark. For validation inspect state immediately after the target transaction (replay/trace if there are later transactions in its block); a later worker repair must not mask a violation. Timestamp coverage is independent of freshness, divergence and confidence: classify those failures separately. Missing RPC data is inconclusive, never a healthy observation. Record block/transaction identity, feed timestamps and mark timestamp for any violation; block qualification/activation pending investigation.

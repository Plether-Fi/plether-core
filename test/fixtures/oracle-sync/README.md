# Atomic synchronization fixture

`arbitrum-sepolia.json` contains the exact six-feed signed bytes from public `updateMarkPrice(bytes[])` transaction `0xbbaa2f141521921dc74baae8e446d7332b46fb10d976d863200aa917d1e90df2`. No API key was used. Pinned pre-commit state is block `311597305`, hash `0x55b6ab63d5a1b1169fee63c836b5d411923d05dd6734afe0a6684bb4dc52da1f`. Execution block/time describe the local fork continuation, not a broadcast order.

Reproduce its payload and state with a public archival RPC:

```sh
ARB_SEPOLIA_RPC_URL=https://arbitrum-sepolia.gateway.tenderly.co \
  python3 scripts/capture-oracle-sync-fixture.py /tmp/recaptured-oracle-sync.json \
  --baseline 71ba5cdcc3c1842ebe2669e8f7ddd9a31c0dcde8 \
  --source-transaction 0xbbaa2f141521921dc74baae8e446d7332b46fb10d976d863200aa917d1e90df2
```

The public-transaction path never reads or sends `PYTH_API_KEY`. Omitting `--source-transaction` uses the configured Hermes endpoint and optional `PYTH_API_KEY`; never commit credentials. Timestamp decoding follows Pyth's [accumulator price-message format](https://github.com/pyth-network/pyth-crosschain/blob/main/target_chains/ethereum/contracts/contracts/pyth/PythAccumulator.sol). The on-chain Pyth implementation, not this decoder, verifies signatures and the unique-tick window during fork replay.

The fixture is required, not silently skipped. It pins the fork block/hash and initial storage, six release feeds, unique-tick window, payload checksum and baseline source commit. Missing/invalid/otherwise-ineligible data cannot qualify a release. Commit the fixture and candidate, then run `scripts/run-oracle-sync-fork.py FIXTURE NEW_OUTPUT_DIRECTORY` with `ARB_SEPOLIA_RPC_URL` set. The runner executes the same test twice: baseline must reproduce the ordering failure, candidate must synchronize and preserve identical historical prices. Do not edit or replace Pyth state/code in either run. Forge lacks the native ArbSys precompile, so both revisions use the same test-only `ArbitrumForkSupport` shim at `0x64`; `vm.roll` represents L2 progression. The shim does not alter oracle data or validate native ArbSys behavior.

The shared regression sets the active Oracle's adverse-confidence multiplier to the release wrapper's 2,500 bps before rotating. The baseline rotation retains the wrapper setting; the current rotation copies the active Oracle policy. Equalizing that setup makes the signed historical-fill comparison meaningful across both revisions.

## V3 qualification matrix

`scenarios.json` references four immutable fixtures. The historical pair contains ticks at `1790091398` and `1790091433`; the second commit cannot reuse the first basket. The full combined `bytes[]` is quoted for each new resolution. Historical settlement uses each order's own window even when execution occurs after that window.

The Friday opening tick is `1790970892` (2026-10-02 19:54:52 UTC), before the natural FAD window. The closing tick is `1790974764` (20:59:24 UTC), shortly before the natural 21:00 UTC freeze. The V3 suite opens before FAD and closes after the natural freeze without changing oracle policy or signed data. Each additional fixture records the public transaction that supplied its exact bytes; recapture it with the same command above and its `payloadSource.transactionHash`.

Run the original regression plus all required V3 scenarios from a committed, clean checkout:

```sh
ARB_SEPOLIA_RPC_URL=https://arbitrum-sepolia.gateway.tenderly.co \
  python3 scripts/run-oracle-sync-fork.py \
  test/fixtures/oracle-sync/arbitrum-sepolia.json \
  artifacts/oracle-sync/NEW_REVISION/fork \
  --scenario-manifest test/fixtures/oracle-sync/scenarios.json
```

The required matrix covers historical single, shared and distinct baskets, natural frozen close, caught target failure, and immediate/deferred unavailable-history refunds. It uses the unchanged 30,000,000-gas cap and isolated Forge transaction contexts. Evidence records execution outcomes, exact ETH allocations, stored coverage and measured call gas. Call gas excludes transaction intrinsic gas and Arbitrum data fees; it is not a live transaction fee estimate.

The frozen-close case replays the Friday opening Engine mark after the natural close with empty data and no Pyth parse or storage update. Its zero fee and opening publish times are deliberate; the Friday closing payload establishes the calendar boundary but is not consumed during frozen execution.

`live-watermark-sep22.json` contains public Hermes timestamp responses for the same six configured feeds, pinned to the historical fixture's block and Pyth deployment. The three signed batches have publish times `1790091384`, `1790091390`, and `1790091391`. Run `forge test --offline --isolate --match-contract '^LiveBasketWatermarkForkTest$'` with `ARB_SEPOLIA_RPC_URL` set to replay initial acceptance, empty-data reuse, stale-payload rejection in real Pyth, and later advancement without mutating Pyth storage.

`live-watermark-uneven.json` selects a single faster feed and five slower feeds from those committed payloads. Reproduce it offline with `python3 scripts/derive-live-watermark-fixture.py`. Only the unsigned accumulator message count and selected entries change: signed messages, Merkle proofs and guardian-signed roots are copied verbatim. Real Pyth verifies them during the fork run. Tests require unequal component times, successful reuse of the unchanged faster feed when the others advance, rejection of missing components both before and after initial acceptance, and an exact out-of-order error for regressed components. Rejections must preserve the accepted basket and Engine mark; all live parsing must preserve Pyth storage.

`pool-epoch-sep23.json` pins block `311799811`, before the 2026-09-23 06:00 UTC LP epoch (`1790143200`). Its public transaction sources contain signed six-feed ticks four seconds before and eight seconds after that boundary. The mixed basket keeps the first feed's intact pre-boundary proof and the other five feeds' post-boundary proofs, all inside the live lookback. Reproduce the fixture with `python3 scripts/capture-pool-epoch-fixture.py /tmp/recaptured-pool-epoch.json`; no Hermes credential is used. `PerpsPoolEpochForkTest` opens a production V3 position and queues both junior LP requests before the cutoff. It requires the exact `PoolEpochComponentTooOld` rejection and rollback, then settles with the complete post-boundary basket, claims deposit shares and redemption cash, and reconciles USDC/ETH while preserving Pyth storage.

`PerpsLiquidationForkTest` reuses the September opening and October Friday-opening signed fixtures. The actual price move makes a normally opened position unhealthy after its free cash is withdrawn through the clearinghouse. A healthy-position control requires the exact solvent rejection and rollback; the later liquidation checks adverse execution price, neutral cached mark, keeper credit, pool/collateral custody and withdrawal of the trader's residual. The LP and liquidation fixtures deploy local protocol contracts and a mock collateral token; deployed Pyth verifies the unchanged signed inputs.

The supported Pyth deployment quotes `q = 0` at these captured blocks. The suite preserves that authentic fee configuration and adds a positive 1-gwei keeper surplus to exercise actual immediate and deferred RouterAdmin refunds. Evidence records whether each refund channel moved positive value. A zero Oracle allocation does not exercise a nonzero Oracle claim: those fee and liability paths are covered by the separate six-feed randomized invariant, which ranges `q` from zero to 1 gwei. These fixtures cannot establish production gas costs for nonzero Pyth fee transfers.

Only a complete, zero-skip matrix can qualify the follow-up. Missing fixtures or RPC data, invalid windows, unexpected pending outcomes, evidence omissions, or changed source inputs fail qualification. All remote operations are reads; no signer or transaction broadcast is involved.

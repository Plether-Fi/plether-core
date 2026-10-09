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

The fixture is required, not silently skipped. It pins the fork block/hash and initial storage, six release feeds, unique-tick window, payload checksum and baseline source commit. Missing/invalid/otherwise-ineligible data cannot qualify a release. Commit the fixture and candidate, then run `scripts/run-oracle-sync-fork.py FIXTURE NEW_OUTPUT_DIRECTORY` with `ARB_SEPOLIA_RPC_URL` set. The runner executes the same test twice: baseline must reproduce the ordering failure, candidate must synchronize and preserve identical historical prices. Do not edit or replace Pyth state/code in either run.

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

Only a complete, zero-skip matrix can qualify the follow-up. Missing fixtures or RPC data, invalid windows, unexpected pending outcomes, evidence omissions, or changed source inputs fail qualification. All remote operations are reads; no signer or transaction broadcast is involved.

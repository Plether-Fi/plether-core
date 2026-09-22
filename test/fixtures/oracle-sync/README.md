# Atomic synchronization fixture

Capture with `python3 scripts/capture-oracle-sync-fixture.py test/fixtures/oracle-sync/arbitrum-sepolia.json --baseline 71ba5cdcc3c1842ebe2669e8f7ddd9a31c0dcde8`.
The process reads `ARB_SEPOLIA_RPC_URL` and optionally `PYTH_API_KEY`; never commit credentials. The signed bytes are public data.

The fixture is required, not silently skipped. It pins the fork block/hash and initial storage, six release feeds, unique-tick window, payload checksum and baseline source commit. Missing/invalid/otherwise-ineligible data cannot qualify a release. The fork tests must run twice with the same fixture: `ORACLE_SYNC_EXPECT_FIXED=false` against the recorded baseline, then `true` against the candidate. Do not edit or replace Pyth state/code in either run.

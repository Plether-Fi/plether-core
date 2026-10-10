# Oracle synchronization validation follow-up

This follow-up to PR #103 adds independently modeled ETH conservation, a real-Pyth V3 scenario matrix, and complete local runtime/creation-input evidence. It does not change production contracts or their public interfaces. The original `atomic-oracle-sync-candidate` evidence remains historical and unchanged.

Qualification applies to source [`593230140be1aebfe6e227264ad5e50742121ea4`](https://github.com/Plether-Fi/plether-core/commit/593230140be1aebfe6e227264ad5e50742121ea4). The [candidate index](candidate-index.json) points to the [versioned manifest](v3-59323014/manifest.json), [gas records](v3-59323014/gas-evidence.json), and [complete evidence archive](v3-59323014/oracle-sync-v3-59323014.tar.gz). Local qualification is complete; deployed qualification remains false. The publication commit adds evidence and documentation after the qualified source commit.

## Recorded qualification

- [Normal CI](https://github.com/Plether-Fi/plether-core/actions/runs/37986310303): all 15 required jobs passed, including builds, package tests, coverage, formatting, package boundaries, static-analysis commands, and 63 Python tooling tests.
- [Deep perps](https://github.com/Plether-Fi/plether-core/actions/runs/37986310302): all four production shards and the aggregate gate passed with seed `0xdeadbeef`, 16 invariant runs and depth 500. Both new ETH properties and the stored-feed coverage property each have a retained 8,000-call, zero-revert receipt.
- The first cloud attempt of deep shard 1 reached the 30-minute limit while compiling the ordinary-test phase, after all 17 fuzz/invariant tests passed. Its sanitized log is retained alongside the final successful per-job attempts; no test setting or timeout was changed. The successful retry took 29m39s, leaving only 21 seconds of CI timeout headroom. Further CI runtime optimization remains useful; this is not a protocol gas-limit change.
- Original identical baseline/candidate regression and all seven isolated V3 scenarios passed without skips. Build and fork inputs have the same fingerprint before and after execution. Actual CI merge-checkout trees match the qualified source tree.
- 87 fresh V3 ABI/compiler artifacts were verified against 167 pinned source/dependency blobs. All 29 local deployment entries pass runtime and full creation-input limits, including constructor arguments and embedded sidecars.
- Static-analysis reports retain 311 raw detector findings across five packages. Command success is recorded separately; these are not independently validated vulnerabilities or a zero-findings claim.

| Real-Pyth scenario | Measured call gas | Verified result |
| --- | ---: | --- |
| Historical single | 1,997,530 | Executed; historical fill preserved |
| Shared-basket batch | 2,991,145 | Two executions; one parse/update pair |
| Distinct-basket batch | 3,687,886 | Two executions; two parse/update pairs |
| Natural frozen close | 1,342,497 | Position closed; one stored-feed update |
| Caught item failure | 976,532 | Failed receipt; synchronization retained |
| Unavailable history, immediate refund | 418,381 | Pending; surplus refunded once |
| Unavailable history, deferred refund | 393,419 | Pending; RouterAdmin claim paid once |

Every call uses the unchanged 30,000,000-gas cap. Call gas excludes transaction intrinsic gas and Arbitrum data fees. Authentic Pyth quotes are zero at these blocks; each scenario supplies a positive 1-gwei surplus, but zero Oracle allocations do not count as exercised Oracle refunds. Nonzero Oracle payments and claims are tested by the independent MockPyth invariant. These fork measurements do not establish nonzero Pyth-transfer gas costs.

The pinned keeper revision proves the supported gas cap only. It still uses generic fee quoting, so this evidence does not establish V3 consumer compatibility or the live service configuration. Matching consumer releases remain separate work.

The closest size margins are 95 bytes for `SettlementMonitorLens` full creation input (49,057 / 49,152), and 146 bytes for `CfdEngine` runtime (24,430 / 24,576). These measurements belong to this compiler/configuration and must be repeated after source or build changes.

Static findings and the two existing optional unrelated fork cases (`InsufficientFreeBounty` and `ZeroFreeReductionRejected`) are enumerated in the manifest and complete logs. A supplementary local replay passed its 17 fuzz/invariant tests, then was deliberately stopped during redundant ordinary-test compilation after the full cloud shard passed; its diagnostic-only status and log are retained and are not counted as a completed local shard. No synchronization scenario skipped. Older evidence remains unchanged. No active deployment record was modified.

## Reproduce

1. Start from a clean checkout with pinned submodules, Forge 1.5.1 and Solidity 0.8.35. Use production via-IR settings and optimizer runs 200.
2. Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_oracle*.py' -v` and the existing formatting/package-boundary checks.
3. Run normal CI and all four production deep-perps shards. The follow-up PR uses the `ci:deep-perps` label; both workflows also support stacked PRs. The ETH invariant uses the existing 16-run, 500-call deep settings and fixed `0xdeadbeef` seed. Normal CI retains its smaller smoke settings.
4. Run the complete signed-Pyth matrix described in `test/fixtures/oracle-sync/README.md`, with `--scenario-manifest test/fixtures/oracle-sync/scenarios.json`. Retain its original baseline comparison and every required V3 case.
5. Without changing the source revision, run `python3 scripts/export-perps-release.py artifacts/oracle-sync/NEW_REVISION/bundle --source-revision FULL_SHA`. This is an offline local build/test export. It compiles all consumer interfaces in fresh isolated output/cache directories and verifies compiler source hashes against the pinned revision. It validates every deployable's runtime and full creation input, including constructor arguments and embedded sidecars. Existing shared build outputs cannot supply interface ABIs.
6. Collect the CI/deep results, static-analysis reports, fork evidence, ABIs and size evidence into a versioned bundle; hash every retained file. Treat static-analysis output as findings requiring interpretation, not as a clean result merely because the command succeeded.

CI preserves the filtered coverage files and complete Slither SARIF reports as run artifacts. Qualification must retain these alongside the job results and sanitized logs, so command success cannot hide analyzer findings. The real-Pyth fixtures retain their actual zero-fee configuration; nonzero Oracle fees and claims are exercised by the randomized invariant, while a positive surplus proves real-Pyth RouterAdmin refund handling. See the fixture README for this measurement limitation.

Local qualification requires every mandatory gate to pass. Existing optional unrelated fork skips must be identified separately; no synchronization scenario may skip. Source changes invalidate the old revision's qualification claim. Evidence-only commits must continue naming the actual tested source revision.

Keeper monitoring, frontend integration, signing, remote deployment/simulation, activation and migration are outside this follow-up. The local Foundry fixtures create and exercise contracts only inside disposable test EVMs.

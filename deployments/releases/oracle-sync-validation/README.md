# Oracle synchronization validation follow-up

This follow-up to PR #103 adds independently modeled ETH conservation, a real-Pyth V3 scenario matrix, and complete local runtime/creation-input evidence. It does not change production contracts or their public interfaces. The original `atomic-oracle-sync-candidate` evidence remains historical and unchanged.

Qualification results belong to one committed source revision. The release index and bundle will identify that revision, compiler/dependency inputs, required results, sanitized logs and checksums. A successful ABI export alone is not qualification. Deployment qualification remains false; no active deployment record is modified.

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

# Integration with current master

The merge commit `2c34cc45a91f82378a1e326622439d93fa0e54d4` integrates master `64c6ea90a537f58f14b1da3c48d296a254ab85c7`, including full-close charge recovery (#104) and atomic historical oracle synchronization (#103). Production sources match that master commit exactly.

## Resolution

- Mapped upstream changes into the reorganized behavior suites and removed superseded conflict paths.
- Preserved all 44 added upstream test/property declarations exactly once. See [declaration reconciliation](merge-upstream-declarations.json).
- Preserved all five changed/added Engine functions and both shared helpers; see [full-close mapping](merge-full-close-mapping.json).
- Preserved all 22 active oracle synchronization fixture sites and the two-ETH batch correction; see [oracle mapping](merge-oracle-mapping.json). One former site belonged to a previously removed contract with no discoverable tests.
- Organized new charge suites, extracted six oracle gas checks into the production lane, and retained both new invariant suites. Fixed callback gas caps make the two ETH properties production-only PR checks; full production CI/audit executes them.
- Reconciled workflows, shard tests, profile budgets, and upstream evidence uploads.
- Cleaned excess EOF blank lines in 49 migrated files.

## Validation status

Formatting, package boundaries, 118 exact coverage-map references, shell/YAML checks and exact shard partitioning pass. All 93 runner/tooling tests pass: 21 recorded-runner tests, nine shard tests, and 63 oracle tooling tests.

The integrated quick, CI and full production CI runs are in progress. Their results must be recorded before claiming integrated-source acceptance. [Code hashes](integrated-code-sha256.json) identify this source. An initial attempt was interrupted during compilation after dependency initialization warnings; it did not execute tests. The restarted run uses local library clones at the same pinned commits.

The earlier three audit campaigns continue in their original frozen checkout. They validate the prior source, not this integration. All three full audit seeds must subsequently validate the integrated code. RPC-dependent coverage remains unavailable unless endpoints are configured.

The earlier [validation snapshot](validation-summary.json) and [source manifest](validated-source-sha256.json) are retained as historical evidence; their passed counts must not be attributed to the integrated source.

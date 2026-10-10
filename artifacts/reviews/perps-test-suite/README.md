# Perps test-suite review evidence

This draft changes tests, fixtures, documentation and CI. Production contracts match current master. Full acceptance remains pending.

Master conflicts are resolved in an isolated checkout; see the [integration report](merge-resolution.md) for the new source, preserved coverage and pending integrated validation. The counts below describe the earlier frozen baseline.

## Review order

1. [Coverage map](../../../packages/perps/test/perps/TEST_MAP.md): normative rules, exact tests, assertion methods, fixture limitations and execution lanes.
2. [Declaration dispositions](audit-test-dispositions.md): all 168 audit-derived declarations from 24 files; 135 retained, 30 rewritten, two duplicate cases merged and one vacuous case deleted. The historical names here identify removed inputs, not current vulnerability findings.
3. [Machine-readable dispositions](audit-test-dispositions.json) and [validated source hashes](validated-source-sha256.json).
4. [Validation snapshot](validation-summary.json): exact commands, compiler settings, budgets, counts and remaining gates.

## Findings and repairs

Assertions were repaired where they compared constants or copied balances, ignored low-level execution results, or inferred settlement from wallets while funds settled in clearinghouse balances. Tests now distinguish independent accounting expectations from production-to-production parity and synthetic fixtures.

Two further invariant assumptions failed on saved histories. Queue progress incorrectly required a successful trade after 32 batches even after liquidity starvation made terminal failures legitimate. Repaired checks authenticate outcomes, queue movement, reservation cleanup and exact keeper credits; all three saved histories replay successfully. Partial-close health incorrectly required pledge alone to exceed a bounty minimum. Repaired checks account independently for same-account claims and residual PnL while treating liquidation reserves separately, including an actual claim-backed partial-close execution.

These investigations confirmed test defects, not a production vulnerability.

## Validation and remaining gates

- Quick correctness: 1,857 passed, zero failures/skips; fuzz 256, invariant 16 × 128.
- CI correctness: 1,857 passed, zero failures/skips; fuzz 2,000, invariant 32 × 256.
- Full production CI: 1,924 passed, zero failures/skips with via-IR, solc 0.8.35 and optimizer 200.
- Formatting, package boundaries, 86 coverage-map references, exact shard selection and 21 runner tests passed.
- Fault sensitivity: eight targeted accounting mutations failed for the intended reason with two healthy controls; a separate admission source mutant was detected.
- Full production audit campaigns are running for seeds `0xdeadbeef`, `0x1`, and `0x2`, each with fuzz 20,000 and invariant 256 × 1,000. See the timestamped JSON snapshot; it is not a completion claim.
- Five package fork cases and external root integration coverage were not run because RPC endpoints are unavailable.
- Instrumented coverage ran six focused cases; compiler source-anchor warnings prevent claiming complete line/branch coverage.

The validated source is based on `75720362a4c1c7e26c99ea15927783e1a1173b80`. Remote master subsequently merged production fixes #103 and #104 at `64c6ea90a537f58f14b1da3c48d296a254ab85c7`. Their integration is now complete in the merge report; validation of the resulting source remains required before merge. The running campaigns retain the frozen validated source. Git commit metadata can differ between batches created before and after the PR commit; the common source manifest identifies the actual tested bytes.

The committed snapshot excludes large machine-local logs, caches and failure corpora. Recorded CI runners publish replay evidence as workflow artifacts. Local campaign evidence remains under `artifacts/perps-suite-review` and `artifacts/perps-resumable-audit-final`.

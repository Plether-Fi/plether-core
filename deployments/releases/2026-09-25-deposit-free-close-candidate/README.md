# Deposit-free close release candidate — 2026-09-25

Optimized source: `7fa1fdd1f6f72a60032907243dd0d65d3d985ef8`. This packet is for a **fresh stack**. It contains 83 consumer/interface ABIs, compiler settings and template sizes (`build.json`), ABI SHA-256 checksums, and verification evidence (`verification.json`). It contains no production deployment addresses and does not authorize broadcast or migration of existing positions.

The implementation and migration contract is [DEPOSIT_FREE_CLOSE.md](../../../packages/perps/DEPOSIT_FREE_CLOSE.md). Intent domain V3 and receipt/configuration domains V4 must be activated together. Keep historical ABI exports, old-stack app/keeper bindings, subsidy servicing, and already-authorized sponsored-operation reconciliation intact. New request builders perform a single commitment call without USDC assistance.

## Optimization results

The original implementation remains available at `e9df1ed8`; the optimized source is recorded above and in `build.json`.

| Operation | Initial implementation | Optimized | Reduction |
| --- | ---: | ---: | ---: |
| Close commitment | 1,086,923 | 980,673 | 9.78% |
| Full-close execution | 1,047,317 | 1,045,621 | 0.16% |
| Partial-close execution | 1,251,822 | 1,250,126 | 0.14% |

Compared with the original pre-feature checkout `8c555544`, commitment overhead falls from 26.65% to 14.27%. This first pass removes about 46% of that added overhead; execution changes are modest. All figures use identical operation fixtures and production codegen, not estimates of total Arbitrum fees. Engine runtime shrinks from 24,566 to 24,430 bytes, and the settlement sidecar shrinks from 24,510 to 23,596 bytes.

Storage compression preserves full-width carry/custody values and public receipt fields. Terminal identity fields in `pendingIntent` are populated only for CallerPaidFullExit. The candidate planner ABI no longer returns its unused projected snapshot from `planCloseCommit`; consume the updated ABI packet. Required funding, health, reservation, and source checks remain enforced.

## Verification

- Production acceptance and gas: **146 passed**, with 256 fuzz cases for each fuzz test.
- Fresh deployment, seeding, activation, instantiated runtime sizes and limiting constructor-inclusive initcode: **1 passed**, entirely inside the local test VM.
- Broad perps execution/fuzz/invariant run: **1,802 passed, zero failed, three archive-dependent tests skipped** across 237 suites, at the default 16 invariant runs × 500 depth. This includes the compact storage, commitment snapshot, fixed call buffer and carry-loop optimizations; the final canonical pool-cash read reuse is covered by the targeted and production runs below.
- Final policy/preview and deposit-free assessment regressions: **100 passed**. These overlap the production acceptance suites.
- SDK typecheck, build, and **31 tests passed**, including archived encoding compatibility.
- Full production build and all exported contract size gates passed. Engine runtime headroom is **146 bytes** and it also passes the existing 24,439-byte repository budget; monitor constructor-inclusive initcode headroom is **95 bytes**. Repeat these gates for every compiler/source change.

`verification.json` records individual run summaries and local log hashes. Local logs are not included as portable replay proof. Re-run on the review checkout.

## Reproduction

Pinned submodules and Forge 1.5.1-stable are required. Default production settings remain solc 0.8.35, via IR, optimizer 200, Prague.

```sh
# Broad execution/fuzz/invariant lane; gas and bytecode gates use production codegen separately.
FOUNDRY_VIA_IR=false forge test --root packages/perps --no-match-test 'RuntimeFitsEip170|FitsEip3860|FitDeploymentLimits|test_Runtime_|GasBudget|test_Gas_'
# Production acceptance and gas (full dependency compilation may take several minutes).
forge test --root packages/perps --match-contract 'DepositFree(Close|Carry)Test|PartialCloseHealthTest|GasProfileTest|OrderLifecycleBookTest|AtomicLpEpochSettlementTest' --fuzz-runs 256
forge test --match-contract VerifyPerpsArbitrumSepoliaTest
forge build --skip test
python3 scripts/generate-close-v3-abi.py --artifacts-dir out
npm --prefix packages/perps-aa-client run typecheck
npm --prefix packages/perps-aa-client test
npm --prefix packages/perps-aa-client run build
```

The recorded focused production run used a temporary entry importing these six suites to avoid recompiling unrelated tests; no source, compiler, optimizer, or fixture substitutions were used. The deployment run similarly imported the unchanged verifier test into a temporary entry.

## Remaining activation gates

The optimization CI is still running as this packet is prepared. The aggregate Slither check reports findings requiring triage, although the individual perps Slither job passes; this packet does not claim green CI or security approval.

1. Set `CLOSE_REGRESSION_ARCHIVE_RPC_URL` to an accessible Arbitrum Sepolia archive endpoint and run `HistoricalCloseRegressionTest`. Public endpoints returned HTTP 403 during this implementation. Historical runtime hashes and storage assertions at blocks 309041940 and 309758933 remain **unverified on chain**. The extra-$0.20 SHORT regression is covered locally by reservation-aware preview tests; synthetic reconstruction is explicitly labelled.
2. Integrate the exported new schemas and distinct funding/health/retryable errors in the external app and keeper. Caller-paid orders have no reward; automatic keeper execution is not guaranteed. Show and permit user execution with native gas/oracle funding.
3. In a separately authorized fresh-stack deployment, record all instantiated runtime hashes and addresses, including the execution sidecar's immutable `recoverySidecar()`. Verify the manifest and repeat deposit → open Max → execute → zero-free ordinary full/partial close plus caller-paid fallback with assistance disabled.
4. Retire new subsidy issuance only for that verified new stack. Old v1.2.3 recovery and servicing remain a separate open task.

Do not present this packet as production activation approval. No production transaction or existing user position was changed.

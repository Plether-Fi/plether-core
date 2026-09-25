# Deposit-free close release candidate — 2026-09-25

Optimized source: `c089e646d9eaa5418e83c654828e5b31618566fc`. This packet is for a **fresh stack**. It contains 83 consumer/interface ABIs, compiler settings and template sizes (`build.json`), ABI SHA-256 checksums, and verification evidence (`verification.json`). It contains no production deployment addresses and does not authorize broadcast or migration of existing positions.

The implementation and migration contract is [DEPOSIT_FREE_CLOSE.md](../../../packages/perps/DEPOSIT_FREE_CLOSE.md). Intent domain V3 and receipt/configuration domains V4 must be activated together. Keep historical ABI exports, old-stack app/keeper bindings, subsidy servicing, and already-authorized sponsored-operation reconciliation intact. New request builders perform a single commitment call without USDC assistance.

## Optimization results

The second pass packs all existing outcome/bounds fields into fewer storage slots and consolidates repeated collateral/configuration reads. Public ABI fields, numeric domains and authenticated receipt hashes are preserved. The initial implementation is `e9df1ed8`; first-pass baseline is `c6607419`.

| Operation | First pass | Second pass | Reduction |
| --- | ---: | ---: | ---: |
| Close commitment | 980,673 | 951,586 | 2.97% |
| Full-close execution | 1,045,621 | 986,901 | 5.62% |
| Partial-close execution | 1,250,126 | 1,191,406 | 4.70% |

Compared with the original pre-feature checkout `8c555544`, overhead is now 10.88% for commitment, 2.63% for full execution and 2.99% for partial execution. These comparisons use identical legacy-adapter operation fixtures and production codegen; they do not estimate complete Arbitrum fees.

New direct production-request benchmarks use cold protocol access state, zero free settlement and public lifecycle setup. Standard full/partial commitment saves about 2%; execution saves 4.29%/4.16%. Caller-paid commitment/execution saves 2.30%/3.05%. Full absolute values, fixture/log hashes, commands and measurement exclusions are in `verification.json` and the implementation notes. Compare each fixture only against its own baseline.

Compiler-confirmed internal bounds storage is 11→10 slots; permanent outcome storage is 13→11. Engine runtime stays 24,430 bytes; settlement sidecar shrinks to 23,436. The Book grows 56 bytes to 14,840. Single-plan execution has been evaluated and documented as a subsequent Engine/API refactor; it is not included in these savings.

## Verification

- Production acceptance and gas: **173 passed**, with 256 fuzz cases for each fuzz test.
- Fresh deployment, seeding, activation, instantiated runtime sizes and limiting constructor-inclusive initcode: **1 passed**, entirely inside the local test VM.
- Broad perps execution/fuzz/invariant run: **1,814 passed, zero failed, three archive-dependent tests skipped** across 238 suites, at the unchanged 16 invariant runs × 500 depth.
- Targeted collateral/policy/preview/close regressions: **107 passed**; packed lifecycle: **34 passed**; router configuration and rollback: **27 passed**. Direct and comparison gas: **nine baseline and nine candidate tests passed**. Counts overlap.
- SDK typecheck, build, and **31 tests passed**, including archived encoding compatibility.
- Full production build and all exported contract size gates passed. Engine runtime headroom is **146 bytes** and it also passes the existing 24,439-byte repository budget; monitor constructor-inclusive initcode headroom is **95 bytes**. Repeat these gates for every compiler/source change.

`verification.json` records individual run summaries and local log hashes. Local logs are not included as portable replay proof. Re-run on the review checkout.

## Reproduction

Pinned submodules and Forge 1.5.1-stable are required. Default production settings remain solc 0.8.35, via IR, optimizer 200, Prague.

```sh
# Broad execution/fuzz/invariant lane; gas and bytecode gates use production codegen separately.
FOUNDRY_VIA_IR=false forge test --root packages/perps --no-match-test 'RuntimeFitsEip170|FitsEip3860|FitDeploymentLimits|test_Runtime_|GasBudget|test_Gas_'
# Production acceptance and gas (full dependency compilation may take several minutes).
forge test --root packages/perps --match-contract 'DepositFree(Close|Carry)Test|PartialCloseHealthTest|GasProfileTest|OrderLifecycleBookTest|AtomicLpEpochSettlementTest|CfdCollateralSnapshotParityTest|OrderRouterAgentV2Test' --fuzz-runs 256
forge test --root packages/perps --match-test 'test_Gas_DirectClose' -vv
forge test --match-contract VerifyPerpsArbitrumSepoliaTest
forge build --skip test
python3 scripts/generate-close-v3-abi.py --artifacts-dir out
npm --prefix packages/perps-aa-client run typecheck
npm --prefix packages/perps-aa-client test
npm --prefix packages/perps-aa-client run build
```

The recorded focused production run used a temporary entry importing these eight suites to avoid recompiling unrelated tests; no source, compiler, optimizer, or fixture substitutions were used. The deployment run similarly imported the unchanged verifier test into a temporary entry.

For the direct-call baseline, check out `c66074198d264597b9ed287b2fbb2387094068f5` separately with its pinned submodules and copy only `packages/perps/test/perps/DirectCloseGas.t.sol` from the candidate into that checkout. Run the same direct-test command against both checkouts. The benchmark file is identical in both runs; its SHA-256 is recorded in `verification.json`. Existing `GasProfile` comparison fixtures require no test substitution.

## Remaining activation gates

The optimization CI is still running as this packet is prepared. Earlier aggregate Slither findings remain untriaged; this packet does not claim green CI or security approval.

1. Set `CLOSE_REGRESSION_ARCHIVE_RPC_URL` to an accessible Arbitrum Sepolia archive endpoint and run `HistoricalCloseRegressionTest`. Public endpoints returned HTTP 403 during this implementation. Historical runtime hashes and storage assertions at blocks 309041940 and 309758933 remain **unverified on chain**. The extra-$0.20 SHORT regression is covered locally by reservation-aware preview tests; synthetic reconstruction is explicitly labelled.
2. Integrate the exported new schemas and distinct funding/health/retryable errors in the external app and keeper. Caller-paid orders have no reward; automatic keeper execution is not guaranteed. Show and permit user execution with native gas/oracle funding.
3. In a separately authorized fresh-stack deployment, record all instantiated runtime hashes and addresses, including the execution sidecar's immutable `recoverySidecar()`. Verify the manifest and repeat deposit → open Max → execute → zero-free ordinary full/partial close plus caller-paid fallback with assistance disabled.
4. Retire new subsidy issuance only for that verified new stack. Old v1.2.3 recovery and servicing remain a separate open task.

Do not present this packet as production activation approval. No production transaction or existing user position was changed.

# Deposit-free close release candidate — 2026-09-25

Candidate source: `f7e8714c20f3f6d449d4d6ef87d0e4b852562389`. This packet is for a **fresh stack**. It contains 83 consumer/interface ABIs, compiler settings and template sizes (`build.json`), ABI SHA-256 checksums, and verification evidence (`verification.json`). It contains no production deployment addresses and does not authorize broadcast or migration of existing positions.

The implementation and migration contract is [DEPOSIT_FREE_CLOSE.md](../../../packages/perps/DEPOSIT_FREE_CLOSE.md). Intent domain V3 and receipt/configuration domains V4 must be activated together. Keep historical ABI exports, old-stack app/keeper bindings, subsidy servicing, and already-authorized sponsored-operation reconciliation intact. New request builders perform a single commitment call without USDC assistance.

## Terminal-record simplification

Permanent terminal records now use **two storage slots instead of eleven**. Account, terminal block, status, reason and full receipt hash remain queryable through `terminalOutcome(orderId)`. Detailed history remains in the unchanged `OrderFinalized` event; `verifyReceipt(receipt, terminalTime)` authenticates supplied data. Finalization checks, reservation/settlement rules and permanent client-ID replay records remain intact.

This intentionally changes the **new-stack read API**. Old `outcome(uint64)` calls fail; external consumers must migrate. SDK 0.2.0 adds `orderLifecycleV5Abi`, `hashOrderReceiptV4` and `decodeVerifiedOrderFinalized`; historical V4 ABI exports remain byte-for-byte unchanged. Intent V3, receipt V4 and configuration V4 hash domains and full receipt/event tuples remain unchanged. V5 identifies the read API only. See [SDK migration instructions](../../../packages/perps-aa-client/README.md).

| Direct zero-free-USDC operation | Previous pass | Two-slot records | Reduction |
| --- | ---: | ---: | ---: |
| Standard full execution | 1,416,433 | 1,235,575 | 12.77% |
| Standard partial execution | 1,464,115 | 1,283,257 | 12.35% |
| Caller-paid full execution | 1,386,566 | 1,225,608 | 11.61% |

Direct commitments increase only 265 gas (0.019–0.021%); they are effectively unchanged. Measurements compare frozen `23c19dfd` with this candidate using identical fixtures and production codegen. They are gross call-level EVM gas, before refunds and excluding intrinsic/calldata gas, L1 publication and oracle fees.

The separate legacy-adapter fixtures measure commitment 951,851, full execution 806,043 and partial execution 1,010,548. Compared with original pre-feature `8c555544`, commitment is 10.91% higher and execution is 16.18%/12.64% lower. Do not mix fixture families. Earlier optimization evidence remains in `DEPOSIT_FREE_CLOSE.md` and `verification.json`.

Engine runtime remains 24,430 bytes, settlement sidecar 23,436, and lifecycle Book is 14,723 (117 smaller). All original runtime/initcode gates remain enforced. Commitment-history events were evaluated, not implemented: retain live commitment history for this candidate to avoid a further receipt/assessment migration or a historical-data dependency in cleanup. Single-plan execution also remains a separate evaluated refactor.

## Verification

- Production lifecycle/close/agent/gas suites: **144 passed**, with 256 cases per fuzz test. Includes independent Solidity/TypeScript receipt hash vectors, altered history/domain/time rejection, full historical-field reconstruction and replay.
- Fresh deployment, seeding, activation, runtime and limiting constructor-inclusive initcode: **1 passed**, entirely in the local test VM.
- Broad perps execution/fuzz/invariant run: **1,818 passed, zero failed, three archive-dependent tests skipped across 238 suites**; invariant settings remain 16 runs × 500 depth.
- SDK typecheck/build and **36 tests passed**, retaining all old action and sponsorship vectors and the complete historical V4 ABI. The export-list fixture adds only the three new reviewed exports; package version advances to 0.2.0.
- Full production build and refreshed 83-ABI export enforce the existing size gates. Engine EIP-170 headroom remains 146 bytes (9 bytes below the tighter repository budget); monitor constructor-inclusive initcode headroom remains 95 bytes.

`verification.json` records current and prior-pass evidence separately. Counts overlap and must not be summed. Local log hashes are not portable replay proof; re-run on the review checkout.

## Reproduction

Pinned submodules and Forge 1.5.1-stable are required. Default production settings remain solc 0.8.35, via IR, optimizer 200, Prague.

```sh
# Broad execution/fuzz/invariant lane; gas and bytecode gates use production codegen separately.
FOUNDRY_VIA_IR=false forge test --root packages/perps --no-match-test 'RuntimeFitsEip170|FitsEip3860|FitDeploymentLimits|test_Runtime_|GasBudget|test_Gas_'
# Production acceptance and gas (full dependency compilation may take several minutes).
forge test --root packages/perps --match-contract 'DepositFree(Close|Carry)Test|GasProfileTest|OrderLifecycleBook.*Test|OrderRouterAgentV2Test|Direct.*GasTest' --fuzz-runs 256
forge test --root packages/perps --match-test 'test_Gas_DirectClose' -vv
forge test --match-contract VerifyPerpsArbitrumSepoliaTest
forge build --skip test
python3 scripts/generate-close-v3-abi.py --artifacts-dir out
npm --prefix packages/perps-aa-client run typecheck
npm --prefix packages/perps-aa-client test
npm --prefix packages/perps-aa-client run build
```

The focused production run used a temporary entry importing `DirectCloseGas.t.sol`, `GasProfile.t.sol`, `OrderLifecycleBook.t.sol`, `OrderLifecycleBookUnpinnedConfig.t.sol`, `DepositFreeClose.t.sol`, and `OrderRouterAgentV2.t.sol`. No source, compiler, optimizer or benchmark fixture substitutions were used. The deployment run imported the unchanged verifier test into a temporary entry.

For the direct and legacy-call baselines, check out `23c19dfd` separately with its pinned submodules and run the same gas fixtures. Both benchmark files are unchanged in the candidate. Baseline and candidate fixture/log hashes are recorded in `verification.json`.

## Remaining activation gates

At the pre-push CI snapshot, package, TypeScript, coverage and individual Slither jobs passed, while aggregate Slither failed. Fresh CI must be checked after this update; this packet does not claim green CI or security approval.

1. Set `CLOSE_REGRESSION_ARCHIVE_RPC_URL` to an accessible Arbitrum Sepolia archive endpoint and run `HistoricalCloseRegressionTest`. Public endpoints returned HTTP 403 during this implementation. Historical runtime hashes and storage assertions at blocks 309041940 and 309758933 remain **unverified on chain**. The extra-$0.20 SHORT regression is covered locally by reservation-aware preview tests; synthetic reconstruction is explicitly labelled.
2. Integrate the V5 terminal read API, verified receipt-event retrieval, exported new schemas and distinct funding/health/retryable errors in the external app and keeper. Caller-paid orders have no reward; automatic keeper execution is not guaranteed. Show and permit user execution with native gas/oracle funding.
3. In a separately authorized fresh-stack deployment, record all instantiated runtime hashes and addresses, including the execution sidecar's immutable `recoverySidecar()`. Verify the manifest and repeat deposit → open Max → execute → zero-free ordinary full/partial close plus caller-paid fallback with assistance disabled.
4. Retire new subsidy issuance only for that verified new stack. Old v1.2.3 recovery and servicing remain a separate open task.

Do not present this packet as production activation approval. No production transaction or existing user position was changed.

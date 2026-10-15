# Zero-close implementation evidence

> Pinned evidence for the 2026-10-14 source revisions below. Tuple and domain statements in this record describe
> that revision; current source has a further ABI cleanup and V5 receipt/config domains. Do not use this record as
> the current deployment ABI or as evidence that the later cleanup was validated.

Status on 2026-10-14: implementation committed; remaining local audit and CI validation **cancelled at the user's request**. This is not a full-validation pass or an activation approval. No public-chain transaction was sent and no operator wallet was funded.

## Source revisions

- Core base: `fd4e0395505079dadfafc5e3a5a2ec55135d8f35` (`origin/master` when implementation began).
- Contract, SDK, tests and operations documentation: `cbddd4f701607ea396d61ce4b4dd1908995a2a5d`.
- Reproducible native fallback fork block: `542e9ae9` (test-only follow-up).
- App base: `7d4205c5a2ab09004c9ceead535a7e9b1e06716b`; implementation: `5e29eb48`, branch `codex/zero-close-bounties` in plether-app.

Production Solidity changes span 18 files: 83 inserted and 630 deleted lines. Public receipt/config tuple shapes and enum numbering remain, but removed pledge-escrow storage and internal interfaces require a coherent fresh stack. This is not a storage-compatible in-place upgrade.

## Completed local evidence

| Check | Result and scope |
| --- | --- |
| Perps broad quick correctness | 2,217 passed, zero failures/skips; non-IR, excluding gas and fork entrypoints. Production source matches the committed change; later corrections concern gas receipt expectations and fork pinning. |
| Production gas/size selection | 87 passed, three failed because the gas helper still expected paid close receipts. Helper corrected in `cbddd4f7`; rerun cancelled. **Final gas selection is unverified.** |
| Full production-codegen CI shard 2 | 55 passed, zero failures/skips. Other shards interrupted; no complete CI claim. |
| Actual SimpleAccount fallback fork | Three passed with production codegen: owner partial/full close through the same account, oracle-free expiry/retry, foreign-owner rejection. Used real pinned v0.8 runtime hashes and fresh local perps/MockUSDC/MockPyth. The later explicit RPC-block pin (`319094449`) rerun was interrupted. |
| SDK | 84 tests passed; typecheck/build passed. Packed and installed compatibility smoke passed from clean commit `cbddd4f7`, including all exports, 11 action encodings, sponsorship/UserOperation hashes and protection journaling. No package published. |
| Operator CLI | Read-only runtime/graph verification against immutable Arbitrum Sepolia release v1.3.1; correctly classified `head=1,nextCommit=1` as empty. No signing/broadcast. |
| Backend | 1,296 Haskell tests passed, including canonical-head and native-cost cap checks. |
| Protection worker | 54 passed, zero skipped, including isolated PostgreSQL indexing/reorg/recovery tests and oracle-fee failure during expiry cleanup. |
| Frontend | Final app lint and production build passed. Final full unit run: 1,938 passed, one existing lifecycle UI test exceeded its 5-second timeout. The focused lifecycle/protection/error selection had previously passed 243 tests; final native fallback selection passed 22. **Full frontend suite is not green.** |
| Options | 199 passed, zero skipped. |
| Perps AA Solidity | 30 passed; two unconfigured historical fork cases skipped. This is nonfork evidence only. |
| Repository tooling | Package boundaries passed; 201 exact test-map references verified; inventory generated; 39 runner/shard tests and 63 oracle-tool tests passed; formatting check passed. |

The frontend timeout was `keeps indexed inclusion through a safe timeout and revokes it if the row disappears` in `PerpsLifecycleLabels.test.tsx`. It occurred while multiple Solidity compilers were active. Resource contention is a possible explanation, not a proven cause. No timeout/budget was relaxed and no assertion was removed to obtain a pass.

## Interrupted and deferred checks

The user stopped all audit campaigns, then all remaining local CI jobs and queued reruns. Full nonfork production-codegen audit at seeds `0xdeadbeef`, `0x1`, `0x2` is incomplete. No audit-budget reduction or successful-audit claim is made. Remaining quick/CI/fork, spot and root checks were stopped. Shard weights were not refreshed from an incomplete campaign.

CI must run the final production gas assertions, full selected correctness suites and frontend suite. Historical RPC forks remain separately configured prerequisites; their absence is not evidence of compatibility. The test-only fixed-block fork also needs its completed rerun.

Funded primary/standby operation, a deployed fresh manifest, live outage/failover rehearsal, measured operating runway and deployment-specific throughput/latency targets remain activation work. Local fork and unit tests do not establish sustainable keeper funding or unlimited-load liveness. See [ZERO_CLOSE_OPERATIONS.md](ZERO_CLOSE_OPERATIONS.md).

## Evidence location

Machine-readable run artifacts, source hashes and explicit user-cancellation records are retained outside Git at `/private/tmp/zero-close-validation`; individual logs use `/private/tmp/zero-close-*.log`. The installed SDK artifact is at `/private/tmp/zero-close-sdk-artifact`. These are local temporary paths, not durable CI artifact links. Historical reports were not rewritten, and generated JSON/build output is excluded from the implementation commits.

## Targeted cleanup follow-up, 2026-10-14

This section records the subsequent cleanup relative to core `77ac7786` and app `5e29eb48`; the earlier cancelled
campaign evidence above remains historical. Core source/test/SDK revisions are `30be05b0` (preview removal),
`d167dc55` (bookkeeping), and `82be2272` (unused hooks). App cleanup is `324b8774`.
No full local CI or audit campaign was restarted. Full selections remain GitHub CI's responsibility.

The cleanup removes a net 321 production Solidity lines and 87 frontend production lines. The only removed
deployed-contract functions are `CfdClosePreview.previewSponsoredClose`, `CfdClosePreview.validateSponsoredClose`,
`MarginClearinghouse.reserveCloseExecutionBountyFromSettlement`, and
`MarginClearinghouse.reserveStaleCloseExecutionBountyFromSettlement`. The constructor, compatibility getters,
remaining ABI fields, enum numbering and storage layouts are unchanged relative to `77ac7786`.
Protection trigger rewards, carry checkpointing, payout/refund/forfeiture and historical grant recovery remain.
The generated SDK error registry was also synchronized with the current source; historical ABI fixtures remain.

| Targeted check | Result |
| --- | --- |
| Solidity correctness | 333 passed, zero failures/skips; 11 selected entrypoints, 17 suites; quick profile, non-IR, 256 fuzz runs. Includes canonical close preview, carry/bounds, clearinghouse reservations, zero-bounty closes, lifecycle receipt fault controls, protection and liquidation. |
| Production-codegen gas/size | 15 passed, zero failures/skips; `CfdClosePreviewGas`, `DirectCloseGas`, `SourceBoundBountyGas`, and `PositionProtectionLiquidationBatchGas`; optimizer 200, via-IR, unchanged acceptance gates. This is not the complete production gas selection. |
| Contract ABI/storage | solc 0.8.35 standard-JSON baseline/current comparison across nine affected contracts/interfaces: exactly the four approved function removals (also reflected in `IMarginClearinghouse`), no additions or other ABI changes, unchanged normalized storage layouts. |
| SDK | 84 tests passed; typecheck passed; current ABI exports regenerated from the targeted build. |
| Frontend | 175 focused tests passed; lint, production build and final TypeScript check passed. Includes normal sponsored submission, native fallback, preserved trigger reward, journal hydration and historical authority recovery. |
| Repository checks | Formatting, diff whitespace, package boundaries, inventory generation and 205 exact test-map references passed. All 39 runner/shard tests passed. Two deleted-suite timing entries removed; remaining measurements retain their historical provenance. |

The tested core `.sol`/SDK `.ts` source and test fingerprint is
`c358f63047b400ee2caa753e8dea1fccaf6a9623c988330391c8c9664fad355c`.
It is SHA-256 over sorted existing, tracked/nonignored paths under `packages/perps/src`, `packages/perps/test`,
and `packages/perps-aa-client/src`, each path and file body followed by NUL. Documentation is excluded.
The corresponding frontend fingerprint is recorded in the app operations document.

Targeted logs, compiler inputs/outputs, ABI/storage comparison and exact selected entrypoint lists are retained
locally in `/private/tmp/zero-close-cleanup-validation`. Generated compiler JSON/build output remains outside Git.
The historical fork tests and archived deployed ABIs remain intact; no RPC fork, live service drill, deployment,
grant issuance or production transaction was performed by this cleanup. The focused frontend results do not
supersede the earlier full-suite timeout; GitHub must validate the complete current selection.

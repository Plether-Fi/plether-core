# Zero-close implementation evidence

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

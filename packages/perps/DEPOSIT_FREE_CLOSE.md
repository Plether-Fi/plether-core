# New-stack deposit-free close implementation

This change is for a fresh deployment. It is not an upgrade or recovery of the existing v1.2.3 stack. Historical bindings, decoders, subsidy servicing, and reconciliation of previously authorized sponsored operations remain in place. Nothing in this package authorizes broadcast, production activation, or migration of existing positions.

## Commitment and execution

`CloseCommitmentLib.project` is the shared commitment calculator used by the engine planner and prospective preview. It validates even a zero bounty, checkpoints carry, and reserves the snapshotted bounty from free settlement followed by eligible position pledge. Reservation changes classification, not custody. It immediately changes side margin and borrow base. Partial commitments require fully collected carry and strict maintenance/FAD health of the entire exposed position after reservation. Claims, unrealized gains, liquidation reserve, VPI backing, and other orders' reservations do not fund the bounty.

Execution preserves price-PnL collection, gain withholding, negative-VPI clawback, spendable action reserve, and free-settlement priority. Terminal-safe pledge release then funds charges before terminal-only committed-order margin. The clearinghouse verifies the released-pledge attribution against its current buckets. Receipt fields satisfy:

```
netReleasedMarginUsdc = safeMarginReleaseUsdc - actionChargeFromReleasedMarginUsdc
```

Partial reductions retain enough pledge to leave exact residual price equity strictly above the active maintenance/FAD requirement. At the boundary, one atomic USDC remains above the requirement. Retaining extra pledge is allowed; partial charge waivers are not. Claims count toward price equity but cannot pay fees. A realized net price gain counts once, as pledge when immediately paid or as a claim when deferred. A free-settlement action rebate is excluded from residual health. Exact entry-cost basis, terminal cap conservation, size quantum, minimum reduction, liquidation-reserve excess release, and rate schedules remain unchanged.

## Public modes and lifecycle

The request adds `CloseMode { Standard, CallerPaidFullExit }`. Opens require Standard. CallerPaidFullExit requires an exact live full close, matching side, zero margin delta, zero maximum post-position size, no pending account orders, and no active protection. No proof of funding exhaustion is needed. Gas and oracle updates remain caller-paid.

Caller-paid admission creates an explicit active zero reservation and an exclusive `pendingTerminalExitId`. Exact client-ID replay is idempotent. Fresh orders and protection creation remain blocked until canonical cleanup. Position epoch, size, and side are snapshotted; a changed position terminates with `TerminalPositionChanged` rather than resizing execution. Deposits and margin actions retain their normal checks. Global execution FIFO, oracle, delay, authorization, configuration, and execution bounds remain binding.

PendingOpen protection can be explicitly cancelled without cancelling its parent order. Armed protection must be cancelled before public terminal admission. Triggered protection executes its linked close. Latched protection retries its original reservation, including an explicitly active zero reservation. Protection bounty ownership never transfers to a public caller-paid request.

## Reservation authority and recovery

The clearinghouse owns backing and provenance; the lifecycle book owns intent and frozen entitlement. Bounty records have explicit None/Active/Settled/Moved/Quarantined state, account association through authenticated namespaces and IDs, free/pledge funding, and source position epoch. `positionEpoch` increments only on flat-to-open transitions.

Execution validates reservation identity, active state, entitlement, provenance totals, protected-reserve floor, and custody. A mismatch is retryable and leaves the whole item unchanged. `expireOrder(orderId)` is permissionless after `block.timestamp > validUntil`, requires no oracle update, and can unlink an expired later entry without executing it ahead of FIFO.

| Expired record | Disposition |
| --- | --- |
| Consistent | Existing expiry/protection policy |
| Authenticated, fully backed, entitlement differs | No keeper payment; refund actual backing by provenance |
| Missing or settled | No movement |
| Wrong owner | Leave the foreign record untouched |
| Invalid provenance, custody, or aggregate accounting | Quarantine identifiable backing, preserve disputed classifications, emit `LedgerInvariantViolation` |

Mismatch cleanup emits `ExpiredReservationMismatch`. Its receipt reports the actual refund and discrepancy; the difference from entitlement is not a receivable. Same-live-epoch pledge refunds return to pledge. Otherwise they become free settlement. Before refund changes the borrow base, accrued carry is checkpointed without collection or an oracle update, preserving arrears. An anomalous protection attempt terminates as Failed.

Automatic queue recovery assumes authenticated identities and valid aggregate accounting. Arbitrary synthetic custody/ownership corruption is not automatically repaired. There is no administrative balance-repair endpoint.

## ABI and consumer migration

Intent domain is V3. Receipt and execution-configuration domains are V4. Solidity's `OrderV2Types` name remains for source continuity; it does **not** imply ABI compatibility. Regenerate all tuple consumers together. Archived release ABIs remain the historical decoders.

Use the new request-taking overload:

```
previewClose(engine, account, request, executor, executionPrice, publishTime)
assessCommittedOrder(engine, orderId, executor, executionPrice, publishTime)
expireOrder(orderId)
```

The prospective preview validates router admission, projects commitment, then assesses execution. `fullExitBlockers` reports no position (1), pending account orders (2), active protection (4), and terminal lock (8). Simulation-only `assessOrder` and pure evaluators accept caller inputs and are not commitment authority. Committed assessment resolves the engine's router, lifecycle entitlement, exact reservation, and canonical pool depth; it projects any outstanding order-margin release that execution will perform.

Commitment effects include carry collected/outstanding, free/pledge bounty funding, and custody/free-settlement projections. Stored commitment effects are authenticated in terminal receipts. Close gross debit includes commitment carry collected, execution carry collected, price-loss custody/claim consumption, action cash collection, and snapshotted bounty once. A self-paid bounty is still gross debit, with zero net custody transfer. Action bounds include commitment carry once; explicit-fee bounds cover assessed execution fee and frozen spread. Absolute settlement bounds refer to total custody.

The AA client exports `orderRouterV3Abi`, `closePreviewV3Abi`, `committedOrderV3Abi`, `orderLifecycleV4Abi`, `CloseMode`, `buildCloseOrderV3`, and `buildExpireOrderV3`. The close builder emits one router call with no approval, deposit, or assistance. Existing historical exports remain unchanged. `closeFailureMessages` keeps bounty funding, cash-charge funding, residual health, caller-paid execution, and retryable reservation failures distinct. These helpers must be integrated in the separately deployed app/keeper before activation; this repository does not contain that application's production rollout.

Do not point the new preview/planner ABI at v1.2.3 contracts. Their planner return tuples differ. Keep the archived September preview and sponsored-close deployments bound to the old stack until its separate recovery task is resolved.

## Deployment and activation packet

The execution sidecar constructor creates an immutable, storage-free `OrderRecoverySidecar`, delegated only through the router execution path. The fresh manifest includes it; deployment logs expose the address and the verifier checks its code and binding using `PERPS_ORDER_RECOVERY_SIDECAR`. Its constructor does not consume the deployer's CREATE nonce used for the router/lifecycle-book address calculation.

Use `scripts/export-perps-release.py` only after source/build inputs are committed, dependencies match pinned submodules, and production compilation passes. It exports consumer ABIs and compiler size evidence without broadcasting. Verify constructor-inclusive initcode and substituted runtime hashes in deployment simulation, then record every address/runtime hash in a new manifest. Do not overwrite historical manifests.

Activation requires the full regression/invariant suites, production size checks, historical evidence, and a fresh-stack smoke test with assistance disabled: deposit, open Max, execute, ordinary full and partial zero-free closes, and caller-paid fallback. Retire new subsidy issuance only for that verified new stack. Preserve old-stack servicing and authorized reconciliation. Deployment and activation remain separate operator actions.

## Verification status and provenance

Focused tests use public funding/open/commit/execute calls. `DepositFreeClose.t.sol` labels deliberate entitlement corruption as synthetic. `PartialCloseHealth.t.sol` labels mathematical boundary fixtures as pure-plan simulations. Neither is represented as a historical fork replay.

Historical acceptance still requires the reservation-aware SHORT extra-$0.20 case, block 309041940's $0.002-free commitment, and block 309758933's 10,000-token zero-free reduction at raw price 98182413, with deployed runtime hashes and storage layouts checked. Public Arbitrum Sepolia RPC requests returned HTTP 403 during implementation; historical archive evidence must not be marked verified from local synthetic tests.

## Retained hardening and new work

PR #99's reservation-aware preview, protected-bounty accounting, canonical receipt lifecycle, and rollback isolation remain in effect. PR #100's archived sponsored-close ABI and old-stack bindings remain available for servicing and reconciliation. The old deployed preview is required for old planner tuples.

New work adds pledge-funded commitment, released-pledge charge funding, strict residual health with retained collateral, explicit caller-paid terminal admission, position epochs and provenance-aware recovery, oracle-independent expiry, authoritative committed assessment, and V3/V4 consumer schemas. No fee/carry schedule, VPI economic formula, liquidation-reserve top-up policy, or terminal shortfall allocation is changed.

## Measured production costs

Compiler: Solidity 0.8.35, optimizer 200, via IR, Prague; Forge 1.5.1-stable. Compared with checkout `8c555544` using the same `GasProfile` fixtures and compiler settings:

| Operation | Baseline gas | Candidate gas | Change |
| --- | ---: | ---: | ---: |
| Close commitment | 858,206 | 1,086,923 | +26.65% |
| Full-close execution | 961,649 | 1,047,317 | +8.91% |
| Partial-close execution | 1,156,801 | 1,251,822 | +8.21% |
| Engine close preview | 146,185 | 148,113 | +1.32% |

These are measured operation gas, not the surrounding test's total gas. New authentication, provenance, commitment effects, and receipt fields have a measurable cost. Native execution and oracle costs remain caller-paid.

The engine runtime is 24,566 bytes (10 bytes below EIP-170); its settlement sidecar is 24,510 bytes (66 bytes below). The release router's constructor-inclusive initcode is 47,159 bytes; the settlement monitor's is 49,057 bytes (95 bytes below EIP-3860). Future source/compiler changes must repeat size gates. The release build packet records all contract template sizes; deployment simulation checks instantiated runtime sizes and these limiting constructor paths.

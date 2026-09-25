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

The AA client exports `orderRouterV3Abi`, `closePreviewV3Abi`, `committedOrderV3Abi`, `orderLifecycleV5Abi`, `CloseMode`, `buildCloseOrderV3`, and `buildExpireOrderV3`. The close builder emits one router call with no approval, deposit, or assistance. Existing historical exports remain unchanged. `closeFailureMessages` keeps bounty funding, cash-charge funding, residual health, caller-paid execution, and retryable reservation failures distinct. These helpers must be integrated in the separately deployed app/keeper before activation; this repository does not contain that application's production rollout.

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

## Storage and read optimization

The internal lifecycle record packs account/mode/terminal identity together and the two bounty-source amounts into one slot. Bounty widths match the clearinghouse's existing uint96 limit; carry and custody amounts retain uint256, including values above uint128. Pre-commitment custody is reconstructed exactly as post-commitment custody plus collected carry. Commitment validates that identity before accepting the record. The public pending-intent and receipt tuples remain unchanged. Position epoch/side/size in the pending intent are populated only for CallerPaidFullExit; ordinary order identity remains in the router order, and pledge funding provenance remains in the clearinghouse reservation.

Actual commitment loads only the relevant side and funding/health fields, while prospective previews retain the full execution snapshot. Both use the unchanged `CloseCommitmentLib` calculation. The pure planner's `planCloseCommit` returns only commitment effects; its unused projected-snapshot return was removed from this not-yet-deployed candidate ABI. Regenerate planner consumers with the release packet.

Both carry-side checkpoints share one pool-cash read because index updates do not move pool cash. Committed assessment also reuses its canonical pool-depth observation for carry cash; non-authoritative simulations still fetch actual pool cash independently from caller-supplied pricing depth. Reservation authentication, bounds, terminal conservation, and post-settlement checks remain in place.

The engine's fixed-shape sidecar call shares one buffer for its 100-byte input and 224-byte output. It checks the exact response length, bubbles revert bytes, and returns through Solidity so terminal/borrow synchronization and the reentrancy modifier's cleanup always run. Regression tests cover malformed return data, rollback, subsequent successful execution, full-width commitment round trips, and invalid reconstruction identities.

## Second optimization pass

The second pass made lifecycle bounds use a private 10-slot representation instead of 11 slots, and permanent outcomes use 11 slots instead of 13. The subsequent product simplification below supersedes that terminal representation. The compiler-confirmed layouts preserve every public field and accepted numeric domain, with explicit expansion into the existing ABI tuples. Receipt and request hashes remain unchanged, and the pending entitlement remains at slot offset 3. That pass alone moved no outcome fields exclusively to events.

`CfdEngineCollateralSnapshotLib` expands a single canonical clearinghouse isolation observation into the planner's account and locked-margin buckets. Execution and assessment add a separate protected-bounty read; commitment keeps execution-only output fields zero. This replaces six overlapping execution getters with two and four commitment getters with one. Parity tests retain the exact checked arithmetic and zero-floor behavior, including labeled synthetic corruption cases.

Normal execution reuses the configuration digest already read after oracle/mark updates while entering the authenticated Router item. Only static dependency reads and Router self-calls intervene before comparison. Pre-oracle cleanup and public committed assessment still validate configuration independently; cleanup without an observation reads a fresh digest. An oracle-callback regression verifies that a finalized configuration change cannot execute under the earlier policy.

`DirectCloseGas.t.sol` measures production Router request calls for standard full, standard partial and caller-paid full exits at zero free settlement. Requests and oracle data are prepared outside the measured section; execution commitments run in fixture setup, and protocol access state is explicitly cooled. These figures complement the unchanged legacy-adapter comparison below. They measure call-level EVM gas before refunds and exclude intrinsic/calldata gas, L1 publication cost and oracle service fees.

## Single-plan execution evaluation

Single-plan execution remains a feasible subsequent architectural change; this pass retains independent Engine planning. The recommended boundary is an Engine-owned, `onlyRouter`/`nonReentrant` committed-close entrypoint that builds one canonical snapshot and plan, invokes an Engine-authenticated policy helper to validate that exact plan against the pending order and reservation, then applies the same delta and returns the fixed-shape assessment. Public committed assessment must retain its standalone authentication. Router post-state/bounty checks and clearinghouse settlement-source checks remain independent.

Do not turn an evaluator-returned delta into an authoritative ledger mutation. A combined entrypoint also needs exact failure-phase evidence (`priceReachedEngine`), malformed-return/typed-error decoding, gas-envelope changes, batch rollback coverage, and new interface exports. The Engine currently has only nine bytes under its existing repository runtime budget, so the refactor must demonstrate code extraction or other savings before adding entrypoint plumbing. These architectural changes are evaluated here, not implemented or included in the measured savings.

## Measured production costs

Compiler: Solidity 0.8.35, optimizer 200, via IR, Prague; Forge 1.5.1-stable. Identical `GasProfile` operation fixtures compare original checkout `8c555544`, initial implementation `e9df1ed8`, the first optimization at `7fa1fdd1`, and the second pass:

| Operation | Original checkout | Initial implementation | First pass | Second pass | Second pass vs original |
| --- | ---: | ---: | ---: | ---: | ---: |
| Close commitment | 858,206 | 1,086,923 | 980,673 | 951,586 | +10.88% |
| Full-close execution | 961,649 | 1,047,317 | 1,045,621 | 986,901 | +2.63% |
| Partial-close execution | 1,156,801 | 1,251,822 | 1,250,126 | 1,191,406 | +2.99% |
| Engine close preview | 146,185 | 148,113 | 148,113 | 148,113 | +1.32% |

The second pass saves **29,087 gas (2.97%) per commitment** and **58,720 gas per execution** (5.62% full and 4.70% partial) relative to the first pass. These are unchanged operation-fixture comparisons, including the test-only legacy adapter for commitment; they are not quotes for complete Arbitrum transaction fees.

The independent direct production-request fixtures compare frozen checkout `c6607419` with the second pass. Every case starts at zero free settlement. No test adapter is deployed, protocol access state is cold, and execution commitments are already persisted in fixture setup:

| Direct production call | First-pass baseline | Second pass | Reduction |
| --- | ---: | ---: | ---: |
| Standard full commitment | 1,438,107 | 1,409,016 | 2.02% |
| Standard partial commitment | 1,459,443 | 1,430,352 | 1.99% |
| Caller-paid full commitment | 1,276,767 | 1,247,367 | 2.30% |
| Standard full execution | 1,479,917 | 1,416,433 | 4.29% |
| Standard partial execution | 1,527,599 | 1,464,115 | 4.16% |
| Caller-paid full execution | 1,430,149 | 1,386,566 | 3.05% |

The two tables use different fixtures and access conditions, so compare columns within a table. Direct figures exclude transaction refunds, intrinsic/calldata gas, L1 publication and oracle service fees. Each fixture also asserts successful lifecycle and accounting outcomes.

Engine runtime is **24,430 bytes**, below both EIP-170 (24,576) and the existing repository budget (24,439); the budget was not relaxed. Its settlement sidecar is **23,436 bytes**, down another 160 bytes. The lifecycle book grows by 56 bytes to 14,840; all deployment limits remain enforced. The release router's constructor-inclusive initcode is **47,159 bytes**; the settlement monitor's remains **49,057 bytes**, leaving 95 bytes below EIP-3860. Repeat compiler and size gates after every source change. The release packet records all contract template sizes, while deployment simulation checks instantiated runtime sizes and the limiting constructor paths.


## Smaller terminal records and consumer migration

The new candidate stores only account, terminal block, lifecycle status, terminal reason and receipt hash: **two slots instead of eleven**. Complete terminal receipt data remains in the unchanged `OrderFinalized` event. Finalization validates the same identity, bounds, entitlement, commitment and receipt semantics before persisting the summary and deleting pending state. Client-ID replay records remain permanent. No settlement, funding, protection or recovery policy is relaxed.

This is an intentional new-stack read-API change. `outcome(uint64)` is removed, so stale calls fail rather than returning fabricated zero details. Consumers use `terminalOutcome(uint64)` and fetch the Book's event at `terminalBlock`. The Book's `verifyReceipt(receipt, terminalTime)` hashes a supplied receipt using its stored block and its chain/Book/Router domain; it cannot retrieve missing event data. Validate the indexed order/account/client ID and event hash as well. Do not present an unavailable event as zero economics.

SDK version 0.2.0 exports `orderLifecycleV5Abi`, `hashOrderReceiptV4`, and `decodeVerifiedOrderFinalized`. The helper checks the emitter, indexed identity, summary fields and exact domain hash before returning full event history. Its summary must come from the trusted Book on the intended chain; apply finality/reorg policy before caching. Existing `orderLifecycleV4Abi` is archived unchanged for older candidates, and other historical bindings remain intact. Intent V3, receipt V4 and configuration V4 domains and full event tuples are unchanged. V5 names the read API, not a new receipt hash domain.

The external app/keeper must migrate historical detail reads before new-stack activation. Index by chain, Book and order ID, retain full receipts and terminal times, and refetch on reorg. A smart contract that needs detailed history must receive the receipt and call `verifyReceipt`; it can no longer read those details by order ID alone. See the SDK README for the retrieval example. Existing position and old-stack servicing remain outside this migration.

## Evaluation: commitment-history events (not implemented)

Current commitment storage occupies five slots: carry collected; carry outstanding; packed free/pledge bounty provenance; post-commitment custody; and post-commitment free settlement. The latter three historical amounts (outstanding carry and the two post-state balances) are candidates for moving to an event. Collected carry still participates in gross/action bounds, and live bounty entitlement/provenance must remain authenticated. This is different from terminal summaries: these fields are read while the order remains pending and copied into assessed/final receipts.

A conservative design would retain collected carry and the packed bounty provenance, replace the three historical slots with a hash, and emit the complete commitment effects. That removes **two net slots**, not three. The hash preserves authority only if the original data can be supplied and verified; it does not let existing assessment or execution entrypoints reconstruct it. To retain current interfaces and complete receipts, a keeper would need to supply the preimage on execution, expiry, liquidation and protection cleanup, or the receipt schema would need to reference commitment history instead of copying it. Requiring historical preimages for permissionless cleanup would create a new availability dependency and is unsuitable for the deposit-free exit goal.

A cleaner product alternative would keep only live carry/provenance state and make terminal receipts reference an authenticated commitment event. Assessment and receipt clients would join two events; historical commitment balances would cease to be directly queryable while pending. This could remove three slots before adding any required commitment digest, but changes the public pending, assessment and receipt schemas and needs a fresh authority design. It must never weaken commitment carry bounds or refund provenance. No gas percentage is claimed without an implementation and identical-fixture measurement.

**Recommendation:** keep commitment history unchanged for this candidate. The terminal simplification captures permanent-write savings with the existing full receipt event. Revisit commitment events only when the external app/keeper can accept a coordinated schema change and event-history retrieval is proven in operation; preserve oracle-independent expiry and liquidation without externally supplied historical data.

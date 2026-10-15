# New-stack deposit-free close implementation

## Commitment and execution

Ordinary full/partial closes and protection close execution have a permanently zero keeper bounty. A user does not
need free settlement or additional USDC for that bounty. Carry, trading fees, VPI, frozen spread, partial-close
health, minimum size, oracle, timing and financial bounds remain binding. This is not a promise that every partial
reduction is healthy or that a close executes in one transaction.

Canonical commitment collects carry even when the bounty is zero, synchronizes borrowing and the terminal curve,
and records a real Active zero Order reservation. It does not reclassify pledge. Opening/increase bounties,
protection trigger rewards and liquidation rewards remain independent.

## Close lifecycle

Commit and execution remain two stages. FIFO and queued exposure rules still apply, including overlapping
close/open/close histories. There is no pledge-specific empty-queue rule or prepaid balance.

Success, recognized failure, expiry and liquidation settle the attempt's zero record exactly once. Normal close
receipts use None and all-zero bounty components with no recipient. Unknown/transient failures remain pending.
Protection trigger pays its separate reward once. A matching failed attempt settles its old record and latches
protection; permissionless retry creates a new zero record and deadline. Armed protection can be cancelled through
its existing owner-authorized action; triggered protection must execute/expire, and latched protection must retry.

## Reservation authority and recovery

Missing and zero reservations are different. Book and clearinghouse independently authenticate account, ID, kind,
Active state, entitlement and funding. Legacy pledge/source fields are zero. The retired ProtectionExecution
namespace cannot acquire a new record. Paid opening funds keep existing protected-floor and custody checks.

After strict expiry, exactly reconcilable independent opening funding may return to free settlement without a new
carry collection. Missing/settled/foreign records move no funds. Inconsistent identified backing is quarantined;
discrepancy receipts preserve evidence. No escrow/NAV mirror or source-position refund exists in the new stack.

## Abandoned zero-bounty orders: keeper responsibility

Operators service unpaid closes and cleanup from native-currency operating wallets. There is no new on-chain pool,
reimbursement distributor, or charge against LP loss backing. Replenishment comes from protocol-owned collected
revenue. A depleted operator wallet delays service; it is not an on-chain close-admission condition.

Read canonical head, nextCommit bound, status and immutable deadline. Empty initial head=nextCommit=1 is not a real
order. Simulate oracle-independent terminal cleanup separately before fetching live historical data, so an oracle
failure cannot undo completed cleanup. Expiry requires timestamp strictly greater than deadline and no oracle.
Live/FAD uses the admissible historical tick, never arbitrary latest data. Frozen follows its prescribed rules.
Confirm authenticated terminal results and bounded batch progress; a transaction success is not all-orders success.
Monitor Triggered and Latched protections until completion. Retain expiry-only automatic retry, queue arrival
budget and operator escalation for other reasons. Do not drop zero-reward heads or silently rewrite trader bounds.

The app's explicit native-gas fallback commits through the verified existing SimpleAccount owner route, without
sponsor or bundler. Execution/expiry of its existing ID is permissionless. Public RPC and independent Hermes provide
chain/oracle reads. Native gas and exact oracle value remain payable; preceding FIFO entries may need separate
execution/cleanup. Network or historical-data unavailability remains visible. Existing protection uses legitimate
cancel/retry paths. No owner-EOA direct commitment substitutes a different trader.

## ABI and consumer migration

Public request/config/receipt/protection tuples and enum ordinals remain stable; compatibility close execution
amounts and legacy pledge fields are zero. Internal Engine/Clearinghouse APIs and storage changed. This targets a
fresh coherent stack, not an in-place upgrade. SDK keeper builders, owner-account close wrapping, native fee quoting,
queue classification and verified terminal history accompany the app/keeper implementation.

## Deployment compatibility

Do not swap a Router into a live bound stack or reinterpret legacy paid reservations. Keep old-stack keepers and
archived decoders until its orders/protections drain or a separately reviewed migration completes. Current templates
use zero; historical manifests remain unchanged. Activation requires coherent new bindings, funded primary/standby
signers, measured spending/latency limits, and a same-account outage drill. No deployment or operating-wallet funding
is performed by this source change. See ZERO_CLOSE_OPERATIONS.md for commands and release gates.

# Historical implementation and measurements

The following sections are retained evidence from before the zero-close-bounty change. Their source revisions,
measurements and optimization proposals do not establish validation of the current source.

## Verification status and provenance

Focused tests use public funding/open/commit/execute calls. `DepositFreeClose.t.sol` labels deliberate entitlement corruption as synthetic. `PartialCloseHealth.t.sol` labels mathematical boundary fixtures as pure-plan simulations. Neither is represented as a historical fork replay.

Historical acceptance still requires the reservation-aware SHORT extra-$0.20 case, block 309041940's $0.002-free commitment, and block 309758933's 10,000-token zero-free reduction at raw price 98182413, with deployed runtime hashes and storage layouts checked. Public Arbitrum Sepolia RPC requests returned HTTP 403 during implementation; historical archive evidence must not be marked verified from local synthetic tests.

## Retained hardening and new work

PR #99's reservation-aware preview, protected-bounty accounting, canonical receipt lifecycle, and rollback isolation remain in effect. PR #100's archived sponsored-close ABI and old-stack bindings remain available for servicing and reconciliation. The old deployed preview is required for old planner tuples.

New work adds pledge-funded commitment, released-pledge charge funding, strict residual health with retained collateral, position epochs and provenance-aware recovery, oracle-independent expiry, authoritative committed assessment, and V3/V4 consumer schemas. No fee/carry schedule, VPI economic formula, liquidation-reserve top-up policy, or terminal shortfall allocation is changed.

## Storage and read optimization

The internal lifecycle record packs the two uint96 bounty-source amounts and uint64 source epoch into one slot. Carry and custody amounts retain uint256, including values above uint128. Pre-commitment custody is reconstructed exactly as post-commitment custody plus collected carry. Commitment validates that identity before accepting the record. Order identity remains in the router order; Book and clearinghouse independently record funding and epoch so neither record alone authorizes a refund.

Actual commitment loads only the relevant side and funding/health fields, while prospective previews retain the full execution snapshot. Both use the unchanged `CloseCommitmentLib` calculation. The pure planner's `planCloseCommit` returns only commitment effects; its unused projected-snapshot return was removed from the new ABI. Planner consumers must use the matching interface.

Both carry-side checkpoints share one pool-cash read because index updates do not move pool cash. Committed assessment also reuses its canonical pool-depth observation for carry cash; non-authoritative simulations still fetch actual pool cash independently from caller-supplied pricing depth. Reservation authentication, bounds, terminal conservation, and post-settlement checks remain in place.

The engine's fixed-shape sidecar call shares one buffer for its 100-byte input and 224-byte output. It checks the exact response length, bubbles revert bytes, and returns through Solidity so terminal/borrow synchronization and the reentrancy modifier's cleanup always run. Regression tests cover malformed return data, rollback, subsequent successful execution, full-width commitment round trips, and invalid reconstruction identities.

## Second optimization pass

The second pass made lifecycle bounds use a private 10-slot representation instead of 11 slots, and permanent outcomes use 11 slots instead of 13. The subsequent product simplification below supersedes that terminal representation. The compiler-confirmed layouts preserve every public field and accepted numeric domain, with explicit expansion into the existing ABI tuples. Receipt and request hashes remain unchanged, and the pending entitlement remains at slot offset 3. That pass alone moved no outcome fields exclusively to events.

`CfdEngineCollateralSnapshotLib` expands a single canonical clearinghouse isolation observation into the planner's account and locked-margin buckets. Execution and assessment add a separate protected-bounty read; commitment keeps execution-only output fields zero. This replaces six overlapping execution getters with two and four commitment getters with one. Parity tests retain the exact checked arithmetic and zero-floor behavior, including labeled synthetic corruption cases.

Normal execution reuses the configuration digest already read after oracle/mark updates while entering the authenticated Router item. Only static dependency reads and Router self-calls intervene before comparison. Pre-oracle cleanup and public committed assessment still validate configuration independently; cleanup without an observation reads a fresh digest. An oracle-callback regression verifies that a finalized configuration change cannot execute under the earlier policy.

`DirectCloseGas.t.sol` measures production Router request calls for full and partial closes at zero free settlement. Requests and oracle data are prepared outside the measured section; execution commitments run in fixture setup, and protocol access state is explicitly cooled. These figures complement the legacy-adapter comparison below. They measure call-level EVM gas before refunds and exclude intrinsic/calldata gas, L1 publication cost and oracle service fees.

## Single-plan execution evaluation

Single-plan execution remains a feasible subsequent architectural change; this pass retains independent Engine planning. The recommended boundary is an Engine-owned, `onlyRouter`/`nonReentrant` committed-close entrypoint that builds one canonical snapshot and plan, invokes an Engine-authenticated policy helper to validate that exact plan against the pending order and reservation, then applies the same delta and returns the fixed-shape assessment. Public committed assessment must retain its standalone authentication. Router post-state/bounty checks and clearinghouse settlement-source checks remain independent.

Do not turn an evaluator-returned delta into an authoritative ledger mutation. A combined entrypoint also needs exact failure-phase evidence (`priceReachedEngine`), malformed-return/typed-error decoding, gas-envelope changes, batch rollback coverage, and new interface exports. The Engine currently has only nine bytes under its existing repository runtime budget, so the refactor must demonstrate code extraction or other savings before adding entrypoint plumbing. These architectural changes are evaluated here, not implemented or included in the measured savings.

## Measured production costs

These historical measurements precede the current request-schema simplification. They describe the specified revisions; current costs require a fresh measurement using the final schema.

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
| Standard full execution | 1,479,917 | 1,416,433 | 4.29% |
| Standard partial execution | 1,527,599 | 1,464,115 | 4.16% |

The two tables use different fixtures and access conditions, so compare columns within a table. Direct figures exclude transaction refunds, intrinsic/calldata gas, L1 publication and oracle service fees. Each fixture also asserts successful lifecycle and accounting outcomes.

Engine runtime is **24,430 bytes**, below both EIP-170 (24,576) and the existing repository budget (24,439); the budget was not relaxed. Its settlement sidecar is **23,436 bytes**, down another 160 bytes. The lifecycle book grows by 56 bytes to 14,840; all deployment limits remain enforced. The release router's constructor-inclusive initcode is **47,159 bytes**; the settlement monitor's remains **49,057 bytes**, leaving 95 bytes below EIP-3860. Repeat compiler and size gates after every source change. Deployment simulation checks instantiated runtime sizes and the limiting constructor paths.


## Smaller terminal records and consumer migration

The measurements in this section describe the pre-timing implementation. Merging commitment-relative timing preserves
the two-slot summary and adds one packed terminal timing slot for the upstream `orderTiming` API. Requests now include
timing bounds, and full receipt events append authenticated timing. The gas measurements below
remain tied to their recorded source and must be repeated against the finalized release.

The compact terminal summary stores only account, terminal block, lifecycle status, terminal reason and receipt hash: **two slots instead of eleven**. Complete terminal receipt data remains in the `OrderFinalized` event. Finalization validates the same identity, bounds, entitlement, commitment and receipt semantics before persisting the summary and deleting pending state. Client-ID replay records remain permanent. No settlement, funding, protection or recovery policy is relaxed.

This is an intentional new-stack read-API change. `outcome(uint64)` is removed, so stale calls fail rather than returning fabricated zero details. Consumers use `terminalOutcome(uint64)` and fetch the Book's event by chain/Book/order identity or known execution transaction. On Arbitrum, `terminalBlock` retains Solidity's ancestor-chain `block.number` semantics and must not be used as the L2 RPC log block; see [Arbitrum documentation](https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/block-numbers-and-time). Record RPC block/hash separately for retrieval and reorg handling. The Book's `verifyReceipt(receipt, terminalTime)` hashes a supplied receipt using its stored block and its chain/Book/Router domain; it cannot retrieve missing event data. Validate the indexed order/account/client ID and event hash as well. Do not present an unavailable event as zero economics.

SDK version 0.2.0 exports `orderLifecycleV5Abi`, `hashOrderReceiptV4`, and `decodeVerifiedOrderFinalized`. The helper checks the emitter, indexed identity, summary fields and exact domain hash before returning full event history. Its summary must come from the trusted Book on the intended chain; apply finality/reorg policy before caching. Existing `orderLifecycleV4Abi` is archived unchanged for older candidates, and other historical bindings remain intact. Intent V3, receipt V4 and configuration V4 domains are unchanged; consumers must regenerate the current tuples together. V5 names the read API, not a new receipt hash domain.

The external app/keeper must migrate historical detail reads before new-stack activation. Index by chain, Book and order ID, retain full receipts and terminal times, and refetch on reorg. A smart contract that needs detailed history must receive the receipt and call `verifyReceipt`; it can no longer read those details by order ID alone. See the SDK README for the retrieval example. Existing position and old-stack servicing remain outside this migration.

### Measured terminal-record savings

Identical production fixtures at pre-simplification `23c19dfd` and source `f7e8714c`:

| Direct zero-free-USDC operation | Before | Two-slot terminal records | Change |
| --- | ---: | ---: | ---: |
| Standard full commitment | 1,409,016 | 1,409,281 | +265 (+0.019%) |
| Standard partial commitment | 1,430,352 | 1,430,617 | +265 (+0.019%) |
| Standard full execution | 1,416,433 | 1,235,575 | −180,858 (−12.77%) |
| Standard partial execution | 1,464,115 | 1,283,257 | −180,858 (−12.35%) |

Commitment cost is effectively unchanged. Savings occur when an order terminates and fewer permanent slots are written. These are gross call-level EVM measurements before refunds, with the same exclusions and cold-state fixtures described above, not complete Arbitrum fee quotes.

The separate legacy-adapter operation fixtures now measure commitment **951,851**, full execution **806,043**, and partial execution **1,010,548**. Relative to the preceding pass this saves 18.33% on full and 15.18% on partial execution. Relative to original pre-feature `8c555544`, execution is 16.18%/12.64% lower, while commitment remains 10.91% higher. Compare within each fixture family.

Compiler storage layout confirms `TerminalOutcome` is 64 bytes: account/block/status/reason at byte offsets 0/20/28/29 in slot 0, hash in slot 1. Engine runtime remains 24,430 bytes and settlement sidecar 23,436; the lifecycle Book is 14,723 bytes, 117 smaller. Full release-export and local deployment gates continue to enforce the original limits.

## Evaluation: commitment-history events (not implemented)

Current commitment storage occupies five slots: carry collected; carry outstanding; packed free/pledge bounty provenance; post-commitment custody; and post-commitment free settlement. The latter three historical amounts (outstanding carry and the two post-state balances) are candidates for moving to an event. Collected carry still participates in gross/action bounds, and live bounty entitlement/provenance must remain authenticated. This is different from terminal summaries: these fields are read while the order remains pending and copied into assessed/final receipts.

A conservative design would retain collected carry and the packed bounty provenance, replace the three historical slots with a hash, and emit the complete commitment effects. That removes **two net slots**, not three. The hash preserves authority only if the original data can be supplied and verified; it does not let existing assessment or execution entrypoints reconstruct it. To retain current interfaces and complete receipts, a keeper would need to supply the preimage on execution, expiry, liquidation and protection cleanup, or the receipt schema would need to reference commitment history instead of copying it. Requiring historical preimages for permissionless cleanup would create a new availability dependency and is unsuitable for the deposit-free exit goal.

A cleaner product alternative would keep only live carry/provenance state and make terminal receipts reference an authenticated commitment event. Assessment and receipt clients would join two events; historical commitment balances would cease to be directly queryable while pending. This could remove three slots before adding any required commitment digest, but changes the public pending, assessment and receipt schemas and needs a fresh authority design. It must never weaken commitment carry bounds or refund provenance. No gas percentage is claimed without an implementation and identical-fixture measurement.

**Recommendation:** keep commitment history unchanged in this implementation. The terminal simplification captures permanent-write savings with the existing full receipt event. Revisit commitment events only when the external app/keeper can accept a coordinated schema change and event-history retrieval is proven in operation; preserve oracle-independent expiry and liquidation without externally supplied historical data.

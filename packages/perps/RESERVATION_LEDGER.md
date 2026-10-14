# Clearinghouse reservation ownership

`MarginClearinghouse` owns reservation amounts and their accounting indexes. The Router owns pending-order
lifecycle and global/account execution queues. `PositionProtectionBook` owns protection lifecycle, attempt linkage,
and each protection's immutable execution-bounty snapshot used to authenticate retries. Neither lifecycle owner stores a mutable bounty
balance or committed-margin queue.

## Committed margin

Each clearinghouse order reservation holds its amount, terminal status, and previous/next active reservation ids.
Each account has a packed head/tail/count plus its existing amount aggregate. Creation appends to that account's FIFO;
full consumption or release unlinks immediately, including when settlement consumes a queued order's
margin before that order executes. Partial consumption keeps its position. Zero is the list sentinel and cannot be a
reservation id. Records remain as terminal receipts and cannot be reused.

The Router's `getMarginReservationIds`, `marginHeadOrderId`, and `marginTailOrderId` forward to this canonical queue.
They exclude exhausted records immediately. There is no `syncMarginQueue` operation. Execution FIFO and the existing
32 pending orders per account cap remain Router responsibilities.

## Bounty records

A record is keyed by `(BountyKind, id)` and contains its account, unpaid amount, lifecycle state, original free/pledge
funding and source position epoch. Numeric ids may overlap across
namespaces. `totalBountyReservationsUsdc(account)` sums all three namespaces and is updated with each creation or
take. A transfer changes attribution without changing this total.

| Transition | Caller | Canonical change | Funding/custody |
| --- | --- | --- | --- |
| Ordinary order commit | Router | Create `Order(orderId)` | Existing reserve lock occurs first |
| Protection creation or attachment | Protection book | Create `ProtectionTrigger(id)` and `ProtectionExecution(id)` | Existing reserve lock occurs first |
| Protection trigger | Protection book | Take trigger record; move execution record to `Order(attemptId)` | Existing trigger credit; execution reserve stays locked |
| Retained failed attempt | Protection book | Move `Order(attemptId)` back to `ProtectionExecution(id)` | No unlock, relock, or custody change |
| Retry | Protection book | Move execution record to the fresh `Order(attemptId)` | No additional funding |
| Successful order payout | Router | Take authenticated order record | Pay/release full bounty; successful ordinary close consumes only its own collectible eligibility |
| Ordinary close failure or expiry | Router through Engine | Take authenticated original split | Restore pledged part to source position, then pay/release free-funded part |
| Liquidation order cleanup | Router through Engine | Take authenticated original split inside isolated liquidation frame | Restore pledged part before health/loss assessment; forfeit only free-funded part |
| Risk-off open cleanup | Router | Take exact free-funded order record | Refund internally, no cleaner payment or carry checkpoint |
| Protection refund or forfeiture | Protection book | Take remaining protection records | Existing settlement path completes atomically |

Only the Router may create/take ordinary order records; only its immutable protection book may create/take
protection records. The book alone can transfer between `Order` and `ProtectionExecution`, after authenticating the
attempt relationship. Transfers reject cross-account attribution, live destinations, other namespace pairs, and
reuse of any previous order record. A consumed protection-execution record may receive its own retry reserve again.

Creation of a nonzero bounty requires existing reserved-settlement backing for the new amount plus all existing
bounties and the VPI floor. A configured zero-bounty ordinary close still creates an explicit active record so its
funding identity can be authenticated. A take returns the full classified amount and zeroes it; exact lifecycle and
owner checks prevent another payment or re-creation under a used id. A known record cannot be taken for another account.

The lifecycle Book independently records the original funding split and source epoch. An ordinary close may use
pledge only when its account queue is empty; later fully free-funded peers remain legal. One Clearinghouse collectible
escrow mirror binds the pledge amount to that pending head and its live source epoch. Reservation decreases physical
pledge and increases this mirror within the Engine's authenticated curve frame, preserving the marked cap while
keeping the bounty locked. The mirror is not extra custody, borrow collateral or an additional protected-reserve floor.

## Atomicity and accounting

Classification is distinct from custody. `recordBountyReservation` classifies funds already locked by the authorized
funding path. `takeBountyReservation` removes that classification before the existing payout, refund, or forfeiture.
These trusted callers must complete both operations in one transaction. Neither record operation nor transfer
checkpoints carry; the existing funding and settlement paths retain their carry timing. Any later failure rolls back
records, lifecycle, and funds together. Removing bounty classification alone does not remove collectible escrow.
Pledged refund checkpoints old-basis carry without collecting it before restoring margin; success consumes eligibility
inside the close mutation. Liquidation restores pledge before authoritative health/loss assessment. Restored solvency
rolls back its inner frame, retaining the pledged order while preserving valid preceding outer risk-off refunds.

Expired discrepancies must reconcile exact Book-backed funding and live source ownership before any refund. Stale
pledge never becomes free settlement or a later generation's collateral. Otherwise identifiable backing remains
locked in quarantine and only matching collectible eligibility is removed inside an Engine curve frame. Failure to
authenticate that boundary fails closed; no administrator can guess or rewrite a disputed owner.

Generic action-reserve consumption protects `VPI reserve + totalBountyReservationsUsdc(account)` using only local
clearinghouse accounting. No Router queue scan or accounting callback supplies that floor. Engine and lens snapshots
read the same aggregate. Router account views combine it with Router-owned pending counts and clearinghouse margin
summaries in constant work. Protection views project the canonical bounty records into their existing public shape.

The first trigger transfers the bounty before queuing its close attempt. The retry callback queues the fresh attempt
before the book transfers its bounty. Both retain the old lifecycle ordering: the same funds remain protected in
one namespace throughout the handoff. Contract identity reads used for authorization remain in place.

## Compatibility

This release changes clearinghouse, Router, and protection-book storage layouts. `getOrderReservation` returns a
reordered tuple with previous/next links, and the obsolete Router `syncMarginQueue(address)` entrypoint is removed.
New clearinghouse bounty entrypoints, getters, and `BountyReservationUpdated` events expose canonical accounting.
Existing trader order/protection input and view shapes remain unchanged; margin queue views now contain only active
records. Rebuild clients that consume the internal accounting interface and do not reuse old raw-storage decoders.

The source-bound close extension also changes internal Engine/Book interfaces and Clearinghouse/Book storage. Public
request/receipt field layouts and their existing hash domains stay stable; `PaidAndRefunded=5` and
`ForfeitedAndRefunded=6` append mixed dispositions. Its new failed-close payout policy and refundable-escrow marked cap
are specified in [Close-order bounty policy](ACCOUNTING_SPEC.md#close-order-bounty-policy). Deploy a matching fresh
stack together; there is no Router-only hot swap or live-state migration. See [Deployment](DEPLOYMENT.md) for cutover
constraints.

## Stateful conservation test

`test/perps/invariant/properties/ProtectionBountyStateMachine.t.sol` maintains a separate ledger of funded, unpaid, paid,
refunded, and forfeited bounty value. Expected amounts come from fixed configured bounties and successful actions;
protocol return values supply record identities. Every step compares all current and historical records, account
totals, reserve backing, keeper credits, and protection/order/position lifecycle against that model.

Each fuzz case first exercises cross-account namespace collisions, cancellation of armed and pending-open protection,
parent execution and expiry, repeated retained retries, successful close payout, risk-off refunds, and liquidation of
armed, triggered, and latched protection. A forced transfer failure checks atomic rollback. It then mixes 32 actions
across three accounts and drains every remaining bounty. Unexpected action reverts fail the case. Carry and VPI are
zero in this focused fixture; their interactions remain covered by the package's separate accounting tests.

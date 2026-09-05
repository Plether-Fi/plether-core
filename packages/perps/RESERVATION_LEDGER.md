# Clearinghouse reservation ownership

`MarginClearinghouse` owns reservation amounts and their accounting indexes. The Router owns pending-order
lifecycle and global/account execution queues. `PositionProtectionBook` owns protection lifecycle, attempt linkage,
and the immutable configured bounty used to authenticate retries. Neither lifecycle owner stores a mutable bounty
balance or committed-margin queue.

## Committed margin

Each clearinghouse order reservation holds its amount, terminal status, and previous/next active reservation ids.
Each account has a packed head/tail/count plus its existing amount aggregate. Creation appends to that account's FIFO;
full consumption, promotion, or release unlinks immediately, including when settlement consumes a queued order's
margin before that order executes. Partial consumption keeps its position. Zero is the list sentinel and cannot be a
reservation id. Records remain as terminal receipts and cannot be reused.

The Router's `getMarginReservationIds`, `marginHeadOrderId`, and `marginTailOrderId` forward to this canonical queue.
They exclude exhausted records immediately. There is no `syncMarginQueue` operation. Execution FIFO and the existing
32 pending orders per account cap remain Router responsibilities.

## Bounty records

A record is keyed by `(BountyKind, id)` and contains its account and unpaid amount. Numeric ids may overlap across
namespaces. `totalBountyReservationsUsdc(account)` sums all three namespaces and is updated with each creation or
take. A transfer changes attribution without changing this total.

| Transition | Caller | Canonical change | Funding/custody |
| --- | --- | --- | --- |
| Ordinary order commit | Router | Create `Order(orderId)` | Existing reserve lock occurs first |
| Protection creation or attachment | Protection book | Create `ProtectionTrigger(id)` and `ProtectionExecution(id)` | Existing reserve lock occurs first |
| Protection trigger | Protection book | Take trigger record; move execution record to `Order(attemptId)` | Existing trigger credit; execution reserve stays locked |
| Retained failed attempt | Protection book | Move `Order(attemptId)` back to `ProtectionExecution(id)` | No unlock, relock, or custody change |
| Retry | Protection book | Move execution record to the fresh `Order(attemptId)` | No additional funding |
| Order payout, refund, risk-off release, or forfeiture | Router | Take exact order record | Existing settlement path completes atomically |
| Protection refund or forfeiture | Protection book | Take remaining protection records | Existing settlement path completes atomically |

Only the Router may create/take ordinary order records; only its immutable protection book may create/take
protection records. The book alone can transfer between `Order` and `ProtectionExecution`, after authenticating the
attempt relationship. Transfers reject cross-account attribution, live destinations, other namespace pairs, and
reuse of any previous order record. A consumed protection-execution record may receive its own retry reserve again.

Creation requires existing reserved-settlement backing for the new amount plus all existing bounties and the VPI
floor. A take returns the full classified amount and zeroes it; taking the same record again returns zero. The retained
account prevents re-creation under an already used id. A known record cannot be taken for another account.

## Atomicity and accounting

Classification is distinct from custody. `recordBountyReservation` classifies funds already locked by the authorized
funding path. `takeBountyReservation` removes that classification before the existing payout, refund, or forfeiture.
These trusted callers must complete both operations in one transaction. Neither record operation nor transfer
checkpoints carry; the existing funding and settlement paths retain their carry timing. Any later failure rolls back
records, lifecycle, and funds together.

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

Deploy a matching stack together. No live-state migration, deployment-boundary consolidation, pricing change,
waterfall change, or new payout policy is included. See [Deployment](DEPLOYMENT.md) for cutover constraints.

## Stateful conservation test

`test/perps/invariant/ProtectionBountyStateMachine.t.sol` maintains a separate ledger of funded, unpaid, paid,
refunded, and forfeited bounty value. Expected amounts come from fixed configured bounties and successful actions;
protocol return values supply record identities. Every step compares all current and historical records, account
totals, reserve backing, keeper credits, and protection/order/position lifecycle against that model.

Each fuzz case first exercises cross-account namespace collisions, cancellation of armed and pending-open protection,
parent execution and expiry, repeated retained retries, successful close payout, risk-off refunds, and liquidation of
armed, triggered, and latched protection. A forced transfer failure checks atomic rollback. It then mixes 32 actions
across three accounts and drains every remaining bounty. Unexpected action reverts fail the case. Carry and VPI are
zero in this focused fixture; their interactions remain covered by the package's separate accounting tests.

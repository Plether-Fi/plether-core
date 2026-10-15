# Clearinghouse reservation ownership

`MarginClearinghouse` owns reservation amounts and their accounting indexes. The Router owns pending-order
lifecycle and global/account execution queues. `PositionProtectionBook` owns protection lifecycle, attempt linkage,
and the trigger-bounty snapshot. Neither lifecycle owner stores a mutable bounty balance or committed-margin queue.

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

A record is keyed by `(BountyKind, id)` and contains its account, amount, and lifecycle state. Numeric ids may overlap
between `Order` and `ProtectionTrigger`. New records are wholly free-funded or zero: `pledgeFundedUsdc` and
`sourcePositionEpoch` remain zero. `ProtectionExecution` is a retired namespace and rejects new reservations.
`totalBountyReservationsUsdc(account)` sums active nonzero records and changes on creation or take.

| Transition | Caller | Canonical change | Funding/custody |
| --- | --- | --- | --- |
| Opening/increase commit | Router | Create nonzero `Order(orderId)` | Reserve free settlement first |
| Ordinary close commit | Router | Create Active zero `Order(orderId)` | No monetary reserve or pledge reclassification |
| Protection creation or attachment | Protection book | Create `ProtectionTrigger(id)` | Reserve trigger reward from free settlement only |
| Protection trigger | Protection book and Router | Take and pay trigger record once; create Active zero `Order(attemptId)` | No linked-close execution reward |
| Matching failed close attempt | Router and protection book | Settle zero Order record; move `Triggered -> Latched` | No cleaner payment or retained execution funds |
| Protection retry | Protection book and Router | Create a fresh Active zero `Order(attemptId)` | No new trader debit or second trigger payout |
| Successful/failed ordinary close | Router | Settle authenticated zero Order record | No bounty recipient or cash movement |
| Liquidation order cleanup | Router | Settle each Order record inside isolated liquidation frame | Unpaid opening bounty may be forfeited; close amount is zero |
| Risk-off open cleanup | Router | Take exact opening Order record | Refund internally, no cleaner payment or carry checkpoint |
| Untriggered protection refund/forfeiture | Protection book | Take remaining trigger record | Existing trigger settlement path completes atomically |

Only the Router may create/take Order records; only its immutable protection book may create/take
`ProtectionTrigger` records. Creation of a nonzero bounty requires existing reserved-settlement backing for the new
amount plus all existing bounties and the VPI floor. A zero-bounty close still creates an explicit Active record so
its funding identity can be authenticated. A take returns the classified amount and settles the record; exact
lifecycle and owner checks prevent another payment or re-creation under a used id.

The lifecycle Book independently authenticates the original funding fields. For a close, entitlement, free funding,
pledge funding, and source epoch are all zero. There is no pledge-specific empty-queue rule or collectible escrow
mirror. FIFO, account pending limits, queued exposure, carry, and risk admission still apply.

## Atomicity and accounting

Classification is distinct from custody. `recordBountyReservation` classifies value already locked by an authorized
opening or trigger funding path, or records an Active zero close without locking funds. `takeBountyReservation` settles
that classification before the payout, refund, or forfeiture. Trusted callers complete both steps atomically; a later
failure rolls back records, lifecycle, and funds together. Record creation and take do not themselves checkpoint carry.
Close commitment independently collects applicable carry even though its bounty is zero.

Expired discrepancies must reconcile exact Book-backed opening funding before any refund. Missing, settled, or
foreign records do not authorize a refund. Identifiable inconsistent backing remains locked in quarantine; the
zero close record still requires matching account, kind, id, and Active state. No administrator can guess or rewrite
a disputed owner.

Generic action-reserve consumption protects `VPI reserve + totalBountyReservationsUsdc(account)` using only local
clearinghouse accounting. No Router queue scan or accounting callback supplies that floor. Engine and lens snapshots
read the same aggregate. Router account views combine it with Router-owned pending counts and clearinghouse margin
summaries in constant work. Protection views project the canonical bounty records into their existing public shape.

The first trigger settles its separate reward before queuing a zero-bounty close attempt. A retry queues a fresh
zero-bounty attempt without transferring value between namespaces or paying the trigger again. Contract identity
reads used for authorization remain in place.

## Compatibility

This release changes clearinghouse, Router, and protection-book storage layouts. `getOrderReservation` returns a
reordered tuple with previous/next links, and the obsolete Router `syncMarginQueue(address)` entrypoint is removed.
New clearinghouse bounty entrypoints, getters, and `BountyReservationUpdated` events expose canonical accounting.
Existing trader order/protection input and view shapes remain unchanged; margin queue views now contain only active
records. Rebuild clients that consume the internal accounting interface and do not reuse old raw-storage decoders.

The current zero-close implementation removes the source-bound pledged-close escrow and its internal mutation paths.
Public request/receipt compatibility fields and historical disposition ordinals remain decodable; normal close
receipts use `None` with zero amounts. See [Close-order bounty policy](ACCOUNTING_SPEC.md#close-order-bounty-policy).
Deploy a matching fresh stack together; there is no Router-only hot swap or live-state migration. See
[Deployment](DEPLOYMENT.md) for cutover constraints.

## Stateful conservation test

`test/perps/invariant/properties/ProtectionBountyStateMachine.t.sol` maintains a separate ledger of funded, unpaid, paid,
refunded, and forfeited bounty value. Expected amounts come from fixed configured bounties and successful actions;
protocol return values supply record identities. Every step compares all current and historical records, account
totals, reserve backing, keeper credits, and protection/order/position lifecycle against that model.

Each fuzz case first exercises cross-account namespace collisions, cancellation of armed and pending-open protection,
parent execution and expiry, repeated zero-bounty retries, successful close settlement, risk-off refunds, and liquidation of
armed, triggered, and latched protection. A forced transfer failure checks atomic rollback. It then mixes 32 actions
across three accounts and drains every remaining bounty. Unexpected action reverts fail the case. Carry and VPI are
zero in this focused fixture; their interactions remain covered by the package's separate accounting tests.

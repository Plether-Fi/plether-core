# V3 commitment-relative execution timing

This source release requires a fresh protocol graph. It does not deploy contracts, publish packages, alter historical
release bundles, or migrate existing orders. V2 requests and signatures are not accepted by the V3 interface.

`OrderV3Types.ExecutionBounds` replaces `validUntil` with `uint64 submitBy` and `uint32 executionWindowSeconds`.
All economic fields retain their existing meaning. Clients default to a fresh reviewed block timestamp plus 120 seconds
for submission and a 60-second execution duration. Fresh commitments accept equality at `submitBy`; the execution
window must be positive and no greater than the configured `maxExecutionWindowSeconds` (default 60, governance cap
one hour). Configuration finalization retains the existing pinned-config invalidation behavior.

The lifecycle Book atomically stores an `OrderTiming` tuple in this exact order:
`(uint64 submitBy,uint32 executionWindowSeconds,uint64 commitTimestamp,uint64 executionDeadline)`.
The resolved deadline is commitment time plus the requested duration. `orderTiming(orderId)` returns that tuple for
both pending and terminal orders, or zeros for an unknown order. `IntentRegistered` appends the timing tuple after the
request. Pending intents, full receipts and compact outcomes append `timing`; the Book authenticates receipt timing
against its pending record. The intent domain is V3; receipt and execution-config domains are V4.

Execution, single-head cleanup and batch preparation compare chain time with the stored deadline, expiring strictly
after it. Exact replay remains unconditional and side-effect-free, including after expiry. Changing either timing
field changes the intent hash and conflicts with an already used client id. Protected opens use the same request;
protocol-generated protection close attempts start their own clocks with the current configured duration.

Commitment rechecks admission, configuration, queued position constraints and applicable reservation bounds.
Execution rechecks the full financial policy, allowed mode and slippage. This change does not add an execution-price
preview to commitment or extend the unique historical oracle settlement window. First eligible prices remain anchored
to the actual commitment time, and FIFO/MEV constraints are unchanged.

Sponsorship must expire no later than `submitBy`. The paymaster calldata hash already signs both fields, so its wire
format is unchanged. Once committed, execution never depends on sponsorship validity or another client signature.
Recovery must distinguish submission authorization expiry from a committed order's resolved deadline, using canonical
chain evidence before releasing an ambiguous signed operation. Local elapsed time is insufficient.

Before activation, export fresh schema-3 release artifacts with `orderInterfaceVersion: 3`, verify all reciprocal
bindings and runtime hashes, and configure the app, API, history indexer and workers together. The sponsored-close
preview now takes its permitted engine as a constructor argument instead of a historical deployment constant.

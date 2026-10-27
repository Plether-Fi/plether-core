# Canonical Perps Entrypoints

Use this guide to choose the public contract for each integration. The linked interfaces and release-generated ABIs
are the source of exact tuple layouts; internal host callbacks and sidecar selectors are not user entrypoints.

| Task | Contract |
| --- | --- |
| Deposit or withdraw trader cash | `MarginClearinghouse` |
| Add isolated position margin or settle a trader claim | `CfdEngine` |
| Commit and execute orders | `OrderRouter` |
| Create, manage or trigger TP/SL protection | `PositionProtectionBook` |
| Resolve order identity and authenticate outcomes | `OrderLifecycleBook` |
| Request/claim LP deposits and redemptions | Senior or Junior `TrancheVault` |
| Read compact product state | `PerpsPublicLens` |
| Choose and preflight LP settlement | `SettlementMonitorLens`, then the selected Pool/Router route |

USDG asset amounts use 6 decimals, LP shares use 9 decimals, prices use 8 decimals, and position sizes use 18 decimals
in multiples of `CfdTypes.SIZE_QUANTUM` (`1e20`, or 100 position units). `LONG` profits when the basket mark falls; `SHORT` profits
when it rises. See [README](README.md) before interpreting direction or slippage.

For review priorities, failure policy and settlement walkthroughs, use the [security review guide](SECURITY.md#review-guide).

For autonomous trading-account and AI-agent integration, including bounded authority and receipt verification, use
[`WORKING_WITH_AI_AGENTS.md`](WORKING_WITH_AI_AGENTS.md) alongside this file.

## Traders

### Funding and orders

- Owner margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`.
  Approve the Clearinghouse to pull USDG before depositing. A deposit credits custody and checkpoints carry; it does
  not automatically add isolated position margin. Withdrawal applies carry and safety checks as well as reserve locks.
- Add isolated margin without increasing size: `CfdEngine.addMargin(address account,uint256 amount)`; caller must be
  the account owner, have an open position and sufficient free settlement after carry collection.
- Credit-only funding: `MarginClearinghouse.depositFor(address,uint256)` pulls the payer's exact USDG amount and
  credits the beneficiary's free settlement without a carry checkpoint or position-margin allocation. Funding gives
  the payer no authority over the beneficiary. `DepositFor` is payer metadata for the same credit recorded by
  `Deposit`; indexers must not count both. See [`BRIDGE_FUNDING.md`](BRIDGE_FUNDING.md) for the Across
  destination-call integration and provider/deployment requirements.
- Ordinary trade action: `OrderRouter.commitOrder(OrderV3Types.OrderRequest request)`
- Fresh external V3 requests must set `expectedConfigHash` to the current nonzero value returned by
  `OrderLifecycleBook.currentExecutionConfigHash()`; the public commit path rejects zero for a new intent.
- Emergency policy note: committed orders remain user-uncancellable. If RouterAdmin enters risk-off, each pre-cutoff
  open is instead terminally invalidated by protocol policy and its remaining reservations are refunded to the
  trader's internal clearinghouse balance.
- Requests include a nonzero client id and target, explicit financial bounds, `submitBy` and
  `executionWindowSeconds`. A close has zero `marginDelta` and zero execution bounty. Fresh requests require nonzero
  `maxPostLeverageBps` even when full-close post-position checks will be skipped. See
  [Order timing](#order-timing) and [Trading-agent integration](WORKING_WITH_AI_AGENTS.md) for field-level rules.
- A positive `minPostSettlementBalanceAssets` is supported only for an opening order on a flat account with no pending
  orders. It protects total internal settlement custody, including locked value. It is not a general close or
  withdrawable-balance floor; closes and increases must set it to zero.
- Trader claim settlement: `CfdEngine.settleTraderClaim(address account)` for the account owner. Payment is
  all-or-nothing and requires Pool cash to cover all outstanding trader claims. An open position receives the payment
  as PnL pledge; otherwise it becomes free settlement.

### Order timing

Every ordinary request supplies two clocks in [`OrderV3Types.ExecutionBounds`](src/OrderV3Types.sol): a deadline to
submit, then an execution duration measured from commitment.

| Field | Meaning | Boundary |
| --- | --- | --- |
| `uint64 submitBy` | Latest chain timestamp for fresh commitment | Equality is allowed. |
| `uint32 executionWindowSeconds` | Duration after successful commitment | Positive and at most `maxExecutionWindowSeconds` (default 60 seconds; governance maximum one hour). |
| `commitTimestamp` | Timestamp of successful commitment | Recorded by the lifecycle Book. |
| `executionDeadline` | `commitTimestamp + executionWindowSeconds` | Expiry is strictly after this timestamp; equality remains eligible. |

A request with `submitBy = 12:02:00` and a 60-second duration committed at `12:01:30` expires after `12:02:30`.
The submission cutoff no longer controls a committed order. FIFO, oracle, MEV, gas and financial checks still apply.
Extending execution duration does not extend the Oracle's separate post-commit `orderSettlementWindow`; the signed
historical price must qualify in that window even if execution happens later. Frozen execution follows the
[stored-mark policy](ORACLE_SYNCHRONIZATION.md#frozen-operation).

Expiry makes an order eligible for cleanup; it does not automatically release reservations. `expireOrder` and
`clearInvalidOrders` provide oracle-free cleanup, and ordinary execution checks expiry before oracle work. See
[Keepers](#keepers) for eligibility and result handling.

`OrderLifecycleBook.orderTiming(orderId)` retains this tuple for pending and terminal orders, and returns zeros for
unknown ids:

```text
(uint64 submitBy, uint32 executionWindowSeconds, uint64 commitTimestamp, uint64 executionDeadline)
```

`IntentRegistered`, pending intents and full receipts include timing; receipt verification authenticates it against
the committed record. Exact `commitOrder` replay with the same account, client id and request returns the original
id without new reservations, including after expiry. Changing either timing field changes the intent hash and
conflicts with a used client id. Resolve ambiguous submissions through `clientIntent(account, clientOrderId)`.
Composite protection actions have their own lifecycle checks and are not unconditional `commitOrder` replay.

Protected parent opens use the same request timing. Each generated protection close/retry gets a fresh commit time
and the then-configured execution duration. Clients choose submission headroom for their transaction path; the
protocol imposes no 120-second default. Sponsored-operation validity controls submission separately and must not be
mistaken for execution validity. Once committed, execution needs no new trader signature; recover ambiguous
operations from chain evidence rather than a local countdown. See [Trading-agent integration](WORKING_WITH_AI_AGENTS.md).

### Closing and reducing positions

Submit an ordinary close through `commitOrder` with the current side, lot-aligned reduction size, zero `marginDelta`
and explicit price/financial limits. Closing reserves no execution bounty. Ordinary commitment still collects
applicable carry and records it in the lifecycle Book; execution later settles price PnL and action charges.
Collected commitment carry is already included in the reported debit/charge totals. Native gas and oracle fees remain
payable by the transaction sender.

A full close removes the position and follows terminal collection/waiver rules. A partial close must preserve a
healthy residual position, satisfy the partial-size minimum and fund the required charges; it can fail even with no
keeper bounty. Trader claims may support price equity but are not cash for action charges. Use
[Close preview](CLOSE_PREVIEW.md) to review the exact request, then simulate commitment and authenticate the eventual
receipt. The detailed cash ordering is in [Close settlement](ACCOUNTING_SPEC.md#close-settlement).

Active protection has its own owner-exit and permissionless retry paths below. A trigger or retry queues a new close
without ordinary commitment carry effects; its execution still settles carry. A paid trigger, accepted commitment or
successful cleanup transaction does not by itself establish that the position closed.

### Position protection

- Discover the immutable protection action/view surface through `OrderRouter.positionProtectionBook()`.
- Open with staged protection: `PositionProtectionBook.commitOpenOrderWithProtection(OrderV3Types.OrderRequest,PositionProtectionParams)`
- Existing-position protection: `PositionProtectionBook.createPositionProtection(PositionProtectionParams)`
- A protection request must explicitly supply `PositionProtectionParams.closeLimits` with four close financial limits:
  `maxExecutionNotionalAssets`, `maxGrossAccountDebitAssets`, `maxActionChargeAssets`, and `maxExplicitFeesAssets`. Each is a
  `uint256` ceiling in 6-decimal USDG units for future triggered or retried close attempts. Set the limits from the trader's intended
  close policy; integrations must not assume an implicit unlimited default. Zero is a zero allowance;
  `type(uint256).max` is an explicit unlimited allowance. The separately reserved trigger bounty is paid when the
  protection fires; these ceilings apply to its generated close attempt.
- Existing-position protection creation is available in degraded mode; Router pause and frozen-oracle restrictions still apply.
  Creation locks its trigger bounty first, then applies the exact-price safety gate through the Engine's configured
  planner. Price equity is PnL pledge plus same-account claim plus exact capped price PnL computed from entry cost;
  free settlement and generic action/reservation buckets do not count as price collateral. Uncovered carry, an underfunded
  negative-VPI reserve, or equity at or below the stricter of initial and active normal/FAD margin rejects the action.
- Protection management: replace a `PendingOpen` or `Armed` record with
  `PositionProtectionBook.replacePositionProtection(uint64,PositionProtectionParams)` to update its triggers and close
  limits, or detach/cancel a `PendingOpen`/`Armed` record with
  `PositionProtectionBook.cancelPositionProtection(uint64)`
- Atomic owner exit: `PositionProtectionBook.cancelPositionProtectionAndCommitClose(uint64,OrderV3Types.OrderRequest)`
  cancels only an `Armed` protection and queues a fresh ordinary full close matching its current side and size.
  Commitment failure rolls back cancellation and the trigger-bounty refund. It is available in live and frozen
  markets; supply the current nonzero config hash, explicit financial bounds, target, and allowed execution modes.
  Successful commitment permanently cancels protection; subsequent close failure or expiry does not restore it.
  Recover the order id by client-intent lookup rather than replaying this composite action.
- Once a trigger is recorded, neither the owner nor a keeper may replace or cancel it. `Triggered` means one live close
  attempt; `Latched` means the irreversible trigger remains active with no live attempt and may be retried
  permissionlessly.
- The owner may amend the close ceilings of a `Latched` protection with
  `PositionProtectionBook.amendLatchedPositionProtectionCloseLimits(uint64,CloseFinancialLimits)` when the account has
  no pending Router order. This changes the limits used for a future retry; it does not replace or cancel the latched
  trigger. `PositionProtectionCloseLimitsUpdated` records each creation, replacement, or amendment of these limits.
- Only Router-authenticated TP/SL-triggered close attempts use `expectedConfigHash == bytes32(0)` as an internal
  unpinned marker. Protected parent opens and ordinary `OrderRouter.commitOrder(...)` requests require the current
  nonzero configuration hash.

### Trader reads and previews

- Compact account and order reads: `PerpsPublicLens` via `IPerpsTraderViews`. Gross settlement balance includes locked
  buckets; use the account's explicit free/withdrawable views and simulate a withdrawal before presenting availability.
- Protection reads: `PositionProtectionBook.activePositionProtectionId(address)` and
  `PositionProtectionBook.getPositionProtection(uint64)`. Read the retained close ceilings with
  `PositionProtectionBook.closeFinancialLimits(uint64)`.
- Open-ticket planning: `CfdEngineLens.previewOpen(...)` and `CfdEngineLens.quoteMaxOpen(...)`; these exclude Router
  admission, bounty-reservation, and oracle-validation checks.
- Pre-commit close review: `CfdClosePreview.previewClose(...)`, which projects commitment carry and the new order's
  zero-bounty commitment before assessing execution. See the current [close-order bounty policy](ACCOUNTING_SPEC.md#close-order-bounty-policy). Continue to
  simulate the actual Router commitment for queue, deadline, configuration, and other admission checks.

Use these interfaces:

- `IMarginAccount`
- `IPerpsTraderActions`
- `IPositionProtectionActions`
- `IPositionProtectionViews`
- `IPerpsTraderViews`
- `ICfdEngineLens` for open-ticket previews and maximum-open quotes
- The deployed `CfdClosePreview` ABI for pre-commit close review

Do not use the wide clearinghouse reservation API or detailed accounting lenses as the canonical trader integration
surface. `CfdEngineLens.previewClose(...)` remains a planner diagnostic; it does not project a new close commitment's
carry and the associated commitment effects.

### Across destination funding

Use `depositFor` as the destination credit operation and verify the confirmed Clearinghouse deposit before treating
funds as trading collateral. A fallback transfer to a wallet still needs a deposit. The complete call ordering,
beneficiary checks, allowance cleanup and fixture limitations are in [Bridge funding](BRIDGE_FUNDING.md).

## LPs

- Senior and Junior entry is asynchronous through the configured `TrancheVault`: request assets with
  `requestDeposit(assets, controller, owner)`, inspect pending/claimable state, and use ERC-4626 `deposit` or `mint`
  only to claim an activated request.
- LP exits are asynchronous. A holder calls `requestRedeem(shares, controller, owner)`; funded requests are exposed by
  `pendingRedeemRequest` / `claimableRedeemRequest` and claimed through ERC-4626 `redeem` or `withdraw`.
- An activated, unclaimed deposit can route shares directly into redemption through
  `requestRedeemFromClaimableDeposit(depositRequestId,shares,controller)`. Read
  `maxRequestRedeemFromClaimableDeposit(depositRequestId,controller)` first. The controller or its approved operator
  must call, the source lot's activation-aged cooldown must have elapsed, and the redemption keeps the same controller.
- Canonical request timing: call `TrancheVault.getRequestEpochWindow()` for
  `(nextRequestEpoch, nextRequestCutoffTime)`. `PerpsPublicLens.getTrancheQueues(bool)` relays the same pair in
  `TrancheQueueView`; Senior and Junior values must match at the same block. `nextRequestCutoffTime` is always the next
  future timestamp at which the advertised target changes. Derive the final-five-minute state as
  `nextRequestEpoch > currentEpoch + 1`; do not persist a boolean across the round-hour boundary. The existing
  `cutoffEpoch` field remains the latest epoch eligible for settlement now and is not the request cutoff.
- Read `lpEpochSettlementPaused` from the public LP, tranche-queue, or protocol status view before presenting
  settlement liveness. While true, `TrancheView.depositEnabled` can remain true even though activation and new
  redemption funding are stopped. Existing cancellation rules and funded claims are unchanged.
- Every Senior/Junior deposit/redemption uses the same rule: with `e = floor(block.timestamp / 3,600)` and
  `b = (e + 1) * 3,600`, target `e + 1` before `b - 300` and `e + 2` at or after `b - 300`. Exact equality rolls
  forward without a cutoff-specific revert. The successful return value and event are authoritative when inclusion
  crosses the cutoff.
- Deposit claims, redemption cancellations, and redemption refunds require `receiver == controller`, including
  zero-share acknowledgements. Approved operators may execute them for the controller. Receiver eligibility does
  not depend on its share balance; `maxDeposit(controller)` and `maxMint(controller)` report controller limits.
- Epoch clearing is permissionless through the `requiredExecutionPath` field returned by
  `SettlementMonitorLens.getSettlementStatus(observedEpoch)`.
  `CachedMark` calls `HousePool.settleLpEpoch(uint256,uint256)` directly; `AtomicOracleRefresh` calls
  `OrderRouter.settleLpEpoch(bytes[])`. On the atomic route, the Router validates one `PoolReconcile` mark under the
  reported minimum-publish-time policy, installs it in the Engine, and reaches the Router-only HousePool callback in
  the same rollback frame. A nonzero `minimumAtomicPublishTime` enforces the post-round-hour floor. Frozen policy
  reports zero but still requires a valid stored Engine mark; this route cannot repair a stale frozen mark. HousePool reconciles once, processes matured Senior
  withdrawal demand before Junior demand, rechecks the live deposit-entry gate after redemption funding, then
  finalizes Junior deposits before Senior deposits. If bounded Senior processing stops with an eligible head remaining,
  the call must stop before Junior. A pass that advances no queue item also rolls back the Pyth and Engine updates. The
  Lens selects the direct cached route when there are no open positions or when the oracle is frozen and the cached
  mark is still fresh under the applicable frozen-mode limit. A frozen stale mark is classified for atomic execution
  but remains blocked by Oracle policy until a valid price path is available.
- Compact reads: `PerpsPublicLens`; use `getTrancheQueues(bool)` for matured heads/backlog and
  `getLpRequestState(bool,uint256,address)` for controller-specific pending/claimable balances.
  `TrancheView.maxWithdrawAssets` means current pool-level queue-funding capacity, not synchronous holder withdrawal capacity.
- Capacity-specific reads: `HousePool.getSeniorDepositCapacity()`, `reservedSeniorDepositAssets()`, and
  `areSeniorDepositReservationsWithinLimits()`; these intentionally are not added to the compact liquidity lens

Use these interfaces:

- `IPerpsLPViews`
- `IAsyncTrancheVault`
- `IAsyncTrancheVaultClaimableRedeem` for direct routing of activated deposit claims into redemption
- `IERC7540` and `IERC7575` for standard-compatible integrations

`IPerpsLPActions` describes configured-vault-to-`HousePool` mutation hooks. It is not a direct user surface. Senior
reservation/release hooks authorize only the configured vaults. Synchronized deposit activation and redemption
funding are coordinated by the Lens-selected cached or atomic keeper route; the atomic-refresh route enters through
the Router. Treat bootstrap,
seed-lifecycle, and other tranche setup mechanics as admin/setup concerns rather than the standard LP surface.

## Keepers

- Order execution: `OrderRouter.executeOrder(uint64 orderId,bytes[])`; execution follows global FIFO.
- Batch execution: `OrderRouter.executeOrderBatch(uint64 maxOrderId,bytes[])`; the id is an inclusive committed-order
  bound, not a count. Inspect returned `nextOrderId`, `terminalCount` and `stopReason` before resuming.
- Expiry cleanup: `OrderRouter.expireOrder(uint64)`.
- Selected invalid-order cleanup: `OrderRouter.clearInvalidOrders(uint64[])`; permissionless and oracle-free,
  accepting expired/configuration-invalid orders including non-head entries. Ineligible, duplicate and terminal ids
  are skipped; item failure stops while retaining prior cleanup. The candidate limit is the smaller of 64 and
  `maxPruneOrdersPerCall`.
- Neutral mark refresh: `OrderRouter.updateMarkPrice(bytes[])`
- Position-protection activation: `PositionProtectionBook.triggerPositionProtection(uint64,bytes[])`
- Latched close retry: `PositionProtectionBook.retryPositionProtectionClose(uint64)`; permissionless, nonpayable, and
  valid only when the protection has no live attempt. It creates a fresh FIFO-tail attempt without re-evaluating the
  original trigger or charging another execution bounty.
- Liquidation: `OrderRouter.executeLiquidation(address,bytes[])`
- Batch liquidation: `OrderRouter.executeLiquidationBatch(address[],bytes[])`
- Risk-off queue cleanup: `OrderRouter.clearRiskOffOrder(uint64)`; permissionless, oracle-free, and unpaid. The caller
  funds gas while the trader receives the full internal margin, execution-bounty, and attached `PendingOpen`
  protection-bounty refund.
- LP epoch clearing: follow `getSettlementStatus(observedEpoch).requiredExecutionPath` on `SettlementMonitorLens`; use direct
  `HousePool.settleLpEpoch(uint256,uint256)` for `CachedMark` and `OrderRouter.settleLpEpoch(bytes[])` for
  `AtomicOracleRefresh`
- LP epoch preflight and health: `SettlementMonitorLens`; select the epoch to observe explicitly, remember that the
  protocol still settles eligible FIFO heads, and simulate the exact selected direct-Pool or Router calldata before
  broadcast. The atomic route additionally requires the exact Pyth payload and fee. Its constructor-created
  `SettlementMonitorLensSidecar` is monitor-bound implementation code and is not a public keeper entrypoint. An active
  `lpEpochSettlementPaused` blocker stops both routes; `LpEpochKeeper` rejects it before payload decoding or fee quote.

Quote historical execution with `PletherOracle.getOrderExecutionFee`, and current-price operations with
`getUpdateFee`; simulate exact calldata and ETH value. A successful transaction can leave an order pending, so read
its `ExecutionResult` and canonical lifecycle outcome. See [Oracle synchronization](ORACLE_SYNCHRONIZATION.md).
Ordinary and protection close execution/cleanup pays no execution bounty; operators must budget gas and oracle fees.

The protocol-operated incident keeper should clear risk-off orders after containment. A risk-off open is already
logically unexecutable before physical cleanup, and cleanup authority does not grant its caller the trader's bounty.
Protection-attempt failure cleanup is unpaid when its exact protected position remains: the attempt's zero Order
bounty record settles and the protection relatches. Keeper infrastructure should process the terminal attempt,
observe `Latched`, confirm the exact position and retry preconditions, and submit the separate retry transaction;
the new attempt gets a fresh zero record. A position mismatch terminally fails the protection with no close-bounty
payment. The distinct protection trigger reward is paid only once, on trigger.

Use this interface:

- `IPerpsKeeper`
- `IPositionProtectionActions` for the permissionless trigger and retry entrypoints

Mark refresh, liquidation and atomic LP settlement are Router entrypoints. Protection triggering is a Book
entrypoint that invokes authenticated Router hooks. Do not call implementation sidecars directly.

## Protocol / Status Readers

- Compact protocol status and LP/trader views: `PerpsPublicLens`
- Retained protection status and latest-attempt linkage: `IPositionProtectionViews` on the Book returned by
  `OrderRouter.positionProtectionBook()`. `linkedOrderId` is the most recent attempt, not complete history; reconstruct
  the one-to-many attempt set from protection events and permanent lifecycle-Book outcomes. Read the protection's
  current close ceilings with `closeFinancialLimits(uint64)`.
- Authoritative order identity and outcome reads: the independently predeployed, exactly Router-bound
  `OrderLifecycleBook` exposed by `OrderRouter.lifecycleBook()` via `IOrderLifecycleBook`. Use
  `currentExecutionConfigHash()` before constructing a request, `clientIntent(account,
  clientOrderId)` to resolve permanent idempotency, `lifecycleStatus(orderId)` / `pendingPolicy(orderId)` while live,
  `isProtectionAttempt(orderId)` for the transient Router-authenticated child marker, and `terminalOutcome(orderId)` for the
  two-slot authenticated terminal summary (account, block, status, reason and hash). Use `verifyReceipt(receipt, terminalTime)` to authenticate supplied full history. `ProtectionAttemptRegistered` is permanent event evidence after finalization
  removes the marker. Full terminal receipts are emitted by `OrderFinalized`; their hash is retained in the compact
  outcome.
- Settlement operations and security monitoring: `SettlementMonitorLens`. Its route, oracle, queue, and invariant
  observations are advisory and fail-soft; they do not authorize settlement or replace an `eth_call` of
  the exact route-specific settlement transaction.
  - `getSettlementStatus(uint256 observedEpoch)`
  - `getSettlementHealth()`
  - `getPoolReconcileOracleStatus()`
  - `getSettlementObservation(uint256 observedEpoch)`
  - `observableConfigDigest()`

  `getSettlementStatus(...)` exposes `executionPathDependencyMask` for failures that prevent route selection and a
  broader `dependencyFailureMask`. Its Senior deposit-deferral mask describes pending activation gates, not
  new-request admission capacity. Use status for routine polling. Larger composite observations are checkpoint and
  alert-investigation reads; they expose `observationComplete` and `completeObservationDigest`.
  Completeness requires every Oracle dependency read, even for cached/no-work routing, but Oracle policy validity only on
  the atomic-refresh route. The complete digest is otherwise zero and always unauthenticated.
  A successfully read settlement hold is intentional complete state: the explicit status flag, operational blocker,
  and deposit deferral are set while route classification remains visible. A failed hold read is an unknown Pool
  dependency and makes the observation incomplete.
- Emergency containment: the configured guardian may call exactly
  `EmergencyPauseCoordinator.triggerEmergencyPause(bytes32,bytes32)`,
  `triggerLpEpochSettlementHold(bytes32,bytes32)`, or `triggerFullContainment(bytes32,bytes32)`. These fixed actions
  respectively add Router risk-off plus LP-entry pause, settlement-only hold, or all restrictions atomically.
  Monitoring output and incident hashes are advisory; neither the Lens nor an arbitrary caller can trip containment.
  Governance rotates/disables the guardian and releases RouterAdmin, HousePool entry, and HousePool settlement
  directly because the coordinator has no unpause surface and restrictions have no expiry.

Use these interfaces:

- `IProtocolViews`
- `IPerpsTraderViews`
- `IPerpsLPViews`
- `IOrderLifecycleBook` for authoritative order identity, policy, and outcome reads
- `ISettlementMonitorLens` for keeper/security monitoring only

## Rich Internal Surfaces

The following remain useful for tests, admin tooling, migration, and deep accounting introspection, but are not the intended long-term product API:

- `ICfdEngine`
- `ICfdEngineCore` is the live runtime/operator boundary, not the default product read API
- `IMarginClearinghouse`
- `ICfdEngineAccountLens`
- `ICfdEngineProtocolLens`
- `ICfdEngineLens` close/liquidation diagnostics, simulation helpers, and legacy open failure probes
- `IOrderRouterAccounting`
- `IHousePool`

## Implementation boundaries

The Engine owns economic state; the Clearinghouse and Pool own custody; the Router and Books own order/protection
lifecycle. Immutable planners and sidecars implement parts of those paths without becoming alternate public APIs.
Read [Architecture map](INTERNAL_ARCHITECTURE_MAP.md) for custody, helper bindings and mutation authority.

Release ABIs must match the deployed graph, including constructor-created Books and sidecars. The current request
API is V3 and current receipt/configuration hash domains are V5. `orderInterfaceVersion: 3` identifies the request
API, not every nested receipt version. Do not infer compatibility from the unversioned contract name or reuse old
tuple/storage decoders; see [Deployment](DEPLOYMENT.md).

# Canonical Perps Entrypoints

This file defines the intended product-facing perps surface.

For audit review that needs policy tables and read-surface canonicality in one place, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) alongside this file.

For autonomous trading-account and AI-agent integration, including bounded authority and receipt verification, use
[`WORKING_WITH_AI_AGENTS.md`](WORKING_WITH_AI_AGENTS.md) alongside this file.

## Traders

- Margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`
- Ordinary trade action: `OrderRouter.commitOrder(OrderV2Types.OrderRequest request)`
- Fresh external V2 requests must set `expectedConfigHash` to the current nonzero value returned by
  `OrderLifecycleBook.currentExecutionConfigHash()`; the public commit path rejects zero for a new intent.
- Emergency policy note: committed orders remain user-uncancellable. If RouterAdmin enters risk-off, each pre-cutoff
  open is instead terminally invalidated by protocol policy and its remaining reservations are refunded to the
  trader's internal clearinghouse balance.
- Discover the immutable protection action/view surface through `OrderRouter.positionProtectionBook()`.
- Open with staged protection: `PositionProtectionBook.commitOpenOrderWithProtection(CfdTypes.Side,uint256,uint256,uint256,PositionProtectionParams)`
- Existing-position protection: `PositionProtectionBook.createPositionProtection(PositionProtectionParams)`
- Existing-position protection creation locks both bounties first, then applies the canonical V2 exact-price safety
  gate through the Engine's configured planner. Price equity uses exact entry cost and only PnL pledge plus same-account
  claim; free settlement and generic action/reservation buckets do not count. Uncovered carry, an underfunded
  negative-VPI reserve, or equity at or below the stricter of initial and active normal/FAD margin rejects the action.
- Protection management: replace a `PendingOpen` or `Armed` record with
  `PositionProtectionBook.replacePositionProtection(uint64,PositionProtectionParams)`, or detach/cancel a
  `PendingOpen`/`Armed` record with `PositionProtectionBook.cancelPositionProtection(uint64)`
- Once a trigger is recorded, neither the owner nor a keeper may replace or cancel it. `Triggered` means one live close
  attempt; `Latched` means the irreversible trigger remains active with no live attempt and may be retried
  permissionlessly.
- Only Router-authenticated TP/SL-generated orders use `expectedConfigHash == bytes32(0)`: the protected parent-open
  host and protection-trigger path treat it as an internal unpinned marker. It is not a public wildcard and cannot be
  selected through `OrderRouter.commitOrder(...)`.
- Trader claim settlement: `CfdEngine.settleTraderClaim(address account)` for the account owner
- Compact reads: `PerpsPublicLens`; use `getTrancheQueues(bool)` for matured heads/backlog and
  `getLpRequestState(bool,uint256,address)` for controller-specific pending/claimable balances. The legacy
  `TrancheView.maxWithdrawUsdc` field now means current pool-level queue-funding capacity, not synchronous holder
  withdrawal capacity.
- Protection reads: `PositionProtectionBook.activePositionProtectionId(address)` and
  `PositionProtectionBook.getPositionProtection(uint64)`
- Trade-ticket previews: `CfdEngineLens.previewOpen(...)` and `CfdEngineLens.previewClose(...)`

Use these interfaces:

- `IMarginAccount`
- `IPerpsTraderActions`
- `IPositionProtectionActions`
- `IPositionProtectionViews`
- `IPerpsTraderViews`
- `ICfdEngineLens` for `previewOpen(...)` / `previewClose(...)` only

Do not use the wide clearinghouse reservation API or detailed accounting lenses as the canonical trader integration surface, except for `CfdEngineLens` trade-ticket previews.

## LPs

- Senior and Junior entry is asynchronous through the configured `TrancheVault`: request assets with
  `requestDeposit(assets, controller, owner)`, inspect pending/claimable state, and use ERC-4626 `deposit` or `mint`
  only to claim an activated request.
- LP exits are asynchronous. A holder calls `requestRedeem(shares, controller, owner)`; funded requests are exposed by
  `pendingRedeemRequest` / `claimableRedeemRequest` and claimed through ERC-4626 `redeem` or `withdraw`.
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
- A share-delivering claim, redemption cancellation, or redemption refund may target the controller or an account with
  no existing vault shares. This prevents unsolicited dust from resetting another holder's whole-balance cooldown;
  `maxDeposit(controller)` and `maxMint(controller)` remain receiver-independent controller limits.
- Epoch clearing is permissionless through the route reported by `SettlementMonitorLens.requiredExecutionPath`.
  `CachedMark` calls `HousePool.settleLpEpoch(uint256,uint256)` directly; `AtomicOracleRefresh` calls
  `OrderRouter.settleLpEpoch(bytes[])`. On the atomic route, the Router validates one `PoolReconcile` mark under the
  reported minimum-publish-time policy, installs it in the Engine, and reaches the Router-only HousePool callback in
  the same rollback frame. A nonzero `minimumAtomicPublishTime` enforces the post-round-hour floor; frozen stale-mark
  recovery reports zero and uses the frozen oracle policy instead. HousePool reconciles once, processes matured Senior
  withdrawal demand before Junior demand, rechecks the live deposit-entry gate after redemption funding, then
  finalizes Junior deposits before Senior deposits. If bounded Senior processing stops with an eligible head remaining,
  the call must stop before Junior. A pass that advances no queue item also rolls back the Pyth and Engine updates. The
  Lens selects the direct cached route when there are no open positions or when the oracle is frozen and the cached
  mark is still fresh under the applicable frozen-mode limit; a frozen stale mark requires the atomic-refresh route.
- Compact reads: `PerpsPublicLens`
- Capacity-specific reads: `HousePool.getSeniorDepositCapacity()`, `reservedSeniorDepositAssetsUsdc()`, and
  `areSeniorDepositReservationsWithinLimits()`; these intentionally are not added to the compact liquidity lens

Use these interfaces:

- `IPerpsLPViews`
- `IAsyncTrancheVault`
- `IERC7540` and `IERC7575` for standard-compatible integrations

`IPerpsLPActions` describes configured-vault-to-`HousePool` mutation hooks. It is not a direct user surface. Senior
reservation/release hooks authorize only the configured vaults. Synchronized deposit activation and redemption
funding are coordinated by the Lens-selected cached or atomic keeper route; the atomic-refresh route enters through
the Router. Treat bootstrap,
seed-lifecycle, and other tranche setup mechanics as admin/setup concerns rather than the standard LP surface.

## Keepers

- Order execution: `OrderRouter.executeOrder(uint64,bytes[])`
- Batch execution: `OrderRouter.executeOrderBatch(uint64,bytes[])`
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
- LP epoch clearing: follow `SettlementMonitorLens.requiredExecutionPath`; use direct
  `HousePool.settleLpEpoch(uint256,uint256)` for `CachedMark` and `OrderRouter.settleLpEpoch(bytes[])` for
  `AtomicOracleRefresh`
- LP epoch preflight and health: `SettlementMonitorLens`; select the epoch to observe explicitly, remember that the
  protocol still settles eligible FIFO heads, and simulate the exact selected direct-Pool or Router calldata before
  broadcast. The atomic route additionally requires the exact Pyth payload and fee. Its constructor-created
  `SettlementMonitorLensSidecar` is monitor-bound implementation code and is not a public keeper entrypoint. An active
  `lpEpochSettlementPaused` blocker stops both routes; `LpEpochKeeper` rejects it before payload decoding or fee quote.

The protocol-operated incident keeper should clear risk-off orders after containment. A risk-off open is already
logically unexecutable before physical cleanup, and cleanup authority does not grant its caller the trader's bounty.
Protection-attempt failure cleanup is unpaid when its exact protected position remains: its one reserved execution
bounty is retained for the next attempt. Keeper infrastructure should therefore process the terminal attempt, observe
`Latched`, confirm the exact position and zero pending-order retry preconditions, and submit the separate retry
transaction; it must not assume that relatching cleanup itself earns the eventual execution bounty. A position
mismatch follows ordinary paid cleanup and terminally fails the protection.

Use this interface:

- `IPerpsKeeper`
- `IPositionProtectionActions` for the permissionless trigger and retry entrypoints

Mark refresh, single and batch liquidation, and atomic-refresh LP-epoch settlement remain Router entrypoints.
Integrations must not call matching selectors on `OrderRouterLiquidationBatchSidecar`: the Router invokes that
separately deployed stateless implementation only through `delegatecall`, and direct or foreign-context sidecar calls
revert. In the delegate frame the Router remains `address(this)` and the direct-event address, downstream integrations
see it as caller, and the Router entrypoint caller is preserved; protection-trigger keeper identity is authenticated
by the Book's trailing payload.

## Protocol / Status Readers

- Compact protocol status and LP/trader views: `PerpsPublicLens`
- Retained protection status and latest-attempt linkage: `IPositionProtectionViews` on the Book returned by
  `OrderRouter.positionProtectionBook()`. `linkedOrderId` is the most recent attempt, not complete history; reconstruct
  the one-to-many attempt set from protection events and permanent lifecycle-Book outcomes.
- Authoritative order identity and outcome reads: the independently predeployed, exactly Router-bound
  `OrderLifecycleBook` exposed by `OrderRouter.lifecycleBook()` via `IOrderLifecycleBook`. Use
  `currentExecutionConfigHash()` before constructing a request, `clientIntent(account,
  clientOrderId)` to resolve permanent idempotency, `lifecycleStatus(orderId)` / `pendingPolicy(orderId)` while live,
  `isProtectionAttempt(orderId)` for the transient Router-authenticated child marker, and `outcome(orderId)` for the
  compact authenticated terminal result. `ProtectionAttemptRegistered` is permanent event evidence after finalization
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
  broader `dependencyFailureMask`. Its Senior deposit-deferral mask describes pending activation and reservation-limit
  state, not new-request admission capacity. Use status for routine polling. Composite observations are checkpoint and
  alert-investigation reads (roughly 6 KB returned and about 0.8–1.3 million representative `eth_call` gas); they
  expose `observationComplete` and `completeObservationDigest`. Completeness requires every Oracle dependency read,
  including the updated current-feed ABI, even for cached/no-work routing, but requires Oracle policy validity only on
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
- Non-preview `ICfdEngineLens` diagnostics such as simulation helpers and legacy open failure probes
- `IOrderRouterAccounting`
- `IHousePool`

## Boundary Summary

- `CfdEngine` / `ICfdEngineCore`: canonical runtime truth for execution, liquidation, and protocol status.
- `CfdEngineSettlementSidecar`: externalized close/liquidation settlement orchestration used by `CfdEngine`; not a product-facing surface.
- `CfdOrderPolicyEvaluator`: fixed permissionless stateless policy dependency used to assess authoritative Engine
  state against caller-pinned financial bounds; applications do not use it as an execution or custody surface.
- `OrderLifecycleBook`: independently predeployed canonical permanent order-identity and terminal-outcome reader. It
  is immutable-bound to the predicted Router, Engine, Clearinghouse, and HousePool; the Router constructor validates
  all four bindings before accepting it. Only that Router may register or finalize lifecycle state, and the Book owns
  no funds or execution authority.
- `OrderRouterV2ExecutionSidecar`: fixed stateless Router delegate implementation for oracle preparation, bounded
  execution, failure classification, and receipts. Direct stateful calls are rejected; integrations call the Router.
- `OrderRouterLiquidationBatchSidecar`: separately predeployed, immutable, exactly Router-bound stateless
  implementation detail for mark refresh, protection-trigger oracle/orchestration, single and batch liquidation, and
  atomic-refresh LP-epoch settlement. Direct integrations call the corresponding Router entrypoint, never the sidecar.
- `HousePoolRedemptionMathSidecar`: immutable stateless pure LP redemption-budget implementation used by HousePool;
  it is not an order, keeper, custody, or product-facing surface.
- `PerpsPublicLens`: canonical product-facing read layer.
- `SettlementMonitorLens`: canonical bounded settlement-monitoring read layer; no mutation or circuit-breaker
  authority. It validates the required one-time core wiring and its monitor-only sidecar is not a second canonical
  surface.
- `EmergencyPauseCoordinator`: guardian-only, immutable-bound surface with three fixed containment actions for new
  trading risk, LP entry, and/or LP settlement; no recovery, arbitrary mask, pricing, configuration, fund movement,
  or arbitrary-call capability. Closes/reductions, liquidations, redemption requests, and already-funded claims
  remain outside its authority; LP deposit requests are stopped by actions that include the entry restriction.
- `CfdEngineAccountLens`: rich account/accounting diagnostics.
- `CfdEngineProtocolLens`: protocol-accounting and house-pool snapshot diagnostics.
- `MarginClearinghouse`: custody plumbing with a small public trader surface and a larger operator surface.
- `OrderRouter`: delayed-order and keeper-execution plumbing, global FIFO ownership, and timelocked protection
  configuration. Its eighth and final constructor dependency is the predeployed lifecycle Book, while it creates the
  position-protection Book itself. It exposes both through `lifecycleBook()` and `positionProtectionBook()` but does
  not forward public protection selectors; raw queue state is non-canonical. To stay within EIP-170 it delegatecalls
  its separate stateless keeper sidecar for
  mark refresh/trigger-oracle resolution, single liquidation, liquidation batches, and atomic-refresh LP-epoch
  settlement, plus the active-oracle forwarding step of authenticated configuration, while retaining every public
  entrypoint, admin check, and Router execution/event address.
- `PositionProtectionBook`: canonical direct action/view surface and retained lifecycle store for position protection.
  It emits all protection lifecycle events and calls narrow Router host operations for mark refresh and FIFO mutation; it
  holds no token custody and does not mutate the queue directly. It is stateful and distinct from the stateless keeper
  sidecar returned by `OrderRouter.liquidationBatchSidecar()`.
- A `PendingOpen`, `Armed`, or `Latched` protection is a retained off-queue record, not an ordinary pending order.
  `Triggered` identifies exactly one live full-position close attempt. Every attempt is an ordinary binding FIFO order
  read through the normal order surfaces; a non-liquidation failure returns the protection to `Latched` and retains its
  execution bounty only when the exact protected side and size remain. A position mismatch resolves the protection as
  `Failed` under ordinary paid cleanup. Neither path erases the failed order's permanent receipt.

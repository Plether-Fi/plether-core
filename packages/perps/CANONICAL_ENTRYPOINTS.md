# Canonical Perps Entrypoints

This file defines the intended product-facing perps surface.

For audit review that needs policy tables and read-surface canonicality in one place, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) alongside this file.

## Traders

- Margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`
- Ordinary trade action: `OrderRouter.commitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice, bool isClose)`
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
- Liquidation: `OrderRouter.executeLiquidation(address,bytes[])`
- Batch liquidation: `OrderRouter.executeLiquidationBatch(address[],bytes[])`
- LP epoch clearing: follow `SettlementMonitorLens.requiredExecutionPath`; use direct
  `HousePool.settleLpEpoch(uint256,uint256)` for `CachedMark` and `OrderRouter.settleLpEpoch(bytes[])` for
  `AtomicOracleRefresh`
- LP epoch preflight and health: `SettlementMonitorLens`; select the epoch to observe explicitly, remember that the
  protocol still settles eligible FIFO heads, and simulate the exact selected direct-Pool or Router calldata before
  broadcast. The atomic route additionally requires the exact Pyth payload and fee. Its constructor-created
  `SettlementMonitorLensSidecar` is monitor-bound implementation code and is not a public keeper entrypoint.

Use this interface:

- `IPerpsKeeper`
- `IPositionProtectionActions` for the permissionless trigger entrypoint

Mark refresh, single and batch liquidation, and atomic-refresh LP-epoch settlement remain Router entrypoints.
Integrations must not call matching selectors on the `PositionProtectionBook`: the Router invokes the Book-carried
stateless implementations only through `delegatecall`, and direct Book calls revert. In the delegate frame the Router
remains `address(this)` and the direct-event address, downstream integrations see it as caller, and the Router
entrypoint caller is preserved; protection-trigger keeper identity is authenticated by the Book's trailing payload.

## Protocol / Status Readers

- Compact protocol status and LP/trader views: `PerpsPublicLens`
- Retained protection status and linkage: `IPositionProtectionViews` on the Book returned by
  `OrderRouter.positionProtectionBook()`
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

Use these interfaces:

- `IProtocolViews`
- `IPerpsTraderViews`
- `IPerpsLPViews`
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
- `PerpsPublicLens`: canonical product-facing read layer.
- `SettlementMonitorLens`: canonical bounded settlement-monitoring read layer; no mutation or circuit-breaker
  authority. It validates the required one-time core wiring and its monitor-only sidecar is not a second canonical
  surface.
- `CfdEngineAccountLens`: rich account/accounting diagnostics.
- `CfdEngineProtocolLens`: protocol-accounting and house-pool snapshot diagnostics.
- `MarginClearinghouse`: custody plumbing with a small public trader surface and a larger operator surface.
- `OrderRouter`: delayed-order and keeper-execution plumbing, global FIFO ownership, and timelocked protection
  configuration. It exposes `positionProtectionBook()` for discovery but does not forward public protection selectors;
  raw queue state is non-canonical. To stay within EIP-170 it delegatecalls Book-carried stateless orchestration for
  mark refresh/trigger-oracle resolution, single liquidation, liquidation batches, and atomic-refresh LP-epoch
  settlement while retaining the public entrypoints and Router execution/event address.
- `PositionProtectionBook`: canonical direct action/view surface and retained lifecycle store for position protection.
  It emits all protection lifecycle events and calls narrow Router host operations for mark refresh and FIFO mutation; it
  holds no token custody and does not mutate the queue directly. Its additional deploy-size role is bytecode carriage:
  delegated keeper logic reads Router state through external getters, never accesses Router storage by assumed layout,
  changes Router-owned state only through authorized external self/item calls, and rejects direct invocation.
- A `PendingOpen` or `Armed` protection is a retained off-queue OCO record, not an ordinary pending order. Once triggered,
  its linked full-position close is an ordinary binding FIFO order and is read through the normal order surfaces.

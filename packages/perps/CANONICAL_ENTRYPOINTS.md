# Canonical Perps Entrypoints

This file defines the intended product-facing perps surface.

For audit review that needs policy tables and read-surface canonicality in one place, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) alongside this file.

## Traders

- Margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`
- Trade actions: `OrderRouter.commitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice, bool isClose)`
- Trader claim settlement: `CfdEngine.settleTraderClaim(address account)` for the account owner
- Compact reads: `PerpsPublicLens`; use `getTrancheQueues(bool)` for matured heads/backlog and
  `getLpRequestState(bool,uint256,address)` for controller-specific pending/claimable balances. The legacy
  `TrancheView.maxWithdrawUsdc` field now means current pool-level queue-funding capacity, not synchronous holder
  withdrawal capacity.
- Trade-ticket previews: `CfdEngineLens.previewOpen(...)` and `CfdEngineLens.previewClose(...)`

Use these interfaces:

- `IMarginAccount`
- `IPerpsTraderActions`
- `IPerpsTraderViews`
- `ICfdEngineLens` for `previewOpen(...)` / `previewClose(...)` only

Do not use the wide clearinghouse reservation API or detailed accounting lenses as the canonical trader integration surface, except for `CfdEngineLens` trade-ticket previews.

## LPs

- Senior and Junior entry is asynchronous through the configured `TrancheVault`: request assets with
  `requestDeposit(assets, controller, owner)`, inspect pending/claimable state, and use ERC-4626 `deposit` or `mint`
  only to claim an activated request.
- LP exits are asynchronous. A holder calls `requestRedeem(shares, controller, owner)`; funded requests are exposed by
  `pendingRedeemRequest` / `claimableRedeemRequest` and claimed through ERC-4626 `redeem` or `withdraw`.
- A share-delivering claim, redemption cancellation, or redemption refund may target the controller or an account with
  no existing vault shares. This prevents unsolicited dust from resetting another holder's whole-balance cooldown;
  `maxDeposit(controller)` and `maxMint(controller)` remain receiver-independent controller limits.
- Epoch clearing is permissionless through `OrderRouter.settleLpEpoch(bytes[])`. With live open positions, the Router
  validates one post-round-hour `PoolReconcile` mark, installs it in the Engine, and reaches the Router-only HousePool
  callback in the same rollback frame. HousePool reconciles once, processes matured Senior withdrawal demand before
  Junior demand, then finalizes Junior deposits before Senior deposits. If bounded Senior processing stops with an
  eligible head remaining, the call must stop before Junior. A pass that advances no queue item also rolls back the
  Pyth and Engine updates. Direct cached-mark settlement is only a zero-position or oracle-frozen fallback.
- Compact reads: `PerpsPublicLens`
- Capacity-specific reads: `HousePool.getSeniorDepositCapacity()`, `reservedSeniorDepositAssetsUsdc()`, and
  `areSeniorDepositReservationsWithinLimits()`; these intentionally are not added to the compact liquidity lens

Use these interfaces:

- `IPerpsLPViews`
- `IAsyncTrancheVault`
- `IERC7540` and `IERC7575` for standard-compatible integrations

`IPerpsLPActions` describes configured-vault-to-`HousePool` mutation hooks. It is not a direct user surface. Senior
reservation/release hooks authorize only the configured vaults. Epoch withdrawal funding and delayed-deposit
activation are coordinated by the Router's atomic keeper entrypoint. Treat bootstrap,
seed-lifecycle, and other tranche setup mechanics as admin/setup concerns rather than the standard LP surface.

## Keepers

- Order execution: `OrderRouter.executeOrder(uint64,bytes[])`
- Batch execution: `OrderRouter.executeOrderBatch(uint64,bytes[])`
- Liquidation: `OrderRouter.executeLiquidation(address,bytes[])`
- Batch liquidation: `OrderRouter.executeLiquidationBatch(address[],bytes[])`
- LP epoch clearing: `OrderRouter.settleLpEpoch(bytes[])`

Use this interface:

- `IPerpsKeeper`

## Protocol / Status Readers

- Compact protocol status and LP/trader views: `PerpsPublicLens`

Use these interfaces:

- `IProtocolViews`
- `IPerpsTraderViews`
- `IPerpsLPViews`

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
- `CfdEngineAccountLens`: rich account/accounting diagnostics.
- `CfdEngineProtocolLens`: protocol-accounting and house-pool snapshot diagnostics.
- `MarginClearinghouse`: custody plumbing with a small public trader surface and a larger operator surface.
- `OrderRouter`: delayed-order and keeper-execution plumbing; raw queue state is non-canonical.

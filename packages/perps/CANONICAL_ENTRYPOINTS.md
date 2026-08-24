# Canonical Perps Entrypoints

This file defines the intended product-facing perps surface.

For audit review that needs policy tables and read-surface canonicality in one place, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) alongside this file.

## Traders

- Margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`
- Ordinary trade action: `OrderRouter.commitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice, bool isClose)`
- Discover the immutable protection action/view surface through `OrderRouter.positionProtectionBook()`.
- Open with staged protection: `PositionProtectionBook.commitOpenOrderWithProtection(CfdTypes.Side,uint256,uint256,uint256,PositionProtectionParams)`
- Existing-position protection: `PositionProtectionBook.createPositionProtection(PositionProtectionParams)`
- Protection management: replace a `PendingOpen` or `Armed` record with
  `PositionProtectionBook.replacePositionProtection(uint64,PositionProtectionParams)`, or detach/cancel a
  `PendingOpen`/`Armed` record with `PositionProtectionBook.cancelPositionProtection(uint64)`
- Trader claim settlement: `CfdEngine.settleTraderClaim(address account)` for the account owner
- Compact account/protocol reads: `PerpsPublicLens`
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

- Senior actions: `HousePool.depositSenior(uint256)` and `HousePool.withdrawSenior(uint256,address)`
- Junior actions: `HousePool.depositJunior(uint256)` and `HousePool.withdrawJunior(uint256,address)`
- Compact reads: `PerpsPublicLens`

Use these interfaces:

- `IPerpsLPActions`
- `IPerpsLPViews`

Treat bootstrap, seed-lifecycle, and other tranche setup mechanics as admin/setup concerns rather than the standard LP surface.

## Keepers

- Order execution: `OrderRouter.executeOrder(uint64,bytes[])`
- Batch execution: `OrderRouter.executeOrderBatch(uint64,bytes[])`
- Position-protection activation: `PositionProtectionBook.triggerPositionProtection(uint64,bytes[])`
- Liquidation: `OrderRouter.executeLiquidation(address,bytes[])`

Use this interface:

- `IPerpsKeeper`
- `IPositionProtectionActions` for the permissionless trigger entrypoint

## Protocol / Status Readers

- Compact protocol status and LP/trader views: `PerpsPublicLens`
- Retained protection status and linkage: `IPositionProtectionViews` on the Book returned by
  `OrderRouter.positionProtectionBook()`

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
- `OrderRouter`: delayed-order and keeper-execution plumbing, global FIFO ownership, and timelocked protection
  configuration. It exposes `positionProtectionBook()` for discovery but does not forward public protection selectors;
  raw queue state is non-canonical.
- `PositionProtectionBook`: canonical direct action/view surface and retained lifecycle store for position protection.
  It emits all protection lifecycle events and calls narrow Router host operations for mark refresh and FIFO mutation; it
  holds no token custody and does not mutate the queue directly.
- A `PendingOpen` or `Armed` protection is a retained off-queue OCO record, not an ordinary pending order. Once triggered,
  its linked full-position close is an ordinary binding FIFO order and is read through the normal order surfaces.

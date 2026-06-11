# Canonical Perps Entrypoints

This file defines the intended product-facing perps surface.

For audit review that needs policy tables and read-surface canonicality in one place, use [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) alongside this file.

## Traders

- Margin actions: `MarginClearinghouse.depositMargin(uint256)` and `MarginClearinghouse.withdrawMargin(uint256)`
- Trade actions: `OrderRouter.commitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice, bool isClose)`
- Trader claim settlement: `CfdEngine.settleTraderClaim(address account)` for the account owner
- Compact reads: `PerpsPublicLens`
- Trade-ticket previews: `CfdEngineLens.previewOpen(...)` and `CfdEngineLens.previewClose(...)`

Use these interfaces:

- `IMarginAccount`
- `IPerpsTraderActions`
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
- Liquidation: `OrderRouter.executeLiquidation(bytes32,bytes[])`

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

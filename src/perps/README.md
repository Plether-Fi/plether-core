# Plether Perps

Plether Perps is a bounded, delayed-order perpetuals engine for synthetic USD-directional exposure.

Traders post USDC margin, submit delayed orders through `OrderRouter`, and take `BULL` or `BEAR` exposure against a tranched USDC `HousePool`. LP capital sits behind senior and junior tranche vaults. The system is designed so worst-case trader liability is bounded at entry because the market price is capped:

```text
0 <= markPrice <= CAP_PRICE
```

If you want the accounting model first, read [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). If you want the operational and trust assumptions, read [`SECURITY.md`](SECURITY.md). If you want a one-page system map, read [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md).

## Perps In 5 Minutes

### What traders are trading

- There is one bounded directional market.
- The mark is the Plether basket price, not a raw DXY index print.
- `BEAR` profits when the basket price rises.
- `BULL` profits when the basket price falls.
- Payouts are bounded because the mark is clamped to `CAP_PRICE`.

### Who does what

- Traders deposit USDC into `MarginClearinghouse`, then submit delayed orders through `OrderRouter`.
- Keepers execute queued orders and liquidations using Pyth update data.
- LPs deposit USDC into `HousePool` through senior and junior `TrancheVault`s.
- `CfdEngine` is the canonical ledger. It does the math but does not custody raw tokens.

### Core product rules

- Delayed orders only. There is no same-tx trader market-order path.
- One live position per `accountId` at a time. Side flips must pass through a close.
- Orders are binding once committed. Users cannot cancel queued orders.
- Queue execution is FIFO from the global head.
- LP-capital carry is used instead of side-to-side funding.
- If the vault is short on cash, trader profits and liquidation bounties can become deferred balance claims instead of reverting the state transition.

### Units and ids

- USDC amounts and margin accounting use 6 decimals.
- Prices use 8 decimals.
- Position size uses 18 decimals.
- The normal trader `accountId` is `bytes32(uint256(uint160(user)))`.

## Canonical Entrypoints

For the intended product-facing surface, see [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md).

In practice, the compact public API is:

- Traders:
  - `MarginClearinghouse.depositMargin(uint256)`
  - `MarginClearinghouse.withdrawMargin(uint256)`
  - `OrderRouter.submitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDeltaUsdc, uint256 acceptablePrice, bool isReduceOnly)`
- Keepers:
  - `OrderRouter.executeOrder(uint64,bytes[])`
  - `OrderRouter.executeOrderBatch(uint64,bytes[])`
  - `OrderRouter.executeLiquidation(bytes32,bytes[])`
- LPs:
  - `HousePool.depositSenior(uint256)` / `HousePool.withdrawSenior(uint256,address)`
  - `HousePool.depositJunior(uint256)` / `HousePool.withdrawJunior(uint256,address)`
- Readers:
  - `PerpsPublicLens`

The simplified public interfaces live in `src/perps/interfaces/`:

- `IMarginAccount.sol`
- `IPerpsTraderActions.sol`
- `IPerpsTraderViews.sol`
- `IPerpsLPActions.sol`
- `IPerpsLPViews.sol`
- `IPerpsKeeper.sol`
- `IProtocolViews.sol`
- `PerpsViewTypes.sol`

The wider engine, clearinghouse, router, and house-pool interfaces still exist for tests, admin tooling, and deep accounting inspection, but they are not the recommended product integration surface.

## Runtime Components

The main runtime and read surfaces are:

- `MarginClearinghouse`: trader custody and typed margin buckets.
- `OrderRouter`: delayed-order queue, Pyth validation, and keeper bounty escrow.
- `CfdEngine`: canonical execution ledger and solvency boundary.
- `CfdEngineSettlementModule`: externalized close/liquidation settlement orchestration used by the engine.
- `HousePool`: LP capital, liabilities, reserves, and tranche waterfall.
- `TrancheVault`: ERC-4626 LP vault wrappers for senior and junior capital.
- `PerpsPublicLens`: compact product-facing read layer.
- `CfdEngineAccountLens` / `CfdEngineProtocolLens`: richer audit and operator read layers.

### Intended boundaries

- `CfdEngine` and `ICfdEngineCore` are the canonical runtime truth for execution, liquidation, and protocol status.
- `CfdEngineSettlementModule` executes close and liquidation choreography, while `CfdEngine` remains the storage owner.
- `MarginClearinghouse` owns trader settlement balances and locked-margin custody buckets.
- `OrderRouter` owns queued order records and router-custodied execution bounty escrow.
- `HousePool` owns LP capital and pays protocol obligations that must leave the vault.
- `PerpsPublicLens` is the default read surface for product consumers.
- The account and protocol lenses are for deeper diagnostics, tests, audits, and operator tooling.

## Trader Lifecycle

1. Deposit USDC into `MarginClearinghouse`.
2. Submit an open or close intent through `OrderRouter.submitOrder(...)`.
3. The router records a FIFO order, reserves committed margin, and escrows a keeper execution bounty.
4. A keeper later calls `executeOrder(...)` or `executeOrderBatch(...)` with Pyth update data.
5. `OrderRouter` validates oracle freshness, live-market `publishTime > commitTime` ordering, slippage, and queue eligibility, then calls `CfdEngine.processOrderTyped(...)`.
6. `CfdEngine` updates the position, realizes fees and carry, and settles through `MarginClearinghouse` and `HousePool`.

Important details:

- `acceptablePrice == 0` behaves like a delayed market-style order.
- Open orders are rejected during degraded mode and close-only windows.
- Failed orders are finalized from router-custodied bounty escrow; they are not requeued.
- Execution-time user-invalid opens and terminal-invalid closes pay the clearer from escrow, while genuine protocol-state invalidations refund the trader.
- Close orders can still execute during genuine frozen-oracle windows using the last valid mark subject to the relaxed frozen-market rules.
- Close-intent queue validation is account-local and bounded by the per-account pending-order queue.

### Deferred trader payouts

Profitable closes and some liquidation residuals can create deferred trader payouts if the vault cannot immediately fund them.

- Deferred payouts are tracked by beneficiary balance: `deferredPayoutUsdc[accountId]`.
- There is no FIFO deferred-claim queue.
- `claimDeferredPayout(accountId)` is permissionless.
- Claims can be partial if current vault cash is insufficient.
- Claimed amounts are credited into `MarginClearinghouse`, not sent directly to the wallet.

### Deferred clearer balances

Liquidation bounties are fail-soft when the vault is illiquid.

- The liquidation still completes.
- Any unpaid bounty is recorded in `deferredClearerBountyUsdc[keeper]`.
- `claimDeferredClearerBounty()` is permissionless and settles to clearinghouse credit rather than direct wallet transfer.
- Deferred trader payouts and deferred clearer balances are included in reserve and solvency accounting.

## LP Lifecycle

LPs provide USDC to the `HousePool`, which is split into senior and junior ERC-4626 tranche vaults.

- Senior gets fixed-rate yield and last-loss protection.
- Junior absorbs first loss and receives residual upside.
- LP withdrawals are gated by solvency, reserved liabilities, lifecycle state, mark freshness policy, and holder cooldown rules.

The withdrawal firewall is the key LP safety mechanism:

```text
freeUSDC = totalAssets - withdrawalReservedUsdc
```

Only unencumbered USDC can leave the pool.

### HousePool basics

- `rawAssets`: literal USDC balance held by `HousePool`.
- `accountedAssets`: canonical protocol-owned assets recognized by pool accounting.
- `excessAssets`: unsolicited positive transfers that have not been admitted into protocol economics.
- `totalAssets()`: conservative physically backed depth derived from `min(rawAssets, accountedAssets)`.

Operationally:

- unsolicited donations stay quarantined as `excessAssets` until explicitly accounted or swept,
- raw-balance shortfalls reduce effective backing immediately,
- reconcile, solvency, and withdrawal logic all consume this canonical depth source rather than the raw token balance.

### Senior / junior waterfall

- Senior principal is restored before junior receives surplus if senior has been impaired.
- `seniorHighWaterMark` prevents junior from extracting value while senior is still below its historical principal watermark.
- The mark increases additively on deposits, scales proportionally on withdrawals, and resets cleanly after wipeout plus recapitalization.
- Deposits remain blocked while senior is partially impaired.

### Bootstrap and withdrawal gates

- Trading does not become live until both tranche seed positions exist and the owner activates trading.
- Risk-increasing order commits and ordinary tranche deposits stay blocked during the seed lifecycle.
- `TrancheVault.maxDeposit()` / `maxMint()` return zero while lifecycle, stale-mark, deposit-pause, senior-impairment, or pending-bootstrap-assignment gates block deposits.
- `TrancheVault.maxWithdraw()` / `maxRedeem()` enforce cooldown plus pool-level withdrawal availability.

### Reconcile / freshness nuance

`HousePool` separates mark-dependent reconcile math from already-funded pending buckets.

- If mark freshness is required and stale, it skips mark-dependent yield and waterfall math.
- That stale path does not back-accrue senior yield across the stale interval.
- Already-funded pending recapitalization or trading-revenue buckets may still apply through the same settlement entrypoint.

This is why the LP docs distinguish freshness-gated repricing from already-funded cash movements.

## Accounting Model

### Bounded solvency at entry

Before increasing risk, the engine checks that the vault can cover the worst-case side payout after the trade.

```text
vault total assets >= max(globalBullMaxProfit, globalBearMaxProfit)
```

This does not mean LPs can never take loss. It means trader upside is bounded and the system can reason about the worst case without iterating positions.

### Carry instead of funding

Plether Perps uses a fixed global carry rate on LP-backed exposure rather than side-to-side funding.

```text
lpBackedNotionalUsdc = max(positionNotionalUsdc - reachableCollateralUsdc, 0)
```

Carry behavior:

- Accrues continuously by wall-clock time.
- Continues accruing even during stale or frozen oracle windows.
- Applies to whichever side is consuming LP capital.
- Is realized on open, close, add-margin, and clearinghouse deposit/withdraw balance mutations before those mutations change the carry basis.
- Flows to LP trading revenue once realized.
- Affects guard and risk checks before realization.

Close and liquidation use the planner's canonical carry-adjusted settlement/equity outputs; the live executor does not recompute a separate carry-blind loss or liquidation kernel.

Open-risk projection credits skew-reducing trade rebates into reachable collateral before the initial-margin check, so preview and execution do not conservatively reject rebate-backed but valid opens.

### Deferred liabilities

The system can complete terminal transitions even when immediate vault cash is insufficient.

- Trader gains can become deferred trader payouts.
- Liquidation bounties can become deferred clearer balances.
- Both are included in reserve and solvency accounting.
- Deferred balances are beneficiary-based, not queue-based.

### Conservative LP accounting

LP accounting intentionally refuses to count unrealized trader losses as present vault assets.

- Unrealized profitable trader PnL is treated as a liability.
- Unrealized trader losses are not booked as instantly withdrawable LP assets.
- Realized losses increase physical pool cash only when settlement actually happens.

This keeps LP share pricing and withdrawal limits conservative.

### Accounting domains

The perps system intentionally splits accounting into separate kernels:

- `CloseAccountingLib`: realized PnL, execution fee, trader settlement, and bad-debt handling for voluntary decreases.
- `LiquidationAccountingLib`: reachable collateral, keeper bounty, residual payout, and bad debt for forced close.
- `SolvencyAccountingLib`: effective assets, bounded max liability, withdrawal reserves, and free vault cash.
- `OrderEscrowAccounting`: router-held execution bounty reserves and margin-queue bookkeeping.

These domains answer different questions. They should not silently share assumptions just because the inputs look similar.

## Order Routing and Oracle Model

`OrderRouter` is a delayed-order FIFO queue with commit-now / execute-later semantics.

### Commit rules

- Opens are blocked while paused, degraded, or close-only.
- The router may reject predictably invalid opens at commit time using engine-lens prechecks.
- Each account may have at most `5` pending orders.
- The router escrows the execution bounty at commit time.

### Queue and bounty economics

- Execution always starts from the global queue head.
- Risk-increasing orders reserve an execution bounty quoted from the engine mark and bounded to `[0.05 USDC, 1.00 USDC]`.
- Close intents reserve a flat `1.00 USDC` bounty.
- Open bounties come from free settlement.
- Close bounties come from free settlement first and can fall back to active position margin so risk-reducing exits remain committable.
- Failed-order rewards stay independent from vault liquidity because they are paid from router escrow rather than LP cash.

### Execute rules

- Keepers execute from the global queue head.
- Pyth update data is required for live-market execution and the caller must attach ETH for the Pyth fee.
- Publish-time ordering and staleness rules enforce MEV resistance when the oracle is live.
- Slippage, expiry, and typed engine failures finalize the order; they do not create a retry queue.

### Basket oracle and publish-time checks

The router is configured with parallel arrays of Pyth feed ids, quantities, and base prices.

- `_computeBasketPrice()` normalizes each feed to 8 decimals.
- The router computes the weighted basket price in the same shape as the spot basket oracle.
- The minimum `publishTime` across feeds drives MEV checks, staleness validation, and `engine.lastMarkTime()` ordering.
- Live order execution requires `publishTime > order.commitTime`; frozen-oracle close-only windows are the only regime that relaxes that ordering rule.
- The execution price is clamped to `CAP_PRICE` before the slippage check so the user sees the same price the engine executes.

### Frozen oracle behavior

The system distinguishes between:

- `FAD window`: elevated margin and close-only risk policy while FX markets are approaching closure.
- `Oracle frozen`: relaxed staleness and relaxed commit-time publish ordering once FX feeds are actually offline.

This preserves close and liquidation liveness during real market closures without turning normal live trading into a free option.

### Stored vs derived order state

- Stored states are `None`, `Pending`, `Executed`, and `Failed`.
- `Executable` is derived from head-of-queue status plus freshness/oracle checks.
- `Expired` is represented by the failure path, not a separate persistent state bucket.

![Order lifecycle](../../assets/diagrams/perps-order-lifecycle.svg)

![Oracle regimes](../../assets/diagrams/perps-oracle-regimes.svg)

## Risk and Failure Containment

### Degraded mode

If a close or liquidation reveals post-op insolvency, the engine latches `degradedMode`.

While degraded:

- new opens are blocked,
- position-backed withdrawals are blocked,
- closes, liquidations, mark updates, and recapitalization remain available.

This is a containment latch, not a pause. The protocol still allows transitions that reduce risk or move the system back toward solvency.

### Liquidations

- Liquidations are proportional and bounded by actually reachable collateral.
- The keeper bounty is proportional with a floor.
- Residual trader value is preserved when positive.
- Same-account deferred payout is not treated as liquidation-reachable collateral; it is only netted once as terminal settlement bookkeeping.
- Bad debt is socialized to LP capital if losses exceed reachable collateral.
- Voluntary closes on underwater positions seize what is reachable and let the vault absorb the shortfall rather than trapping the user in an impossible state.

### Friday Auto-Deleverage (FAD)

The protocol raises margin requirements around FX market closure windows.

| Window | Margin basis | Max leverage |
|--------|--------------|--------------|
| Normal | `maintMarginBps = 1%` | 100x |
| FAD | `fadMarginBps = 3%` | 33x |

The owner can also add admin FAD days for expected FX-market holidays.

### Position and side invariants

The important runtime invariants are:

- each account holds at most one live directional position,
- side-local cached accounting remains symmetric and conservative,
- `sides[BULL].totalMargin + sides[BEAR].totalMargin == sum(pos.margin)` across live positions,
- preview/live parity must hold for close and liquidation accounting,
- router-custodied execution bounties are conserved across the order lifecycle.

## Governance and Admin Controls

Most risk-sensitive parameter changes are timelocked for 48 hours.

Timelocked surfaces include:

- `CfdEngine.riskParams`
- `CfdEngine.fadMaxStaleness`
- `CfdEngine.fadRunwaySeconds`
- `CfdEngine.engineMarkStalenessLimit`
- `HousePool.seniorRateBps`
- `HousePool.markStalenessLimit`
- `OrderRouter.maxOrderAge`
- `OrderRouter.orderExecutionStalenessLimit`
- `OrderRouter.liquidationStalenessLimit`

Instant controls remain for one-time wiring, emergency pause, and fee withdrawal.

### Pause behavior

- Pausing `OrderRouter` blocks new risk-increasing order commits.
- Keeper execution, liquidation, and other protective paths remain available.
- Pausing `HousePool` blocks new LP deposits but not protective withdrawals or reconcile.

## Key Constants

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maintMarginBps` | 100 (1%) | Maintenance margin requirement |
| `initMarginBps` | 150 (1.5%) | Initial margin requirement |
| `fadMarginBps` | 300 (3%) | FAD margin requirement |
| `baseCarryBps` | 500 (5%) | Annualized carry on LP-backed notional |
| `bountyBps` | 15 (0.15%) | Liquidation bounty rate |
| `minBountyUsdc` | 5,000,000 ($5) | Liquidation bounty floor |
| `EXECUTION_FEE_BPS` | 4 (0.04%) | Protocol trading fee |
| Open execution bounty | 0.05 to 1.00 USDC | Reserved at commit |
| Close execution bounty | 1.00 USDC | Reserved at commit |
| Normal execution staleness | 60s | Normal order execution freshness |
| Liquidation staleness | 15s | Live-market liquidation freshness |
| `engineMarkStalenessLimit` | 60s | Engine-side mark freshness |
| `markStalenessLimit` | 60s | HousePool mark freshness |
| `fadMaxStaleness` | 3 days | Frozen-market max staleness |
| `fadRunwaySeconds` | 3 hours | Admin FAD pre-close runway |
| `seniorRateBps` | 800 (8% APY) | Senior fixed-rate target |
| `DEPOSIT_COOLDOWN` | 1 hour | LP anti-flash cooldown |

## Further Reading

- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md): full accounting and reserve model
- [`SECURITY.md`](SECURITY.md): trust assumptions, liveness tradeoffs, and security posture
- [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md): intended product-facing integration surface
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md): one-page component and custody map

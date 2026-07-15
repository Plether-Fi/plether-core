# Plether Perps

Plether Perps is a bounded, delayed-order perpetuals engine for synthetic USD-directional exposure.

This package depends only on `shared` and third-party libraries. Build it independently from the repository root with
`forge build --root packages/perps` and test it with `forge test --root packages/perps`. Its package-owned tests live under
`packages/perps/test/perps/`.

Traders post USDC margin, submit delayed orders through `OrderRouter`, and take `BULL` or `BEAR` exposure against a tranched USDC `HousePool`. LP capital sits behind senior and junior tranche vaults. The system is designed so worst-case trader liability is bounded at entry because the market price is capped:

```text
0 <= markPrice <= CAP_PRICE
```

If you want the accounting model first, read [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). If you want the operational and trust assumptions, read [`SECURITY.md`](SECURITY.md). If you want a one-page system map, read [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md). If you are preparing for audit review, start with [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md).

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
- The owner can delegate emergency router pause authority through `OrderRouterAdmin` and pool pause authority on `HousePool` to dedicated `pauser` addresses while retaining owner-only `unpause()` and role assignment.

### Core product rules

- Delayed orders only. There is no same-tx trader market-order path.
- One live position per account address at a time. Side flips must pass through a close.
- Orders are binding once committed. Users cannot cancel queued orders.
- Queue execution is FIFO from the global head.
- LP-capital carry is used instead of side-to-side funding.
- If the HousePool is short on cash, trader profits can become senior trader claims instead of reverting the state transition; keeper bounties are funded from reserved trader margin inside the clearinghouse.

### Units and accounts

- USDC amounts and margin accounting use 6 decimals.
- Prices use 8 decimals.
- Position size uses 18 decimals.
- Accounts are tracked directly by trader address.

## Canonical Entrypoints

For the intended product-facing surface, see [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md).

In practice, the compact public API is:

- Traders:
  - `MarginClearinghouse.depositMargin(uint256)`
  - `MarginClearinghouse.withdrawMargin(uint256)`
- `OrderRouter.commitOrder(CfdTypes.Side side, uint256 sizeDelta, uint256 marginDelta, uint256 targetPrice, bool isClose)`
- Keepers:
  - `OrderRouter.executeOrder(uint64,bytes[])`
  - `OrderRouter.executeOrderBatch(uint64,bytes[])`
  - `OrderRouter.executeLiquidation(address,bytes[])`
- LPs:
  - `HousePool.depositSenior(uint256)` / `HousePool.withdrawSenior(uint256,address)`
  - `HousePool.depositJunior(uint256)` / `HousePool.withdrawJunior(uint256,address)`
- Readers:
  - `PerpsPublicLens`
  - `CfdEngineLens.previewOpen(...)` / `previewClose(...)` for trade-ticket simulations using caller-supplied oracle prices

The simplified public interfaces live in `packages/perps/src/interfaces/`:

- `IMarginAccount.sol`
- `IPerpsTraderActions.sol`
- `IPerpsTraderViews.sol`
- `ICfdEngineLens.sol` for `previewOpen(...)` / `previewClose(...)` trade-ticket previews
- `IPerpsLPActions.sol`
- `IPerpsLPViews.sol`
- `IPerpsKeeper.sol`
- `IProtocolViews.sol`
- `PerpsViewTypes.sol`

The wider engine, clearinghouse, router, and house-pool interfaces still exist for tests, admin tooling, and deep accounting inspection, but they are not the recommended product integration surface.

### Trade-ticket previews

Frontends should use `CfdEngineLens.previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime)` to simulate opens and same-side increases before committing an order. The lens is read-only: it uses the caller-supplied `oraclePrice` and `publishTime`, does not fetch Hermes data, does not ingest Pyth updates, and does not mutate engine mark state.

Preview units match the rest of perps:

- USDC amounts, fees, VPI, margin, equity, and PnL use 6 decimals.
- Oracle prices and returned execution/liquidation prices use 8 decimals.
- Position sizes use 18 decimals.
- Signed fields such as `vpiUsdc`, `tradeCostUsdc`, `postVpiAccrued`, `postUnrealizedPnlUsdc`, and `postEquityUsdc` may be negative.

`executionPrice` is clamped to `CAP_PRICE`. `valid`, `invalidReason`, and `failureCategory` are authoritative for whether the order would pass planner validation. For invalid previews, numeric economics or post-trade fields may be zero or partial depending on where planning stopped.

For valid previews, `postSize`, `postMarginUsdc`, `postEntryPrice`, `postVpiAccrued`, post-trade health, and liquidation fields are projected from the same planner/accounting logic used by live execution. `hasLiquidationPrice == false` means no liquidation threshold exists inside `[0, CAP_PRICE]`. For BULL positions, `liquidationPrice` is the lowest in-range price that is liquidatable. For BEAR positions, it is the highest in-range price that is liquidatable.

Close previews expose frozen-market pricing separately from VPI. `frozenSpreadUsdc` is the fixed spread assessed on the reduced notional, `frozenSpreadPaidUsdc` is the portion actually retained or collected for LPs, and `frozenSpreadWaivedUsdc` is the uncollectible portion waived on a terminal full close. These values are zero outside `oracleFrozen`, and a valid preview preserves `frozenSpreadUsdc == frozenSpreadPaidUsdc + frozenSpreadWaivedUsdc`. Successful closes with a nonzero assessment emit `FrozenCloseSpreadSettled(account, assessedUsdc, paidUsdc, waivedUsdc)` from `CfdEngineSettlementSidecar`, so the live result is reconstructible from durable logs.

## Runtime Components

The main runtime and read surfaces are:

- `MarginClearinghouse`: trader custody and typed margin buckets.
- `OrderRouter`: thin external shell for delayed-order commits, keeper execution, Pyth validation, and clearinghouse-reserved keeper bounties.
- `CfdEngine`: canonical execution ledger and solvency boundary.
- `CfdEngineSettlementSidecar`: externalized open/close/liquidation settlement orchestration used by the engine.
- `CfdEnginePlanner`: externalized open/close/liquidation plan builder wired into the engine after deployment.
- `HousePool`: LP capital, liabilities, reserves, and tranche waterfall.
- `TrancheVault`: ERC-4626 LP vault wrappers for senior and junior capital.
- `PerpsPublicLens`: compact product-facing read layer.
- `CfdEngineAccountLens` / `CfdEngineProtocolLens`: richer audit and operator read layers.

### Intended boundaries

- `CfdEngine` and `ICfdEngineCore` are the canonical runtime truth for execution, liquidation, and protocol status.
- `CfdEngineSettlementSidecar` executes open, close, and liquidation settlement choreography, while `CfdEngine` remains the storage owner.
- `CfdEngine`, `CfdEnginePlanner`, `CfdEngineSettlementSidecar`, and `CfdEngineAdmin` are now deployed separately and wired once through `CfdEngine.setDependencies(...)` to keep engine initcode under EIP-3860.
- `MarginClearinghouse` owns trader settlement balances and locked-margin custody buckets.
- `OrderRouter` owns queued order records while execution-bounty value remains reserved in `MarginClearinghouse`; its implementation is split into base storage/hooks, handler, validation, and utility modules.
- `HousePool` owns LP capital and pays engine-authorized obligations that must leave the pool.
- `PerpsPublicLens` is the default read surface for product consumers.
- The account and protocol lenses are for deeper diagnostics, tests, audits, and operator tooling.

## Trader Lifecycle

1. Deposit USDC into `MarginClearinghouse`.
2. Submit an open or close intent through `OrderRouter.commitOrder(...)`.
3. The router records a FIFO order, reserves committed margin, and reserves a keeper execution bounty in `MarginClearinghouse`.
4. A keeper later calls `executeOrder(...)` or `executeOrderBatch(...)` with Pyth update data.
5. `OrderRouter` resolves the first valid Pyth tick strictly after the order's `commitTime`, applies conservative confidence-adjusted pricing, validates slippage and queue eligibility, then calls `CfdEngine.processOrderTyped(...)`.
6. `CfdEngine` updates the position, realizes fees and carry, and settles through `MarginClearinghouse` and `HousePool`.

Important details:

- `acceptablePrice == 0` behaves like a delayed market-style order.
- Open orders are rejected during degraded mode and close-only windows.
- Failed orders are finalized from reserved clearinghouse bounty reservation; blocked FIFO heads remain pending.
- Execution-time user-invalid opens, protocol-state invalidations, and terminal-invalid closes pay the keeper from reservation so FIFO cleanup remains incentive compatible.
- Close orders can still execute during genuine frozen-oracle windows using the last valid mark subject to the relaxed frozen-market rules and the fixed LP-owned frozen-close spread.
- Close-intent queue validation is account-local and bounded by the per-account pending-order queue.

### Trader claim balance

Profitable closes and some liquidation residuals can create a trader claim balance if the HousePool cannot immediately fund them.

- Trader claim balance is tracked by beneficiary balance: `traderClaimBalanceUsdc[account]`.
- There is no FIFO trader-claim queue.
- `settleTraderClaim(account)` is beneficiary-only and requires the caller to own `account`.
- Settlement is all-or-nothing for the account claim and only succeeds when aggregate trader claim liabilities are fully cash-covered.
- Claimed amounts are credited into `MarginClearinghouse`, not sent directly to the wallet.

### Keeper bounty credit

Order and liquidation bounties are margin transfers inside `MarginClearinghouse`.

- Open and close order bounties are reserved from trader margin at commit time.
- Successful execution credits the keeper's clearinghouse settlement balance from the reservation.
- Liquidation bounties are capped by liquidation-reachable collateral and credited directly to the keeper.

Protocol fees settle into the treasury clearinghouse account only when they are cash-collected from trader settlement or when remaining free `HousePool` cash can fund a top-up after senior trader claims and immediate trader payouts. The simplified custody model does not create protocol-fee receivables; uncredited fee portions stay in pool backing rather than becoming withdrawable treasury margin.

## LP Lifecycle

LPs provide USDC to the `HousePool`, which is split into senior and junior ERC-4626 tranche vaults.

- Senior gets a target coupon funded from junior NAV, plus last-loss protection.
- Junior absorbs first loss and receives residual upside.
- LP withdrawals are gated by solvency, reserved liabilities, lifecycle state, mark freshness policy, and holder cooldown rules.
- Ordinary tranche deposits and partial withdrawals must be at least `1 USDC`, preventing dust flows from forcing coupon checkpoint churn while still allowing full dust exits.
- During `oracleFrozen`, withdrawals remain live under stale-priced ERC4626 math with a fixed tranche-local surcharge. Immediate active-share deposits use the same surcharge only if no trader positions are open; otherwise LP entry must use pending deposit epochs.
- During `oracleFrozen`, bootstrap admin flows stay blocked: `initializeSeedPosition(...)` and `assignUnassignedAssets(...)` must wait for the oracle to become live again instead of inheriting the stale-window LP fee path.

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
- `seniorHighWaterMark` is a compounded protected senior claim watermark, not a principal-only watermark.
- When the junior-funded coupon increases `seniorPrincipal`, the paid coupon also ratchets `seniorHighWaterMark` upward and remains senior-protected after later losses.
- The mark increases additively on deposits, scales proportionally on withdrawals, and resets cleanly after wipeout plus recapitalization.
- Ordinary deposits into both tranches remain blocked while senior is impaired; recovery capital must arrive through explicit recapitalization or realized pool revenue.

### Reachability domains

- Generic collateral reachability excludes queued committed-order and reserved-settlement buckets.
- Use the generic basis for carry, withdraw checks, and other non-terminal position health paths.
- Terminal collateral reachability may consume queued/reserved buckets, but only in full-close and liquidation settlement paths that explicitly unlock them.

### Bootstrap and withdrawal gates

- Trading does not become live until both tranche seed positions exist and the owner activates trading.
- Risk-increasing order commits and ordinary tranche deposits stay blocked during the seed lifecycle.
- `TrancheVault.maxDeposit()` / `maxMint()` return zero while lifecycle, stale-mark, deposit-pause, open-position, senior-impairment, or pending-bootstrap-assignment gates block immediate active-share deposits.
- `TrancheVault.requestDeposit()` keeps ordinary LP entry available through pending deposit epochs; requests are funded up front, become non-cancellable at their activation epoch, and mint shares only after permissionless epoch finalization fixes the batch price.
- During `oracleFrozen`, `TrancheVault.maxMint()` returns the finite share cap implied by the active frozen-entry fee rather than the default unbounded ERC4626 value.
- `TrancheVault.maxWithdraw()` / `maxRedeem()` enforce cooldown plus pool-level withdrawal availability.

### Reconcile / freshness nuance

`HousePool` separates mark-dependent reconcile math from already-funded pending buckets.

- If mark freshness is required and stale, it skips mark-dependent revenue/loss waterfall math.
- The senior coupon still checkpoints against existing junior NAV, so future junior entrants are not charged for prior time.
- `finalizePoolConfig()` cannot change `seniorRateBps` while the mark is stale; governance must refresh the mark first.
- Already-funded pending recapitalization or trading-revenue buckets may still apply through the same settlement entrypoint.

This is why the LP docs distinguish freshness-gated repricing from already-funded cash movements.

## Accounting Model

### Bounded solvency at entry

Before increasing risk, the engine checks that the HousePool can cover the worst-case side payout after the trade.

```text
pool total assets >= max(globalBullMaxProfit, globalBearMaxProfit)
```

This does not mean LPs can never take loss. It means trader upside is bounded and the system can reason about the worst case without iterating positions.

### LP-capital carry

Plether Perps uses utilization-indexed carry on each side's fixed borrow base rather than a side-to-side rate
mechanism.

```text
borrowBaseUsdc = max(positionMaxProfitUsdc - activePositionMarginUsdc, 0)
sideUtilizationBps = min(sideBorrowBaseUsdc / poolAssetsUsdc, 100%)
positionCarryUsdc = borrowBaseUsdc * (sideCarryIndex - positionLastCarryIndex)
```

Carry behavior:

- Accrues continuously by wall-clock time.
- Continues accruing even during stale or frozen oracle windows.
- Is assessed per position on a stored borrow base, not on a checkpoint-time mark price.
- Both `BULL` and `BEAR` positions can accrue carry at the same time if both sides have nonzero borrow base.
- Can be checkpointed into `unsettledCarryUsdc` when a basis-changing settlement credit occurs before physical collection is possible.
- Is realized before margin, pool-asset, or risk-parameter mutations change the carry base/rate denominator.
- On deposit, realized carry may be collected from post-deposit settlement in the same transaction.
- On withdraw, carry is realized before settlement balance is reduced.
- Flows to LP trading revenue once realized.
- Affects guard and risk checks before realization.

Close and liquidation use the planner's canonical carry-adjusted settlement/equity outputs; the live executor does not recompute a separate carry-blind loss or liquidation kernel.

Open-risk projection credits skew-reducing trade rebates into reachable collateral before the initial-margin check, so preview and execution do not conservatively reject rebate-backed but valid opens.

### Trader claim liabilities

The system can complete terminal transitions even when immediate pool cash is insufficient.

- Trader gains can become trader claim balances.
- Keeper bounties are direct clearinghouse credits funded from trader margin and do not become vault liabilities.
- Trader claim balance is included in reserve and solvency accounting.
- Trader claim balances are beneficiary-based, not queue-based.

### Conservative LP accounting

LP accounting intentionally refuses to count unrealized trader losses as present pool assets.

- Unrealized profitable trader PnL is treated as a liability.
- Unrealized trader losses are not booked as instantly withdrawable LP assets.
- Side MtM uses a conservative max-profit envelope so same-side loser debt cannot net down live winner liability before settlement.
- Realized losses increase physical pool cash only when settlement actually happens.

This keeps LP withdrawal limits conservative. Incoming deposits are priced from a separate unrealized-MtM-neutral NAV so conservative phantom liabilities cannot become a discount for new shares, while realized pool losses still lower deposit pricing.
Immediate active-share deposits are only accepted when no trader positions are open. While positions are open, ordinary LP entry moves through pending deposit epochs: the user funds the request up front, waits at least one full epoch, loses cancellation rights once the activation epoch begins, and later receives the batch-priced shares after permissionless finalization. This avoids pricing instantly active new LP shares against an incomplete unrealized-loss model: the engine's O(1) side aggregates can conservatively bound winner liabilities, but they cannot compute exact collateral-capped loser receivables without per-position accounting.

### Accounting domains

The perps system intentionally splits accounting into separate kernels:

- `CloseAccountingLib`: realized PnL, signed VPI, execution fee, frozen-close spread, trader settlement, and bad-debt handling for voluntary decreases.
- `LiquidationAccountingLib`: reachable collateral, keeper bounty, residual payout, and bad debt for forced close.
- `SolvencyAccountingLib`: effective assets, bounded max liability, withdrawal reserves, and free pool cash.
- `OrderReservationAccounting`: clearinghouse-reserved execution bounty accounting and margin-queue bookkeeping.
- `OrderRouterBase` / `OrderCommitHandler` / `OrderExecutionHandler` / `OrderExecutionSettlement` / `OrderLiquidationHandler` / `OrderBountyAccounting` / `OrderValidation`: shared router state, delayed-order lifecycle handling, terminal execution settlement, liquidation flow, bounty accounting, and preflight validation.
- `HousePool.recordClaimantInflow(amount, kind, cashMode)`: claimant-owned value routing for both revenue and recapitalization, with explicit cash-arrival vs retained-value modes.

These domains answer different questions. They should not silently share assumptions just because the inputs look similar.

## Order Routing and Oracle Model

`OrderRouter` is a delayed-order FIFO queue with commit-now / execute-later semantics.

### Commit rules

- Opens are blocked while paused, degraded, or close-only.
- The router may reject predictably invalid opens at commit time using engine-lens prechecks.
- Partial closes must meet the same notional floor used for new positions; only full closes may clear a smaller residual.
- Each account may have at most `5` pending orders.
- The router reserves the execution bounty in `MarginClearinghouse` at commit time.

### Queue and bounty economics

- Execution always starts from the global queue head.
- Risk-increasing orders reserve an execution bounty quoted from the engine mark and bounded to `[0.01 USDC, 0.20 USDC]`.
- Close intents reserve a flat governance-configured bounty capped at `1 USDC` (default `0.20 USDC`).
- Partial close size is floored by the engine `minBountyUsdc / bountyBps` notional threshold at the commit reference price, preventing dust closes from occupying the FIFO queue for a flat bounty.
- Open bounties come from free settlement.
- Close bounties use free settlement first when carry can be checkpointed from a fresh live mark; otherwise they fall back to bounded active position margin so stale-mark closes remain committable.
- Failed-order rewards stay independent from pool liquidity because they are paid from clearinghouse-reserved trader value rather than LP cash.

### Execute rules

- Keepers execute from the global queue head.
- Pyth update data is required for live-market execution and the caller must attach ETH for the Pyth fee.
- Live order settlement uses Pyth's unique historical parse over `(commitTime, commitTime + orderSettlementWindow]`, capped at `block.timestamp`, rather than the latest reveal-time price.
- `executeOrderBatch` caches a successfully parsed historical basket and reuses it for later FIFO orders whose `commitTime` is still strictly before the cached tick and covered by the same unique range, avoiding repeated Pyth parsing for clustered commits.
- A keeper cannot skip an unfavorable post-commit tick by submitting a later tick: the unique parse requires the previous publish time to be no later than the order's `commitTime`.
- Slippage, expiry, and typed engine failures finalize the order; close-only ineligibility for queued opens blocks execution without consuming the FIFO head.

### Basket oracle and publish-time checks

The router is configured with a `PletherOracle` contract. The oracle instance owns the Pyth endpoint plus the basket feed ids, quantities, base prices, and inversion flags set at deployment.

- `PletherOracle` normalizes each feed to 8 decimals while computing the basket price.
- The oracle computes the weighted basket price in the same shape as the spot basket oracle.
- Basket confidence is propagated conservatively by summing weighted component relative confidence, then multiplying by the basket price.
- Opening and closing orders use the adverse side of the confidence interval for the trader's side: `BULL` opens are priced lower, `BEAR` opens are priced higher, `BULL` closes are priced higher, and `BEAR` closes are priced lower.
- Liquidation checks also use the side-adverse confidence-adjusted mark for the liquidated account.
- Component publish times must stay within `maxComponentPublishTimeDivergence`; if one basket leg is too far from the others, live opens are blocked rather than mixing fresh and stale components.
- The minimum `publishTime` across feeds remains the basket publish time passed to the engine; historical order fills can use an older post-commit price without rewinding a newer cached engine mark.
- Frozen-oracle close-only windows are the only regime that relaxes historical live-market settlement.
- The router's `PletherOracle` address is recoverable through `OrderRouterAdmin`'s timelocked oracle-config flow; changing the Pyth endpoint or basket arrays requires deploying a new oracle and timelocking the router onto it.
- The execution price is clamped to `CAP_PRICE` before the slippage check so the user sees the same price the engine executes.

### Frozen oracle behavior

The system distinguishes between:

- `FAD window`: elevated margin and close-only risk policy while FX markets are approaching closure.
- `Oracle frozen`: relaxed staleness and relaxed commit-time publish ordering once FX feeds are actually offline.

LP policy follows that split as well:

- `FAD` alone does not change LP entry/exit pricing.
- Voluntary close/reduce execution keeps the normal signed quadratic VPI curve and lifetime rebate clamp in every oracle regime, so a skew-reducing frozen close can still earn the same bounded negative VPI as a live close.
- During `oracleFrozen` only, voluntary close/reduce execution also assesses `frozenCloseSpreadBps` on the reduced position notional. The spread is fixed rather than staleness-dependent, belongs entirely to LPs, and never credits the protocol treasury.
- Live and FAD-only closes do not pay the frozen-close spread. Pyth's adverse-confidence price adjustment remains an independent execution-price guard rather than an input to this spread.
- A partial close must fully settle the spread together with the rest of its close obligation. If a terminal full close cannot collect the entire spread, the uncollectible portion is waived instead of becoming bad debt, preserving exit liveness.
- Liquidations do not assess the frozen-close spread and retain their existing settlement rules.
- `oracleFrozen` keeps LP withdrawals live and keeps immediate LP deposits live only when no trader positions are open; pending deposit epochs remain the ordinary entry path. Senior and junior stale-window actions pay fixed surcharges that compensate incumbent LPs in that same tranche.

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
- Liquidations are designed to avoid price-impact-driven cascades: positions settle against an external bounded oracle mark, not forced selling into an AMM or order book, so one liquidation does not mechanically move the execution price for the next. Large oracle moves can still make many positions independently liquidatable.
- The keeper bounty is proportional with a floor.
- Liquidation does not compute a fresh VPI delta, but any negative accrued VPI rebate debt is clawed back before residual/bad-debt planning.
- Residual trader value is preserved when positive.
- Same-account trader claim balance is not treated as liquidation-reachable collateral; it is only netted once as terminal settlement bookkeeping.
- Bad debt is socialized to LP capital if losses exceed reachable collateral.
- Voluntary full closes on underwater positions seize what is reachable and let the HousePool absorb genuine trading-loss shortfall rather than trapping the user in an impossible state; an uncollectible frozen-close spread is waived and does not add bad debt.

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
- side-local cached accounting stays consistent with the live position set and never overstates bounded payoff or margin state,
- `sides[BULL].totalMargin + sides[BEAR].totalMargin == sum(pos.margin)` across live positions,
- commit-time open preview must not admit orders the router can already classify as commit-time rejectable, and close/liquidation preview math must match live accounting semantics,
- clearinghouse USDC execution-bounty reservations and admin-custodied ETH refund claims are each conserved across their respective lifecycle transitions.

## Governance and Admin Controls

Most risk-sensitive parameter changes are timelocked for 48 hours.
Engine risk controls live on `CfdEngineAdmin`, and router risk controls plus pause state now live on `OrderRouterAdmin`, with both deployed admin contracts finalizing changes onto their host contracts.

Timelocked surfaces include:

- `CfdEngineAdmin.EngineRiskConfig` -> `CfdEngine.riskParams`, `CfdEngine.executionFeeBps`, `CfdEngine.frozenCloseSpreadBps`
- `CfdEngineAdmin.EngineCalendarConfig` -> `CfdEngine.fadDayOverrides`, `CfdEngine.fadRunwaySeconds`
- `CfdEngineAdmin.EngineFreshnessConfig` -> `CfdEngine.fadMaxStaleness`, `CfdEngine.engineMarkStalenessLimit`
- `HousePool.seniorRateBps`
- `HousePool.markStalenessLimit`
- `OrderRouterAdmin` -> `OrderRouter.RouterConfig`
- `OrderRouterAdmin` -> `OrderRouter.OracleConfig` for the configured `PletherOracle` address

Instant controls remain for one-time wiring and fee withdrawal. `OrderRouter` pause/unpause is now owner-gated on `OrderRouterAdmin` rather than the router itself.

### Pause behavior

- Pausing `OrderRouter` blocks new risk-increasing order commits.
- Keeper execution, liquidation, and other protective paths remain available.
- Pausing `HousePool` blocks new LP deposits but not protective withdrawals or reconcile.

## Default Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maintMarginBps` | 100 (1%) | Maintenance margin requirement |
| `initMarginBps` | 150 (1.5%) | Initial margin requirement |
| `fadMarginBps` | 300 (3%) | FAD margin requirement |
| `baseCarryBps` | 500 (5%) | Annualized carry on LP-backed notional |
| `bountyBps` | 10 (0.10%) | Liquidation bounty rate |
| `minBountyUsdc` | 1,000,000 ($1) | Liquidation bounty floor |
| `executionFeeBps` | 4 (0.04%) | Timelocked protocol trading fee |
| `frozenCloseSpreadBps` | 50 (0.50%) | Fixed LP-owned spread on voluntary close/reduce notional during `oracleFrozen` |
| Open execution bounty | 0.01 to 0.20 USDC | Timelocked router reserve bounds |
| Close execution bounty | 0.20 USDC | Timelocked router reserve amount |
| Normal execution staleness | 60s | Normal order execution freshness |
| Order settlement window | 15s | Historical Pyth search window after order commit |
| Component publish divergence | 5s | Max basket-leg publish-time skew for live settlement |
| Adverse confidence multiplier | 2,000 (0.2x) | Confidence interval multiplier applied to execution and liquidation marks |
| Liquidation staleness | 15s | Live-market liquidation freshness |
| `engineMarkStalenessLimit` | 60s | Engine-side mark freshness |
| `markStalenessLimit` | 60s | HousePool mark freshness |
| FAD override days | empty | Admin-set calendar override set |
| `fadMaxStaleness` | 3 days | Frozen-market max staleness |
| `fadRunwaySeconds` | 3 hours | Admin FAD pre-close runway |
| `seniorRateBps` | 800 (8% APY) | Senior target coupon rate funded from junior NAV |
| `DEPOSIT_COOLDOWN` | 1 hour | LP anti-flash cooldown |

OrderRouter also exposes timelocked admin control over `maxPendingOrders`, `minEngineGas`, and `maxPruneOrdersPerCall`.
`maxOrderAge` must stay nonzero and cannot exceed one hour, so close-only windows cannot be indefinitely pinned by an old FIFO head.

`frozenCloseSpreadBps` is timelocked with the rest of `EngineRiskConfig`, must remain nonzero, and is hard-capped at `1,000` bps (10%).

## Off-Chain Applications and Workers

The product applications and supporting services live in the [`plether-app`](https://github.com/Plether-Fi/plether-app) repository:

- [Frontend application](https://github.com/Plether-Fi/plether-app/tree/master/apps/frontend): provides the trader and LP web interface for reading protocol state and submitting transactions.
- [Backend API](https://github.com/Plether-Fi/plether-app/tree/master/apps/backend): provides a read-only API for cached market data, account history, Pyth payloads, and other product-facing queries; it does not submit protocol transactions.
- [Order and liquidation keeper](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/Keeper.hs): monitors pending orders and unhealthy positions, then submits eligible executions and liquidations.
- [Pyth basket cache worker](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/BasketWorker.hs): fetches current and historical Pyth FX data and stores basket snapshots and update payloads for the API and keeper flows.
- [On-chain oracle updater](https://github.com/Plether-Fi/plether-app/blob/master/apps/frontend/scripts/perps-oracle-worker.mjs): reads fresh cached Pyth payloads from the backend and submits `updateMarkPrice` transactions.
- [Perps history indexer](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/PerpsIndexer.hs): indexes confirmed perps contract events into the backend database for historical queries.

## Further Reading

- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md): full accounting and reserve model
- [`SECURITY.md`](SECURITY.md): trust assumptions, liveness tradeoffs, and security posture
- [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md): intended product-facing integration surface
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md): one-page component and custody map

# Plether Perpetuals Engine

Bounded synthetic directional markets with zero-slippage execution. Traders take leveraged `plDXY-BULL` and `plDXY-BEAR` exposure against a tranched USDC House Pool.

## Core Insight: Bounded Solvency

Traditional perpetuals have unbounded upside tail risk. Plether constrains payout with a fixed Protocol CAP (`P_bull + P_bear = CAP`), so each trade has a deterministic worst-case liability at entry. Before opening risk, the engine proves that the House Pool can fund that bound even if the oracle jumps to either extreme. LP bad debt can still arise from realized settlement shortfalls or delayed liquidation, but it remains bounded, socialized, and contained through bad-debt accounting, degraded mode, and withdrawal reserves.

## Architecture

Five contracts separate custody, execution, and ledger math.

For the accounting model that should govern future refactors, see [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). For a one-page map of custody buckets, mutators, accounting readers, and cross-domain value flows, see [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md).

### Accounting Domains

- `CloseAccountingLib`: shared kernel for preview/live close settlement, including realized PnL, execution fees, and net trader settlement.
- `LiquidationAccountingLib`: shared kernel for preview/live liquidation settlement, including reachable collateral, keeper bounty, residual payout, and bad debt.
- `SolvencyAccountingLib`: protocol-level balance-sheet view used for max-liability checks, effective-asset construction, and degraded-mode decisions.
- `WithdrawalAccountingLib`: LP cash-firewall view used for withdrawal reserves and free vault cash after fees and deferred liabilities.
- Planner previews follow the same staged transition model as live execution: router cash mutations happen before payout and solvency classification on the post-mutation state.
- The current no-funding baseline reserves real liabilities only. Any future LP-capital carry model should be introduced as a fresh feature on top of this baseline rather than reviving classic side-to-side funding.

These domains answer different questions and must not silently share assumptions.

### Accounting Glossary

- `raw assets`: the literal USDC token balance currently sitting in `HousePool`.
- `accounted assets`: canonical protocol-owned USDC recognized by `HousePool` accounting; unsolicited positive transfers do not enter here until explicitly accounted.
- `excess assets`: raw USDC held above `accountedAssets`; quarantined surplus that can be swept or explicitly admitted into protocol economics later.
- `net physical assets`: the physically backed vault depth after applying the canonical accounting boundary, i.e. `min(rawAssets, accountedAssets)` before any higher-level solvency adjustments.
- `effective solvency assets`: the conservative asset figure used by solvency checks after applying protocol-specific adjustments such as unpaid liabilities, withdrawal-reserve treatment, and "do not count unrealized trader losses as assets" policy.
- `terminal reachable collateral`: the maximum collateral the protocol can actually seize and realize from a trader by following the close or liquidation path to completion, after applying margin-bucket access rules and free-settlement reachability constraints.
- `physical reachable collateral`: the clearinghouse USDC the protocol can touch immediately for generic risk checks and views. This excludes deferred payout IOUs.
- `same-account nettable deferred payout`: an existing deferred trader payout owed to the same account. This is not generic collateral and is only consumed where terminal settlement explicitly nets it.

### I. MarginClearinghouse — The Prime Broker

[`MarginClearinghouse.sol`](MarginClearinghouse.sol)

USDC-only cross-margin portfolio manager and collateral custodian. It tracks settlement balances and typed locked-margin buckets in 6-decimal USDC.

The execution engine never touches raw tokens. It operates through typed bucket and reservation APIs (`lockPositionMargin()`, `unlockPositionMargin()`, `reserveCommittedOrderMargin()`, `releaseOrderReservation()`, `consumeOrderReservation()`, `settleUsdc()`, `seizeUsdc()`), with the router authorized through the engine's configured `orderRouter()` boundary.

### II. HousePool + TrancheVault — The House Pool & Firewall

[`HousePool.sol`](HousePool.sol) · [`TrancheVault.sol`](TrancheVault.sol)

The House Pool is the USDC counterparty for trader payouts. It has senior and junior ERC-4626 tranche vaults (`TrancheVault`).

**Withdrawal Firewall**: `maxWithdraw` / `maxRedeem` compute `freeUSDC = totalAssets() - maxSystemLiability`. LPs can withdraw only unencumbered capital. At 100% utilization, capital is locked to cover active trader payouts.

**Canonical Pool Depth**: `HousePool` distinguishes `rawAssets` (token balance), `accountedAssets` (canonical protocol-owned depth), `excessAssets` (unaccounted positive balance), and `totalAssets()` / physical assets (`min(rawAssets, accountedAssets)`). Unsolicited positive transfers stay quarantined as excess until explicitly accounted or swept. Raw-balance shortfalls reduce effective backing immediately. Solvency, reconcile, and withdrawal-firewall paths all consume this controlled depth source.

**Senior High-Water Mark**: `seniorHighWaterMark` tracks peak senior principal. After senior impairment, revenue restores `seniorPrincipal` to that mark before any surplus flows to junior. The mark increases additively on deposits, scales proportionally on withdrawals (along with `unpaidSeniorYield`), and resets cleanly after a full wipeout and recapitalization. Deposits remain blocked while senior is partially impaired (`0 < seniorPrincipal < seniorHighWaterMark`).

**Seed Lifecycle Gate**: Once bootstrap seeding begins, risk-increasing order commits and ordinary tranche deposits stay blocked until both tranche seed positions exist on-chain and the owner explicitly activates trading. This prevents partially seeded live operation.

**ERC-4626 Deposit View Parity**: `TrancheVault.maxDeposit()` / `maxMint()` share the same `HousePool.canAcceptTrancheDeposits()` gate as the mutate path. They return zero during lifecycle or senior-impairment blocks, while tranche deposits are paused, while required mark freshness is stale, or while `unassignedAssets` indicates pending bootstrap assignment.

**Stale Reconcile Clocking**: HousePool separates the waterfall reconcile clock from the senior-yield checkpoint clock. If mark freshness is required but stale, it skips mark-dependent yield and waterfall math without resetting `lastReconcileTime`. Any stale-path mutation that changes senior principal first checkpoints `lastSeniorYieldCheckpointTime`, preventing later fresh reconciles from back-accruing yield across the pre-mutation interval. Pending recapitalization and trading-revenue buckets still apply.

**Projected Withdrawal Parity**: `getPendingTrancheState()` uses the same pending-bucket mapping as live reconcile and reserves projected assets exactly once. ERC-4626 preview consumers therefore see the same post-reconcile principals and withdrawal caps as the mutate-first path.

### III. OrderRouter — The MEV Shield & Queue

[`OrderRouter.sol`](OrderRouter.sol)

Two-step asynchronous **commit-reveal** pipeline:

1. **Commit** — The user submits intent (size, side, target price) and locks margin. The router assigns a strictly sequential `orderId` and records `block.timestamp`.
2. **Reveal** — Keepers submit Pyth price payloads. The router aggregates the FX feeds into the basket price, enforces `publishTime > commitTimestamp` and `publishTime >= engine.lastMarkTime()` while the oracle is live, and supports batched multi-order execution. During genuine frozen-oracle windows, closes execute against the last valid oracle price rather than failing an impossible publish-time check.

**Basket Oracle**: The router is configured with parallel arrays of Pyth feed IDs, quantities (18-dec weights summing to `1e18`), and base prices (8-dec). `_computeBasketPrice()` normalizes each feed to 8 decimals and computes `Σ (price × quantity) / (basePrice × 1e10)`, matching the spot `BasketOracle`. The minimum `publishTime` across feeds drives MEV checks, action-specific staleness validation, and `engine.lastMarkTime()`.

**Slippage Protection**: The execution price is clamped to `CAP_PRICE` before the slippage check. Users therefore see the same price that `CfdEngine` executes.

**Queue Economics**: Execution always starts from the global queue head, and the engine call is wrapped in `try/catch`. Retryable market-state misses such as slippage emit `OrderSkipped`, move the order to the global tail, and apply a short retry cooldown. Risk-increasing orders reserve an execution bounty quoted from `lastMarkPrice()` in the engine (falling back to `$1.00` before the first mark) and bounded to `[0.05 USDC, 1.00 USDC]`. Close intents reserve a flat `1.00 USDC` router-custodied bounty, sourced from free settlement first and then live position margin. Commit-time rejection is limited to `CommitTimeRejectable` opens; execution-time `UserInvalid` failures pay the clearer; execution-time `ProtocolStateInvalidated` opens refund the trader bounty; retryable market-state misses remain pending.

**Bounded Queue Cleanup**: Global queue cleanup is bounded. `executeOrder()` auto-skips only a fixed number of expired head orders per call, `executeOrderBatch()` uses a fixed global scan budget, and keepers can call `pruneExpiredOrders()` to advance expired queue heads in fixed-cost slices.

**Execution Bounty Custody**: At commit time the router seizes the reserved execution bounty into router custody. Opens always source it from free settlement. Closes source it from free settlement first and can fall back to active position margin so risk-reducing close intents remain committable without idle cash. Failed-order rewards therefore stay independent from vault liquidity.

**Order Escrow Accounting**: Order escrow flows through `OrderEscrowAccounting`. Router-held execution bounty reserves and margin-queue bookkeeping live there, while committed order margin remains clearinghouse-owned reservation state. Account-level escrow summaries adapt that reservation ledger rather than re-owning the economic amount inside the router.

**Freshness Buckets**: Live-market oracle freshness is split across four uses. `orderExecutionStalenessLimit` gates normal order execution and manual mark refresh. `liquidationStalenessLimit` separately gates live-market liquidations. `engineMarkStalenessLimit` gates engine-side mark-sensitive paths such as the trader withdraw guard and close-order bounty backing. `HousePool.markStalenessLimit` gates reconciliation and withdrawal safety. During genuine frozen-oracle windows, all four switch to `fadMaxStaleness`.

**Close Bounty Tradeoff**: Allowing close intents to source their flat keeper bounty from active position margin is a bounded liveness tradeoff. With the per-account pending-order cap, at most `5 USDC` of otherwise reachable margin can sit in router escrow awaiting close execution.

**Typed Engine Failure Boundary**: `OrderRouter` executes through `CfdEngine.processOrderTyped()` and receives `CfdEngine__TypedOrderFailure(CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose)` instead of matching raw engine selectors. Combined with `previewOpenFailurePolicyCategory(...)`, this gives the router a stable semantic boundary for commit-time rejection and execution-time bounty routing.

**Explicit Order Records**: Each `orderId` maps to one `OrderRecord` carrying the immutable `CfdTypes.Order`, lifecycle status, reserved execution bounty, and both intrusive queue link sets. Residual committed margin lives in clearinghouse-owned reservation records keyed by `orderId`; router/accounting helpers expose queue structure and derived summaries over that reservation ledger.

**Engine Margin vs Custody Margin**: `CfdEngine.positions[accountId].margin` is the canonical economic position-margin state used in risk, open/close planning, and side aggregate accounting. `MarginClearinghouse.positionMarginUsdc` / `activePositionMarginUsdc` is the canonical custody bucket holding the locked funds that back that state. `sides[*].totalMargin` is a cached aggregate of engine economic margin, not a custody owner.

**Stored vs Derived Order States**: Storage persists `None`, `Pending`, `Executed`, and `Failed`. `Executable` is derived (`Pending && orderId == nextExecuteId && oracle data / age checks pass`), not stored. `Expired` is represented as `Failed` plus the expiry failure path and reason.

![Order lifecycle](../../assets/diagrams/perps-order-lifecycle.svg)

**Binding User Intents**: Open and close orders are binding once committed. Users cannot cancel queued intents, so keepers can rely on FIFO settlement without giving traders a free execution option. Open commits are rejected during degraded mode and close-only windows to prevent deterministic bounty loss on impossible orders.

**Per-Account Queue Cap**: Each account may hold at most `5` pending orders. This bounds account-local cleanup during liquidation and prevents one trader from bloating the FIFO.

**Terminal Settlement Liveness**: Full closes remain FIFO-local and do not scan later queued orders. Liquidations perform bounded account-local cleanup: when an account is liquidated, the router walks only that account's capped pending-order list, clears those orders, and forfeits their execution escrow to the vault. Liquidation preview and live accounting both include that forfeitable escrow in the same post-forfeiture vault-depth view.

### IV. CfdEngine — The Mathematical Ledger

[`CfdEngine.sol`](CfdEngine.sol)

Core state machine. **Holds zero physical funds.** It receives validated intents, enforces O(1) solvency bounds, mutates positions, calculates PnL, and instructs the Clearinghouse and HousePool on settlement.

**Degraded Mode**: If a profitable close pushes `effectiveAssets` below the remaining worst-case liability bound, the close succeeds and the engine latches `degradedMode`. While degraded, new opens and position-backed withdrawals are blocked. Closes, liquidations, mark updates, and recapitalization remain available until the owner clears the mode after solvency is restored.

**Deferred Close Payouts**: A profitable close never fails solely because the House Pool is short on free cash. If the vault cannot immediately fund realized gain after reserving outstanding deferred claims and protocol-fee inventory, the position is destroyed and the unpaid profit is recorded in `deferredPayoutUsdc[accountId]`. Deferred payouts are outstanding protocol liabilities in reserve and solvency accounting. Claims are serviced through a global oldest-first queue, but each account keeps one active queue node: added deferred value inherits that account's existing queue position. Partial liquidity services the queue head first. `claimDeferredPayout(accountId)` is permissionless, and paid value settles into the trader's `MarginClearinghouse` balance.

**Fail-Soft Keeper Bounties**: Liquidations are fail-soft if the House Pool cannot immediately fund the liquidation bounty after reserving outstanding deferred claims and protocol-fee inventory. The state transition completes and the unpaid amount becomes a deferred bounty claim in the same oldest-first queue. Each keeper keeps one active queue node, so additional shortfalls inherit queue position. Servicing is permissionless, senior to fee withdrawals, and settles into `MarginClearinghouse` credit rather than direct wallet transfer. Order-execution bounties remain router-custodied user escrow and do not depend on vault liquidity.

**Deferred Liabilities in NAV/Reserves**: Deferred trader payouts and deferred clearer/liquidation bounty claims are included in withdrawal reserve, solvency, and HousePool reconciliation / NAV paths. A shared senior-cash reservation kernel gates fee withdrawal, fresh trader payouts, fresh liquidation bounty payments, and deferred-claim servicing. Deferred queue heads are senior to fee withdrawals, while fresh non-fee payouts reserve both queued senior claims and protocol-fee inventory.

**Three-Bucket Liquidation Residuals**: Liquidation planning carries three trader-value buckets: `settlementRetainedUsdc` for reachable settlement left in the clearinghouse ledger, `existingDeferredRemainingUsdc` for pre-existing deferred payout that survives liquidation, and `freshTraderPayoutUsdc` for new trader payout created by liquidation equity in excess of reachable settlement after the keeper bounty. This keeps preview, execution, and solvency accounting aligned.

**Accounting Domains**: `CfdEngine` uses explicit accounting kernels for close settlement (`CloseAccountingLib`), liquidation settlement (`LiquidationAccountingLib`), solvency (`SolvencyAccountingLib`), and withdrawal reserves (`WithdrawalAccountingLib`). This separates execution and balance-sheet policy by domain.

**Preview Solvency Signals**: Canonical `previewClose()` / `previewLiquidation()` and hypothetical `simulateClose()` / `simulateLiquidation()` expose both the transition-only `triggersDegradedMode` flag and the raw post-op solvency result (`postOpDegradedMode`, `effectiveAssetsAfterUsdc`, `maxLiabilityAfterUsdc`). Integrators can therefore distinguish "this action newly latches degraded mode" from "the system remains degraded after this action."

**Canonical vs Hypothetical Views**: Canonical `previewClose()` / `previewLiquidation()` read vault depth from `HousePool.totalAssets()` and answer current-state behavior. Hypothetical `simulateClose()` / `simulateLiquidation()` are explicit what-if APIs for caller-supplied depth assumptions.

**Position View Semantics**: `getPositionView()` separates `physicalReachableCollateralUsdc` from `nettableDeferredPayoutUsdc`. Generic position-health and withdraw-facing views use only physically reachable clearinghouse collateral. Existing deferred payout is shown separately so UIs and audits can reason about same-account terminal netting without treating that IOU as instantly withdrawable collateral.

**Withdraw Guard Policy**: Open-position withdrawals are blocked once post-withdraw equity would fall below `initMarginBps`, not only maintenance margin. `initMarginBps`, `maintMarginBps`, and `fadMarginBps` are separate configuration surfaces.

**Key Invariants**:

**Core Protocol**

- Each `accountId` holds at most one live directional position at a time; side-flips must pass through a close.
- FIFO execution is strict: `orderId == nextExecuteId`, so no later order can bypass an earlier pending order.
- Router-custodied execution bounties are conserved across order lifecycle transitions until they are paid to a clearer or absorbed as protocol revenue.

**Side-State / Engine Accounting**

- `SideState` remains symmetric and conservative: side-local mirrors (`maxProfitUsdc`, `openInterest`, `entryNotional`, `totalMargin`) must stay consistent with the aggregate live position set.
- `sides[BULL].totalMargin + sides[BEAR].totalMargin` must equal the sum of `pos.margin` across all live positions.
- Preview/live parity must hold for the close and liquidation accounting kernels, including degraded-mode checks.
- Terminal close and liquidation settlement must conserve value across trader payout, vault assets, protocol fees, deferred liabilities, and bad debt.

**Router Queue / Margin Escrow**

- `pendingOrderCounts` must match the actual pending FIFO queue per account.
- Margin-queue membership must match orders whose clearinghouse reservation record has positive `remainingAmountUsdc`.
- Clearinghouse reservation records are the sole source of truth for committed order margin; the router only maintains queue membership and execution-bounty escrow.
- Locked margin attributable to queued opens must remain consistent with clearinghouse reservation state and only be released, consumed, or converted through explicit order lifecycle events.

**Solvency / Containment**

- Withdrawal reserve must move monotonically with deferred liabilities; adding deferred trader payouts or liquidation bounties cannot reduce reserves.
- Effective solvency assets must never overstate realizable vault resources: unrealized trader losses do not count as assets, while deferred liabilities remain senior claims on liquidity.
- After terminal transitions (close/liquidation) reveal insolvency, `degradedMode` must contain further risk expansion until recapitalization restores solvency.

**HousePool / LP Accounting**

- HousePool withdrawal limits can only expose unencumbered USDC after accounting for protocol fees, max liability, and deferred liabilities.
- Senior high-water-mark accounting must prevent junior from extracting value while senior capital remains impaired.
- HousePool reconciliation, NAV, and withdrawal-firewall paths must consume the same canonical engine snapshots for accounting inputs.

**Solvency Invariant**: Before opening any trade, the engine proves:

```
vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)
```

Because prices cannot exceed CAP or drop below zero, this check bounds solvency at trade entry. Realized close payouts can reveal post-trade insolvency, which is why the engine latches `degradedMode` and blocks further risk expansion until recapitalized.

### V. CfdMath — The Quantitative Library

[`CfdMath.sol`](CfdMath.sol)

Pure stateless math library for PnL limits and virtual price impact (VPI).

## Market Balancing: The Economic Repulsion Engine

The protocol takes no physical inventory risk and does not auto-hedge on AMMs. It uses path-independent math to repel toxic flow and reward market makers for healing skew.

### Virtual Price Impact (VPI)

Quadratic formula that charges toxic directional flow and rewards market makers with uncapped rebates:

```
C(S) = 0.5 · k · S² / D
```

`S` = Skew, `D` = Vault Depth, `k` = severity factor. Trade cost = `C(S_post) - C(S_pre)`.

**Wash-Trade Immunity**: Opening and immediately closing yields exactly `$0` net VPI. Combined with the flat 4 bps execution fee, wash trading to farm rebates is a net loss.

**Depth Manipulation Resistance**: Each position tracks `vpiAccrued`, the cumulative VPI charges and rebates across its lifetime. On close, the engine bounds VPI so the user cannot extract a net rebate greater than what they paid. Inflating or deflating depth between open and close therefore cannot produce VPI profit because the bound enforces `accruedVpi + closeVpi >= 0`.

## Conservative Mark-to-Market

The engine values LP equity with O(1) global accumulators (`globalBullEntryNotional`, `globalBearEntryNotional`) plus bounded payout accounting, giving real-time aggregate PnL without iterating positions.

### Per-Side Zero Clamp

The MtM function (`getVaultMtmAdjustment`) computes per-side unrealized `PnL`, then clamps each side at zero. The vault therefore never recognizes unrealized trader losses as assets:

```
bullTotal = bullPnl
bearTotal = bearPnl

if bullTotal < 0: bullTotal = 0
if bearTotal < 0: bearTotal = 0

return bullTotal + bearTotal
```

The return value is the vault's aggregate unrealized liability to profitable traders. When traders are losing on net, MtM returns zero rather than a positive vault asset. Realized losses flow through physical USDC transfers and naturally increase pool balance.

**Trade-off**: The vault temporarily undercounts assets when traders have unrealized losses. This is conservative: junior principal may dip until traders close or are liquidated, at which point physical USDC transfers restore balance. That is preferable to letting paper profits inflate LP principal and be withdrawn as real USDC.

### Layered Conservatism

Different protocol functions use different conservatism levels:

| Function | Purpose | Approach | Rationale |
|----------|---------|----------|-----------|
| `_reconcile()` | LP equity valuation | Zero-clamped MtM | Conservative share pricing — vault only counts liabilities, never unrealized gains |
| `getFreeUSDC()` | LP withdrawal limits | Asymmetric (liabilities only) | Cash leaving the vault must exist physically — never offset reserves by paper claims |
| `_getEffectiveAssets()` | Position solvency | Direct collateral + PnL | Solvency counts only economically real resources |

The junior tranche absorbs realized bad debt through the reconciliation waterfall. No insurance fund or ADL is required.

## Risk Management & Liquidations

### Opposing Position Restriction

An `accountId` can hold only one directional state per market. Opening the opposite side requires closing the existing position first, preventing capacity griefing through offsetting positions.

### Minimum Position Size

Positions must be large enough that their proportional keeper bounty (`notional × bountyBps`) meets the `minBountyUsdc` floor. This preserves liquidation incentive at all sizes. Partial closes that would leave `margin < minBountyUsdc` are rejected to prevent unliquidatable dust.

### Proportional Liquidations

- **Keeper Bounty**: 0.15% of notional size, bounded by a $5 floor. Capped at positive equity when available, otherwise capped by physically reachable liquidation collateral (vault never pays more than the liquidation path can actually seize)
- **Residual Equity Preserved**: The protocol seizes only the exact mathematical loss + keeper bounty; remaining cross-margin equity is returned to the user
- **Bad Debt Socialization**: If user equity is negative (extreme slippage), the House Pool absorbs the shortfall as a systemic insurance cost
- **Graceful Self-Close**: Voluntary closes on underwater positions seize available balance and let the vault absorb any shortfall, rather than reverting

### Friday Auto-Deleverage (FAD)

FX markets close on weekends. Sunday reopens can gap through leverage buffers.

| Window | MMR | Max Leverage |
|--------|-----|-------------|
| Normal | 1.0% | 100x |
| FAD (Fri 19:00 UTC -> Sun 22:00 UTC) | 3.0% | 33x |

Traders above 33x leverage must add margin before Friday evening or be liquidated while Friday oracle prices are active.

**Two-State Oracle Model**: The router separates risk management from oracle availability:

1. **FAD window** (`isFadWindow()`, Friday 19:00 UTC+): enforces close-only mode and elevated margins. Open orders are rejected. MEV checks remain live and live-market staleness uses the normal execution and liquidation thresholds because Pyth FX feeds continue publishing until about 22:00 UTC.
2. **Oracle frozen** (`isOracleFrozen()`, Friday 22:00 -> Sunday 21:00 UTC): relaxes staleness to `fadMaxStaleness` (default 3 days) and bypasses the MEV `commitTime` check because Pyth FX feeds have stopped. Close orders submitted during the freeze execute at the last valid oracle price instead of failing an impossible `publishTime > commitTime` requirement. Friday uses 22:00 UTC to avoid freezing while markets may still be open; Sunday uses 21:00 UTC to restore MEV protection as soon as markets could resume. In winter, the 21:00 unfreeze creates a safe 1-hour liveness drop because 60s staleness rejects the ~47h-old price.

This prevents the Friday 19:00-22:00 interval from becoming an MEV gap while markets are still moving.

![Oracle regimes](../../assets/diagrams/perps-oracle-regimes.svg)

**Admin FAD Days**: The owner can designate additional FAD days through `proposeAddFadDays()` / `proposeRemoveFadDays()` for FX market holidays such as Christmas or New Year. On those days the oracle is assumed offline, so staleness relaxes to `fadMaxStaleness` and MEV checks are bypassed to preserve close liveness at the last valid oracle price.

**Deleverage Runway**: Admin holidays do not have the natural weekend runway (Friday 19:00-22:00). `fadRunwaySeconds` (default 3 hours, max 24 hours, configurable through `proposeFadRunway()`) triggers `isFadWindow()` before midnight when the next day is an admin FAD day. During the runway, close-only mode and elevated margins apply while the oracle remains live with normal staleness and MEV checks, giving keepers time to liquidate over-leveraged positions before midnight freeze.

## Fee Structure

| Fee | Rate | Source |
|-----|------|--------|
| Execution Fee | 4 bps (0.04%) | Charged on notional size at open/close |

Open and close execution fees accrue to protocol revenue and are withdrawn by the owner via `withdrawFees()`. Keeper execution is compensated separately through reserved router order bounties.

## Governance

### 48-Hour Timelock

All admin parameter changes follow a **propose -> wait 48 hours -> finalize** pattern:

1. **Propose**: Owner calls `proposeX(newValue)` — stores the pending value and sets `activationTime = now + 48h`
2. **Wait**: The 48-hour delay gives users and monitoring systems time to react (exit positions, withdraw LP capital)
3. **Finalize**: After 48 hours, owner calls `finalizeX()` — applies the pending value and clears the proposal
4. **Cancel**: Owner can call `cancelXProposal()` at any time to abort a pending change

Timelocked parameters:

| Contract | Parameters |
|----------|-----------|
| CfdEngine | `riskParams`, `fadDayOverrides`, `fadMaxStaleness`, `fadRunwaySeconds`, `engineMarkStalenessLimit` |
| HousePool | `seniorRateBps`, `markStalenessLimit` |
| OrderRouter | `maxOrderAge`, `orderExecutionStalenessLimit`, `liquidationStalenessLimit` |
| MarginClearinghouse | none after one-time `setEngine(address)` |

**Not timelocked** (instant): one-time setters (`setVault`, `setOrderRouter`, `setEngine`, etc.), `withdrawFees`, `pause`/`unpause`, ownership transfer.

### Emergency Pause

The protocol includes an instant circuit breaker:

| Contract | Paused Actions | Always Active |
|----------|---------------|---------------|
| OrderRouter | `commitOrder` | `executeOrder`, `executeLiquidation`, `updateMarkPrice` |
| HousePool | `depositSenior`, `depositJunior` | `withdrawSenior`, `withdrawJunior`, `reconcile` |

Only the owner can pause or unpause. Protective actions (closes, liquidations, withdrawals) are never blocked.

## Key Constants

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maintMarginBps` | 100 (1%) | Maintenance margin requirement |
| `initMarginBps` | 150 (1.5%) | Initial margin requirement configured explicitly in risk params |
| `fadMarginBps` | 300 (3%) | FAD window maintenance margin |
| `baseCarryBps` | 500 (5%) | Reserved for future LP-capital carry design; inactive in current no-funding baseline |
| `bountyBps` | 15 (0.15%) | Liquidation keeper bounty |
| `minBountyUsdc` | 5,000,000 ($5) | Keeper bounty floor |
| `vpiFactor` | WAD-scaled | VPI severity `k` |
| `maxSkewRatio` | 0.40e18 (40%) | Hard skew cap |
| IMR | `initMarginBps` | Initial margin requirement |
| Execution fee | 4 bps (0.04%) | Protocol fee charged on notional at open/close |
| Open execution bounty | 0.05 USDC to 1.00 USDC | Reserved at commit based on notional |
| Close execution bounty | 1.00 USDC | Reserved at commit as router-custodied escrow |
| Normal oracle staleness | 60s | Max Pyth price age for execution and mark refresh |
| Liquidation oracle staleness | 15s | Max Pyth price age for liquidations |
| `engineMarkStalenessLimit` | 60s | Max mark age for engine-side withdraw guard and close bounty backing |
| `markStalenessLimit` | 60s | Max mark age for HousePool reconciliation |
| `DEPOSIT_COOLDOWN` | 1 hour | TrancheVault anti-flash-loan lockup; self-deposits reset cooldown, and meaningful third-party top-ups also reset the recipient cooldown |
| `fadMaxStaleness` | 259,200 (3 days) | Max oracle age during frozen oracle windows |
| `fadRunwaySeconds` | 10,800 (3 hours) | Lookahead for admin FAD day deleverage runway |
| `seniorRateBps` | 800 (8% APY) | Fixed-rate senior tranche yield |

## LP Withdrawal Availability

LP withdrawal limits are a gated accounting flow, not a boolean switch. `TrancheVault.maxWithdraw()` and `maxRedeem()` first enforce holder cooldown and protocol-state gates, then `HousePool` computes reserved capital from protocol liabilities and exposes only tranche-prioritized free USDC that can safely leave the vault.

![LP withdrawal flow](../../assets/diagrams/perps-lp-withdrawal-availability.svg)

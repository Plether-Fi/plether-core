# Plether Perpetuals Engine

Institutional-grade, zero-slippage, bounded synthetic perpetuals. Traders take leveraged directional positions on synthetic assets (plDXY-BULL / plDXY-BEAR) against a tranched USDC House Pool.

## Core Insight: Bounded Solvency

Traditional perpetuals face infinite upside tail risk. Plether's synthetic assets are bounded by a fixed Protocol CAP (`P_bull + P_bear = CAP`), making the maximum payout of any trade deterministic at inception. Before any trade opens, the engine proves that the House Pool holds enough USDC to pay every winner simultaneously — even if the oracle instantly teleports to the extremes. Bad debt to LPs is mathematically impossible.

## Architecture

Five contracts strictly decouple custody, execution, and ledger math to isolate systemic risk.

### I. MarginClearinghouse — The Prime Broker

[`MarginClearinghouse.sol`](MarginClearinghouse.sol)

Universal cross-margin portfolio manager and collateral custodian. Users deposit supported assets (currently USDC). The contract applies Loan-to-Value haircuts via oracles to produce a single **Total Buying Power** metric in 6-decimal USDC.

The Execution Engine never touches raw tokens. It commands the Clearinghouse to `lockMargin()`, `unlockMargin()`, or `seizeAsset()`, preserving user equity and enabling future collateral types without altering CFD math.

### II. HousePool + TrancheVault — The House Pool & Firewall

[`HousePool.sol`](HousePool.sol) · [`TrancheVault.sol`](TrancheVault.sol)

The House Pool is the USDC counterparty backing all trader payouts. It implements a **tranched** structure with senior and junior vaults, each an ERC-4626 share token (`TrancheVault`).

**Withdrawal Firewall**: `maxWithdraw` / `maxRedeem` compute `freeUSDC = totalAssets() - maxSystemLiability`. LPs can only withdraw unencumbered capital. At 100% utilization, capital is temporarily locked to guarantee all active trader payouts.

**Senior High-Water Mark**: A `seniorHighWaterMark` tracks the peak senior principal. After a catastrophic loss impairs senior capital, revenue first restores `seniorPrincipal` to the high-water mark before any surplus flows to junior. This prevents junior from profiting while senior remains impaired. The mark increases additively on deposits, scales proportionally on withdrawals (along with `unpaidSeniorYield`), and a fully wiped senior tranche can be recapitalized from zero without carrying the stale pre-wipeout mark forward. Deposits remain blocked while senior is partially impaired (`0 < seniorPrincipal < seniorHighWaterMark`).

### III. OrderRouter — The MEV Shield & Queue

[`OrderRouter.sol`](OrderRouter.sol)

Two-step asynchronous **Commit-Reveal** intent pipeline:

1. **Commit** — User submits intent (Size, Side, Target Price) and locks margin. The router assigns a strictly sequential `orderId` and logs `block.timestamp`.
2. **Reveal** — Keepers push Pyth price payloads. The router aggregates multiple Pyth FX feeds into a weighted basket price (replicating the spot BasketOracle formula) and verifies the weakest-link `publishTime > commitTimestamp` to defeat oracle latency arbitrage. Supports batched multi-order execution for L2 throughput.

**Basket Oracle**: The router is constructed with parallel arrays of Pyth feed IDs, quantities (18-dec weights summing to 1e18), and base prices (8-dec). `_computeBasketPrice()` loops over feeds, normalizes each to 8 decimals, and computes `Σ (price × quantity) / (basePrice × 1e10)` — identical to the spot BasketOracle. The minimum `publishTime` across all feeds is used for MEV checks, staleness validation, and as the engine's `lastMarkTime` (ensuring mark freshness reflects actual oracle data age, not transaction execution time).

**Slippage Protection**: The execution price is clamped to `CAP_PRICE` before the slippage check, ensuring users see the same price the CfdEngine will actually use. This prevents orders from passing slippage at an oracle price above CAP but executing at the clamped price.

**Un-Brickable FIFO Queue**: Execution enforces `orderId == nextExecuteId`. The Engine call is wrapped in `try/catch` — if a trade breaches slippage or skew caps, it gracefully cancels and advances the queue for 100% protocol liveness. Successful fills pay the keeper in USDC from accrued execution fees, capped at `min(1 bp of notional, 1 USDC)`.

### IV. CfdEngine — The Mathematical Ledger

[`CfdEngine.sol`](CfdEngine.sol)

Core state machine. **Holds zero physical funds.** Receives validated intents, enforces O(1) solvency bounds, handles position mutations, calculates PnL, and instructs the Clearinghouse/HousePool on exactly who to pay.

**Solvency Invariant**: Before opening any trade, the engine proves:

```
vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)
```

Because prices cannot exceed CAP or drop below zero, this single check guarantees full solvency.

### V. CfdMath — The Quantitative Library

[`CfdMath.sol`](CfdMath.sol)

Pure, stateless math library optimized to prevent precision loss. Houses PnL limits, Virtual Price Impact (VPI) equations, and Piecewise Funding curves.

## Market Balancing: The Economic Repulsion Engine

The protocol takes zero physical inventory risk (no auto-hedging on AMMs). It uses path-independent math to financially repel toxic flow and reward Market Makers for healing skew.

### Virtual Price Impact (VPI)

Quadratic formula that charges toxic directional flow and rewards MMs with uncapped rebates:

```
C(S) = 0.5 · k · S² / D
```

`S` = Skew, `D` = Vault Depth, `k` = severity factor. Trade cost = `C(S_post) - C(S_pre)`.

**Wash-Trade Immunity**: Opening and immediately closing yields exactly $0 net VPI. Combined with the flat 6 bps execution fee, wash-trading to farm rebates is guaranteed to be a net loss.

**Depth Manipulation Resistance**: Each position tracks `vpiAccrued` — the cumulative VPI charges and rebates across its lifetime. On close, the engine bounds the VPI so the user can never extract a net rebate greater than what they paid. This stateful approach is immune to depth manipulation: inflating or deflating depth between open and close cannot produce VPI profit because the bound enforces `accruedVpi + closeVpi >= 0`.

### Kinked Convex Funding Curve

Funding rates scale on Skew Ratio (`S/D`) to create extreme urgency before hitting hard limits:

| Zone | Skew Ratio | Rate | Shape |
|------|-----------|------|-------|
| 1 | 0% → 25% | 0 → 15% APY | Linear ramp |
| 2 | 25% → 40% | 15% → 300% APY | Quadratic explosion |

Zone 2 creates a "wall of APY" that forces arbitrageurs to delta-neutralize the pool before the 40% hard cap.

### Continuous Funding Without Loops

Dual `int256` accumulators (`bullFundingIndex`, `bearFundingIndex`) track funding owed per unit of size at 18-decimal (WAD) precision to prevent truncation at short keeper intervals. User funding PnL = `size × (currentIndex - entryIndex) / FUNDING_INDEX_SCALE`. No gas-heavy loops across users.

## Conservative Mark-to-Market

The engine values LP equity using O(1) global accumulators (`globalBullEntryNotional`, `globalBearEntryNotional`, funding indexes). This gives real-time aggregate PnL without iterating positions.

### Per-Side Zero Clamp

The MtM function (`getVaultMtmAdjustment`) computes per-side `PnL + funding` and clamps each side at zero — the vault never recognizes unrealized trader losses as assets:

```
bullTotal = bullPnl + bullFunding
bearTotal = bearPnl + bearFunding

if bullTotal < 0: bullTotal = 0
if bearTotal < 0: bearTotal = 0

return bullTotal + bearTotal
```

The return value represents the vault's aggregate unrealized liability to profitable traders. When traders are losing on net, MtM returns zero rather than a positive vault asset. Realized losses flow through physical USDC transfers (settlements, liquidations) which naturally increase the pool's balance.

**Why not cap at `-totalSideMargin`?** Per-side netting creates phantom vault assets: a profitable position's real liability gets offset against another position's bad debt, even though margins are isolated. Clamping at zero eliminates this class of accounting error entirely.

**Trade-off**: The vault temporarily undercounts its assets when traders owe unrealized funding or have unrealized losses. This is conservative — junior principal may dip temporarily until traders close or are liquidated, at which point physical USDC transfers restore the balance. This is preferable to the alternative where paper profits inflate LP principal and get withdrawn as real USDC.

### Layered Conservatism

Different protocol functions require different levels of conservatism:

| Function | Purpose | Approach | Rationale |
|----------|---------|----------|-----------|
| `_reconcile()` | LP equity valuation | Zero-clamped MtM | Conservative share pricing — vault only counts liabilities, never unrealized gains |
| `getFreeUSDC()` | LP withdrawal limits | Asymmetric (liabilities only) | Cash leaving the vault must exist physically — never offset reserves by uncollected receivables |
| `_getEffectiveAssets()` | Position solvency | Capped symmetric funding | Economic solvency allows counting receivables up to margin cap |

The junior tranche naturally absorbs any realized bad debt through the existing reconciliation waterfall — no insurance fund or ADL mechanism is needed.

## Risk Management & Liquidations

### Opposing Position Restriction

An `accountId` can only hold one directional state per market. Opening an opposing side requires explicitly closing the existing position first, preventing capacity griefing (locking up vault liability for free with offsetting positions).

### Minimum Position Size

Positions must be large enough that their proportional keeper bounty (`notional × bountyBps`) meets the `minBountyUsdc` floor. This guarantees keepers are always incentivized to liquidate, regardless of position size. Partial closes that would leave a remaining position with `margin < minBountyUsdc` are rejected to prevent unliquidatable dust.

### Proportional Liquidations

- **Keeper Bounty**: 0.15% of notional size, bounded by a $5 floor. Capped at equity when positive, at `posMargin` when negative (vault never pays more than it seizes)
- **Residual Equity Preserved**: The protocol seizes only the exact mathematical loss + keeper bounty; remaining cross-margin equity is returned to the user
- **Bad Debt Socialization**: If user equity is negative (extreme slippage), the House Pool absorbs the shortfall as a systemic insurance cost
- **Graceful Self-Close**: Voluntary closes on underwater positions seize available balance and let the vault absorb any shortfall, rather than reverting

### Friday Auto-Deleverage (FAD)

FX markets close on weekends. Sunday re-opens feature violent price gaps that blow past leverage buffers.

| Window | MMR | Max Leverage |
|--------|-----|-------------|
| Normal | 1.0% | 100x |
| FAD (Fri 19:00 UTC -> Sun 22:00 UTC) | 3.0% | 33x |

Traders over 33x leverage must deposit margin before Friday evening, or keepers liquidate them while Friday oracle prices are still active, neutralizing weekend gap risk.

**Two-State Oracle Model**: The router separates two distinct states to avoid conflating risk management with oracle availability:

1. **FAD window** (`isFadWindow()`, Friday 19:00 UTC+): Enforces **close-only mode** and elevated margins. Open orders are rejected. MEV and staleness checks remain at normal thresholds (60s/15s) since Pyth FX feeds are still publishing until ~22:00 UTC.
2. **Oracle frozen** (`_isOracleFrozen()`, Friday 22:00 → Sunday 21:00 UTC): Relaxes staleness to `fadMaxStaleness` (default 3 days) and bypasses MEV `commitTime` check, since Pyth FX feeds have stopped and prices are genuinely frozen. Asymmetric DST-safe thresholds: Friday uses 22:00 UTC (latest possible close) to avoid freezing while markets may still be open; Sunday uses 21:00 UTC (earliest possible open) to restore MEV protection as soon as markets could resume. In winter, the 21:00 unfreeze causes a safe 1-hour liveness drop (60s staleness rejects the ~47h-old price).

This prevents the Friday 19:00-22:00 gap from being exploitable -- during this period, markets are open and prices are moving, so full MEV protection is required even though close-only mode is active.

**Admin FAD Days**: The protocol owner can designate additional FAD days via `proposeAddFadDays()` / `proposeRemoveFadDays()` for FX market holidays (e.g., Christmas, New Year). On admin days the oracle is assumed offline, so staleness relaxes to `fadMaxStaleness` and MEV checks are bypassed.

**Deleverage Runway**: Admin holidays lack the natural 3-hour runway that weekends get (Friday 19:00→22:00). To compensate, `fadRunwaySeconds` (default 3 hours, max 24 hours, configurable via `proposeFadRunway()`) triggers `isFadWindow()` N seconds before midnight when the next day is an admin FAD day. During the runway, close-only mode and elevated margins are enforced while the oracle remains live with normal staleness and MEV checks — giving keepers time to liquidate over-leveraged positions before the oracle freezes at midnight.

## Fee Structure

| Fee | Rate | Source |
|-----|------|--------|
| Execution Fee | 6 bps (0.06%) | Charged on notional size at open/close |
| Funding | Variable | Majority side pays the minority side proportional to unhedged skew |

Accumulated fees are withdrawn by the protocol owner via `withdrawFees()`.

## Governance

### 48-Hour Timelock

All admin parameter changes follow a **propose → wait 48 hours → finalize** pattern:

1. **Propose**: Owner calls `proposeX(newValue)` — stores the pending value and sets `activationTime = now + 48h`
2. **Wait**: The 48-hour delay gives users and monitoring systems time to detect the change and react (exit positions, withdraw LP capital)
3. **Finalize**: After 48 hours, owner calls `finalizeX()` — applies the pending value and clears the proposal
4. **Cancel**: Owner can call `cancelXProposal()` at any time to abort a pending change

Timelocked parameters:

| Contract | Parameters |
|----------|-----------|
| CfdEngine | `riskParams`, `fadDayOverrides`, `fadMaxStaleness`, `fadRunwaySeconds` |
| HousePool | `seniorRateBps`, `markStalenessLimit` |
| OrderRouter | `maxOrderAge` |
| MarginClearinghouse | operator status, withdraw guard, asset configs (LTV, oracle) |

**Not timelocked** (instant): one-time setters (`setVault`, `setOrderRouter`, etc.), `withdrawFees`, `pause`/`unpause`, ownership transfer.

### Emergency Pause

The protocol includes an instant circuit breaker for incident response:

| Contract | Paused Actions | Always Active |
|----------|---------------|---------------|
| OrderRouter | `commitOrder` | `executeOrder`, `executeLiquidation`, `updateMarkPrice` |
| HousePool | `depositSenior`, `depositJunior` | `withdrawSenior`, `withdrawJunior`, `reconcile` |

Only the owner can pause/unpause. Protective actions (closes, liquidations, withdrawals) are never blocked.

## Key Constants

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maintMarginBps` | 100 (1%) | Maintenance margin requirement |
| `fadMarginBps` | 300 (3%) | FAD window maintenance margin |
| `bountyBps` | 15 (0.15%) | Liquidation keeper bounty |
| `minBountyUsdc` | 5,000,000 ($5) | Keeper bounty floor |
| `vpiFactor` | WAD-scaled | VPI severity `k` |
| `kinkSkewRatio` | 0.25e18 (25%) | Funding curve inflection point |
| `maxSkewRatio` | 0.40e18 (40%) | Hard skew cap |
| `baseApy` | 0.15e18 (15%) | Funding rate at kink |
| `maxApy` | 3.00e18 (300%) | Funding rate at wall |
| IMR | 1.5× MMR (1.5%) | Initial margin requirement |
| Execution fee | 6 bps (0.06%) | Charged on notional at open/close |
| Normal oracle staleness | 60s | Max Pyth price age for execution |
| Liquidation oracle staleness | 15s | Max Pyth price age for liquidations |
| `markStalenessLimit` | 120s | Max mark age for HousePool reconciliation |
| `DEPOSIT_COOLDOWN` | 1 hour | TrancheVault anti-flash-loan lockup; third-party deposits to existing holders are rejected |
| `fadMaxStaleness` | 259,200 (3 days) | Max oracle age during frozen oracle windows |
| `fadRunwaySeconds` | 10,800 (3 hours) | Lookahead for admin FAD day deleverage runway |
| `seniorRateBps` | 800 (8% APY) | Fixed-rate senior tranche yield |

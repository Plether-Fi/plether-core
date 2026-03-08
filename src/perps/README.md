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

### III. OrderRouter — The MEV Shield & Queue

[`OrderRouter.sol`](OrderRouter.sol)

Two-step asynchronous **Commit-Reveal** intent pipeline:

1. **Commit** — User submits intent (Size, Side, Target Price) and locks margin. The router assigns a strictly sequential `orderId` and logs `block.timestamp`.
2. **Reveal** — Keepers push Pyth price payloads. The router verifies `publishTime > commitTimestamp` to defeat oracle latency arbitrage. Supports batched multi-order execution for L2 throughput.

**Un-Brickable FIFO Queue**: Execution enforces `orderId == nextExecuteId`. The Engine call is wrapped in `try/catch` — if a trade breaches slippage or skew caps, it gracefully cancels and refunds the user, incrementing the queue for 100% protocol liveness.

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

### Kinked Convex Funding Curve

Funding rates scale on Skew Ratio (`S/D`) to create extreme urgency before hitting hard limits:

| Zone | Skew Ratio | Rate | Shape |
|------|-----------|------|-------|
| 1 | 0% → 25% | 0 → 15% APY | Linear ramp |
| 2 | 25% → 40% | 15% → 300% APY | Quadratic explosion |

Zone 2 creates a "wall of APY" that forces arbitrageurs to delta-neutralize the pool before the 40% hard cap.

### Continuous Funding Without Loops

Dual `int256` accumulators (`bullFundingIndex`, `bearFundingIndex`) track "USDC owed per 1 unit of size." User funding PnL = `size × (currentIndex - entryIndex)`. No gas-heavy loops across users.

## Risk Management & Liquidations

### Opposing Position Restriction

An `accountId` can only hold one directional state per market. Opening an opposing side requires explicitly closing the existing position first, preventing capacity griefing (locking up vault liability for free with offsetting positions).

### Proportional Liquidations

- **Keeper Bounty**: 0.15% of notional size, bounded by a $5 floor for L2 gas profitability
- **Residual Equity Preserved**: The protocol seizes only the exact mathematical loss + keeper bounty; remaining cross-margin equity is returned to the user
- **Bad Debt Socialization**: If user equity is negative (extreme slippage), the House Pool absorbs the shortfall as a systemic insurance cost

### Friday Auto-Deleverage (FAD)

FX markets close on weekends. Sunday re-opens feature violent price gaps that blow past leverage buffers.

| Window | MMR | Max Leverage |
|--------|-----|-------------|
| Normal | 1.0% | 100x |
| FAD (Fri 19:00 UTC → Sun 22:00 UTC) | 3.0% | 33x |

Traders over 33x leverage must deposit margin before Friday evening, or keepers liquidate them while Friday oracle prices are still active, neutralizing weekend gap risk.

## Fee Structure

| Fee | Rate | Source |
|-----|------|--------|
| Execution Fee | 6 bps (0.06%) | Charged on notional size at open/close |
| Funding | Variable | Majority side pays the minority side proportional to unhedged skew |

Accumulated fees are withdrawn by the protocol owner via `withdrawFees()`.

## Contract Map

```
src/perps/
├── CfdEngine.sol              # Core state machine & solvency math
├── CfdMath.sol                # Pure math: PnL, VPI, Funding curves
├── CfdTypes.sol               # Shared structs: Position, Order, RiskParams
├── HousePool.sol              # USDC counterparty pool (senior/junior tranches)
├── MarginClearinghouse.sol    # Cross-margin collateral manager
├── OrderRouter.sol            # MEV-resistant commit-reveal order queue
├── TrancheVault.sol           # ERC-4626 share token per tranche
└── interfaces/
    ├── ICfdEngine.sol
    ├── ICfdVault.sol
    ├── IHousePool.sol
    └── IMarginClearinghouse.sol
```

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

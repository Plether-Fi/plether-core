# Options Module

Fully-collateralized covered call vaults for Plether synthetic assets. The module combines a clearinghouse (MarginEngine), an automated auction vault (PletherDOV), and lightweight option tokens (OptionToken) to create weekly covered call strategies on splDXY-BEAR and splDXY-BULL.

## Architecture

```
Retail Users                    Market Makers
    |                                |
    | deposit USDC                   | fill auction (pay USDC premium)
    v                                v
+-----------+    create/mint    +---------------+    settle/exercise    +------------------+
| PletherDOV| ───────────────> | MarginEngine  | <─────────────────── | Option Holders   |
| (Vault)   | <─────────────── | (Clearinghouse)| ──────────────────> | (Market Makers)  |
+-----------+  unlock collat.  +---------------+    share payout       +------------------+
    |                                |
    | holds splDXY shares            | deploys per-series
    v                                v
+-------------+              +-------------+
| StakedToken |              | OptionToken |
| (ERC4626)   |              | (EIP-1167)  |
+-------------+              +-------------+
```

## Contracts

### MarginEngine

Core clearinghouse that enforces 100% margin and fractional in-kind settlement.

**Series lifecycle:**

1. **Create** — A `SERIES_CREATOR_ROLE` holder (the DOV) deploys a new OptionToken proxy via EIP-1167 and registers the series with a strike, expiry, and side (bull/bear).

2. **Mint** — The series creator locks splDXY shares as collateral and receives option tokens 1:1 against the underlying asset capacity. `previewWithdraw()` determines the exact shares needed, accounting for the ERC4626 exchange rate.

3. **Settle** — Anyone can settle after expiry by providing Chainlink round hints. The SettlementOracle looks up historical prices at the exact expiry timestamp. The current share-to-asset exchange rate is locked at this moment (`settlementShareRate`), ensuring all subsequent payouts use a consistent conversion.

4. **Exercise** — Option holders burn tokens to claim their fractional payout within a 90-day window. Payout math: `assetPayout = amount * (price - strike) / price`, converted to shares at the locked settlement rate. A per-series pro-rata cap prevents cross-series drain under negative yield.

5. **Unlock** — The writer reclaims residual collateral. Global debt is calculated as if 100% of options were exercised, then allocated proportionally to each writer's minted amount. A pool safety cap ensures no writer can extract more than their proportional share of the non-debt pool.

6. **Sweep** — After 90 days, the admin recovers shares reserved for unexercised ITM options.

**Early acceleration:** If the SyntheticSplitter liquidates mid-cycle (price >= CAP), settlement can happen immediately. BEAR options settle at CAP (full profit), BULL options settle at 0.

**Admin fallback:** `adminSettle()` provides oracle failure recovery with a mandatory 2-day grace period.

### PletherDOV

Automated covered call vault that runs weekly epochs with Dutch auctions.

**State machine:** `UNLOCKED -> AUCTIONING -> LOCKED -> UNLOCKED`

**Epoch flow:**

1. **UNLOCKED** — Retail users queue USDC deposits. The keeper converts USDC to splDXY (external zap), calculates available collateral, creates a MarginEngine series, mints options, and starts a Dutch auction with configurable premium bounds and duration.

2. **AUCTIONING** — Option price decays linearly from `maxPremium` to `minPremium` over the auction window. A market maker calls `fillAuction()` at their desired price, paying USDC premium and receiving all option tokens. The vault transitions to LOCKED.

3. **LOCKED** — Options are held by the market maker until expiry. The keeper calls `settleEpoch()` which settles the series on the MarginEngine and unlocks the DOV's residual collateral. The vault returns to UNLOCKED for the next epoch.

**Cancellation path:** If no market maker fills the auction before it expires (or the splitter liquidates), `cancelAuction()` returns the vault to UNLOCKED. The DOV can then exercise its unsold options (if ITM) and reclaim collateral via separate calls.

**Deposit queue:** Per-user deposits are tracked by epoch. Once `startEpochAuction()` processes deposits into collateral, they cannot be withdrawn. New deposits in subsequent epochs reset stale balances.

### OptionToken

Minimal ERC20 deployed as an EIP-1167 proxy for each series. Only the MarginEngine can mint and burn. No yield, no staking — purely represents the option contract. The implementation contract's constructor sets `_initialized = true` to prevent direct initialization.

## Settlement Math

The system uses **fractional in-kind settlement**: payouts are denominated in splDXY shares, not USDC.

```
Exercise payout (assets):  optionsAmount * (settlementPrice - strike) / settlementPrice
Convert to shares:         assetPayout * oneShare / settlementShareRate
Pro-rata cap:              optionsAmount * totalSeriesShares / totalSeriesMinted

Writer residual:           lockedShares - (globalDebtShares * writerOptions / totalMinted)
Pool safety cap:           (totalShares - globalDebtShares) * lockedShares / totalShares
```

Locking the exchange rate at settlement ensures economic correctness: all exercisers receive the same $/share conversion regardless of when they exercise within the 90-day window.

## Security Model

| Mechanism | Purpose |
|-----------|---------|
| 100% margin | Collateral always covers max payout — no insolvency risk |
| Single writer per series | `seriesCreator` restriction eliminates multi-writer edge cases |
| Per-series collateral pools | Prevents negative yield in one series from draining another |
| Pool safety cap | Bounds `unlockCollateral` returns during negative yield scenarios |
| Settlement rate locking | Prevents oracle/rate manipulation during the 90-day exercise window |
| ReentrancyGuard | All state-mutating functions with external calls |
| AccessControl | Series creation, admin settle, unclaimed sweep |
| 2-day admin settle delay | Gives the oracle time to recover before manual intervention |

## Decimal Reference

| Component | Decimals |
|-----------|----------|
| USDC / auction premium | 6 |
| Option tokens (plDXY underlying) | 18 |
| splDXY shares (StakedToken) | 21 (ERC4626 `_decimalsOffset=3`) |
| Oracle / strike / settlement price | 8 |
| Dutch auction premium calc | `options(18) * premium(6) / 1e18 = USDC(6)` |

# Security Assumptions & Known Limitations — Perpetuals Engine

This document outlines the security assumptions, trust model, known limitations, and emergency procedures for the Plether Perpetuals Engine.

## Upgradeability

All perpetuals contracts are **non-upgradeable**. Once deployed, the bytecode cannot be changed.

- **No proxy patterns**: No UUPS, Transparent, or Beacon proxies
- **Immutable logic**: Contract behavior is fixed at deployment
- **Immutable parameters**: `CAP_PRICE`, `USDC` address, oracle feed IDs, basket weights, and base prices are set at construction

**Mutable admin state:**

| Parameter | Contract | Guard |
|-----------|----------|-------|
| `riskParams` (VPI, funding curve, margins, bounty) | CfdEngine | `onlyOwner` — no timelock |
| `fadDayOverrides` | CfdEngine | `onlyOwner` |
| `fadMaxStaleness` | CfdEngine | `onlyOwner`, must be > 0 |
| `fadRunwaySeconds` | CfdEngine | `onlyOwner`, max 24 hours |
| `seniorRateBps` | HousePool | `onlyOwner` — no timelock |
| Supported assets / LTV haircuts | MarginClearinghouse | `onlyOwner` |
| Protocol operators | MarginClearinghouse | `onlyOwner` |

**One-time setters** (cannot be changed after initial configuration):

| Setter | Contract |
|--------|----------|
| `setVault(address)` | CfdEngine |
| `setOrderRouter(address)` | CfdEngine |
| `setSeniorVault(address)` | HousePool |
| `setJuniorVault(address)` | HousePool |
| `setOrderRouter(address)` | HousePool |

## Protocol Invariants

These properties must always hold. Violation indicates a critical bug.

### Solvency Invariants

| Invariant | Description |
|-----------|-------------|
| **Vault Solvency** | `vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)` — the House Pool can always pay every winner simultaneously |
| **Bounded Payout** | No trade's maximum profit exceeds `size × CAP_PRICE / USDC_TO_TOKEN_SCALE` — payouts are deterministic at inception |
| **Withdrawal Firewall** | `freeUSDC = balance - max(bullMaxProfit, bearMaxProfit) - accumulatedFees` — LPs cannot withdraw encumbered capital |
| **Senior High-Water Mark** | After a loss impairs `seniorPrincipal`, revenue restores it to `seniorHighWaterMark` before any surplus flows to junior. Proportionally adjusted on withdrawals, reset to 0 on full wipeout |

### Position Invariants

| Invariant | Description |
|-----------|-------------|
| **Single Direction** | An `accountId` holds at most one directional position (BULL or BEAR). Opening the opposite side requires closing first |
| **Minimum Notional** | Every position's notional × `bountyBps` >= `minBountyUsdc × 10,000` — keeper bounty is always economically viable |
| **Margin Sufficiency** | `pos.margin >= IMR` after every open, where `IMR = max(1.5 × MMR, minBountyUsdc)` |
| **FIFO Execution** | `orderId == nextExecuteId` — orders execute in strict commitment sequence |

### Funding Invariants

| Invariant | Description |
|-----------|-------------|
| **Zero-Sum Funding** | `bullFundingIndex` and `bearFundingIndex` move symmetrically — majority side pays, minority side receives |
| **No Silent Drain** | If funding debt exceeds margin on an open order, the engine reverts with `FundingExceedsMargin` (position must be liquidated instead) |

### Clearinghouse Invariants

| Invariant | Description |
|-----------|-------------|
| **Balance Integrity** | `balances[accountId][asset]` always equals actual tokens attributable to that account |
| **Withdrawal Guard** | Users can only withdraw if `remainingEquity >= lockedMarginUsdc` |
| **Seizure Bound** | `seizeAsset` reverts if `balances < amount` (no negative balances) |

## Trust Assumptions

### External Protocol Dependencies

#### Pyth Network (FX Price Feeds)

- **Assumption**: Pyth provides accurate, timely price data for all basket FX pairs (EUR/USD, JPY/USD, GBP/USD, CAD/USD, SEK/USD, CHF/USD)
- **Architecture**: OrderRouter aggregates multiple Pyth feeds into a weighted basket price replicating the spot BasketOracle formula
- **Mitigation (MEV)**: Commit-Reveal pipeline with `publishTime > commitTime` check defeats oracle latency arbitrage
- **Mitigation (Staleness)**: 60s max age for order execution, 15s for liquidations. Relaxed to `fadMaxStaleness` (default 3 days) during frozen oracle windows
- **Mitigation (Negative/Zero)**: `_normalizePythPrice` reverts on non-positive prices; `_computeBasketPrice` reverts if basket sum is zero
- **Risk (Weekend Gaps)**: Pyth FX feeds stop publishing Friday ~22:00 UTC. The two-state oracle model (FAD window vs oracle frozen) handles this explicitly
- **Risk (Feed Compromise)**: If any single Pyth feed is compromised, the basket price is affected proportionally to that feed's weight. The weakest-link `minPublishTime` prevents selective staleness attacks
- **Risk (Exponent Variation)**: Different Pyth feeds may use different exponents. `_normalizePythPrice` normalizes all to 8 decimals but truncates on scale-down

#### USDC (Circle)

- **Assumption**: USDC maintains its $1 peg and operates as a standard ERC-20 token
- **Risk (Blacklisting)**: Circle can blacklist addresses. If the HousePool, MarginClearinghouse, or TrancheVault contracts are blacklisted, the protocol cannot process payouts or withdrawals
- **Risk (Upgradeability)**: USDC is an upgradeable proxy. Circle could modify transfer logic or add fees
- **Risk (Fee-on-Transfer)**: MarginClearinghouse uses balance-before/after for deposits to correctly handle fee-on-transfer tokens. HousePool and TrancheVault assume standard ERC-20 transfers
- **Mitigation**: None. These are fundamental risks of using USDC as collateral

### External Library Dependencies

#### OpenZeppelin Contracts

- **Assumption**: OpenZeppelin's implementations of ERC20, ERC4626, Ownable2Step, ReentrancyGuard, and SafeERC20 are secure
- **Mitigation**: Pinned versions; OpenZeppelin is the most widely audited Solidity library
- **Usage**: CfdEngine (Ownable2Step, ReentrancyGuard), TrancheVault (ERC4626), MarginClearinghouse (Ownable2Step, SafeERC20)

### Internal Trust Model

#### Owner/Admin Role

The protocol owner can:
- Adjust all risk parameters (`vpiFactor`, funding curve, margin BPS, bounty) — **no timelock**
- Add/remove FAD day overrides for FX market holidays
- Configure `fadMaxStaleness` and `fadRunwaySeconds`
- Set the senior tranche interest rate
- Add supported collateral assets and configure LTV haircuts
- Grant/revoke operator status on the MarginClearinghouse
- Withdraw accumulated execution fees to any recipient
- Transfer ownership (via Ownable2Step two-step pattern)

The owner **cannot**:
- Change `CAP_PRICE` after deployment
- Change the OrderRouter, HousePool, or TrancheVault addresses after initial setup
- Directly mint, burn, or move user margin
- Bypass the solvency invariant (fee withdrawal checks post-solvency)
- Modify oracle feed IDs, weights, or base prices (immutable in OrderRouter constructor)

**Risk (No Timelock)**: Risk parameter changes take effect immediately. A malicious or compromised owner could set extreme VPI factors, funding rates, or margin requirements that adversely affect open positions. Users must trust the owner or monitor parameter changes via events.

#### Keepers

Keepers are permissionless — anyone can execute orders and liquidations:
- **Order Execution**: Keepers push Pyth price payloads and receive ETH incentive fees attached to orders
- **Liquidation**: Keepers trigger liquidations and receive USDC bounties from the vault
- **MEV Protection**: Commit-Reveal prevents keepers from seeing user intent before committing oracle prices
- **Cancel Refunds**: When orders are cancelled for MEV/staleness reasons, the keeper fee is refunded to the user (not the keeper), preventing keeper griefing

#### Protocol Operators

The CfdEngine and OrderRouter are granted operator status on the MarginClearinghouse. Operators can:
- Lock/unlock margin on user accounts
- Settle USDC (credit or debit balances)
- Seize assets from accounts (for losses, fees, and bad debt)

Operators **cannot**:
- Withdraw user funds to arbitrary addresses (seizure requires a `recipient` parameter, always `address(vault)` in practice)
- Create negative balances (seizure reverts if balance insufficient)

## Known Limitations

### Oracle Edge Cases

#### Price at or Above CAP

- **Behavior**: CfdEngine clamps `currentOraclePrice` to `CAP_PRICE` in both `processOrder` and `liquidatePosition`. OrderRouter clamps before slippage check.
- **Impact**: BEAR positions hit maximum profit; BULL positions hit maximum loss. The protocol is solvent by construction at CAP.
- **Limitation**: If the oracle price genuinely exceeds CAP for extended periods, BEAR traders cannot capture additional upside beyond CAP.

#### Basket Price Truncation

- **Behavior**: `_computeBasketPrice()` computes `Σ (price × quantity) / (basePrice × 1e10)`. Each term truncates independently.
- **Impact**: With 6 feeds, cumulative truncation error is at most 6 wei in 8-decimal space (~$0.00000006). Negligible for all practical purposes.

### Funding Precision

Funding accumulators use 18-decimal precision (WAD). At extreme low values:
- `fundingDelta = (annRate × timeDelta) / SECONDS_PER_YEAR` — at 0.01% APY with 1-second blocks, this is ~3.17e5 (non-zero)
- `step = (price × fundingDelta) / 1e8` — with price=1e8, step=3.17e5 per second. Accumulates correctly.
- **Lower bound**: Funding truncates to zero only when `annRate × timeDelta < SECONDS_PER_YEAR / price`, which at $1.00 means annRate × timeDelta < 315. At 12s blocks, this requires annRate < 26, i.e., < 2.6e-17 APY. Practically unreachable.

### Liquidation Mechanics

#### Keeper Bounty Capping

The bounty is calculated as `max(notional × bountyBps, minBountyUsdc)`, then capped:
- **Positive equity**: Capped at `uint256(equityUsdc)` — keeper cannot extract more than the position's equity
- **Negative equity**: Capped at `posMargin` — vault only pays what it can seize back, never a net payer

This means keepers may receive less than `minBountyUsdc` when equity is small but positive. The minimum position size guard ensures this gap is bounded: at the threshold ($3,333 notional), the proportional bounty equals `minBountyUsdc`, so the cap only binds when PnL has eroded equity.

#### Bad Debt Socialization

When a position goes underwater (equity < 0):
- **Liquidation**: Vault seizes all position margin + available free USDC from clearinghouse. Remaining deficit is absorbed as bad debt by the House Pool.
- **Self-Close**: `_processDecrease` seizes `min(available, owed)` from the user. Any shortfall is absorbed by the vault.
- **Risk**: Sustained bad debt erodes LP capital. The funding curve's "wall of APY" at 40% skew is designed to prevent this by forcing deleveraging before extremes.

#### No Partial Liquidation

- **Behavior**: `liquidatePosition` always closes the entire position
- **Impact**: Users with large positions face all-or-nothing liquidation. No opportunity to partially reduce and restore margin requirements.
- **Rationale**: Simplifies accounting and prevents liquidation gaming (partially closing to reduce notional while keeping the riskiest portion open)

### VPI (Virtual Price Impact)

#### Liquidation Skips VPI

- **Behavior**: `liquidatePosition` does not compute or charge VPI. Only voluntary opens and closes include VPI in their cost/rebate.
- **Impact**: The vault misses the VPI charge that would be applied on a voluntary close. For MM positions that earned a rebate at open, the vault doesn't recover the matching charge at liquidation.
- **Mitigation**: VPI rebates at open are locked into `pos.margin` via `netMarginChange`. When the position is liquidated, margin is seized back to the vault, partially recovering the rebate. The net leakage is bounded by the VPI charge at close, which is typically small relative to the position.
- **Rationale**: Computing VPI during liquidation adds complexity and gas. In bad-debt liquidations, the user can't pay the VPI charge anyway, so it would only increase the deficit.

#### Depth Sensitivity

- **Behavior**: VPI uses live `vault.totalAssets()` as depth `D` at both open and close. If vault depth changes between open and close, the VPI charge/rebate differs.
- **Impact**: MMs opening when the vault is small (earning large rebates) and closing when the vault is large (paying small charges) net a small profit from VPI alone.
- **Mitigation**: This is symmetric risk — vault depth could also decrease between open and close, increasing the VPI charge. The MM bears directional risk during the holding period. The effect is bounded by vault depth volatility over the position's lifetime.

### FAD (Friday Auto-Deleverage) Edge Cases

#### DST Transitions

- **Behavior**: FAD window uses fixed UTC thresholds. Oracle frozen uses asymmetric thresholds: Friday 22:00 UTC (latest possible FX close) and Sunday 21:00 UTC (earliest possible FX open).
- **Impact (Winter)**: The 21:00 Sunday unfreeze causes a ~1-hour liveness gap where 60s staleness rejects the ~47-hour-old frozen price. Orders submitted during this gap will fail until fresh prices arrive.
- **Rationale**: Safe failure mode — no trades execute on stale prices. Liveness resumes within minutes of market open.

#### Admin FAD Days Without Runway

- **Behavior**: Admin holidays lack the natural 3-hour deleverage runway (Friday 19:00→22:00). `fadRunwaySeconds` provides this synthetically.
- **Risk**: If `fadRunwaySeconds` is set to 0, keepers have no time to liquidate over-leveraged positions before the oracle freezes on admin FAD days.
- **Mitigation**: Default `fadRunwaySeconds = 3 hours`. Owner can increase up to 24 hours.

### Clearinghouse Limitations

#### V1: USDC-Only Cross-Margin

- **Behavior**: While `MarginClearinghouse` supports multiple asset types with LTV haircuts, the CfdEngine exclusively uses USDC for all margin operations (`lockMargin`, `seizeAsset`, `settleUsdc`).
- **Impact**: Non-USDC collateral types can be deposited and contribute to buying power, but seizure calls target only USDC. If a user's USDC balance is insufficient but they hold other assets, `seizeAsset` reverts.
- **Planned**: V2 will add fallback logic in `seizeAsset` to sell non-USDC collateral.

#### No Oracle Staleness in Clearinghouse

- **Behavior**: `getAccountEquityUsdc()` calls `IAssetOracle.getPriceUnsafe()` with no staleness validation.
- **Impact**: If an asset oracle stops updating, the clearinghouse continues valuing it at the stale price, potentially overvaluing collateral.
- **Mitigation**: V1 uses only USDC with `oracle = address(0)` (1:1 pricing, no oracle needed). Future multi-asset support must add staleness checks.

### TrancheVault Limitations

#### Deposit Cooldown

- **Behavior**: 1-hour cooldown after depositing prevents same-block or near-block withdrawal.
- **Impact**: Users cannot deposit and immediately withdraw, even if the vault's share price has not changed.
- **Rationale**: Prevents share price manipulation via flash loans or MEV sandwich attacks on LP deposits.

#### No Emergency Pause

- **Behavior**: TrancheVault and HousePool have no pause mechanism.
- **Impact**: If a critical bug is discovered, deposits and withdrawals cannot be halted. The withdrawal firewall (free USDC check) provides the only safety net.
- **Mitigation**: CfdEngine's `processOrder` and `liquidatePosition` are gated by `onlyRouter`, and the OrderRouter is the single entry point. Pausing the keeper infrastructure effectively halts new trades.

### Decimal Handling

| Asset/Oracle | Decimals | Notes |
|--------------|----------|-------|
| USDC | 6 | Collateral token |
| Position Size | 18 | Synthetic token units |
| Oracle Price | 8 | Pyth normalized output |
| Basket Price | 8 | `_computeBasketPrice()` output |
| Funding Index | 18 | WAD precision accumulators |
| PnL | 6 | `size(18) × priceDiff(8) / 1e20 = USDC(6)` |
| Funding PnL | 6 | `size(18) × indexDelta(18) / 1e30 = USDC(6)` |
| TrancheVault Offset | 3 | 1000x inflation attack protection |

### Fee Structure

| Fee | Rate | Notes |
|-----|------|-------|
| Execution Fee | 6 bps (0.06%) | Charged on notional at open and close |
| Funding | Variable | Kinked curve: 0→15% APY (linear), 15%→300% APY (quadratic) |
| Keeper Bounty | 15 bps (0.15%) | Floor: $5 USDC. Paid from vault on liquidation |

Fees are hardcoded (execution = 6 bps, bounty = 15 bps). Funding curve parameters are admin-configurable via `setRiskParams()`.

## Emergency Procedures

### Suspected Oracle Manipulation

1. Owner sets extreme `fadMaxStaleness` (e.g., 1 second) to reject all oracle prices
2. All pending orders fail with staleness errors (FIFO queue still advances)
3. Liquidations also halt (15s staleness threshold)
4. Investigate and restore `fadMaxStaleness` when resolved

### Keeper Infrastructure Failure

1. Orders queue up in the FIFO queue but are not executed
2. No time-based expiry — orders persist until explicitly executed or cancelled
3. Users can continue committing orders (they queue)
4. Resume keeper bots to drain the queue
5. **Risk**: Stale orders may execute at unfavorable prices. Users should use `targetPrice` for slippage protection.

### Extreme Skew

1. The funding curve's quadratic Zone 2 (25%→40% skew) creates a "wall of APY" at up to 300% annualized
2. At 40% skew ratio, no new orders on the majority side are accepted (VPI becomes extremely expensive)
3. If skew persists, owner can adjust `maxSkewRatio` downward to force earlier rejection
4. MMs are financially incentivized to heal skew via VPI rebates

### Bad Debt Cascade

1. Multiple liquidations creating bad debt erode `vault.totalAssets()`
2. The solvency invariant (`vault >= maxLiability`) blocks new opens but allows closes and liquidations
3. LP withdrawals are restricted by the withdrawal firewall
4. If vault is critically depleted, owner should:
   - Set `fadMarginBps` very high (force all positions to be liquidatable)
   - Let keepers clear remaining positions
   - LPs bear losses pro-rata through reduced share value

## Security Contact

For responsible disclosure of security vulnerabilities, please contact:
contact@plether.com

## Audit Status

Not yet audited. The perpetuals engine is pre-deployment.

### Coverage

| Component | Status |
|-----------|--------|
| CfdEngine | Not yet audited |
| CfdMath | Not yet audited |
| OrderRouter | Not yet audited |
| MarginClearinghouse | Not yet audited |
| HousePool | Not yet audited |
| TrancheVault | Not yet audited |

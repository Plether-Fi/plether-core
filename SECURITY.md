# Security Assumptions & Known Limitations

This document outlines the security assumptions, trust model, known limitations, and emergency procedures for the Plether protocol.

## Trust Assumptions

### External Protocol Dependencies

#### Chainlink Oracles
- **Assumption**: Chainlink price feeds provide accurate, timely data for EUR/USD, JPY/USD, GBP/USD, CAD/USD, SEK/USD, and CHF/USD
- **Mitigation**: 8-hour staleness timeout rejects stale data; sequencer uptime check on L2s
- **Risk**: If Chainlink is compromised or all 6 feeds fail simultaneously, minting is blocked but existing positions can still be redeemed

#### Curve Finance
- **Assumption**: Curve pool for USDC/DXY-BEAR operates correctly and provides fair exchange rates
- **Mitigation**: `price_oracle()` deviation check (2% max) prevents price manipulation attacks
- **Risk**: Curve pool manipulation could affect ZapRouter and LeverageRouter swap outcomes; user-provided slippage protects against this

#### Morpho Blue
- **Assumption**: Morpho Blue lending protocol correctly handles collateral, borrows, liquidations, and flash loans
- **Mitigation**: Router contracts validate authorization before operations; flash loan callbacks validate caller and initiator
- **Risk**: Morpho protocol bugs could affect leveraged positions; users must monitor positions independently
- **Note**: Morpho Blue flash loans are fee-free, reducing leverage costs compared to other providers

### Internal Trust Model

#### Owner/Admin Role
The protocol owner can:
- Pause/unpause the SyntheticSplitter (blocks minting, not redemption)
- Pause/unpause router contracts
- Propose adapter migrations (7-day timelock)
- Propose treasury/staking address changes (7-day timelock)
- Rescue stuck tokens (non-core assets only)

The owner **cannot**:
- Freeze user funds permanently (burn always works when active)
- Modify the CAP after deployment
- Change oracle addresses after deployment
- Mint or burn tokens directly

#### Permissionless Operations
Anyone can call:
- `triggerLiquidation()` - settles protocol if oracle price >= CAP
- `harvestYield()` - collects and distributes yield from adapter

#### Timelock Protection
Critical operations require a 7-day timelock:
- Adapter migration (yield strategy change)
- Treasury address change
- Staking address change

This provides users time to exit if they disagree with proposed changes.

## Known Limitations

### Oracle Edge Cases

#### Zero/Negative Oracle Prices
- **Behavior**: OracleLib reverts with `OracleLib__InvalidPrice` on zero or negative prices
- **Impact**: All state-changing operations (mint, burn, liquidation) halt when oracle reports invalid data
- **Rationale**: Operating with broken oracle data could enable arbitrage exploits between oracle price and market price; halting operations is the safer default
- **Note**: The `getSystemStatus()` view function gracefully returns 0 for UI diagnostics without reverting

#### Price Volatility Between Preview and Execution
- **Behavior**: `previewMint()` and `previewBurn()` show expected values at current price
- **Impact**: Actual execution may differ if price changes between preview and execution
- **Rationale**: This is inherent to any DeFi protocol; users should set appropriate slippage

### Liquidation Mechanics

#### Burn During Liquidation
- **Behavior**: Users can burn tokens to redeem USDC even after liquidation triggers
- **Impact**: This is intentional - users should always be able to exit
- **Rationale**: Only minting is blocked during liquidation to prevent new positions

#### No Partial Liquidation
- **Behavior**: When price >= CAP, the entire protocol enters SETTLED state
- **Impact**: All positions are affected equally
- **Rationale**: The CAP represents the theoretical maximum DXY value; exceeding it means the inverse token has zero value

### Minimum/Maximum Amounts

| Operation | Minimum | Maximum | Notes |
|-----------|---------|---------|-------|
| Mint | 1 wei | Unlimited* | *Subject to available USDC liquidity |
| Burn | 1 wei | Token balance | Must burn equal BEAR + BULL |
| Leverage Principal | ~$1 | Unlimited* | *Subject to Morpho liquidity |
| Flash Mint | 1 wei | `maxFlashLoan()` | Per ERC-3156 spec |

### Rounding Behavior

- **Mint**: Rounds UP (favors protocol) - users pay slightly more USDC
- **Burn**: Rounds DOWN (favors protocol) - users receive slightly less USDC
- **Rationale**: Prevents economic exploits from rounding arbitrage

### Buffer Management

- **Local Buffer**: 10% of deposited USDC kept in Splitter for immediate redemptions
- **Adapter Deployment**: 90% deployed to yield adapter
- **Risk**: Large concurrent redemptions may require waiting for adapter withdrawal
- **Mitigation**: Harvest function can be called to rebalance

## Emergency Procedures

### Protocol Pause

**When to pause:**
- Suspected oracle manipulation
- External protocol exploit affecting Plether
- Critical bug discovered

**Effect of pause:**
- Minting blocked
- Burning still allowed (users can always exit)
- Leverage operations blocked

**Unpause procedure:**
1. Identify and fix root cause
2. Verify oracle feeds are healthy
3. Call `unpause()` on affected contracts

### Liquidation Trigger

**Trigger condition:**
- Oracle price >= CAP ($2.00 for DXY)

**How to trigger:**
- Anyone can call `triggerLiquidation()` when oracle reports price >= CAP
- The function reverts if price is below CAP

**Post-liquidation:**
1. Protocol enters SETTLED state
2. Minting permanently disabled
3. Users redeem at fixed CAP rate
4. Any remaining USDC distributed pro-rata

### Emergency Token Rescue

If tokens are accidentally sent to contracts:
1. Identify the stuck token
2. Call `rescueToken(token, recipient)` on the relevant contract
3. Note: Cannot rescue core assets (USDC, DXY-BEAR, DXY-BULL)

### Adapter Migration (Emergency)

If yield adapter is compromised:
1. Pause the Splitter immediately
2. Propose new adapter via `proposeAdapter(newAdapter)`
3. Wait 7-day timelock (cannot be bypassed)
4. Execute migration via `executeAdapterMigration()`
5. Unpause Splitter

**Note:** During the 7-day period, users can continue to redeem existing tokens.

## Security Contact

For responsible disclosure of security vulnerabilities, please contact:
contact@plether.com

## Audit Status

| Component | Auditor | Date | Status |
|-----------|---------|------|--------|
| SyntheticSplitter | - | - | Pending |
| Routers | - | - | Pending |
| Oracles | - | - | Pending |

## Changelog

| Date | Change |
|------|--------|
| 2026-01-03 | Migrated to Morpho Blue as sole flash loan provider (removed Aave/Balancer dependencies) |
| 2025-01-03 | Initial security documentation |

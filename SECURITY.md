# Security Assumptions & Known Limitations

This document outlines the security assumptions, trust model, known limitations, and emergency procedures for the Plether protocol.

## Upgradeability

All Plether contracts are **non-upgradeable**. Once deployed, the bytecode cannot be changed. This provides strong guarantees:

- **No proxy patterns**: No UUPS, Transparent, or Beacon proxies are used
- **Immutable logic**: Contract behavior is fixed at deployment
- **Immutable parameters**: CAP, oracle addresses, and token addresses cannot be changed

The only mutable state is governed by timelocks:
- Adapter address (7-day timelock)
- Treasury/staking addresses (7-day timelock)
- BasketOracle Curve pool (7-day timelock after initial setup)

## Protocol Invariants

These properties must always hold. Violation indicates a critical bug.

### Solvency Invariants

| Invariant | Description |
|-----------|-------------|
| **Collateral Backing** | `totalAssets >= totalLiabilities` where `totalLiabilities = tokenSupply × CAP` |
| **No Value Leak** | `totalAssets <= totalLiabilities + accumulatedYield + dust` (no funds stuck) |
| **Fair Pricing** | Users always pay at least the ceiling-rounded USDC cost (no rounding exploits) |

### Token Invariants

| Invariant | Description |
|-----------|-------------|
| **Supply Parity** | `TOKEN_A.totalSupply == TOKEN_B.totalSupply - emergencyRedeemed` |
| **No Orphaned Tokens** | If `tokenSupply > 0`, then `totalAssets > 0` |
| **Mint/Burn Symmetry** | `currentSupply == totalMinted - totalBurned - totalEmergencyRedeemed` |

### State Invariants

| Invariant | Description |
|-----------|-------------|
| **Liquidation Irreversibility** | Once `isLiquidated == true`, it can never become `false` |
| **Router Statelessness** | Routers hold zero tokens after any operation completes |
| **Self-Reference Prevention** | Treasury and staking addresses are never the Splitter itself |

## Trust Assumptions

### External Protocol Dependencies

#### Chainlink Oracles
- **Assumption**: Chainlink price feeds provide accurate, timely data for EUR/USD, JPY/USD, GBP/USD, CAD/USD, SEK/USD, and CHF/USD
- **Mitigation**: 8-hour staleness timeout rejects stale data; sequencer uptime check on L2s
- **Risk**: If Chainlink is compromised or all 6 feeds fail simultaneously, minting is blocked but existing positions can still be redeemed

#### Curve Finance
- **Assumption**: Curve pool for USDC/plDXY-BEAR operates correctly and provides fair exchange rates
- **Mitigation**: `price_oracle()` deviation check (2% max) prevents price manipulation attacks
- **Risk**: Curve pool manipulation could affect ZapRouter and LeverageRouter swap outcomes; user-provided slippage protects against this

#### Morpho Blue
- **Assumption**: Morpho Blue lending protocol correctly handles collateral, borrows, liquidations, and flash loans
- **Mitigation**: Router contracts validate authorization before operations; flash loan callbacks validate caller and initiator
- **Risk (Bugs)**: Morpho protocol bugs could affect leveraged positions; users must monitor positions independently
- **Risk (Liquidity)**: If Morpho market utilization is high (all supplied USDC is borrowed), adapter withdrawals revert. Burns exceeding the local buffer will fail until Morpho liquidity returns. The `ejectLiquidity()` emergency function is also affected—it cannot withdraw from an illiquid market. Users may be temporarily unable to redeem even if the protocol is solvent.
- **Mitigation (Liquidity)**: Use `withdrawFromAdapter(amount)` for gradual liquidity extraction when the protocol is paused. This allows repeated partial withdrawals as Morpho liquidity becomes available, rather than requiring full withdrawal in a single transaction.
- **Note**: Morpho Blue flash loans are fee-free, reducing leverage costs compared to other providers

#### USDC (Circle)
- **Assumption**: USDC maintains its $1 peg and operates as a standard ERC-20 token
- **Risk (Depeg)**: If USDC depegs significantly, the protocol's collateral value diverges from its nominal value. Users holding plDXY tokens would receive fewer real dollars than expected on redemption.
- **Risk (Blacklisting)**: Circle can blacklist addresses, freezing their USDC balances. If the SyntheticSplitter, MorphoAdapter, or Morpho market contracts are blacklisted, the protocol cannot process redemptions or yield withdrawals.
- **Risk (Upgradeability)**: USDC is an upgradeable proxy contract. Circle could modify transfer logic, add fees, or change behavior in ways that break protocol assumptions.
- **Risk (Regulatory)**: Circle operates under US regulatory oversight. Regulatory action could affect USDC availability or require compliance changes that impact the protocol.
- **Mitigation**: None. These are fundamental risks of using USDC as collateral. Users should understand that the protocol inherits all USDC counterparty risks.
- **Note**: The protocol does not implement USDC depeg detection. If USDC depegs, the protocol continues operating at nominal values.

### External Library Dependencies

#### OpenZeppelin Contracts
- **Assumption**: OpenZeppelin's audited implementations of ERC20, ERC4626, Ownable, Pausable, ReentrancyGuard, and ERC3156 are secure and behave as documented
- **Mitigation**: Using pinned versions; OpenZeppelin is the most widely audited Solidity library with extensive formal verification
- **Risk**: A vulnerability in OpenZeppelin base contracts could affect all inheriting contracts

### Internal Trust Model

#### Owner/Admin Role
The protocol owner can:
- Pause/unpause the SyntheticSplitter (blocks minting, not redemption)
- Pause/unpause router contracts
- Propose adapter migrations (7-day timelock)
- Propose treasury/staking address changes (7-day timelock)
- Propose BasketOracle Curve pool changes (7-day timelock)
- Rescue stuck tokens (non-core assets only)
- Transfer ownership (via Ownable2Step two-step pattern)

The owner **cannot**:
- Freeze user funds permanently (burn always works, even when paused)
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
- BasketOracle Curve pool change (initial setup is immediate)

This provides users time to exit if they disagree with proposed changes.

#### Governance Cooldown
After unpausing the protocol, a 7-day cooldown period must elapse before governance operations (adapter migration, fee receiver changes) can be finalized. This prevents rapid pause/unpause cycles that could bypass timelock protections.

The cooldown is enforced by `_checkLiveness()`:
- Reverts if protocol is paused
- Reverts if `block.timestamp < lastUnpauseTime + 7 days`

#### Adapter Migration Safety

Adapter migrations include two safety mechanisms to prevent fund loss:

| Mechanism | Implementation | Purpose |
|-----------|----------------|---------|
| **Atomic swap** | `yieldAdapter` pointer is never set to null | Prevents view functions from returning incorrect values mid-migration |
| **Loss check** | `assetsAfter >= assetsBefore * 99.999%` | Reverts if total assets decrease by more than 0.1 bps (0.001%) |

The loss check protects against:
- Malicious adapters that steal funds on deposit
- Adapters with excessive entry/exit fees
- Rounding errors that compound during migration

If migration fails the loss check, it reverts with `Splitter__MigrationLostFunds`. The admin must investigate and propose a different adapter.

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

#### Oracle/Market Price Deviation
- **Mechanism**: BasketOracle compares the theoretical plDXY-BEAR price (derived from Chainlink feeds) against Curve's internal EMA oracle (`price_oracle()`)
- **Threshold**: Maximum 2% deviation (configurable via `MAX_DEVIATION_BPS` at deployment)
- **Behavior**: If deviation exceeds threshold, `latestRoundData()` reverts with `BasketOracle__PriceDeviation(theoretical, spot)`
- **Affected Operations**: Minting, liquidation trigger, and leverage operations (via Morpho oracle). Burns are NOT affected—users can always exit.
- **Rationale**: Detects oracle manipulation (Chainlink compromise) or market manipulation (Curve pool attack). Also catches stale oracle data if Chainlink stops updating but Curve continues trading.
- **User Impact**: Minting and leverage operations temporarily halt until prices converge. This is a protective circuit breaker.
- **Recovery**: Prices typically converge within minutes as arbitrageurs trade the discrepancy. No admin intervention required.
- **Note**: Uses Curve's `price_oracle()` (time-weighted EMA) rather than `get_dy()` (instantaneous spot) to resist flash loan manipulation

### Liquidation Mechanics

#### Burn During Liquidation
- **Behavior**: Users can burn tokens to redeem USDC even after liquidation triggers
- **Impact**: This is intentional - users should always be able to exit
- **Rationale**: Only minting is blocked during liquidation to prevent new positions

#### No Partial Liquidation
- **Behavior**: When price >= CAP, the entire protocol enters SETTLED state
- **Impact**: All positions are affected equally
- **Rationale**: The CAP represents the theoretical maximum plDXY value; exceeding it means the inverse token has zero value

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
- **Risk**: Burns exceeding the local buffer require adapter withdrawal. If Morpho market is illiquid, burns revert with `Splitter__AdapterWithdrawFailed`
- **Mitigation**: 10% buffer absorbs normal withdrawal patterns; Morpho interest rates incentivize repayments when utilization is high
- **Note**: Buffer ratio is enforced at mint time only; no automatic rebalancing occurs

### Protocol Fees

The protocol has zero fees for user operations. The only fee is a performance fee on yield.

| Operation | Fee | Notes |
|-----------|-----|-------|
| Mint | 0% | No fee to mint BEAR+BULL pairs |
| Burn | 0% | No fee to redeem USDC |
| Flash Mint (plDXY-BEAR/BULL) | 0% | ERC-3156 compliant, zero fee |
| Flash Loan (Morpho) | 0% | Morpho Blue provides fee-free flash loans |
| Curve Swaps | ~0.04% | Paid to Curve LPs, not Plether |

#### Yield Distribution (Performance Fee)

When `harvestYield()` is called, surplus yield is distributed:

| Recipient | Share | Purpose |
|-----------|-------|---------|
| Caller | 0.1% | Incentive to call harvest |
| Treasury | 20% | Protocol/developer performance fee |
| Staking | 79.9% | Distributed to stakers |

- Performance fee only applies to yield generated, not principal
- If staking address is not set, treasury receives 100% of non-caller share
- Fee percentages are hardcoded and cannot be changed

#### Morpho Token Rewards

Morpho may distribute token rewards (e.g., MORPHO) to suppliers via their Universal Rewards Distributor (URD). These are separate from lending yield:

| Aspect | Details |
|--------|---------|
| Distribution | Merkle-based claims requiring off-chain proofs |
| Claiming | Protocol owner calls `claimRewards()` on MorphoAdapter |
| Recipient | Protocol owner specifies destination address |
| Frequency | Dependent on Morpho's reward campaigns |

- Rewards are **not** automatically distributed to stakers
- Protocol owner (same admin role as SyntheticSplitter) has full discretion over reward token destination
- Requires `setUrd()` to configure the URD contract address before claiming

### Flash Mint Capability

SyntheticToken (plDXY-BEAR and plDXY-BULL) supports ERC-3156 flash mints:

- **Fee**: Zero (no flash mint fee)
- **Max Amount**: Unlimited (tokens are minted on demand)
- **Use Cases**:
  - ZapRouter: Flash mints plDXY-BEAR for atomic BULL acquisition
  - BullLeverageRouter: Flash mints plDXY-BEAR for closing leveraged positions (single flash loan pattern)
- **Risk**: Flash-minted tokens could be used in complex attack vectors (e.g., oracle manipulation, governance attacks)
- **Mitigation**: Tokens must be returned in same transaction; protocol operations validate prices independently

### Decimal Handling

Critical decimal conversions throughout the protocol:

| Asset/Oracle | Decimals | Notes |
|--------------|----------|-------|
| USDC | 6 | Collateral token |
| plDXY-BEAR / plDXY-BULL | 18 | Synthetic tokens |
| Chainlink Price Feeds | 8 | EUR/USD, JPY/USD, etc. |
| BasketOracle Output | 8 | Aggregated plDXY price |
| Morpho Oracle | 36 | Internal Morpho scaling |
| StakedToken Offset | 3 | 1000x inflation attack protection |

Conversion formula in Splitter:
- `USDC_MULTIPLIER = 10^(18 - 6 + 8) = 10^20`
- `usdcNeeded = (tokenAmount * CAP) / USDC_MULTIPLIER`

### RewardDistributor Security

The RewardDistributor allocates yield based on price discrepancy between Chainlink (theoretical) and Curve EMA (spot). Potential manipulation vectors have been analyzed:

#### Price Manipulation for Reward Skew

**Attack concept:** Manipulate Curve EMA to diverge from Chainlink, causing rewards to favor one side.

**Why it's not economically viable:**

| Factor | Constraint |
|--------|------------|
| **BasketOracle deviation check** | Reverts if Chainlink/Curve diverge >2%, limiting manipulation range |
| **Curve EMA resistance** | Moving EMA requires sustained trading against arbitrageurs |
| **Attack cost** | Moving price 2% on a deep pool costs $50k-200k+ in fees/slippage |
| **Max profit** | Extra allocation × attacker's stake share × reward pool size |
| **Cooldown** | 1-hour minimum between distributions limits frequency |

**Example:** To gain an extra $5k (from 50/50 → 100/0 on a $100k reward pool with 10% stake), attacker spends $50k+ manipulating the pool. Net loss.

#### Stale EMA Frontrunning

**Attack concept:** During rapid price moves, Chainlink updates faster than Curve EMA, creating temporary discrepancy.

**Why it's not exploitable:** The same 2% BasketOracle deviation check that prevents manipulation also prevents stale-EMA exploitation. Large moves (>2% divergence) cause the oracle to revert entirely, blocking distribution until prices converge.

The system assumes that if the gap is >2%, the market is "disordered." By reverting, we protect the protocol from distributing based on noise. The 10% liquid buffer in the Splitter ensures that even if rewards are paused, users can still redeem their principal without friction.

### StakedToken Security

StakedToken (splDXY-BEAR, splDXY-BULL) is an ERC-4626 vault used as Morpho collateral:

- **Inflation Attack Protection**: Uses `_decimalsOffset() = 3` (1000x multiplier)
- **Streaming Rewards**: `donateYield()` streams rewards linearly over 1 hour instead of instant distribution
- **Withdrawal Delay**: 1 hour minimum stake duration before withdrawal (enforced via `maxWithdraw()`/`maxRedeem()`)
- **Transfer Timer Reset**: Receiving shares via transfer resets your withdrawal timer (prevents bypass)

#### Reward Sniping Protection

The streaming + delay combination prevents reward sniping attacks:

| Attack Vector | Mitigation |
|---------------|------------|
| Flash stake (same block) | Blocked by 1-hour withdrawal delay |
| Deposit → claim → withdraw | Rewards stream over 1 hour; early exit captures only pro-rata portion |
| Front-run `donateYield()` | Must hold for full stream duration to capture full rewards |
| Transfer shares to bypass delay | Timer resets on transfer recipient |

**How it works:**
1. `donateYield(amount)` starts a 1-hour linear stream via `rewardRate` and `streamEndTime`
2. `totalAssets()` excludes unvested rewards: `balance - _unvestedRewards()`
3. Share price increases gradually as rewards vest (not instantly)
4. `maxWithdraw()`/`maxRedeem()` return 0 during lock period (ERC4626 compliant)
5. Attacker who deposits and exits after 1 hour only captures rewards proportional to their stake duration

**Precision:** Streaming math uses 1e18 scaling. Truncation dust (~1000 wei per 100 ETH donation) vests immediately but is negligible and favors existing stakers.

#### Acknowledged Risk: Permissionless donateYield()

`StakedToken.donateYield()` is intentionally permissionless. While this allows anyone to inflate the vault exchange rate, exploitation requires burning capital with no economic return. The protocol accepts this griefing risk because:
- Attack is not profitable (attacker loses funds)
- Benefits existing stakers (higher share value)
- Morpho's time-weighted pricing limits liquidation manipulation
- Router contracts include exchange rate buffers (1%) to handle drift

### Curve Pool Configuration

Router contracts assume specific Curve pool structure:

| Index | Asset | Constant |
|-------|-------|----------|
| 0 | USDC | `USDC_INDEX` |
| 1 | plDXY-BEAR | `PLDXY_BEAR_INDEX` |

- **Risk**: If Curve pool is deployed with different indices, all router swaps fail
- **Mitigation**: Indices are verified during deployment; pool address is immutable
- **Deviation Check**: BasketOracle validates Chainlink price against Curve `price_oracle()` (max 2% deviation)
- **Pool Updates**: BasketOracle Curve pool can be updated via 7-day timelock (`proposeCurvePool` → `finalizeCurvePool`). Initial setup via `setCurvePool` is immediate.

### Router Architecture

LeverageRouter and BullLeverageRouter share a common base contract (`LeverageRouterBase`) for consistent behavior:

- **Shared Validation**: Authorization checks, deadline validation, slippage limits (max 1%)
- **Custom Errors**: All routers use custom errors for gas-efficient reverts and clear error identification
- **Flash Loan Pattern**: Both routers use single-level flash loans (Morpho for USDC, ERC-3156 for tokens)
- **Callback Security**: Flash loan callbacks validate `msg.sender` (lender) and `initiator` (self)

| Router | Flash Loan Source | Collateral Token |
|--------|-------------------|------------------|
| LeverageRouter | Morpho (USDC) | splDXY-BEAR |
| BullLeverageRouter | Morpho (USDC) for open, ERC-3156 (plDXY-BEAR) for close | splDXY-BULL |
| ZapRouter | ERC-3156 (plDXY-BEAR) | N/A |

#### MEV Protection

All routers implement multiple layers of MEV protection:

| Protection | Implementation | Purpose |
|------------|----------------|---------|
| Max Slippage Cap | `MAX_SLIPPAGE_BPS = 100` (1%) | Prevents users from setting dangerously high slippage |
| Deadline | `if (block.timestamp > deadline) revert` | Prevents stale transactions from executing |
| Min Output | `minAmountOut` / `minUsdcOut` parameters | User-specified minimum acceptable output |
| Curve Enforcement | `min_dy` passed to `exchange()` | On-chain slippage check in Curve swap |
| Safety Buffer | `SAFETY_BUFFER_BPS = 50` (0.5%) in ZapRouter | Accounts for rounding in flash calculations |
| Real-time Pricing | `get_dy()` before swaps | Uses current pool state, not stale oracle prices |

**Limitations:**
- Transactions are visible in the public mempool before inclusion; users can mitigate this by using private mempools (e.g., Flashbots Protect)
- The 1% cap is a maximum; users can specify lower values for tighter protection, but large positions may still experience significant slippage in dollar terms

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
- Oracle price >= CAP ($2.00 for plDXY)

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
3. Note: Cannot rescue core assets (USDC, plDXY-BEAR, plDXY-BULL)

Contracts supporting `rescueToken`:
- **SyntheticSplitter**: Rescues any token except USDC, plDXY-BEAR, plDXY-BULL
- **MorphoAdapter**: Rescues any token except USDC (the underlying asset)

### Adapter Migration (Emergency)

If yield adapter is compromised:
1. Pause the Splitter immediately
2. Propose new adapter via `proposeAdapter(newAdapter)`
3. Wait 7-day timelock (cannot be bypassed)
4. Execute migration via `finalizeAdapter()`
5. Unpause Splitter

**Note:** During the 7-day period, users can continue to redeem existing tokens.

### Adapter Migration (Tight Liquidity)

If adapter withdrawal fails due to high Morpho utilization:
1. Pause the Splitter via `pause()`
2. Call `withdrawFromAdapter(amount)` to extract available liquidity
3. Repeat step 2 as liquidity frees up (borrowers repay or get liquidated)
4. Once adapter is fully drained, propose new adapter via `proposeAdapter(newAdapter)`
5. Wait 7-day timelock
6. Execute migration via `finalizeAdapter()` (skips redemption if adapter has 0 shares)
7. Unpause Splitter

**Note:** `withdrawFromAdapter()` requires the protocol to be paused and caps withdrawal to `maxWithdraw()` from the adapter.

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
| 2026-01-30 | StakedToken: Added streaming rewards (1h linear vesting) and withdrawal delay (1h minimum) to prevent reward sniping |
| 2026-01-29 | Added RewardDistributor Security section: economic analysis of price manipulation and stale EMA attacks |
| 2026-01-21 | Added USDC (Circle) risks: depeg, blacklisting, upgradeability, and regulatory risks |
| 2026-01-15 | Documented acknowledged risk: permissionless donateYield() griefing vector |
| 2026-01-15 | Updated ownership model to reflect Ownable2Step pattern |
| 2026-01-15 | Added Governance Cooldown and Adapter Migration Safety sections under Trust Assumptions |
| 2026-01-14 | Added `rescueToken()` to SyntheticSplitter for recovering accidentally sent tokens (excludes USDC, plDXY-BEAR, plDXY-BULL) |
| 2026-01-14 | Added Upgradeability section (non-upgradeable contracts) and Protocol Invariants section (solvency, token, state invariants) |
| 2026-01-14 | Added Oracle/Market Price Deviation section documenting the 2% deviation check between Chainlink and Curve prices |
| 2026-01-14 | Added `withdrawFromAdapter()` for gradual liquidity extraction under tight Morpho utilization; documented new emergency procedure |
| 2026-01-14 | Added MEV Protection section under Router Architecture |
| 2026-01-13 | BasketOracle: Added 7-day timelock for Curve pool updates; refactored to use OpenZeppelin Ownable |
| 2026-01-13 | Documented Morpho liquidity risk: burns revert if adapter withdrawal fails due to high market utilization |
| 2026-01-11 | Reduced harvest caller reward from 1% to 0.1%; added Morpho token rewards documentation |
| 2026-01-09 | Added External Library Dependencies section with OpenZeppelin trust assumptions |
| 2026-01-04 | Added Router Architecture section; documented LeverageRouterBase, custom errors, and single flash loan pattern for BullLeverageRouter close |
| 2026-01-03 | Added protocol fees, flash mint, decimal handling, StakedToken, and Curve pool documentation |
| 2026-01-03 | Migrated to Morpho Blue as sole flash loan provider (removed Aave/Balancer dependencies) |
| 2025-01-03 | Initial security documentation |

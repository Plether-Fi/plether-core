# Perps Deployment

This document covers the current deployment flow for the perps stack in `packages/perps/src/`.

The current target network is Arbitrum Sepolia with:

- mock USDC as the settlement asset
- Pyth as the router oracle source
- a separate deploy phase and bootstrap phase

## Scripts

- Deploy script: `script/DeployPerpsArbitrumSepolia.s.sol`
- Bootstrap script: `script/BootstrapPerpsArbitrumSepolia.s.sol`

The deploy script handles contract creation and one-time wiring.

The bootstrap script handles operator actions after deploy:

- setting pausers
- proposing or finalizing finite senior-exposure limits
- seeding the junior tranche and then the senior tranche
- minting mock USDC to test users
- activating trading

## Deployment Shape

The deploy script creates and wires:

1. `MockUSDC`
2. `MarginClearinghouse`
3. `CfdEngine`
4. `CfdEnginePlanner`
5. `CfdEngineSettlementSidecar`
6. `CfdEngineAdmin`
7. `HousePool`
8. `TrancheVault` senior
9. `TrancheVault` junior
10. `CfdEngineAccountLens`
11. `CfdEngineLens`
12. `OrderRouter`
13. `PerpsPublicLens`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

Important:

- `HousePool` remains inactive after deployment.
- Trading does not go live until a finite capacity configuration completes its 48-hour timelock, both seed positions
  exist within those limits, and `activateTrading()` is called.

## Oracle Configuration

The Arbitrum Sepolia deploy script uses Pyth at:

- `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`

The router basket uses 6 FX feeds with DXY weights:

- `EUR/USD` direct
- `USD/JPY` inverted
- `GBP/USD` direct
- `USD/CAD` inverted
- `USD/SEK` inverted
- `USD/CHF` inverted

Base prices and weights are currently hardcoded in the script to match the existing perps basket assumptions.

### Arbitrum Sepolia Release Parameters

The next Arbitrum Sepolia perps deployment uses these initial defaults:

| Parameter | Value |
| --- | --- |
| `vpiFactor` | `0.005e18` |
| `frozenCloseSpreadBps` | `50` |
| `maxSkewRatio` | `0.4e18` |
| `maintMarginBps` | `30` |
| `initMarginBps` | `45` |
| `fadMarginBps` | `300` |
| `baseCarryBps` | `500` |
| `minBountyUsdc` | `1e6` |
| `bountyBps` | `10` total liquidation-charge rate |
| `keeperShareBps` | `5_000` (50% of collected charge to keeper) |
| `protocolShareBps` | `0` (protocol liquidation fee disabled; remaining 50% goes to LPs) |
| `executionFeeBps` | `4` |
| `fadRunwaySeconds` | `1 hours` |
| `pythMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_000` |
| `maxSeniorExposureUsdc` | Operator-supplied finite USDC amount |
| `maxSeniorShareBps` | Operator-supplied value below `10_000` |

`frozenCloseSpreadBps = 50` charges a fixed 0.50% spread on reduced notional for voluntary close/reduce execution only while `oracleFrozen`. Normal signed VPI and its lifetime rebate clamp remain active. For oracle-frozen voluntary closes, the spread replaces rather than compounds with the Pyth adverse-confidence adjustment; live/FAD-only closes and liquidations retain that adjustment. The spread belongs to LPs rather than protocol treasury and does not apply to liquidations. A terminal full close waives any uncollectible portion instead of adding bad debt, while a partial close must settle its full obligation.

`frozenCloseSpreadBps` is part of `CfdEngineAdmin.EngineRiskConfig` and therefore uses the 48-hour propose/finalize timelock. Deployments and updates reject zero and values above `1_000` bps (10%). `keeperShareBps` and `protocolShareBps` use the same timelock; both may be zero, but their sum must not exceed `10_000`. Each configured allocation rounds down and LPs receive the exact liquidation-charge remainder.

Adding `protocolShareBps` makes `RiskParams` a ten-field struct and changes its storage layout and tuple ABI. Deploy the engine, admin, router, and lenses from the same build on a fresh testnet deployment; do not mix these contracts with an older eight- or nine-field `riskParams()` deployment.

`pythMaxConfidenceRatioBps = 10` rejects a component feed when Pyth's reported confidence interval exceeds
`0.10%` of that component's price. Pyth confidence is an uncertainty band, so larger values mean less precise
prices.

`adverseConfidenceMultiplierBps = 2_000` applies `0.2x` of Pyth's confidence interval when shifting live/FAD
order execution and all liquidation prices in the adverse direction. Oracle-frozen voluntary closes bypass the
shift and use `frozenCloseSpreadBps` instead; confidence-width validation remains active.

## Environment

### Deploy

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...
```

Run:

```bash
source .env && forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The script prints the deployed addresses to the console. Save at least:

- `MockUSDC`
- `HousePool`
- `OrderRouter`

These are needed by the bootstrap script.

### Bootstrap

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...

PERPS_USDC=0x...
PERPS_HOUSE_POOL=0x...
PERPS_ORDER_ROUTER=0x...

MAX_SENIOR_EXPOSURE_USDC=...
MAX_SENIOR_SHARE_BPS=...
```

Optional:

```bash
PERPS_PAUSER=0x...

SENIOR_SEED_USDC=50000000000000
JUNIOR_SEED_USDC=50000000000000

SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...

ACTIVATE_TRADING=true

TEST_USER_RECIPIENTS=0xabc...,0xdef...
TEST_USER_AMOUNTS=1000000000000,500000000000
```

Notes:

- USDC amounts are raw 6-decimal values.
- `50000000000000` means `50_000_000e6`, or 50,000,000 mock USDC.
- Both senior-limit variables are mandatory. The exposure limit must be finite and the share limit must be below
  `10_000` bps; the script deliberately refuses the constructor's uncapped bootstrap values.
- Choose limits that admit the intended seeds. For symmetric `50_000_000e6` seeds, the exposure cap must be at least
  `50_000_000e6` and the senior-share cap must be at least `5_000` bps.
- `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` must have the same length.

Run:

```bash
source .env && forge script script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The first run proposes the exact finite limits through `HousePool.proposePoolConfig(...)` and then exits without
seeding, funding test users, or activating trading. Wait at least 48 hours and rerun the same command with the same
environment. The second run verifies the pending proposal, finalizes it, initializes junior before senior, funds test
users, and optionally activates trading. An unrelated outstanding `HousePool` proposal makes the script revert rather
than silently overwrite or finalize it.

## Bootstrap Behavior

The configuration, seed, and activation phases of the bootstrap script are designed to be partial-rerun safe:

- it separates the required limit proposal and finalization across the `HousePool` 48-hour timelock
- it refuses to seed while the requested finite limits are not active
- it skips pauser updates if already set
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

Test-user funding is intentionally not idempotent: each ready-state rerun mints the configured amounts again. Remove
the test-user recipient/amount inputs after the intended funding run.

This is useful if the first bootstrap attempt completes only partially.

## Operational Notes

- Perps contracts are non-upgradeable. Existing deployments do not gain these capacity controls; production rollout
  requires a coordinated replacement stack. Migrating assets between stacks is explicitly outside this change.
- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Run the deploy script.
2. Record the deployed addresses.
3. Set bootstrap env vars, including both explicit senior limits.
4. Run the bootstrap script to propose the finite limits.
5. Wait for the 48-hour `HousePool` timelock.
6. Rerun the same bootstrap command to finalize, seed junior then senior, and activate trading.
7. Fund any test wallets with Arbitrum Sepolia ETH.
8. Start integration testing against `PerpsPublicLens`, `MarginClearinghouse`, `OrderRouter`, and `HousePool`.

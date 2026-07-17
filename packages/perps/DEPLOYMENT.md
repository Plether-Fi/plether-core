# Perps Deployment

This document covers the current deployment flow for the perps stack in `packages/perps/src/`.

The current target network is Arbitrum Sepolia with:

- mock USDC as the settlement asset
- Pyth as the router oracle source
- a separate deploy phase and bootstrap phase

Use this guide with the operator
[`ARBITRUM_SEPOLIA_DEPLOYMENT_PACKET.md`](ARBITRUM_SEPOLIA_DEPLOYMENT_PACKET.md) and the machine-readable
[`arbitrum-sepolia-perps.template.json`](../../deployments/arbitrum-sepolia-perps.template.json). The packet is the
release gate; this document describes the scripts and configuration.

## Scripts

- Deploy script: `script/DeployPerpsArbitrumSepolia.s.sol`
- Bootstrap script: `script/BootstrapPerpsArbitrumSepolia.s.sol`
- Deploy simulation helper: `scripts/deploy-perps-arbitrum-sepolia-dry-run.sh`
- Bootstrap simulation helper: `scripts/bootstrap-perps-arbitrum-sepolia-dry-run.sh`

The deploy script handles contract creation and one-time wiring.

The bootstrap script handles operator actions after deploy:

- setting pausers
- seeding senior and junior tranches
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
7. `HousePool` (which creates its dedicated `CfdEngineProtocolLens`)
8. `TrancheVault` senior
9. `TrancheVault` junior
10. `CfdEngineAccountLens`
11. `CfdEngineLens`
12. `PletherOracle`
13. `OrderRouter` (which creates its dedicated `OrderRouterAdmin`)
14. `PerpsPublicLens`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

Important:

- `HousePool` remains inactive after deployment.
- Trading does not go live until both seed positions exist and `activateTrading()` is called.

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

### Recurring Market Calendar

The recurring schedule is compiled into each newly deployed engine and uses UTC:

| Regime | Window | Duration |
| --- | --- | --- |
| FAD only, oracle live | Friday 21:30–22:00 | 30 minutes |
| FAD and oracle frozen | Friday 22:00–Sunday 21:00 | 47 hours |
| FAD only, oracle live again | Sunday 21:00–21:15 | 15 minutes |

The recurring boundaries are not an admin parameter and cannot be changed on an existing non-proxy deployment. The
`fadRunwaySeconds` setting applies only before an admin-configured FAD override day.

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
| `bountyBps` | `10` |
| `executionFeeBps` | `4` |
| `fadRunwaySeconds` | `1 hours` |
| `fadMaxStaleness` | `3 days` |
| `engineMarkStalenessLimit` | `60 seconds` |
| `pythMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_000` |

`frozenCloseSpreadBps = 50` charges a fixed 0.50% spread on reduced notional for voluntary close/reduce execution only while `oracleFrozen`. Normal signed VPI and its lifetime rebate clamp remain active. For oracle-frozen voluntary closes, the spread replaces rather than compounds with the Pyth adverse-confidence adjustment; live/FAD-only closes and liquidations retain that adjustment. The spread belongs to LPs rather than protocol treasury and does not apply to liquidations. A terminal full close waives any uncollectible portion instead of adding bad debt, while a partial close must settle its full obligation.

The parameter is part of `CfdEngineAdmin.EngineRiskConfig` and therefore uses the 48-hour propose/finalize timelock. Deployments and updates reject zero and values above `1_000` bps (10%).

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

Start from `.env.example`, keep the release worktree clean, and run the guarded simulation:

```bash
scripts/deploy-perps-arbitrum-sepolia-dry-run.sh
```

After reviewing the simulation, broadcast the exact entrypoint:

```bash
set -a
source .env
set +a
forge script script/DeployPerpsArbitrumSepolia.s.sol \
  --tc DeployPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

The script prints the deployed addresses to the console. Record every created contract and transaction hash in a dated
copy of the manifest template. `MockUSDC`, `HousePool`, and `OrderRouter` are required inputs to the bootstrap script, but
recording only those three is not a complete deployment record.

### Bootstrap

Required:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...

PERPS_USDC=0x...
PERPS_HOUSE_POOL=0x...
PERPS_ORDER_ROUTER=0x...
ACTIVATE_TRADING=false
```

Optional:

```bash
PERPS_PAUSER=0x...

SENIOR_SEED_USDC=50000000000000
JUNIOR_SEED_USDC=50000000000000

SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...

TEST_USER_RECIPIENTS=0xabc...,0xdef...
TEST_USER_AMOUNTS=1000000000000,500000000000
```

Notes:

- USDC amounts are raw 6-decimal values.
- `50000000000000` means `50_000_000e6`, or 50,000,000 mock USDC.
- `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` must have the same length.

Use `ACTIVATE_TRADING=false` for the initial seed/bootstrap pass. Run the guarded simulation:

```bash
scripts/bootstrap-perps-arbitrum-sepolia-dry-run.sh
```

After reviewing the simulation, broadcast the exact entrypoint:

```bash
set -a
source .env
set +a
forge script script/BootstrapPerpsArbitrumSepolia.s.sol \
  --tc BootstrapPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

Read back the complete deployment before activation. Then set `ACTIVATE_TRADING=true`, rerun the bootstrap simulation,
and broadcast the idempotent activation rerun only after the readback is approved.

## Bootstrap Behavior

The bootstrap script is designed to be partial-rerun safe:

- it skips pauser updates if already set
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

This is useful if the first bootstrap attempt completes only partially.

## Deployment Record

Before the first simulation, copy `deployments/arbitrum-sepolia-perps.template.json` to a dated release manifest. After
deployment, replace every null contract address, populate transaction hashes and Arbiscan links, record the full release
commit and deployer, and update each verification flag from evidence.

The release is incomplete while any expected address is null or any of these remain unverified:

- contract source and constructor inputs
- set-once wiring
- risk, calendar, oracle, router, and pool configuration readback
- ownership and pauser state
- seed and activation state
- bounded integration smoke tests

## Operational Notes

- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Freeze a clean release commit and create the dated manifest.
2. Run and approve the deploy simulation.
3. Broadcast the deploy phase and record every address and transaction.
4. Set bootstrap env vars from the new manifest, with `ACTIVATE_TRADING=false`.
5. Run and approve the bootstrap simulation, then broadcast the seed/bootstrap phase.
6. Read back wiring, configuration, ownership, pause state, oracle inputs, and seed state.
7. Set `ACTIVATE_TRADING=true`, simulate again, and broadcast activation.
8. Fund test wallets with Arbitrum Sepolia ETH and run bounded integration smoke tests.
9. Complete the manifest, source verification, release notes, and consumer handoff.

# Perps Deployment

This document covers the current deployment flow for the perps stack in `src/perps/`.

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
- seeding senior and junior tranches
- minting mock USDC to test users
- activating trading

## Deployment Shape

The deploy script creates and wires:

1. `MockUSDC`
2. `MarginClearinghouse`
3. `CfdEngine`
4. `CfdEnginePlanner`
5. `CfdEngineSettlementModule`
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
- `CfdEngine.setVault(...)`
- `CfdEngine.setOrderRouter(...)`
- `HousePool.setOrderRouter(...)`
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
```

Optional:

```bash
PERPS_PAUSER=0x...

SENIOR_SEED_USDC=1000000000
JUNIOR_SEED_USDC=1000000000

SENIOR_SEED_RECEIVER=0x...
JUNIOR_SEED_RECEIVER=0x...

ACTIVATE_TRADING=true

TEST_USER_RECIPIENTS=0xabc...,0xdef...
TEST_USER_AMOUNTS=1000000000000,500000000000
```

Notes:

- USDC amounts are raw 6-decimal values.
- `1000000000` means `1000e6`, or 1,000 mock USDC.
- `TEST_USER_RECIPIENTS` and `TEST_USER_AMOUNTS` must have the same length.

Run:

```bash
source .env && forge script script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

## Bootstrap Behavior

The bootstrap script is designed to be partial-rerun safe:

- it skips pauser updates if already set
- it skips a seed if that side is already initialized
- it skips activation if trading is already active

This is useful if the first bootstrap attempt completes only partially.

## Operational Notes

- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.

## Recommended Flow

1. Run the deploy script.
2. Record the deployed addresses.
3. Set bootstrap env vars.
4. Run the bootstrap script.
5. Fund any test wallets with Arbitrum Sepolia ETH.
6. Start integration testing against `PerpsPublicLens`, `MarginClearinghouse`, `OrderRouter`, and `HousePool`.

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
7. `HousePool`
8. `TrancheVault` senior
9. `TrancheVault` junior
10. `CfdEngineAccountLens`
11. `CfdEngineLens`
12. `OrderRouter`
13. `PositionProtectionBook`, deployed internally and immutably bound by the Router constructor
14. `PerpsPublicLens`

It then performs the required set-once wiring:

- `CfdEngine.setDependencies(...)`
- `HousePool.setSeniorVault(...)`
- `HousePool.setJuniorVault(...)`
- `CfdEngine.setPool(...)`
- `CfdEngine.setOrderRouter(...)`
- `MarginClearinghouse.setEngine(...)`

The Book requires no separate deployment transaction or mutable wiring. Discover its address from
`OrderRouter.positionProtectionBook()` and verify that its immutable `ROUTER()` and `ENGINE()` values match the newly
deployed Router and engine.

Important:

- `HousePool` remains inactive after deployment.
- Trading does not go live until both seed positions exist and `activateTrading()` is called.
- `OrderRouter` is non-upgradeable and `CfdEngine.setOrderRouter(...)` is one-time. A release containing position
  protection therefore requires a fresh complete perps stack; do not point a new router at an existing engine or migrate
  live positions into the new release.
- Position-protection creation is disabled on a fresh router. Ordinary trading can be bootstrapped independently while
  the trigger worker, indexer, and product integrations are verified.

## Oracle Configuration

The Arbitrum Sepolia deploy script uses Pyth at:

- `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`

Pre-broadcast blocker: the current `plether-app` Arbitrum Sepolia configuration instead names
`0x0B73614636C855Bf23F342F307FB981A3e47f42B`. Confirm the authoritative Pyth endpoint and align both repositories before
deploying; this guide intentionally does not choose between the conflicting addresses.

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
| `bountyBps` | `10` |
| `executionFeeBps` | `4` |
| `fadRunwaySeconds` | `1 hours` |
| `pythMaxConfidenceRatioBps` | `10` |
| `adverseConfidenceMultiplierBps` | `2_000` |
| `closeOrderExecutionBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionTriggerBountyUsdc` | `200_000` (`0.20 USDC`) |
| `positionProtectionCommitsEnabled` | `false` |

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

Run:

```bash
source .env && forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia --rpc-url $ARB_SEPOLIA_RPC_URL --broadcast
```

The script prints the deployed addresses and position-protection defaults to the console. Save the complete output,
including at least:

- `MockUSDC`
- `MarginClearinghouse`
- `CfdEngine` and its planner, settlement sidecar, admin, and lenses
- `HousePool`
- both tranche vaults
- `PletherOracle`
- `OrderRouter`
- `PositionProtectionBook` returned by `OrderRouter.positionProtectionBook()`
- `OrderRouterAdmin`
- `PerpsPublicLens`

Also record the source commit, deployment block, transaction hashes, and verified-bytecode status. `MockUSDC`,
`HousePool`, and `OrderRouter` are needed by the bootstrap script; the other addresses are required by product,
indexer, keeper, monitoring, and audit tooling.

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

Bootstrap does not enable position protection or propose router configuration. Its final output reports the discovered
Book address, current feature flag, and trigger bounty so operators can verify that ordinary trading was activated
without exposing an unprepared conditional-order surface.

## Position Protection Activation

Position protection has a two-stage keeper model:

1. A permissionless trigger worker evaluates an armed TP/SL condition with a current Pyth update and, when a condition
   is met, appends a full-position market-style close to the ordinary global FIFO tail.
2. The ordinary order keeper executes that linked close using the normal post-commit historical Pyth rule.

Trader calls that create, replace, or attach protection are nonpayable and validate against the engine's cached fresh
mark. They target the `PositionProtectionBook` discovered through `OrderRouter.positionProtectionBook()`, as does the
payable `triggerPositionProtection(...)` keeper call. The Router does not forward these public selectors. Only the
trigger call ingests payable Pyth update data. This keeps the trader flow compatible with zero-native-value sponsored
accounts while retaining an independently verified trigger observation.

Protection lifecycle events originate from the Book. Indexers and trigger workers must subscribe at the Book address;
the generated close's ordinary `OrderCommitted` and terminal-order events originate from the Router.

The feature flag and trigger bounty are members of the 48-hour timelocked `OrderRouterAdmin.RouterConfig`. Enabling the
feature must use the normal proposal/finalization path:

1. Read every current router and oracle-policy field onchain.
2. Build a complete `RouterConfig` from those current values, changing only the intended protection fields.
3. Propose the configuration through `OrderRouterAdmin` and record the proposal transaction and activation timestamp.
4. Wait the full 48-hour delay.
5. Re-read the pending configuration, verify every field, and finalize it.
6. Confirm `positionProtectionCommitsEnabled() == true` and the expected snapshotted bounty values on the router.

Do not reconstruct unrelated fields from old release notes or hardcoded defaults: finalizing `RouterConfig` replaces the
complete router configuration. Disabling new protection commits follows the same timelocked path. Disabling or pausing
must not strand existing records: cancellation, valid triggering, linked FIFO execution, terminal cleanup, and
liquidation remain live.

## Operational Notes

- The bootstrap script only mints mock USDC. It does not fund users with ETH.
- Test users still need Arbitrum Sepolia ETH from a faucet to submit transactions.
- The deploy and bootstrap scripts currently assume the broadcaster owns the deployed contracts.
- The router admin is deployed internally by `OrderRouter`; bootstrap uses `router.admin()` to reach it.
- The position-protection Book is deployed internally by `OrderRouter`; bootstrap logs
  `router.positionProtectionBook()` for discovery and consistency checks.
- All ownership-bearing perps contracts use `Ownable2Step`: the current owner initiates a handoff and the pending
  owner must call `acceptOwnership()` before authority changes.

## Recommended Flow

1. Run formatting, package tests, integration script tests, and `forge build --sizes`; do not deploy an oversized router.
2. Simulate and then run the deploy script for a fresh complete stack.
3. Record the exact commit, deployment block, transaction hashes, addresses, and verification status.
4. Verify every set-once and immutable binding, record the Book returned by `positionProtectionBook()`, and confirm
   protection creation is disabled with a `200_000` trigger bounty and `200_000` linked-close execution bounty.
5. Set bootstrap environment variables, run bootstrap, and fund test wallets with Arbitrum Sepolia ETH as needed.
6. Point the frontend, public lens consumers, indexer, ordinary order keeper, trigger worker, and monitoring at the new
   release. Protection clients and event subscriptions use the Book; ordinary FIFO services use the Router. Start all
   offchain services from the deployment block.
7. Exercise trigger-worker discovery and dry-run/simulation paths while creation remains disabled.
8. Propose, wait 48 hours, verify, and finalize the complete router configuration that enables protection commits.
9. Test attached-open activation, existing-position protection, both trigger directions, cancellation/replacement,
   linked-order execution and expiry, frozen-oracle behavior, and liquidation end to end.
10. Run a limited-TVL soak for at least seven days before broader use. Monitor armed and triggered counts,
    trigger-to-FIFO and FIFO-to-terminal latency, linked-close failure/expiry, keeper profitability, liquidation before
    fill, and exact reservation reconciliation.

Create a new dated release note after deployment. Do not edit historical release notes. The new note must identify the
old stack as lacking position protection and state clearly that a trigger queues a close; it does not guarantee execution
time, execution price, or execution before liquidation.

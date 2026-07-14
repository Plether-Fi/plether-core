# Spot Operations and Deployment

This runbook covers operational setup and deployment for the contracts in [`packages/spot`](README.md). Run commands from
the repository root unless a section says otherwise.

## SyntheticSplitter Liquidity

`SyntheticSplitter` keeps a local USDC buffer equal to 10% of required backing and can deploy collateral above that target
through its configured yield adapter.

- `deployToAdapter()` is permissionless and pushes eligible excess USDC toward the adapter.
- Burns use local USDC first and may withdraw from the adapter when the local balance is insufficient.
- Adapter liquidity is an external dependency. A solvent protocol can still experience delayed large redemptions if the
  adapter cannot return assets immediately.
- During an adapter-liquidity incident, the owner can pause risk-increasing protocol activity and call
  `withdrawFromAdapter(amount)` repeatedly as liquidity becomes available.

Changing the adapter is timelocked. Operators must verify the proposed adapter's asset, code, accounting behavior, and
withdrawal liquidity before finalizing it.

## Reward Distribution

`SyntheticSplitter.harvestYield()` sends realized USDC yield toward the configured reward flow. `RewardDistributor` then
uses the difference between BasketOracle fair value and Curve EMA price to favor the underperforming synthetic:

- At zero discrepancy, rewards split 50/50 between BEAR and BULL.
- Below 2% discrepancy, the underperformer's share increases quadratically from 50% toward 100%.
- At or above 2% discrepancy, the underperformer receives 100% of distributable rewards.
- The distribution caller receives 10 basis points (0.1%) of the available USDC as an execution incentive.

These percentages determine the BEAR-side and BULL-side allocations. When INVAR is configured, the BEAR-side allocation is
split between staked BEAR and INVAR in proportion to their current BEAR exposure; if the INVAR read or donation fails, that
amount falls back to staked BEAR.

Distribution requires an active splitter, fresh oracle data, a nonzero reward balance, and the minimum distribution
interval. When the Pyth-backed FX component needs refreshing, use the price-update distribution entrypoint with a current
update payload rather than relying on stale adapter state.

## INVAR Initial Configuration

INVAR's staking and gauge-reward destinations use separate seven-day propose/finalize flows. Do not rely on harvesting or
reward routing until both destinations are finalized.

1. Deploy `InvarCoin` and its `StakedToken` wrapper.
2. Call `proposeStakedInvarCoin(sINVAR)`.
3. Wait `STAKED_INVAR_TIMELOCK` (7 days), then call `finalizeStakedInvarCoin()`.
4. Call `proposeGaugeRewardsReceiver(receiver)` with the intended rewards sink.
5. Wait `GAUGE_REWARDS_TIMELOCK` (7 days), then call `finalizeGaugeRewardsReceiver()`.
6. Call `protectRewardToken(token)` for CRV and every other gauge incentive that must not be recoverable through the
   generic rescue path.
7. After claiming gauge rewards, route protected balances only with `sweepGaugeRewards(token)`.

Before finalization, verify every proposed address, its code, token compatibility, and operational ownership. A mistaken
proposal must be corrected and wait through a new timelock.

## INVAR Liquidity and Harvesting

INVAR targets a 2% local USDC buffer and holds the remaining balanced exposure through Curve LP. Permissionless solvers can
rebalance that inventory:

- `sellLpToVault(lpAmount, minUsdcOut)` sells Curve LP to the vault when local USDC exceeds the target.
- `buyLpFromVault(lpAmount, maxUsdcIn)` buys Curve LP from the vault to restore the local buffer.
- `harvest()` isolates Curve virtual-price fee growth and streams the resulting INVAR to sINVAR stakers.

Operational safety properties include:

- Deposits use optimistic NAV while withdrawals use pessimistic NAV, bounding dilution and extraction around oracle/EMA
  disagreement.
- `lpWithdraw()` remains the balanced emergency exit when single-sided flows are paused.
- Solver fills and balanced redeployment require oracle/EMA fair-value validation.
- Virtual shares protect the first-depositor path.
- `totalAssets()` is a best-effort monitoring view; use `totalAssetsValidated()` when strict oracle validation is required.
- Best-effort harvesting skips failed Curve virtual-price reads, while pending yield still requires strict validation before
  accounting.
- `setEmergencyMode()` pauses deposits and single-sided withdrawals without discarding LP accounting.
- Protected gauge rewards cannot be swept to arbitrary recipients.
- Oracle-critical L2 operations enforce the configured sequencer uptime feed and restart grace period.

Gauge configuration and emergency removal have additional trust and loss assumptions. Review
[`SECURITY.md`](../../SECURITY.md) before operating INVAR or changing its gauge.

## Deployment Runbooks

### Common Checks

Before every deployment:

1. Initialize git submodules and build the Spot package.
2. Run package tests plus the relevant root deployment-script and fork tests.
3. Confirm the target chain ID, deployer, nonce, balance, RPC endpoint, external protocol addresses, and oracle feed IDs.
4. Simulate the exact script without `--broadcast` and review every created contract and call.
5. Record deployed addresses, constructor inputs, transaction hashes, bytecode, and verification identifiers.

Never commit `.env`, private keys, RPC credentials, or generated update payloads.

### Ethereum Sepolia

Required `.env` values:

```bash
TEST_PRIVATE_KEY=...
SEPOLIA_RPC_URL=...
```

The helper fetches and encodes current Pyth data, exports `PYTH_UPDATE_DATA`, and broadcasts
`DeployToSepolia.s.sol:DeployToSepolia`:

```bash
scripts/deploy-sepolia.sh
```

The script deploys a test Spot stack, mock USDC, a local Morpho Blue instance with a zero-rate IRM, and test liquidity. Treat
every address it prints as testnet-only.

### Arbitrum Sepolia

Required `.env` values:

```bash
TEST_PRIVATE_KEY=...
ARB_SEPOLIA_RPC_URL=...
```

Optional settlement-token override:

```bash
SPOT_USDC=0x...
```

If `SPOT_USDC` is absent, the script falls back to `PERPS_USDC` and then its configured shared test USDC. The dry-run helper
fetches the six Pyth FX updates, exports `PYTH_UPDATE_DATA`, and simulates the deployment:

```bash
source .env && scripts/deploy-spot-arbitrum-sepolia-dry-run.sh
```

After reviewing a successful simulation, load a current `PYTH_UPDATE_DATA` value and broadcast explicitly:

```bash
source .env && forge script script/DeploySpotArbitrumSepolia.s.sol:DeploySpotArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

The Arbitrum Sepolia stack uses real Pyth, a mock Curve-compatible pool, mock USDC where configured, and a local Morpho Blue
instance for frontend and integration testing.

### Local Anvil Fork

Start Anvil against a mainnet RPC endpoint:

```bash
source .env
anvil --fork-url "$MAINNET_RPC_URL" --chain-id 31337
```

In another shell, choose one of Anvil's funded development accounts and export its key only for the local process:

```bash
source .env
export TEST_PRIVATE_KEY="$ANVIL_PRIVATE_KEY"
forge script script/DeployToAnvilFork.s.sol:DeployToAnvilFork \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

The local fork uses real mainnet integration addresses at the selected fork block while deploying mock USDC and test-owned
protocol components. Oracle values remain tied to the forked chain state unless explicitly updated.

### Ethereum Mainnet

The production entrypoint is [`DeployToMainnet.s.sol`](../../script/DeployToMainnet.s.sol). This document intentionally does
not provide a copy-paste broadcast command: production deployment must use release-specific reviewed parameters, address
manifests, simulation output, verification steps, and signer procedures.

## After Deployment

- Verify every contract using its package-qualified source path under `packages/spot/src/`.
- Complete all set-once wiring and timelocked propose/finalize sequences.
- Confirm protocol lifecycle state, pause authorities, treasury and reward destinations, adapter, Curve pool, Morpho
  markets, oracle feeds, staleness thresholds, and sequencer feed.
- Seed only the liquidity required by the reviewed deployment plan.
- Exercise mint, burn, staking, distribution, adapter, INVAR, and emergency paths with bounded test amounts.
- Publish the address manifest and exact commit SHA used for the release.

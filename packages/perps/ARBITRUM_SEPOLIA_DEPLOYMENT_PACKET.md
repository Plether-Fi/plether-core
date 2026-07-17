# Arbitrum Sepolia Perps Deployment Packet

This packet is the release checklist for a fresh perps-only deployment. It does not authorize a broadcast. The reviewed
release commit, signer, environment, simulation output, transaction set, and final manifest must all refer to the same
deployment.

## Fixed Release Scope

- Network: Arbitrum Sepolia (`421614`)
- Deploy entrypoint: `script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia`
- Bootstrap entrypoint: `script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia`
- Address-manifest template: `deployments/arbitrum-sepolia-perps.template.json`
- Products in scope: perps contracts and their dedicated mock USDC only
- Products out of scope: Spot, Options, Curve, Morpho, staking, rewards, and frontend deployment

The recurring UTC calendar compiled into the engine is:

| Regime | Window | Duration |
| --- | --- | --- |
| FAD-only, live oracle | Friday 21:30–22:00 | 30 minutes |
| FAD and frozen oracle | Friday 22:00–Sunday 21:00 | 47 hours |
| FAD-only, live oracle | Sunday 21:00–21:15 | 15 minutes |

## Release Freeze

- [ ] Select the exact release commit and record its full SHA.
- [ ] Confirm the worktree and index are clean.
- [ ] Confirm the release branch contains only reviewed perps deployment changes.
- [ ] Record deployer, intended final owner, pauser, seed receivers, and activation decision.
- [ ] Confirm the deployer has sufficient Arbitrum Sepolia ETH and the expected nonce.
- [ ] Copy the manifest template to a dated release file; do not overwrite an older deployment record.

Required validation:

```bash
forge fmt --check
bash scripts/check-package-boundaries.sh
forge test --root packages/perps --offline
forge test --offline --match-contract ArbitrumSepoliaReleaseDefaultsTest
jq empty deployments/arbitrum-sepolia-perps.template.json
bash -n scripts/deploy-perps-arbitrum-sepolia-dry-run.sh
bash -n scripts/bootstrap-perps-arbitrum-sepolia-dry-run.sh
```

## Environment Review

Copy `.env.example` to `.env` and fill only the reviewed values. Never commit `.env`, RPC credentials, private keys, or
test-user funding lists.

Deploy requires:

```text
ARB_SEPOLIA_RPC_URL
TEST_PRIVATE_KEY
```

Bootstrap additionally requires:

```text
PERPS_USDC
PERPS_HOUSE_POOL
PERPS_ORDER_ROUTER
ACTIVATE_TRADING
```

Seed amounts default to `50_000_000e6` on each side. The packet sets `ACTIVATE_TRADING=false` for the first bootstrap so
the deployment can be read back before opening trading. Activation is a separate, explicit rerun with
`ACTIVATE_TRADING=true`.

## Deploy Phase

Run the guarded simulation:

```bash
scripts/deploy-perps-arbitrum-sepolia-dry-run.sh
```

Review the predicted deployer nonce, contract addresses, constructor arguments, gas, and every set-once wiring call. The
simulation must create only the perps stack described in `DEPLOYMENT.md`.

After approval, broadcast the exact same commit and script:

```bash
set -a
source .env
set +a
forge script script/DeployPerpsArbitrumSepolia.s.sol \
  --tc DeployPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

Immediately record every created address and transaction hash in the dated manifest. Populate the bootstrap addresses
from that manifest rather than from an earlier release note.

## Bootstrap Phase

First simulate with `ACTIVATE_TRADING=false`:

```bash
scripts/bootstrap-perps-arbitrum-sepolia-dry-run.sh
```

Review:

- pauser assignments on `HousePool` and `OrderRouterAdmin`,
- senior and junior seed amounts and receivers,
- every test-user mint,
- the fact that trading remains inactive.

After approval, broadcast the bootstrap script:

```bash
set -a
source .env
set +a
forge script script/BootstrapPerpsArbitrumSepolia.s.sol \
  --tc BootstrapPerpsArbitrumSepolia \
  --rpc-url "$ARB_SEPOLIA_RPC_URL" \
  --broadcast
```

Read back all wiring, configuration, ownership, seeds, pause state, and oracle feed configuration. Then set
`ACTIVATE_TRADING=true`, rerun the guarded bootstrap simulation, and broadcast the same command for activation only after
the readback is approved.

## Required Readback

- [ ] All expected addresses have nonempty bytecode.
- [ ] Engine dependencies, pool, router, clearinghouse, vaults, oracle, admin contracts, and lenses point to the new stack.
- [ ] Risk, calendar, oracle, router, and pool values match the manifest.
- [ ] Pyth is `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`; all six feed IDs, weights, bases, and inversions match.
- [ ] Both seed positions exist and their receivers are correct.
- [ ] HousePool and OrderRouterAdmin are unpaused and have the reviewed pauser.
- [ ] Ownership and any pending `Ownable2Step` handoffs match the signer plan.
- [ ] Trading remains inactive until the explicit activation transaction.
- [ ] A bounded post-activation open, close, liquidation-preview, LP deposit, and LP withdrawal smoke test passes.

## Packet Completion

- [ ] Manifest contains the full commit SHA, deployment date, deployer, contracts, transaction hashes, and Arbiscan links.
- [ ] Constructor inputs and source verification are complete for every contract.
- [ ] Configuration readback and smoke-test evidence are attached to the release.
- [ ] Frontend/indexer consumers receive the new `PerpsPublicLens`, `MarginClearinghouse`, `OrderRouter`, `HousePool`, vault,
      oracle, and mock-USDC addresses.
- [ ] The dated release note names this manifest and explicitly supersedes the previous Arbitrum Sepolia perps stack.

Do not label the deployment complete while any manifest address is null, any verification flag is false, or trading state
does not match the reviewed activation decision.

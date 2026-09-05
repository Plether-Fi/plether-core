# Arbitrum Sepolia perps deployment — 2026-09-05

**Deployed and verified; trading inactive; both tranches unseeded.** The active deployment record at
`deployments/arbitrum-sepolia-perps.json` still points to the previous stack. Do not switch consumers to this deployment
until bootstrap, activation, and their verification stages pass.

## Deployment evidence

- Source: `c3f60f58bcd5dc1b85a28739a5de7ec4a2ee114c`, merged in [PR #81](https://github.com/Plether-Fi/plether-core/pull/81).
- Chain: Arbitrum Sepolia (`421614`).
- Toolchain: Forge `1.5.1-stable`; Solidity `0.8.35`; optimizer 200 runs; via-IR; Prague EVM target.
- All **31 transactions succeeded**, creating **26 contracts** including the internal Engine Protocol Lens.
- Deployment blocks: **305627052–305627147**.
- Receipt gas used: **91,543,070**; summed `gasUsed × effectiveGasPrice`: **0.01874256165515 ETH**.
- The authenticated six-feed Hermes request, upgraded-Pyth compatibility call, and final no-broadcast preflight passed.
- A clean production rebuild matched all 26 simulated creation inputs before broadcast.
- All **26 contracts are source-verified** on the Arbitrum Sepolia explorer, including constructor-created helpers.
- The standalone `deployed` verifier passed; post-deployment state was recorded at block **305627917**.
- Release-branch [CI passed](https://github.com/Plether-Fi/plether-core/actions/runs/33954187996). The merged release tree
  equals that tested tree. The [full perps deep suite](https://github.com/Plether-Fi/plether-core/actions/runs/33952474869)
  passed on `b4679b5`; perps package source, tests, and configuration are unchanged from that run. The revised bootstrap
  and verifier passed all **39 local deployment/script tests**, including the one-USDC seed lifecycle.

The companion `manifest.json` contains every address, on-chain runtime code hash, deployment transaction hash,
execution-config hash, and phase-verification result. Explorer source-verification results are recorded separately
from the on-chain wiring verifier.

## Main addresses

| Component | Address |
| --- | --- |
| Mock USDC | [0xAbEe441b564DC084857468fA244AEE0A444B07DF](https://sepolia.arbiscan.io/address/0xAbEe441b564DC084857468fA244AEE0A444B07DF) |
| Engine | [0x2CEDc3f0059f0E9C1099bE96974f459E58c428d6](https://sepolia.arbiscan.io/address/0x2CEDc3f0059f0E9C1099bE96974f459E58c428d6) |
| HousePool | [0x7b8b851cb3783611bcDA4CF2F7D5A2F8C6106F98](https://sepolia.arbiscan.io/address/0x7b8b851cb3783611bcDA4CF2F7D5A2F8C6106F98) |
| Senior vault | [0xF98e69d808F8c22fCE4210516E2F0B2dAa4CC0B2](https://sepolia.arbiscan.io/address/0xF98e69d808F8c22fCE4210516E2F0B2dAa4CC0B2) |
| Junior vault | [0xd6B662D75B102eA360C1B083E1f332e6c1634832](https://sepolia.arbiscan.io/address/0xd6B662D75B102eA360C1B083E1f332e6c1634832) |
| Order Router | [0x2b9790AD11cE5fB1B91aC3415B08cD1Ec7D0cE0B](https://sepolia.arbiscan.io/address/0x2b9790AD11cE5fB1B91aC3415B08cD1Ec7D0cE0B) |
| Position Protection Book | [0x63973Eb0B5a862dfc95348D4d575FC55C9546F04](https://sepolia.arbiscan.io/address/0x63973Eb0B5a862dfc95348D4d575FC55C9546F04) |
| Public Lens | [0x269db12a9A275F40b2d3826fDea7eadee8b7CBe9](https://sepolia.arbiscan.io/address/0x269db12a9A275F40b2d3826fDea7eadee8b7CBe9) |
| Settlement Monitor | [0x3d6E6407F23fc41899180C7dC699F02a1BB2926B](https://sepolia.arbiscan.io/address/0x3d6E6407F23fc41899180C7dC699F02a1BB2926B) |
| Emergency Coordinator | [0x8f23B8E9e3B0E2D4876fb0616FAa66093fC78457](https://sepolia.arbiscan.io/address/0x8f23B8E9e3B0E2D4876fb0616FAa66093fC78457) |

## Why bootstrap is pending

The current FX weekend window is oracle-frozen. `HousePool.initializeSeedPosition` rejects an oracle-frozen bootstrap;
this condition was confirmed on-chain. No bootstrap or activation transactions were sent, and no mock USDC was minted
for this deployment. Both vaults have zero supply. Trading and new position-protection commits remain disabled.

The new coordinator is installed as both pausers but its guardian is still the zero address. Bootstrap will configure
the intended guardian `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`, which is also the deployer/owner and the intended
receiver of both seed positions.

The normal calendar unfreezes at **2026-09-06 21:00 UTC / Sunday, September 6 at 23:00 Warsaw time**. Recheck the live
oracle-frozen status and the operational oracle/keeper prerequisites before continuing; do not bypass the calendar.

## Resume from this deployment

Use the ignored local `.env.arbitrum-sepolia-perps`, which already contains the deployed addresses, intended guardian
and seed receivers, `RELEASE_COMMIT=c3f60f58bcd5dc1b85a28739a5de7ec4a2ee114c`, and **1,000,000 raw units (1 mock USDC)
per tranche**. Keep this pinned Solidity source when operating the released stack.

1. Export the env file with `set -a; source .env.arbitrum-sepolia-perps; set +a`, then use a clean checkout of
   `$RELEASE_COMMIT`. Confirm chain `421614`, the manifest address bindings, and `CfdEngine.isOracleFrozen() == false`. Re-run the deployed-phase verifier before first seeding.
2. Simulate `BootstrapPerpsArbitrumSepolia` with `ACTIVATE_TRADING=false`. If it passes, broadcast that same bootstrap
   phase. It installs the guardian and initializes Junior then Senior with exactly **1 USDC each (2 total)**.
3. Run `VerifyPerpsArbitrumSepolia` with `VERIFY_PHASE=seeded` and no `--broadcast`.
4. Remove any optional test-user mint arrays before a bootstrap rerun. Simulate, then broadcast bootstrap with
   `ACTIVATE_TRADING=true`; run the verifier with `VERIFY_PHASE=active`.
5. Record the seed and activation receipts, live guardian, and verifier results in the dated manifest. Only then archive
   the prior active manifest and promote this deployment to `deployments/arbitrum-sepolia-perps.json`.
6. Coordinate frontend, keeper, indexer, and monitoring cutover. Index this stack from block `305627052` and regenerate
   bindings for bounded protected opens, V3 receipt/config domains, latched retries, and settlement-based LP cooldowns.
   Complete the trading, LP, and guardian smoke checks described in `packages/perps/DEPLOYMENT.md`.

Do not rerun the deploy script to resume bootstrap. The contracts already exist. There is no live-state migration
between generations. Read-only inspection of the old stack found no queued orders, protection records, pending LP
deposits/redemptions, or trader-claim liability; it does still have LP shares. Keep old-stack exit servicing available.

Position-protection creation stays disabled until trigger/retry workers are ready. Enabling it uses the separate
48-hour governance proposal/finalization flow. A trigger queues a close and does not guarantee its timing, price, or
execution before liquidation.

# Arbitrum Sepolia perps release candidate — 2026-09-04

Status: **prepared, not deployed**. The candidate contains no live addresses or successful on-chain verification
claims. The active deployment remains recorded in `deployments/arbitrum-sepolia-perps.json`.

## Source and scope

- Final candidate source: pending review and merge of the latest master plus the one-USDC seed change. Set
  `manifest.json`'s `sourceCommit` to that final reviewed commit before preflight.
- Previously validated baseline: `d3b28d1520d46a730e3179303b70761e315e0ce2`.
- Previous deployed source: `69fa3e2bc2d2c9d32a5808e26e62b59c11119fb9`, deployed 2026-08-26.
- Chain: Arbitrum Sepolia, `421614`; Pyth: `0x0B73614636C855Bf23F342F307FB981A3e47f42B`.
- Build: Forge `1.5.1-stable`, Solidity `0.8.35`, optimizer 200 runs, via-IR.
- Deploy a fresh complete stack. Contracts are non-upgradeable; do not mix generations or import live state.

This release combines three changes since the previous deployment:

1. **Bounded protected opens.** `commitOpenOrderWithProtection` takes the full V2 `OrderRequest` and protection
   parameters. The old scalar selector is removed. Public parent requests must pin the active execution-config hash;
   the zero-hash exception is reserved for authenticated internal protection-close attempts.
2. **Latched close retries.** A failed triggered close can retain its execution bounty and enter `Latched`. Keepers
   call the nonpayable `retryPositionProtectionClose` without new trigger Pyth data. Each attempt gets a fresh order
   id, clock, deadline, and oracle window. Consumers must retain all attempts, decode the appended status/bounty enum
   values, and index Book attempt events plus lifecycle-Book registration events. A trigger queues a close; it does
   not guarantee execution time, price, or execution before liquidation.
3. **Settlement-based LP cooldowns.** Deposit cooldowns age from successful settlement. Finalized deposit shares can
   move directly into an async redemption through `IAsyncTrancheVaultClaimableRedeem`, without first claiming ERC-20
   shares. Use `PerpsPublicLens.getLpDepositCooldownState` for request-specific eligibility. Regenerate vault and lens
   bindings together; the base async interface id remains stable.

Order intent/request encoding remains V2. Receipt and execution-config domains are now V3. Recompute hashes against
the new lifecycle Book. The old stack already has position-protection contracts; its recorded release defaults leave
new protection commits disabled. Inspect its live state before cutover instead of assuming no outstanding records.

## Prepared evidence

The one-USDC seed update passed all **39 deployment/script tests**, including deployment, inactive seeding,
idempotent bootstrap reruns, and separate activation with all three verifier phases. Formatting and package-boundary
checks also passed.

The CI, simulation, size, and ABI-bundle evidence below describes the previously validated baseline. Rebuild and
revalidate the final source before deployment; the old exported bundle does not include the revised seed manifest.

- [CI passed](https://github.com/Plether-Fi/plether-core/actions/runs/33919232007) on the baseline source,
  including production deployment-size checks.
- [Full perps deep suite passed](https://github.com/Plether-Fi/plether-core/actions/runs/33919231980) on that source.
- Local formatting and package-boundary checks passed.
- Local production build passed. Focused non-via-IR regressions: **118 passed, 0 failed**, including protection,
  lifecycle, claimable-deposit redemption, public-lens cooldowns, market calendar, and oracle-boundary invariants.
- No-broadcast RPC simulation passed: **31 transactions**, estimated **119,241,745 gas / 0.048263334891481745 ETH**.
  These estimates and simulated addresses depend on chain state and deployer nonce; rerun immediately before broadcast.
- RPC checks confirmed chain `421614`, code at Pyth, and approximately `2.3125 ETH` in the configured deployer.
- Consumer bundle: **74 ABIs**, SHA-256 ABI hashes, compiler settings, pinned submodules, and bytecode size evidence.

Local logs and the consumer bundle are under ignored `artifacts/perps-release-2026-09-04/`. The bundle contains compiler
artifacts, not verified live contract addresses or runtime code hashes. Rebuild it from a clean source checkout with:

```bash
python3 scripts/export-perps-release.py artifacts/perps-release-candidate
```

The exporter builds production artifacts, refuses modified source/build inputs or an existing output directory,
and checks compiler runtime and creation-code limits. Constructor arguments are excluded from its creation-code
counts; the RPC simulation supplies the full creation-input evidence below.

| Component | Runtime bytes | Full creation input bytes |
| --- | ---: | ---: |
| Release Router | 18,808 | 43,350 |
| V2 execution sidecar | 24,005 | 24,051 |
| Tranche vault (each) | 23,879 | 26,450 |
| Settlement monitor facade | 23,339 | 49,057 |

The monitor creation input has only **95 bytes** of EIP-3860 headroom. Any Solidity/build change requires remeasurement.

## Remaining release gates

- Supply `PYTH_API_KEY` securely in the ignored release env file. It was absent from the available deployment
  environment, so the authenticated six-feed Hermes preflight has **not passed**. The successful deployment simulation
  does not substitute for that gate.
- Merge/review preparation changes, select the clean final `origin/master` SHA, and set `RELEASE_COMMIT` to that SHA.
  If the final source differs from the candidate, rerun CI, deep tests, artifact export, and the full preflight; update
  the candidate manifest's source commit and evidence. Do not describe an unreviewed build as the reviewed release.
- Set the intended owner/deployer, nonzero guardian, and Senior/Junior seed receivers explicitly. Do not copy old
  addresses into the candidate contract map. Confirm frontend calendar/holiday overrides and keeper readiness.
- Inventory old orders, protections, positions, LP requests, and claims, and arrange the coordinated consumer cutover
  described in `packages/perps/DEPLOYMENT.md`. Keep the old stack's exit servicing available as needed.

## Operator sequence

From the repository root, copy `.env.arbitrum-sepolia-perps.example` to the ignored
`.env.arbitrum-sepolia-perps` and populate the release credentials and operator inputs. Export plain assignments so
Forge subprocesses can read them:

```bash
set -a
source .env.arbitrum-sepolia-perps
set +a
scripts/prepare-perps-arbitrum-sepolia-release.sh
```

After every release gate passes, execute the following stages in order, saving broadcast receipts and verification
output for each stage. Deployment, bootstrap, activation, consumer cutover, and publication remain unexecuted.

1. Deploy with `forge script script/DeployPerpsArbitrumSepolia.s.sol:DeployPerpsArbitrumSepolia
   --rpc-url "$ARB_SEPOLIA_RPC_URL" --broadcast`. Preserve the uninterrupted lifecycle Book / keeper sidecar / Router
   nonce sequence. Populate **all** `PERPS_*` contract addresses from that actual deployment, then re-source the env.
2. Run `VERIFY_PHASE=deployed forge script script/VerifyPerpsArbitrumSepolia.s.sol:VerifyPerpsArbitrumSepolia
   --rpc-url "$ARB_SEPOLIA_RPC_URL"` without broadcast.
3. Bootstrap with `ACTIVATE_TRADING=false forge script
   script/BootstrapPerpsArbitrumSepolia.s.sol:BootstrapPerpsArbitrumSepolia --rpc-url "$ARB_SEPOLIA_RPC_URL" --broadcast`.
   Seed exactly `1000000` raw mock USDC per tranche. Set receivers and guardian explicitly.
4. Run the standalone verifier with `VERIFY_PHASE=seeded`. Remove optional test-user funding arrays before any
   bootstrap rerun because those mints are not idempotent.
5. Rerun bootstrap with `ACTIVATE_TRADING=true`, then run the standalone verifier with `VERIFY_PHASE=active`.
6. Record actual addresses, transaction hashes, deployment block, runtime hashes, execution-config hash, and verifier
   results in `manifest.json`. Verify explorer source and record its status. Only then archive the prior active record
   and promote the completed manifest to `deployments/arbitrum-sepolia-perps.json`.
7. Switch frontend, keeper, indexer, and monitoring bindings together. Publish dated deployment notes using observed
   results. Leave `positionProtectionCommitsEnabled=false` until trigger/retry workers are ready; enabling it requires
   the separate, existing 48-hour governance proposal/finalization flow.

Initial seed funding is `$1/$1`; the other release economics remain `$40M/80%` Senior limits, `$1,000` minimum open,
`2,500`-bps adverse-confidence multiplier, and `100`-bps Junior maintenance fee. The candidate manifest records these
expected values; each deployment/seed/active verification must confirm the appropriate live state.

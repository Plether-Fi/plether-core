# v1.2.3 — Arbitrum Sepolia perps deployment

All **27 contracts are deployed and source-verified on Arbiscan**. Both tranches were subsequently seeded with **0.01 mock USDC each** at blocks 307404152–307404154.
Trading remains inactive and the emergency guardian is disabled. The active deployment record is unchanged.
The original manifest, bundle, and deployment validation retain their pre-seeding snapshots;
`seeding-evidence.json` records the subsequent operation and independent checks at block 307404339.

## Changes since v1.2.2

- Clearinghouse-owned committed-margin FIFO and typed order/protection bounty records. `getOrderReservation` has a
  changed tuple layout, and Router `syncMarginQueue` is removed. Regenerate accounting decoders and integration ABIs.
- Full-position-close and carry-accounting fixes align previews, policy, and execution. Carry consumes active
  position margin before free settlement; only unpaid carry enters terminal recovery and waiver.
- `CfdEngineLens.quoteMaxOpen(...)` returns the largest planner-valid size and its diagnostics. The lens creates the
  stateless `CfdEngineOpenQuoter` helper internally; consumers call the lens. Quote results do not include every
  Router or terminal-book execution gate and are not execution guarantees.
- Retired obsolete accounting and planner APIs. The release also fixes the test-clock issue that previously prevented
  a carry regression from exercising its second interval under production compilation.

This is a fresh complete stack with changed storage layouts and immutable bindings. There is no in-place upgrade or
live-state migration. Rebuild frontend, keeper, governance, indexer, and monitoring bindings together. Order intents
remain V2; receipt and execution-config domains remain V3. Position protection has no separate activation flag.
A protection trigger queues a close; it does not guarantee execution time, price, or execution before liquidation.

## Deployment

- Network: Arbitrum Sepolia (`421614`).
- Source and release-tag target: [`ffe4593`](https://github.com/Plether-Fi/plether-core/commit/ffe45937b7f38133133ad292c5435828bf99357d).
- All **31 deployment transactions succeeded**, creating 27 contracts at blocks 307397196–307397286.
- Deployment gas: 93,084,456; transaction fees: 0.023969210266096 Sepolia ETH.
- Deployer and owner: `0x5a71a4094ec81165ada48aa4c27da48ec27e0d6b`.
- **27/27 Arbiscan source verifications passed**, with compiler version, optimizer settings, and constructor arguments
  independently read back from the explorer. There are 26 exact matches. Arbiscan reuses the verified source
  for the stateless `HousePoolRedemptionMathSidecar` and returns “Already Verified” on direct submission; its full
  1,042-byte runtime is identical to the linked verified contract, with no constructor arguments. This is recorded
  explicitly in `source-verification.json`.
- Deployed-phase verification and runtime checks passed at block 307397477.

Index this stack from block `307397196`. Both seed receivers are the deployment owner, `0x5a71a4094ec81165ada48aa4c27da48ec27e0d6b`.

- [Junior seed: 0.01 USDC](https://sepolia.arbiscan.io/tx/0x4a6eeb9061b85796ac20f17b7c75df59ddf48336f2099d561550f20439a16c69).
- [Senior seed: 0.01 USDC](https://sepolia.arbiscan.io/tx/0xeeb93262b88831af34b200f5a5f4509aa4280a23d266964ac329dc9ec6c278b6).
- All four funding/seeding transactions succeeded. Each tranche has `10000` raw USDC principal and `10000000`
  permanent seed shares. Pool token balance and accounted assets are `20000` raw USDC, with zero remaining approval.
- This explicitly requested amount differs from the standard bootstrap script and seeded verifier, which require
  1 USDC per tranche. A dedicated fork simulation and independent on-chain checks validated the 0.01-USDC operation;
  the standard seeded-phase verifier was not used. Do not attempt to seed these initialized tranches again.

Before activation, configure the intended guardian and adapt operational validation to the recorded seed amounts.
Recheck live oracle/pause state and arrange servicing of all old-stack positions, orders, protections, balances,
claims, and LP obligations before coordinated consumer cutover.

## Contract addresses

| Component | Verified source |
| --- | --- |
| mockUsdc | [`0xf7cbfcc74f2d9eb6fa7dc11941b3bef9fd7f8eb8`](https://sepolia.arbiscan.io/address/0xf7cbfcc74f2d9eb6fa7dc11941b3bef9fd7f8eb8#code) |
| marginClearinghouse | [`0xfa6e677ec1062757c1194d411a5e61e1e9644499`](https://sepolia.arbiscan.io/address/0xfa6e677ec1062757c1194d411a5e61e1e9644499#code) |
| cfdEngine | [`0xafece93321be41aa73474457e2f47cf7b2fb738f`](https://sepolia.arbiscan.io/address/0xafece93321be41aa73474457e2f47cf7b2fb738f#code) |
| terminalNavBookV2 | [`0x3f42840648a56f0cb2b266576abc71c5b3826c73`](https://sepolia.arbiscan.io/address/0x3f42840648a56f0cb2b266576abc71c5b3826c73#code) |
| cfdEnginePlanner | [`0x43ee7271b4ba820179d4e1e4f2d8398fe860ad52`](https://sepolia.arbiscan.io/address/0x43ee7271b4ba820179d4e1e4f2d8398fe860ad52#code) |
| cfdEngineSettlementSidecar | [`0x69dc8489dc12bcfd74b4f453f59ec7381822f5bb`](https://sepolia.arbiscan.io/address/0x69dc8489dc12bcfd74b4f453f59ec7381822f5bb#code) |
| cfdEngineAdmin | [`0xe83a05b403f227ceee33d5091a7f1f100e4657f0`](https://sepolia.arbiscan.io/address/0xe83a05b403f227ceee33d5091a7f1f100e4657f0#code) |
| housePoolRedemptionMathSidecar | [`0x2b1b35f3d39bcc2a7a20275cd9046a20a1148762`](https://sepolia.arbiscan.io/address/0x2b1b35f3d39bcc2a7a20275cd9046a20a1148762#code) |
| housePool | [`0x87622630fb1941fe02731d4a9fcdec0388efd78b`](https://sepolia.arbiscan.io/address/0x87622630fb1941fe02731d4a9fcdec0388efd78b#code) |
| cfdEngineProtocolLens | [`0xa60216ccfac2195b426c06722cbd931af09db702`](https://sepolia.arbiscan.io/address/0xa60216ccfac2195b426c06722cbd931af09db702#code) |
| seniorVault | [`0x970ac2cfe9a19d4318806812719a5c291711b33a`](https://sepolia.arbiscan.io/address/0x970ac2cfe9a19d4318806812719a5c291711b33a#code) |
| juniorVault | [`0x2075a46921fc5fbcf5fca808e3a2c66c6f812d79`](https://sepolia.arbiscan.io/address/0x2075a46921fc5fbcf5fca808e3a2c66c6f812d79#code) |
| cfdEngineAccountLens | [`0x29fd3b5faf8de6c84405d28e1aac371e46a104c6`](https://sepolia.arbiscan.io/address/0x29fd3b5faf8de6c84405d28e1aac371e46a104c6#code) |
| cfdEngineLens | [`0x8fe702213241482d6e94327f9e70195ad183d1ad`](https://sepolia.arbiscan.io/address/0x8fe702213241482d6e94327f9e70195ad183d1ad#code) |
| cfdEngineOpenQuoter | [`0x233abeb5d1c753007560fd8419da646ef7cd2276`](https://sepolia.arbiscan.io/address/0x233abeb5d1c753007560fd8419da646ef7cd2276#code) |
| cfdOrderPolicyEvaluator | [`0x43c93d3028fcd4c1f578a50639750b8fbfdee799`](https://sepolia.arbiscan.io/address/0x43c93d3028fcd4c1f578a50639750b8fbfdee799#code) |
| orderRouterV2ExecutionSidecar | [`0x0b3fd1ccb1d1a5882df767d7408e1dca0bdc398c`](https://sepolia.arbiscan.io/address/0x0b3fd1ccb1d1a5882df767d7408e1dca0bdc398c#code) |
| pletherOracle | [`0x9f4d9ae736b94249b18a85a7e14092bfca0688eb`](https://sepolia.arbiscan.io/address/0x9f4d9ae736b94249b18a85a7e14092bfca0688eb#code) |
| orderRouterLiquidationBatchSidecar | [`0x57ec1dc2c2b543893a4e5c4c160ca4c50e5af0bb`](https://sepolia.arbiscan.io/address/0x57ec1dc2c2b543893a4e5c4c160ca4c50e5af0bb#code) |
| orderLifecycleBook | [`0x753eb48305ffb88bb70869ade2c4efa941879221`](https://sepolia.arbiscan.io/address/0x753eb48305ffb88bb70869ade2c4efa941879221#code) |
| orderRouter | [`0x6215d36fcbd610ca1525252eebcbfd8b223a6072`](https://sepolia.arbiscan.io/address/0x6215d36fcbd610ca1525252eebcbfd8b223a6072#code) |
| orderRouterAdmin | [`0xfc18c770468f0dbbfe054d320509895ab77aff07`](https://sepolia.arbiscan.io/address/0xfc18c770468f0dbbfe054d320509895ab77aff07#code) |
| positionProtectionBook | [`0x3204c51cd567d6490c011399ccbaaf67b5d3d768`](https://sepolia.arbiscan.io/address/0x3204c51cd567d6490c011399ccbaaf67b5d3d768#code) |
| perpsPublicLens | [`0x63a6ee8ef44cf13d0d1f393a1e9f8d25da1abfb4`](https://sepolia.arbiscan.io/address/0x63a6ee8ef44cf13d0d1f393a1e9f8d25da1abfb4#code) |
| settlementMonitorLens | [`0x52f9621446650ab663f2f1665f28817924c96826`](https://sepolia.arbiscan.io/address/0x52f9621446650ab663f2f1665f28817924c96826#code) |
| settlementMonitorLensSidecar | [`0xb13d18d1b30e2c6fce1138f93123136113d0af5b`](https://sepolia.arbiscan.io/address/0xb13d18d1b30e2c6fce1138f93123136113d0af5b#code) |
| emergencyPauseCoordinator | [`0xc91300b69e3371c6a07799168ae94dda12b98685`](https://sepolia.arbiscan.io/address/0xc91300b69e3371c6a07799168ae94dda12b98685#code) |

## Validation and artifacts

- [CI](https://github.com/Plether-Fi/plether-core/actions/runs/34465522437) passed on the exact deployed source. Full deep-test coverage also passed for all four shards;
  GitHub shards 2–4 passed. Shard 1 hit the 30-minute GitHub limit during compilation, leaving the
  [GitHub deep run](https://github.com/Plether-Fi/plether-core/actions/runs/34465522258) cancelled; its complete local rerun passed 14 fuzz/invariant and 443 regular
  tests with the same production settings, seed, and full test parameters. See `validation.json` and the bundled local log.
- All **40 local integration/script tests** passed, including deployment, one-USDC seeding, and separate activation.
- Authenticated upgraded-Pyth preflight and no-broadcast deployment simulation passed.
- All **27 full creation inputs matched the production build** and fit deployment limits. Every on-chain runtime
  matched its compiler template outside immutable substitution; the Engine/lens/helper bindings and deployed stack
  wiring were checked. Runtime hashes and deployment transaction hashes are recorded in the manifest.
- The settlement monitor facade creation input is **49,057 bytes**, leaving **95 bytes** below EIP-3860. Remeasure after
  any source or compiler-setting change.
- Production settings: Forge `1.5.1-stable`, Solidity `0.8.35`, optimizer 200 runs, via-IR, Prague EVM.

The release bundle contains **77 ABIs**, ABI hashes, build settings, the live deployment manifest, creation-input
comparisons and constructor arguments, runtime and explorer verification evidence, validation results, transaction receipts,
and file checksums. Guardian configuration, trading activation, and consumer cutover remain pending.

[Deployment runbook](https://github.com/Plether-Fi/plether-core/blob/ffe45937b7f38133133ad292c5435828bf99357d/packages/perps/DEPLOYMENT.md) ·
[Changes since v1.2.2](https://github.com/Plether-Fi/plether-core/compare/v1.2.2...v1.2.3)

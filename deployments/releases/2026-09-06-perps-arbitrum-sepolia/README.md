# v1.2.2 — Arbitrum Sepolia perps deployment

Contracts deployed and source-verified. Trading is inactive; both tranches are unseeded.

## Changes since v1.2.1

- Removed `positionProtectionCommitsEnabled` and its configuration field. Position protection has no separate activation transaction; normal pause, position, margin, and oracle checks still apply.
- Retains the latched SL/TP retries introduced in v1.2.1, including fresh retry identifiers and oracle windows.
- Included the merged protocol-lens and HousePool state cleanups. Regenerate bindings from this release's ABIs; there is no backward-compatibility layer or live-state migration.

## Deployment

- Network: Arbitrum Sepolia (`421614`).
- Source and release-tag target: [`d704122`](https://github.com/Plether-Fi/plether-core/commit/d704122c779d4d681d0fa2be517707b7f7df3902).
- All 31 deployment transactions succeeded, creating 26 contracts at blocks 306119399–306119486.
- Deployment gas: 91,195,120; fee: 0.02009824944903 Sepolia ETH.
- 26/26 sources verified on Arbiscan; deployed-phase verification passed at block 306119832.
- Guardian configuration, seeding, trading activation, and consumer cutover remain pending.

The normal weekend oracle freeze is active. The earliest bootstrap time is September 6, 2026 at 21:00 UTC (23:00 Warsaw); recheck the live oracle status before seeding. Planned seeds are 1 mock USDC per tranche (`1000000` base units each). The intended guardian and both seed receivers are `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`; the current guardian is zero. Configure the guardian, seed with `ACTIVATE_TRADING=false`, verify the seeded phase, activate trading, then verify the active phase.

This is a fresh stack. The previous active manifest and existing deployments are unchanged. Do not cut consumers over until activation verification passes. Index this stack from block `306119399`. Protection triggers queue close attempts; they do not guarantee execution time, price, or execution before liquidation.

## Contract addresses

| Component | Verified source |
| --- | --- |
| mockUsdc | [`0xc3CE8590B7EcDE7454f9D5b51a797bbDe96fe56B`](https://sepolia.arbiscan.io/address/0xc3CE8590B7EcDE7454f9D5b51a797bbDe96fe56B#code) |
| marginClearinghouse | [`0xA863F985EedA8BF5BE2320693BB93d109EBB2dBd`](https://sepolia.arbiscan.io/address/0xA863F985EedA8BF5BE2320693BB93d109EBB2dBd#code) |
| cfdEngine | [`0x9611E643aC4691E8fDeD8a0c2C22c56438B6f352`](https://sepolia.arbiscan.io/address/0x9611E643aC4691E8fDeD8a0c2C22c56438B6f352#code) |
| terminalNavBookV2 | [`0x56d9f628a1FE45625777e48FEE6F27c10e49d786`](https://sepolia.arbiscan.io/address/0x56d9f628a1FE45625777e48FEE6F27c10e49d786#code) |
| cfdEnginePlanner | [`0x8d5146ed1f8Bd18998235A2DFa26a9a7Bcf15b5F`](https://sepolia.arbiscan.io/address/0x8d5146ed1f8Bd18998235A2DFa26a9a7Bcf15b5F#code) |
| cfdEngineSettlementSidecar | [`0x5CBb5A2f75ea005753a6C0AcCE01f7bB02B668D7`](https://sepolia.arbiscan.io/address/0x5CBb5A2f75ea005753a6C0AcCE01f7bB02B668D7#code) |
| cfdEngineAdmin | [`0xc1c5027a609a1188B745aa04ADcDeEc9Db37ebaE`](https://sepolia.arbiscan.io/address/0xc1c5027a609a1188B745aa04ADcDeEc9Db37ebaE#code) |
| housePoolRedemptionMathSidecar | [`0x950c9d6d4936cdbD67fAf789d4Ac6ADF11E1bd7D`](https://sepolia.arbiscan.io/address/0x950c9d6d4936cdbD67fAf789d4Ac6ADF11E1bd7D#code) |
| housePool | [`0x21D52509Bb9b9857DaBc8c7FD36dD7fed9118918`](https://sepolia.arbiscan.io/address/0x21D52509Bb9b9857DaBc8c7FD36dD7fed9118918#code) |
| seniorVault | [`0x7Bf2B3d3912b5B8D367987C9ADfC6Bd1216E8129`](https://sepolia.arbiscan.io/address/0x7Bf2B3d3912b5B8D367987C9ADfC6Bd1216E8129#code) |
| juniorVault | [`0x41D785d3BcF4D0e306E491a66Ddb0d938135Cc1c`](https://sepolia.arbiscan.io/address/0x41D785d3BcF4D0e306E491a66Ddb0d938135Cc1c#code) |
| cfdEngineAccountLens | [`0xd949E5987c3d33299dA4Da4d06b064729000d2EB`](https://sepolia.arbiscan.io/address/0xd949E5987c3d33299dA4Da4d06b064729000d2EB#code) |
| cfdEngineLens | [`0xE004D20803B484fb62734b78d6144438669Bad18`](https://sepolia.arbiscan.io/address/0xE004D20803B484fb62734b78d6144438669Bad18#code) |
| cfdOrderPolicyEvaluator | [`0x1ed622ed2Cbd64bd36115dB9D4f4c0006b5894fB`](https://sepolia.arbiscan.io/address/0x1ed622ed2Cbd64bd36115dB9D4f4c0006b5894fB#code) |
| orderRouterV2ExecutionSidecar | [`0x5528Dea8EF5a223aeE951Ba40D62ed24430a0D50`](https://sepolia.arbiscan.io/address/0x5528Dea8EF5a223aeE951Ba40D62ed24430a0D50#code) |
| pletherOracle | [`0x9e7f0a912a9CB3e1c1d77Ed433F171E23E2D7c87`](https://sepolia.arbiscan.io/address/0x9e7f0a912a9CB3e1c1d77Ed433F171E23E2D7c87#code) |
| orderRouterLiquidationBatchSidecar | [`0x8d6168a70CC28696BFB08a3CD6F5f9B0227AAefc`](https://sepolia.arbiscan.io/address/0x8d6168a70CC28696BFB08a3CD6F5f9B0227AAefc#code) |
| orderLifecycleBook | [`0x616aD381Df40047e9b060a1E85085B3Ed2CC6D3C`](https://sepolia.arbiscan.io/address/0x616aD381Df40047e9b060a1E85085B3Ed2CC6D3C#code) |
| orderRouter | [`0xbd2f286efca5F761E21452673ab9b8C14e17aad7`](https://sepolia.arbiscan.io/address/0xbd2f286efca5F761E21452673ab9b8C14e17aad7#code) |
| orderRouterAdmin | [`0x7447ee8A4a80Fd8668a2dF00F655f2df36D6cCEd`](https://sepolia.arbiscan.io/address/0x7447ee8A4a80Fd8668a2dF00F655f2df36D6cCEd#code) |
| positionProtectionBook | [`0x35f495fFDbB4d6ae395691D4632629f67603C926`](https://sepolia.arbiscan.io/address/0x35f495fFDbB4d6ae395691D4632629f67603C926#code) |
| perpsPublicLens | [`0x53B1B00748E7D1A87dc30433e87c331CeDe30149`](https://sepolia.arbiscan.io/address/0x53B1B00748E7D1A87dc30433e87c331CeDe30149#code) |
| settlementMonitorLens | [`0xf799Be4f8B5142C052d821F0067ADdFBF9Ce5820`](https://sepolia.arbiscan.io/address/0xf799Be4f8B5142C052d821F0067ADdFBF9Ce5820#code) |
| settlementMonitorLensSidecar | [`0x81c3a8D145C14f28334314Fa67A0dA0Ba5c50c6B`](https://sepolia.arbiscan.io/address/0x81c3a8D145C14f28334314Fa67A0dA0Ba5c50c6B#code) |
| emergencyPauseCoordinator | [`0x8c5586C051F26651AfB2fA6bbD7BeB24fDdC87aD`](https://sepolia.arbiscan.io/address/0x8c5586C051F26651AfB2fA6bbD7BeB24fDdC87aD#code) |
| cfdEngineProtocolLens | [`0x80b39ba83d44332f3ee6690c74e10d97cb57babe`](https://sepolia.arbiscan.io/address/0x80b39ba83d44332f3ee6690c74e10d97cb57babe#code) |

## Validation and artifacts

- [CI](https://github.com/Plether-Fi/plether-core/actions/runs/34051305070) and [all four deep-test shards](https://github.com/Plether-Fi/plether-core/actions/runs/34051305075) passed on the exact deployed source.
- All 40 local integration/script tests passed, including the deployment, one-USDC seeding, and activation lifecycle.
- Authenticated upgraded-Pyth preflight and no-broadcast simulation passed.
- Clean production rebuild matched all 26 simulated creation inputs. All runtime and full creation-input sizes fit their limits; the largest creation input is SettlementMonitorLens at 49,057 bytes (49,152 limit).
- Read-only deployed-phase verifier passed. Seeded and active verification remain pending.

The release bundle contains 75 ABIs, build settings and ABI hashes, the deployment manifest, creation-size evidence, source-verification evidence, and this deployment record. The manifest records every deployed runtime hash and deployment transaction hash. Order intents remain V2; receipts and execution configuration use V3 domains.

[Deployment runbook](https://github.com/Plether-Fi/plether-core/blob/d704122c779d4d681d0fa2be517707b7f7df3902/packages/perps/DEPLOYMENT.md) · [Changes since v1.2.1](https://github.com/Plether-Fi/plether-core/compare/v1.2.1...v1.2.2)

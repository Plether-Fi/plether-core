# Perps v1.3.0 — Arbitrum Sepolia

Fresh complete stack deployed on 2026-10-12 from source commit [`cf86189b`](https://github.com/Plether-Fi/plether-core/commit/cf86189bcca4813f39d6405a338b77176783eb42). All **32 transactions succeeded**, creating **29 contracts** at L2 blocks **318367917–318367988**.

**Deployed/inactive:** neither tranche has been seeded, trading is disabled, and the emergency guardian is unset. No bootstrap, activation, live-state migration, or consumer cutover was performed. Prior active deployment records are unchanged.

Owner and deployment-time treasury: `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`. Settlement uses the newly deployed mock USDC. Actual deployment gas: **102,131,829**; fees: **0.002080175269437829 test ETH**.

## Release behavior

This release includes V3 bounded orders and commit-relative deadlines, clearinghouse-owned reservations, deposit-free closes with exact charge recovery, atomic historical Pyth synchronization, and credit-only `depositFor` funding. It requires matching Router, Books, Engine, clearinghouse, sidecars, oracle, and lens implementations. There is no automatic migration from v1.2.3. A protection trigger queues a close; it does not guarantee execution time, price, or execution before liquidation.

Consumers must regenerate bindings from the included source revision and use `getOrderExecutionFee(bytes[])` for historical order execution. Oracle and Router deferred ETH refunds remain separate claim paths. Bridge destination-call support does not enable a real provider route: that route and its application evidence remain independently gated.

## Validation

- Exact-source [CI](https://github.com/Plether-Fi/plether-core/actions/runs/38222712233) and all four production-codegen [deep shards](https://github.com/Plether-Fi/plether-core/actions/runs/38222712210) passed. The workflow’s optional configured RPC integration was skipped; the separate mandatory signed-Pyth replay below ran locally.
- **41 integration/script tests**, **63 release-tooling tests**, and **9 bridge release-tooling tests** passed. Formatting, package boundaries, and the 173-reference test map passed.
- The immutable build exported **87 ABIs**. All **29 runtimes and full creation inputs** fit EIP-170 and EIP-3860. Production settings: Forge 1.5.1-stable, Solidity 0.8.35, optimizer 200, via-IR, Prague.
- Every actual on-chain runtime matches the compiled template outside immutable substitutions. All top-level creation inputs were independently read from chain; every constructor-created helper input was checked through on-chain execution traces. Core graph and reciprocal immutable bindings passed the deployed-phase verifier.
- Signed-Pyth baseline/candidate replay retained historical fill `97666256` and neutral mark `97667164`. All **seven isolated V3 fork scenarios** passed; the largest isolated call used **3,689,894 gas**, below the 30,000,000 cap. These measurements exclude transaction intrinsic gas and Arbitrum data fees. Authentic zero-fee scenarios do not establish nonzero Oracle-allocation refunds; the separate production-codegen ETH-conservation invariant covers that path.
- The additional inactive oracle-synchronization verifier passed with a current authenticated six-feed payload and the deployed execution-config hash. A current `updateMarkPrice(bytes[])` **eth_call simulation** passed; no oracle update was broadcast by that check. These are point-in-time checks.
- **29/29 Arbiscan source verifications passed.** Independent explorer input readback confirmed every relevant source content, Solidity version, via-IR/Prague settings, optimizer configuration, and exact constructor argument against the pinned build. The junior vault required a separate exact submission after the explorer initially reused the senior source match; the follow-up passed. Source publication was explicitly approved.

The tightest size margins are **95 bytes** for SettlementMonitorLens full creation input (`49,057 / 49,152`) and **153 bytes** for CfdEngine runtime (`24,423 / 24,576`). Source or compiler changes require fresh build evidence. Solidity `block.number` in the verifier follows Arbitrum’s L1 numbering; manifest deployment blocks and runtime RPC checkpoints use L2 numbering.

The shared environment template now includes the required `PERPS_CLOSE_PREVIEW` and `PERPS_ORDER_RECOVERY_SIDECAR` fields, and the deployment guide records all 29 contracts. These documentation/template corrections occur after the deployed source commit; they do not change the deployed Solidity. The unseeded verifier was supplied a nonzero prospective guardian input because it requires one, but its deployed phase does not install or assert that guardian. The actual coordinator guardian remains zero.

## Addresses

| Component | Arbiscan |
| --- | --- |
| mockUsdc | [`0x653b0cebe3cda9ec51de171cc2bb9e454a156e45`](https://sepolia.arbiscan.io/address/0x653b0cebe3cda9ec51de171cc2bb9e454a156e45#code) |
| marginClearinghouse | [`0x3c1f9fdd4882fef4650ee03dcc4703860dd8d1c0`](https://sepolia.arbiscan.io/address/0x3c1f9fdd4882fef4650ee03dcc4703860dd8d1c0#code) |
| cfdEngine | [`0x95462ce6a0088170ffabc0f93b2f93b17ba2c8b0`](https://sepolia.arbiscan.io/address/0x95462ce6a0088170ffabc0f93b2f93b17ba2c8b0#code) |
| terminalNavBookV2 | [`0xd6e94db3bb26e89183563719b8f4a66c1e0a1872`](https://sepolia.arbiscan.io/address/0xd6e94db3bb26e89183563719b8f4a66c1e0a1872#code) |
| cfdEnginePlanner | [`0x1e0420b749ea85d0a1f70db4a715458008606f44`](https://sepolia.arbiscan.io/address/0x1e0420b749ea85d0a1f70db4a715458008606f44#code) |
| cfdEngineSettlementSidecar | [`0x7336290349ee4f4149173dc93b89ab951321c9af`](https://sepolia.arbiscan.io/address/0x7336290349ee4f4149173dc93b89ab951321c9af#code) |
| cfdEngineAdmin | [`0xeb5ccf3d63ff78541d33f56a3772d3e78341954a`](https://sepolia.arbiscan.io/address/0xeb5ccf3d63ff78541d33f56a3772d3e78341954a#code) |
| housePoolRedemptionMathSidecar | [`0xa89d01d5ba82bd9d2e5e897194e6203d15a88829`](https://sepolia.arbiscan.io/address/0xa89d01d5ba82bd9d2e5e897194e6203d15a88829#code) |
| housePool | [`0xfafdc23a0879b56f580914d594c29423501cbad0`](https://sepolia.arbiscan.io/address/0xfafdc23a0879b56f580914d594c29423501cbad0#code) |
| cfdEngineProtocolLens | [`0xcb3141511d7c8fc58ec45815ce35a5bc7a2e9f57`](https://sepolia.arbiscan.io/address/0xcb3141511d7c8fc58ec45815ce35a5bc7a2e9f57#code) |
| seniorVault | [`0xd1893d4c3a3e1dc3b3634c59310c8212409c1aaa`](https://sepolia.arbiscan.io/address/0xd1893d4c3a3e1dc3b3634c59310c8212409c1aaa#code) |
| juniorVault | [`0xfbcf57e732a6b2420e22acc0bd976648f4aaf029`](https://sepolia.arbiscan.io/address/0xfbcf57e732a6b2420e22acc0bd976648f4aaf029#code) |
| cfdEngineAccountLens | [`0x12ca3776d001fbe12895783a9c93149ee8b5a1e5`](https://sepolia.arbiscan.io/address/0x12ca3776d001fbe12895783a9c93149ee8b5a1e5#code) |
| cfdEngineLens | [`0x069b3c61377009c79e48d94bf947b414a7fd3600`](https://sepolia.arbiscan.io/address/0x069b3c61377009c79e48d94bf947b414a7fd3600#code) |
| cfdEngineOpenQuoter | [`0xef91017698fade5f985b1419d2f71e5c8601d854`](https://sepolia.arbiscan.io/address/0xef91017698fade5f985b1419d2f71e5c8601d854#code) |
| cfdOrderPolicyEvaluator | [`0xec050dde46f13848b4018b304e8609ffcc1997ad`](https://sepolia.arbiscan.io/address/0xec050dde46f13848b4018b304e8609ffcc1997ad#code) |
| cfdClosePreview | [`0x041b37223268f098eebfa77a78d250ef1f49b1a6`](https://sepolia.arbiscan.io/address/0x041b37223268f098eebfa77a78d250ef1f49b1a6#code) |
| orderRouterExecutionSidecar | [`0x0f33d9c9c4bb480ce2dd95f1da5e544b74445a5f`](https://sepolia.arbiscan.io/address/0x0f33d9c9c4bb480ce2dd95f1da5e544b74445a5f#code) |
| orderRecoverySidecar | [`0x1b73bbf4b730da5664618c1186be7917ecf8470e`](https://sepolia.arbiscan.io/address/0x1b73bbf4b730da5664618c1186be7917ecf8470e#code) |
| pletherOracle | [`0x76b6461880be19aba592c16975611be8b6eaf6e5`](https://sepolia.arbiscan.io/address/0x76b6461880be19aba592c16975611be8b6eaf6e5#code) |
| orderRouterLiquidationBatchSidecar | [`0xb392fbfc729ceaa3ebc5208f3d69d19a78d601f8`](https://sepolia.arbiscan.io/address/0xb392fbfc729ceaa3ebc5208f3d69d19a78d601f8#code) |
| orderLifecycleBook | [`0xfc22e0532c52101bbfe742e7754a4578af297f68`](https://sepolia.arbiscan.io/address/0xfc22e0532c52101bbfe742e7754a4578af297f68#code) |
| orderRouter | [`0x5e6b97a9b8f9fd43ad098462d5cc5852a74ddc70`](https://sepolia.arbiscan.io/address/0x5e6b97a9b8f9fd43ad098462d5cc5852a74ddc70#code) |
| orderRouterAdmin | [`0xef255d9a937b1d482970ad3f0541a61c2aaf7c6a`](https://sepolia.arbiscan.io/address/0xef255d9a937b1d482970ad3f0541a61c2aaf7c6a#code) |
| positionProtectionBook | [`0xff43e35ad574fe30e69769741abb0fff3273a812`](https://sepolia.arbiscan.io/address/0xff43e35ad574fe30e69769741abb0fff3273a812#code) |
| perpsPublicLens | [`0x88cba0d30ff0b1c13ab49f8e54ed22e75745e7c5`](https://sepolia.arbiscan.io/address/0x88cba0d30ff0b1c13ab49f8e54ed22e75745e7c5#code) |
| settlementMonitorLens | [`0xa2cad103857aed976a063219ee6b8366a758d9ea`](https://sepolia.arbiscan.io/address/0xa2cad103857aed976a063219ee6b8366a758d9ea#code) |
| settlementMonitorLensSidecar | [`0xca44e01506f4463e22a7ca02dbfb0dbbfb77de9b`](https://sepolia.arbiscan.io/address/0xca44e01506f4463e22a7ca02dbfb0dbbfb77de9b#code) |
| emergencyPauseCoordinator | [`0xe5e2386d153c20db34227b46c72c021bc10a667a`](https://sepolia.arbiscan.io/address/0xe5e2386d153c20db34227b46c72c021bc10a667a#code) |

Execution-config hash: `0x7ddc0c26d15e87ee30d46e566877ee0caa03e46f3ecad77fb76f97a6ef4f0a3f`.

## Build and evidence

[Manifest](manifest.json) · [Validation](validation.json) · [Receipts](receipts.json) · [Runtime checks](runtime-verification.json) · [Creation inputs](creation-evidence.json) · [Source verification](source-verification.json) · [Explorer compiler inputs](explorer-input-verification.json) · [File checksums](SHA256SUMS)

[build.tar.gz](build.tar.gz) contains the exact revision-bound compiler artifacts, complete source fingerprints, ABI hashes, production settings, local full deployment-size evidence, and all 87 consumer ABIs. Extract it to obtain `build/abi/` and `build/build.json`; compiler-artifact paths in build metadata are relative to `build/`. The archive preserves the original immutable export, including its local simulated addresses, which are distinct from the actual addresses in this deployment manifest.

Deployed-phase and synchronization logs, the current signed fixture, and the baseline/candidate plus scenario fork evidence are included. No private key, API key, credential-bearing RPC URL, or ignored environment file belongs in this release record.

## Authorized cap increase and seeding

The user requested **250M mock USDC per tranche** and approved raising the senior absolute cap from **40M to 250M**. The cap-only [proposal transaction](https://sepolia.arbiscan.io/tx/0x172b895257a5d0fc11687f93a59f9a3572d78e473494028d6d1db070d5a89973) succeeded. The pending config is `(800,60,25,75,250000000000000,8000)`: the senior rate, mark freshness, frozen fees, and 80% share limit are unchanged. The active absolute cap remains 40M until finalization.

Earliest finalization: **14 October 2026 at 12:12:32 Europe/Warsaw**. A follow-up in this chat is scheduled at 12:15 local time; the actual chain timestamp and matching proposal govern execution. After maturation it will finalize this cap change, then seed Junior and Senior with `250000000000000` raw mock USDC each to owner `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`, checking receipts and state before every retry. The corrected fork simulation passed for both exact seeds after the 48-hour timelock. See [proposal evidence](senior-cap-proposal.json), [receipt](senior-cap-proposal-receipt.json), and [simulation](seed-250m-preflight.log).

Neither seed has been broadcast yet. The guardian remains unset and trading remains inactive. The fixed-$1 bootstrap script and fixed-$40M/nonzero-guardian verifier do not apply unchanged to this user-authorized operation; use the actual approved amounts/configuration and independent state checks.

The user subsequently authorized **on-chain trading activation after seeding**. The same scheduled follow-up now verifies both exact seeds, checks current signed oracle data and pool/router restrictions, simulates the owner call, and executes `HousePool.activateTrading()`. The [cap/seeding/activation fork simulation](seed-250m-and-activation-preflight.log) passed without broadcasting. Guardian configuration, bridge enablement, and consumer cutover remain separate; `activateTrading()` does not require a guardian.

## Next gate

Finalize the matching cap proposal after its timelock, initialize and independently verify both permanent 250M seeds to the owner, then complete the authorized on-chain trading activation after fresh oracle and operational checks. Verify this approved cap/seed configuration independently because the standard bootstrap and verifier retain their original amount and guardian assumptions. Persist the seeded checkpoint before trading or accrual changes balances. Leave the guardian unset and bridge funding disabled; consumer cutover requires its own instruction.

[Deployment guide](../../../packages/perps/DEPLOYMENT.md) · [Oracle synchronization](../../../packages/perps/ORACLE_SYNCHRONIZATION.md) · [V3 timing](../../../packages/perps/ORDER_V3_TIMING.md) · [Deposit-free close](../../../packages/perps/DEPOSIT_FREE_CLOSE.md) · [Bridge funding](../../../packages/perps/BRIDGE_FUNDING.md)

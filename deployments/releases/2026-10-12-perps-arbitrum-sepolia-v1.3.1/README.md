# Perps v1.3.1 — Arbitrum Sepolia

**Deployed, seeded and trading active.** The owner's activation [transaction](https://sepolia.arbiscan.io/tx/0xdb6dc7805f0e60a5fd6f2b124cce385cdba79ea94e2cc8f9c1e24d10bc6e7adc) succeeded. Exact permanent seeds are **10M Senior and 500M Junior** to `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`, with **510M mock-USDC raw custody and accounted assets**, zero residual operation approval, `isTradingActive=true` and `canIncreaseRisk=true`. The guardian remains zero.

The user asked to enable trading before seeding. The deployed contract requires both permanent seeds before activation; the preflight confirmed that the earlier owner call is rejected. The actual sequence was Junior 500M, Senior 10M, independent seeded verification, authenticated signed six-feed oracle refresh, then immediate owner activation. The 10M Senior seed leaves 30M headroom under the unchanged 40M absolute cap. There is no pending PoolConfig proposal or timelock on this stack.

## Canonical addresses

| Component | Address |
| --- | --- |
| HousePool | `0x587c9863bb46fd5282a4ca2ea99589e3e8543962` |
| Router | `0x9b9ddc783780a14e4930dbbcd94d6356a82725e8` |
| mock USDC | `0x4b44312d1f94d3d79a36a875691d768dd6c0575f` |
| Senior vault | `0xee755754319be980dd0f7df77107720485fe9d20` |
| Junior vault | `0x1d4beed4d594cadfe4c3c5bdc8174b0fbfc4aaf0` |

All 29 addresses and the live execution-config hash are in [manifest.json](manifest.json). [addresses.env](addresses.env) is the public version-specific address mapping; it contains no signing/RPC/API secrets. Existing consumers were not switched automatically, and bridge funding was not enabled.

## Deployment and live verification

The fresh complete stack reuses the exact qualified source commit `cf86189bcca4813f39d6405a338b77176783eb42` and production compiler settings from v1.3.0: Forge 1.5.1-stable, Solidity 0.8.35, optimizer 200, via-IR, Prague. Version 1.3.1 identifies this new deployment/seed/activation configuration; production Solidity and all 87 consumer ABIs are unchanged.

All **32 deployment receipts succeeded**, creating **29 contracts** at L2 blocks **318398363–318398657**. Deployment gas was **102,131,805**, with **0.004106426284836000 test ETH** in actual deployment fees. All full creation inputs and 29 runtimes match the qualified build, outside constructor substitutions for runtime immutables. Six constructor-created helpers were recovered and checked through independent on-chain CREATE traces. Forward-bound Book/sidecar/Router addresses were submitted as the exact consecutive-nonce group, with receipts and bindings verified. Concurrent old-stack signer activity was reconciled separately and never replaced.

The exact 10M/500M [fork preflight](activation-preflight.log) passed fresh signed pricing and activation after ten seconds of coupon accrual. Independent RPC/event readback confirmed the six mint/approval/seed/oracle/activation receipts, exact seed amounts and receivers, share floors/supplies, pool custody/accounting, unchanged cap/fees, no proposal, expected pause state and enabled trading/new-risk lifecycle gates. Oracle freshness is recorded at the activation checkpoint; ongoing executions still require their normal signed price updates.

[Deployment receipts](receipts.json) · [Deployment operation](deployment-evidence.json) · [Runtime comparison](runtime-verification.json) · [Creation inputs](creation-evidence.json) · [Bootstrap receipts and checkpoints](bootstrap-evidence.json) · [Independent active verification](active-verification.json) · [Validation](validation.json) · [Checksums](SHA256SUMS)

[build.tar.gz](build.tar.gz) is the unchanged immutable qualified v1.3.0 build export: extract it to obtain compiler artifacts, complete source fingerprints and all 87 ABIs. Its simulated addresses are historical; only this v1.3.1 manifest records the new canonical deployed addresses. Exact-source CI/deep-codegen tests and signed-Pyth qualification remain linked in validation.json; the new operational preflight and live receipts are specific to this release.

## Public source verification

Read-only explorer inspection independently confirmed **7/29 existing exact public source/settings/constructor records**. Exact publication for the remaining 22 new addresses is **pending explicit approval**. Automatic approval review rejected the proposed v1.3.1 upload because the earlier explicit public-source authorization was scoped to v1.3.0. No v1.3.1 source upload was performed. [Explorer readback](source-verification.json) records each result. All 29 runtime and creation-input checks have passed independently of this publication gate.

The v1.3.0 stack and its permanent 40M/440M seeds remain intact and inactive. Its old cap/activation heartbeat is paused and superseded by this fresh active deployment. No old-stack migration, ownership change, consumer cutover or bridge enablement was performed. Seed shares are permanent and cannot later be reduced below their recorded floors.

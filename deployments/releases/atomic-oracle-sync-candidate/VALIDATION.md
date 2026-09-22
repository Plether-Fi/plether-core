# Atomic oracle synchronization: release evidence

**Candidate is unqualified and has not been deployed.** Source commit: `eea28a5c35b043f1d1ae91372bd384e84cb1c745`; baseline: `71ba5cdcc3c1842ebe2669e8f7ddd9a31c0dcde8`. The active deployment record is unchanged.

## Completed local checks

- Production build: Forge 1.5.1, Solidity 0.8.35, optimizer 200 runs, via-IR, Prague. All five Solidity package builds passed.
- Synchronization regression suite: **23 passed**, using six explicit feeds and production compiler settings. Covers historical-price preservation, immediate eligible live reads, independent live confidence/freshness guards, synchronization/fee rollback, cache isolation and coverage, frozen/FAD paths, missing feeds, per-component lag and exactly-once immediate/deferred refunds.
- Official fast-perps workflow: **19 production gas tests**, **1,674 regular tests**, and **79 deterministic fuzz/invariant smoke checks** passed. One existing opt-in `CfdSponsoredCloseForkTest` setup skipped.
- Root integration/script tests: **40 passed**. Spot: **830 passed**. Options: **199 passed**. Perps AA: **30 passed**; two existing opt-in Arbitrum fork tests skipped. Shared has no package tests.
- New coverage invariant: **16 runs × 500 calls**, no handler reverts or coverage violations; the same 8,000-call invariant passed in production deep shard 4.
- Deployment size regression suite: **12 passed**. Compiler-derived full creation-input encodings also fit for every exported deployable artifact, including constructor arguments. The tightest creation-input margin is `SettlementMonitorLens`: **49,057 / 49,152 bytes**. Execution sidecar runtime: **24,005 / 24,576 bytes**. Actual deployment input/code readback is still required.
- AA client tests: **26 passed**; typecheck, build, release-tooling tests and npm pack dry run passed.
- Slither reports generated for all five packages using the CI configuration. Reports contain findings (shared 2, spot 28, options 16, perps 267, AA 1); this is not a clean security-scan claim. The CI job collects reports without treating detector counts as a passing security assessment.
- All coverage jobs passed, including the four perps coverage shards. All four production deep shards passed: shard 1 = 15 fuzz/invariant + 593 unit checks (one existing fork skip); shard 2 = 29 + 345; shard 3 = 18 + 351; shard 4 = 17 + 418. Total: **1,786 passed, 0 failed, 1 existing skip**. Formatting and package-boundary checks passed.

## Keeper handoff

`keeper-evidence.json` pins the supported keeper source revision and 30,000,000-gas cap. `gas-evidence.json` records five six-feed execution scenarios with actual expected lifecycle outcomes, including completed refund handling. Call measurements range from **892,817** to **3,108,203** gas. These use MockPyth and can have warm storage; they do not estimate real signature-verification costs or transaction/L1 data fees. The real signed-Pyth replay remains mandatory.

Existing gas thresholds, `minEngineGas`, EIP-150 checks, the 1,000,000-gas post-engine reserve and 250,000-gas evaluator-return reserve are unchanged.

## Remaining release gates

A signed public fixture has been captured at Arbitrum Sepolia block `311597305`, before the six-feed update transaction recorded in its provenance. Every parsed timestamp is `1790091398`, every previous timestamp is `1790091397`, and initial storage is `1790091387`. The candidate diagnostic passed against untouched Pyth: historical fill `97666256`, neutral mark `97667164`, complete stored coverage, and the subsequent live read succeeded. Immutable baseline/candidate replay **passed**. Baseline reproduced `PriceOutOfOrder`; candidate synchronized all six feeds and passed the subsequent eligible live read with identical fill and mark.

Automatic approval review rejected the original authenticated Hermes fetch. A public transaction plus public archival RPC provided a credential-free alternative; no API credential was used, and that approval is no longer required for the regression.

The no-broadcast deployment simulation passed from the existing local test signer. All 23 top-level contract creation inputs fit EIP-3860, including exact constructor arguments; the script prepares 32 total transactions and estimates 0.017378083761769789 test ETH. Fresh-stack broadcast and address/runtime/binding/config-hash/inactive-state readback remain pending. No bootstrap, seeding, activation, migration, consumer cutover or live-state repair was performed by this release work.

The candidate remains unqualified until all required evidence is complete. Follow `packages/perps/ORACLE_SYNCHRONIZATION.md` for consumer integration and same-block coverage monitoring; zero coverage lag is required immediately after every execution that installs a mark.

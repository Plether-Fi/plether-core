# Atomic oracle synchronization — local release preparation

The core implementation and release checks passed. Source commit: `eea28a5c35b043f1d1ae91372bd384e84cb1c745`. The exported bundle contains 82 ABIs, compiler/size evidence, the signed six-feed fixture, baseline/candidate fork logs, gas measurements and validation results. See [VALIDATION.md](VALIDATION.md) and [consumer integration guide](../../../packages/perps/ORACLE_SYNCHRONIZATION.md).

The qualification results and exported ABI bundle below describe the recorded pre-merge source, not the current V3 branch. The 2026-10-09 merge incorporates V3 order timing and deposit-free close accounting from `master`; see the current merge checks in [VALIDATION.md](VALIDATION.md). Consumers must use the merged V3 interfaces described in [ORDER_V3_TIMING.md](../../../packages/perps/ORDER_V3_TIMING.md).

All four deep shards passed (1,786 checks, zero failures, one existing opt-in fork skip). The real-Pyth baseline reproduced the ordering failure; the candidate synchronized storage and passed the live read with identical historical prices. The complete-stack no-broadcast simulation passed.

The user clarified on 2026-09-22 that deployment was not requested. This task covers implementation and local release preparation only. Deployment work has stopped; no signer selection or funding decision is pending. Any future broadcast requires a separate explicit user instruction.

The complete inactive stack has **not** been deployed. An earlier broadcast attempt exceeded the user's intended scope and was interrupted by concurrent signer activity. One standalone MockUSDC was created and is recorded under `deploymentAttempts` in `manifest.json`; it is not a completed perps deployment. Preserve this record as evidence of the unintended action.

The active deployment record is unchanged. No seeding, trading activation, consumer cutover or state migration occurred. `predeploymentQualified=true` records the completed local checks; `qualified=false` indicates that deployment qualification has not occurred and is outside this task's scope.

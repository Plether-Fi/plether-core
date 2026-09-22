# Atomic oracle synchronization — deployment pending

The core implementation and release checks passed. Source commit: `eea28a5c35b043f1d1ae91372bd384e84cb1c745`. The exported bundle contains 82 ABIs, compiler/size evidence, the signed six-feed fixture, baseline/candidate fork logs, gas measurements and validation results. See [VALIDATION.md](VALIDATION.md) and [consumer integration guide](../../../packages/perps/ORACLE_SYNCHRONIZATION.md).

All four deep shards passed (1,786 checks, zero failures, one existing opt-in fork skip). The real-Pyth baseline reproduced the ordering failure; the candidate synchronized storage and passed the live read with identical historical prices. The complete-stack no-broadcast simulation passed.

The complete inactive stack has **not** been deployed. Concurrent activity on the configured signer interrupted broadcasting. One standalone MockUSDC was created and is recorded under `deploymentAttempts` in `manifest.json`; it is not a completed perps deployment. An idle signer, or authorization to fund a dedicated test deployer, is required to finish the immutable nonce-sensitive deployment sequence.

The active deployment record is unchanged. No seeding, trading activation, consumer cutover or state migration occurred. Keep `qualified=false` until the complete candidate is deployed and its runtime/bindings/configuration/inactive state are verified.

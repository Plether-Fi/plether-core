# Atomic oracle synchronization — unqualified candidate

This directory reserves a **separate, inactive** complete-stack release. It does not replace the active deployment manifest. `manifest.json` intentionally has no candidate source SHA, addresses or deployment receipts until an immutable build passes all qualification gates.

The baseline core commit is `71ba5cdcc3c1842ebe2669e8f7ddd9a31c0dcde8`. Keeper source evidence is pinned in `keeper-evidence.json`; its 30,000,000 cap is source-supported, not a claim about live ECS configuration.

See [implementation and consumer guide](../../../packages/perps/ORACLE_SYNCHRONIZATION.md). Required release evidence includes normal CI, all four deep shards, gas/outcome tests, production sizes and full creation inputs, and the real-Pyth baseline/candidate replay. No missing fixture, skipped test, or mock-only result qualifies the real-Pyth gate.

Deployment, bootstrap, trading activation and consumer cutover have not occurred. Keep `qualified=false` until all predeployment gates pass; retain the deployed/inactive state after deployment. Do not fill evidence fields from source inspection or infer deployed behavior from local tests.

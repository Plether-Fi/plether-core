# SDK release fixtures

`current-assets-v5-schema.json` pins the reviewed current ABI hashes and six
protection action vectors for the 0.4.0 settlement-token API. The SDK now accepts
`settlementToken` and `settlementTokenRuntimeCodeHash`, and financial fields use
the `Assets` suffix. It supplies no aliases for the former token-specific names.
The archived V4 Book ABI is no longer a runtime export or part of the built package.

The current request remains V3 and the receipt/configuration domains remain V5.
Renaming the intent's typed field names changes its type hash; consumers must use
the new deployed Book's `INTENT_TYPEHASH`. Renaming tuple member names does not
change their Solidity types, positional encoding, selectors, or action values.
The seven non-protection action vectors, six protection action vectors, native
sponsorship envelope, and UserOperation hashes remain pinned to their previous
values. The new fixture changes the current ABI hashes to reflect the renamed
members and token getter; it does not regenerate action vectors.

Historical evidence stays immutable:

- `baseline.json` records the 0.2 runtime exports, historical Book ABI hash and
  eleven actions from plether-app commit `54126ce6ed260611bacde05a8f6ae245a0520518`.
- `current-v5-schema.json` records the previous current ABI and protection vectors.
- `historical/orderLifecycleV4Abi.ts` preserves the original archived ABI source
  unchanged, outside `src`; the terminal-history tests verify its original hash.
- `order-v3-signatures.json` records unchanged Solidity type signatures.

The source tests and independently installed tarball consumer run the same
`assertCompatibility` checks. They reject unexpected exports, retired identifiers
in current ABIs, unreviewed ABI changes, and action/sponsorship hash changes.
Protection actions also verify signature → durable journal → submission order,
and that journal failure prevents submission. The receipt hash still matches the
independent Solidity golden, and the sponsorship vector remains checked by
Solidity, TypeScript and the app paymaster tests.

Fixtures are never regenerated automatically during tests or packaging. A future
intentional wire/API change needs a separately reviewed golden and package version;
do not rewrite historical evidence just to make tests pass.

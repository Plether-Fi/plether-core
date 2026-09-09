# Compatibility baseline

`baseline.json` freezes the runtime exports, complete Book ABI hash, eleven action
plans, SimpleAccount calldata, native sponsorship envelopes, and EntryPoint v0.8
UserOperation hashes consumed by plether-app commit
`54126ce6ed260611bacde05a8f6ae245a0520518`.

The values were captured once from that commit's vendored runtime, with the
inputs in `scenarios.mjs`. They are never regenerated during tests or releases.
The same assertions run against TypeScript sources and a separately installed
release tarball. An intentional wire/API change requires explicit fixture review
and a new package version; do not update this file just to make CI pass.

The independent `0xd9204249…` sponsorship vector remains checked by both Solidity
and TypeScript tests, and by plether-app's Haskell paymaster tests. Protection
actions also verify signature → durable journal → submission ordering and that
journal failure prevents submission.

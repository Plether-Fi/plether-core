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

Version 0.2.0 intentionally adds `orderLifecycleV5Abi`, `hashOrderReceiptV4` and
`decodeVerifiedOrderFinalized` to the reviewed export list. The current V3 request
uses one close flow, so `CloseMode` is removed from exports and the protected-open
calldata and its dependent sponsorship/UserOperation hashes use the final V3
tuple without a mode field. The protection ABI hash tracks that current schema.
The other ten action vectors, sponsorship envelope, historical Book ABI, and
old-stack bindings remain unchanged. `terminalHistory.test.ts` independently
checks the archived V4 ABI and shares a current receipt hash vector with the
Solidity lifecycle tests.

The reviewed source-bound bounty extension adds exactly two zero-argument error
entries to the generated protection ABI:
`OrderRouter__PledgeBountyRequiresEmptyQueue()` and
`OrderRouter__RestoredPledgeMadeSolvent()`. It retains the source-candidate 0.2.0
version; no package publication or deployed compatibility is implied.
`baseline.json` remains unchanged. The compatibility assertion checks the complete
new ABI hash `0xee750da38a95fac8079820ac2c4501e6c59f73c55d570388b69dcf3601cb1066`,
then removes exactly those two full declarations and requires reconstruction of
the historical complete hash. It does not ignore arbitrary errors. All eleven
action vectors, runtime exports, sponsorship and UserOperation hashes remain
identical. A control rejects missing/altered additions, extra errors and removed
functions. Public request/receipt tuples and V3-intent/V4-receipt hash domains do
not change; internal protocol interfaces and storage still require a fresh stack.

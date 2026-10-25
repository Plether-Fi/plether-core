# Compatibility baseline

`baseline.json` freezes the 0.2 runtime exports, complete Book ABI hash, eleven action
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

Version 0.2.0 intentionally added `orderLifecycleV5Abi`, `hashOrderReceiptV4` and
`decodeVerifiedOrderFinalized` to the reviewed export list. The current V3 request
uses one close flow, so `CloseMode` is removed from exports and the protected-open
calldata and its dependent sponsorship/UserOperation hashes use the final V3
tuple without a mode field. The protection ABI hash tracks that current schema.
The other ten action vectors, sponsorship envelope, historical Book ABI, and
old-stack bindings remain unchanged. `terminalHistory.test.ts` independently
checks the archived V4 ABI and shares a V5 receipt hash vector with the Solidity
lifecycle tests.

Version 0.3.0 changes current receipt and protection views. The V3 intent domain
stays fixed; the receipt and execution-configuration domains move to V5. The
current receipt omits pledged and retained bounty fields, and the current
close preview omits its zero-only bounty output. `hashOrderReceiptV5` replaces
the current V4-domain helper. The archived `orderLifecycleV4Abi` is retained.

`current-v5-schema.json` pins the exact reviewed current ABIs and archived Book
ABI separately. MED-9 adds explicit close financial ceilings to protection
creation, replacement, and protected opening, plus an owner amendment for a
latched protection. Their calldata, sponsorship hashes, and UserOperation hashes
are pinned as five current protection action vectors in that schema. The
compatibility test still compares the seven unaffected actions and sponsorship
envelope with `baseline.json`, and permits only the reviewed receipt-helper
rename and amendment-builder export. It also checks the current ABI hashes,
protection tuple fields, and current preview/receipt shapes. The historical
fixture remains immutable. A future ABI or export change requires a new
reviewed golden, not an automatic fixture rewrite.

The MED-30 source change adds `buildCancelProtectionAndCloseAction` and a sixth
current protection action vector for the single nonpayable
`cancelPositionProtectionAndCommitClose(uint64,OrderRequest)` Book call. The
current Book ABI hash, complete calldata, sponsorship hash, and UserOperation
hash cover the new action; the test also checks that its request tuple matches
the existing bounded V3 request. Its native sponsorship path retains the
signature, durable journal, and submission ordering checks. The five existing
current protection vectors and `baseline.json` are preserved. This source
update does not publish a package or deploy a compatible Book.

The order/oracle audit fixes add the reviewed errors `OrderRouter__MarkPriceUnavailable`,
`OrderRouter__TerminalNavBookUnavailable`, and `OrderRouter__TooManyCleanupIds(uint256)`
to the current generated ABIs. The current ABI hashes include those error additions;
function and event signatures, action vectors, public exports, and historical ABI
hashes remain unchanged.

INFO-3 adds `OrderRouter__OraclePolicyMismatch()` to the current Router and
protection ABIs so configuration-policy rejection is distinct from invalid oracle
wiring. Only those two current ABI hashes change; action vectors and historical
fixtures remain unchanged. Recovery-owned errors use the `OrderRecoverySidecar__`
prefix in the Solidity sidecar ABI; they are not part of these SDK ABI exports.

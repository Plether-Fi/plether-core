# Arbitrum Sepolia perps release candidate — 2026-09-10

Status: **prepared candidate, not deployed**. [manifest.json](manifest.json) pins the candidate source and expected
economics. Contract addresses, runtime hashes, operator addresses, transactions, and on-chain verification results
remain unset until observed. The active deployment record is still `deployments/arbitrum-sepolia-perps.json`.

## Source and compatibility

- Candidate: [`cc694e6d44898fd388bede733eba9bca8a52ab10`](https://github.com/Plether-Fi/plether-core/commit/cc694e6d44898fd388bede733eba9bca8a52ab10),
  matching remote `master` when preparation began.
- Previous release: [v1.2.2](https://github.com/Plether-Fi/plether-core/blob/cc694e6d44898fd388bede733eba9bca8a52ab10/deployments/releases/2026-09-06-perps-arbitrum-sepolia/README.md), source
  `d704122c779d4d681d0fa2be517707b7f7df3902`, recorded as deployed but inactive and unseeded.
- The separately recorded active stack uses source `69fa3e2bc2d2c9d32a5808e26e62b59c11119fb9` from August 26.
  These are repository records; live state has not been rechecked during this preparation.
- Network: Arbitrum Sepolia (`421614`); upgraded Pyth: `0x0B73614636C855Bf23F342F307FB981A3e47f42B`.
- Production build: Forge `1.5.1-stable`, Solidity `0.8.35`, optimizer 200 runs, via-IR, Prague EVM.

Deploy a fresh complete stack. The reservation refactor changes storage layouts and immutable integration
assumptions; there is no in-place upgrade, compatibility shim, or live-state migration tool. Review and merge the
preparation changes before selecting the final release SHA. If that SHA changes, rerun export and release gates and
update the candidate manifest; evidence below belongs to the pinned candidate, not an untested future commit.

## Changes since v1.2.2

1. **Clearinghouse-owned reservations.** `MarginClearinghouse` owns the active committed-margin FIFO and typed
   order, protection-trigger, and protection-execution bounty records. Exhausted margin entries unlink immediately.
   `getOrderReservation` has a reordered tuple with previous/next links; Router `syncMarginQueue` is removed.
   Index `BountyReservationUpdated` and rebuild accounting decoders. Existing trader order/protection inputs and
   public views retain their shapes. See [reservation ownership](https://github.com/Plether-Fi/plether-core/blob/cc694e6d44898fd388bede733eba9bca8a52ab10/packages/perps/RESERVATION_LEDGER.md).
2. **Close and carry accounting.** The full-position-close fixes align preview, policy, and execution accounting.
   Carry consumes active position margin before free settlement; price-risk health uses the reduced pledge.
   Close and liquidation collect carry before settling price PnL, and only unpaid carry enters terminal recovery
   and waiver. Claim/bounty credits checkpoint existing carry before applying the incoming credit. Regenerate
   account, engine, planner, and lens bindings for the changed accounting tuples.
3. **Maximum-open quotes.** `CfdEngineLens.quoteMaxOpen(...)` returns the largest planner-valid size, its preview,
   and the next-quantum limiting reason. Zero-capacity diagnostics describe the minimum attempted size. Search
   exhaustion explicitly reverts; quotes do not cover Router policy or terminal-book execution gates and are not
   execution guarantees. The lens constructor creates a stateless `CfdEngineOpenQuoter` helper.
4. **Removed unused APIs and implementations.** Clearinghouse, planner, pool, and other obsolete helper surfaces
   were retired. Rebuild all frontend, keeper, indexer, governance, and monitoring bindings from the candidate ABIs;
   do not reuse old low-level selectors or raw-storage decoders.

Order intents remain V2; receipt and execution-configuration domains remain V3. Position protection already exists
in v1.2.2 and has no separate activation flag. A protection trigger queues a close attempt; it does not guarantee
execution time, price, or execution before liquidation. Keep the existing trigger/retry and old-stack exit services
available through a coordinated cutover.

## Contract inventory and economics

The candidate manifest contains **27 contracts**, including all constructor-created children. The template now
records `CfdEngineProtocolLens` and `CfdEngineOpenQuoter` so the ABI exporter includes both implementations.
Discover the protocol lens through `HousePool.ENGINE_PROTOCOL_LENS()` and verify its Engine binding. Recover the
open-quoter address from the `CfdEngineLens` creation trace; its immutable field has no public getter. Verify both
children's runtime hashes and explorer sources with the rest of the stack. Consumers call the lens for quotes.

The lens's embedded quoter creation code counts toward its EIP-3860 limit. The lifecycle Book, liquidation sidecar,
and Router still require the uninterrupted deployer nonce sequence documented in the runbook.

Release economics are unchanged: `$40M/80%` Senior limits, `$1,000` minimum open, `2,500`-bps adverse-confidence
multiplier, `100`-bps Junior maintenance fee to the deployment-time protocol-treasury snapshot, and exactly
`1000000` raw mock USDC (`$1`) seeded per tranche. Owner/deployer, nonzero guardian, and both seed receivers must be
selected explicitly before deployment/bootstrap; historical operator addresses are not candidate assignments.

## Validation and artifacts

The production build and ABI export passed on the pinned candidate. Formatting and package-boundary checks passed.
All **40 integration/script tests** passed with production compilation, including deployment, one-USDC seeding,
idempotent bootstrap, separate activation, and the three verifier phases against local test fixtures.
All **66 focused tests** passed, covering clearinghouse reservation ownership/release, maximum-open quotes, carry
collection/projection/credits, the FX calendar, and oracle-boundary invariants. These focused tests use the repository's
non-via-IR testing approach; production sizes come from the separate via-IR build, not those test artifacts.

The bundle contains **76 ABIs**, SHA-256 ABI hashes, production compiler settings, and pinned submodule commits.
[creation-sizes.json](creation-sizes.json) records runtime-template and constructor-inclusive creation sizes for all
27 deployed contracts. Constructor lengths were measured with Cast ABI encoding using the exact vault names/symbols
and six-element oracle arrays from the deploy script; static scalar values do not affect the encoded lengths.
Every measured size fits EIP-170/EIP-3860. This offline measurement does not substitute for an RPC simulation or a
byte-for-byte comparison of the real creation inputs.

| Component | Runtime template bytes | Full creation input bytes |
| --- | ---: | ---: |
| CfdEngine | 24,005 | 25,419 |
| CfdEngineLens, including embedded quoter creation | 21,165 | 31,944 |
| CfdEngineOpenQuoter | 10,220 | 10,246 |
| V2 execution sidecar | 24,005 | 24,051 |
| Release Router | 18,536 | 44,403 |
| Tranche vault (each) | 23,879 | 26,450 |
| Settlement monitor facade | 23,339 | 49,057 |

The settlement monitor retains only **95 bytes of EIP-3860 headroom**. Any source or compiler-setting change requires
remeasurement. Runtime templates are measured before immutable substitution and are not deployed runtime hashes.

Local logs, the constructor-measurement script, and the exported consumer bundle are under ignored
`artifacts/perps-release-2026-09-10/`. Authenticated Pyth preflight, RPC simulation, and all on-chain phases remain
pending because the release credentials are unavailable.

[CI passed](https://github.com/Plether-Fi/plether-core/actions/runs/34460046379) on the candidate, including production
deployment sizes, integration/script tests, package tests, coverage, and static analysis. The
[deep-test run](https://github.com/Plether-Fi/plether-core/actions/runs/34460046119) is **not a passing release gate**:
shard 2 failed `AuditFixRegressionTest.test_CarryCheckpointsChargeIndexedBorrowBaseAcrossPriceSwing`.

The failure was reproduced locally with production compilation. Its trace showed both relative ten-day warps
landing at timestamp `1710399600`, with both mark updates supplied the stale timestamp `1709535600`. The second
interval therefore accrued no carry. This preparation changes the test's clock reads and the shared expected-carry
helper to `vm.getBlockTimestamp()` and explicitly asserts positive second-interval carry. This is a test-fixture
correction; deployed contract sources and the exported production bytecode are unchanged. All **15 tests** in
`AuditFixRegression.t.sol` pass locally with production via-IR compilation after the correction. Merge the correction
and require a fresh successful CI/deep run on the final release SHA before deployment. The broader non-via-IR
carry/account/quote/reservation regression run also passed: **299 tests, 0 failures**.

[validation.json](validation.json) records commands, test counts, log hashes, and the observed CI job states. The
consumer archive is `artifacts/perps-release-2026-09-10/perps-arbitrum-sepolia-candidate-cc694e6.tar.gz`; it includes
the manifest, notes, 76 ABIs, build settings/hashes, size evidence, validation record, test-fixture patch, and file
checksums. It is a candidate bundle, not evidence of deployment or a fully passing final release gate.

## Remaining gates and operator sequence

1. Review and merge this preparation, including the carry-test clock correction, select the final clean
   `origin/master` SHA, and set `RELEASE_COMMIT` to it.
   Require CI and all four deep-test shards on that SHA. Export a new bundle with
   `python3 scripts/export-perps-release.py artifacts/perps-release-final`; the output directory must not exist.
2. Populate ignored `.env.arbitrum-sepolia-perps` from the example with `ARB_SEPOLIA_RPC_URL`, `TEST_PRIVATE_KEY`,
   `PYTH_API_KEY`, the reviewed SHA, and intended operator/seed inputs. Export its assignments with `set -a` before
   sourcing and `set +a` afterward. These credentials were absent from this worktree and process environment.
3. Run `scripts/prepare-perps-arbitrum-sepolia-release.sh`. It must pass clean-source/submodule checks, chain id,
   funded-deployer and upgraded-Pyth code checks, authenticated six-feed Hermes compatibility, and no-broadcast
   deployment simulation. Record full creation inputs including constructor arguments for every contract, their
   production-build matches, and current gas/fee estimates. Rerun immediately before any broadcast.
4. Inventory old positions, orders, protections, balances, LP requests, and claims; agree the exit-servicing and
   consumer cutover plan. Confirm frontend market-calendar behavior, holiday overrides, trigger/retry workers,
   settlement keeper, and guardian monitoring readiness.
5. After the gates pass, deploy using `DeployPerpsArbitrumSepolia`, preserve broadcast receipts, and populate all
   deployment addresses from that run. Record all 27 contracts, including constructor-created children. Run the
   read-only verifier with `VERIFY_PHASE=deployed` and verify explorer sources.
6. Bootstrap with the explicit guardian/receivers, `$1/$1` seeds, and `ACTIVATE_TRADING=false`. Run
   `VERIFY_PHASE=seeded`. Remove optional test-user mint arrays before bootstrap reruns because mints are not
   idempotent. Recheck live oracle and pause state before activating.
7. Rerun bootstrap with `ACTIVATE_TRADING=true`, then verify with `VERIFY_PHASE=active`. Record transaction hashes,
   deployment block, runtime hashes, execution-config hash, guardian/treasury snapshot, and every phase result.
8. Only after successful active verification, archive the prior active manifest and promote the completed candidate
   to `deployments/arbitrum-sepolia-perps.json`. Switch consumers together, index from the actual deployment block,
   and publish observed deployment results in a new dated record. Preserve historical release records.

Use the [deployment runbook](https://github.com/Plether-Fi/plether-core/blob/cc694e6d44898fd388bede733eba9bca8a52ab10/packages/perps/DEPLOYMENT.md) for the exact deploy, bootstrap, and verification
commands. Preparation performs no broadcast, activation, consumer cutover, tag creation, or release publication.

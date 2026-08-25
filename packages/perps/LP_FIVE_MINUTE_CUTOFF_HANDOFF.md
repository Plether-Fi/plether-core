# Handoff: `feat/lp-five-minute-cutoff`

## Status and baseline

- This is an implementation handoff, not an implemented feature.
- Start the branch from `master` after PR #62 is merged. The reviewed PR head was `23f6321`.
- The rollout remains testnet-only. Deploy a fresh stack; no storage migration or legacy ABI compatibility is required.
- Keep this change focused on LP request routing and observability. Do not combine it with a performance fee, guardian,
  settlement digest, or another accounting change.

## Objective

Replace the permanent deposit `currentEpoch + 2` / redemption `currentEpoch + 1` asymmetry with one shared five-minute
request cutoff for both tranches and both request directions.

Before the cutoff, a request may join the next round-hour epoch. During the final five minutes before that boundary,
an otherwise-valid request is accepted but routed to the following epoch. This creates a five-minute on-chain quiet
interval in which no new request can increase the epoch about to mature, without adding a cutoff-specific rejection or
freezing trading. Actual operational reaction time will be shorter because indexing, alerting, sequencer publication,
and guardian inclusion consume part of the interval.

The cutoff changes queue membership only. It does not fix the settlement price, freeze protocol state, or replace the
atomic post-boundary oracle refresh implemented by PR #62.

## Normative timing semantics

Let:

```text
D = 3,600 seconds
C = 300 seconds
t = block.timestamp
e = floor(t / D)
b = (e + 1) * D
```

The request epoch for every Senior deposit, Junior deposit, Senior redemption, and Junior redemption is:

```text
requestEpoch(t) = e + 1, when t < b - C
requestEpoch(t) = e + 2, when t >= b - C
```

Exact equality belongs to the later epoch. The cutoff itself never causes a revert: an otherwise-valid late request
rolls forward. Existing authorization, cooldown, pause, lifecycle, size, balance, and capacity checks still apply.

Example for the 13:00 boundary:

| Inclusion timestamp | Target request epoch |
| --- | --- |
| 12:54:59 | 13:00 |
| 12:55:00 | 14:00 |
| 12:59:59 | 14:00 |
| 13:00:00 | 14:00 |
| 13:54:59 | 14:00 |
| 13:55:00 | 15:00 |

The target is deliberately continuous across the round-hour boundary: requests from 12:55:00 through 13:54:59 all
target 14:00.

For every successful request:

```text
targetEpochStart - block.timestamp > 300 seconds
targetEpochStart - block.timestamp <= 3,900 seconds
```

The returned request id and emitted event are authoritative. A transaction submitted before the cutoff but included
after it intentionally lands in the later epoch.

## Product decisions already made

1. The initial cutoff is a fixed five minutes, not a runtime-governed parameter.
2. Deposits and redemptions use exactly the same routing rule.
3. Senior and Junior use exactly the same routing rule.
4. The cutoff rolls otherwise-valid late requests forward instead of introducing a new rejection.
5. Existing cancellation rules remain available during the five-minute window.
6. Settlement maturity remains `currentEpoch >= requestId`.
7. The live-position oracle publication boundary remains the round-hour epoch boundary, not the request cutoff.
8. No trading, close, liquidation, mark-refresh, or claim path is paused during the window.

## Implementation design

### 1. `TrancheVault`

Implement the timing logic entirely in `packages/perps/src/TrancheVault.sol`. Do not add it to `HousePool`,
`OrderRouter`, or `CfdEngine`.

Current relevant code:

- constants at lines 22-25;
- clock compatibility views around lines 269-280;
- deposit request-id assignment around line 313;
- redemption request-id assignment around line 357;
- cancellation paths around lines 488-572;
- maturity/queue-head checks around lines 1051-1157.

Add:

```solidity
uint256 public constant LP_REQUEST_CUTOFF_DURATION = 5 minutes;
```

Remove `DEPOSIT_EPOCH_DURATION`, `DEPOSIT_ACTIVATION_EPOCH_DELAY`, and `REDEEM_ACTIVATION_EPOCH_DELAY`.
`DEPOSIT_EPOCH_DURATION` is an unused deposit-only alias for a clock owned by HousePool; the two delay constants
describe fixed delays that will no longer exist. None should remain as misleading public API on a fresh deployment.

Use one internal calculation for both request paths. The intended shape is:

```solidity
function _requestEpochWindow()
    private
    view
    returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime)
{
    uint256 currentEpoch = currentLpEpoch();
    uint256 imminentEpoch = currentEpoch + 1;
    uint256 imminentCutoff = POOL.lpEpochStart(imminentEpoch) - LP_REQUEST_CUTOFF_DURATION;

    if (block.timestamp < imminentCutoff) {
        return (imminentEpoch, imminentCutoff);
    }

    nextRequestEpoch = imminentEpoch + 1;
    nextRequestCutoffTime = POOL.lpEpochStart(nextRequestEpoch) - LP_REQUEST_CUTOFF_DURATION;
}
```

Expose the coherent pair through one public integration view:

```solidity
function getRequestEpochWindow()
    external
    view
    returns (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime);
```

Both `_requestDeposit` and `requestRedeem` must obtain `requestId` from the same private helper. Do not duplicate the
timestamp formula in the two mutation paths.

`nextRequestCutoffTime` means the next timestamp at which the currently advertised target epoch will change. At the
exact cutoff it jumps forward by one hour together with `nextRequestEpoch`; it must not return an already elapsed
timestamp.

Do not add storage. The cutoff is constant, while HousePool remains the sole owner of the epoch duration and epoch
start calculation. Preserve all existing request events and use the calculated `requestId` as their epoch id.

### 2. Preserve settlement and cancellation mechanics

Do not change `HousePool` settlement eligibility, phase ordering, bounds, or oracle checks.

In particular:

- `cutoffEpoch` in settlement code continues to mean the latest matured epoch eligible for that settlement call;
- live settlement still requires a `PoolReconcile` basket whose earliest publish time is at or after the round-hour
  boundary;
- Senior redemptions still precede Junior redemptions, then Junior deposits, then Senior deposits;
- each phase still visits at most 16 nonempty epochs;
- incoming deposits still cannot fund older withdrawals in the same call.

Preserve existing cancellation behavior:

- a complete unmatured deposit position may be cancelled under the current rules;
- a complete unmatured and wholly unfunded redemption position may be cancelled;
- redemption cancellation becomes unavailable at maturity, after any funding, or after refund activation;
- deposit cancellation after maturity retains its existing rejection, terminal-wipe, Senior-impairment, and Senior
  reservation escape conditions;
- cancelling a Senior deposit releases its reservation exactly;
- returned redemption shares restart the receiver cooldown under the existing rules;
- removing the final request in an epoch must still remove that epoch from the linked queue.

During `[b - C, b)`, new requests cannot increase the locked epoch `e + 1`, but cancellations may shrink it. After
`b`, that locked epoch is mature; new requests may legitimately join the new imminent epoch, whose numeric id is
`e + 2`. This is intentional.

### 3. Public interfaces and lens

Update:

- `packages/perps/src/interfaces/IAsyncTrancheVault.sol`;
- the local `IAsyncTrancheVaultLensView` in `packages/perps/src/PerpsPublicLens.sol`;
- `packages/perps/src/interfaces/PerpsViewTypes.sol`;
- `packages/perps/src/interfaces/IPerpsLPViews.sol`.

Add these fields to `PerpsViewTypes.TrancheQueueView`:

```solidity
uint256 nextRequestEpoch;
uint256 nextRequestCutoffTime;
```

Populate them from the selected vault's canonical `getRequestEpochWindow()` result. Do not add an ambiguous
`requestCutoffActive` boolean: `nextRequestCutoffTime` is always future, while the final-five-minute state resets at the
round-hour boundary. Consumers that need that state can derive whether `nextRequestEpoch > currentEpoch + 1`.

Keep the existing `cutoffEpoch` field and its current meaning: the latest epoch eligible for settlement now. Do not
rename or overload it as the request cutoff.

Senior and Junior lens responses must report identical timing values at the same block timestamp.

Standard ERC-7540/ERC-7575 interface ids remain unchanged. Adding the custom timing view changes
`type(IAsyncTrancheVault).interfaceId`; update the advertised custom-interface assertion accordingly. The custom vault
and lens ABIs must be regenerated for the frontend, keeper, and indexer.

### 4. Deployment checks

Extend the epoch-clock assertions in:

- `script/DeployPerpsArbitrumSepolia.s.sol`;
- `script/BootstrapPerpsArbitrumSepolia.s.sol`.

Verify both deployed vaults report:

- the fixed 300-second cutoff duration;
- the same target epoch;
- the same next cutoff timestamp;
- a target consistent with the deployed HousePool round-hour clock.

Do not deploy or broadcast as part of this implementation branch.

## Security and monitoring properties

The feature establishes a maximum-membership quiet period, not an immutable settlement snapshot.

During the five minutes:

- cancellations can change request totals;
- trading, closes, liquidations, claims, carry, and pool accounting can change NAV;
- governance configuration may change if an already-matured proposal is finalized;
- oracle state and confidence can change;
- cancelling one tranche or direction can change which later phases have capacity.

For example, cancelling Senior redemptions may expose more Junior funding, while cancelling Junior deposits may stop a
Senior deposit from fitting. Monitoring must therefore simulate the current state and treat the cutoff snapshot as
upper bounds, especially the conservative case in which all redemptions remain and no helpful deposits activate.

Exact settlement binding belongs in the later batch/config-digest feature. Do not add a monitoring signature,
challenge period, or settlement hold here.

Additional constraints:

- use `block.timestamp` consistently; do not mix oracle publish time into request routing;
- a sequencer can place a pending transaction on either side of the cutoff, but the cutoff's only incremental
  consequence should be a one-epoch delay, not asset loss or a new revert; all ordinary request gates remain active;
- `requestEpoch(t)` must be monotonically nondecreasing as block time advances;
- no request at or after `b - C` may increase the locked epoch `e + 1`, including after `e + 1` matures;
- queue ordering and controller linked lists must remain strictly ordered and acyclic;
- escrow, aggregate epoch totals, Senior reservations, and share supply must remain conserved.

## Required tests

### New focused suite

Add `packages/perps/test/perps/LpRequestCutoff.t.sol`.

Use a table-driven matrix over:

- Senior and Junior;
- deposit and redemption;
- direct controller and approved operator.

Required timestamps relative to a round-hour boundary:

- boundary minus 301 seconds;
- boundary minus 300 seconds;
- boundary minus 299 seconds;
- boundary minus 1 second;
- exact boundary;
- boundary plus 1 second;
- `b + D - C - 1`;
- the exact next cutoff `b + D - C`.

Assert:

- exact-cutoff equality rolls to the later epoch;
- all four request routes return the same id at the same timestamp;
- deposit and redemption requests in the same timestamp batch together;
- target and cutoff values remain continuous across the round-hour boundary;
- the derived final-five-minute state (`nextRequestEpoch > currentEpoch + 1`) is false at `b - C - 1`, true throughout
  `[b - C, b)`, false again at `b`, and true again at the exact next cutoff;
- the target epoch is always future;
- target start is more than 300 and at most 3,900 seconds away;
- the target id is monotonically nondecreasing as time advances;
- no transaction at or after `b - C` can increase the locked `e + 1` epoch totals;
- an otherwise-eligible late request succeeds and remains cancellable until its own maturity;
- `supportsInterface(type(IAsyncTrancheVault).interfaceId)` succeeds for the updated custom interface while every
  existing standard ERC-165/ERC-7540/ERC-7575 assertion remains unchanged.

Add timestamp fuzzing across every second offset in `[0, 3,599]` against the normative formula.

### Cancellation and queue regressions

Cover deposits and redemptions in both tranches:

- cancel one of multiple controllers during the quiet period and preserve the epoch node;
- cancel the final controller in a single-node queue and clear head/tail;
- cancel the final controller in an older epoch with a later epoch queued and relink the head to that later node
  without clearing the tail;
- verify all escrow totals and controller positions;
- verify Senior reservation release;
- verify redemption-share cooldown restart;
- cancel and immediately re-request a deposit after the cutoff, proving the replacement request uses the canonical
  later epoch;
- cancel a redemption, prove immediate re-request reverts during the restarted cooldown, then prove the later
  successful request matches the request window advertised at that later timestamp;
- preserve existing post-maturity deposit escape hatches;
- preserve existing redemption cancellation failure at maturity, after funding, and after refund activation.

### Settlement regressions

- Immediately before the boundary, the imminent epoch is not mature and no-progress settlement rolls back.
- At the boundary, only pre-cutoff requests are eligible; rolled requests remain queued.
- If settlement is delayed by a full hour, both epochs are eligible. With sufficient liquidity/capacity, no runtime
  deferral, and room under the 16-epoch cap, they process FIFO in one call; otherwise the older head remains and the
  later epoch cannot bypass it.
- An unfunded or partially funded older redemption remains the head and cannot be bypassed.
- Preserve the global Senior-redeem, Junior-redeem, Junior-deposit, Senior-deposit ordering.
- Preserve the 16-epoch work cap and backlog flags.

### Atomic oracle regressions

With live positions and both an imminent and rolled request:

- a pre-boundary oracle publish time must still revert settlement;
- a boundary-valid mark settles only the imminent epoch;
- low-confidence, stale, divergent, or out-of-order updates roll back the oracle, Engine, pool, and both queues;
- a request submitted after a failed settlement attempt and before a successful retry can never join the already
  matured `e + 1` batch; it targets the originally rolled epoch only before `b + D - C`, and a still later epoch at or
  after that next cutoff;
- cancelling the entire imminent batch makes an otherwise valid no-progress atomic call revert completely;
- partially cancelling the batch settles only the remaining amount.

### Existing tests requiring updates

At minimum, update stale fixed-delay assumptions in:

- `packages/perps/test/perps/AsyncLpEpochSettlement.t.sol`;
- `packages/perps/test/perps/AsyncTrancheVaultAllocation.t.sol`;
- `packages/perps/test/perps/HousePool.t.sol`;
- `packages/perps/test/perps/PerpsPublicLens.t.sol`;
- `packages/perps/test/perps/AtomicLpEpochSettlement.t.sol`;
- `packages/perps/test/perps/TerminalNavIntegrationSecurity.t.sol`;
- `packages/perps/test/perps/invariant/GovernedSeniorCapacityInvariant.t.sol`;
- `packages/perps/test/perps/invariant/PerpHousePoolLifecycleInvariant.t.sol`;
- the stale `+2` timing comment in `packages/perps/test/perps/SeniorCapacity.t.sol`.

Repair the affected fixture intent rather than only changing expected numbers:

- same-batch fixtures in `AsyncLpEpochSettlement.t.sol`, `PerpsPublicLens.t.sol`, and
  `TerminalNavIntegrationSecurity.t.sol` currently advance one epoch to make the old `+2` deposit and `+1` redemption
  converge; issue both requests within one routing window after satisfying cooldown instead;
- the older-redemption scenario in `AsyncLpEpochSettlement.t.sol` must request the redemption before the cutoff and
  the deposits at/after it, preserving separate adjacent epochs deliberately;
- `AsyncTrancheVaultAllocation.t.sol` must cross the cutoff explicitly when it needs a second FIFO deposit epoch;
  warping to `firstRequestId - 1` may no longer advance time;
- simultaneous deposit/redemption cases in `AtomicLpEpochSettlement.t.sol` and `HousePool.t.sol` should assert equal
  request ids, not merely an ordering relation.

The governed-capacity handler must derive its expected id from the canonical request-window view rather than adding a
constant. Ensure stateful action generation reaches both sides of the cutoff and records reachability counters.

Re-run existing allocation, dust/refund, pause/frozen-entry, terminal-wipe, Senior-priority/capacity, FIFO/backlog,
atomic rollback, ERC-7540 operator/interface, and value-conservation coverage unchanged.

### Gas and bytecode

Extend request gas coverage in `packages/perps/test/perps/GasProfile.t.sol` to benchmark both sides of the cutoff.

At the current baseline:

- `HousePool` runtime is approximately 24,352 bytes, leaving 224 bytes;
- `TrancheVault` runtime is approximately 19,683 bytes, leaving 4,893 bytes;
- `PerpsPublicLens` runtime is approximately 10,739 bytes.

Require no runtime growth in `CfdEngine`, `HousePool`, or `OrderRouter`. Keep the timing implementation in the vault and
lens, and report final vault/lens sizes and request gas deltas in the PR description.

## Documentation updates

Update:

- `packages/perps/README.md` with the exact cutoff and roll-forward behavior;
- `packages/perps/WHITEPAPER.md` to replace the fixed deposit `+2` / redemption `+1` statement;
- `packages/perps/ACCOUNTING_SPEC.md` to distinguish request admission cutoff from settlement maturity and oracle
  boundary;
- `packages/perps/DEPLOYMENT.md` with frontend and keeper timing expectations;
- `packages/perps/PRE_AUDIT_GUIDE.md` with the new request-id derivation;
- `packages/perps/SECURITY.md` with the monitoring qualification that additions freeze but state and cancellations do
  not;
- `packages/perps/CANONICAL_ENTRYPOINTS.md` with the canonical timing view.
- `packages/perps/INTERNAL_ARCHITECTURE_MAP.md` with `TrancheVault` as the owner of request-epoch selection;
- `packages/perps/test/perps/invariant/README.md` with the stateful cutoff-routing properties.

Remove language claiming that every deposit always waits two epochs or that every request waits at least one complete
epoch. A request placed one second before the cutoff waits five minutes and one second.

## Explicit non-goals

- No performance fee.
- No settlement batch/config digest.
- No explicit target epoch, settlement deadline, or output bounds in keeper calldata.
- No guardian, new pauser role, or automated circuit breaker.
- No trading freeze during the cutoff window.
- No runtime-configurable cutoff or timelock proposal path.
- No change to oracle confidence, freshness, divergence, or post-boundary publication rules.
- No change to withdrawal budgets, phase priority, backlog bounds, NAV mathematics, or Terminal NAV synchronization.
- No migration or compatibility selectors for an older deployment.
- No testnet broadcast.

## Validation commands

Run, at minimum:

```bash
forge fmt --check packages/perps script
forge test --root packages/perps --match-contract LpRequestCutoffTest
forge test --root packages/perps --match-contract AsyncLpEpochSettlementTest
forge test --root packages/perps --match-contract PerpsPublicLensTest
forge test --root packages/perps --match-contract AtomicLpEpochSettlementTest
forge test --root packages/perps --match-contract TerminalNavIntegrationSecurityTest
forge test --root packages/perps --match-contract GovernedSeniorCapacityInvariantTest
forge test --root packages/perps --match-contract PerpHousePoolLifecycleInvariantTest
forge test --root packages/perps
make test-integration
make coverage-perps
bash scripts/check-package-boundaries.sh
forge build --root packages/perps --sizes
! rg -n "DEPOSIT_EPOCH_DURATION|DEPOSIT_ACTIVATION_EPOCH_DELAY|REDEEM_ACTIVATION_EPOCH_DELAY|deposit \\+2|redeem \\+1" \
    packages/perps script --glob '!LP_FIVE_MINUTE_CUTOFF_HANDOFF.md'
```

## Definition of done

- [ ] Both request directions and both tranches use one canonical timing helper.
- [ ] Before-cutoff requests target `currentEpoch + 1`.
- [ ] From the exact cutoff until the round-hour boundary, requests target the pre-boundary `currentEpoch + 2` and
      do not revert.
- [ ] At the exact round-hour boundary, the numeric target remains continuous and equals the new
      `currentEpoch + 1`.
- [ ] The lens exposes the target epoch and its next cutoff time without an ambiguous cutoff-state flag.
- [ ] No request at or after `b - C` can increase the locked `e + 1` epoch.
- [ ] Existing cancellation, escrow, reservation, cooldown, FIFO, and refund rules are preserved.
- [ ] Settlement maturity and atomic oracle boundary semantics are unchanged.
- [ ] The updated custom vault interface id and all unchanged standard interface ids are advertised correctly.
- [ ] Boundary, fuzz, stateful, cancellation, and atomic rollback regressions pass.
- [ ] Full perps, invariant, integration, coverage, package-boundary, gas, and size gates pass.
- [ ] Core runtime sizes do not grow.
- [ ] Documentation and integration ABIs describe the new timing exactly.
- [ ] The PR description reports timing semantics, security limitations, gas deltas, bytecode sizes, and verification.

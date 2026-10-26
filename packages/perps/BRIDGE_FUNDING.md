# Bridge funding into perps margin

`MarginClearinghouse.depositFor(account, amount)` lets a third party pay USDC into another account's free settlement
balance. The Across integration uses that method during a destination callback: approve the clearinghouse, deposit
for the trading account, clear the allowance, and emit a quote-specific marker. If the action fails, the intended
fallback sends wallet USDC to the same trading account. **A bridge fill or wallet transfer is not proof of margin
credit.**

This repository contains the contract method, client helpers, a release verifier, and local tests using pinned Across
runtimes. It does not establish a compatible live deployment or a successful end-to-end bridge transfer. Existing
immutable clearinghouses without `depositFor` need a new compatible core release. Keep funding unavailable until the
core deployment, authentic provider quote, and application release have been verified together.

## Clearinghouse accounting

`depositFor` pulls tokens from **its caller**, requires a positive amount and nonzero beneficiary, checks that the
clearinghouse received exactly the requested amount, and credits the beneficiary's free settlement. It permits
self-funding and counterfactual account addresses. It does not verify that the payer controls the beneficiary; the
application must establish the intended trading account before requesting a source signature.

The deposit does not allocate position margin, collect/checkpoint carry, change reservations or Terminal NAV, or grant
the payer authority over the beneficiary. Outstanding carry remains due under normal account actions and risk checks.
Owner `deposit` and `depositMargin` retain their carry-realization behavior.

The clearinghouse emits both `Deposit(account,asset,amount)` and `DepositFor(payer,account,amount)` for the **same**
credit. Index the credit once; the second event supplies payer attribution. On the Across route the payer is the
verified handler, not the source wallet or relayer. After credit, normal withdrawal, health, and carry rules apply.

## Destination message

The tested recipe uses the existing Across MulticallHandler and pinned Across EventEmitter. ABI-encode:

```text
((address target, bytes callData, uint256 value)[] calls, address fallbackRecipient)
```

Set `fallbackRecipient` to the verified destination trading account, which may differ from the source wallet. Use
these four ordered calls, all with zero native value:

| Step | Outer target | Action |
| --- | --- | --- |
| 1 | Handler itself | `makeCallWithBalance` wrapping `USDC.approve(clearinghouse, 0)` |
| 2 | Handler itself | `makeCallWithBalance` wrapping `clearinghouse.depositFor(beneficiary, 0)` |
| 3 | USDC | `approve(clearinghouse, 0)` to clear remaining allowance |
| 4 | Pinned EventEmitter | `emitData(bytes)` containing the unique 32-byte quote ID |

The two dynamic wrappers each use one replacement `(USDC, 36)`. Offset 36 is the amount word after the four-byte
selector and first 32-byte argument. The original amount must be zero: the pinned handler inserts its current token
balance using bitwise OR. Approval and deposit therefore use the actual balance, including any unsolicited dust,
rather than a quoted estimate or unlimited allowance.

If the inner call sequence succeeds, the clearinghouse credits the beneficiary and the marker follows its deposit
events. If an inner call fails, the entire sequence rolls back and the handler drains remaining callback-token USDC
to the beneficiary. Remaining USDC is also drained after a successful sequence. A failed fallback transfer or malformed
outer message can revert the callback; attempted execution alone does not prove wallet delivery.

The handler is shared and permissionless, with no per-intent custody or replay protection. Never send a standalone
transfer to it or plan a later flush. The fill and callback must execute together. Runtime hashes prove contract
identity, not intent authorization. See the [fixture documentation](test/fixtures/across-direct-funding/README.md)
for pinned addresses, source provenance, independent encoding, and actual local-receipt checks.

## Attribution and funding lifecycle

Persist the intent before submission. Validate the quote against that intent and a reviewed allowlist: source and
destination chains/tokens, amount bounds, expiry/slippage, transaction target, approval spender, exchange, SpokePool,
handler recipient, exact destination message, and beneficiary fallback. Provider-suggested addresses must not expand
the allowlist. A source approval must cover only the intended spend; validate the following source transaction too.

| Evidence | What it establishes |
| --- | --- |
| Validated provider quote | An offered route matching the intent's constraints |
| Source transaction hash | Submission, not successful execution |
| Confirmed source receipt/deposit | Canonical source execution and relay identity |
| Provider delivery status | Advisory progress |
| Canonical destination fill | The relay was filled; destination actions may have fallen back |
| Matching confirmed clearinghouse credit | The actual amount credited to the trading account |
| Matching confirmed fallback transfer | Wallet USDC delivered; a separate deposit is still needed |

Reconcile the canonical destination fill to the persisted source intent, then inspect the successful receipt at the
configured confirmation depth. Credit evidence must match chain, clearinghouse emitter, USDC, beneficiary, handler
payer, and amount. Require the quote marker after the deposit events inside that fill's callback interval. The emitter
is permissionless, so the marker alone is insufficient. Fallback evidence must match `CallsFailed`, the USDC transfer,
and `DrainedTokens` in the same callback interval.

Represent confirmed wallet fallback as `needs-deposit`, not trading-ready margin. A later authenticated deposit can
move it into settlement. A connected owner EOA cannot spend a smart account's tokens without that account's normal
authorization path. Refresh canonical account balances before using credited funds in a trading decision.

Resume pending intents across reloads, wallet changes, RPC failures, replacement transactions, and provider timeouts.
Do not repeat the source payment because destination polling failed. Reorgs invalidate confirmation evidence and
require reconciliation again. Keep reconciliation for the original release available after disabling new quotes.

## Client helpers

The [bridge funding client](../perps-aa-client/src/bridgeFunding.ts) exports:

- `buildDepositForCalls({usdc,clearinghouse,beneficiary,amount})`: raw approval and caller-funded deposit calls from
  the same payer. Batch atomically when supported; otherwise confirm approval before deposit. The supplied positive
  amount is fixed. This helper does not build the Across dynamic-balance message or clear allowance after failure.
- `verifyBridgeFundingDeployment({client,deployment})`: checks chain ID, runtime hashes for token, clearinghouse,
  SpokePool proxy/implementation and handler, the SpokePool EIP-1967 implementation slot, and the clearinghouse's token
  binding at one captured block. It returns the verified addresses, chain ID, and observation block.

`BridgeFundingDeployment` contains `chainId`, `usdc`, `clearinghouse`, `destinationSpokePool`,
`destinationSpokePoolImplementation`, `multicallHandler`, and each address's corresponding `*RuntimeCodeHash`.
Populate these from a validated funding release. The helper does not prove `depositFor` behavior, provider support,
the full core graph, or margin credit. USDC proxy governance and SpokePool upgrades remain external dependencies.

The builder neither sponsors gas nor proves wallet control. These calls are not additional `sendSponsoredAction`
kinds and do not extend the paymaster allowlist.

## Funding release artifact

Use repository-root `deployments/perps-bridge-funding.template.json`. The separate AA manifest has a strict schema for
account abstraction/paymaster policy and must not receive funding fields.

The funding artifact pins `version: "perps-funding-v1"`, `provider: "across"`, destination chain/release identity,
clearinghouse, token, SpokePool proxy/implementation, handler, code hashes, confirmation depth, start block, allowed
source routes and transaction targets, and evidence for a real third-party `depositFor` probe. Flat values must match
`evidence.contracts`. Missing, unknown, malformed, zero, or inconsistent required release values fail validation.
The template's null values are deliberate placeholders, not an executable release.

From the repository root, check template structure:

```bash
node scripts/perps-bridge-funding-release.mjs template deployments/perps-bridge-funding.template.json
```

For a populated release, set `FUNDING_MANIFEST` to its file path and export `FUNDING_RPC_URL` for its destination chain.
`verify` also requires `cast` on `PATH`:

```bash
node scripts/perps-bridge-funding-release.mjs validate "$FUNDING_MANIFEST"
node scripts/perps-bridge-funding-release.mjs verify "$FUNDING_MANIFEST"
```

Both commands are read-only. `validate` checks structure; `verify` checks runtime hashes and reciprocal core bindings
for the token, clearinghouse, Engine, Pool, Router, Oracle, and lifecycle Book, plus handler identity and the SpokePool
implementation. It verifies the probe's successful canonical receipt, confirmation depth, exact transfer/credit
logs, and that `startBlock` does not skip its block. A selector, simulated call, or token binding alone does not
establish deployed `depositFor` support.

This verifier complements the full perps verifier. It does not verify every admin, sidecar, vault, economic parameter,
activation state, off-chain service, or source-chain provider allowlist. Pin the reviewed artifact's distribution
location and keep historical artifacts unchanged.

## Application boundary and validation limits

The companion `plether-app` repository owns quote admission, the frontend funding state, and destination
reconciliation. Use that release's configuration and operational documentation; the core helpers do not establish
its supported source routes, API readiness, worker readiness, or AA compatibility. No receiver/factory deployment,
bridge-specific signer, or later flush is required by the direct callback design.

The checked-in [runtime fixtures](test/fixtures/across-direct-funding/README.md) test destination semantics with mock
USDC and the local clearinghouse. Their receipt verifier runs local Anvil without a fork. The recorded provider
validation did not capture an authentic quote with the required nonzero beneficiary fallback: the attempted POST was
rejected before API processing. The independent encoding vector is not a returned quote. These tests therefore do
not prove that the provider offers the required message or that a real bridge fill will credit a compatible live
clearinghouse. Release qualification must supply that missing evidence.

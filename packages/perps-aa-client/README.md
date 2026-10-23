# Plether perps account-abstraction client

## Install

The organization-owned package is `@plether-fi/perps-aa-client`. Configure
`@plether-fi:registry=https://npm.pkg.github.com` in the consuming project's
`.npmrc`, then authenticate in your user-level npm configuration:

```bash
npm login --scope=@plether-fi --auth-type=legacy --registry=https://npm.pkg.github.com
npm install --save-exact @plether-fi/perps-aa-client@0.1.0
```

The command shows the initial published version. The V5 source described below
is version 0.3.0; install its exact registry version only after release and
deployment compatibility checks.

Use your GitHub username and a classic PAT with `read:packages`. Authentication
is required even for public GitHub npm packages. Never commit tokens. Actions
consumers use `GITHUB_TOKEN` with `packages: read` after the consuming repository
has been granted package Actions access. See [release operations](RELEASING.md)
for publishing and provenance.

This package supplies vendor-neutral frontend primitives for sponsored Plether perps actions. It deliberately does not choose a wallet SDK, smart-account implementation, bundler, or paymaster provider.

The connected MetaMask, Rabby, Trust Wallet, or other EOA remains the owner and signature UI. The smart account is the canonical trader address seen by the existing perps contracts. All positions, balances, orders, and claims must therefore be queried by `account.accountAddress`, not by the owner EOA.

## Integration sequence

1. Connect the owner's ordinary wallet.
2. Resolve its deterministic smart-account address through your chosen account implementation.
3. Build a `PerpsActionPlan` with the exported action builders.
4. Pass adapters for the account, sponsor service, and bundler to `sendSponsoredAction`.
5. Supply the exact manifest-derived `paymasterProfile` (including chain, EntryPoint, gas limits, and validity ceiling)
   and a `journalSignedUserOperation` callback that durably
   stores the signed operation and returns its locally computed EntryPoint v0.8 hash.
6. Render `onStatus` values as one transaction flow: preparing, confirm in wallet, journaling, submitting, confirmed.

The orchestrator enforces the v0.8 signing order:

1. Build the operation; the account adapter may retain a dummy signature only for bundler estimation.
2. Request `pm_getPaymasterStubData` and estimate gas.
3. Apply the gas estimate.
4. Request and apply final `pm_getPaymasterData`.
5. Ask the owner wallet to sign the final UserOperation.
6. Persist the exact signed operation and locally computed hash.
7. Submit it to the bundler and reject a returned hash that differs from the journaled hash.

Never replace paymaster data after the owner signs; that changes the EntryPoint UserOperation hash and invalidates the signature.
The adapter may retain a dummy account signature in its internal operation for bundler estimation, but both ERC-7677
paymaster RPC payloads must omit `signature`; the owner supplies the real account signature only after final sponsorship.

## Adapter contract

`SmartAccountAdapter` receives inner calls. For the official EntryPoint v0.8 `SimpleAccount`, the adapter should encode them with `execute(address,uint256,bytes)` for one call or `executeBatch((address target,uint256 value,bytes data)[])` for a batch. Other account types can encode their own execution ABI without changing the perps builders.

`SponsorAdapter` mirrors ERC-7677 but returns either split fields or packed `paymasterAndData`. Its request serializer
must strip any adapter-local dummy `signature`. The parser requires this fixed Plether envelope:

```text
paymaster(20) | verificationGasLimit(16) | postOpGasLimit(16) |
validUntil(6) | validAfter(6) | maxCost(16) | policyId(32) |
accountCodeHash(32) | signature(65)
```

`paymasterData` is 157 bytes and the full envelope is 209 bytes. Stub and final
payloads must have the same fixed length so estimation runs the same validation
path. `accountCodeHash` binds the sponsorship to the validated smart-account
runtime, including an EIP-7702 delegation target or immutable account runtime.
For the initial Arbitrum Sepolia rollout, `accountCodeHash` is the pinned SimpleAccount proxy runtime hash.
`validatePletherPaymasterEnvelope` checks the manifest-pinned paymaster, policy, code hash, gas limits, and ten-minute
validity ceiling. For this explicit Arbitrum Sepolia-only UUPS exception, the paymaster binds the proxy runtime hash
and the pinned factory/implementation addresses and runtime hashes. The API must separately recheck the proxy's
ERC-1967 implementation slot, zero beacon slot, and factory-derived identity before stub issuance, final signing, and
submission. An owner can still upgrade after signing and submit elsewhere; that residual risk is accepted on Sepolia
only with short validity, low on-chain and database caps, and a small deposit. Mainnet requires an immutable or
irreversibly upgrade-locked account implementation and a separate security review.
The initial stub must supply both paymaster gas limits. A standards-compatible
final response may return only `paymaster` and `paymasterData`; the orchestrator
reuses the stub limits and rejects a final response that changes paymaster address.

`hashPletherSponsorship` and `getPletherSponsorshipTypedData` implement the contract's exact EIP-712 domain and
message. The package test pins the shared Solidity/TypeScript digest
`0xd92042495de3ae32c76391a73aeb6bfaf515af2dd3da45c9a8921b5310cde1ea`.

## First USDC deposit

`buildReceiveWithAuthorizationTypedData` creates the owner signature payload. The domain name and version are required configuration because the SDK does not guess token metadata. After the owner signs it, `buildAuthorizedDepositAction` creates one atomic smart-account batch:

```text
USDC.receiveWithAuthorization(owner, smartAccount, amount, ...)
USDC.approve(clearinghouse, amount)
clearinghouse.depositMargin(amount)
```

The smart account is both the EIP-3009 recipient and the caller of `depositMargin`, preserving the contracts' `msg.sender` ownership invariant. Enable this route only after verifying that the configured USDC implements `receiveWithAuthorization` with the expected EIP-712 domain.

## Bridge funding

The source package exports funding primitives for a separately verified release with
`MarginClearinghouse.depositFor(address,uint256)`. Existing immutable clearinghouses without that method require a
new compatible core deployment. Existing published package versions may not contain these exports.

`buildDepositForCalls` builds an exact payer approval plus free-settlement credit for a fixed beneficiary. Both calls
must execute from the same payer; use an atomic batch when the account supports it, or confirm approval before the
deposit. The beneficiary receives no authority over the payer, and the payer receives no authority over the beneficiary.

`verifyBridgeFundingDeployment` checks the destination chain, pinned USDC/clearinghouse/SpokePool/implementation/handler
code, the SpokePool's EIP-1967 implementation slot, and the clearinghouse settlement token at one block. Supply
`chainId`, `usdc`, `clearinghouse`, `destinationSpokePool`, `destinationSpokePoolImplementation`, `multicallHandler`, and
each contract's corresponding `RuntimeCodeHash` from a trusted release. The full core graph and actual `depositFor` behavior must
already have passed release verification. The shared Across handler is permissionless; it has no immutable binding
to a SpokePool or beneficiary, and these identity checks do not authorize arbitrary handler calldata.

The builder returns raw zero-native-value destination calls, not sponsored `PerpsActionPlan` objects. Across
quotes, destination message construction, source allowlists, and durable source/fill correlation remain application
responsibilities. A handler address, provider status, or token balance alone does not prove margin credit. Match the
specific source deposit and destination fill/message to the beneficiary's confirmed clearinghouse credit, and count
the `Deposit`/`DepositFor` pair once. If Across returns USDC to the intended fallback beneficiary after a destination
call fails, that wallet balance still needs a separate authorized deposit. This SDK does not create receivers or
provide receiver flush/recovery operations. See the repository's
[bridge-funding guide](../perps/BRIDGE_FUNDING.md) for release and fallback requirements.

## Trader actions and cancellation

Builders are provided for deposit, commit order, add margin, withdraw, and settle claim. `addMargin(account, amount)` and `settleTraderClaim(account)` always encode the smart-account address as the account argument.

`buildPlaceOrderAction` retains the historical scalar-router ABI. Use `buildPlaceOrderV3Action` for V3 deployments.

`buildWithdrawAction` calls `withdrawMargin`, so the clearinghouse sends USDC to
the smart account (`msg.sender`). It does not silently append a transfer to the
owner EOA. `buildWithdrawToOwnerAction` provides the explicit atomic alternative:
`withdrawMargin(amount)` followed by `USDC.transfer(owner, amount)`. Both amounts
are identical and both calls carry zero native value. The backend must prove the
recipient is the registered smart-account owner; it must reject arbitrary
recipients, token addresses, extra calls, and mismatched amounts. EIP-7702
same-address accounts should use `buildWithdrawAction` because the withdrawal is
already paid to the owner's address.

Committed delayed orders are binding in the current perps protocol; there is no trader cancellation function. `cancelOrder.supported` is therefore false, and `buildCancelOrderAction` raises `ACTION_UNSUPPORTED`. The UI should show pending/finalizing state and must not display an active Cancel button.

## Position protection

`buildProtectedOpenAction` builds an atomic bounded V3 opening order with TP/SL.
`buildCreateProtectionAction`, `buildReplaceProtectionAction`, and
`buildCancelProtectionAction` manage account-owned protection records.
`buildAmendLatchedProtectionCloseLimitsAction` lets the owner change the close
limits of a `Latched` protection before a permissionless retry. Every
builder targets the configured PositionProtectionBook with zero native value;
the exported `positionProtectionBookAbi` is generated for the current source and must match the target deployment.
Supply all four `bigint` fields in `params.closeLimits` for create, replace, and
protected open: `maxExecutionNotionalUsdc`, `maxGrossAccountDebitUsdc`,
`maxActionChargeUsdc`, and `maxExplicitFeesUsdc`. The amendment builder takes
the same `closeLimits` object. Values are uint256 ceilings in 6-decimal USDC
units. Zero is a zero allowance; use `maxUint256` only when unlimited authority
is intended. Builders reject missing or invalid close limits; they do not
insert unlimited defaults. Read the current values from the Book's
`closeFinancialLimits(uint64)` getter. The trigger bounty is reserved separately
and paid when protection fires; the limits bound each generated close attempt,
not a cumulative amount across retries.
Reject empty triggers, invalid uint64 protection IDs, and invalid or closing parent-open requests before asking for
sponsorship. Pass these plans through the same manifest validation and durable
journaling flow as other native AA actions.

`buildCancelProtectionAndCloseAction({ account, book, protectionId, request })`
encodes one nonpayable `cancelPositionProtectionAndCommitClose` call to the Book,
with action kind `cancel-protection-and-close`. Supply the complete bounded V3
close request, including a fresh nonreserved client ID, the current nonzero
configuration hash, and the live position's side and full size. The builder
preserves every request field and exposes `submitBy` as `submissionDeadline` for
sponsorship. It rejects invalid IDs, nonpositive or non-lot-aligned sizes,
nonzero margin or settlement floors, invalid timing, and execution mode masks
outside 1–7; financial ceilings remain explicit and are never widened.

The Book requires the caller to own an `Armed` protection for the current
position and requires a full close on the same side. These state checks,
client-ID freshness, and configuration freshness require an onchain read or
simulation before signing; the pure builder cannot establish them. The supplied
`account` is smart-account metadata, and that account must execute the call.
Cancellation and the trigger-bounty refund revert together if the new close
cannot be queued. After successful queueing the protection stays cancelled even
if the close later fails or expires. Exact replay of the composite action is
rejected. Use this builder only with a compatible Book deployment and sponsor
policy that supports the new action.

The package originated from the self-hosted-AA source patch (SHA-256
`d1c6941c03f37cc9a93b35b95dc73a876ee87dab624524ed9c4d6336022f2955`,
base `bc8f6290c540665e4ff61328ea83a4c3d421a8d4`) with protection source
`3472427ed15b0a478248af7d025535da349a8592`. Those references record its historical
origins; current source and release evidence define the updated order and protection ABIs.
The immutable historical compatibility baseline records the old protection
encodings and hashes. The reviewed current schema records the changed protection
vectors and amendment action alongside the current order ABI. `RELEASING.md`
describes the artifact compatibility gate.

## UI errors and fallback

Use `mapPerpsExecutionError` to turn nested wallet, bundler, paymaster, and contract failures into stable codes and user-safe messages. Do not silently fall back to an EOA transaction: it would create protocol state under a different `msg.sender` and split the user's account. If sponsorship is unavailable, show a retry/support state unless the product has explicitly implemented and disclosed user-paid smart-account gas.

`buildCloseOrderV3` uses the same request shape for full closes and partial
reductions. New close commitments have zero USDC keeper bounty; normal native
account-abstraction gas sponsorship remains available. Opening orders and
protection triggers retain their separate reward rules. `classifyCloseFailureV3`
keeps carry funding, action funding, residual health, and live-side mismatch
failures distinct. `buildExpireOrderV3` encodes permissionless cleanup after the
order's execution deadline without oracle data. Use archived bindings for older
deployments with funded close bounties.

A positive `minPostSettlementBalanceUsdc` is supported only for a first opening
order while the account has no live position and no pending order. The account
must fund that minimum plus the full declared `maxGrossAccountDebitUsdc`, after
commitment reservations; an unlimited gross ceiling cannot be used with a
positive minimum. No later same-account commitment is allowed until this order
terminates, and withdrawals must preserve its floor. Exact client-ID retries
still resolve to the original order. Orders with a zero minimum keep their
existing funding rules.

The pure builders reject positive floors on closes and positive floors with an
unlimited gross ceiling; they preserve the supplied values and perform no RPC
calls. Before signing a positive-floor open, read or simulate against the trusted
deployment to verify the account is flat, its queue is empty, and funding is
sufficient. Increases and closes must use a zero minimum. This restriction
protects the settlement minimum during its pending lifetime; other execution
bounds still depend on the state at execution.

## Terminal history on the new stack (0.3.0)

The candidate's `orderLifecycleV5Abi` replaces `outcome(orderId)` with
`terminalOutcome(orderId)`: account, terminal block, status, reason and receipt
hash. Full details come from the V5-domain `OrderFinalized` event, including the merged timing tuple. Use the
trusted deployment's chain, Book and Router addresses; do not take those or the
summary from an untrusted indexer.

```ts
import { decodeVerifiedOrderFinalized, orderLifecycleV5Abi } from "@plether-fi/perps-aa-client";

const summary = await publicClient.readContract({
  address: book, abi: orderLifecycleV5Abi, functionName: "terminalOutcome", args: [orderId],
});
// None/Pending has no terminal history. Wait for finality before caching.
if (summary.status === 2 || summary.status === 3) {
  // Fetch by chain + Book + order ID from your receipt index, or select the
  // event from the known execution transaction receipt. The helper checks it.
  const matchingFinalizedLog = await history.getFinalizedLog({ chainId, book, orderId });
  const verified = decodeVerifiedOrderFinalized({
    chainId: BigInt(chainId), book, router, summary, log: matchingFinalizedLog,
  });
  displayReceipt(verified.receipt);
}
```

`history.getFinalizedLog` represents the application's event retrieval layer; it is not an SDK method. `matchingFinalizedLog` includes its emitter address, data, and nonempty topics.
The helper authenticates the event, clocks and full receipt against the summary;
`hashOrderReceiptV5` exposes the same digest separately. Solidity consumers can
call `verifyReceipt(receipt, terminalTime)` on the Book. The receipt and execution
configuration domains are V5; the request intent domain remains V3. Requests use
one close flow, and the receipt includes authenticated timing. Earlier candidate
event and request encodings must not be reused on the final graph.

Cache history by chain/Book/order ID and invalidate it on reorg. If a log cannot
be retrieved, report history as unavailable instead of assuming zero fees or
bounty. Verification proves authenticity, not availability. Detailed on-chain
reads now require a supplied full receipt. The archived `orderLifecycleV4Abi`
export and old-stack action/assistance bindings remain available; choose ABI by
deployment, and migrate external app/keeper reads before new-stack activation.
Commitment history remains stored and does not require an event join.

The current receipt tuple omits pledged-bounty and retained-bounty fields. Its
`bountyDisposition` values are `None=0`, `Paid=1`, `Forfeited=2`, and
`RefundedToAccount=3`. Read the paid, refunded, and forfeited amounts from the
authenticated receipt; do not decode a current receipt with a historical ABI.

Internal interfaces, public tuples, and Clearinghouse/Book storage change. Deploy the compatible
connected stack together; this does not permit a Router hot swap
or importing populated state with empty escrow mirrors. No publication, deployment,
activation or live-state migration is performed by these SDK changes.

On Arbitrum, the authenticated `terminalBlock` retains Solidity `block.number`
semantics (an approximate ancestor-chain block); it is **not** the RPC/L2 log
block number. Never use it directly as an `eth_getLogs` block range. Use the
execution transaction receipt, an index keyed by chain/Book/order ID, or paginated
RPC log queries over the known L2 deployment-to-head range. Keep transport
`blockNumber`/`blockHash` separately for indexing and reorg handling; hash the
event's authenticated `terminalBlock` as emitted. See [Arbitrum block-number
documentation](https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/block-numbers-and-time).

## Historical V3 order timing (0.2.0 source release)

`buildPlaceOrderV3Action` and `buildProtectedOpenAction` encode `submitBy` and
`executionWindowSeconds`. A fresh web review uses 120 seconds for submission
and 60 seconds for execution after commitment. Both builders expose
`submissionDeadline`; `sendSponsoredAction` rejects stub or final sponsorship
that extends beyond it before requesting the owner signature. The contract
resolves the execution deadline at commitment, so execution requires no new
client signature. V2 signed calldata cannot be reinterpreted as V3.

This is a breaking order ABI release. No package publication or deployment is
included. See `packages/perps/ORDER_V3_TIMING.md` in the repository for activation
requirements and the canonical lifecycle timing tuple.

## Zero-close execution helpers

New stacks require zero execution bounties for ordinary and protection closes. Opens/increases and the protection trigger still have positive configured rewards; carry and trading charges remain. Use `buildOwnerAccountClose` only after verifying the existing smart account's owner/factory/implementation and chain. It wraps the close in owner-authorized account execution and never changes the canonical trader to the owner EOA.

`classifyKeeperHead`, `buildExecuteOrderV3`, `buildExecuteOrderBatchV3`, `buildRiskOffCleanupV3`, `buildTriggerProtection`, `buildRetryProtection` and `quoteExecutionNativeValue` support permissionless execution. Authenticate terminal evidence with the existing V5 receipt helpers. A Pending result or partial batch is not completion. Native gas and oracle fees are still payable, even when the USDC bounty is zero.

See [zero-close operations](../perps/ZERO_CLOSE_OPERATIONS.md) for funding, strict expiry, FIFO blockers, protection retries and deployment limitations. The source-tree `scripts/close-operator.mjs` is an explicit one-shot operator tool, not a production daemon or an automatic retry service. Historical ABIs and receipt layouts remain available; do not apply zero-bounty assumptions to old deployments.

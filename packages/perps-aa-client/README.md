# Plether perps account-abstraction client

## Install

The organization-owned package is `@plether-fi/perps-aa-client`. Configure
`@plether-fi:registry=https://npm.pkg.github.com` in the consuming project's
`.npmrc`, then authenticate in your user-level npm configuration:

```bash
npm login --scope=@plether-fi --auth-type=legacy --registry=https://npm.pkg.github.com
npm install --save-exact @plether-fi/perps-aa-client@0.1.0
```

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

## Trader actions and cancellation

Builders are provided for deposit, commit order, add margin, withdraw, and settle claim. `addMargin(account, amount)` and `settleTraderClaim(account)` always encode the smart-account address as the account argument.

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

`buildProtectedOpenAction` builds an atomic bounded V2 opening order with TP/SL.
`buildCreateProtectionAction`, `buildReplaceProtectionAction`, and
`buildCancelProtectionAction` manage account-owned protection records. Every
builder targets the configured PositionProtectionBook with zero native value;
the exported `positionProtectionBookAbi` is the complete reviewed v1.2.1 ABI.
Reject empty triggers, invalid uint64 protection IDs, and unbounded/closing
requests before asking for sponsorship. Pass these plans through the same
manifest validation and durable journaling flow as other native AA actions.

The package combines the self-hosted-AA source patch (SHA-256
`d1c6941c03f37cc9a93b35b95dc73a876ee87dab624524ed9c4d6336022f2955`,
base `bc8f6290c540665e4ff61328ea83a4c3d421a8d4`) with protection source
`3472427ed15b0a478248af7d025535da349a8592`. Core source and immutable package
releases are authoritative for future changes. Tests freeze the app's previous
encodings and hashes; `RELEASING.md` describes the artifact compatibility gate.

## UI errors and fallback

Use `mapPerpsExecutionError` to turn nested wallet, bundler, paymaster, and contract failures into stable codes and user-safe messages. Do not silently fall back to an EOA transaction: it would create protocol state under a different `msg.sender` and split the user's account. If sponsorship is unavailable, show a retry/support state unless the product has explicitly implemented and disclosed user-paid smart-account gas.

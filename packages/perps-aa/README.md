# Plether Perps Account Abstraction

This package adds ERC-4337 v0.8 gas sponsorship without changing the deployed perps contracts. A trader's smart
account remains `msg.sender`, so the existing clearinghouse, engine, and delayed-order ownership checks continue to
work as written.

`PletherVerifyingPaymaster` is intentionally narrow. It verifies a short-lived EIP-712 approval, enforces signed and
owner-controlled cost ceilings, pins the reviewed SimpleAccount factory/implementation/runtime profile, permits only
nonce key zero and the account's `execute` methods, and pays EntryPoint from its deposit. Semantic target allowlists,
budgets, rate limits, proxy-slot checks, and simulation remain in the Haskell sponsorship gateway.

## ERC-4337 version and encoding

The contract targets EntryPoint v0.8. The canonical v0.8 address is
`0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`.

`paymasterAndData` is exactly 209 bytes:

```text
paymaster                 20 bytes
verificationGasLimit      16 bytes (uint128, big endian)
postOpGasLimit            16 bytes (uint128, big endian)
validUntil                 6 bytes (uint48, non-zero)
validAfter                 6 bytes (uint48)
maxCost                   16 bytes (uint128)
policyId                  32 bytes
accountCodeHash           32 bytes
signature                 65 bytes (r || s || v)
```

The sponsorship digest commits to every packed UserOperation field except the account signature and the sponsor
signature itself. It also commits to the policy fields, account runtime code hash, EntryPoint, chain id, and paymaster
address. The public `getSponsorshipHash` function is the canonical test oracle for backend signing implementations
and can be called before a counterfactual account exists. EntryPoint deploys a counterfactual sender before paymaster
validation, so validation then observes and requires the pinned proxy runtime hash.

This deployment is an explicit **Arbitrum Sepolia-only UUPS exception**. The paymaster verifies the fixed proxy runtime,
factory runtime, factory-reported implementation, and implementation runtime. It cannot read another proxy's ERC-1967
implementation slot, so the gateway must recheck that slot before signing and again before submission. This profile is
not approved for mainnet; mainnet requires an immutable or irreversibly locked account implementation.

Validation requires zero post-op gas because the contract returns an empty context and performs no post-op accounting.
Validity windows may be at most 600 seconds. The contract starts paused and authorizes exactly one signer. Rotation
stops issuance, pauses validation, waits for every old-signer authorization to settle or expire behind the safe
reconciler cursor, calls `setSponsorSigner(newSigner)` through the Safe, attests the replacement, and then unpauses.

EntryPoint v0.8 includes the entire final `paymasterAndData` in the account's UserOperation hash. The required client
ordering is therefore:

1. Install fixed-length stub paymaster data and estimate gas.
2. Request and install final signed paymaster data.
3. Ask the connected wallet owner to sign the final UserOperation.
4. Durably journal the exact signed UserOperation and its locally computed hash.
5. Submit the signed UserOperation to the bundler and verify its returned hash.

Never replace the paymaster data after the account signature has been produced.

## Build and test

```bash
forge build --root packages/perps-aa
forge test --root packages/perps-aa
```

## Deployment

Required variables:

```bash
export DEPLOYER_PRIVATE_KEY=...
export PAYMASTER_OWNER=0x...             # multisig/timelock in production
export SPONSOR_SIGNER=0x...              # KMS/HSM-backed service signer
export MAX_SPONSORED_COST_WEI=...
export SIMPLE_ACCOUNT_PROXY_RUNTIME_CODE_HASH=0x...
```

Optional variables are `INITIAL_PAYMASTER_DEPOSIT_WEI`, `INITIAL_PAYMASTER_STAKE_WEI`, and
`PAYMASTER_UNSTAKE_DELAY_SEC`. The script rejects every chain except Arbitrum Sepolia and pins EntryPoint v0.8,
factory `0x13E9...5944`, implementation `0x2842...9ec3`, and policy
`0x8dd77324...4f5ae3`. It also rejects any drift from the reviewed EntryPoint, factory, implementation, or
SimpleAccount proxy runtime code hashes recorded in the deployment template. The explicit proxy-hash environment
value must equal that reviewed profile; it is not an arbitrary deployment parameter.

`addStake` is owner-only. If `PAYMASTER_OWNER` differs from the deployer (the normal production setup), keep
`INITIAL_PAYMASTER_STAKE_WEI=0` and add stake in a separate multisig transaction after deployment.

```bash
forge script packages/perps-aa/script/DeployPletherVerifyingPaymaster.s.sol:DeployPletherVerifyingPaymaster \
  --root packages/perps-aa \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Before funding, independently derive the proxy runtime hash with `cast code` plus `cast keccak`, compare all values
against the deployment artifact, verify the pending/accepted Safe owner and sole KMS signer, fund only the canary
amount, and deliberately call `unpause()`. Staking and depositing are separate operations. Fill
`deployments/arbitrum-sepolia-perps-aa.template.json` with the source commit, bytecode hashes, transactions, signer
address, ownership, deposit, stake, and readback evidence.

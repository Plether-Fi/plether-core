# Perps Gas Sponsorship Security Model

The paymaster controls a pool of native token. A successful exploit can drain that pool even when it cannot steal
protocol or trader settlement tokens. Treat the policy service, sponsor signer, account implementation, bundler, and EntryPoint as a
separate production security boundary.

## Enforced on-chain

- Only the configured ERC-4337 v0.8 EntryPoint can validate or invoke `postOp`.
- The EntryPoint must advertise the official v0.8 interface through ERC-165 at deployment.
- The final 209-byte envelope must be canonical and must identify this paymaster.
- EIP-712 signatures bind chain, paymaster, EntryPoint, sender, nonce, init code, call data, gas fields, validity,
  operation cost ceiling, policy id, and account runtime code hash.
- The policy id and account code hash must match immutable deployment configuration.
- The sender, factory, and implementation runtime code hashes must still match their deployment-time values.
- The factory must still report the pinned implementation; non-empty init code must use the pinned factory.
- Only nonce key zero and the reviewed SimpleAccount `execute`/`executeBatch` entry points are accepted.
- Sponsorship validity is bounded to ten minutes.
- Post-op gas must be zero because successful validation returns an empty context.
- Both the signed cost ceiling and the owner-controlled global cost ceiling bound one operation's maximum exposure.
- The owner can pause validation, replace the sole signer while paused, reduce the cost ceiling, and withdraw
  deposit/stake. The contract starts paused.

The current SimpleAccount is a UUPS proxy. Its proxy code hash does not change when its ERC-1967 implementation slot
changes, and Solidity cannot read another contract's storage slot. The contract's factory/implementation checks
therefore do not prove that an individual proxy remains on that implementation. The gateway must validate the exact
proxy slot and zero beacon slot before signing and submission. This is a bounded Sepolia exception, never a mainnet
security claim.

## Required off-chain controls

- Accept only Arbitrum Sepolia, the configured EntryPoint/paymaster, the pinned SimpleAccount proxy runtime, factory,
  implementation, owner-derived index-zero address, and trusted counterfactual init code.
- Decode the smart-account outer call and every nested call. Reject malformed encodings, trailing data, unknown
  selectors, nonzero native value, self-calls, `delegatecall` semantics, upgrades, modules, arbitrary token calls, and
  keeper/admin methods.
- Permit only exact trader patterns documented by the sponsor service. Approval and token-transfer calls must be
  inseparable from their matching deposit/withdraw operation.
- Run deterministic validation and EntryPoint/bundler simulation before signing.
- Atomically apply account/IP rate limits, per-operation caps, rolling account/global budgets, and idempotency checks
  in PostgreSQL. The fixed-length stub uses an invalid signature, so it must not reserve funds; final signed data does.
- Keep signature validity short. Do not log private keys, raw KMS material, wallet signatures, or authorization secrets.
- Back the signer with KMS/HSM infrastructure in production. Separate signer permissions from paymaster owner
  permissions and use a multisig/timelock owner.
- Reconcile reservations against UserOperation receipts and expire unused reservations conservatively.

The in-memory budget/rate/replay stores supplied by the service are development implementations. Production must use an
atomic shared store such as Redis or a transactional database so multiple service replicas cannot race limits.

## Operational monitors

Alert on EntryPoint deposit/stake thresholds, spend velocity, denials by reason, signature volume, stub-to-final ratio,
simulation failures, bundler errors, account-code mismatches, signer rotation, owner changes, pause state, and changes to
configured contract/code hashes. Maintain a tested response runbook: pause, rotate signer, revoke service credentials,
reduce the cost ceiling, and disable the frontend sponsorship flag.

## Production gates

Before mainnet funding, complete an external review of the paymaster and service, test against the real EntryPoint v0.8
and selected bundler/account implementation, validate EIP-7702 behavior on the target chain, load-test budget atomics,
and rehearse pause/signer rotation/deposit withdrawal. Keep the legacy direct-wallet path available during rollout.

## Kernel v4 pilot profile

`PletherKernelVerifyingPaymaster` binds EntryPoint v0.9, a staked ZeroDev Staker, the underlying KernelFactory,
expected Kernel UUPS implementation, validator and proxy runtime. It accepts one canonical index-zero ECDSA root
initializer through `Staker.deployWithFactory(KernelFactory, KernelFactory.deploy(...))`. The Staker must approve that
factory and maintain at least 1 ETH stake with a one-day unstake delay. The gateway must attest the current approval,
runtime and stake before issuing a sponsored first deployment; revoking the approval or unlocking stake disables
new first deployments. The paymaster must also be staked for SafeMode validation of its own storage reads.
It limits sponsored operations to nonce key zero and atomic ERC-7579 single or batch execution. It rejects the
v0.9 optional paymaster-signature suffix and block-based validity windows. The signature binds the exact operation.

Kernel UUPS accounts can change their implementation and root. The paymaster checks the proxy runtime and the
configured implementation and validator code hashes. The gateway must independently attest the sender's live
implementation and beacon slots, root and validator owner at agreed canonical state before issuance and submission.
The constructor restricts this UUPS pilot to Arbitrum Sepolia. Use controlled accounts, a small dedicated deposit
and short-lived authorizations. A production profile requires immutable execution or an irreversible upgrade lock
and qualification under the production bundler validation rules.

ETH-paid operations run without a paymaster, signer approval, or sponsor reservation. Continue checking account
identity, approved actions, nonce and canonical receipt evidence throughout this path.

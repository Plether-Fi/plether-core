# Bridge funding into perps margin

Bridge funding delivers the destination deployment's canonical USDC to a deterministic receiver and then credits a
fixed beneficiary's clearinghouse account. The bridge/provider handles the source transaction and cross-chain
delivery. Perps contracts handle only destination-chain custody and credit. A bridge completion notification is not
proof that margin was credited.

This feature requires `MarginClearinghouse.depositFor(address,uint256)`. Existing deployments without that method
cannot gain it by deploying a receiver. Clearinghouse/Engine/Router bindings are immutable or set once, so those
deployments require a new compatible core release. Do not point a new funding manifest at an old clearinghouse or
replace an address inside an existing deployment record to imply an upgrade. No deployed bridge-funding release is
asserted by the checked-in template.

## Contract flow

1. Pin the destination chain, settlement token, clearinghouse, factory, verified code hashes, and confirmation policy
   from the reviewed funding release. The beneficiary is the user's canonical perps trading account, which may differ
   from the connected source wallet.
2. Persist a unique `bytes32 intentSalt` with the funding intent and beneficiary. Query
   `BridgeDepositReceiverFactory.predictReceiver(beneficiary,intentSalt)` against the verified factory.
3. Anyone may call `createReceiver(beneficiary,intentSalt)`. The call is idempotent. A second caller cannot change the
   beneficiary or acquire recovery rights. Tokens may arrive before deployment, but provider support for an arbitrary
   or counterfactual recipient must be established separately.
4. Have the approved provider route deliver **the exact configured destination USDC token** to the receiver. Persist
   the source chain, source transaction, provider tracking identity, destination chain, expected receiver, and quote
   bounds. A token symbol or a source USDC address is not sufficient to identify the destination asset.
5. Once canonical USDC is present, anyone may call `receiver.flush()`. It approves the clearinghouse for exactly the
   current balance, calls `depositFor(beneficiary,balance)`, clears the allowance, and emits `Deposited`. An empty
   receiver is a harmless no-op. A revert rolls back the whole flush, including its approval.
6. Confirm the destination receipt and the clearinghouse's credit event at the configured confirmation depth before
   presenting the amount as credited. Refresh the account's canonical balances because other account activity can
   occur concurrently.

The receiver's address binds the factory, beneficiary, intent salt, fixed clearinghouse/token, and receiver creation
code. Its CREATE2 salt is `keccak256(abi.encode(beneficiary,intentSalt))`; the creation input includes constructor
arguments `(beneficiary,clearinghouse,usdc)`. A zero intent salt is valid but reuses the same receiver for that
beneficiary. Use a new persisted salt when independent funding intents need independent accounting.

`depositFor` pulls tokens from **its caller**, requires an exact received amount, and credits the chosen account's
free settlement. It does not allocate position margin, collect/checkpoint carry, change reservations or terminal NAV,
or grant the payer any account authority. Outstanding carry remains due under ordinary account actions and risk
checks. Existing `depositMargin` semantics, including its carry hook, are unchanged.

The clearinghouse emits the existing `Deposit(account,asset,amount)` once and an additional
`DepositFor(payer,account,amount)` event describing the same credit. Index the credit once; `DepositFor` supplies
payer attribution and is not a second deposit. A flush's payer is the receiver, not the bridge relayer or source
wallet. Match contract addresses, beneficiary, payer, amount, successful receipt, and chain before attributing credit.

## Recovery and retries

`flush()` is permissionless and may be retried after a failed attempt or a later arrival. Each successful call deposits
the balance present at that moment. Partial deliveries can therefore produce several distinct credits for one intent.
Deduplicate by destination transaction and log identity, account for reorgs, and retain an intent until its expected
delivery/credit policy is satisfied. A provider's expected output is an estimate, not the amount to credit locally.

Only the immutable beneficiary may call `recover()`, which returns unflushed canonical USDC to that beneficiary, or
`recoverToken(token)`, which returns an accidentally received noncanonical ERC-20 to the same beneficiary. Neither
method accepts a recipient override. Recovery from a smart-account beneficiary must execute through that account's
authenticated call path; a connected owner EOA is not automatically the beneficiary. An undeployed beneficiary must
be deployed before it can make such a call.

A permissionless flush can execute before a pending recovery transaction. Recovery can return only the balance still
held by the receiver; after credit, normal clearinghouse withdrawal/health/carry rules apply. The receiver has no
native-token recovery, arbitrary-call, destination setter, owner-admin, or bridge callback. Send only the configured
ERC-20 destination asset through the funding route.

## Provider and lifecycle boundaries

The runtime manifest currently selects `provider: "across"`. Provider integration is separate from the contract API;
these contracts and client helpers contain no Privy account or funding-session assumption. An external-wallet quote
proves only the quoted route and calldata at that time. It does not prove that a different token, source chain,
destination account, deployed release, or later quote is supported, nor that a transaction will execute successfully.

Verify every quote against the persisted intent and reviewed source allowlists before requesting signatures. Check
source/destination chain and token, receiver, amounts, slippage/expiry, transaction targets, approval spenders, swap
exchanges, and bridge spoke pools. A provider-suggested address must never extend an allowlist automatically. When
allowance is required, authorize only the intended source spend and independently validate the subsequent call.

Keep lifecycle evidence separate:

| Evidence | What it establishes |
|---|---|
| Approved quote | A currently offered route matching the intended constraints |
| Submitted source transaction | A transaction hash, not final source execution |
| Confirmed source receipt | Source execution according to the source confirmation policy |
| Provider delivery status | Provider-reported progress, requiring destination reconciliation |
| Canonical USDC at receiver | Funds available for a flush; still outside clearinghouse margin |
| Submitted flush | A pending destination action, not a credit |
| Confirmed clearinghouse credit | The actual amount credited to the beneficiary |
| Recovery receipt | Unflushed tokens returned to the beneficiary, not a margin deposit |

Persist intent identity before submission and resume from it after reload, wallet changes, RPC failures, replacement
transactions, and provider timeouts. Retry destination deployment/flush independently from source submission; do not
re-send the source payment simply because a status poll failed. Gas funding or sponsorship for destination deployment,
flush, and recovery must be configured separately.

## Client helpers

`@plether-fi/perps-aa-client` exports the minimal funding ABIs and these helpers:

- `buildDepositForCalls({usdc,clearinghouse,beneficiary,amount})`: approval plus caller-funded deposit, both from the
  same payer. Execute atomically when the caller's account supports batching; otherwise wait for approval before the
  deposit. The beneficiary remains fixed in the deposit calldata.
- `buildCreateBridgeDepositReceiverCall({factory,beneficiary,intentSalt})`: deterministic receiver deployment.
- `buildFlushBridgeDepositReceiverCall(receiver)`: permissionless deposit of the receiver's canonical USDC balance.
- `buildRecoverBridgeDepositReceiverCall(receiver)` and
  `buildRecoverBridgeDepositReceiverTokenCall({receiver,token,usdc})`: beneficiary-only recovery calls.
- `resolveBridgeDepositReceiver({client,deployment,beneficiary,intentSalt})`: verifies RPC chain, code hashes, factory
  bindings, clearinghouse token, and any deployed receiver's immutable bindings at one block, then returns the
  receiver, deployment status, and observation block.

These builders return raw zero-native-value destination calls. They do not create a provider quote, authorize a
bridge route, sponsor gas, prove wallet control, or extend the existing paymaster action allowlist. The client
resolver's `BridgeFundingDeployment` uses `chainId`, `usdc`, `clearinghouse`, `factory`, and the three corresponding
runtime code hashes. Map these from the runtime manifest and its reviewed `evidence.contracts` entries. Its check is
a client recheck of a previously validated release, not a substitute for full deployment verification or receipt
confirmation. A proxy runtime hash alone does not establish its implementation; settlement-token governance remains
part of the token trust model.

Existing client action encodings and sponsorship hashes are preserved. The compatibility fixture adds only the new
exports; the new helpers are not passed through `sendSponsoredAction` as an invented action kind.

## Release artifact and validation

`script/DeployBridgeDepositReceiverFactory.s.sol` deploys only the factory against an already deployed compatible
core. Supply `FUNDING_CHAIN_ID`, `DEPLOYER_PRIVATE_KEY`, and each address below with its independently reviewed runtime
hash in the corresponding `_CODE_HASH` variable:

```text
FUNDING_USDC                 FUNDING_USDC_CODE_HASH
FUNDING_CLEARINGHOUSE        FUNDING_CLEARINGHOUSE_CODE_HASH
FUNDING_ENGINE               FUNDING_ENGINE_CODE_HASH
FUNDING_HOUSE_POOL           FUNDING_HOUSE_POOL_CODE_HASH
FUNDING_ROUTER               FUNDING_ROUTER_CODE_HASH
FUNDING_ORACLE               FUNDING_ORACLE_CODE_HASH
FUNDING_LIFECYCLE_BOOK        FUNDING_LIFECYCLE_BOOK_CODE_HASH
```

The script checks chain, code, token decimals, and the existing reciprocal graph before deployment. It then checks
the resulting factory runtime against the compiled artifact with the same immutable constructor values. Simulate
without broadcasting first:

```bash
forge script script/DeployBridgeDepositReceiverFactory.s.sol:DeployBridgeDepositReceiverFactory \
  --rpc-url "$FUNDING_RPC_URL"
```

Only a separately authorized release broadcast should add `--broadcast`. A successful factory simulation does not
prove the core implements `depositFor`; activating the release additionally requires the recorded real deposit probe
described below. This implementation work does not deploy a factory or perform that probe.

Use the separate repository-root template `deployments/perps-bridge-funding.template.json`. Do not add funding fields
to `arbitrum-sepolia-perps-aa.template.json`, whose strict schema describes account abstraction and paymaster policy.
The funding runtime profile is:

- `version: "perps-funding-v1"`, `provider: "across"`, `destinationChainId`, and `releaseId`;
- `clearinghouse`, `clearinghouseCodeHash`, `token`, `receiverFactory`, `factoryCodeHash`, `confirmations`, and
  `startBlock`;
- `sources`, each with `chainId`, `name`, `token`, `symbol`, `decimals`, `transactionTargets`, `approvalSpenders`,
  `swapExchanges`, and `spokePools`;
- `evidence`, containing source provenance, pinned destination contract addresses/runtime hashes, factory deployment
  evidence, and a successful third-party `depositFor` probe.

Both flat runtime code hashes must match their corresponding `evidence.contracts` values. In particular,
`clearinghouseCodeHash` must equal `evidence.contracts.marginClearinghouse.runtimeCodeHash`; a valid new factory does
not establish that its clearinghouse supports `depositFor`. Missing, zero, malformed, or inconsistent hashes fail
release validation.

The template deliberately contains null deployment values. It is not a usable runtime profile. Populate a new release
artifact from actual reviewed deployment results, and pin its trusted distribution location. The frontend configuration
uses `VITE_PERPS_FUNDING_MANIFEST_URL`; a missing or unverified compatible release must keep this route unavailable.

From the repository root, check the unpopulated template without treating it as a release:

```bash
node scripts/perps-bridge-funding-release.mjs template deployments/perps-bridge-funding.template.json
```

After recording a real release at a new path, run its strict validation and read-only RPC verification. Set
`FUNDING_MANIFEST` to that saved release path and `FUNDING_RPC_URL` to its destination chain; `verify` also requires
`cast` on `PATH`:

```bash
node scripts/perps-bridge-funding-release.mjs validate "$FUNDING_MANIFEST"
node scripts/perps-bridge-funding-release.mjs verify "$FUNDING_MANIFEST"
```

Neither command broadcasts a transaction. The destination graph covers the token, clearinghouse, Engine, HousePool,
Router, oracle, lifecycle Book, and receiver factory, including reciprocal bindings and code hashes. The successful
third-party deposit probe must demonstrate the new method with a real receipt and matching transfer/credit events;
an ABI declaration or four-byte selector match alone is insufficient. The factory deployment must also match the
recorded receipt and constructor bindings.

This funding verifier complements the full perps release verifier. It does not replace verification of the remaining
admins, sidecars, terminal Book, vaults, economic parameters, activation state, or operational services. Source-chain
provider allowlists require their own review; destination RPC checks cannot verify them. Keep historical release
artifacts unchanged, retain the reviewed source commit and transaction evidence, and enable routing only after the
new core release and funding graph have both passed their release checks.

## Backend activation and worker operation

The application backend in the separate `plether-app` repository owns quote admission and destination reconciliation.
Its worker entrypoint is `apps/backend/app/FundingWorker.hs`; the implementation lives under
`apps/backend/src/Plether/Perps/Funding/`. Configure the API and worker from the same verified funding release served
to the frontend. `PERPS_FUNDING_DEPLOYMENT_JSON` contains the complete JSON text, not a filename. It must include the
flat `clearinghouseCodeHash` and `factoryCodeHash`; the release identifier is at most 128 characters and
`confirmations` is between 1 and 1,000.

Both processes need the normal backend database and destination RPC configuration: `DATABASE_URL`, `PERPS_RPC_URL`
(or the backend's `RPC_URL` fallback), and `PERPS_RPC_AUTH_TOKEN` when that RPC requires it. The API additionally
requires actual `ACROSS_API_KEY` and `ACROSS_INTEGRATOR_ID` credentials, plus `PERPS_FUNDING_SOURCE_RPC_URL` pointing
to an HTTPS Ethereum mainnet RPC. Supply `PERPS_FUNDING_SOURCE_RPC_AUTH_TOKEN` when that source RPC requires it.
A missing or non-HTTPS source endpoint makes funding unavailable; new quotes also fail if that endpoint cannot
confirm chain ID 1. An explicitly enabled API still rejects new funding quotes until its release, provider, database,
source RPC, and destination worker are ready.

Keep `PERPS_FUNDING_ENABLED` unset or `false` while verifying the deployment. With the verified deployment JSON and
database/RPC configuration already supplied, a worker observation pass is:

```bash
PERPS_FUNDING_WORKER_EXECUTE=false plether-funding-worker --once
```

This can persist reconciliation results but does not sign or broadcast transactions, and does not establish executor
readiness for new funding quotes. To activate destination execution, the operator must configure a KMS key
and its matching signer address, fund that address with destination native gas, and set:

```text
PERPS_FUNDING_WORKER_EXECUTE=true
PERPS_FUNDING_KMS_KEY_ID
PERPS_FUNDING_SIGNER_ADDRESS
PERPS_FUNDING_MAX_TX_COST_WEI
```

The first setting must be the literal `true`; the remaining values come from the authorized deployment configuration.
The worker validates signer control and checks its gas balance. `PERPS_FUNDING_MAX_TX_COST_WEI` limits each destination
transaction's maximum gas cost; it defaults to `1000000000000000` wei (0.001 ETH), and an explicit value must be
positive and no more than `100000000000000000` wei (0.1 ETH). Supply the backend's existing KMS credentials and
permissions; this release tooling does not create keys, credentials, or a funded signer.

Run `plether-funding-worker --loop` for continuous reconciliation, or `--once` for one pass. After the executing worker
has verified the configured release and recorded readiness, set `PERPS_FUNDING_ENABLED=true` for the API and verify
`GET /api/perps/funding/config` reports availability. This API response is a readiness signal, not a substitute for
release verification or an attestation of a future bridge transfer. Worker readiness and source-route eligibility are
rechecked when admitting quotes.

After source submission, `POST /api/perps/funding/intents/:id/source` verifies the transaction against the persisted
intent using the source RPC: chain, transaction hash, sender, target, calldata, and native value must match. The
transaction must already be visible to that RPC. `GET /api/perps/funding/intents/:id` reconciles `sourceStatus` as
`pending`, `confirmed`, or `reverted`, using a canonical receipt with two source-chain confirmations. Its separate
`bridgeStatus` remains advisory provider progress. Neither source confirmation nor bridge progress proves the
destination clearinghouse credit; that requires the destination worker's confirmed credit evidence.

The current API requires a quoted minimum of at least 1 USDC. The worker waits until confirmed credits plus the
receiver's available balance meet that minimum before scheduling a flush. Once the minimum is credited, subsequent
balances of at least 1 USDC can be flushed automatically; smaller late arrivals remain in the receiver to bound
sponsored gas use. Anyone may manually flush that dust, or the beneficiary may recover it under the contract rules
above. The receiver contract itself has no 1 USDC minimum. A provider status alone never satisfies the worker's
credit check, and failed destination reconciliation is not a reason to repeat the source payment.

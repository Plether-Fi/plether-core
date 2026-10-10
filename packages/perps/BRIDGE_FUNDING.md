# Bridge funding into perps margin

The Across integration requests an atomic destination action through Across's existing MulticallHandler: approve
canonical USDC to the configured clearinghouse, call `depositFor` for the user's verified trading account, clear the
allowance, and emit the quote's unique marker through the known Across EventEmitter.
The same trading account is the explicit fallback recipient. A successful bridge fill is not proof of margin credit;
fallback USDC in that account's wallet remains `needs-deposit`.

The route remains disabled without a reviewed compatible release. No live compatible clearinghouse or successful
end-to-end bridge transfer is asserted here. Existing immutable clearinghouses without
`MarginClearinghouse.depositFor(address,uint256)` require a new compatible core release. This integration does not
upgrade them or resolve the application's active V3 trading and account-abstraction compatibility. Do not replace
addresses in historical release records to imply an upgrade.

## Destination call flow

1. Pin the destination chain, canonical USDC, clearinghouse, Across SpokePool proxy and implementation, existing
   MulticallHandler, runtime code hashes, and confirmation policy from the reviewed funding release. Verify the
   trading-account beneficiary separately from the connected source wallet; they may be different addresses.
2. Persist the funding intent and validate the provider quote before requesting a source signature. The quote must
   bind the allowed source route, destination token/handler, beneficiary, destination message, amount bounds, and
   expiry. The message's nonzero `fallbackRecipient` must equal that beneficiary.
3. The required message has four ordered zero-native-value calls: an exact-balance USDC approval to the clearinghouse,
   `depositFor(beneficiary, balance)`, `USDC.approve(clearinghouse, 0)`, and the pinned Across EventEmitter's
   `emitData(quoteId)` with the 32-byte quote identifier. The first two are handler self-calls to
   `makeCallWithBalance`; each inner amount starts at zero and is replaced at byte offset 36 with the handler's
   current canonical-USDC balance. The deposit amount is not a quoted estimate or unlimited allowance. The parser
   accepts exactly these four calls, or eight calls with only two additional same-token/same-beneficiary drains and
   two bounded metadata calls to the known emitter. The quote marker and nonzero beneficiary fallback are mandatory.
4. If the calls succeed, the clearinghouse pulls that balance from the handler and credits the beneficiary. If any
   inner call reverts, the handler rolls back the entire call sequence and drains remaining canonical USDC to the
   explicit beneficiary. Leftover tokens are drained there after successful calls too. If the fallback transfer itself cannot
   succeed, the handler invocation reverts; do not report wallet delivery from the attempted callback alone.
5. Attribute the result only after matching the canonical destination fill to the persisted source intent and
   confirming its receipt and relevant credit/fallback logs at the configured depth. Successful credit requires the
   exact quote marker after the clearinghouse events in that fill's callback interval. Fallback requires matching
   `CallsFailed`, token transfer, and `DrainedTokens` evidence in the same interval. Refresh canonical account balances
   before using credited funds in a trading decision.

The handler is shared and its callback is permissionless. It is not a per-user custody account, and tokens left
there can be consumed by another caller. Never send funds there as a standalone transfer or design a later flush or
recovery step. The intended fill and callback execute together. Balance substitution consumes the handler's full
current token balance, which can include unsolicited dust; use the actual confirmed credit amount, not a locally
invented balance increment. Code pins establish contract identity, not source-intent authorization.

## Clearinghouse accounting

`depositFor` pulls tokens from **its caller**, requires exact receipt of the requested amount, and credits the chosen
account's free settlement. It does not allocate position margin, collect/checkpoint carry, change reservations or
terminal NAV, or grant the payer account authority. Outstanding carry remains due under ordinary account actions
and risk checks. Existing owner `deposit` and `depositMargin` carry behavior is unchanged.

The clearinghouse emits `Deposit(account,asset,amount)` once and an additional `DepositFor(payer,account,amount)`
describing the same credit. Index it once; `DepositFor` adds payer attribution. For the direct Across route, the payer
is the verified handler, not the relayer or source wallet. Match chain, emitting clearinghouse, token, beneficiary,
handler payer, amount, successful receipt, and the intent's fill evidence. An unrelated deposit in the same account
cannot satisfy a funding intent.

A fallback transfers wallet USDC to the trading-account beneficiary without crediting the clearinghouse. That result
is `needs-deposit`, never trading-ready margin on that evidence alone. A separate authenticated deposit can move
those tokens into margin. A connected owner EOA cannot spend a smart account's tokens without that account's
normal authorization path. After credit, normal clearinghouse withdrawal, health, and carry rules apply.

## Provider and lifecycle boundaries

The runtime manifest selects `provider: "across"`. The application currently targets Ethereum mainnet USDC/USDT to
native Arbitrum USDC through an external source wallet. Support for those routes does not establish support for
other tokens, chains, accounts, or future quotes. No Privy funding-session API is required by the core `depositFor`
method or the client helpers.

The backend sends the documented `POST /api/swap/approval` action body for those four calls. An authentic response
with the required handler recipient, nonzero beneficiary fallback, and exact destination calldata has not been
captured: the live POST attempt returned HTTP 403, and no Across API key/integrator ID was available for verification.
The actual API recipient/fallback encoding therefore remains unverified. The runtime parser rejects any returned
calldata that does not meet the recipe; a successful HTTP response alone cannot enable a source transaction. The
route remains disabled until an authentic quote and a real compatible clearinghouse establish the integration.

Validate every quote's source/destination chains and tokens, exact destination message and fallback beneficiary,
amounts, slippage/expiry, transaction targets, approval spenders, swap exchanges, and SpokePools against the persisted
intent and reviewed allowlists. Provider-suggested addresses must not extend an allowlist. Where a source approval is
required, approve only the intended spend and independently validate the subsequent transaction.

| Evidence | What it establishes |
|---|---|
| Approved quote | A currently offered route matching the intent's constraints |
| Submitted source transaction | A transaction hash, not successful source execution |
| Confirmed source receipt and deposit event | Canonical source execution and the relay identity to reconcile |
| Provider delivery status | Advisory provider progress |
| Canonical destination fill | The intent's relay was filled; destination calls may still have fallen back |
| Matching confirmed clearinghouse credit | The actual amount credited to the beneficiary |
| Matching confirmed fallback transfer | Wallet USDC delivered to the beneficiary; still `needs-deposit` |

Persist intent identity before submission and resume it after reload, wallet changes, RPC failures, replacement
transactions, and provider timeouts. Do not repeat the source payment because polling or destination reconciliation
failed. Reorgs invalidate earlier confirmation evidence and require reconciliation again. The integration deploys no
per-intent receiver/factory and has no bridge-specific KMS signer, deployment transaction, or flush transaction.

## Client helpers

`@plether-fi/perps-aa-client` exports the minimal clearinghouse funding ABI and:

- `buildDepositForCalls({usdc,clearinghouse,beneficiary,amount})`: approval plus a caller-funded deposit, both executed
  from the same payer. Batch atomically when the account supports it; otherwise confirm approval before depositing.
  This helper uses a supplied positive amount; it does not build the Across balance-replacement message.
- `verifyBridgeFundingDeployment({client,deployment})`: checks the RPC chain, runtime hashes for USDC, clearinghouse,
  SpokePool proxy/implementation and handler, the SpokePool's EIP-1967 implementation slot, and the clearinghouse's
  settlement-token binding at one block. Returns the verified addresses, chain ID, and observation block.

`BridgeFundingDeployment` contains `chainId`, `usdc`, `clearinghouse`, `destinationSpokePool`,
`destinationSpokePoolImplementation`, `multicallHandler`, and each address's corresponding `*RuntimeCodeHash`.
Map those fields from a previously validated release. The handler has no immutable SpokePool binding; the helper
cannot prove route authorization, provider support, `depositFor` behavior, or a credited receipt. It also does not
replace verification of the full core graph. USDC's proxy governance remains part of the settlement-token trust model.

The deposit builder returns raw zero-native-value calls. It does not create a quote, sponsor gas, prove wallet
control, or extend the existing paymaster action allowlist. These helpers are not new `sendSponsoredAction` kinds.

## Release artifact and validation

Use the separate repository-root `deployments/perps-bridge-funding.template.json`. Do not add funding fields to
`arbitrum-sepolia-perps-aa.template.json`, whose strict schema describes account abstraction and paymaster policy.
The funding profile contains:

- `version: "perps-funding-v1"`, `provider: "across"`, `destinationChainId`, `releaseId`, `clearinghouse`,
  `clearinghouseCodeHash`, `token`, `confirmations`, and `startBlock`;
- `destinationSpokePool`, `destinationSpokePoolCodeHash`, `destinationSpokePoolImplementation`,
  `destinationSpokePoolImplementationCodeHash`, `multicallHandler`, and `multicallHandlerCodeHash`;
- `sources`, each with `chainId`, `name`, `token`, `symbol`, `decimals`, `transactionTargets`, `approvalSpenders`,
  `swapExchanges`, and `spokePools`;
- `evidence`, with source provenance, pinned contract addresses/runtime hashes, and a successful real third-party
  `depositFor` probe.

Flat addresses/hashes must agree with `evidence.contracts`; missing, zero, malformed, inconsistent, or unknown fields
fail strict release validation. The template intentionally contains null deployment values and is not an executable
profile. Populate a new artifact from reviewed deployment evidence and pin its trusted distribution location.
`VITE_PERPS_FUNDING_MANIFEST_URL` selects that artifact for the frontend; a missing or incompatible release keeps the
route unavailable. The active application deployment and its trading/AA configuration must match separately.

From the repository root, validate the unpopulated template without treating it as a release:

```bash
node scripts/perps-bridge-funding-release.mjs template deployments/perps-bridge-funding.template.json
```

For a real release, set `FUNDING_MANIFEST` to the saved artifact and `FUNDING_RPC_URL` to the destination RPC. `verify`
requires `cast` on `PATH`:

```bash
node scripts/perps-bridge-funding-release.mjs validate "$FUNDING_MANIFEST"
node scripts/perps-bridge-funding-release.mjs verify "$FUNDING_MANIFEST"
```

Both commands are read-only. Verification checks runtime hashes and reciprocal bindings for token, clearinghouse,
Engine, HousePool, Router, oracle, and lifecycle Book, plus handler identity and the SpokePool proxy implementation
slot/runtime at the captured block. The direct third-party `depositFor` probe must have a successful canonical,
sufficiently confirmed receipt and matching transfer/credit events; `startBlock` must not skip its block. An ABI
selector, simulated call, or token binding alone does not establish deployed `depositFor` support.

The funding verifier complements the full perps release verifier. It does not verify all admins, sidecars, terminal
Book, vaults, economic parameters, activation state, operational services, or source-chain provider allowlists.
SpokePool upgrades can invalidate a reviewed implementation pin. Keep historical artifacts unchanged and enable
routing only after the compatible core, funding graph, and application releases pass their respective checks.

## Backend operation

The separate `plether-app` repository owns quote admission and read-only destination reconciliation. Its worker
entrypoint is `apps/backend/app/FundingWorker.hs`; implementation is under
`apps/backend/src/Plether/Perps/Funding/`. Configure API and worker from the same verified release served to the
frontend. `PERPS_FUNDING_DEPLOYMENT_JSON` contains JSON text, not a filename, including the flat clearinghouse,
SpokePool proxy/implementation, and handler address/hash fields above. `releaseId` is at most 128 characters;
`confirmations` is between 1 and 1,000.

Both processes need PostgreSQL and destination RPC configuration (`DATABASE_URL`, `PERPS_RPC_URL` or `RPC_URL`, and
`PERPS_RPC_AUTH_TOKEN` when required), plus an HTTPS Ethereum-mainnet `PERPS_FUNDING_SOURCE_RPC_URL` and optional
`PERPS_FUNDING_SOURCE_RPC_AUTH_TOKEN`. The API also needs actual `ACROSS_API_KEY` and `ACROSS_INTEGRATOR_ID`
credentials. Keep `PERPS_FUNDING_ENABLED=false` while the compatible deployment and provider route are unavailable.
A configuration flag alone cannot establish release or worker readiness.

Run `plether-funding-worker --once` for one reconciliation pass or `--loop` continuously. The worker persists
observations and confirmed evidence; it does not deploy receivers, sign, broadcast, or flush. Use the backend's
bridge-funding configuration documentation for current API readiness and schema requirements. Existing AA KMS
configuration serves its separate trading/sponsorship role and is not bridge funding infrastructure.

New quotes require a quoted minimum of at least 1 USDC. Source-hash registration verifies the submitted transaction
against the persisted quote. Source confirmation requires two canonical source confirmations and binds a unique
relay to the intent. The backend also pins the known EventEmitter runtime used for the success marker. Source status
and provider progress stay separate from destination credit. A confirmed beneficiary fallback is `needs-deposit`;
a provider's `filled` or `refunded` response alone cannot establish margin credit. Keep reconciliation available for
pending intents on their original release until resolved, even after new quote admission is disabled. The API hides
previously confirmed credit/fallback status while observer readiness or its evidence is stale.

## Validation limits

The checked-in [runtime fixtures](test/fixtures/across-direct-funding/README.md) record the observed Arbitrum handler
and emitter bytecode and their source provenance. Installing those runtimes into a local test VM with mock USDC and
the local clearinghouse tests destination-call semantics. It is not a mainnet fork, a real provider quote, a mined
bridge fill, or proof of a compatible live clearinghouse. Activation still requires actual reviewed deployment and
route evidence.

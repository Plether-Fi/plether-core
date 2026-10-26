# MockUSDG for a new perps deployment

Status: the core MockUSDG implementation and breaking token-neutral API rename are implemented and targeted validation has completed. The SDK is version `0.4.0`, with no old token-specific API aliases. Source finalization, packing the SDK from a clean commit, the packed-consumer smoke check, and companion app integration remain the finalization steps below. No full-suite rerun, deployment, or transaction broadcast has been performed. Revision-bound release export and live activation remain deferred until review and separate authorization.

## Objective and decisions

Prepare a fresh Arbitrum Sepolia perps deployment using freely mintable MockUSDG, with clear token metadata and an operational path for future production USDG rewards.

- Deploy `MockUSDG` with name `Mock USDG`, symbol `USDG`, six decimals, and unrestricted `mint(address,uint256)` on testnet. Display `USDG` in the testnet app.
- Keep the existing perps PnL, margin, liquidation, carry, tranche, and solvency calculations and numerical parameters.
- Rename every current perps token-specific API and its consumers to token-neutral names: `settlementToken()` and `settlementToken` for token addresses, `*Assets` for settlement amounts, `*AssetAtoms` for exact base units, and `_ASSETS` for amount constants. Rename `getFreeAssets`, `getSettlementFreeAssets`, and `AccountAssetBuckets` consistently. This is a deliberate breaking API change for a fresh deployment, with no compatibility aliases. Token identity comes from the configured address and metadata; `1_000_000` six-decimal base units means one token.
- Scope changes to the new perps deployment and its consumers. Existing deployed stacks, historical release evidence, spot/options code, and shared USDC mocks remain valid historical or independent configurations.
- MockUSDG provides ordinary ERC-20 transfers and approvals. It does not implement EIP-2612 or EIP-3009, mirroring the existing release mock. Signed-deposit compatibility with official USDG is a later validation task.
- Future GDN rewards use a separate payout recipient. Reward accrual, claiming, distribution economics, and production registration are not simulated by the mock.

## 1. Deployment token and configuration

Files:

- `script/DeployPerpsArbitrumSepolia.s.sol`
- `script/BootstrapPerpsArbitrumSepolia.s.sol`
- `script/VerifyPerpsArbitrumSepolia.s.sol`
- `.env.arbitrum-sepolia-perps.example`

Implementation:

1. Replace the deployment-local `MockUSDC` class with `MockUSDG`. Update script-local types, deployment struct references, construction, and output labels. Keep it local to the perps release script rather than changing the shared mock used by other products.
2. Bind the new token consistently to the clearinghouse, engine, HousePool, both tranche vaults, and relevant lenses.
3. Use `PERPS_SETTLEMENT_TOKEN` for new perps bootstrap and verification configuration. Do not populate `PERPS_USDC` with the new USDG address: spot scripts currently inherit that setting as a fallback.
4. Use neutral seed inputs `SENIOR_SEED_ASSETS` and `JUNIOR_SEED_ASSETS` in the new environment example and script readers. Preserve the existing numerical seed values and six-decimal units.
5. Reuse the current generic `IMintableERC20` bootstrap logic, including idempotent permanent LP seeds and optional `TEST_USER_RECIPIENTS` / `TEST_USER_AMOUNTS` funding.
6. Keep deployment verification of code, six decimals, and asset bindings; add expected mock identity verification for this testnet release. Do not treat name/symbol checks as authentication of official USDG.
7. Document a direct mint command for repeat tester funding so users do not need to rerun deployment or activation scripts. Optional bootstrap tester funding intentionally mints again on each eligible rerun.

Acceptance: a fresh stack uses one MockUSDG address throughout; testers can mint repeatedly; seed reruns do not duplicate permanent seeds; an inconsistent configured settlement address is rejected.

## 2. Release metadata and export

Files:

- `deployments/arbitrum-sepolia-perps.template.json`
- `scripts/export-perps-release.py`
- `test/scripts/PerpsReleaseDeploymentSize.t.sol`
- Release consumers in `plether-app`

Implementation:

1. Give new manifests a canonical `contracts.settlementToken` entry with explicit artifact `script/DeployPerpsArbitrumSepolia.s.sol:MockUSDG`, address, and runtime code hash.
2. Record name, symbol, decimals, mock status, and `supportsReceiveWithAuthorization: false` in settlement-token metadata. Make application display and capability configuration consume this metadata.
3. Use schema version 4 and update current consumer readers together. Current runtime configuration must require the new prepared manifest instead of accepting old token-specific aliases. Preserve historical manifests and decoders as archived evidence, separate from current runtime configuration.
4. Align exporter artifact resolution and deployment-size evidence with the new key and explicit artifact. Keep historical `mockUsdc` manifests unchanged as evidence; the current export path uses the explicit new settlement-token entry.
5. Generate new release artifacts into a fresh directory from the reviewed source revision. Do not rewrite old manifests, ABI snapshots, code hashes, or deployment receipts, and do not mark a prepared release as deployed or active.

Acceptance: the exported token ABI is MockUSDG's; every manifest contract matches its size evidence; the app resolves the new token without interpreting an old USDC address as USDG.

## 3. SDK and application integration

Core repository files:

- `packages/perps-aa-client/src/actions.ts`
- `packages/perps-aa-client/src/capabilities.ts`
- `packages/perps-aa-client/src/errors.ts`
- Relevant SDK tests and documentation

Companion work in `Plether-Fi/plether-app`:

- Deployment configuration and manifest ingestion.
- Token display, balances, approvals, funding/faucet UI, deposit and withdrawal UI.
- Sponsorship target configuration, simulations, and token-address/code-hash checks.
- Indexer and worker deployment bindings for the new stack.

Implementation:

1. Pass the MockUSDG address through SDK `settlementToken` inputs. Rename current ABI fields, getters, errors, action inputs, amount constants, receipt types, typed-data definitions, and consumer accessors consistently. Regenerate current ABIs and bindings from the renamed source; remove old token-specific aliases. Preserve archived release snapshots and historical compatibility evidence without exposing them as current APIs.
2. Replace active hardcoded USDC display/error text with the configured token symbol (`USDG` for this release); retain numeric formatting at six decimals.
3. Keep `supportsReceiveWithAuthorization` false. Do not offer the owner-wallet signed first-deposit route for this mock.
4. Make the normal testnet path: obtain the canonical trading smart-account address, mint MockUSDG to it, then use the existing `buildSmartAccountBalanceDepositAction` to batch approval and `depositMargin`. The mint transaction still needs testnet gas. If funds are already in an owner EOA, transfer to the trading account before using this deposit path.
5. Ensure the app does not disable the supported account-balance deposit just because the signed owner-wallet route is unavailable. Refresh sponsorship targets for the new stack and test sponsorship where it is enabled.
6. Keep external bridge funding unavailable for the mock unless a real provider route is separately established. Do not reuse a USDC bridge release manifest for MockUSDG.

Acceptance: the app clearly shows USDG, credits the intended trading account, offers a working funded-account deposit path, and never advertises a signed-deposit or bridge capability the token lacks.

## 4. Future rewards readiness

Implementation:

1. Add an operational rewards section to the new deployment metadata/runbook: network, intended holding addresses (clearinghouse and HousePool), registration status, separate payout destination, and the party controlling that destination.
2. On MockUSDG testnet set status to `not_applicable` and payout destination to unconfigured until a destination is supplied. Do not invent a production address or imply eligibility.
3. Document the production registration procedure for those holding addresses and a separate treasury/multisig payout destination. Registration, claim authority, verification, and exact eligible balances must be confirmed against the production Paxos configuration when activated.
4. Validate any future configured payout destination against the deployment inventory: it must not be the clearinghouse, engine, HousePool, or tranche vaults. Its controller must be able to move received rewards.
5. Route rewards independently from collateral custody. The clearinghouse does not credit unsolicited transfers and cannot rescue its settlement token; HousePool only recognizes excess after an explicit owner action.
6. Keep unclaimed rewards outside margin and LP NAV. A future distribution module can pay traders/LPs or fund a separately chosen allocation policy without changing the clearinghouse merely to receive rewards.

Acceptance: the deployment records the information needed for later registration and payout routing, but has no new principal-withdrawal permissions, arbitrary-call hooks, claim contracts, APY promises, or automatic changes to the tranche waterfall.

## 5. Tests and documentation

Extend existing integration tests instead of duplicating ERC-20 library tests:

- `test/scripts/ArbitrumSepoliaReleaseDefaults.t.sol`: updated mock types and configuration names.
- `test/scripts/VerifyPerpsArbitrumSepolia.t.sol`: deploy -> verify -> seed -> verify -> activate -> verify with MockUSDG; identity/address checks; preserve seed-rerun assertions.
- `test/scripts/PerpsReleaseDeploymentSize.t.sol`: new settlement-token artifact and manifest key.
- `scripts/test_oracle_release_export.py`: explicit MockUSDG artifact/schema handling and historical artifact resolution where changed.
- SDK capability tests: a token without EIP-3009 disables the authorization route while ordinary account-balance deposit actions remain usable.
- A runtime integration smoke test using the actual release MockUSDG: mint to trader account -> approve/deposit -> open/close -> withdraw; include LP deposit/finalization and asynchronous redemption/claim.
- Reuse current excess/donation accounting coverage; add a small rewards-configuration validation test only if that validator is introduced. Do not add a rewards simulator.

The authorized targeted checks have completed; the current validation record below supersedes the earlier pre-rename results for this API change. Current consumer fixtures target the renamed API, while historical release snapshots and fixture evidence remain archived and unchanged. No full perps suite was rerun.

Update `packages/perps/README.md`, `DEPLOYMENT.md`, `SECURITY.md`, affected NatSpec, the environment example, and SDK docs to explain MockUSDG, unrestricted test minting, six-decimal settlement base units, breaking token-neutral API names without aliases, testnet funding, and the separate future rewards destination. Update downstream app documentation with the deployment configuration changes.

## 6. Release sequence and completion

1. Finalize and review the coherent core change, then record it in a clean source commit through the authorized source-control workflow. Include the renamed contracts, deployment/configuration, manifests, generated bindings, SDK `0.4.0`, tests, and documentation.
2. Pack SDK `0.4.0` from that clean commit and run the packed-consumer smoke check against the current renamed API. Record the source revision and package evidence; archived historical fixtures remain separate from current exports.
3. Complete companion app integration against that exact SDK artifact and matching generated ABIs. Keep the schema-4 prepared manifest inactive, without deployed addresses or enabled sponsorship/funding, until a fresh release is supplied.
4. Produce any revision-bound release evidence through the existing clean-tree workflow when authorized. A later deployment must use the existing deployed -> seeded -> active verification stages and runtime smoke tests, recording actual addresses, code hashes, transactions, and results. Deployment and activation are not part of the present implementation.

Implementation readiness means freely mintable MockUSDG is wired through the new perps source and its consumers; the app's funding, trading, and withdrawal paths use the matching token-neutral API without aliases; collateral math retains its prior behavior; metadata identifies the correct token and capabilities; and future USDG reward registration/payout configuration has a documented home. Live deployment acceptance remains a separate authorized stage.

Production USDG deployment, real-token signature compatibility, GDN onboarding, reward allocation automation, and new cross-chain funding routes are separate follow-up work.

## Current token-neutral implementation and validation record

- The fresh perps API uses `settlementToken`, `*Assets`, `*AssetAtoms`, and `_ASSETS` identifiers throughout current contracts, bindings, SDK, deployment tooling, and consumer configuration. SDK `0.4.0` exposes no old token-specific aliases. Historical ABIs, fixtures, releases, and audit evidence remain archived for their original deployments.
- MockUSDG retains six decimals and unrestricted test minting. The prepared manifest identifies it explicitly; signed owner-wallet deposits and external bridge funding remain unsupported for this mock. Sponsorship and activation remain disabled in the prepared configuration until a reviewed deployed release is supplied. Reward status remains `not_applicable`, with separate payout/controller metadata unconfigured.

| Completed check | Result and scope |
| --- | --- |
| Root deployment/script tests | 43 passed, including MockUSDG lifecycle and deployment binding checks. |
| Order lifecycle tests | 42 passed, including six fuzz tests at 256 runs each. |
| SDK | 129 tests passed; typecheck and build passed for SDK `0.4.0`. |
| SDK artifact tooling | Four tests passed; packing from the final clean commit and the packed-consumer smoke check remain finalization steps. |
| Python release exporter | 30 tests passed. |
| Node bridge tooling | 10 checks passed. |
| Repository hygiene | Package boundaries, Solidity formatting, and diff checks passed. |
| Solidity compiler checks | ABI/type checking covered 421 Solidity files; the optimized production build passed. |
| Mechanical source comparison | 130 production files matched the approved identifier mapping. |
| Mechanical ABI/storage comparison | 169 artifacts preserved ABI types/order and storage types/order/slots under the rename. |

The mechanical comparisons support the unchanged accounting implementation and data layout. They do not make the renamed API backward compatible: public names and affected selectors/typed-data definitions must be consumed through the matching current release. The targeted results are not a full-suite pass and are not live deployment evidence. No full-suite rerun, deployment, public-testnet mint, bootstrap, activation, or other transaction broadcast was performed for this change.

## Earlier MockUSDG implementation record (before API rename)

- Core branch: `codex/perps-mock-usdg`; implementation and validation used `b431a689`, then the branch was advanced to `f50f8482` (audit documentation only) for PR preparation.
- Deployment scripts, the schema-4 template/export checks, SDK wording/capabilities, operational documentation, and MockUSDG trading/LP integration coverage are implemented.
- Companion app work is isolated from the existing dirty app checkout. The complete 52-file patch and its base-commit/checksum metadata are saved locally under `artifacts/perps-usdg/plether-app-mock-usdg.patch` and `.patch.json`. The patch applies to app commit `ccb8788ed7a3fbdcc258fc0c91f277949913974a`; active deployment configurations remain pinned to their existing release.
- Validation completed: 43 root script tests, including the actual MockUSDG trading/LP lifecycle; all 29 deployment-size records against the template and compiled artifacts; 29 Python export tests; 129 SDK tests plus typecheck/build; Solidity formatting and package boundaries.
- The production perps gates passed all 92 tests. The full correctness run was stopped at the user's request because the targeted checks are sufficient for this change. Its partial report contained 999 passing results and no reported failures; it is interrupted evidence, not a completed full-suite pass. No further full-suite run is required for this implementation.
- App validation completed: 1,807 frontend tests, followed by 22 funding tests including one additional recovery regression; typecheck, production build and targeted lint; 262 backend Perps tests, separate Manifest/Release checks, 16 offline tooling tests, and desktop/mobile visual checks. Both review findings were fixed and rechecked.
- Local test evidence is under `artifacts/perps-usdg/`; full perps CI evidence is under `artifacts/perps/`. This working-tree evidence is not an immutable release bundle.
- No deployment, public-testnet mint, bootstrap, or activation was performed. Source commits and PR publication were authorized separately. Export the revision-bound release bundle only after the source is committed and reviewed, using the existing clean-tree checks. Live chain validation and activation remain future authorized work.

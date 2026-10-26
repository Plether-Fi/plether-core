# MockUSDG for a new perps deployment

Status: implemented and validated locally on `codex/perps-mock-usdg`. The full perps correctness run was stopped at the user's request; targeted validation is complete. No deployment or transaction broadcast has been performed. Revision-bound release export and live activation remain deferred until the changes are reviewed and a deployment is authorized.

## Objective and decisions

Prepare a fresh Arbitrum Sepolia perps deployment using freely mintable MockUSDG, with clear token metadata and an operational path for future production USDG rewards.

- Deploy `MockUSDG` with name `Mock USDG`, symbol `USDG`, six decimals, and unrestricted `mint(address,uint256)` on testnet. Display `Mock USDG` in the testnet app.
- Keep the existing perps PnL, margin, liquidation, carry, tranche, and solvency calculations and numerical parameters.
- Preserve public Solidity selectors, events, error signatures, receipt fields, and SDK input names such as `USDC()`, `*Usdc`, and `usdc`. Document them as legacy identifiers for six-decimal settlement-token amounts/addresses. Token identity comes from the configured address and metadata.
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
3. Increment the new manifest schema version for the contract-key change and update current consumer readers together. Keep support for reading historical schemas where those readers already handle old deployments.
4. Align exporter artifact resolution and deployment-size evidence with the new key and explicit artifact. Preserve historical `mockUsdc` interpretation for old manifests.
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

1. Pass the MockUSDG address through existing SDK `usdc` inputs. Keep action encodings, public exports, signed-operation domains, and historical compatibility fixtures stable.
2. Replace active hardcoded USDC display/error text with configured token labels or `settlement token`; retain numeric formatting at six decimals.
3. Keep `supportsReceiveWithAuthorization` false. Do not offer the owner-wallet signed first-deposit route for this mock.
4. Make the normal testnet path: obtain the canonical trading smart-account address, mint MockUSDG to it, then use the existing `buildSmartAccountBalanceDepositAction` to batch approval and `depositMargin`. The mint transaction still needs testnet gas. If funds are already in an owner EOA, transfer to the trading account before using this deposit path.
5. Ensure the app does not disable the supported account-balance deposit just because the signed owner-wallet route is unavailable. Refresh sponsorship targets for the new stack and test sponsorship where it is enabled.
6. Keep external bridge funding unavailable for the mock unless a real provider route is separately established. Do not reuse a USDC bridge release manifest for MockUSDG.

Acceptance: the app clearly shows Mock USDG, credits the intended trading account, offers a working funded-account deposit path, and never advertises a signed-deposit or bridge capability the token lacks.

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

Run formatting and package-boundary checks, targeted root deployment tests, release-export Python tests, the appropriate perps CI suite, and SDK tests/typecheck/build. Verify SDK compatibility fixtures without regenerating historical goldens.

Update `packages/perps/README.md`, `DEPLOYMENT.md`, `SECURITY.md`, affected NatSpec, the environment example, and SDK docs to explain MockUSDG, unrestricted test minting, six-decimal settlement units, retained legacy API names, testnet funding, and the separate future rewards destination. Update downstream app documentation with the deployment configuration changes.

## 6. Release sequence and completion

1. Land the mock, script/configuration, manifest, test, and documentation changes as one coherent core change.
2. Update SDK display text and companion app configuration/funding behavior against the new manifest format.
3. Complete local tests and a no-broadcast deployment rehearsal; produce fresh revision-bound release evidence using the existing release workflow.
4. When deploying the new testnet release, use the existing deployed -> seeded -> active verification stages and complete the runtime smoke tests. Record actual addresses, code hashes, transactions, and validation results.

Done means: a new perps stack uses freely mintable MockUSDG end to end; the app supports minting/funding, trading, and withdrawals; collateral math and public protocol interfaces retain their prior behavior; release evidence identifies the correct token; and future USDG reward registration/payout configuration has a documented home.

Production USDG deployment, real-token signature compatibility, GDN onboarding, reward allocation automation, and new cross-chain funding routes are separate follow-up work.

## Local implementation record

- Core branch: `codex/perps-mock-usdg`; implementation and validation used `b431a689`, then the branch was advanced to `f50f8482` (audit documentation only) for PR preparation.
- Deployment scripts, the schema-4 template/export checks, SDK wording/capabilities, operational documentation, and MockUSDG trading/LP integration coverage are implemented.
- Companion app work is isolated from the existing dirty app checkout. The complete 52-file patch and its base-commit/checksum metadata are saved locally under `artifacts/perps-usdg/plether-app-mock-usdg.patch` and `.patch.json`. The patch applies to app commit `ccb8788ed7a3fbdcc258fc0c91f277949913974a`; active deployment configurations remain pinned to their existing release.
- Validation completed: 43 root script tests, including the actual MockUSDG trading/LP lifecycle; all 29 deployment-size records against the template and compiled artifacts; 29 Python export tests; 129 SDK tests plus typecheck/build; Solidity formatting and package boundaries.
- The production perps gates passed all 92 tests. The full correctness run was stopped at the user's request because the targeted checks are sufficient for this change. Its partial report contained 999 passing results and no reported failures; it is interrupted evidence, not a completed full-suite pass. No further full-suite run is required for this implementation.
- App validation completed: 1,807 frontend tests, followed by 22 funding tests including one additional recovery regression; typecheck, production build and targeted lint; 262 backend Perps tests, separate Manifest/Release checks, 16 offline tooling tests, and desktop/mobile visual checks. Both review findings were fixed and rechecked.
- Local test evidence is under `artifacts/perps-usdg/`; full perps CI evidence is under `artifacts/perps/`. This working-tree evidence is not an immutable release bundle.
- No deployment, public-testnet mint, bootstrap, or activation was performed. Source commits and PR publication were authorized separately. Export the revision-bound release bundle only after the source is committed and reviewed, using the existing clean-tree checks. Live chain validation and activation remain future authorized work.

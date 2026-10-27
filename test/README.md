# Plether Integration Test Suite

Package-owned unit, fuzz, invariant, and security tests live beside their contracts under `packages/*/test`. This root
directory contains cross-package compatibility, deployment-script, and mainnet fork tests.

## Running Tests

```bash
make test                                      # Package tests plus root integration tests
make test-packages                             # Spot, options, and perps tests
make test-spot                                 # One package
forge test --root packages/spot --match-test "test_FunctionName"
forge test --root packages/spot --match-path "test/ZapRouter.t.sol"
forge test --no-match-path "test/fork/*"        # Root compatibility and script tests

# All perps fork integrations, including real Pyth, EntryPoint and native ArbSys.
# Requires MAINNET_RPC_URL and ARB_SEPOLIA_RPC_URL; PYTH_API_KEY is optional.
# The Arbitrum archive endpoint must support eth_call state overrides.
set -a; source .env; set +a
make test-perps-fork-all
# Zero skips required. Selection, compiler configuration and results are recorded
# under artifacts/perps/integration-forks (override with PERPS_ARTIFACT_DIR).

# Root fork tests: Ethereum mainnet + Arbitrum Sepolia archive RPCs.
set -a; source .env; set +a
export ORACLE_SYNC_FIXTURE=test/fixtures/oracle-sync/arbitrum-sepolia.json
export ORACLE_SYNC_EXPECT_FIXED=true
forge test --match-path "test/fork/*" \
  --no-match-contract '^(PythRealUpdateForkTest|OracleSynchronizationGasForkTest)$' -vvv

# The gas/refund scenarios require isolated transaction contexts.
ORACLE_SYNC_SCENARIO_MANIFEST=test/fixtures/oracle-sync/scenarios.json \
ORACLE_SYNC_ISOLATION_MODE=transaction \
  forge test --isolate --match-contract '^OracleSynchronizationGasForkTest$' -vvv

# Package fork lanes use the same Arbitrum Sepolia archive endpoint.
export SPONSORED_CLOSE_FORK_RPC_URL="$ARB_SEPOLIA_RPC_URL"
export CLOSE_REGRESSION_ARCHIVE_RPC_URL="$ARB_SEPOLIA_RPC_URL"
export NATIVE_CLOSE_FORK_RPC_URL="$ARB_SEPOLIA_RPC_URL"
make test-perps-fork
ARBITRUM_SEPOLIA_RPC_URL="$ARB_SEPOLIA_RPC_URL" \
  forge test --root packages/perps-aa --match-path 'test/*Fork.t.sol' -vvv

# Package gas snapshot (excludes fuzz/invariant)
forge snapshot --root packages/spot --no-match-test "testFuzz_|invariant_"
```

## Test Structure

### Spot Tests (`packages/spot/test/*.t.sol`)

Core contract logic using mock contracts. No network dependency.

| File | Contract | Tests |
|------|----------|-------|
| `SyntheticSplitter.t.sol` | SyntheticSplitter | 106 |
| `SyntheticSplitterConcurrent.t.sol` | Multi-user concurrency | 9 |
| `SyntheticSplitterPreview.t.sol` | Preview function accuracy | 22 |
| `SyntheticSplitterFuzzy.t.sol` | Fuzz testing | 6 |
| `InvarCoin.t.sol` | InvarCoin vault | 106 |
| `RewardDistributor.t.sol` | Yield distribution | 70 |
| `ZapRouter.t.sol` | Zap + MEV + mutation | 52 |
| `LeverageRouter.t.sol` | BEAR leverage + interest | 50 |
| `BullLeverageRouter.t.sol` | BULL leverage + drift | 56 |
| `BasketOracle.t.sol` | 6-feed basket pricing | 39 |
| `MorphoOracle.t.sol` | Morpho adapter (24 dec) | 9 |
| `StakedOracle.t.sol` | Staked price oracle | 13 |
| `OracleEdgeCases.t.sol` | Staleness, sequencer, boundaries | 14 |
| `StakedToken.t.sol` | ERC4626 staking wrapper | 17 |
| `SyntheticToken.t.sol` | ERC20 + flash mint | 4 |
| `VaultAdapter.t.sol` | ERC4626 vault adapter | 20 |
| `MorphoBalancesLib.t.sol` | Balance computation | 7 |
| `SecurityAttackVectors.t.sol` | Attack simulations | 6 |
| `Reentrancy.t.sol` | Reentrancy guards | 3 |
| `Integration.t.sol` | Cross-contract flows | 11 |
| `oracles/PythAdapter.t.sol` | Pyth oracle adapter | 29 |

### Options Tests (`packages/options/test/options/*.t.sol`)

| File | Contract | Tests |
|------|----------|-------|
| `DOVZapRouter.t.sol` | Single-sided DOV entry | 12 |
| `MarginEngine.t.sol` | Margin accounting | 60 |
| `PletherDOV.t.sol` | DOV vault | 75 |
| `SettlementOracle.t.sol` | Option settlement | 22 |
| `OptionToken.t.sol` | Option ERC20 | 19 |
| `PletherDOVIntegration.t.sol` | End-to-end DOV | 7 |

### Perps Tests (`packages/perps/test/perps/`)

Perps specification, accounting, matrix, differential, invariant, compatibility, and gas suites are package-owned.
Use the [`perps test map`](../packages/perps/test/perps/TEST_MAP.md) for exact critical-rule coverage, fixture limits,
profile commands, and replay instructions. RPC-dependent package forks run in a separate lane.

### Invariant Tests (`packages/*/test/**/*Invariant.t.sol`)

Stateful fuzz tests that verify protocol-wide invariants hold across arbitrary action sequences.

| File | Invariants |
|------|------------|
| `SyntheticSplitterInvariant.t.sol` | Solvency (USDC >= BEAR + BULL value), liquidation correctness |
| `InvarCoinInvariant.t.sol` | NAV backing, LP cost basis tracking |
| `LeverageRouterInvariant.t.sol` | BEAR + BULL debt/collateral ratios |
| `ZapRouterInvariant.t.sol` | No residual tokens after zap |
| `options/MarginEngineInvariant.t.sol` | Margin solvency across positions |

### Fork Tests (`test/fork/*.t.sol`)

Mainnet fork tests against real Curve, Morpho, and Chainlink deployments require `MAINNET_RPC_URL`.
The oracle synchronization and watermark suites additionally require `ARB_SEPOLIA_RPC_URL` with archive access.

Arbitrum tests using current local perps contracts install `ArbitrumForkSupport` at ArbSys (`0x64`) because Forge
1.5.1 does not implement that native precompile. The shim returns the fork's L2 block height and follows `vm.roll`;
a native-close regression verifies that same-L2-block execution remains pending. Real Pyth code, storage and signed
payloads are not replaced. `PerpsNativeArbSysFork.t.sol` separately executes the production block-number library
through read-only remote `eth_call` code overrides. It checks actual ArbSys L2 heights across adjacent blocks that
share one L1 ancestor. This covers the library's native execution domain; the full order lifecycle still runs in Forge.

Root perps tests fund LPs through request/epoch settlement/claim. `PerpsFork.t.sol` and the current-perps AA fixture
use a controllable Pyth mock; the synchronization, watermark, LP epoch and liquidation suites use deployed Pyth
with authentic signed data. The LP epoch case keeps a position open and checks rejected pre-boundary components,
rollback, successful settlement and both deposit/redemption claims. The AA case uses deployed EntryPoint and
SimpleAccount with the current paymaster and production Router for signed deposit/open/close/withdraw operations,
plus failed-batch rollback and nonce-safe retry. Its settlement token and Pyth are mocks.
Historical fills are constrained by the order's post-commit settlement window; they are not rejected merely because
the execution-time live mark is older than 60 seconds. Keeper gas is measured alongside actual payouts and illustrative
break-even gas prices, without the obsolete 550k limit or a profitability assertion based on mixed USD/USDC units.

These checks complement package unit and invariant suites; a green fork count does not establish complete
coverage. The perps fork fixtures isolate external boundaries; they do not run a public bundler/keeper service or
combine real USDC, signed Pyth, native ArbSys and EntryPoint in one public-chain transaction.

`PythRealUpdateFork.t.sol` is opt-in because it also needs a current Hermes update fixture. Fetch and load the fixture
before running that file:

```bash
set -a; source .env; set +a
# PYTH_API_KEY uses https://pyth.dourolabs.app/hermes; authenticated overrides are restricted to that service.
fixture=$(scripts/fetch-pyth-real-update-fixture.sh) && eval "$fixture"
forge test --match-path "test/fork/PythRealUpdateFork.t.sol" -vvv
```

| File | Coverage |
|------|----------|
| `InvarCoinFork.t.sol` | Real Curve LP deposit/withdraw/harvest |
| `InvarCoinGaugeFork.t.sol` | Curve gauge staking, rewards, and recovery paths |
| `InvarCoinManipulationFork.t.sol` | Flash loan and sandwich resistance |
| `CurveCalcAccuracyFork.t.sol` | Curve calc_token_amount vs actual |
| `LeverageRouterFork.t.sol` | BEAR + BULL leverage on real Morpho |
| `LiquidationFork.t.sol` | Morpho liquidation scenarios |
| `MorphoBorrowInvariantFork.t.sol` | Borrow invariants with real interest |
| `SlippageProtectionFork.t.sol` | Slippage guards against real pools |
| `SlippageReport.t.sol` | Slippage measurement across sizes |
| `RewardDistributorFork.t.sol` | Yield distribution with real swaps |
| `BasketOracleFork.t.sol` | Real Chainlink feeds + deviation checks |
| `PythRealUpdateFork.t.sol` | Opt-in validation against a freshly fetched Hermes update |
| `VaultAdapterFork.t.sol` | Real Morpho Vault integration |
| `VaultAdapterV1V2.t.sol` | Adapter compatibility across Morpho Vault versions |
| `ZapRouterFork.t.sol` | Zap against real Curve pool |
| `DeployToAdapterFork.t.sol` | Adapter deployment lifecycle |
| `FullCycleFork.t.sol` | End-to-end mint/stake/leverage/redeem |
| `YieldIntegrationFork.t.sol` | Yield accrual over time |
| `PermitFork.t.sol` | EIP-2612 permit on real USDC |
| `OptionsForkTest.t.sol` | DOV with real oracle settlement |
| `DOVZapRouterFork.t.sol` | Single-sided DOV entry against forked integrations |
| `PerpsFork.t.sol` | Perps deployment and external-oracle integration |
| `PerpsAccountAbstractionFork.t.sol` | Real EntryPoint and SimpleAccount execute current-perps trading and withdrawal; failed batch rollback/retry |
| `PerpsPoolEpochFork.t.sol` | Authentic signed feeds straddle an LP epoch with an open position, deposit and redemption claims |
| `PerpsLiquidationFork.t.sol` | Authentic signed prices drive healthy rejection and subsequent liquidation with custody reconciliation |
| `PerpsNativeArbSysFork.t.sol` | Production block-number library against remote native ArbSys across adjacent L2 blocks |

### Shared Utilities

- `packages/shared/test-support/` - Product-neutral test doubles exposed as `@plether/test-utils/`
- `packages/spot/test/{mocks,utils}/` - Spot-specific adapters, pools, and token doubles
- `packages/options/test/utils/` - Options-specific permit, splitter, and setup fixtures
- `packages/perps/test/` - Perps base fixtures, debug lens, and invariant handlers
- `test/fork/BaseForkTest.sol` - Root fork-test base with mainnet contract addresses

## Test Guidelines

See `CLAUDE.md` for the full set of test writing rules. Key principles:

- **Oracle tests must use basket != $1.00** to avoid masking BEAR/BULL formula bugs
- **No tautological assertions** (`assertGe(uint256, 0)` is always true)
- **No circular assertions** (don't mirror contract math to compute expected values)
- **Mocks must return realistic values** (zeros break dependent logic silently)
- **Never work around contract bugs in tests** (failing tests are signal)

## Security Test Coverage

| Vector | Test File(s) |
|--------|-------------|
| Reentrancy | `Reentrancy.t.sol` |
| Flash loan manipulation | `InvarCoinManipulationFork.t.sol`, `SecurityAttackVectors.t.sol` |
| Oracle staleness/sequencer | `OracleEdgeCases.t.sol`, `BasketOracleFork.t.sol` |
| MEV/sandwich | `ZapRouter.t.sol` (MEV + mutation suites), `SlippageProtectionFork.t.sol` |
| First-depositor inflation | `InvarCoin.t.sol`, `SyntheticSplitter.t.sol` |
| Curve liveness failures | `InvarCoin.t.sol` (emergency mode + bricked Curve tests) |
| Liquidation edge cases | `LiquidationFork.t.sol` |
| Interest accrual drift | `LeverageRouter.t.sol` (interest accrual suite) |

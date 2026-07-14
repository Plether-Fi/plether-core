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

# Fork tests (require MAINNET_RPC_URL in .env)
(source .env && forge test --match-path "test/fork/*" --fork-url $MAINNET_RPC_URL -vvv)

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

Perps unit, regression, fuzz, audit-history, and stateful invariant suites are fully package-owned. See the perps package
[`README.md`](../packages/perps/README.md) and [`PRE_AUDIT_GUIDE.md`](../packages/perps/PRE_AUDIT_GUIDE.md) for the suite map.

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

Mainnet fork tests against real Curve, Morpho, and Chainlink deployments. Require `MAINNET_RPC_URL` in `.env`.

| File | Coverage |
|------|----------|
| `InvarCoinFork.t.sol` | Real Curve LP deposit/withdraw/harvest |
| `InvarCoinManipulationFork.t.sol` | Flash loan and sandwich resistance |
| `CurveCalcAccuracyFork.t.sol` | Curve calc_token_amount vs actual |
| `LeverageRouterFork.t.sol` | BEAR + BULL leverage on real Morpho |
| `LiquidationFork.t.sol` | Morpho liquidation scenarios |
| `MorphoBorrowInvariantFork.t.sol` | Borrow invariants with real interest |
| `SlippageProtectionFork.t.sol` | Slippage guards against real pools |
| `SlippageReport.t.sol` | Slippage measurement across sizes |
| `RewardDistributorFork.t.sol` | Yield distribution with real swaps |
| `BasketOracleFork.t.sol` | Real Chainlink feeds + deviation checks |
| `VaultAdapterFork.t.sol` | Real Morpho Vault integration |
| `ZapRouterFork.t.sol` | Zap against real Curve pool |
| `DeployToAdapterFork.t.sol` | Adapter deployment lifecycle |
| `FullCycleFork.t.sol` | End-to-end mint/stake/leverage/redeem |
| `YieldIntegrationFork.t.sol` | Yield accrual over time |
| `PermitFork.t.sol` | EIP-2612 permit on real USDC |
| `OptionsForkTest.t.sol` | DOV with real oracle settlement |

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

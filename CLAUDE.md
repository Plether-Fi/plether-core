# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
forge build              # Compile contracts
forge test               # Run all tests
forge test -vvv          # Run tests with verbose output
forge test --match-test "test_FunctionName"  # Run single test
forge test --match-path "test/ZapRouter.t.sol"  # Run tests in specific file
forge fmt                # Format code
forge fmt --check        # Check formatting (CI enforced)
forge coverage           # Generate coverage report
forge snapshot --no-match-path "test/fork/*" --no-match-test "testFuzz_|invariant_"  # Update gas snapshot

# Fork tests (require MAINNET_RPC_URL in .env)
(source .env && forge test --match-path test/fork/MainnetForkTest.t.sol --fork-url $MAINNET_RPC_URL -vvv)
```

## Deployment Commands

```bash
# Sepolia testnet deployment (requires SEPOLIA_RPC_URL in .env)
(source .env && forge script script/DeployToSepolia.s.sol --tc DeployToSepolia --rpc-url $SEPOLIA_RPC_URL --broadcast)

# Dry run (simulation without broadcast)
(source .env && forge script script/DeployToSepolia.s.sol --tc DeployToSepolia --rpc-url $SEPOLIA_RPC_URL)

# Local Anvil deployment
SEPOLIA_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge script script/DeployToSepolia.s.sol --tc DeployToSepolia --rpc-url http://127.0.0.1:8545 --broadcast
```

**Anvil Deployment Note**: After deploying to local Anvil, always ask the user for a wallet address to fund with MockUSDC and ETH for testing.

## Architecture Overview

Plether is a DeFi protocol for synthetic dollar-denominated tokens with inverse and direct (bear/bull) exposure to the US Dollar Index (USDX).

### Core Contracts

**SyntheticSplitter** - Central protocol contract
- Accepts USDC collateral to mint equal amounts of plDXY-BEAR + plDXY-BULL
- Maintains 10% liquidity buffer locally, 90% deployed to yield adapters
- Three lifecycle states: ACTIVE → PAUSED → SETTLED
- Liquidates when oracle price >= CAP (protocol end-of-life)

**SyntheticToken** - ERC20 + ERC20FlashMint tokens
- plDXY-BEAR: appreciates when USD weakens / USDX falls
- plDXY-BULL: appreciates when USD strengthens / USDX rises
- Only SyntheticSplitter can mint/burn

### Staking Layer

**StakedToken** - Staked versions of plDXY-BEAR and plDXY-BULL (splDXY-BEAR, splDXY-BULL)
- Users stake plDXY tokens to receive staked tokens 1:1
- Staked tokens are used as collateral in Morpho lending pools
- Required for leverage positions (routers stake on behalf of users)
- May accrue staking rewards (protocol-specific incentives)

### Routing Layer

**ZapRouter** - Efficient plDXY-BULL acquisition using flash mints
- Flash mints plDXY-BEAR → swaps to USDC via Curve → mints pairs → keeps plDXY-BULL
- 1% max slippage cap for MEV protection

**LeverageRouter** - Leveraged plDXY-BEAR positions via Morpho Blue
- Flash loans USDC → swaps to plDXY-BEAR → stakes to splDXY-BEAR → deposits as Morpho collateral
- Morpho market uses splDXY-BEAR as collateral token
- Requires user authorization in Morpho (`isAuthorized`)

**BullLeverageRouter** - Leveraged plDXY-BULL positions via Morpho Blue
- Open: Flash loan USDC → mint pairs via Splitter → sell plDXY-BEAR on Curve → stake plDXY-BULL → deposit splDXY-BULL to Morpho
- Close: Single plDXY-BEAR flash mint for entire operation
- Close flow: Flash mint BEAR (collateral + extra for debt) → sell extra BEAR for USDC → repay debt → withdraw splDXY-BULL → unstake → redeem pairs → buy back BEAR
- Morpho market uses splDXY-BULL as collateral token
- Requires user authorization in Morpho (`isAuthorized`)

### Oracle Layer

**BasketOracle** - Computes plDXY as weighted basket of 6 Chainlink feeds (EUR, JPY, GBP, CAD, SEK, CHF)
- Returns the price of foreign currencies in USD (not the dollar index)
- When USD weakens → basket price UP → BEAR appreciates
- When USD strengthens → basket price DOWN → BULL appreciates
- **BEAR price = basket price** (direct correlation)
- **BULL price = CAP - basket price** (inverse correlation)

**MorphoOracle** - Adapts BasketOracle to Morpho's 1e36 scale format

**StakedOracle**: Wrapper that calculates `Price(Asset) * ExchangeRate` to price splDXY collateral for Morpho

### Yield Adapters (ERC4626)

**MorphoAdapter** - Morpho Blue wrapper for production yield
**MockYieldAdapter** - Testnet mock (no yield, used in tests)

## Key Patterns

- **Rounding**: Round UP for mint (favor protocol), DOWN for burn (favor user)
- **Decimals**: USDC=6, Tokens=18, Oracle=8, Morpho=36
- **Timelock**: 7 days for critical governance changes (adapter/treasury migration)
- **Oracle Safety**: 8-hour staleness timeout, sequencer uptime check on L2s
- **Flash Loans**: Routers implement IERC3156FlashBorrower with initiator/lender validation

## Test Structure

- `SyntheticSplitter*.t.sol` - Core protocol tests (unit, concurrent, fuzzy, invariant, preview)
- `ZapRouter.t.sol` / `LeverageRouter.t.sol` / `BullLeverageRouter.t.sol` - Router tests with MEV protection scenarios
- `MorphoAdapter.t.sol` - Adapter tests for Morpho Blue integration
- Mock contracts in `test/` files (MockToken, MockFlashLender, MockMorpho, MockSplitter, etc.)

**Test Guidelines**: Only write tests for application-specific logic. Do not add tests that verify library behavior (OpenZeppelin ERC20/ERC4626/Ownable/Pausable, Chainlink AggregatorV3Interface, etc.) - those are already tested by their maintainers.

## External Integrations

- **Chainlink**: AggregatorV3Interface for price feeds
- **Curve**: ICurvePool for USDC/plDXY-BEAR swaps (indices: USDC=0, plDXY-BEAR=1)
- **Morpho Blue**: IMorpho for lending with staked tokens (splDXY-BEAR, splDXY-BULL) as collateral, and yield via MorphoAdapter

## Git Workflow

Do not push or ask to push the git repo to origin. The user will handle pushes manually.

## Documentation Standards

Always keep documentation up to date and consistent when making code changes:
- **Natspec**: Update function/contract comments when behavior changes
- **README.md**: Update if architecture, usage, or setup instructions change
- **SECURITY.md**: Update if security model, trust assumptions, or risk factors change
- **Function references**: Verify any function names in docs exist in the actual contracts (use `grep -r "function funcName" src/`)

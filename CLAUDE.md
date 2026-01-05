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

# Fork tests (require MAINNET_RPC_URL in .env)
(source .env && forge test --match-path test/fork/MainnetForkTest.t.sol --fork-url $MAINNET_RPC_URL -vvv)
```

## Architecture Overview

Plether is a DeFi protocol for synthetic dollar-denominated tokens with inverse (bull/bear) exposure to the US Dollar Index (DXY).

### Core Contracts

**SyntheticSplitter** - Central protocol contract
- Accepts USDC collateral to mint equal amounts of DXY-BEAR + DXY-BULL
- Maintains 10% liquidity buffer locally, 90% deployed to yield adapters
- Three lifecycle states: ACTIVE → PAUSED → SETTLED
- Liquidates when oracle price >= CAP (protocol end-of-life)

**SyntheticToken** - ERC20 + ERC20FlashMint tokens
- DXY-BEAR: appreciates when USD weakens / DXY falls
- DXY-BULL: appreciates when USD strengthens / DXY rises
- Only SyntheticSplitter can mint/burn

### Staking Layer

**StakedToken** - Staked versions of DXY-BEAR and DXY-BULL (sDXY-BEAR, sDXY-BULL)
- Users stake DXY tokens to receive staked tokens 1:1
- Staked tokens are used as collateral in Morpho lending pools
- Required for leverage positions (routers stake on behalf of users)
- May accrue staking rewards (protocol-specific incentives)

### Routing Layer

**ZapRouter** - Efficient DXY-BULL acquisition using flash mints
- Flash mints DXY-BEAR → swaps to USDC via Curve → mints pairs → keeps DXY-BULL
- 1% max slippage cap for MEV protection

**LeverageRouter** - Leveraged DXY-BEAR positions via Morpho Blue
- Flash loans USDC → swaps to DXY-BEAR → stakes to sDXY-BEAR → deposits as Morpho collateral
- Morpho market uses sDXY-BEAR as collateral token
- Requires user authorization in Morpho (`isAuthorized`)

**BullLeverageRouter** - Leveraged DXY-BULL positions via Morpho Blue
- Open: Flash loan USDC → mint pairs via Splitter → sell DXY-BEAR on Curve → stake DXY-BULL → deposit sDXY-BULL to Morpho
- Close: Single DXY-BEAR flash mint for entire operation
- Close flow: Flash mint BEAR (collateral + extra for debt) → sell extra BEAR for USDC → repay debt → withdraw sDXY-BULL → unstake → redeem pairs → buy back BEAR
- Morpho market uses sDXY-BULL as collateral token
- Requires user authorization in Morpho (`isAuthorized`)

### Oracle Layer

**BasketOracle** - Computes DXY as weighted basket of 6 Chainlink feeds (EUR, JPY, GBP, CAD, SEK, CHF)

**MorphoOracle** - Adapts BasketOracle to Morpho's 1e36 scale format

**StakedOracle**: Wrapper that calculates `Price(Asset) * ExchangeRate` to price sDXY collateral for Morpho

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

## External Integrations

- **Chainlink**: AggregatorV3Interface for price feeds
- **Curve**: ICurvePool for USDC/DXY-BEAR swaps (indices: USDC=0, DXY-BEAR=1)
- **Morpho Blue**: IMorpho for lending with staked tokens (sDXY-BEAR, sDXY-BULL) as collateral, and yield via MorphoAdapter

## Git Workflow

Do not push or ask to push the git repo to origin. The user will handle pushes manually.

## Documentation Standards

Always keep documentation up to date and consistent when making code changes:
- **Natspec**: Update function/contract comments when behavior changes
- **README.md**: Update if architecture, usage, or setup instructions change
- **SECURITY.md**: Update if security model, trust assumptions, or risk factors change

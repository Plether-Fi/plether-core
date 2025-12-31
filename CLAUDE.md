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
```

## Architecture Overview

Plether is a DeFi protocol for synthetic dollar-denominated tokens with inverse (bull/bear) exposure to the US Dollar Index (DXY).

### Core Contracts

**SyntheticSplitter** - Central protocol contract
- Accepts USDC collateral to mint equal amounts of TOKEN_A (mDXY/bear) + TOKEN_B (mInvDXY/bull)
- Maintains 10% liquidity buffer locally, 90% deployed to yield adapters
- Three lifecycle states: ACTIVE → PAUSED → SETTLED
- Liquidates when oracle price >= CAP (protocol end-of-life)

**SyntheticToken** - ERC20 + ERC20FlashMint tokens
- mDXY (bear): appreciates when DXY falls
- mInvDXY (bull): appreciates when DXY rises
- Only SyntheticSplitter can mint/burn

### Routing Layer

**ZapRouter** - Efficient bull token acquisition using flash mints
- Flash mints mDXY → swaps to USDC via Curve → mints pairs → keeps mInvDXY
- 1% max slippage cap for MEV protection

**LeverageRouter** - Leveraged positions via Morpho Blue
- Flash loans USDC → swaps to mDXY → deposits as Morpho collateral
- Requires user authorization in Morpho (`isAuthorized`)

### Oracle Layer

**BasketOracle** - Computes DXY as weighted basket of 6 Chainlink feeds (EUR, JPY, GBP, CAD, SEK, CHF)

**MorphoOracle** - Adapts BasketOracle to Morpho's 1e36 scale format

### Yield Adapters (ERC4626)

**YieldAdapter** - Aave V3 wrapper with CAPO donation attack protection
**MorphoAdapter** - Morpho Blue wrapper
**MockYieldAdapter** - Testnet mock (no yield)

## Key Patterns

- **Rounding**: Round UP for mint (favor protocol), DOWN for burn (favor user)
- **Decimals**: USDC=6, Tokens=18, Oracle=8, Morpho=36
- **Timelock**: 7 days for critical governance changes (adapter/treasury migration)
- **Oracle Safety**: 8-hour staleness timeout, sequencer uptime check on L2s
- **Flash Loans**: Routers implement IERC3156FlashBorrower with initiator/lender validation

## Test Structure

- `SyntheticSplitter*.t.sol` - Core protocol tests (unit, concurrent, fuzzy, invariant, preview)
- `ZapRouter.t.sol` / `LeverageRouter.t.sol` - Router tests with MEV protection scenarios
- `YieldAdapter.t.sol` / `MorphoAdapter.t.sol` - Adapter tests with CAPO mechanism
- Mock contracts in `test/` files (MockToken, MockFlashLender, MockMorpho, etc.)

## External Integrations

- **Chainlink**: AggregatorV3Interface for price feeds
- **Curve**: ICurvePool for USDC/mDXY (bear) swaps (indices: USDC=0, mDXY=1)
- **Morpho Blue**: IMorpho for lending/collateral
- **Aave V3**: IAavePool for yield farming

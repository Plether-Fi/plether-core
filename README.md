# Plether Protocol

[![CI](https://github.com/Plether-Fi/plether-core/actions/workflows/ci.yml/badge.svg)](https://github.com/Plether-Fi/plether-core/actions/workflows/ci.yml)
[![Coverage](https://codecov.io/gh/Plether-Fi/plether-core/branch/master/graph/badge.svg)](https://codecov.io/gh/Plether-Fi/plether-core)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.33-363636?logo=solidity)](https://docs.soliditylang.org/)

Plether is a DeFi protocol for synthetic dollar-denominated tokens with inverse exposure to the US Dollar Index (DXY). Users deposit USDC to mint paired tokens that track USD strength, enabling speculation and hedging on dollar movements.

## How It Works

The protocol creates two synthetic tokens from USDC collateral:

- **DXY-BEAR** - Appreciates when USD weakens (DXY falls)
- **DXY-BULL** - Appreciates when USD strengthens (DXY rises)

These tokens are always minted and burned in pairs, maintaining a zero-sum relationship. When you deposit 100 USDC, you receive equal amounts of both tokens. The combined value of a BEAR + BULL pair always equals the original USDC deposit.

```
User deposits USDC
        │
        ▼
┌───────────────────┐
│ SyntheticSplitter │
└───────────────────┘
        │
        ├──► DXY-BEAR (gains when USD weakens)
        │
        └──► DXY-BULL (gains when USD strengthens)
```

## Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| [`SyntheticSplitter`](src/SyntheticSplitter.sol) | Central protocol contract. Accepts USDC, mints/burns token pairs, manages yield deployment |
| [`SyntheticToken`](src/SyntheticToken.sol) | ERC20 + ERC20FlashMint implementation for DXY-BEAR and DXY-BULL |
| [`StakedToken`](src/StakedToken.sol) | ERC-4626 vault wrapper enabling yield accrual on deposited tokens |

### Oracle Layer

| Contract | Description |
|----------|-------------|
| [`BasketOracle`](src/oracles/BasketOracle.sol) | Computes DXY as weighted basket of 6 Chainlink feeds (EUR, JPY, GBP, CAD, SEK, CHF) |
| [`MorphoOracle`](src/oracles/MorphoOracle.sol) | Adapts BasketOracle to Morpho Blue's 36-decimal scale format |
| [`StakedOracle`](src/oracles/StakedOracle.sol) | Wraps underlying oracle to price ERC-4626 staked token shares |

### Routing Layer

| Contract | Description |
|----------|-------------|
| [`ZapRouter`](src/ZapRouter.sol) | Efficient single-sided DXY-BULL acquisition using flash mints |
| [`LeverageRouter`](src/LeverageRouter.sol) | Leveraged DXY-BEAR positions via Morpho Blue + flash loans |
| [`BullLeverageRouter`](src/BullLeverageRouter.sol) | Leveraged DXY-BULL positions via Morpho Blue + nested flash loans |

### Yield Adapters (ERC-4626)

| Contract | Description |
|----------|-------------|
| [`YieldAdapter`](src/YieldAdapter.sol) | Aave V3 wrapper with CAPO donation attack protection |
| [`MorphoAdapter`](src/MorphoAdapter.sol) | Morpho Blue wrapper for yield generation |

## Ecosystem Integrations

```
                    ┌─────────────┐
                    │  Chainlink  │
                    │   Oracles   │
                    └──────┬──────┘
                           │ Price Feeds
                           ▼
┌─────────┐    USDC    ┌───────────────────┐    Yield    ┌───────────┐
│  Users  │◄─────────►│      Plether      │◄──────────►│  Aave V3  │
└─────────┘            │   (Splitter +     │             └───────────┘
     │                 │    Routers)       │
     │                 └─────────┬─────────┘             ┌───────────┐
     │                           │                  ────►│  Morpho   │
     │                           │          Lending      │   Blue    │
     │                           ▼                       └───────────┘
     │                 ┌─────────────────┐
     └────────────────►│   Curve AMM     │
        Swap Tokens    │  (USDC/BEAR)    │
                       └─────────────────┘
```

- **Chainlink** - Price feeds for EUR/USD, JPY/USD, GBP/USD, CAD/USD, SEK/USD, CHF/USD
- **Curve Finance** - AMM pools for USDC/DXY-BEAR swaps
- **Morpho Blue** - Lending markets for leveraged positions (DXY-BEAR and DXY-BULL as collateral)
- **Aave V3** - Yield generation on idle USDC reserves

## Protocol Mechanics

### Liquidity Management

The SyntheticSplitter maintains a 10% local buffer of USDC for redemptions, with 90% deployed to yield adapters. This generates yield while ensuring liquidity for normal operations.

### Leverage

Users can open leveraged positions through the routers:

1. **LeverageRouter** (Bear): Flash loan USDC → Swap to DXY-BEAR → Stake → Deposit to Morpho as collateral → Borrow USDC to repay flash loan
2. **BullLeverageRouter** (Bull): Flash loan USDC → Mint pairs → Sell DXY-BEAR → Stake DXY-BULL → Deposit to Morpho → Borrow to repay

Both routers include MEV protection via user-defined slippage caps (max 1%).

### Lifecycle States

The protocol operates in three states:

1. **ACTIVE** - Normal operations (mint, burn, redeem)
2. **PAUSED** - Emergency pause (only admin functions)
3. **SETTLED** - End-of-life when DXY hits CAP price (only redemptions allowed)

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge build
```

### Test

```bash
forge test              # Run all tests
forge test -vvv         # Verbose output
forge coverage          # Generate coverage report
```

### Format

```bash
forge fmt               # Format code
forge fmt --check       # Check formatting
```

## Security

- All contracts use OpenZeppelin's battle-tested implementations
- Reentrancy protection on state-changing functions
- 7-day timelock for critical governance changes
- Oracle staleness checks (8-hour timeout)
- Flash loan callback validation (initiator + lender checks)
- CAPO mechanism protects yield adapters from donation attacks

## License

[AGPL-3.0](LICENSE)

## Disclaimer

This software is provided "as is" without warranty of any kind. Use at your own risk. This protocol has not been audited. Do not use in production without a professional security audit.

# Deployment Guide

This document provides the complete deployment procedure for the Plether protocol on Ethereum mainnet.

## Prerequisites

### Required Accounts & Keys
- [ ] Deployer wallet with sufficient ETH for gas (~0.5 ETH recommended)
- [ ] Treasury multisig address configured
- [ ] Staking rewards address configured

### External Dependencies
- [ ] USDC contract address verified: `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
- [ ] Chainlink feed addresses verified (see below)
- [ ] Morpho Blue address verified: `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`
- [ ] Aave V3 Pool address verified: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`
- [ ] Curve pool deployed and address recorded

### Chainlink Price Feeds (Mainnet)
| Feed | Address | Decimals |
|------|---------|----------|
| EUR/USD | `0xb49f677943BC038e9857d61E7d053CaA2C1734C1` | 8 |
| JPY/USD | `0xBcE206caE7f0ec07b545EddE332A47C2F75bbeb3` | 8 |
| GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` | 8 |
| CAD/USD | `0xa34317DB73e77d453b1B8d04550c44D10e981C8e` | 8 |
| SEK/USD | `0x803a123F84E77A13C69459F0C8952d7d5a6f1B8c` | 8 |
| CHF/USD | `0x449d117117838fFA61263B61dA6301AA2a88B13A` | 8 |

## Pre-Deployment Checklist

### Code Review
- [ ] All tests pass: `forge test`
- [ ] No compiler warnings in production code
- [ ] Code formatted: `forge fmt --check`
- [ ] Coverage report reviewed: `forge coverage`

### Security Review
- [ ] Reentrancy guards present on all routers
- [ ] Pausable functionality tested
- [ ] Constructor validations in place
- [ ] No hardcoded test addresses in production code

### Configuration Review
- [ ] CAP set correctly: `2 * 10**8` ($2.00)
- [ ] LLTV values appropriate: `0.77e18` (77%)
- [ ] Buffer ratio: 10% local, 90% adapter
- [ ] Timelock duration: 7 days

## Deployment Sequence

### Step 1: Deploy BasketOracle
```bash
# Verify Chainlink feeds are responding
cast call 0xb49f677943BC038e9857d61E7d053CaA2C1734C1 "latestRoundData()" --rpc-url $RPC_URL
```

**Deployment:**
```solidity
BasketOracle basketOracle = new BasketOracle(feeds, quantities, curvePool, maxDeviationBps);
```

**Verification:**
- [ ] `latestRoundData()` returns valid price
- [ ] Price within expected range ($0.90 - $1.40)

### Step 2: Deploy MorphoAdapter
```solidity
// Predict Splitter address first
address predictedSplitter = computeCreateAddress(deployer, nonce + 1);
MorphoAdapter adapter = new MorphoAdapter(USDC, MORPHO_BLUE, marketParams, owner, predictedSplitter);
```

**Verification:**
- [ ] `SPLITTER()` returns predicted address
- [ ] `asset()` returns USDC address

### Step 3: Deploy SyntheticSplitter
```solidity
SyntheticSplitter splitter = new SyntheticSplitter(
    basketOracle,
    USDC,
    adapter,
    CAP,
    treasury,
    address(0) // No sequencer feed on L1
);
```

**Verification:**
- [ ] `address(splitter) == predictedSplitter`
- [ ] `TOKEN_A()` returns plDXY-BEAR address
- [ ] `TOKEN_B()` returns plDXY-BULL address
- [ ] `CAP()` returns correct value
- [ ] `paused()` returns false
- [ ] `isLiquidated()` returns false

### Step 4: Deploy Morpho Oracles
```solidity
MorphoOracle morphoOracleBear = new MorphoOracle(basketOracle, CAP, false);
MorphoOracle morphoOracleBull = new MorphoOracle(basketOracle, CAP, true);
```

**Verification:**
- [ ] `price()` returns non-zero value for both
- [ ] BEAR price + BULL price ≈ 2 * 10^36 (scaled CAP)

### Step 5: Deploy Staked Tokens
```solidity
StakedToken stakedBear = new StakedToken(PLDXY_BEAR, "Staked plDXY-BEAR", "splDXY-BEAR");
StakedToken stakedBull = new StakedToken(PLDXY_BULL, "Staked plDXY-BULL", "splDXY-BULL");
```

**Verification:**
- [ ] `asset()` returns correct underlying token
- [ ] `decimals()` returns 18

### Step 6: Deploy Staked Oracles
```solidity
StakedOracle stakedOracleBear = new StakedOracle(stakedBear, morphoOracleBear);
StakedOracle stakedOracleBull = new StakedOracle(stakedBull, morphoOracleBull);
```

**Verification:**
- [ ] `price()` returns non-zero value

### Step 7: Deploy ZapRouter
```solidity
ZapRouter zapRouter = new ZapRouter(splitter, PLDXY_BEAR, PLDXY_BULL, USDC, curvePool);
```

**Verification:**
- [ ] `CAP()` matches Splitter CAP
- [ ] `SPLITTER()` returns correct address

### Step 8: Deploy LeverageRouter
```solidity
LeverageRouter leverageRouter = new LeverageRouter(
    MORPHO_BLUE,
    curvePool,
    USDC,
    PLDXY_BEAR,
    stakedBear,
    AAVE_POOL,
    bearMarketParams
);
```

**Verification:**
- [ ] Constructor params stored correctly

### Step 9: Deploy BullLeverageRouter
```solidity
BullLeverageRouter bullLeverageRouter = new BullLeverageRouter(
    MORPHO_BLUE,
    splitter,
    curvePool,
    USDC,
    PLDXY_BEAR,
    PLDXY_BULL,
    stakedBull,
    AAVE_POOL,
    bullMarketParams
);
```

**Verification:**
- [ ] Constructor params stored correctly

## Post-Deployment Checklist

### Functional Verification
- [ ] Test mint with small amount (~$10 USDC)
- [ ] Test burn with minted tokens
- [ ] Verify token balances correct
- [ ] Test ZapRouter `zapMint()` if Curve pool has liquidity

### Oracle Verification
- [ ] BasketOracle price within expected bounds
- [ ] MorphoOracle prices consistent
- [ ] StakedOracle prices equal underlying (no deposits yet)

### Access Control Verification
- [ ] Splitter owner is correct address
- [ ] Router owners are correct addresses
- [ ] Token SPLITTER references correct

### External Integration Verification
- [ ] Morpho market created (if not existing)
- [ ] Curve pool has initial liquidity
- [ ] Aave flash loans available

## Deployment Script Usage

### Environment Setup
```bash
export PRIVATE_KEY=your_private_key
export RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
export ETHERSCAN_API_KEY=your_etherscan_key
export TREASURY=0x...
```

### Run Deployment
```bash
# Dry run (simulation)
forge script script/DeployToMainnet.s.sol --rpc-url $RPC_URL

# Actual deployment
forge script script/DeployToMainnet.s.sol --rpc-url $RPC_URL --broadcast --verify

# If verification fails, verify manually
forge verify-contract <ADDRESS> <CONTRACT> --chain mainnet
```

### Run Verification Script
```bash
# Update addresses in VerifyDeployment.s.sol first
forge script script/VerifyDeployment.s.sol --rpc-url $RPC_URL
```

## Post-Deployment Operations

### Transfer Ownership to Multisig
```bash
# For each contract
cast send <CONTRACT> "transferOwnership(address)" <MULTISIG> --private-key $PRIVATE_KEY
```

### Create Morpho Markets (if needed)
Markets must exist on Morpho Blue for:
1. USDC/splDXY-BEAR (for LeverageRouter)
2. USDC/splDXY-BULL (for BullLeverageRouter)

### Seed Curve Pool
Initial liquidity required for:
- USDC (one side)
- plDXY-BEAR (other side)

## Rollback Procedure

If critical issues discovered post-deployment:

1. **Pause all contracts immediately**
   ```bash
   cast send <SPLITTER> "pause()" --private-key $PRIVATE_KEY
   cast send <ZAP_ROUTER> "pause()" --private-key $PRIVATE_KEY
   cast send <LEVERAGE_ROUTER> "pause()" --private-key $PRIVATE_KEY
   cast send <BULL_LEVERAGE_ROUTER> "pause()" --private-key $PRIVATE_KEY
   ```

2. **Communicate to users**
   - Announce pause on all channels
   - Explain issue and timeline

3. **Assess and fix**
   - Determine if upgrade possible
   - If not, plan migration strategy

4. **Resume or migrate**
   - Unpause if fixed
   - Or deploy new contracts and assist user migration

## Contract Addresses (Post-Deployment)

Update this section after deployment:

| Contract | Address | Verified |
|----------|---------|----------|
| BasketOracle | `0x...` | [ ] |
| MorphoAdapter | `0x...` | [ ] |
| SyntheticSplitter | `0x...` | [ ] |
| plDXY-BEAR | `0x...` | [ ] |
| plDXY-BULL | `0x...` | [ ] |
| MorphoOracle (BEAR) | `0x...` | [ ] |
| MorphoOracle (BULL) | `0x...` | [ ] |
| StakedToken (BEAR) | `0x...` | [ ] |
| StakedToken (BULL) | `0x...` | [ ] |
| StakedOracle (BEAR) | `0x...` | [ ] |
| StakedOracle (BULL) | `0x...` | [ ] |
| ZapRouter | `0x...` | [ ] |
| LeverageRouter | `0x...` | [ ] |
| BullLeverageRouter | `0x...` | [ ] |

## Changelog

| Date | Change |
|------|--------|
| 2025-01-03 | Initial deployment guide |

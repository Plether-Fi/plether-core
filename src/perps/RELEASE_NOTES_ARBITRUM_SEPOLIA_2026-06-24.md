# Arbitrum Sepolia Perps Release Notes - 2026-06-24

## Summary

This release deploys the Plether perps stack to Arbitrum Sepolia with DXY-oriented risk defaults, stricter
Pyth confidence filtering, and larger bootstrap liquidity for testnet exercise.

The stack is deployed, wired, verified on Arbiscan, bootstrapped, and trading is active.

## Network

| Field | Value |
| --- | --- |
| Network | Arbitrum Sepolia |
| Chain id | `421614` |
| Source commit | `a2af579` |
| Deployer | `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B` |
| Pyth | `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF` |

## Deployed Contracts

| Contract | Address |
| --- | --- |
| `MockUSDC` | `0xf1e1B188b87525C51ECe4bae8627ae621D769651` |
| `MarginClearinghouse` | `0x731bb0939CE531728459394A277B28Cbff8df049` |
| `CfdEngine` | `0xA1Ebfb8aD9C90367eA30A29592419d447E3f8224` |
| `CfdEnginePlanner` | `0x7dDC8AdF27456A71e02e517E28a975832D49d195` |
| `CfdEngineSettlementSidecar` | `0x78C79E81fF5221DCdfB6B384A86990bffAFd4D6b` |
| `CfdEngineAdmin` | `0x03957FACB0d371f170737fa0252CDC1088bba78A` |
| `HousePool` | `0x793dAbc20Ab0eCEb0AD8060b1fb307212C9EB6df` |
| `SeniorVault` | `0x352F2C0Ad6e0Db6EbC3fBE7738857a804327f53b` |
| `JuniorVault` | `0x783daF5eC664932764a59Ae387C3eAbD6cC61A74` |
| `CfdEngineAccountLens` | `0xb46f7ECAE1E7D3BC8ebC7FB1cda20d2d9a83cC29` |
| `CfdEngineLens` | `0xB7F0A32EfD67193782171Efc60D5D13A44bd5177` |
| `PletherOracle` | `0x8c95f554D728215b9f8D15b5F3Da5F5CD7Ba08bA` |
| `OrderRouter` | `0x4A0a6c028164A1254e10C3e39cc89Af45090069e` |
| `OrderRouterAdmin` | `0xf11858573eE79EF64e38e47572785D67cE7641Ec` |
| `PerpsPublicLens` | `0xDdDCfb123569774427802fcA9D19CBF00c14e2Ad` |

## Configuration

| Parameter | Release value | Rationale |
| --- | --- | --- |
| `vpiFactor` | `0.005e18` | Keeps skew-sensitive virtual price impact enabled without making testnet opens overly punitive. |
| `frozenCloseVpiFactor` | `0.005e18` | Keeps frozen-oracle close/reduce execution aligned with the live VPI factor and satisfies the nonzero safety bound. |
| `maxSkewRatio` | `0.4e18` | Allows meaningful directional imbalance for testing while retaining a clear skew cap. |
| `maintMarginBps` | `30` | Low maintenance margin is acceptable for testnet and matches the lower-volatility character of a DXY-style FX basket. |
| `initMarginBps` | `45` | Enables high-leverage position-open testing; max initial-margin leverage is about `222.22x` before fees and other protocol limits. |
| `fadMarginBps` | `300` | Keeps the FAD margin buffer materially stricter than normal trading. |
| `baseCarryBps` | `500` | Preserves the existing carry baseline for skew/carry behavior testing. |
| `minBountyUsdc` | `1e6` | Keeps the minimum liquidation bounty at `1` mock USDC. |
| `bountyBps` | `10` | Preserves the proportional bounty setting for liquidation incentive coverage. |
| `executionFeeBps` | `4` | Unchanged protocol execution fee. |
| `fadRunwaySeconds` | `1 hours` | Provides a short close-only runway before configured FAD days without over-constraining testnet order flow. |
| `pythMaxConfidenceRatioBps` | `10` | Rejects component feeds whose Pyth confidence exceeds `0.10%` of price; appropriate because major FX feeds should usually be tight. |
| Senior seed | `50_000_000e6` | Provides deep senior-side mock liquidity for integration and stress testing. |
| Junior seed | `50_000_000e6` | Provides symmetric junior-side mock liquidity and keeps pool accounting balanced at launch. |

## Oracle Notes

`pythMaxConfidenceRatioBps = 10` means the oracle accepts a component price only when:

```text
confidence / price <= 0.10%
```

Pyth confidence is an uncertainty band, not a confidence score. Larger confidence values mean less precise prices, so
larger values are more likely to be rejected.

## Bootstrap Status

| Check | Value |
| --- | --- |
| `seniorSeedInitialized` | `true` |
| `juniorSeedInitialized` | `true` |
| `isTradingActive` | `true` |
| Senior vault assets after bootstrap | `50,000,002.663622` mock USDC |
| Junior vault assets after bootstrap | `49,999,997.209539` mock USDC |
| HousePool mock USDC balance | `100,000,000` mock USDC |

## Operational Notes

- All contracts in the final stack were verified on Arbitrum Sepolia Arbiscan.
- The final usable `PerpsPublicLens` is `0xDdDCfb123569774427802fcA9D19CBF00c14e2Ad`.
- Earlier partial deployment attempts left incomplete contracts on-chain; use only the addresses in this release note for
  integration testing.
- Test wallets still need Arbitrum Sepolia ETH for gas. The bootstrap only minted and deposited mock USDC liquidity.

# Perps v2.1.0 — Arbitrum Sepolia

USDG-settled Perps release with tuned v2.1.0 margin, oracle confidence, order execution, bounty, and FAD window parameters. Trading is active.

- Source: `d5ef9725f72f5e131272da27004266d8a3d51e50`. Solidity 0.8.39, optimizer 200, via-IR, Prague, Forge `1.5.1-stable`.
- Owner, treasury, guardian, and both permanent seed recipients: `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`.
- Permanent seeds: 1 USDG per vault. Junior maintenance fee: 0 bps.
- Key v2.1.0 parameter updates: `initMarginBps = 30` (333x), `fadMarginBps = 200` (50x), `FAD_LEAD = 10m` / `FAD_LAG = 5m`, `fadRunwaySeconds = 600s`, `minOpenSlippageToleranceBps = 25`, `basketMaxConfidenceRatioBps = 25`, `adverseConfidenceMultiplierBps = 2500`, `minOrderSettlementDelay = 2s`, `maxExecutionWindowSeconds = 30s`, `maxOpenOrderExecutionBountyAssets = 250_000` (0.25 USDG), `positionProtectionTriggerBountyAssets = 250_000` (0.25 USDG).
- All 31 contracts have verified source on Arbiscan (exact matches).
- [HousePool](https://sepolia.arbiscan.io/address/0x23735f88637cbf329ca1c4f49b96953d25a24b4a#code) · [OrderRouter](https://sepolia.arbiscan.io/address/0xb4c7548ba764e22107964637e31558af724c1c3e#code) · [CfdEngine](https://sepolia.arbiscan.io/address/0xa3c43242f4e0a7c9a21bd7de48376d2f0779caa6#code) · [MockUSDG](https://sepolia.arbiscan.io/address/0x66705f56f2c88c9474d021d9c6afe134205a63ce#code)
- [Addresses, configuration, and transaction hashes](manifest.json) · [Public script environment](addresses.env)

Liquidity: Junior 1,000,000 USDG is queued for epoch `498833` (2026-11-27 17:00 UTC / 18:00 CET). After it settles, Senior 1,000,000 USDG can be requested for the next hourly epoch.

Preflight dry run, deployed, seeded, and active on-chain verification phases all passed. Existing historical deployment records and consumers are unchanged.

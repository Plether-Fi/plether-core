# Perps v2.0.0 — Arbitrum Sepolia

First release with USDG settlement (six-decimal Mock USDG on testnet). Trading is active.

- Source: `1209ca8a5b94a4fb6323c7c4585846ed93db3932`. Solidity 0.8.35, optimizer 200, via-IR, Prague.
- Owner, treasury, guardian, and both permanent seed recipients: `0x5a71a4094Ec81165Ada48AA4c27dA48ec27E0d6B`.
- Permanent seeds: 1 USDG per vault. Junior maintenance fee: 0 bps.
- All 30 contracts have verified source on Arbiscan: 29 exact matches; redemption math sidecar is an existing Similar Match.
- [HousePool](https://sepolia.arbiscan.io/address/0xeb5604c393843b2f3c347ec24fa9ddad6ab2131e#code) · [OrderRouter](https://sepolia.arbiscan.io/address/0x918663d6da8cb33b325a04c4a5e8c51d42f3b444#code)
- [Addresses, configuration, and transaction hashes](manifest.json) · [Public script environment](addresses.env)

Liquidity: Junior 1,000,000 USDG is queued for 2026-10-28 12:00 UTC (13:00 Warsaw). After it settles, Senior 1,000,000 USDG can be requested for the next hourly epoch. Pending deposits are not yet pool liquidity.

No additional tests were run, as requested. Existing USDC deployment records and consumers are unchanged.

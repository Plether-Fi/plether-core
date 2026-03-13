# Security Audit Fix Implementation

## Priority Order (from audit)

- [x] **H-1**: DOV emergency withdrawal after Splitter liquidation
- [x] **H-2**: Snapshot share rate at mint time (eliminates manipulation window)
- [x] **M-1**: Time-limited reclaim for unclaimed exercise shares (90-day sweep)
- [x] **M-2**: Atomic settle+unlock in `settleEpoch()`
- [x] **M-3**: Early cancel on liquidation in `cancelAuction()`
- [x] **M-4**: Direction-aware price validation in `adminSettle()`
- [x] **M-5**: Explicit epoch ordering enforcement in `startEpochAuction()`
- [x] **L-1**: Disable initialization of OptionToken implementation
- [x] **L-2**: Reject `strike = 0` in `createSeries`
- [x] **L-3**: Zero-address check in `OptionToken.mint()`
- [x] **I-1**: Event on `OptionToken.initialize()`
- [x] **I-2**: (skipped — silent success is acceptable idempotent behavior per audit)
- [x] Tests for all fixes

## Test Results: 125/125 pass (was 102)

## InvarCoin P0/P1 Remediation (Mar 13 2026)

- [x] Preserve pro-rata LP claims in emergency mode by keeping LP accounting intact until assets are actually recovered
- [x] Require balanced LP redemption in `lpWithdraw()` even during emergency mode
- [x] Harden gauge onboarding with explicit approval + LP token validation
- [x] Replace persistent gauge approvals with exact-per-call approvals
- [x] Update unit and fork tests for new emergency/gauge behavior

### Verification
- `forge test --match-path test/InvarCoin.t.sol`
- `forge test --match-path test/fork/InvarCoinGaugeFork.t.sol`

## InvarCoin P1/P2 Hardening (Mar 13 2026)

- [x] Replace direct `stakedInvarCoin` setter with validated propose/finalize timelock flow
- [x] Validate staking vault code exists and `asset() == INVAR`
- [x] Add timelocked `gaugeRewardsReceiver` configuration
- [x] Add protected reward token sweep path and block arbitrary rescue of protected rewards
- [x] Update scripts and tests for the new integration flow

### Verification
- `forge test --match-path test/InvarCoin.t.sol`
- `forge test --match-path test/fork/InvarCoinGaugeFork.t.sol`
- `forge build`

---

## PletherDOV Completion (pre-audit)

### Missing Features
- [x] **USDC → splDXY zap** — Extracted to `DOVZapRouter`. Coordinates BEAR+BULL DOVs: matched minting via Splitter (zero slippage), excess via Curve/flash. PletherDOV gains `zapKeeper` role + `releaseUsdcForZap()`.
- [ ] **Vault share accounting** — ERC20 inherited but `_mint()` never called. Depositors need shares on deposit, redemption mechanism after epoch settles. Decide: ERC4626 with epoch-locked withdrawals vs simpler pro-rata queue.

### Decisions Required
- [ ] Include PletherDOV in audit scope or defer to second audit? (MarginEngine/SettlementOracle/OptionToken are audit-ready independently)
- [x] Zap strategy for USDC → splDXY conversion (DOVZapRouter with coordinated minting)
- [ ] Vault share model (ERC4626 vs custom pro-rata)

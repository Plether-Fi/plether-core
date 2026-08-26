# Arbitrum Sepolia Perps Release Notes - 2026-08-26

## Release intent

This release prepares a fresh, parallel Perps stack on Arbitrum Sepolia. It does not mutate earlier Perps deployments
or Spot, and repository preparation performs no broadcast. The source tree must be the reviewed, clean
`origin/master` commit recorded in the deployment manifest.

## Approved economics

| Setting | Release value |
| --- | --- |
| Initial / maintenance margin | `20` / `10` bps |
| Liquidation charge | `10` bps |
| Minimum liquidation charge | `$1` (`1e6` USDC units) |
| Minimum keeper payout | `$0.50`, from the unchanged `50%` keeper split |
| Minimum opening notional | `$1,000` |
| VPI / maximum skew | `0.01e18` / `0.4e18` |
| Basket confidence / adverse multiplier | `10` / `2,500` bps |
| FAD / base carry / execution fee | `300` / `500` / `4` bps |
| Frozen-close spread | `50` bps |
| Pending-order limit | `5` |
| Initial liquidity | `$10M` Senior + `$10M` Junior |
| Senior limits | `$40M` exposure / `80%` share |
| Junior maintenance fee | `100` bps nominal APR |
| Junior fee recipient | deployment-time snapshot of `CfdEngine.protocolTreasury()` |

## Deployment and bootstrap changes

- The release uses upgraded Pyth at `0x0B73614636C855Bf23F342F307FB981A3e47f42B` and the authenticated
  `https://pyth.dourolabs.app/hermes` service in preflight.
- `TrancheVault` now receives initial fee APR and recipient constructor arguments. Senior is constructed with
  `0/address(0)`, registered first, and Junior is then constructed with `100` bps and the Engine treasury snapshot.
  `MaintenanceFeeConfigInitialized` records the APR, recipient, and first hourly checkpoint boundary.
- Later Junior rate or recipient changes retain the existing 48-hour proposal/finalization delay. An Engine treasury
  rotation does not dynamically change the Junior recipient; governance must separately rotate it through that delay.
- Engine risk values are installed at construction. Release-only HousePool, PletherOracle, and Router constructor
  wrappers also install the `$40M/80%` limits and `$1,000/2,500` Router policy before the fresh contracts become
  observable. The shared generic constructors and their defaults remain unchanged.
- Bootstrap requires explicit `$10M/$10M` amounts and receiver addresses. Before the first Junior seed it verifies an
  active `100`-bps fee, the current deployment treasury snapshot, no fee proposal, zero pending fee shares, all four
  constructor-initialized Router/HousePool values, and no outstanding Router or HousePool proposal.
- Bootstrap no longer proposes or finalizes initial Router/HousePool configuration. Every later change still uses the
  existing independent 48-hour governance proposal/finalization path.
- The complete graph includes `CfdOrderPolicyEvaluator`, `OrderRouterV2ExecutionSidecar`, the predeployed
  `OrderLifecycleBook`, `PositionProtectionBook`, the predeployed liquidation batch sidecar, the monitor facade and
  monitor sidecar, Terminal NAV V2, the redemption math sidecar, and all account/public/protocol lenses.

## Junior fee economics

Fee payment is hourly dilution through newly minted Junior shares. It transfers no USDC, changes no tranche principal,
and never charges Senior. Effective Junior supply is raw supply plus currently accrued fee shares. Time elapsed before
the first nonzero Junior supply is checkpointed without dilution, so the first `$10M` seed receives no retroactive fee.
Existing catch-up bounds, zero-NAV behavior, settlement-hold/oracle-freeze accrual, redemption pricing, and tranche
isolation remain unchanged.

## Required evidence

Populate `deployments/arbitrum-sepolia-perps.template.json` as the immutable release record, including addresses,
runtime code hashes, constructor-initialization evidence, transactions, seed receivers, treasury snapshot, source
commit, and all three verifier phases. Run `scripts/prepare-perps-arbitrum-sepolia-release.sh` before any broadcast,
then use `VerifyPerpsArbitrumSepolia` at `deployed`, `seeded`, and `active`. The verifier is read-only.

The final release gate includes formatting, package-boundary checks, sized builds, all non-fork tests, Perps unit/fuzz/
invariant suites, EIP-170/EIP-3860 regressions, and an authenticated upgraded-Pyth no-broadcast Arbitrum Sepolia dry
run. No release is approved if the on-chain treasury changes between deployment, verification, seeding, and activation.

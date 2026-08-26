# Arbitrum Sepolia Perps Release Notes (Draft) - 2026-08-06

> Superseded by `RELEASE_NOTES_ARBITRUM_SEPOLIA_2026-08-26.md`. Retained as the historical draft for the earlier
> release shape and economics; do not use these defaults for the August 26 deployment.

## Summary

This release candidate replaces Plether's per-component Pyth confidence ceiling with a weighted aggregate basket
confidence gate and adds granular emergency containment. The default confidence limit remains `10` bps, but now
applies to the neutral basket before the protocol's price cap rather than independently to every currency feed.

This file describes the intended next Arbitrum Sepolia deployment. Contract addresses, deployment block,
bootstrap status, and trading activation must be recorded after deployment.

## Oracle Confidence Policy

The renamed `basketMaxConfidenceRatioBps` parameter defaults to `10`. The oracle accepts a basket when:

```text
basketConfidence * 10_000 <= basketPrice * basketMaxConfidenceRatioBps
```

`basketConfidence` is the sum of each normalized component contribution multiplied by that feed's raw
confidence-to-price ratio, with each component contribution floored before summation. `basketPrice` is the
neutral basket before capping. A basket exactly at the configured limit is accepted.

There is no separate per-component confidence ceiling. A low-weight component may therefore exceed 10 bps
individually when its weighted uncertainty leaves the full basket at or below 10 bps. This deliberately improves
oracle and order-execution liveness while continuing to bound the uncertainty of the product users actually
trade. It also means an individually wide feed can be masked by a sufficiently small basket weight; positive
price, staleness, feed ordering, and component publish-time-divergence validation remain unchanged.

## Compatibility and Operations

- The public configuration getter and router config field are renamed from `pythMaxConfidenceRatioBps` to
  `basketMaxConfidenceRatioBps`.
- Confidence validation failures use the new aggregate basket error rather than identifying one rejected feed.
- Live/FAD execution and liquidation continue using aggregate basket confidence for side-adverse pricing.
- Oracle-frozen voluntary closes continue replacing the adverse confidence shift with `frozenCloseSpreadBps`,
  but the aggregate basket confidence-width gate still applies.
- The 2026-06-24 release note remains the historical record for the previous deployment and its per-component
  confidence policy.

## Emergency Containment

- Deployment creates an `EmergencyPauseCoordinator` after the settlement monitor and installs it as the common pauser
  on RouterAdmin and HousePool. Bootstrap requires its address and a nonzero guardian, verifies exact bindings, and
  never repairs partial wiring or unpauses a component.
- The guardian has three fixed actions: Router risk-off plus LP entry, LP-settlement-only hold, and atomic full
  containment. It cannot supply an arbitrary mask. The Lens remains advisory and does not permissionlessly trip
  containment; reason/evidence hashes point to archived off-chain incident material.
- Router pause records a permanent inclusive order-id cutoff. Pre-cutoff opens are refunded to the trader's internal
  settlement without an oracle, Engine mutation, carry checkpoint, Terminal NAV synchronization, or cleanup bounty;
  Router authorization still reads the Engine's canonical binding, and the protocol incident keeper pays gas.
- Liquidation performs the same exact refund for each invalidated account order before forfeiting unaffected bounties.
  The loop is account-local and capped at 32; an aggregate Router implementation was rejected after exceeding
  EIP-170, while the retained path stays below the pre-change Router runtime baseline.
- HousePool settlement hold blocks both direct cached/no-position and Router atomic-refresh epoch clearing, so pending
  deposits do not activate and new redemptions are not funded. New deposits/Senior reservations and redemptions may
  still queue, existing cancellation rules do not change, and already-funded claims remain available.
- Closes/reductions, liquidations, mark refresh, recapitalization/reconciliation, and funded claims are deliberately
  unpausable. Redemption-request-off and a global all-LP-request freeze do not exist; actions containing the entry
  restriction do stop new deposit requests. There is no arbitrary mask, queue quarantine, emergency price setter, or
  global protocol freeze.
- Governance alone recovers Router risk-off, LP entry, and LP settlement. Restrictions have no expiry; release does
  not repair state or guarantee the next transaction, and unpause never clears the historical cutoff. Automated
  off-chain guardian operation remains out of scope.

`SettlementMonitorLens` reports a readable active hold as an explicit operational blocker and deposit deferral while
preserving route classification for recovery. A failed hold read is an unknown Pool dependency. `LpEpochKeeper`
rejects an active hold before payload decoding, fee quotation, or broadcast. Hold state is part of the observation
digest, and the monitoring ABI changes, so the monitor schema and both digest domains advance from V1 to V2. Runtime
hold changes do not alter `observableConfigDigest`.

To preserve HousePool EIP-170 headroom, deployment now creates a stateless pure
`HousePoolRedemptionMathSidecar` before HousePool and passes its address into the constructor. The deploy/bootstrap
flow records the sidecar and verifies code plus
`implementationId() == keccak256("Plether.HousePoolRedemptionMathSidecar.v1")`. The binding is internal immutable;
the sidecar has no storage, setter, delegatecall, upgrade path, custody, or settlement authority.

The release separately predeploys a fixed `OrderRouterLiquidationBatchSidecar` to preserve Router EIP-170 and
EIP-3860 headroom. The deployer computes the immediately next Router `CREATE` address, binds the sidecar to that
address, and creates the Router next without an intervening nonce-consuming transaction or `CREATE`. The Router
constructor rejects missing sidecar
code or a `ROUTER()` mismatch. The sidecar carries stateless mark-refresh/protection-trigger, LP-epoch settlement, and
single/batch liquidation orchestration; it has no mutable storage or upgrade path and rejects direct or foreign-context
execution. Keepers continue calling the canonical `OrderRouter` entrypoints.

## Deployment Record

Populate this section after the parallel stack is deployed and verified:

- source commit,
- new contract addresses and deployment block,
- configured `basketMaxConfidenceRatioBps`,
- bootstrap and trading-activation status,
- Router keeper/protection/liquidation sidecar address, code hash, exact Router binding, and deployment-order
  verification; HousePool redemption-math sidecar address and implementation identity; emergency coordinator,
  guardian, shared-pauser verification, and all three containment-drill results,
- oracle-worker soak result and decoded-revert monitoring status.

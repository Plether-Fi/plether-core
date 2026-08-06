# Arbitrum Sepolia Perps Release Notes (Draft) - 2026-08-06

## Summary

This release candidate replaces Plether's per-component Pyth confidence ceiling with a weighted aggregate basket
confidence gate. The default limit remains `10` bps, but now applies to the neutral basket before the protocol's
price cap rather than independently to every currency feed.

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

## Deployment Record

Populate this section after the parallel stack is deployed and verified:

- source commit,
- new contract addresses and deployment block,
- configured `basketMaxConfidenceRatioBps`,
- bootstrap and trading-activation status,
- oracle-worker soak result and decoded-revert monitoring status.

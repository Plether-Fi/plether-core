# Security Assumptions And Known Limitations - Perps

This document describes the trust model, protocol invariants, failure-containment design, and known limitations for the Plether perps system.

It is written as an audit-facing companion to:

- [`README.md`](README.md) for the high-level product and architecture story
- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md) for the canonical accounting model
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md) for the custody and state-boundary map
- [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) for the compact policy tables, liveness tradeoffs, and test map used during audit review

## Security Model In One Page

The perps system is built around a few core security choices:

- bounded trader payouts through a capped market price,
- delayed-order execution through a keeper-run FIFO router,
- strict separation between trader custody, router escrow, engine accounting, and LP capital,
- conservative LP accounting that refuses to count unrealized trader losses as present assets,
- fail-soft terminal settlement through deferred trader and clearer balances,
- degraded-mode containment if a terminal transition reveals insolvency.

The protocol is intentionally non-upgradeable. Admins can tune risk parameters and pause certain entrypoints, but they cannot swap logic or rewrite deployed code.

## Upgradeability And Admin Surface

All perps contracts are non-upgradeable.

- No proxy patterns.
- Runtime logic is fixed at deployment.
- Core constructor parameters such as `CAP_PRICE`, oracle feed configuration, basket weights, and base prices are immutable.

### Timelocked admin state

The following parameter families are owner-controlled behind a 48-hour propose/finalize delay.
Engine risk controls live in `CfdEngineAdmin`, and router risk controls live in `OrderRouterAdmin`, with each admin module applying finalized values onto its host contract:

| Parameter | Contract | Guard |
|-----------|----------|-------|
| `riskParams` (VPI, carry, margins, bounty) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `fadDayOverrides` | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `fadMaxStaleness` | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `fadRunwaySeconds` | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `engineMarkStalenessLimit` | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `seniorRateBps` | `HousePool` | `onlyOwner`, 48-hour timelock |
| `markStalenessLimit` | `HousePool` | `onlyOwner`, 48-hour timelock |
| `orderExecutionStalenessLimit` | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |
| `liquidationStalenessLimit` | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |
| `maxOrderAge` | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |
| `pythMaxConfidenceRatioBps` | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |

### One-time wiring

These are one-time configuration setters rather than mutable governance knobs:

| Setter | Contract |
|--------|----------|
| `setVault(address)` | `CfdEngine` |
| `setOrderRouter(address)` | `CfdEngine` |
| `setEngine(address)` | `MarginClearinghouse` |
| `setSeniorVault(address)` | `HousePool` |
| `setJuniorVault(address)` | `HousePool` |
| `setOrderRouter(address)` | `HousePool` |

### Instant owner controls

The owner can act immediately to:

- pause and unpause `OrderRouter` through `OrderRouterAdmin`,
- pause and unpause `HousePool`,
- withdraw protocol fees,
- transfer ownership.

The owner cannot:

- change deployed logic,
- change `CAP_PRICE`,
- rewrite historical state,
- directly seize arbitrary user funds,
- bypass the core solvency and withdrawal accounting model.

## Critical Capability Boundaries

Several perps contracts intentionally expose narrow but high-authority capability surfaces.

- `OrderRouter` is the external execution boundary and can reach engine settlement paths plus `HousePool.payOut(...)` / `recordProtocolInflow(...)` through the approved caller set.
- `CfdEngineSettlementModule` is engine-gated, but any external function added there is automatically security-critical because it can reach engine-owned settlement hooks.
- `MarginClearinghouse` operator paths trust `engine`, `orderRouter`, and `settlementModule` to move trader custody across settlement, escrow, and seizure buckets.
- `MarginClearinghouse.seizeUsdcWithoutCarryCheckpoint(...)` and `seizePositionMarginUsdcWithoutCarryCheckpoint(...)` are intentionally narrow stale close-commit escape hatches; they must remain reserved for risk-reducing stale fallback flows that have already been bounded by router/engine policy.
- `HousePool.payOut(...)` and `HousePool.recordProtocolInflow(...)` trust `engine`, `orderRouter`, and `settlementModule` as capability-bearing callers.

Practical rule:

- any new external function on `OrderRouter` or `CfdEngineSettlementModule`, and any new helper/module that can reach these caller sets, must be treated as security-critical and reviewed like a core custody or settlement change.

## Critical Protocol Invariants

These are the highest-value properties an auditor should expect to hold.

### Solvency and containment

| Invariant | Description |
|-----------|-------------|
| Bounded entry solvency | Risk-increasing opens require `vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)` using canonical physical backing rather than raw token balance |
| Degraded containment | If a close or liquidation reveals post-op insolvency, `degradedMode` latches and blocks further risk expansion while still permitting protective transitions |
| Bounded payout | No trader payout can exceed the capped market payoff implied by `CAP_PRICE` |
| Withdrawal firewall | LP withdrawals are limited to conservative free cash after accounting for bounded liability, deferred liabilities, and protocol-owned balances |
| Deferred liabilities are senior | Deferred trader credit and deferred keeper credit remain senior claims on vault liquidity until serviced |

### Position and engine accounting

| Invariant | Description |
|-----------|-------------|
| Single direction per account | An `accountId` holds at most one live directional position at a time |
| Margin sufficiency | Opens and withdraw-facing checks use explicit initial/maintenance/FAD margin policy surfaces |
| Side symmetry | Side-local cached accounting stays consistent with the live position set |
| Total margin conservation | `sides[BULL].totalMargin + sides[BEAR].totalMargin == sum(pos.margin)` across all live positions |
| Preview/live parity | Close and liquidation preview math should match live execution semantics |

### Router and escrow accounting

| Invariant | Description |
|-----------|-------------|
| Global FIFO | Execution always starts from the current global queue head |
| Binding intents | Users cannot cancel queued orders once committed |
| Bounty conservation | Router-custodied execution bounty escrow is conserved across order lifecycle transitions until distributed or absorbed |
| Reservation source of truth | Clearinghouse reservation records remain the source of truth for committed order margin |
| Bounded cleanup | Queue cleanup, liquidation cleanup, and close-intent position projection are account-local and intentionally bounded |

### HousePool and LP accounting

| Invariant | Description |
|-----------|-------------|
| Canonical asset boundary | Pool depth is based on `min(rawAssets, accountedAssets)`, not raw token balance alone |
| Conservative MtM | Unrealized trader losses do not count as instantly withdrawable LP assets |
| High-water-mark protection | Senior impairment must be restored before junior extracts surplus |
| Shared accounting inputs | Reconcile, withdrawal limits, and LP status views consume the same canonical engine snapshots |

## Trust Assumptions

### Pyth Network

The protocol assumes Pyth provides timely and correct FX feed data for the basket components.

Mitigations:

- delayed-order execution with publish-time ordering while the oracle is live,
- distinct staleness thresholds for order execution, liquidation, engine-side guards, and HousePool freshness,
- shared normalized basket-price construction across execution paths,
- frozen-oracle regime for close liveness during genuine market closure.

Risks:

- compromised or stale feeds distort the basket price,
- frozen-market execution is intentionally liveness-first for risk reduction,
- exponent normalization truncates on scale-down,
- all live execution still depends on external oracle availability.

### USDC

The protocol assumes standard ERC-20 behavior and practical dollar parity from USDC.

Risks:

- blacklist risk,
- upgrade risk at the token level,
- collateral centralization risk,
- no mitigation inside the core perps design.

### OpenZeppelin and other dependencies

The system relies on standard audited libraries and treats them as trusted building blocks rather than protocol-specific attack surfaces.

## Internal Trust Boundaries

### Owner

The owner can tune risk and liveness configuration and activate pauses, but cannot arbitrarily rewrite custody state.

### Keepers

Keepers are permissionless executors.

- They execute queued orders with oracle data.
- They trigger liquidations.
- They receive router-custodied execution bounties or liquidation bounties depending on the path.
- They are not trusted with user intent beyond what the delayed-order model reveals.

### Engine and router vs clearinghouse

`MarginClearinghouse` trusts only the configured engine and the router address sourced from the engine boundary.

Those actors can:

- lock and unlock margin,
- settle USDC balances,
- seize settlement into protocol-authorized flows,
- move execution bounty reserves into router custody.

Those actors cannot:

- create negative balances,
- withdraw seized user funds to arbitrary third-party recipients,
- bypass clearinghouse bucket accounting.

## Oracle And Execution Security

### Delayed-order model

The router uses delayed commit/execute semantics rather than same-tx market execution.

Security properties:

- trader intent is committed before keeper execution,
- live-market execution requires `publishTime > commitTime`, which defends against oracle latency arbitrage,
- FIFO execution prevents later orders from bypassing earlier ones,
- binding order semantics prevent traders from turning queued intents into free options.

### Queue failure handling

Current policy is intentionally simple:

- slippage-invalid orders fail terminally,
- expired orders fail terminally,
- typed engine failures route bounty according to semantic failure category,
- terminal-invalid closes pay the clearer rather than refunding potentially margin-backed escrow to the trader wallet,
- open-order refunds and clearer payouts credit clearinghouse settlement rather than sending direct wallet USDC transfers,
- the router does not maintain a retry or requeue lane.

### Oracle regimes

The protocol distinguishes two states around market closure:

- `FAD window`: elevated margins and close-only risk policy while markets are still plausibly live,
- `oracle frozen`: relaxed staleness and relaxed publish-ordering rules once feeds are genuinely offline.

This is a deliberate trade-off: preserve close and liquidation liveness during real closures without weakening live-market MEV protections.

## Accounting And Solvency Security

### Conservative LP accounting

The protocol does not treat unrealized trader losses as immediately realizable LP assets.

That means:

- LP share pricing may temporarily undercount value,
- junior principal can dip before later realized recovery arrives,
- but the protocol avoids phantom-profit withdrawal bugs.

This is an explicit design choice, not an accounting accident.

### Carry instead of funding

The perps system uses LP-capital carry instead of side-to-side funding.

- carry base: `max(positionNotionalUsdc - reachableCollateralUsdc, 0)`
- accrual clock: wall-clock time
- stale/frozen behavior: carry does not pause during stale or frozen oracle windows
- basis-change fallback: if physical collection is unsafe, elapsed carry is checkpointed into `unsettledCarryUsdc`
- realization points: open, close, add margin, and clearinghouse deposit/withdraw using the pre-mutation reachable basis; deposits may collect realized carry from post-deposit settlement in the same transaction, while withdraws realize carry before reducing settlement
- destination: realized carry becomes LP trading revenue

Close and liquidation security depends on using the planner's canonical carry-adjusted settlement outputs directly in the live executor rather than recomputing a second carry-blind kernel.

Security implication: oracle freshness still gates execution and LP accounting freshness, but not carry accrual.

### Deferred liabilities

Terminal transitions are fail-soft when the vault lacks immediate cash.

- profitable closes can create deferred trader credit,
- liquidation bounties can create deferred keeper credit,
- both are beneficiary-balance based rather than FIFO queue based,
- both remain part of reserve and solvency accounting until paid.

This preserves risk reduction and liquidation liveness under temporary cash shortfall.

### Explicit netting boundary

Same-account deferred trader credit is not generic collateral.

- generic account-health and withdraw checks use physically reachable clearinghouse collateral,
- terminal settlement paths may still explicitly net same-account deferred trader credit,
- this avoids accidentally reusing a vault IOU as immediately spendable account cash.

## HousePool And LP-Specific Risks

### Canonical asset boundary

`HousePool` distinguishes:

- `rawAssets`,
- `accountedAssets`,
- `excessAssets`,
- `totalAssets() = min(rawAssets, accountedAssets)`.

Security purpose:

- unsolicited donations do not silently change economic depth,
- raw-balance shortfalls reduce effective backing immediately,
- all LP accounting works from a controlled economic boundary.

### Seed lifecycle gate

The protocol blocks normal live operation until both tranche seeds exist and trading is explicitly activated.

This prevents partially initialized live state and ambiguous ownership of early revenue flows.

### Freshness-gated LP actions

When marks are stale and freshness is required:

- withdrawal and deposit-facing LP paths may be blocked,
- mark-dependent reconcile math is skipped,
- already-funded pending buckets may still settle,
- fresh oracle publication is the recovery path.

### Senior yield model

Senior yield is a preferred return from surplus revenue, not a hard coupon paid by draining junior capital during inactivity.

This avoids weakening the junior loss buffer during flat or low-volume periods.

## Liquidation Security

### Full liquidation only

Liquidations always close the entire position.

Trade-off:

- simpler accounting and fewer liquidation games,
- no partial-liquidation recovery path for oversized positions.

### Reachability and bounty bounds

- liquidation accounting is constrained by actually reachable collateral,
- keeper bounty is proportional with a floor but capped by reachable value,
- residual trader value is preserved when positive,
- same-account deferred trader credit does not support liquidation reachability and is only netted once against terminal shortfall,
- remaining deficit becomes bad debt socialized to LP capital.

### Queue interaction during liquidation

Liquidation performs bounded account-local cleanup of that account's pending orders.

This preserves terminal liveness without requiring an unbounded global queue scan.

## Known Limitations

### Oracle and market-closure limitations

- frozen-oracle windows prioritize close liveness over live-market-style freshness guarantees,
- DST and holiday boundaries can create short safe liveness gaps around market reopen,
- execution remains dependent on fresh keeper infrastructure and oracle publication outside frozen windows.

### Router and keeper limitations

- users cannot manually cancel queued intents,
- bounded cleanup means heavily expired queues may take multiple keeper calls to clear,
- per-account pending-order caps bound griefing and liquidation cleanup now stays on bounded account-local order traversal,
- failed orders remain terminal rather than retryable.

### LP accounting limitations

- conservative MtM can temporarily understate junior value,
- stale marks can block LP actions,
- senior yield is not guaranteed during flat periods,
- deposit cooldown can be griefed only by economically irrational donation-style top-ups.

### VPI limitations

- liquidation does not compute a fresh VPI delta, but negative accrued VPI is clawed back into liquidation shortfall,
- VPI depends on live vault depth,
- the lifetime clamp intentionally zeroes otherwise extractable rebate-only round trips,
- partial-close VPI release is a bounded linear approximation.

### Clearinghouse limitations

- V1 is USDC-only cross-margin,
- non-USDC collateral pricing and staleness policy are intentionally out of scope.

## Emergency Procedures

### Emergency pause

1. Pause `OrderRouter` and/or `HousePool`.
2. New risk-increasing order commits and/or LP deposits stop immediately.
3. Protective execution paths remain available.
4. Investigate and remediate.
5. Unpause when safe.

### Suspected oracle issue

1. Pause `OrderRouter` to stop new commitments.
2. Let existing protective flows continue.
3. Investigate feed correctness and liveness.
4. Resume once oracle behavior is understood.

### Keeper outage

1. Orders accumulate in the queue.
2. Users cannot manually cancel them.
3. Restart keeper infrastructure.
4. Expect bounded cleanup rather than instant queue drain.

### Bad debt cascade

1. Let closes and liquidations continue.
2. Prevent further risk expansion via degraded mode and, if needed, admin pause.
3. Consider stricter risk settings to accelerate cleanup.
4. Recapitalize or clear positions.
5. Clear degraded mode only after solvency is genuinely restored.

## Asset Isolation

Core perps LP capital must remain pure, immediately accessible USDC.

The protocol explicitly rejects embedding third-party yield or lending-market exposure into the core `HousePool` because that would:

- turn bounded solvency into an external liquidity assumption,
- create crisis-time liquidity mismatch,
- import external smart-contract and bad-debt contagion,
- weaken confidence in immediate trader payout capacity.

If yield overlays are desired, they should sit above the base protocol as opt-in wrappers rather than inside the core clearing layer.

## Decimal Reference

| Quantity | Decimals |
|----------|----------|
| USDC | 6 |
| Position size | 18 |
| Oracle / basket price | 8 |
| PnL | 6 |
| TrancheVault offset | 3 |

## Audit Status

Not yet audited. The perps system remains pre-deployment.

| Component | Status |
|-----------|--------|
| `CfdEngine` | Not yet audited |
| `CfdMath` | Not yet audited |
| `OrderRouter` | Not yet audited |
| `MarginClearinghouse` | Not yet audited |
| `HousePool` | Not yet audited |
| `TrancheVault` | Not yet audited |

## Security Contact

For responsible disclosure:

`contact@plether.com`

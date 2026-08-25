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
- strict separation between trader custody, router intent records, engine accounting, and LP capital,
- exact symmetric LP NAV that counts only account-capped collectible marked losses as receivables and never as
  withdrawal cash before collection,
- fail-soft terminal settlement through trader claim balances,
- degraded-mode containment if a terminal transition reveals insolvency.

The protocol is intentionally non-upgradeable. Admins can tune risk parameters and pause certain entrypoints, but they cannot swap logic or rewrite deployed code.

## Upgradeability And Admin Surface

All perps contracts are non-upgradeable.

- No proxy patterns.
- Runtime logic is fixed at deployment.
- Core constructor parameters such as `CAP_PRICE` are immutable.
- `OrderRouter`'s configured `PletherOracle` address can be rotated only through `OrderRouterAdmin`'s 48-hour timelocked oracle config flow. Feed ids, basket weights, base prices, inversion flags, and the Pyth endpoint are fixed on each `PletherOracle` instance, so changing them requires deploying a new oracle and timelocking the router onto it.

### Timelocked admin state

The following parameter families are owner-controlled behind a 48-hour propose/finalize delay.
Engine risk controls live in `CfdEngineAdmin`, and router risk controls live in `OrderRouterAdmin`, with each deployed admin contract applying finalized values onto its host contract:

`CfdEngine` sidecars (`CfdEnginePlanner`, `CfdEngineSettlementSidecar`, `CfdEngineAdmin`) are now deployed separately and wired once via `setDependencies(...)`. That wiring is owner-only and one-time. The engine rejects a settlement sidecar or admin bound to another engine and rejects a no-code admin address; audited `CfdEngineAdmin` bytecode remains a deployment trust assumption.

`TerminalNavBookV2` is also deployed separately and wired once through `setTerminalNavBook(...)` before any exposure.
The Engine accepts only an empty book immutably bound to itself with matching `CAP_PRICE` and the canonical `1e20`
size quantum.

| Parameter | Contract | Guard |
|-----------|----------|-------|
| `EngineRiskConfig` (`riskParams`, `executionFeeBps`, `frozenCloseSpreadBps`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `EngineCalendarConfig` (`fadDayOverrides`, `fadRunwaySeconds`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `EngineFreshnessConfig` (`fadMaxStaleness`, `engineMarkStalenessLimit`) | `CfdEngineAdmin` -> `CfdEngine` | `onlyOwner`, 48-hour timelock |
| `seniorRateBps` | `HousePool` | `onlyOwner`, 48-hour timelock |
| `markStalenessLimit` | `HousePool` | `onlyOwner`, 48-hour timelock |
| `maxSeniorExposureUsdc`, `maxSeniorShareBps` | `HousePool` | `onlyOwner`, 48-hour timelock; finalized values must be finite and below 100%, respectively |
| `RouterConfig` (`maxOrderAge`, staleness limits, basket confidence ratio, historical settlement window, component publish-time skew, adverse confidence multiplier, bounty limits) | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |
| `OracleConfig` (`pletherOracle`) | `OrderRouterAdmin` -> `OrderRouter` | `onlyOwner`, 48-hour timelock |

The deployed `frozenCloseSpreadBps` default is `50` bps (0.50%). Both construction and timelocked updates reject zero and values above the `1,000` bps (10%) hard cap.

### One-time wiring

These are one-time configuration setters rather than mutable governance knobs:

| Setter | Contract |
|--------|----------|
| `setDependencies(planner, settlementSidecar, admin)` | `CfdEngine` |
| `setTerminalNavBook(address)` | `CfdEngine` |
| `setPool(address)` | `CfdEngine` |
| `setOrderRouter(address)` | `CfdEngine` |
| `setEngine(address)` | `MarginClearinghouse` |
| `setSeniorVault(address)` | `HousePool` |
| `setJuniorVault(address)` | `HousePool` |

`SettlementMonitorLens` construction validates the required core wiring and reciprocal bindings before fixing its
constructor bindings. `getSettlementHealth()` checks those bindings again at runtime, and the observable configuration digest
records the planner, settlement-sidecar, admin, Oracle/Pyth, vault, book, and asset identities for off-chain drift
comparison. This is detection only; the monitor cannot repair wiring or authorize a replacement.

`EmergencyPauseCoordinator` is independently immutable-bound to the exact RouterAdmin and HousePool. Deployment
installs it as both components' pauser. It does not trust or call the Lens: monitoring output, `reasonHash`, and
`evidenceHash` are advisory incident evidence, and only the configured guardian may trigger containment.

`OrderRouter` constructor-deploys one `OrderRouterLiquidationBatchSidecar` and exposes its immutable address. The
sidecar has no mutable storage or upgrade setter, records the deploying Router immutably, and rejects direct calls;
its batch entrypoint is valid only under delegatecall where `address(this)` is that Router. Its Router self-callback
remains self-only, so an external caller cannot use the sidecar to bypass Router authorization or reentrancy guards.

### Instant owner controls

The owner can act immediately to:

- pause and unpause `OrderRouter` through `OrderRouterAdmin`,
- pause and unpause `HousePool`,
- install or replace the common coordinator pauser on `OrderRouterAdmin` and `HousePool`,
- rotate or disable the coordinator guardian,
- set the protocol treasury account,
- initiate an ownership transfer, which the pending owner must explicitly accept through the `Ownable2Step` flow.

The owner cannot:

- change deployed logic,
- change `CAP_PRICE`,
- rewrite historical state,
- directly seize arbitrary user funds,
- bypass the core solvency and withdrawal accounting model.

## Critical Capability Boundaries

Several perps contracts intentionally expose narrow but high-authority capability surfaces.

- `OrderRouter` is the external execution boundary and can reach engine order/liquidation paths plus a narrow clearinghouse reservation surface. Router-sourced protocol value must credit the treasury account through clearinghouse accounting rather than calling `HousePool` inflow hooks.
- `CfdEngineSettlementSidecar` is engine-gated, but any external function added there is automatically security-critical because it can reach engine-owned settlement hooks.
- `TerminalNavBookV2` accepts curve mutations only from its immutable-bound Engine. It has no owner, repair, or
  migration path. Engine wiring validates the bound Engine, price cap, size quantum, and completely empty book before
  accepting it once.
- `MarginClearinghouse` broad operator paths trust only `engine` and `settlementSidecar` to move trader custody across settlement and seizure buckets; router access is limited to reservation lifecycle paths needed for queued orders.
- Close-execution bounty paths, including stale fallback, lock eligible free settlement as action reserve. They must not
  reclassify PnL pledge without an atomic terminal-curve resynchronization and a new security review.
- Negative lifetime VPI is protected by a dedicated sub-balance of action reserve. Generic action collection must not
  cross the combined floor of protected execution bounties plus `max(-vpiAccrued, 0)`.
- `HousePool.payOut(...)` and `HousePool.recordProtocolInflow(...)` trust only `engine` and `settlementSidecar`; unsolicited raw pool cash must be admitted through owner-governed excess accounting, and protocol fees stay in treasury clearinghouse margin.

Practical rule:

- any new external function on `OrderRouter` or `CfdEngineSettlementSidecar`, and any new helper/sidecar that can reach these caller sets, must be treated as security-critical and reviewed like a core custody or settlement change.

## Critical Protocol Invariants

These are the highest-value properties an auditor should expect to hold.

### Solvency and containment

| Invariant | Description |
|-----------|-------------|
| Bounded entry solvency | Risk-increasing opens require `pool.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)` using canonical physical backing rather than raw token balance |
| Degraded containment | If a close or liquidation reveals post-op insolvency, `degradedMode` latches and blocks further risk expansion while still permitting protective transitions |
| Bounded payout | No trader payout can exceed the capped market payoff implied by `CAP_PRICE` |
| Withdrawal firewall | Synchronized LP redemption funding is limited to conservative free cash after accounting for bounded liability and trader claim liabilities |
| Matured Senior priority | A settlement cannot fund Junior redemptions while any eligible matured Senior demand remains unaccounted for |
| Funded-claim backing | Every claimable LP asset is held one-for-one in vault escrow and cannot be reused by `HousePool` |
| Trader claim liabilities are senior | Trader claim balance remains a senior claim on pool liquidity until serviced; keeper bounties are not pool liabilities |
| Explicit terminal deficit | Signed terminal liabilities above physical assets and collectible terminal receivables are persisted on fresh reconcile and block LP entry |

### Position and engine accounting

| Invariant | Description |
|-----------|-------------|
| Single direction per account | An account address holds at most one live directional position at a time |
| Margin sufficiency | Opens and withdraw-facing checks use explicit initial/maintenance/FAD margin policy surfaces |
| Side symmetry | Side-local cached accounting stays consistent with the live position set |
| Total margin conservation | `sides[BULL].totalMargin + sides[BEAR].totalMargin == sum(pos.margin)` across all live positions |
| Preview/live parity | Close and liquidation preview math should match live execution semantics |
| Frozen-spread conservation | For a valid frozen voluntary close, assessed spread equals LP-paid spread plus terminally waived spread; none is credited to protocol treasury |
| Exact-lot basis | Every live position uses whole 100-token lots and exact entry cost is conserved across increases and partial closes |
| Terminal-book parity | Each account curve matches its live side, lots, exact entry cost, and `pnlPledge + same-account claim` cap after every successful mutation |

### Router and reservation accounting

| Invariant | Description |
|-----------|-------------|
| Global FIFO | Execution always starts from the current global queue head |
| Binding intents | Users cannot cancel queued orders once committed |
| Bounty conservation | Clearinghouse-reserved execution bounty value is conserved across order lifecycle transitions until distributed or absorbed, and is excluded from close-loss reachability while reserved |
| VPI reserve conservation | Every live negative lifetime-VPI balance has equal dedicated action-reserve backing; only an exact clawback, equivalent withholding, or lower surviving target may consume or release it |
| Reservation source of truth | Clearinghouse reservation records remain the source of truth for committed order margin |
| Earliest lot gate | Router commit rejects non-100-token-multiple opens and closes before reserving value or assigning an order id |
| Economic close granularity | Partial close intents must meet the engine notional floor; only full residual closes may be smaller |
| Bounded cleanup | Queue cleanup, liquidation cleanup, and close-intent position projection are account-local and intentionally bounded |

### HousePool and LP accounting

| Invariant | Description |
|-----------|-------------|
| Canonical asset boundary | Pool depth is based on `min(rawAssets, accountedAssets)`, not raw token balance alone |
| Symmetric terminal NAV | LP entry and exit pricing use the same signed exact terminal price delta and waterfall snapshot |
| Receivable/cash separation | Positive marked receivables are capped by account pledge/claim value and never increase physical redemption funding before collection |
| High-water-mark protection | Senior impairment must be restored before junior extracts surplus |
| Bounded new senior exposure | Counted admission exposure (`E + R`) cannot exceed the smaller absolute and senior-share headrooms |
| Junior covenant | Junior redemption funding cannot leave active protected exposure (`E`, excluding `R`) above the configured share of Senior-plus-Junior claimant capital |
| Shared cutoff routing | Both tranches and both request directions use the same five-minute cutoff; exact equality rolls to the later epoch without a cutoff-specific revert |
| Locked-epoch additions | For boundary `b`, no request at or after `b - 300` may increase locked epoch `e + 1`, including after it matures; cancellation may still shrink it, while requests after `b` may join the new imminent numeric epoch `e + 2` until its own cutoff |
| Shared accounting inputs | Reconcile, synchronized redemption funding, deposit finalization, and LP status views consume the same canonical engine snapshot |

### Coverage map

The tables above describe the intended safety properties. The suites below are the highest-signal places where those properties are exercised today.

| Invariant family | Primary coverage |
|-----------|-------------|
| Bounded entry solvency / margin sufficiency | `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/CfdEnginePlanRegression.t.sol`, `packages/perps/test/perps/invariant/PerpPreviewInvariant.t.sol` |
| Degraded containment / post-op degraded-mode parity | `packages/perps/test/perps/PerpInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpPreviewInvariant.t.sol`, `packages/perps/test/perps/PreviewExecutionDifferential.t.sol` |
| Bounded payout / preview-live settlement parity | `packages/perps/test/perps/CfdEngine.t.sol`, `packages/perps/test/perps/invariant/PerpPreviewInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpClosePreviewParityInvariant.t.sol` |
| Withdrawal firewall / trader-claim seniority | `packages/perps/test/perps/PerpInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpEconomicConservationInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpTraderClaimInvariant.t.sol`, `packages/perps/test/perps/HousePool.t.sol` |
| Single direction / side symmetry / total-margin conservation | `packages/perps/test/perps/PerpInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpMultiAccountInvariant.t.sol` |
| Global FIFO / binding intents / bounded cleanup | `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/invariant/PerpAccountingInvariant.t.sol` |
| Bounty conservation / reservation source of truth | `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/invariant/PerpAccountingInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpEconomicConservationInvariant.t.sol` |
| Canonical asset boundary / symmetric terminal NAV / high-water-mark protection | `packages/perps/test/perps/PerpInvariant.t.sol`, `packages/perps/test/perps/HousePool.t.sol`, `packages/perps/test/perps/invariant/PerpHousePoolLifecycleInvariant.t.sol`, `packages/perps/test/perps/TerminalNavBookV2.t.sol` |
| Shared request cutoff / locked-epoch additions | `packages/perps/test/perps/LpRequestCutoff.t.sol`, `packages/perps/test/perps/invariant/GovernedSeniorCapacityInvariant.t.sol` |
| Oracle freshness / FAD boundaries / ETH refund custody | `packages/perps/test/perps/OrderRouter.t.sol`, `packages/perps/test/perps/invariant/PerpOracleBoundaryInvariant.t.sol`, `packages/perps/test/perps/invariant/PerpOraclePathInvariant.t.sol` |
| Fee custody / protocol accounting snapshots | `packages/perps/test/perps/invariant/PerpFeeFlowInvariant.t.sol`, `packages/perps/test/perps/PerpsReadParity.t.sol` |

## Trust Assumptions

### Pyth Network

The protocol assumes Pyth provides timely and correct FX feed data for the basket components.

Mitigations:

- delayed-order execution that settles against the first unique Pyth tick strictly after commit while the oracle is live,
- distinct staleness thresholds for order execution, liquidation, engine-side guards, and HousePool freshness,
- shared normalized basket-price construction across execution paths,
- timelocked rotation of the router's `PletherOracle` address if the Pyth endpoint or basket-feed set must be replaced,
- conservative weighted basket confidence propagation, a timelocked aggregate pre-cap confidence limit, and side-adverse pricing for execution, equity checks, and liquidation, except that oracle-frozen voluntary closes replace the adverse price shift with the fixed frozen-close spread,
- component publish-time skew limits so a basket cannot mix fresh and stale legs,
- frozen-oracle regime for close liveness during genuine market closure.

Risks:

- compromised or stale feeds distort the basket price,
- unavailable historical update data can delay live order execution until a keeper supplies the commit-window tick or the order expires,
- frozen-market execution is intentionally liveness-first for risk reduction,
- exponent normalization truncates on scale-down,
- the basket-only confidence gate deliberately favors liveness over an individual-feed hard ceiling: a low-weight component with a wide confidence interval can pass when its weighted contribution keeps aggregate basket confidence within the configured limit,
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

### Guardian and emergency coordinator

`OrderRouterAdmin` and `HousePool` retain separate owner-controlled pause state, but normal deployment installs one
`EmergencyPauseCoordinator` as both pausers. Governance owns the coordinator and assigns its guardian.

- Only the guardian may call `triggerEmergencyPause(reasonHash,evidenceHash)`.
- The transaction pauses RouterAdmin first and HousePool second; any failure rolls back every change made by that
  call while preserving pre-existing pause state. Repeated or partially pre-paused calls are idempotent.
- The coordinator can only add restrictions. It cannot unpause, change child configuration, set prices, move funds,
  or call arbitrary targets. Governance retains direct owner-only recovery and role assignment.
- Router pause records an inclusive, monotonic order-id cutoff. Pending opens at or below it are permanently invalid,
  including after unpause; later orders are unaffected.
- Cleanup is permissionless and oracle-independent. It returns all remaining committed margin and execution bounty to
  the trader's free internal settlement, pays the caller nothing, and defers carry checkpointing to the trader's next
  ordinary margin mutation. The protocol incident keeper therefore funds cleanup gas.
- Liquidation applies the same risk-off refund before forfeiting unaffected queued bounties, so cleanup-first and
  liquidation-first keeper ordering cannot change whether the invalidated-open reservation is refunded. Refunded free
  settlement remains ordinary trader capital and may still satisfy legitimate liquidation obligations. Liquidation
  reuses the exact single-order Clearinghouse reversal for each invalidated open; this is bounded by the 32-order
  account cap and remains inside one rollback frame. A one-call aggregate variant was rejected because it made the
  Router exceed both EIP-170 and its pre-change runtime baseline.
- HousePool pause blocks LP entry only. Redemptions, synchronized redemption funding, and funded claims remain live.
  It does not itself unlock cancellation of a matured deposit; that request still needs an existing rejection,
  projected-wipe, Senior-impairment, or Senior-reservation escape condition, or later activation after recovery.
- LP request-off, LP settlement-off, and corrupted-queue quarantine are separate proposed breakers, not powers hidden
  in this coordinator.

### Keepers

Keepers are permissionless executors.

- They execute queued orders with oracle data.
- They trigger liquidations.
- They receive clearinghouse-reserved execution bounties or liquidation bounties depending on the path.
- They are not trusted with user intent beyond what the delayed-order model reveals.

### Engine and router vs clearinghouse

`MarginClearinghouse` grants broad operator authority only to the configured engine and settlement module, while the router address sourced from the engine boundary can reach only narrow reservation lifecycle paths.

The broad operators can:

- lock and unlock margin,
- settle USDC balances,
- seize settlement into protocol-authorized flows.

The router reservation paths can:

- reserve and release queued-order margin and execution bounty buckets,
- route reserved execution bounty value through engine-approved payout, refund, or forfeiture paths.

Those actors cannot:

- create negative balances,
- withdraw seized user funds to arbitrary third-party recipients,
- bypass clearinghouse bucket accounting.

## Oracle And Execution Security

### Delayed-order model

The router uses delayed commit/execute semantics rather than same-tx market execution.

Security properties:

- trader intent is committed before keeper execution,
- live-market execution uses Pyth's unique historical parse over `(commitTime, commitTime + orderSettlementWindow]`, capped at `block.timestamp`, so settlement is bound to the first post-commit tick rather than the keeper's reveal-time tick,
- the unique historical parse rejects skipped ticks because the parsed update must prove its previous publish time is no later than the order's `commitTime`,
- batch execution may reuse a parsed historical basket only for later FIFO orders whose `commitTime` is strictly before the cached tick and falls within its proven coverage,
- the neutral pre-cap basket is accepted only when `basketConfidence * 10_000 <= basketPrice * basketMaxConfidenceRatioBps`; equality passes, each weighted component contribution is floored before summation, and no independent component-confidence ceiling applies,
- aggregate basket confidence is included in live/FAD execution and all liquidation prices instead of being treated only as metadata; oracle-frozen voluntary closes retain aggregate confidence-width validation but replace the adverse price shift with the fixed frozen-close spread,
- FIFO execution prevents later orders from bypassing earlier ones,
- partial-close size floors prevent flat-bounty dust closes from occupying global FIFO slots,
- binding order semantics prevent traders from turning queued intents into free options.

### Queue failure handling

Current policy is intentionally simple:

- slippage-invalid orders fail terminally,
- expired orders fail terminally,
- ordinary terminal engine failures pay the cleanup caller from the reserved bounty; the reason remains typed for
  diagnostics but does not change that routing,
- terminal-invalid closes pay the keeper from the already locked action reserve rather than refunding it to the trader wallet,
- open-order refunds and keeper payouts credit clearinghouse settlement rather than sending direct wallet USDC transfers,
- persistent risk-off cancellation is administrative invalidation, precedes expiry, needs no oracle, and fully refunds
  the trader internally without paying the cleanup caller,
- the router does not maintain a retry or requeue lane.

### Oracle regimes

The protocol distinguishes two states around market closure:

- `FAD window`: elevated margins and close-only risk policy while markets are still plausibly live,
- `oracle frozen`: relaxed staleness and relaxed publish-ordering rules once feeds are genuinely offline.

LP actions intentionally stay live across that split:

- `FAD` alone keeps ordinary LP pricing,
- `oracle frozen` keeps eligible synchronized redemption settlement live. Ordinary entry and exit remain
  asynchronous: a request does not lock a price, rate, or fee. Funded redemptions apply the then-active surcharge
  (`25 bps` Senior, `75 bps` Junior), retain it in the same tranche for incumbents, and place only net assets into
  claim escrow. Deposit activation is deferred until the live symmetric-NAV entry gate passes; withdrawal funding is
  not blocked merely because entries are deferred.

Voluntary close pricing follows the same regime boundary but is separate from LP entry/exit fees:

- live and FAD-only close/reduce execution uses normal signed VPI with the lifetime rebate clamp, retains Pyth adverse-confidence pricing, and assesses no frozen-close spread,
- `oracle frozen` keeps that same signed VPI treatment, waives the Pyth adverse-confidence price shift for voluntary closes, and assesses a fixed spread on reduced notional instead,
- the spread is LP-owned and never protocol-treasury revenue,
- partial closes must settle required separate charges, while price loss beyond the account's collectible cap is a
  diagnostic write-off; an uncollectible spread portion on a terminal full close is waived without creating a
  protocol liability or terminal deficit,
- liquidation pricing and settlement retain adverse-confidence pricing and do not assess the spread.

This is a deliberate trade-off: preserve close and liquidation liveness during real closures without weakening live-market MEV protections.

## Accounting And Solvency Security

### Exact symmetric LP NAV

LP entry and exit pricing consume the same authenticated terminal snapshot. The Engine stores whole 100-token lots
and exact entry cost, while `TerminalNavBookV2` aggregates each account's LP-side marked price PnL. A positive LP
receivable is capped by only that account's `pnlPledgeUsdc + traderClaimBalanceUsdc`; liquidation, order, and action
reserves cannot inflate it. A negative value is the exact marked price amount LPs owe the trader within the bounded
market.

Security consequences:

- new LPs receive the same marked-liability discount borne by existing LPs and do not inherit old trader obligations
  at a higher deposit NAV,
- losing-trader value above the account-specific collectible cap is excluded, preventing phantom receivables,
- marked receivables affect ownership pricing but remain unavailable to fund redemptions until physically collected,
- carry, VPI, fees, frozen spread, and liquidation charges stay outside the pre-close price book,
- realized partial-close price gains either replenish the surviving position's PnL pledge or become a nettable
  same-account trader claim; full-close price gains are free-settlement payouts or trader claims,
- gross negative lifetime VPI is backed by a dedicated nonwithdrawable reserve equal to `max(-vpiAccrued, 0)`; together
  with protected execution bounties it forms the action-reserve floor that generic charges cannot consume,
- opens/increases must fully fund any higher VPI target. Close and liquidation paths consume the reserve for realized
  clawback and leave the exact residual target protected; only genuinely excess or equivalently replaced value is
  released,
- new close-time action rebates use only pool cash free after protecting existing trader claims. Unfunded value is
  waived rather than claim-backed, and neither anticipated VPI nor its reserve inflates terminal `K` or symmetric NAV,
- a current terminal deficit blocks deposit activation,
- the Engine fails closed if the terminal book is absent or inconsistent, an open-position mark is unavailable, or an
  account mutation is in progress. `HousePool` independently rejects or defers LP actions under its configured mark-age
  and oracle-frozen policy.

Ordinary LP entry remains asynchronous: assets are funded into request escrow, a complete pending deposit is
cancellable before maturity, and post-maturity cancellation remains available only under the documented
epoch rejection, projected terminal-wipe, Senior-impairment, or Senior-reservation escape conditions. Shares are
minted only after synchronized `HousePool` settlement fixes the batch price. ERC-4626 `deposit` and `mint` only claim
already activated shares. During a frozen entry state the request remains deferred; redemptions can still use the
separate conservative cash-reserve path.

Atomic Engine-to-book synchronization is a critical trust boundary. Any path that changes position lots, exact entry
cost, side, PnL pledge, or same-account claim must finish by installing the matching curve or removing it. The
optimistic old-curve hash and monotonic book version protect against stale mutation plans; they are not a substitute
for invariant and differential testing of every settlement path.

A settlement pass that advances no queue item reverts, rolling back both waterfall reconciliation and engine carry
checkpoints. This prevents per-block no-op checkpoint grief. Senior coupon arithmetic still floors independently at
each settlement that advances real epoch work, so sub-micro-USDC rounding remains execution-frequency dependent; the
hourly aggregation of requests bounds that residual rather than making coupon accrual mathematically remainder-exact.

Async allocation uses per-controller floor rounding against immutable epoch totals. Splitting a request among more
controllers cannot increase aggregate entitlement. Once all controllers reach terminal state, deposit-share dust is
burned; funded-redemption share dust is booked in the epoch's claimed-share counter; funded asset dust returns raw to
`HousePool` without restoring `accountedAssets` and therefore becomes excess; and refundable-share dust moves to the
permanent seed account without resetting its cooldown. These terminal sweeps prevent stranded escrow without allowing
the final caller to capture another controller's rounding remainder.

This is an explicit design choice, not an accounting accident.

### LP-capital carry

The perps system uses LP-capital carry instead of a side-to-side rate mechanism.

- carry base: `max(positionMaxProfitUsdc - activePositionMarginUsdc, 0)`
- accrual clock: wall-clock time
- stale/frozen behavior: carry does not pause during stale or frozen oracle windows
- basis-change fallback: if physical collection is unsafe, elapsed carry is checkpointed into `unsettledCarryUsdc`
- realization points: open, close, add margin, pool-asset changes, risk-parameter changes, and clearinghouse deposit/withdraw before the carry base/rate denominator changes; deposits may collect realized carry from post-deposit settlement in the same transaction, while withdraws realize carry before reducing settlement
- destination: realized carry becomes LP trading revenue
- health isolation: project carry against eligible free settlement first. Fully funded carry does not reduce exact
  price-risk health; any uncovered remainder blocks withdrawal and independently makes the account liquidatable.
  PnL pledge plus same-account claim remains exclusive to exact price risk and cannot offset residual carry

Close and liquidation security depends on using the planner's canonical carry-adjusted settlement outputs directly in the live executor rather than recomputing a second carry-blind kernel.

Security implication: oracle freshness still gates execution and LP accounting freshness, but not carry accrual.

### Trader claim liabilities

Terminal transitions are fail-soft when the HousePool lacks immediate cash.

- profitable closes can leave senior trader claim balances,
- trader claim balances are beneficiary-balance based rather than FIFO queue based,
- they remain part of reserve and solvency accounting until paid,
- terminal full-close settlement may waive an uncollectible frozen-close spread, but that waived amount is neither a trader claim nor a protocol liability.

This preserves risk reduction and liquidation liveness under temporary cash shortfall.

### Explicit netting boundary

Same-account trader claim balance is price-risk backing, not generic cash or action collateral.

- open/increase, trader-withdraw, close, and liquidation health use the exact same-account price-risk cap:
  `pnlPledgeUsdc + traderClaimBalanceUsdc`; VPI never adds to or subtracts from this price-risk equity,
- the separately funded VPI reserve backs only that account's typed VPI obligation: overfunding never adds price
  collateral, while backing below `max(-vpiAccrued, 0)` independently blocks withdrawal and makes the account
  liquidatable,
- the terminal book includes the claim in that same account's collectible price-loss cap,
- terminal settlement paths may explicitly net the same-account claim once against that account's exact price loss,
- the claim is not withdrawable cash and cannot fund carry, VPI, execution fees, frozen spread, liquidation charges,
  order margin, or other action obligations,
- when a claim is physically paid while its beneficiary has a live position, the credit goes directly to PnL pledge
  and the curve cap is resynchronized; crediting free settlement would allow withdrawal and double use,
- this avoids accidentally reusing a pool IOU as immediately spendable account cash.

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

### Seed and senior-capacity lifecycle gate

The protocol blocks normal live operation until governance finalizes a finite absolute senior limit and a senior-share
limit below 100%, both tranche seeds exist within those limits, and trading is explicitly activated.

This prevents partially initialized or uncapped live state and ambiguous ownership of early revenue flows.

### LP request cutoff and monitoring boundary

For `e = floor(block.timestamp / 3,600)` and next round-hour boundary `b = (e + 1) * 3,600`, every Senior deposit,
Junior deposit, Senior redemption, and Junior redemption targets `e + 1` before `b - 300` and `e + 2` at or after
`b - 300`. Equality deliberately belongs to the later epoch. The cutoff's incremental effect on an otherwise-valid
request is a one-epoch delay, not asset loss or a new revert; ordinary request gates remain active. Sequencer
inclusion time is authoritative, so a pending transaction may land on either side.

This creates a five-minute **maximum-membership** quiet period for the epoch about to mature. It is not an immutable
settlement snapshot:

- eligible cancellations can reduce deposit or redemption totals in the locked epoch,
- trading, closes, liquidations, claims, carry, and pool accounting can change NAV,
- governance configuration may change if an already-matured proposal is finalized,
- oracle state and confidence can change, and
- cancellation in one tranche or direction can change capacity available to later settlement phases.

Monitoring must therefore simulate current state and treat cutoff-time request totals as upper bounds. In particular,
the conservative case assumes all redemptions remain and no helpful deposits activate. Cancelling Senior redemptions
may expose more Junior funding, while cancelling Junior deposits may prevent a Senior deposit from fitting. Indexing,
alerting, sequencer publication, and transaction inclusion also consume part of the nominal five minutes, so the
operational reaction window is shorter. `SettlementMonitorLens` reads an explicitly observed epoch so a monitor can
keep following the closed batch after the request target rolls forward. That argument does not select what the Router
settles; eligible FIFO heads remain authoritative. `observableConfigDigest()` and the `observationDigest` returned by
`getSettlementObservation(observedEpoch)` help detect off-chain drift. `completeObservationDigest` repeats that hash
only when `observationComplete` and is otherwise zero, but it remains unauthenticated. None is a trusted batch commitment
and the Router does not accept or enforce them. This cutoff and lens add no signature, challenge period, settlement
hold, or trading freeze.

### Settlement-monitor trust boundary

`SettlementMonitorLens` is a read-only, bounded operator/security surface. `getSettlementStatus(observedEpoch)`
separates operational blockers, warnings, and deposit deferrals; `getSettlementHealth()` separately reports critical
faults and dependency-read failures. A reverted or malformed dependency read is unknown state, never a healthy zero.
Its checks can detect observable wiring, epoch-window, NAV aggregate, pool-backing, vault-escrow, and seed-floor
failures, but they do not enumerate accounts, radix nodes, or unbounded queues and cannot prove per-account
terminal-curve parity. `executionPathDependencyMask` is the narrow subset of status read failures that makes the
cached-mark versus atomic-refresh route unknown; `dependencyFailureMask` remains the complete status read-failure
set. Canonical matured-head getters are the sole route evidence: auxiliary lifecycle, link, membership, or endpoint
corruption degrades health without replacing a route that is still known, while impossible canonical head pairs are
critical. Projected deposit deferrals combine the tranche-neutral
`HousePool.canSettleDepositEntries()` pre-redemption projection with canonical redemption evidence, so residual
pending claimants remain visible even when an epoch's queued assets are zero. The Lens does not confirm either
tranche's activation while matured Senior funding can still change principal/HWM rounding, or Senior activation while
matured Junior funding can reduce reservation capacity. HousePool rechecks the exact gates after redemption funding;
this prevents a zero-fee
virtual-offset rounding transition from admitting deposits into newly impaired Senior accounting. The view does not
quote new-request capacity. The facade constructor rejects a Router whose immutable settlement pool differs from
`Engine.pool()` and deploys a code-size sidecar whose diagnostic builders accept only the constructor-bound
facade; its constructor-set binding getters remain publicly readable and it has no setter or delegatecall path. That
sidecar is a monitor-bound implementation detail, not another trusted public result surface.

The sidecar pins the Engine planner address and code hash at construction and probes the planner's canonical
carry-index and market-calendar ABIs before treating wiring as healthy. Seed receiver/floor settings must be consistently zero/zero or
nonzero/nonzero. Because the facade embeds the sidecar's creation code, EIP-3860 creation-input size is a release
constraint in addition to each contract's EIP-170 runtime limit.

Normal monitoring should poll the lighter `getSettlementStatus(observedEpoch)` view. The composite
`getSettlementObservation(observedEpoch)` is designed for checkpoints and alert investigation: its ABI return is
roughly 6 KB and representative `eth_call` execution is about 0.8–1.3 million gas. The Senior deposit-deferral mask
describes whether pending activation or existing reservation limits are blocked, not how much new Senior capital can
be admitted; use the canonical admission-capacity view for a new request.

`getPoolReconcileOracleStatus()` describes feeds readable at the observation block. It cannot certify a future Hermes
payload or the fee and publish times used by a later transaction. It requires the updated
`PletherOracle.getLatestPoolReconcilePrice()` return ABI; an older configured oracle causes a fail-soft Oracle
dependency failure rather than fabricated zero-valued feed health. Every Oracle dependency read must succeed for
`observationComplete`, even when the execution route is cached mark or no work; Oracle `policyValid` is required for
completeness only when atomic refresh is the selected route. Thus an older Oracle ABI always leaves
`completeObservationDigest == 0`, while a readable but currently stale or low-confidence feed need not invalidate a
cached/no-work checkpoint. Reported confidence is for the neutral pre-cap basket, but the returned mark can be capped,
so recomputing the ratio against `markPrice` is not always an independent policy check. Likewise, the reported
required execution path is advisory rather than an authoritative `canSettle` result. Keepers must quote and simulate the exact
`OrderRouter.settleLpEpoch(bytes[])` calldata and `msg.value`; the Router and EVM rollback frame remain the execution
authority.

### Freshness-gated LP actions

When marks are stale and freshness is required:

- live open-position epoch settlement is available only through `OrderRouter.settleLpEpoch(bytes[])`, which validates a
  `PoolReconcile` Pyth basket and installs the exact Engine mark before the Router-only HousePool callback,
- the basket's earliest component publish time must be at or after the current round-hour boundary, so a still-fresh
  pre-boundary tick cannot price a newly matured batch,
- stale, low-confidence, future, divergent, or out-of-order data reverts the whole call; already-funded claims remain
  live and pending requests remain queued,
- no pending epoch bucket advances on a rejected live call; only claims funded by an earlier successful settlement
  remain independently callable,
- fresh oracle publication is the recovery path.

Exception: once the protocol enters `oracle frozen`, eligible synchronized settlement remains live under fixed
stale-price surcharges instead of hard-blocking immediately. Deposit activation keeps the ordinary lifecycle,
bootstrap, and Senior-impairment gates. Claims never reprice or reassess the fee fixed when a request was funded.
Direct cached-mark settlement is otherwise limited to the no-open-position case, where NAV is mark independent.

Pool pause blocks new deposit requests and deposit activation, but it does not block redemption requests or reconciled
funding of already-matured redemptions. The settlement result marks entries deferred, and already-funded claims remain
live.

### Senior coupon model

Senior coupon is funded from existing junior NAV and capped by available junior principal.

This removes unpaid senior-coupon debt queues while making the cost of the fixed senior product explicit for junior LPs.

### Senior exposure limits and passive overage

Active protected senior exposure is `E = max(projected senior principal, projected senior high-water mark)`. Counted
admission exposure is `C = E + R`, where `R` is the gross USDC reserved in unfinalized senior deposit epochs. The
absolute and share admission tests use `C`, while the Junior redemption-funding covenant deliberately uses active `E`
only.
Governance sets both an absolute USDC limit and a maximum share of senior-plus-junior claimant capital. The high-water
term prevents an impaired principal balance from falsely reopening capacity while its restoration entitlement remains.

Senior deposit reservations are provisional. They consume quoted headroom when requested, but the whole outstanding
reservation book is checked again at finalization. If a timelocked cap reduction or later accounting change makes the
book invalid, finalization remains blocked and post-maturity cancellation is unlocked so depositors can recover the
escrowed USDC. Junior redemption funding does not lock against `R`, so a permitted fill can also invalidate the
provisional book and make it refundable. Integrators must not present a request-time quote as guaranteed finalization.

The covenant also limits Junior redemption funding; using active `E` and explicitly excluding pending reservations,
the pool retains enough projected Junior principal that the configured Senior share still holds after the fill.
This is an LP-liquidity restriction, not an extra source of cash or a guarantee that losses cannot impair senior.

Coupon, loss allocation, revenue restoration, and privileged claimant recapitalization remain higher-priority
accounting rules. They may passively move the pool above a configured limit, but the protocol does not haircut active
senior shares, suppress coupon already payable from junior, or misroute loss to force compliance. Instead, new senior
capacity closes until funded Senior redemptions, Junior deposits, or subsequent revenue cure the state. The engine-authorized
`recordClaimantInflow(..., Recapitalization, ...)` path is deliberately exempt when restoring protected senior claims;
it cannot mint new senior LP shares, and excess value continues through the canonical claimant/unassigned routing.

## Liquidation Security

### Full liquidation only

Liquidations always close the entire position.

Trade-off:

- simpler accounting and fewer liquidation games,
- no partial-liquidation recovery path for oversized positions.

### Reachability and bounty bounds

- liquidation accounting is constrained by actually reachable collateral,
- the proportional liquidation charge has a floor, is capped by reachable value, and may explicitly subsidize
  low-equity liquidations,
- the collected charge is conserved across a bounded, timelocked allocation where
  `keeperShareBps + protocolShareBps <= 10_000`: the keeper and protocol treasury each receive their independently
  rounded-down configured shares as clearinghouse credit, and LPs receive the exact remainder, including rounding dust,
  as claimant revenue,
- residual trader value is preserved when positive,
- same-account trader claim balance is not generic liquidation collateral, but it is included in that account's
  terminal collectible cap and netted once against exact price loss,
- uncollateralized position price loss above the PnL cap is reported as a diagnostic write-off and is not socialized
  as LP debt or terminal deficit.

### Queue interaction during liquidation

Liquidation performs bounded account-local cleanup of that account's pending orders.

This preserves terminal liveness without requiring an unbounded global queue scan.

Batch liquidation validates and pays for one shared Pyth snapshot, updates the neutral mark once, and isolates each
account in its own rollback frame. Solvent and positionless accounts are skipped without losing prior successes, while
the returned cursor leaves any low-gas or empty-revert item unattempted so a keeper can resume safely.

## Known Limitations

### Oracle and market-closure limitations

- frozen-oracle windows prioritize close liveness over live-market-style freshness guarantees,
- oracle-frozen voluntary close/reduce execution applies normal signed VPI plus a fixed LP-owned notional spread; normal live and FAD-only closes apply signed VPI without that spread,
- a fixed spread deliberately does not increase with mark staleness inside the permitted frozen window,
- full-close liveness takes priority over collecting an otherwise uncollectible spread; partial closes retain
  all-or-nothing rules for required charges but do not fail solely on uncollateralized price loss above the PnL cap,
- the recurring FX calendar follows New York daylight-saving transitions on-chain; unscheduled provider closures and
  holiday hours still require governance-configured UTC-day overrides,
- the current post-2007 US daylight-saving rule is compiled into the planner; a future legal or provider schedule
  change at an intraday boundary requires a coordinated engine/planner/oracle deployment,
- execution remains dependent on fresh keeper infrastructure and oracle publication outside frozen windows.

### Router and keeper limitations

- users cannot manually cancel queued intents,
- bounded cleanup means heavily expired queues may take multiple keeper calls to clear,
- per-account pending-order caps bound griefing and liquidation cleanup now stays on bounded account-local order traversal,
- failed orders remain terminal rather than retryable.

### LP accounting limitations

- exact terminal NAV is only as current as its authenticated mark; live open-position epoch settlement requires an
  atomically validated post-boundary mark, while frozen exits deliberately use the cached stale-window mark,
- a positive marked receivable is not cash, so share NAV can exceed immediately redeemable liquidity,
- `TerminalNavBookV2` is intentionally non-upgradeable and has no owner repair path; a book/Engine invariant failure
  requires containment and a fresh-stack deployment rather than an in-place edit,
- `oracleFrozen` keeps eligible synchronized LP settlement live under fixed tranche-local frozen fees rather than a
  separate stale-action gate for exits; redemption funding is allowed to proceed while entry activation is deferred,
- each bounded live backlog pass pays a Pyth update fee and may use a later valid post-boundary mark than the previous
  pass; atomicity binds one call, not an arbitrarily large backlog,
- senior coupon payments are capped by available junior principal,
- governance can prospectively reduce senior limits below live exposure, closing new senior entry and potentially
  reducing Junior redemption-funding capacity until the covenant is cured; it cannot force existing Senior capital out,
- pending senior reservations are not grandfathered against later cap or accounting changes, but become refundable if
  they no longer fit at finalization,
- deposit cooldown can be griefed only by economically irrational donation-style top-ups.

### VPI limitations

- liquidation does not compute a fresh VPI delta, but the gross negative accrued VPI clawback is settled from its
  dedicated reserve or equivalent withheld trader gain before residual planning,
- VPI depends on live pool depth,
- voluntary closes use the same signed VPI curve and lifetime rebate clamp in live, FAD-only, and oracle-frozen regimes,
- frozen-market stale-price protection is a fixed notional spread that leaves VPI unchanged and replaces, rather than compounds with, the Pyth adverse-confidence price shift for oracle-frozen voluntary closes only,
- the lifetime clamp intentionally zeroes otherwise extractable rebate-only round trips,
- partial-close VPI release is a bounded linear approximation.

### Clearinghouse limitations

- V1 is USDC-only cross-margin,
- non-USDC collateral pricing and staleness policy are intentionally out of scope.

## Emergency Procedures

The canonical operator capability matrix, trigger policy, containment procedure, recovery criteria, and off-chain
guardian design requirements live in [EMERGENCY_RESPONSE_GUIDE.md](EMERGENCY_RESPONSE_GUIDE.md). Read that guide
before automating any response from `SettlementMonitorLens`.

### Emergency pause

1. Corroborate the unsafe observation from block-pinned direct reads and an independent provider when time permits.
2. Have the guardian simulate and call the coordinator so Router risk-off and HousePool entry pause activate
   atomically.
3. Verify both pause states, the permanent inclusive order cutoff, and the emitted incident hashes.
4. Keep closes, liquidations, mark refresh, redemption requests, eligible redemption funding, funded claims, and
   incident cleanup operating.
5. Governance investigates and recovers deliberately; the guardian never auto-unpauses.

Monitoring should page operators before applying a breaker. An observable NAV or custody invariant failure warrants
pausing new risk and LP entry while preserving protective exits where protocol policy allows them. Oracle-read
failure is transient until corroborated; queue backlog, Senior priority, capacity, and insufficient free cash are
liveness states rather than accounting corruption. `SettlementMonitorLens` cannot pause anything itself. A critical
fault also makes the composite observation incomplete, so automation must inspect masks individually rather than
watching only the complete-observation digest.

### Suspected oracle issue

1. Distinguish a confirmed correctness/integrity problem from routine staleness or low confidence that the on-chain
   policy already rejects.
2. For a credible integrity incident, use composite containment to stop both new trading risk and new LP entry.
3. Preserve protective flows and archive the raw signed update plus independent market evidence.
4. Governance resumes only after feed bindings, behavior, and canonical accounting are understood.

### Keeper outage

1. Orders accumulate in the queue.
2. Users cannot manually cancel them.
3. Restart keeper infrastructure.
4. Expect bounded cleanup rather than instant queue drain.

### Explicit terminal-deficit cascade

This runbook concerns actual negative terminal LP equity or trader payout claims that physical cash cannot currently
service. A terminal price-loss write-off above an account's collectible cap and a waived terminal action remainder
create neither condition; V2 has no accumulated-debt ledger to clear.

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
- import external smart-contract and credit-loss contagion,
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

The perps system has completed one external pre-audit / security consultation, but has not completed a formal production audit. It remains pre-deployment.

### SC Audit Studio Pre-Audit (April-May 2026)

**Auditor:** SC Audit Studio OY (Linus L. / oot2k, Ihtisham U. / ihtishamSudo)  
**Review period:** April 14-May 4, 2026  
**Report date:** May 4, 2026  
**Reviewed commit:** [`fc5f03ba8b91e879e0fa7f0d9be208d4c518a305`](https://github.com/Plether-Fi/plether-core/commit/fc5f03ba8b91e879e0fa7f0d9be208d4c518a305)
**Resolution commit:** [`86263b00b6f92301c4cb62fa0aab4317f0cbe7cd`](https://github.com/Plether-Fi/plether-core/commit/86263b00b6f92301c4cb62fa0aab4317f0cbe7cd)
**Report:** [`audits/plether-pre-audit-report.pdf`](../../audits/plether-pre-audit-report.pdf)

This engagement was a pre-audit consultation intended to challenge the protocol design, find obvious security issues, improve code quality, and prepare the codebase for a later formal audit. Although it should not be treated as a production-readiness endorsement, it was performed to assess and improve readiness for testnet deployment.

Findings summary:

| Severity | Count |
|----------|-------|
| High | 2 |
| Medium | 7 |
| Low | 1 |
| Informational | 18 |

The review also produced code-quality and architecture recommendations. The most important outcomes were fixes or mitigations for LP yield dilution, zero-value withdrawal cooldown griefing, oracle-frozen liquidation liveness, same-side increase dust handling, rebate-backed undercollateralized opens, stale senior-yield accrual, oracle-window option value, queue dust DoS, and pending claimant accounting.

Several items were intentionally acknowledged or left for follow-up rather than fully redesigned in this pre-audit cycle:

- `CAP_PRICE` is immutable and cannot be changed after deployment.
- Users cannot manually cancel committed queued orders.
- Bounty and deferred payout accounting could be simplified further.
- Some broader HousePool/ERC-4626 architecture and test-suite organization recommendations remain open.
- Large fixes, especially the senior accounting rewrite and oracle-window mitigation, should receive follow-up formal audit coverage.

As of May 21, 2026, `master` includes the resolution commit and later changes. Future releases should be assessed against their exact deployment commit.

| Component | Status |
|-----------|--------|
| `CfdEngine` | Pre-audit reviewed; formal audit pending |
| `CfdMath` | Pre-audit reviewed as supporting logic; formal audit pending |
| `OrderRouter` | Pre-audit reviewed; formal audit pending |
| `MarginClearinghouse` | Pre-audit reviewed; formal audit pending |
| `HousePool` | Pre-audit reviewed; formal audit pending |
| `TrancheVault` | Pre-audit reviewed; formal audit pending |
| `SettlementMonitorLens` and monitor-bound sidecar | Read-only monitoring addition; formal audit pending |
| `EmergencyPauseCoordinator` and persistent Router risk-off refund path | Emergency containment addition; formal audit pending |

## Security Contact

For responsible disclosure:

`contact@plether.com`

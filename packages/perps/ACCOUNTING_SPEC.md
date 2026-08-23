# Perps Accounting Spec

This document defines the accounting model for the Plether perps system.

It is the source of truth for:

- solvency,
- LP redemption-funding limits,
- close and liquidation settlement,
- trader claim liabilities,
- clearinghouse reservation treatment,
- LP-capital carry.

Use it together with:

- [`README.md`](README.md) for the system overview,
- [`SECURITY.md`](SECURITY.md) for invariants and trust assumptions,
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md) for the custody map,
- [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md) for the consolidated policy tables, quantity ownership table, and transaction narratives.

## Accounting Model In One Page

The protocol deliberately keeps several different accounting views instead of trying to collapse everything into one notion of equity.

The key rules are:

1. Physical USDC and mathematical claims are different objects.
2. Unrealized trader losses are not LP assets until they are physically realized.
3. LP redemption funding is stricter than protocol solvency.
4. Pending-order reservations are not free trader collateral.
5. Realized trading-loss shortfall must become either immediate seizure, trader claim liability, or bad debt; a waived terminal frozen-close spread is an uncollected charge, not trading-loss bad debt.
6. A valid risk-reducing transition must not revert just to preserve pre-close solvency; the protocol contains the outcome with `degradedMode` instead.
7. Frozen-close spread value belongs to LPs and must never be credited to protocol treasury.

## Canonical Quantities

All quantities are in 6-decimal USDC unless stated otherwise.

### Physical asset terms

Use these terms consistently:

- `rawAssets`: literal USDC token balance held by `HousePool`
- `accountedAssets`: canonical protocol-owned USDC recognized by pool accounting
- `excessAssets = max(rawAssets - accountedAssets, 0)`: unsolicited or otherwise unaccounted positive balance
- `physicalAssets = totalAssets() = min(rawAssets, accountedAssets)`: conservative economic pool backing
- `protocolTreasuryBalance = clearinghouse.balanceUsdc(protocolTreasury)`: cash-realized protocol-owned inventory held as treasury margin in `MarginClearinghouse`, not LP equity
- `netPhysicalAssets = max(physicalAssets - protocolTreasuryBalance, 0)`: protocol/lens diagnostic quantity exposed by accounting snapshots when treasury margin should be excluded from protocol-owned pool depth

Operational rules:

- unsolicited positive transfers do not become economic depth until explicitly admitted,
- raw-balance shortfalls reduce effective backing immediately,
- all core accounting paths should read canonical physical assets rather than raw token balance,
- live HousePool redemption-funding and reconcile kernels start from `physicalAssets` and subtract explicit reserve
  buckets; they do not implicitly reserve `protocolTreasuryBalance`.

### Liability terms

- `bullMaxProfit`: worst-case payout to all live BULL positions at one price extreme
- `bearMaxProfit`: worst-case payout to all live BEAR positions at the opposite price extreme
- `maxLiability = max(bullMaxProfit, bearMaxProfit)`
- `badDebt`: realized shortfall that could not be covered by reachable account value or available settlement paths

### Frozen-close spread terms

- `frozenSpreadUsdc`: fixed spread assessed on the reduced position notional for a voluntary close/reduce while `oracleFrozen`
- `frozenSpreadPaidUsdc`: assessed spread actually retained or collected as LP trading revenue
- `frozenSpreadWaivedUsdc`: uncollectible assessed spread waived to let a terminal full close complete

For a valid close plan, `frozenSpreadUsdc == frozenSpreadPaidUsdc + frozenSpreadWaivedUsdc`. All three values are zero for live and FAD-only closes. Liquidations never assess this spread.

### Conservative unrealized MtM

For LP accounting, unrealized trader profits may be recognized as liabilities, but unrealized trader losses must not be recognized as present assets.

Definition:

- compute a side-local upper bound from cached max-profit exposure,
- for BULL, scale side max profit by `(CAP_PRICE - markPrice) / CAP_PRICE`,
- for BEAR, scale side max profit by `markPrice / CAP_PRICE`,
- sum the two conservative side liabilities.

This quantity is appropriate for conservative LP equity and tranche reconciliation, not for pretending the pool has already collected losing traders' money. It can temporarily over-reserve LP value when entry prices are dispersed inside a side, but it avoids netting winners against uncollected same-side loser debt.

## The Four Core Accounting Views

The engine needs separate views because different actions answer different questions.

### 1. Risk-increasing solvency view

Question answered:

- may the protocol accept more risk right now?

Definition:

- start from `physicalAssets`,
- subtract existing trader claim liabilities when deriving effective solvency assets,
- compare post-op assets to post-op `maxLiability`.

Rule:

- a risk-increasing action is allowed only if post-op effective solvency assets remain at least as large as post-op bounded liability.

Notes:

- this view does not rely on speculative receivables,
- it must not count unrealized trader losses as spendable assets,
- it is less conservative than LP withdrawal accounting, but still bounded and physical-first.

### 2. LP redemption-settlement view

Question answered:

- how much USDC may the next synchronized settlement commit to matured LP redemptions?

Definition:

```text
freeUsdc = physicalAssets - withdrawalReservedUsdc
```

Where `withdrawalReservedUsdc` is built from the canonical reserve model, including at least:

- bounded trader liability,
- trader claim balance,
- supplemental withdrawal reserves,
- pool-level pending claimant and unassigned-asset reservations where applicable.

Rule:

- matured LP redemptions may be funded only from conservative free cash. Senior demand is funded first. Junior demand
  uses only the remainder and must also preserve the active Senior-share covenant.

Notes:

- this view is intentionally stricter than solvency,
- it ignores uncollected trader debts as a cash source for withdrawal.
- dormant Senior NAV is not reserved merely because it exists; only eligible matured Senior demand has priority over
  Junior demand,
- deposit assets finalized later in the same synchronized transaction are not a funding source for withdrawals,
- funded assets leave `HousePool` for vault claim escrow and cannot be counted as free cash again,
- during `oracleFrozen`, the settlement-time output is reduced by the tranche's frozen-window surcharge rather than
  hard-blocking automatically.

### 3. LP reconciliation and deposit-pricing views

Question answered:

- what is tranche equity for share pricing and revenue distribution?

Withdrawal/reconcile definition:

- start from `physicalAssets`,
- subtract trader claim liabilities,
- apply conservative unrealized MtM liability only,
- do not book unrealized trader losses as assets.

Deposit/mint pricing definition:

- start from the same physical assets, trader-claim liabilities, claimant buckets, recapitalizations, and revenue state,
- ordinary LP entry always starts with an asynchronous deposit request: assets are funded up front, cancellation is
  unconditional before activation and, after activation, reopens when Senior impairment blocks finalization or a
  Senior reservation book no longer fits its governed limits,
- `HousePool.settleLpEpoch` fixes the epoch price after both redemption phases and activates Junior deposits before
  Senior deposits; ERC-4626 `deposit` and `mint` only claim already-activated requests,
- a settlement pass that advances no queue item reverts, so its reconcile and carry checkpoints cannot be retained by
  a permissionless no-op caller,
- permissionless settlement can still be ordered before a later close or liquidation realizes trader losses into pool
  cash; the request activation delay prevents a depositor from creating and pricing an uncommitted same-block entry,
- do not subtract unrealized MtM liability unless it comes from an exact, non-manipulable deposit-side model,
- realized pool losses still lower deposit NAV,
- conservative unrealized MtM remains a withdrawal protection, not a discount offered to incoming LPs.

Rules:

- over-recognition is forbidden,
- temporary under-recognition is acceptable,
- value with no valid claimant path must sit in explicit `unassignedAssets`.
- during `oracleFrozen`, synchronized redemption funding and deposit activation apply fixed tranche-local LP
  surcharges instead of requiring an ordinary live-market mark,
- during `oracleFrozen`, bootstrap admin flows (`initializeSeedPosition`, `assignUnassignedAssets`) are blocked rather than inheriting LP frozen-fee pricing.

Required consequences:

- `unassignedAssets > 0` blocks new tranche-deposit requests and activation,
- a wiped tranche cannot be silently revived by an ordinary asynchronous deposit,
- seeded ownership continuity is preferred over governance re-assignment.

### 3.1 Senior exposure admission limits

Let:

- `S` be projected senior principal after the conservative reconcile used by senior admission,
- `H` be the projected senior high-water mark,
- `J` be projected junior principal,
- `R` be gross USDC reserved by all unfinalized senior deposit requests,
- `E = max(S, H)` be active protected senior exposure,
- `C = E + R` be counted senior admission exposure,
- `A = maxSeniorExposureUsdc`, and
- `B = maxSeniorShareBps`, where finalized governance requires `A` to be finite and `B < 10_000`.

New senior exposure is admissible only while both conditions hold after the action:

```text
C <= A
C * 10_000 <= B * (C + J)
```

Equivalently, before a new deposit and for nonzero `B`, ratio headroom is bounded by
`floor(J * B / (10_000 - B)) - C`, saturated at zero. The active senior capacity is the smaller absolute and ratio
headroom. A zero `B` permits no positive senior exposure. Raw cash, unassigned assets, trader balances, and pending
junior deposits do not count as junior subordination.

Rules:

- a pending senior request adds its gross assets to `R`, preventing parallel epochs from overbooking the same capacity,
- finalization revalidates the complete reservation book against current accounting and the active limits before it
  atomically releases the reservation and adds the same gross amount to active senior principal,
- reservations are provisional rather than grandfathered: if a governance reduction, coupon, loss, or junior-capital
  change makes the book invalid, post-activation cancellation is enabled so owners can recover escrowed assets,
- funded junior redemptions of net assets `w` must additionally preserve
  `E * 10_000 <= B * (E + J - w)` using active protected exposure only; reservations do not lock junior liquidity, so
  permitted Junior funding may instead invalidate provisional reservations and make them refundable,
- funded Senior redemptions and Junior deposits improve capacity and may cure an overage,
- governance reductions are prospective for active claims: existing senior shares are not burned, repriced, or forced
  out, while new senior capacity remains zero until the state returns within both limits.

The limits are admission controls, not alternate waterfall arithmetic. Junior-funded coupon, junior-first loss,
revenue restoration, and privileged recapitalization continue under their ordinary priority rules even if they create
or deepen a passive overage. In particular, claimant recapitalization recorded through
`recordClaimantInflow(amount, Recapitalization, cashMode)` may restore an existing protected senior entitlement above
a reduced limit; it mints no new senior LP shares. Assigning ownerless `unassignedAssets` to senior or creating a
senior seed does create new senior shares and goes through the same admission checks. Constructor-neutral limits make
those checks permissive during bootstrap, but trading activation requires finite active limits and a compliant seeded
capital structure; once those finite limits are active, later senior assignment and seeding are directly bounded.

### 4. Trader reachability / terminal settlement view

Question answered:

- what value is actually reachable from this account for close, liquidation, and generic health checks?

Rules:

- use physically reachable clearinghouse collateral for generic views and withdraw checks,
- same-account trader claim balance is a separate explicit netting bucket rather than generic collateral,
- liquidation and close settlement must cap seizure and payout logic by actually reachable value,
- pending-order reservations and execution bounty reserves must be handled explicitly rather than assumed to be free cash.

## Snapshot Boundaries

Snapshot structs are boundary objects between engine accounting and downstream consumers.

### `HousePoolInputSnapshot`

Purpose:

- canonical accounting payload for LP redemption funding and tranche reconciliation. Live LP kernels consume
  `physicalAssetsUsdc` plus explicit reserve fields; `netPhysicalAssetsUsdc` is exposed for protocol and read-layer
  parity where treasury margin should be excluded.

Key fields:

- `physicalAssetsUsdc`
- `netPhysicalAssetsUsdc`
- `maxLiabilityUsdc`
- `supplementalReservedUsdc`: reserved extension slot for LP-withdrawal accounting; currently zero in the carry model
- `unrealizedMtmLiabilityUsdc`
- `traderClaimBalanceUsdc`
- `markFreshnessRequired`
- `maxMarkStaleness`

Rule:

- downstream LP accounting should not need to re-derive these values from raw engine state.
- the request delay and synchronized activation replace the old instant-deposit gate; no ordinary request mints active
  shares in the submission transaction.

### `HousePoolStatusSnapshot`

Purpose:

- non-accounting liveness flags for LP actions.

Key fields:

- `lastMarkTime`
- `oracleFrozen`
- `degradedMode`

Rule:

- keep status gating distinct from accounting insufficiency.

## Frozen-Window LP Fees

The protocol keeps eligible LP actions live during `oracleFrozen` by charging fixed stale-price surcharges rather than
fully disabling entry and queued-redemption settlement.

Default configured fees:

- senior tranche: `25 bps`
- junior tranche: `75 bps`

Governance model:

- `HousePool` governance may update these fees through the same 48-hour timelock pattern used for other LP-facing config,
- the active fee is zero whenever `oracleFrozen == false`, even during the FAD-only shoulder windows.

Accounting rules:

- synchronized activation moves requested gross USDC into the tranche and fixes claimant shares after the active
  frozen fee; `deposit` and `mint` only release already-activated claim shares,
- a redemption request escrows shares without fixing its exchange rate or fee; pending shares remain outstanding and
  participate in tranche profit and loss,
- synchronized settlement prices funded shares from the post-reconcile, pre-burn tranche snapshot using the existing
  ERC-4626 virtual offsets, applies the then-active frozen fee, burns only shares with nonzero net output, and escrows
  exactly the resulting net assets,
- `withdraw` and `redeem` only release already-funded escrow and do not reprice or reassess a fee,
- the fee does not become protocol revenue,
- the fee does not increase `protocolTreasuryBalanceUsdc`,
- the fee remains inside the same tranche and therefore benefits incumbent LPs of that tranche only.

Async allocation dust is resolved only after every controller's entitlement is accounted for:

- each controller receives a floor-rounded pro-rata allocation from the fixed epoch totals; splitting one request
  across controllers cannot increase aggregate entitlement because the sum of individual floors cannot exceed the
  floor of the combined allocation,
- terminal deposit-share dust is removed from claim escrow, booked into `epoch.claimedShares`, and burned,
- terminal funded-redemption share dust was already burned during funding and is booked into `epoch.claimedShares`;
  corresponding asset dust is removed from withdrawal escrow and returned raw to `HousePool` without increasing
  `accountedAssets`, so it becomes pool excess,
- terminal refundable-redemption share dust is booked into `epoch.refundedShares` and transferred to the permanent
  seed account without resetting that account's cooldown.

Consequences:

- senior frozen-window actions must not reprice junior shares,
- junior frozen-window actions must not reprice senior shares,
- pending-request estimate views must reproduce the settlement conversion and fee rounding without promising a fixed
  future rate,
- asynchronous `previewWithdraw` and `previewRedeem` revert; `maxWithdraw` and `maxRedeem` expose only funded claim
  capacity.

### Preview and simulation solvency outputs

Purpose:

- tell integrators whether an action is legal, whether it newly degrades the protocol, and what the raw post-op solvency looks like.

Required fields:

- `effectiveAssetsAfterUsdc`
- `maxLiabilityAfterUsdc`
- `postOpDegradedMode`
- `triggersDegradedMode`

Rule:

- canonical preview reads live protocol depth,
- hypothetical simulation reads caller-supplied what-if depth,
- both must preserve the same economic stage ordering.

## Ownership Routing For Pool Inflows

Not every inflow into `HousePool` is LP equity.

Keep these categories separate:

- `recordClaimantInflow(amount, Recapitalization, CashArrived)`: recapitalization intended to restore waterfall claimants
- `recordClaimantInflow(amount, Revenue, CashArrived)`: claimant-owned value where fresh cash entered the pool in this flow
- `recordClaimantInflow(amount, Revenue, AlreadyRetained)`: claimant-owned value already retained physically by the pool and only needing ownership routing
- `accountExcess()`: owner-governed admission of unsolicited raw pool cash into canonical assets

Rules:

- source semantics decide the owner of the inflow,
- explicit cash inflow vs implicit retained value decides whether `accountedAssets` should increase,
- claimant continuity should prefer seeded ownership paths when available,
- only value with no safe claimant path belongs in `unassignedAssets`.

`unassignedAssets` should be exceptional telemetry, not a normal operating bucket.

## LP-Capital Carry

The protocol uses LP-capital carry instead of a side-to-side rate mechanism.

Definitions:

- `borrowBaseUsdc = max(positionMaxProfitUsdc - activePositionMarginUsdc, 0)`
- `sideBorrowBaseUsdc`: sum of open-position borrow bases for one side
- `sideUtilizationBps = min(sideBorrowBaseUsdc / poolAssetsUsdc, 100%)`
- `pendingCarryUsdc = borrowBaseUsdc * (currentSideCarryIndex - positionLastCarryIndex)`
- `unsettledCarryUsdc[account]`: carry that has been checkpointed at a basis change but not yet physically collected

Rules:

- carry accrues continuously by wall-clock time,
- carry does not pause when the oracle is stale or frozen,
- both sides pay when they have nonzero borrow base,
- pending carry reduces equity for guard and risk checks before realization,
- basis-changing settlement credits must checkpoint carry even when physical collection remains pending,
- carry is realized before margin, pool-asset, or risk-parameter mutations change the carry base/rate denominator,
- on deposit, realized carry may be collected from post-deposit settlement in the same transaction,
- on withdraw, carry is realized before settlement balance is reduced,
- liquidation does not have its own separate carry-realization path,
- realized carry is booked as LP trading revenue.

## Trader Claim Liabilities

The protocol supports fail-soft terminal settlement.

### Trader claim balance

- profitable closes and some liquidation residuals may create `traderClaimBalanceUsdc[account]`,
- only the beneficiary account owner may call `settleTraderClaim(account)`,
- settlement is all-or-nothing for the account claim once aggregate trader claim liabilities are fully cash-covered,
- settlement is credited into `MarginClearinghouse`.

Rules:

- trader claim liabilities are beneficiary-balance based, not FIFO queue based,
- trader claim liabilities are senior claims on pool cash,
- trader claim servicing is frozen entirely while physical pool cash is below aggregate trader claim liabilities,
- fresh payout funding, protocol fee top-ups, and claim servicing must all agree on what pool cash is actually free,
- protocol fee top-ups are subordinate to trader claims and immediate trader payouts; any fee amount that cannot be cash-credited under this priority is not recorded as a protocol fee receivable.

## Pending-Order Reservation Model

Question answered:

- what value is reserved for queued actions and therefore not free to withdraw or reuse?

Reservation / reservation buckets include:

- committed order margin,
- clearinghouse-reserved execution bounty value.

Rules:

- reserved value is not withdrawable,
- reserved value is not free buying power,
- reserved execution bounty value is not reachable collateral for unrelated close losses,
- releasing or consuming reservation must happen exactly once,
- clearinghouse reservation records are the source of truth for committed trader margin,
- execution bounty reserves are not LP cash and should not become a pool liability bucket.

### Close-order bounty policy

- close intents may source their flat clearinghouse-reserved bounty from active position margin when free settlement is exhausted,
- this is an explicit bounded liveness tradeoff,
- partial close intents below the engine's minimum meaningful notional are rejected at commit time unless they fully close the queued residual position,
- `closeOrderExecutionBountyUsdc` is governance-configured but hard-capped at `1 USDC`,
- the amount parked in reservation is bounded by `MAX_PENDING_ORDERS * 1 USDC` per account,
- collateral reachability should treat that reservation as temporarily unavailable until the order resolves,
- terminal-invalid close execution pays the keeper from the clearinghouse-reserved bounty; liquidatable full closes may reserve that bounty only from free settlement, not active position margin.

### Open-order failure policy

- deterministic live-state open failures may be rejected at commit time,
- execution-time user-invalid opens pay the keeper from clearinghouse-reserved bounty value,
- genuine post-commit protocol-state invalidations pay the keeper from clearinghouse-reserved bounty value so FIFO head cleanup remains incentive compatible,
- typed engine policy categories, not raw revert selectors, should drive the split.

## Settlement Rules

Close and liquidation should share the same economic assumptions wherever the question is identical, and differ only where the product deliberately differs.

### Close settlement

Every voluntary close uses the normal signed VPI curve and the lifetime rebate clamp. While `oracleFrozen`, the same VPI result is combined with a fixed spread on reduced notional. `frozenCloseSpreadBps` defaults to `50` bps (0.50%), is part of the 48-hour timelocked engine risk config, must be nonzero, and is hard-capped at `1,000` bps (10%). For an oracle-frozen voluntary close, the spread replaces the Pyth adverse-confidence price adjustment and is allocated exclusively to LPs; live/FAD-only closes and liquidations retain adverse-confidence pricing.

When a close realizes a loss:

1. seize what is immediately collectible from reachable trader-owned value,
2. if this is a full close, same-account committed reservations may also be consumed through the clearinghouse reservation path before bad debt is recorded,
3. allocate collected close value according to settlement priority, with the frozen-close spread junior to the base close obligation,
4. if this is a partial close and any obligation remains unsettled, revert the partial close,
5. if this is a full close, waive any still-uncollectible frozen-close spread rather than converting it into bad debt,
6. record any remaining uncovered base trading-loss shortfall as explicit bad debt.

Required properties:

- a user must not partially close, externalize realized losses to LPs, and keep a protected residual alive,
- a user must not shield otherwise reachable settlement by parking it in queued committed margin right before terminal settlement,
- carry-adjusted close loss must be planned once and consumed live from that same canonical loss amount,
- retained, cash-collected, or same-account-claim-recovered frozen spread becomes LP revenue and never treasury margin,
- assessed spread must equal paid spread plus waived spread,
- preview and live close paths should share one close-accounting kernel and expose the same assessed/paid/waived result; successful nonzero assessments emit `FrozenCloseSpreadSettled`.

### Open projection

- skew-reducing rebates must count as reachable collateral for projected IMR checks,
- post-trade skew above the configured cap is allowed only while the open strictly reduces the existing imbalance
  without making the order side heavier; unchanged or worsening skew and above-cap sign flips remain invalid,
- open preview and execution should not reject a trade solely because the planner omitted a rebate that the live settlement would credit.

### Treasury fee withdrawals

- protocol fee withdrawal is a standard `MarginClearinghouse` withdrawal from the configured treasury account,
- `MarginClearinghouse.balanceUsdc(CfdEngine.protocolTreasury())` reports the configured treasury account balance,
- only cash-collected execution or liquidation fees and free-cash-funded top-ups become treasury margin,
- uncredited fee amounts are not withdrawable protocol inventory in the simplified treasury-margin model,
- frozen-close spread is LP-owned trading revenue and never becomes treasury margin,
- withdrawing treasury margin must not consume `HousePool` cash, trader claims, or LP withdrawal reserves.

### Liquidation settlement

Liquidation must:

1. seize reachable account value,
2. allocate the capped liquidation charge using the configured `keeperShareBps` and `protocolShareBps`, crediting the
   keeper and protocol-treasury shares through clearinghouse settlement and transferring the exact LP remainder to
   `HousePool` claimant revenue,
3. preserve residual trader value when positive,
4. realize remaining shortfall as bad debt,
5. delete the position,
6. re-evaluate degraded-mode containment.

Liquidation-charge rule:

- assess the configured `bountyBps` rate and `minBountyUsdc` floor as one total charge,
- cap the total charge by physically reachable liquidation collateral,
- require `keeperShareBps + protocolShareBps <= 10_000`,
- set `keeperAllocation = floor(totalCharge * keeperShareBps / 10_000)` and credit it to the keeper,
- set `protocolAllocation = floor(totalCharge * protocolShareBps / 10_000)` and credit it to the protocol treasury,
- allocate `totalCharge - keeperAllocation - protocolAllocation` to LPs so all rounding remainder belongs to LPs and
  the three destinations conserve the collected charge exactly,
- allow the total charge to exceed positive equity as an explicit liquidation subsidy,
- never cap by stale notions of notional or margin alone.

Required property:

- liquidation eligibility, charge caps, and residual planning must use carry-adjusted equity,
- negative accrued VPI must reduce liquidation equity before charge and residual planning,
- any charge assessed above positive equity must flow through the normal residual shortfall and bad-debt accounting,
- liquidation does not assess `frozenCloseSpreadBps`, including while `oracleFrozen`,
- preview and live liquidation should share the same liquidation-accounting kernel.

### Three-bucket liquidation residual accounting

Liquidation residuals must be modeled explicitly as:

- settlement retained on-ledger in the clearinghouse,
- existing trader claim balance consumed / remaining,
- fresh trader payout created by the liquidation itself.

This prevents overloading one residual bucket with multiple meanings.

## Degraded Mode

`degradedMode` is a containment latch, not a retroactive revert mechanism.

It must trigger whenever a realized transition leaves:

```text
effectiveSolvencyAssets < maxLiability
```

Allowed while degraded:

- closes,
- liquidations,
- mark updates,
- recapitalization,
- owner action to clear the mode after solvency is genuinely restored.

Blocked while degraded:

- new opens,
- other risk-increasing modifications,
- withdrawals that rely on position-backed equity.

Required properties:

- both close and liquidation re-check containment,
- preview and simulation should expose both `triggersDegradedMode` and `postOpDegradedMode`.

## Oracle And Freshness Policy

Freshness policy is action-specific.

### Opens and increases

- require fresh post-commit oracle data,
- stale data reverts and leaves the order pending.

### Closes

- in live markets, require fresh oracle data under the close execution rule,
- stale data is a keeper/oracle failure rather than a user failure,
- frozen-oracle windows use the dedicated frozen-market policy, including relaxed cross-feed publish-time divergence up to the frozen staleness window,
- normal signed VPI and the lifetime rebate clamp apply to voluntary close/reduce execution in every regime,
- during `oracleFrozen` only, voluntary closes assess the fixed LP-owned `frozenCloseSpreadBps` against reduced notional instead of applying the Pyth adverse-confidence price shift,
- live and FAD-only closes retain Pyth adverse-confidence pricing and assess no frozen-close spread,
- a terminal full close may waive uncollectible spread without creating bad debt, while a partial close must settle the full obligation.

### Liquidations

- use a stricter live-market freshness rule,
- may use relaxed FAD/frozen policy only where explicitly intended,
- do not assess the voluntary frozen-close spread.

### LP accounting actions

- withdrawals and reconcile use LP-accounting freshness policy,
- during `oracleFrozen`, LP entry and exit stay live under the fixed frozen-fee policy rather than introducing a second outer stale-action gate,
- already-funded pending buckets may still settle through the same settlement entrypoint,
- preview and live LP paths must agree on the active frozen-fee treatment whenever `oracleFrozen` is true.

## Order State Model

Conceptually, an order can be thought of as:

- `Committed`
- `Executable`
- `Executed`
- `Expired`

In storage, the live router persists:

- `None`
- `Pending`
- `Executed`
- `Failed`

Interpretation rules:

- `Executable` is derived, not stored,
- `Expired` is represented by the failure path rather than its own enum member.

Required transition rules:

- execution consumes reservation exactly once,
- user cancellation is disallowed once pending,
- expiry resolves through the configured bounty and reservation policy,
- stale or missing oracle data does not destroy a valid pending order,
- slippage-invalid orders fail terminally and must not pin the FIFO head,
- live-market execution requires `order.commitTime < oraclePublishTime <= block.timestamp`; only genuine frozen-oracle close-only windows may relax commit-time ordering.

![Order state machine](../../assets/diagrams/perps-order-lifecycle.svg)

## Required Global Invariants

The accounting system should preserve the following:

1. funded redemption assets never exceed physical assets after explicit withdrawal reserves
2. LP-withdrawable cash is at least as conservative as solvency assets
3. no realized shortfall goes unrecorded
4. no pending-order reservation is treated as free trader equity
5. no liquidation assumes access to nonexistent or already-reserved funds
6. solvency and withdrawal accounting do not silently share assumptions
7. a successful close may reduce solvency but must not revert solely to preserve it
8. terminal full closes and liquidations must not perform work proportional to total queue length
9. full closes do not eagerly cancel unrelated queued orders
10. liquidation may perform bounded account-local cleanup under the per-account pending-order cap
11. every position-deletion path re-checks degraded-mode containment
12. Junior redemption funding is zero while any eligible matured Senior demand remains unaccounted for
13. every claimable LP asset is backed one-for-one by vault-held escrow and can be claimed at most once

## Architecture Goal

The system uses multiple conservative accounting kernels because different paths answer different questions: solvency, withdrawal availability, close settlement, liquidation planning, trader claim liabilities, and clearinghouse reservations all need different boundaries.

Design rules:

- keep each kernel explicit and local to its purpose,
- share logic only when the economic question is truly the same,
- make cross-domain reuse deliberate rather than accidental,
- prefer duplication over silently mixing assumptions from the wrong domain.

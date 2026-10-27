# Perps Accounting Spec

This document explains the accounting implemented by the current Plether perps contracts. It covers:

- solvency,
- LP redemption-funding limits,
- close and liquidation settlement,
- trader claim liabilities,
- clearinghouse reservation treatment,
- LP-capital carry,
- LP request admission timing and its separation from settlement maturity and oracle boundaries.

Use it together with:

- [`README.md`](README.md) for the system overview,
- [`SECURITY.md`](SECURITY.md) for invariants, trust assumptions, review guidance and settlement walkthroughs,
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md) for the custody and ownership map.

## Reading the accounting model

The protocol keeps cash availability, risk solvency, and terminal LP equity as separate questions. LP entry and exit
pricing, however, deliberately share one exact terminal-NAV view.

The key rules are:

1. Physical USDG and mathematical claims are different objects.
2. Marked LP equity includes only the portion of an unrealized trader loss collectible from that account's dedicated
   PnL pledge or nettable same-account trader claim. It is not spendable
   withdrawal cash before collection.
3. LP redemption funding is stricter than protocol solvency.
4. Risk-increasing admission and LP redemption funding preserve a liability-scaled settlement buffer; the buffer is
   headroom, not a liability, NAV adjustment, yield source, or separately custodied balance.
5. Pending-order reservations are not free trader collateral.
6. Price loss beyond an account's collectible cap is a diagnostic write-off, not an LP asset or trader debt.
   Unpaid price profit becomes a trader claim. Unfunded action rebates and uncollectible terminal action charges may
   instead be waived; independently negative pool terminal equity is reported as terminal deficit.
7. A valid risk-reducing transition must not revert just to preserve either pre-close solvency or settlement-buffer
   headroom; the protocol contains raw insolvency with `degradedMode` instead.
8. Frozen-close spread value belongs to LPs and must never be credited to protocol treasury.

## Canonical Quantities

All monetary quantities are in 6-decimal USDG unless stated otherwise: `1e6` units equals 1 USDG. Prices use 8
decimals, position sizes use 18 decimals, and rates in basis points use a denominator of 10,000.

| Term | Meaning |
| --- | --- |
| PnL | Trader profit or loss from the change in the capped basket price. |
| PnL pledge | Settlement cash allocated to the live position and reachable for price losses. |
| Trader claim | An unpaid price payout owed by the pool; it is a liability, not cash in the trader's clearinghouse account. |
| NAV | Net asset value attributed to LP shares after the terminal price adjustment and tranche waterfall. |
| VPI | Virtual price impact: a signed skew-based action charge or rebate, accounted separately from price PnL. |
| FAD | The scheduled close-only regime with elevated maintenance margin around oracle closures. FAD alone does not mean the oracle is frozen. |

Here `LONG` profits when the basket mark falls, and `SHORT` profits when it rises. The names describe dollar exposure;
they are the reverse of being long or short the displayed basket mark. See [README.md](README.md) for the market model.

### Physical asset terms

Use these terms consistently:

- `rawAssets`: literal USDG token balance held by `HousePool`
- `accountedAssets`: canonical protocol-owned USDG recognized by pool accounting
- `excessAssets = max(rawAssets - accountedAssets, 0)`: unsolicited or otherwise unaccounted positive balance
- `physicalAssets = totalAssets() = min(rawAssets, accountedAssets)`: conservative economic pool backing
- `economicDepth = max(physicalAssets - totalTraderClaimBalanceAssets, 0)`: depth for carry utilization, skew capacity,
  and VPI. Do not also subtract open-position liabilities, the settlement buffer, or LP principal.
- `protocolTreasuryBalance = clearinghouse.balanceAssets(protocolTreasury)`: cash-realized protocol-owned inventory held as treasury margin in `MarginClearinghouse`, not LP equity
- `netPhysicalAssets = physicalAssets`: the retained snapshot field reports canonical pool backing. Treasury
  settlement is held in the clearinghouse, outside pool custody, so subtracting it here would understate backing.
  A pool-funded treasury payment already reduces `rawAssets` and `accountedAssets` when it leaves the pool.
  Treasury-only clearinghouse deposits and withdrawals must not change either pool asset field. Trader claims
  remain separate liabilities and are deducted when computing `economicDepth` and effective solvency assets.

Operational rules:

- unsolicited positive transfers do not become economic depth until explicitly admitted,
- raw-balance shortfalls reduce effective backing immediately,
- all core accounting paths should read canonical physical assets rather than raw token balance,
- live HousePool redemption-funding and reconcile kernels start from `physicalAssets` and subtract explicit reserve
  buckets; they do not implicitly reserve `protocolTreasuryBalance`.

### Liability terms

- `longMaxProfit`: sum of live LONG entry costs, the maximum payout at basket price zero
- `shortMaxProfit`: sum of `lots * CAP_PRICE - entryCost` for live SHORT positions, the maximum payout at the cap
- `maxLiability = max(longMaxProfit, shortMaxProfit)`
- `priceLossWrittenOffAssets`: diagnostic trader price loss above the account's collectible cap; it is not a liability
  or receivable. Unpaid price payouts become trader claims; negative aggregate terminal equity is reported
  separately as `terminalDeficit`.

### Settlement-buffer terms

Let:

```text
P = physicalAssets
C = totalTraderClaimBalance
E = max(P - C, 0)
L = maxLiability
B = ceil(L * settlementBufferBps / 10_000)
```

`settlementBufferBps` defaults to `25` bps and governance may set it anywhere from `0` through `1,000` bps,
inclusive. The ceiling is applied in 6-decimal USDG atoms, so nonzero `L` and a nonzero rate produce at least one
atom of buffer.

`B` is protected settlement headroom. It does not represent an additional trader claim or maximum payout, does not
enter terminal NAV or yield, and is not a custody or clearinghouse reserve bucket. No tokens are moved merely because
`B` changes. It affects only risk-increasing admission and the cash available for LP redemption funding.

### Exact terminal price-PnL terms

Every live position is stored as whole 100-token lots:

```text
SIZE_QUANTUM = 1e20
lots = size / SIZE_QUANTUM
```

At an 8-decimal price, `lots * price` is already denominated in 6-decimal USDG atoms. The Engine stores
`entryCostAssetAtoms` exactly rather than reconstructing it from the display-only average `entryPrice`. On an increase,
the added basis is `addedLots * executionPrice`. On a partial close:

```text
closedEntryCost = floor(oldEntryCost * closedLots / oldLots)
remainingEntryCost = oldEntryCost - closedEntryCost
```

This assigns every entry-cost atom exactly once and preserves all basis dust for the residual position.

For one account at mark `p`, let `entryCost` be exact entry cost and let
`K = pnlPledgeAssets + sameAccountTraderClaimAssets`. Its LP-side terminal price delta is:

```text
LONG: min(lots * p - entryCost, K)
SHORT: min(entryCost - lots * p, K)
```

A negative result is an amount owed by LPs to the trader. A positive result is capped at value reachable from that
same account. Carry, VPI, execution/frozen spreads, protocol fees, liquidation reserve, order margin, and other action
reserves are deliberately excluded: they are separate realized-settlement quantities, not marked price PnL.

`TerminalNavBookV2` aggregates these account curves exactly over `[0, CAP_PRICE]`. It is immutable-bound to one
Engine, writable only by that Engine, and queried at the Engine's authenticated cached mark. The Engine authenticates
mark availability and book consistency; `HousePool` separately enforces its configured mark-age and oracle-frozen
policy before LP actions. The Engine updates the position, pledge/claim state, and curve atomically;
the book's monotonic version makes the captured snapshot auditable.

### Frozen-close spread terms

- `frozenSpreadAssets`: fixed spread assessed on the reduced position notional for a voluntary close/reduce while `oracleFrozen`
- `frozenSpreadPaidAssets`: assessed spread actually retained or collected as LP trading revenue
- `frozenSpreadWaivedAssets`: uncollectible assessed spread waived to let a terminal full close complete

For a valid close plan, `frozenSpreadAssets == frozenSpreadPaidAssets + frozenSpreadWaivedAssets`. All three values are zero for live and FAD-only closes. Liquidations never assess this spread.

### Symmetric exact marked NAV

The aggregate signed book output is the sole mark-to-close adjustment used to price both LP deposits and LP
redemptions, before allocating pending claimant inflows and excluding ownerless assets from tranche ownership:

```text
signedTerminalEquity = physicalAssets
                     - totalTraderClaimBalanceAssets
                     + terminalLpPriceDeltaAssets

distributable = max(signedTerminalEquity, 0)
terminalDeficit = max(-signedTerminalEquity, 0)
```

This is symmetric: an entrant receives the same discount for inherited marked liabilities that an exiting LP bears,
and receives credit only for collectible marked receivables. It does not make those receivables cash. Redemption
funding still uses the stricter physical withdrawal reserve described below.

For example, suppose the pool holds 1,000 USDG, owes 100 USDG of trader claims, has maximum open-position liability
of 600 USDG, and has a collectible terminal price delta of +80 USDG. At a 25-bps buffer rate:

| Question | Calculation | Result |
| --- | --- | --- |
| Raw solvency | `1,000 - 100 >= 600` | Solvent, with 300 USDG of raw headroom. |
| Buffered admission | `900 >= 600 + 1.50` | The current state meets the buffer; a new trade must also pass on its post-trade state. |
| Terminal equity | `1,000 - 100 + 80` | 980 USDG before ownership routing. |
| Base LP funding capacity | `1,000 - 100 - 600 - 1.50` | 298.50 USDG before pending-claimant, unassigned-asset, and tranche limits. |

The marked 80-USDG receivable raises NAV but cannot fund a redemption until collected.

### LP request admission, maturity, and oracle boundaries

LP request admission uses one fixed cutoff for both tranches and both request directions. Let:

```text
D = 3,600 seconds
cutoff = 300 seconds
t = block.timestamp
e = floor(t / D)
b = (e + 1) * D
```

The request id is:

```text
requestEpoch(t) = e + 1, when t < b - cutoff
requestEpoch(t) = e + 2, when t >= b - cutoff
```

Exact equality belongs to the later epoch. The cutoff does not add a rejection condition: a request that passes the
ordinary authorization, cooldown, pause, lifecycle, size, balance, and capacity checks is accepted and routed to the
calculated epoch. The returned request id and request event reflect the inclusion timestamp and are authoritative.
For every successful request:

```text
targetEpochStart - block.timestamp > 300 seconds
targetEpochStart - block.timestamp <= 3,900 seconds
```

These are three distinct boundaries:

- **Request admission cutoff:** during `[b - cutoff, b)`, new requests cannot increase epoch `e + 1`; they route to
  `e + 2`. Cancellations may still reduce `e + 1`, and no later request can add to that epoch after it matures. During
  `[b, b + D - cutoff)`, requests may legitimately join numeric epoch `e + 2`, which is then the new imminent epoch.
- **Settlement maturity:** a queued epoch is eligible when `currentEpoch >= requestId`. The cutoff does not alter this
  test or the settlement phase order.
- **Live-position oracle boundary:** the reconciliation basket's earliest publish time must be at or after the current
  round-hour boundary. The request cutoff neither fixes the settlement price nor substitutes for that post-boundary
  refresh.

The cutoff freezes only additions to the imminent epoch. Trading, closes, liquidations, claims, carry, pool
accounting, governance finalization, oracle state, and cancellations can still change the state used at settlement.

## The Four Core Accounting Views

The engine needs separate views because different actions answer different questions.

### 1. Risk-increasing solvency view

This view determines whether the protocol may accept more risk. Compute the following after the proposed trade:

- derive post-op `E = max(P - C, 0)`,
- derive post-op `L = max(longMaxProfit, shortMaxProfit)`,
- derive `B = ceil(L * settlementBufferBps / 10_000)`.

Rule:

- a risk-increasing open or increase is allowed only if post-op `E >= L + B`; implementation uses the equivalent
  subtraction form after first proving `E >= L`.

Notes:

- it must not count unrealized trader losses as spendable assets,
- it is less conservative than LP withdrawal accounting, but still bounded and physical-first,
- attached take-profit/stop-loss protection inherits the parent open's ordinary admission check; attaching or
  replacing protection on an existing position does not create exposure and therefore does not apply this gate,
- close, liquidation, and triggered-protection settlement may consume `B`; they are not reverted merely to restore
  the target.

### 2. LP redemption-settlement view

This view determines how much cash the next synchronized settlement may commit to matured LP redemptions:

```text
baseWithdrawalReservedAssets = C + L + B
freeAssets = max(P - withdrawalReservedAssets, 0)
```

HousePool adds pending claimant assets and `unassignedAssets` to the base reserve before calculating free cash.
The Engine supplies `B` as `supplementalReservedAssets`.

Rule:

- matured LP redemptions may be funded only from conservative free cash. Senior demand is funded first. Junior demand
  uses only the remainder and must also preserve the active Senior-share covenant.

Notes:

- this view is intentionally stricter than solvency,
- it ignores uncollected carry and marked price-loss receivables as a cash source for withdrawal,
- dormant Senior NAV is not reserved merely because it exists; only eligible matured Senior demand has priority over
  Junior demand,
- deposit assets finalized later in the same synchronized transaction are not a funding source for withdrawals,
- funded assets leave `HousePool` for vault claim escrow and cannot be counted as free cash again,
- during `oracleFrozen`, the settlement-time output is reduced by the tranche's frozen-window surcharge rather than
  hard-blocking automatically.

### 3. Canonical LP reconciliation and share-pricing view

This view determines tranche equity for share pricing and revenue distribution:

- start from the same physical assets, trader-claim liabilities, claimant buckets, recapitalizations, and revenue state,
- apply the exact signed `terminalLpPriceDeltaAssets` once,
- route the resulting distributable equity through the same Senior/Junior waterfall for both redemption and deposit
  pricing,
- ordinary LP entry always starts with an asynchronous deposit request: assets are funded up front, Junior requests
  are cancellable before maturity, and Senior requests commit capacity at admission. Senior refunds require epoch
  rejection, projected terminal wipe, Senior impairment, or an explicit LP settlement hold,
- `OrderRouter.settleLpEpoch(bytes[])` validates a `PoolReconcile` Pyth basket, installs its neutral Engine mark, and
  invokes the Router-only HousePool settlement callback in one rollback frame; with live open positions, the basket's
  earliest publish time must be at or after the current round-hour epoch boundary,
- HousePool reconciles once, funds Senior redemptions before Junior redemptions, then activates Junior deposits
  before Senior deposits. Each tranche's redemption phase uses its pre-burn price; its deposit phase fixes a price
  after redemption funding. All epochs processed in a phase share that phase's price. ERC-4626 `deposit` and `mint`
  only claim already-activated requests,
- a settlement pass that advances no queue item reverts, so its reconcile and carry checkpoints cannot be retained by
  a permissionless no-op caller; on the Router path the Pyth and Engine updates roll back as well,
- the current terminal snapshot must be fresh and internally stable; the Engine rejects snapshots while a
  multi-contract account mutation is in progress,
- a nonzero current `terminalDeficit` blocks deposit activation, as do degraded mode, stale/frozen entry policy,
  Senior impairment, ownerless assets, or zero tranche NAV with nonzero supply,
- realized pool losses continue to lower the same NAV.

Rules:

- uncollateralized trader losses beyond an account's collectible cap are not booked as LP receivables,
- marked receivables cannot fund same-transaction LP withdrawals,
- value with no valid claimant path must sit in explicit `unassignedAssets`,
- during `oracleFrozen`, synchronized redemption funding may apply the fixed tranche-local exit surcharge, while
  deposit activation is deferred until the live symmetric-NAV entry gate passes,
- direct cached-mark settlement is restricted to zero-open-position state or `oracleFrozen`; a separately refreshed
  live cached mark cannot bypass the atomic Router path. A frozen cached mark must still pass its configured age limit,
- during `oracleFrozen`, bootstrap admin flows (`initializeSeedPosition`, `assignUnassignedAssets`) are blocked rather than inheriting LP frozen-fee pricing.

Required consequences:

- `unassignedAssets > 0` blocks new tranche-deposit requests and deposit activation; initial trading activation also
  rejects stored or projected unassigned assets and residual pending claimant assets,
- a wiped tranche cannot be silently revived by an ordinary asynchronous deposit,
- seeded ownership continuity is preferred over governance re-assignment.

### Senior/Junior waterfall and coupon

`seniorPrincipal` and `juniorPrincipal` are the current NAV attributed to the two tranches, not immutable records of
historical deposits. `seniorHighWaterMark` records the Senior entitlement that future revenue must restore after a
loss. With both tranches owned, reconciliation applies these rules:

1. Checkpoint the elapsed Senior coupon as a transfer from Junior principal to Senior principal.
2. Compare terminal equity, excluding reserved pending claimant inflows and `unassignedAssets`, with total principal.
3. Charge a shortfall to Junior first, then Senior. Losses do not reduce the Senior high-water mark.
4. Route surplus first to restore Senior principal to its high-water mark, then to Junior.
5. Route pending recapitalization and trading-revenue buckets according to their explicit ownership intent, described
   below. Reserving them in step 2 prevents counting the same inflow twice.

For elapsed seconds `dt`, the coupon calculation is:

```text
couponDue  = floor(seniorPrincipal * seniorRateBps * dt / (10_000 * 365 days))
couponPaid = min(couponDue, juniorPrincipal)
```

The coupon requires nonzero Junior share supply. Payment first fills any Senior impairment; only the remainder
raises both Senior principal and its high-water mark. It changes no pool cash and creates no unpaid-coupon liability
when Junior cannot cover the full amount. Paid coupon becomes Senior principal for subsequent accrual intervals.
The default `seniorRateBps` is 800 (8% nominal annual rate); it is not a guaranteed return.

Coupon time has its own checkpoint, separate from mark-dependent reconciliation. A stale mark prevents repricing
terminal equity but does not erase elapsed coupon time. Principal mutations and finalized coupon-rate changes
checkpoint the applicable old rate before changing the basis. Revenue with no eligible share owner is routed to
`unassignedAssets`; a new depositor cannot acquire it simply by being first to deposit.

### 3.1 Junior maintenance-fee supply

The Junior vault may dilute its outstanding shares to pay a maintenance fee. It never transfers USDG or changes
`juniorPrincipal`, Senior principal or high-water mark, withdrawal reserves, claimant buckets, or the allocation of
assets between tranches. The Junior constructor accepts the initial rate and recipient; Senior requires both to be
zero. When the Junior rate is zero, pending fee shares are zero and effective supply equals raw ERC-20 `totalSupply()`.

For a configured nominal APR `r` in basis points, completed Unix hours accrue through a fixed-point hourly retention
factor:

```text
hourlyFeeRay = floor(r * 1e27 / (10_000 * 8_760))
retentionRay = rayPowUp(1e27 - hourlyFeeRay, chargeableHours)
feeShares    = floor(rawSupply * (1e27 - retentionRay) / retentionRay)
effectiveSupply = rawSupply + pendingFeeShares
```

Retention rounds up and fee shares round down, so the protocol does not exceed the configured charge. A checkpoint
charges at most `8_760` hours; if more time elapsed, older hours are explicitly forgiven and the boundary advances to
the latest completed Unix hour. The nominal APR is therefore not an exact annual dilution percentage: at `1_000 bps`,
hourly retention produces approximately `9.516%` dilution over a flat year.

Integer rounding can make split checkpoints differ from a single checkpoint by a small number of share atoms.
The [maintenance-fee math tests](test/perps/accounting/fees/JuniorMaintenanceFeeMathLib.t.sol) specify and check that
rounding bound. There is no permissionless fee-only checkpoint.

If raw Junior supply is zero, there is no fee-bearing ownership to charge. The next real mint advances the fee clock
prospectively to the next Unix-hour boundary and emits a zero-share checkpoint with zero charged and forgiven hours;
empty-supply history is not classified as one-year catch-up forgiveness.

All Junior share conversions, previews, bootstrap quotes, and epoch prices use effective supply. Raw `totalSupply()`
continues to mean actually minted shares. The vault materializes pending fee shares immediately before any nonzero
Junior supply mutation, including a pool-authorized mint or burn and the terminal deposit-claim escrow-dust burn, or
when governance finalizes fee configuration; there is no public fee-only checkpoint. Pending deposits enter the fee
base only when activated. Pending redemption shares remain outstanding and fee-bearing until funding burns them;
funded claims never reprice. Completed-hour granularity can assign less than one hour of pre-activation exposure to a
mid-hour deposit activation, or forgive less than one hour of exposure for a mid-hour funded redemption. Callers
cannot create arbitrary fee-only checkpoints to amplify this bounded shift.

The fee continues to accrue while LP settlement is held, the oracle is frozen, or Junior NAV is zero. A reverted or
held settlement cannot mint shares or advance the checkpoint, but the elapsed completed hours remain pending for the
next successful crystallization. Shares minted at zero NAV initially have no asset value but participate in a later
recovery like ordinary transferable Junior shares.

Only the current HousePool owner may propose, replace, cancel, or finalize Junior fee configuration. Changes have a
48-hour delay, `maintenanceFeeAprBps` is capped at `1_000`, and a nonzero rate requires a valid nonzero recipient.
Finalization first pays elapsed time under the old rate and recipient, preventing retroactive enablement or recipient
rotation. This mechanism is not a performance fee: it has no profit test, Junior HWM, equalization, cost basis, or
per-holder accounting.

### 3.2 Senior exposure admission limits

Let:

- `S` be projected senior principal after the conservative reconcile used by senior admission,
- `H` be the projected senior high-water mark,
- `J` be projected junior principal,
- `R` be gross USDG reserved by all unfinalized senior deposit requests,
- `X = max(S, H)` be active protected senior exposure,
- `Y = X + R` be counted senior admission exposure,
- `A = maxSeniorExposureAssets`, and
- `Q = maxSeniorShareBps`, where finalized governance requires `A` to be finite and `Q < 10_000`.

New senior exposure is admissible only while both conditions hold after the action:

```text
Y <= A
Y * 10_000 <= Q * (Y + J)
```

Equivalently, before a new deposit and for nonzero `Q`, ratio headroom is bounded by
`floor(J * Q / (10_000 - Q)) - Y`, saturated at zero. The active senior capacity is the smaller absolute and ratio
headroom. A zero `Q` permits no positive senior exposure. Raw cash, unassigned assets, trader balances, and pending
junior deposits do not count as junior subordination.

Rules:

- a pending senior request adds its gross assets to `R`, preventing parallel epochs from overbooking the same capacity,
- accepted Senior reservations are firm commitments: finalization atomically releases `R` and adds the same gross
  amount to active senior principal without rechecking later capacity drift,
- a governance reduction, coupon, or loss can passively move the book above current limits, closing new Senior
  admission. A settlement hold stops new Senior requests and permits controllers to recover pending escrow; projected
  terminal wipe, Senior impairment, and rejected epochs also permit refunds,
- funded junior redemptions of net assets `w` must additionally preserve
  `(X + R) * 10_000 <= Q * (X + R + J - w)` using active protected exposure plus pending commitments,
- funded Senior redemptions and Junior deposits improve capacity and may cure an overage,
- governance reductions are prospective for active claims and accepted reservations: neither is burned, repriced, or
  forced out, while new Senior capacity remains zero until the state returns within both limits.

The limits are admission controls, not alternate waterfall arithmetic. Junior-funded coupon, junior-first loss,
revenue restoration, and privileged recapitalization continue under their ordinary priority rules even if they create
or deepen a passive overage. In particular, claimant recapitalization recorded through
`recordClaimantInflow(amount, Recapitalization, cashMode)` may restore an existing protected senior entitlement above
a reduced limit; it mints no new senior LP shares. Assigning ownerless `unassignedAssets` to senior or creating a
senior seed does create new senior shares and goes through the same admission checks. Constructor-neutral limits make
those checks permissive during bootstrap, but trading activation requires finite active limits and a compliant seeded
capital structure; once those finite limits are active, later senior assignment and seeding are directly bounded.

### 4. Trader reachability / terminal settlement view

This view determines what backs one account's exact price-risk health and which funds can actually settle an
obligation:

- generic account views distinguish free settlement, PnL pledge, liquidation reserve, order margin, and action reserve,
- exact price-risk health uses post-carry `pnlPledgeAssets + traderClaimBalanceAssets`, including for open/increase, trader-withdraw,
  close, and liquidation checks; the claim is nettable exactly once against that same account's price loss,
- the separately funded VPI reserve backs only that account's typed VPI obligation: excess reserve never increases
  price-risk equity or the terminal price-PnL cap, while backing below `max(-vpiAccrued, 0)` blocks withdrawal and
  makes account health views flag the position as liquidatable; close and liquidation planners reject the inconsistent
  reserve state rather than executing a clawback,
- same-account trader claim balance is not withdrawable cash and cannot fund carry, VPI, execution fees, frozen
  spread, liquidation charges, order margin, or other action obligations,
- liquidation and close settlement must cap physical seizure and payout logic by actually spendable typed value while
  applying the explicit same-account price-loss netting once,
- pending-order reservations and execution bounty reserves must be handled explicitly rather than assumed to be free cash.

### Credit-only account funding

`MarginClearinghouse.depositFor(account, amount)` changes custody and settlement credit only. It pulls exactly
`amount` of the configured settlement token from the payer and requires the clearinghouse token-balance increase to
match. Both the beneficiary and amount must be nonzero. On success:

```text
clearinghouse USDG custody += amount
settlementBalances[account] += amount
all position, order, liquidation, action, and VPI reserve buckets are unchanged
```

For an otherwise consistent account, free settlement increases by the same amount. The call performs no Engine hook,
carry collection/checkpoint, mark update, position allocation, or terminal-NAV mutation. It changes neither pool assets
nor trader claims. Pending carry remains due and is projected or collected by ordinary subsequent account actions;
free settlement does not itself enter the account's terminal price-PnL cap. Increasing a live position's PnL pledge
requires the owner's ordinary margin-allocation action.

The credit is recorded by `Deposit(account, asset, amount)`. `DepositFor(payer, account, amount)` identifies the payer
of that same credit and must not be summed as a second deposit. Existing owner-only `deposit(account, amount)` and
`depositMargin(amount)` retain their post-credit carry behavior.

Bridge funds become settlement credit only when the destination handler successfully transfers them through
`depositFor`. A provider status or wallet token balance is not clearinghouse collateral. A wallet fallback still
requires a deposit; see [BRIDGE_FUNDING.md](BRIDGE_FUNDING.md) for the attribution and recovery rules.

## Snapshot Boundaries

Snapshot structs are boundary objects between engine accounting and downstream consumers.

### `HousePoolInputSnapshot`

Purpose:

- canonical accounting payload for LP redemption funding and tranche reconciliation. Live LP kernels consume
  `physicalAssets` plus explicit reserve fields; `netPhysicalAssets` is exposed for protocol and read-layer
  parity with the same canonical pool backing. Treasury clearinghouse balances are outside this custody boundary.

Key fields:

- `physicalAssets`
- `netPhysicalAssets`
- `maxLiabilityAssets`
- `supplementalReservedAssets`: the current settlement-buffer target
  `ceil(maxLiabilityAssets * settlementBufferBps / 10_000)` for LP-withdrawal accounting
- `terminalLpPriceDeltaAssets`: exact signed collectible price-PnL adjustment used by both entry and exit pricing
- `terminalNavBookVersion`: monotonic version captured with the exact delta
- `traderClaimBalanceAssets`
- `hasOpenPositions`
- `markFreshnessRequired`
- `maxMarkStaleness`

Rule:

- downstream LP accounting must not re-derive the terminal delta from rounded position tuples or side aggregates,
- the Engine snapshot authenticates mark, claims, position status, maximum directional liability, and book version in
  one call,
- no ordinary deposit request mints active shares in the submission transaction; shares are priced and minted at
  epoch activation.

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

The protocol keeps eligible queued-redemption settlement live during `oracleFrozen` by charging fixed stale-price
surcharges. It defers deposit activation because symmetric entry pricing requires the live terminal-NAV gate.

Default configured fees:

- senior tranche: `25 bps`
- junior tranche: `75 bps`

Governance model:

- `HousePool` governance may update these fees through the same 48-hour timelock pattern used for other LP-facing config,
- the active fee is zero whenever `oracleFrozen == false`, even during the FAD-only shoulder windows.

Accounting rules:

- synchronized deposit activation does not run during `oracleFrozen`; `deposit` and `mint` can still release shares
  activated by an earlier live settlement,
- a redemption request escrows shares without fixing its exchange rate or fee; pending shares remain outstanding and
  participate in tranche profit and loss,
- synchronized settlement prices funded shares from the post-reconcile, pre-burn tranche snapshot using the existing
  ERC-4626 virtual offsets, applies the then-active frozen fee, burns only shares with nonzero net output, and escrows
  exactly the resulting net assets,
- `withdraw` and `redeem` only release already-funded escrow and do not reprice or reassess a fee,
- the fee does not become protocol revenue,
- the fee does not increase `protocolTreasuryBalanceAssets`,
- the fee remains inside the same tranche and therefore benefits incumbent LPs of that tranche only.

Senior withdrawal protection follows the actual net principal debit: for pre-withdrawal principal `P`, high-water
mark `H`, and funded assets `A`, settlement sets `P' = P - A` and `H' = H - floor(H * A / P)`.
This preserves healthy Senior principal/HWM equality and retains impaired protection proportionally, including
protection for retained fees. Rounding favors the remaining protected claim; zero funding leaves both values unchanged.

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

## Preview and simulation solvency outputs

Purpose:

- tell integrators whether an action is legal, whether it newly degrades the protocol, and what the raw post-op solvency looks like.

Required fields:

- `effectiveAssetsAfterAssets`
- `maxLiabilityAfterAssets`
- `postOpDegradedMode`: whether projected `effectiveAssetsAfterAssets < maxLiabilityAfterAssets`
- `triggersDegradedMode`: that insolvency condition is true and the latch was not already set

`postOpDegradedMode` reports projected raw insolvency, not the future value of the sticky on-chain latch. A healthy
projection does not itself clear an existing latch; only an authorized `clearDegradedMode()` call does that.

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

Governance funds recapitalization through `CfdEngine.recapitalizePool(amountAssets)`. The engine owner approves
the engine for USDG; the call checkpoints carry at the old depth, transfers from the owner's wallet directly to
the pool, and verifies exact receipt before recording `Recapitalization` with `CashArrived`. Transfer and recording
are atomic. Normal reconciliation allocates the queued amount to senior restoration or unassigned assets;
the funding call mints no LP shares and does not automatically clear degraded mode.

Rules:

- source semantics decide the owner of the inflow,
- explicit cash inflow vs implicit retained value decides whether `accountedAssets` should increase,
- claimant continuity should prefer seeded ownership paths when available,
- only value with no safe claimant path belongs in `unassignedAssets`.

`unassignedAssets` should be exceptional telemetry, not a normal operating bucket.

## Economic Depth For Carry And Risk Pricing

Carry utilization, the opening skew cap, and open/close VPI use `economicDepth`, not gross physical assets. Paying a
flat account's existing claim reduces assets and liabilities equally and therefore does not change these quantities
when no other state changes. Physical custody, payout affordability, solvency snapshots, Router depth/receipt fields,
and hypothetical preview inputs remain gross; each risk-pricing consumer subtracts claims once.

Carry uses actual live economic depth even when a simulation supplies hypothetical gross assets for trade pricing.
Projected carry collection adds cash before the trade's net-depth calculation. Both directional indexes checkpoint
against the old depth before claim creation, claim consumption/netting, claim payment, or a physical-asset change.

At zero economic depth, a positive borrow base accrues carry at full utilization. Opens/increases reject with
`SOLVENCY_EXCEEDED` after projecting carry collection, even if the proposed order would reduce market skew. Maximum-open
quotes return zero capacity. Protective closes and liquidations remain available under their existing health and
settlement rules. A zero-depth close creates no fresh VPI charge or rebate, but still recovers any negative lifetime
VPI allocated to the closed size; fees, frozen spreads, and claim seniority remain enforced.

## LP-Capital Carry

The protocol uses LP-capital carry instead of a side-to-side rate mechanism.

Definitions:

- `borrowBaseAssets = max(positionMaxProfitAssets - activePositionMarginAssets, 0)`
- `sideBorrowBaseAssets`: sum of open-position borrow bases for one side
- `sideUtilizationBps = min(floor(sideBorrowBaseAssets * 10_000 / economicDepth), 10_000)`; a positive base at zero depth uses 10,000 bps
- `pendingCarryAssets = unsettledCarryAssets + floor(borrowBaseAssets * (currentSideCarryIndex - positionLastCarryIndex) / 1e18)`
- `unsettledCarryAssets[account]`: carry that has been checkpointed at a basis change but not yet physically collected

For elapsed seconds `dt` at fixed borrow base and economic depth, the side index increases by:

```text
indexDelta = floor(baseCarryBps * sideUtilizationBps * 1e18 * dt / (365 days * 10_000 * 10_000))
```

The implementation combines this division so it does not prematurely round the utilization-adjusted rate.

Rules:

- carry accrues continuously by wall-clock time,
- carry does not pause when the oracle is stale or frozen,
- both sides pay when they have nonzero borrow base,
- guard, open/modify, withdrawal, close, and liquidation paths allocate pending carry to canonical active position
  margin first, then free settlement. Collection protects all other locked buckets and same-account trader claims,
- projected price-risk health uses the remaining margin plus same-account claim and exact price PnL. Fully collected
  carry is not an independent delinquency, but its margin debit can cause a maintenance breach,
- any uncovered carry remainder means both margin and free settlement are exhausted; it blocks withdrawal and
  independently makes the account liquidatable. A trader claim cannot pay that remainder,
- claim payments and keeper bounty credits first collect all available margin and free settlement toward carry,
  retaining any unpaid remainder. Then the full credit is applied: paid claims become pledge for live positions,
  bounties become free settlement. No second collection pass or waiver occurs; a later checkpoint can collect that
  credit even at the same timestamp, without reassessing elapsed carry,
- stored `unsettledCarryAssets` may therefore coexist with new backing immediately after a credit. Health checks project
  collection from current buckets; stored arrears alone do not prove carry delinquency,
- claim service still requires pool cash to cover all outstanding trader claims after carry collection. Collected carry
  may enable that payout; insufficient cash or any later failure reverts the entire collection and credit,
- side carry indexes advance before borrowing-base, pool-asset, trader-claim, or risk-parameter mutations change their rate or
  denominator. Account collection remains lazy; an LP deposit or redemption does not collect every trader's debt,
- a flat-to-open transition advances both side indexes to execution wall-clock time using the old borrowing bases
  and pool depth before inserting new exposure. This also applies to historical-price fills that retain a newer
  cached accounting mark: the new position must not accrue carry for time before it opened,
- on owner `deposit` / `depositMargin`, realized carry may be collected from post-deposit settlement in the same
  transaction. Credit-only `depositFor` skips the checkpoint and leaves existing carry due,
- on withdraw, carry is realized before settlement balance is reduced,
- close and liquidation planners project this same allocation before calculating price-loss caps, residual margin,
  action charges, and pool solvency. Live settlement invokes the shared collector before applying the remaining plan,
- only still-unpaid carry enters the subsequent action settlement, using eligible action sources or withheld new gains.
  Full closes also collect from released surplus as specified below; partial-close rejection and liquidation waiver
  rules remain unchanged,
- realized carry is booked as LP trading revenue once. Receipts and financial bounds include the direct collection once,
  in addition to the residual action settlement; carried-forward arrears are not counted as newly accrued carry,
- margin-consuming collection updates the terminal curve atomically with collateral, borrowing-base, and pool
  changes. Terminal-NAV reads are blocked during intermediate accounting, and a revert restores the entire change.

`CarryRealized` reports collection and retained arrears whenever nonzero carry is due, including zero collection when
no backing remains.

LP ownership follows collection time. Indexed pending carry and retained `unsettledCarryAssets` are trader debt, not
LP NAV receivables. Cash collection becomes pool revenue and the existing tranche waterfall prices it at the next
reconcile. Shares activated before collection participate even while held in deposit-claim escrow; shares burned to
fund a redemption stop participating, and the resulting fixed cash claim does not earn later carry. Carry collected
before deposit activation is already included in the activation price.

This intentionally allows a trader and incoming LP to time collection after LP activation and share carry accrued
before that activation. There is no account sweep, accrual-cohort allocation, or entry/exit barrier for pending carry.
The same rule applies when retained arrears are later paid. This is a collection-time ownership policy, not a claim
that timing cannot transfer part of old carry revenue to a new LP.

Collected cash is not always an equal increase in LP NAV. For a solvent pool at a fixed mark and with no other flows,
the change in aggregate tranche NAV is `collectedCarryAssets + changeInTerminalLpPriceDeltaAssets`. Collecting from pledged
margin reduces the account's collectible price-loss cap. If that cap binds both before and after collection, the decrease in
the marked price-loss receivable offsets the carry cash. Reconcile must neither add uncollected carry nor count the
same pledge once as a price-loss receivable and again as collected revenue.

`MarginClearinghouseAccountingLib.projectCarryLoss` owns the post-carry collateral arithmetic used by trade planners,
withdrawal estimates, and account-risk views. It reuses the live collector's allocation policy and returns fresh buckets;
the input snapshot remains unchanged. Raw ledger diagnostics, displayed position margin, and the stored terminal-price
collectible cap continue to describe custody before collection. Price-risk equity and withdrawal capacity use projected
margin and free settlement, respectively; same-account claims contribute to price equity without funding carry.

For every checkpoint sequence, `starting arrears + newly accrued carry = margin collected + free settlement collected
+ ending arrears`. At a terminal action, reconcile any remaining arrears separately against terminal recovery and waiver.
An ordinary close commitment collects applicable carry without reserving a bounty from free settlement or position pledge.
Zero free settlement alone does not prevent commitment. Partial commitments still require no unpaid carry and strict
post-carry maintenance/FAD health; full commitments retain their separate rules. The zero bounty does not bypass
carry or admission checks.

## Trader Claim Liabilities

The protocol supports fail-soft terminal settlement.

### Trader claim balance

- profitable closes and some liquidation residuals may create `traderClaimBalanceAssets[account]`,
- only the beneficiary account itself may call `settleTraderClaim(account)` (`msg.sender == account`; an AA account's
  owner must execute through that account),
- settlement is all-or-nothing for the account claim once aggregate trader claim liabilities are fully cash-covered,
- settlement is credited into `MarginClearinghouse`,
- if the beneficiary still has a live position, paid claim value is credited directly to `pnlPledgeAssets` and the
  account's terminal curve is resynchronized; it must not become withdrawable free settlement while its value was
  already included in the marked collectible cap.

Rules:

- trader claim liabilities are beneficiary-balance based, not FIFO queue based,
- trader claim liabilities are senior claims on pool cash,
- trader claim servicing is frozen entirely while physical pool cash is below aggregate trader claim liabilities,
- fresh payout funding, protocol fee top-ups, and claim servicing must all agree on what pool cash is actually free,
- protocol fee top-ups are subordinate to trader claims and immediate trader payouts; any fee amount that cannot be cash-credited under this priority is not recorded as a protocol fee receivable.

## Pending-Order Reservation Model

Reservations identify settlement cash that cannot be withdrawn or reused for another obligation. The clearinghouse
splits it into:

- `pnlPledgeAssets`: live-position custody immediately reachable by marked price losses,
- `liquidationReserveAssets`: keeper/protocol liquidation-charge backing, isolated from price PnL,
- `orderMarginAssets`: committed open/increase margin,
- `actionReserveAssets`: opening execution bounties and other action charges, including the dedicated negative
  lifetime-VPI reserve and dormant position-protection trigger rewards. Close execution bounties are zero.

For a live position, the gross VPI reserve target is:

```text
vpiRebateReserveAssets = max(-vpiAccrued, 0)
actionReserveAssets >= protectedExecutionBountyAssets + vpiRebateReserveAssets
```

The second relation is a protected floor: generic action-charge collection may consume only action reserve above it.
An open/increase that raises the VPI target must fully fund the increase from eligible settlement or newly supplied
pledge, otherwise planning fails before exposure grows.

After an open/increase, the target liquidation reserve is:

```text
max(minBountyAssets, floor(resultingNotionalAssets * bountyBps / 10_000))
```

Approved position collateral beyond that target is PnL pledge. A reduction recomputes the target and releases excess
reserve; price movement alone never permits a liquidation charge to consume PnL pledge.

Rules:

- reserved value is not withdrawable,
- reserved value is not free buying power,
- liquidation, order, and action reserves do not increase the TerminalNavBook collectible cap,
- reserved execution bounty value is not reachable collateral for unrelated price losses,
- VPI reserve is nonwithdrawable, cannot fund generic action charges, and cannot be extracted by LPs before its
  account obligation settles,
- releasing or consuming reservation must happen exactly once,
- clearinghouse reservation records are the source of truth for committed trader margin,
- execution bounty reserves are not LP cash and should not become a pool liability bucket.

### Reservation ownership and queues

`MarginClearinghouse` owns reservation amounts, active-reservation indexes, and settlement custody. `OrderRouter`
owns the global and per-account execution queues; `OrderLifecycleBook` retains permanent order identity and outcomes.
`PositionProtectionBook` owns protection lifecycle, attempt linkage, and the trigger-reward snapshot. These lifecycle
stores do not maintain a second mutable committed-margin queue or bounty balance.

Committed margin has its own per-account FIFO in the clearinghouse. Each `OrderReservation` records the account,
original and remaining amounts, status, and previous/next active reservation ids. Creation appends; partial consumption
keeps the record in place; full consumption or release unlinks it immediately. This can happen before the associated
order executes when a full close consumes its committed margin. Terminal records remain readable and cannot be reused;
zero is the queue sentinel, never a reservation id.

The monetary-reservation FIFO is therefore different from the Router execution FIFO. Exhausting an order's margin does
not itself execute or remove that order. Router views `getMarginReservationIds`, `marginHeadOrderId`, and
`marginTailOrderId` forward to the clearinghouse queue and exclude exhausted records immediately. There is no manual
queue-synchronization step. The Router separately enforces `maxPendingOrders` (default 5 per account, governance maximum
32) on pending execution orders.

### Bounty records and protected backing

A bounty record is keyed by `(BountyKind, id)` and contains `account`, `amountAssets`, `freeFundedAssets`, and `state`.
Numeric ids may overlap across the two independent namespaces:

| Namespace | Authorized record owner | Monetary backing |
| --- | --- | --- |
| `Order` | Router | Opening/increase execution reward from free settlement; every close attempt records zero. |
| `ProtectionTrigger` | Router's immutable protection book | One trigger reward from free settlement; it is paid once or refunded/forfeited before payment. |

`totalBountyReservationsAssets(account)` is the sum of outstanding protected bounty amounts in both namespaces. Creation
increases it; taking or successfully recovering a record decreases it. Quarantine preserves the amount in the aggregate.
A new record requires an unused nonzero id and enough already-locked action reserve to cover the new amount, existing
bounties, and the dedicated VPI reserve. A zero close still needs an explicit `Active` record and valid backing for the
account's other obligations. The planner snapshot field `protectedExecutionBountyAssets` reads this same aggregate,
including unpaid protection-trigger rewards.

The exact floor enforced locally by the clearinghouse is:

```text
protectedActionReserveAssets = vpiRebateReserveAssets + totalBountyReservationsAssets(account)
```

Generic action charges cannot consume this protected amount. No Router queue scan or external accounting callback
supplies the floor. Engine/lens snapshots read the same aggregate; Router account views combine it with pending-order
counts and the clearinghouse's committed-margin summary.

### Reservation recovery and atomicity

Recording a reservation classifies custody; it does not create or transfer USDG. `recordBountyReservation` classifies
value already locked by the authorized funding path, or records an active zero close. `takeBountyReservation` settles
the classification while the underlying action reserve remains locked. The authorized caller then completes the payout,
refund, or forfeiture in the same transaction. Later failure rolls back the record, lifecycle state, and funds together.
Neither record creation nor taking a record checkpoints carry; ordinary close commitment collects carry separately.

The lifecycle Book independently authenticates the original bounty entitlement and free funding, both zero for a close.
Account, kind, id, active state, and amount must match before ordinary settlement. A record cannot be recreated under a
used id, and an absent record is not an active zero record.

Reservation mismatch before expiry is retryable. Strictly after the execution deadline, the recovery path reconciles
exact Book-backed opening funding before any internal refund, without a new carry checkpoint. Missing, already-settled,
or foreign-account records authorize no refund. Identifiable records with inconsistent funding, aggregate backing, or
custody become `Quarantined`; their value stays locked and remains included in the protected aggregate. A discrepancy
never authorizes an administrator to guess or rewrite ownership. `BountyRecovery` reports the recoverable `freeAssets`
and a `discrepancy` classification; a zero close still requires its complete authenticated identity.

### Reading and checking reservations

Use these views for their distinct purposes:

| Read | Meaning |
| --- | --- |
| `getOrderReservation(orderId)` | Persistent committed-margin record, including original/remainder amounts and terminal status. |
| `getAccountReservationSummary(account)` | Active committed-margin total and active reservation count. |
| `getMarginReservationIds(account)` | Active monetary-reservation FIFO; not the execution queue. |
| `getBountyReservation(kind, id)` | Canonical bounty owner, amount, funding classification, and state. |
| `totalBountyReservationsAssets(account)` | Protected outstanding bounty amount, including quarantined backing. |
| `OrderRouter.getAccountReservations(account)` | Router pending count plus canonical committed-margin and bounty totals. |
| `OrderLifecycleBook` / `PositionProtectionBook` | Order outcome and protection lifecycle, respectively. |

`BountyReservationUpdated` reports classification updates, but settling a zero record need not emit another update.
It is not a second token transfer or a complete order receipt. Combine record views with lifecycle receipts to
interpret payouts, refunds, forfeitures, and zero-bounty terminal outcomes.

[ProtectionBountyStateMachine.t.sol](test/perps/invariant/properties/ProtectionBountyStateMachine.t.sol) checks an
independent ledger with `funded = unpaid + paid + refunded + forfeited`. It compares historical/current records,
account aggregates, custody backing, keeper credits, and lifecycle state after terminal paths, repeated retries,
cross-account namespace collisions, and transfer-failure rollback. Each fuzz case then mixes 32 actions across three
accounts and drains remaining rewards. Carry and VPI are zero in this focused fixture; their interaction coverage is
in the separate accounting suites, rather than implied by this conservation test.

### Funded settlement minimum for a pending flat open

A positive `minPostSettlementBalanceAssets` is supported only for a flat account's first pending open. The canonical
pending intent is the sole floor ledger; no account-level floor storage is added. After commitment and reservations,
settlement custody `S`, minimum `M` and maximum gross debit `G` must satisfy `S >= M && S - M >= G`. Every owner
withdrawal applies the same predicate after its provisional debit, in addition to ordinary reservation checks. The
withdrawal estimate is `min(freeSettlement, S - M - G)` when funded, otherwise zero.

No later fresh same-account order may overlap this funded open. Increases and closes cannot request a positive
minimum, and exact intent replay precedes fresh admission. With the account flat, deposits, claim settlement and keeper
credits cannot collect live-position carry; they only increase its funded surplus. Execution and terminal bounty
settlement may consume their allowance while linked. Successful or failed terminal queue removal releases the floor;
retryable execution and failed receipt finalization roll back to the original pending floor. Zero-minimum orders retain
ordinary availability. This protection prevents owner withdrawals from manufacturing a settlement-minimum failure; it
does not freeze market-dependent financial bounds.

### Close-order bounty policy

Ordinary and protection close attempts have zero execution bounty, so commitment requires no USDG top-up for a close
keeper reward. Native transaction gas and oracle-update fees are separate. Opening/increase bounties, protection
trigger rewards, and liquidation rewards remain paid incentives. A zero reward does not make trading charges zero
or guarantee that every partial reduction passes its health and financial limits.

Ordinary close commitment validates the position, queued exposure, direction, size quantum, minimum partial size,
carry and financial bounds. It collects carry from pledge first, then free settlement, protecting other reservations. A partial
commitment requires fully collected carry and strict maintenance/FAD health. Full-close commitment may retain unpaid
carry under its own admission rules. Collected commitment carry is included exactly once in gross account debit,
assessed/collected action charges, and carry totals for the user's financial bounds. The Book records custody before
and after commitment and any carry still outstanding.

The Router creates an explicit active `Order` bounty record with amount zero. It locks no money, but its account,
kind, identifier, and active state still authenticate terminal cleanup. A missing record is not equivalent to an active
zero record.

| Transition | Accounting | Queue and receipt |
| --- | --- | --- |
| Ordinary commit | Collect carry; no bounty reserve | Append authenticated zero record. |
| Protection trigger/retry | Queue through the protection path without ordinary commitment carry effects | Append a fresh authenticated zero record; carry is assessed at execution. |
| Successful close | Settle price PnL, carry, fees, VPI, spread, and claims | Settle zero record; unlink once; bounty disposition `None`. |
| Ordinary terminal failure or expiry | Roll back execution; no bounty payment | Settle zero record; unlink only this order. |
| Protected attempt failure with the same position | No bounty movement | Settle old attempt; latch protection; retry gets a new zero record. |
| Liquidation | Apply liquidation settlement and its independent reward | Clear the account's unpaid close records; preserve other accounts' FIFO order. |
| Retryable or unknown failure | Roll back the item | Preserve pending state, identity, and links. |

Receipts for normal close attempts have zero bounty entitlement, payment, refund, and forfeiture, with no bounty
recipient. Receipt finalization, reservation settlement, and queue cleanup succeed or revert together.

Discrepancies follow [reservation recovery and atomicity](#reservation-recovery-and-atomicity); a normal close
receipt never substitutes for authenticating the actual record.

### Position-protection bounty policy

`PositionProtectionBook` owns protection lifecycle state; `MarginClearinghouse` owns the underlying custody and
bounty records. The Book holds no tokens. A protection reserves one fixed trigger reward from free settlement and
does not reclassify position pledge. Every generated close attempt has its own authenticated zero bounty record.

For an existing position, protection creation locks the trigger reward before checking safety. The canonical planner
requires post-carry price-risk equity, using only PnL pledge, same-account claim, and exact price PnL, to be strictly
above the greater of the initial and active maintenance/FAD requirement. Uncovered carry or an underfunded VPI reserve
independently prevents creation. An attached protection locks its reward before the parent open is admitted.

The reserve follows these transitions:

- Parent-open success normally arms protection against the resulting full position without moving the trigger
  reserve. If the accepted-basket/Engine-mark consistency check fails, protection instead fails and refunds its
  trigger reward while the parent fill remains executed.
- Parent failure/expiry or cancellation before trigger refunds the unpaid trigger reward. Cancelling an attached
  `PendingOpen` protection detaches it without cancelling the binding parent order.
- A valid trigger pays the reward once and appends a full-close attempt to the Router FIFO.
- A failed attempt with the exact protected position still present becomes `Latched`; a retry appends a fresh zero
  bounty attempt and does not pay the trigger reward again.
- Terminal cancellation, failure, risk-off cleanup, or liquidation releases or forfeits only funds that remain unpaid,
  according to the reservation policy. No terminal protection retains a monetary reserve.

See [bounty records and protected backing](#bounty-records-and-protected-backing) for the canonical record ownership.

### Open-order failure policy

- deterministic live-state open failures may be rejected at commit time,
- unsupported numeric inputs are rejected even when commitment cannot rely on a fresh cached mark; execution
  repeats the checked planner,
- ordinary execution-time terminal failures pay the keeper from clearinghouse-reserved bounty value,
- the persistent administrative risk-off cutoff is the sole terminal-failure exception: it refunds the full remaining
  margin, ordinary execution bounty, and any attached `PendingOpen` protection bounties internally to the trader in
  one no-checkpoint clearinghouse release, and pays no cleanup reward,
- engine revert selectors classify the public failure reason and preserve mark-price-out-of-order as nonterminal, but
  do not split ordinary terminal-failure bounty routing.

## Settlement Rules

Close and liquidation should share the same economic assumptions wherever the question is identical, and differ only where the product deliberately differs.

### Close settlement

Successful ordinary close planning uses physical PnL pledge and same-account claim. No close-bounty escrow exists.
The enclosing item rolls back settlement if later receipt finalization or queue cleanup fails.

A full close removes the entire position, so it has no residual-position health/leverage check and is exempt from the
partial-close minimum-notional floor. A partial close must leave a healthy residual position and meet the applicable
size and leverage bounds. "Full" is evaluated against the position at each check: queued admission and live execution
can differ if an earlier order fails. Both paths still require lot-aligned size, matching direction, admissible oracle
data, and valid timing, mode, and financial bounds. A positive `minPostSettlementBalanceAssets` is not supported for a
fresh close.

Every voluntary close uses the signed VPI curve and lifetime rebate clamp. During `oracleFrozen`, it also assesses
a fixed spread on reduced notional. The deployment script initializes `frozenCloseSpreadBps` to 50 bps (0.50%); the
constructor accepts a configured rate, and subsequent changes use the 48-hour engine risk timelock. The rate must be
nonzero and cannot exceed 1,000 bps (10%). This LP-owned spread replaces the Pyth adverse-confidence price adjustment
for frozen voluntary closes. Live/FAD-only closes and liquidations retain adverse-confidence pricing.

When a close realizes a loss:

1. collect margin-first carry, then allocate exact entry cost to the closed lots and compute their price PnL from that basis,
2. seize price loss from the dedicated PnL pledge and explicitly net same-account claim value up to the book's cap,
3. treat price loss above that cap as a diagnostic write-off; it does not create LP equity, LP deficit, trader claim,
   or protocol debt; a partial close still requires a healthy residual position,
4. handle still-unpaid carry, VPI, fees, and spreads through their separate settlement paths; those distinct
   charges retain their explicit partial-close collection policy,
5. on a full close, release the unused post-carry, post-price-loss pledge and liquidation reserve into free settlement
   before collecting action charges; waive only the shortfall after all eligible funds are exhausted,
6. atomically replace or remove the account's terminal curve, including the residual position's updated collectible
   cap, before the transition completes.

Required properties:

- full closes withhold new price gains and settle dedicated VPI backing first, then collect generic action charges
  from spendable action reserve, free settlement (including released liquidation reserve and unused VPI backing), safely released pledge, and finally
  committed-order margin in FIFO order. Protected execution bounties and existing trader claims cannot pay action
  charges. A waiver at the engine settlement boundary implies no eligible cash remains; later router bounty credits
  and protected-reservation refunds are separate transitions,
- partial closes retain the current health- and terminal-cap-safe pledge funding policy, but cannot use released
  liquidation reserve or committed-order margin for action charges and still reject a shortfall. Liquidation's
  separate charge and bounty allocation is unchanged,
- price-loss write-off never creates a receivable; a partial close still requires a healthy residual position and
  full collection of its required action charges,
- a price payout, after any action charge withheld from the gain, is paid in full only when unreserved pool cash
  covers it; otherwise the entire price payout becomes a same-account trader claim,
- an immediate partial-close price payout goes directly into the surviving position's PnL pledge; a deferred payout
  becomes a claim. Both outcomes remain in that account's next terminal collectible cap. An immediate full-close
  price payout goes to free settlement,
- the full gross negative lifetime-VPI clawback target `max(-vpiAccrued, 0)` remains protected in the dedicated VPI
  sub-reserve while a position survives. A partial close must leave the exact target for the residual accrual; value
  above that target is consumed when the clawback is collected or released only when equivalent trader value was
  withheld,
- a new close-time action rebate uses the cash left after price-payout processing and protection of all trader claims,
  including a newly deferred price payout. It may be partially paid; the unfunded portion is explicitly waived and
  never becomes a trader claim or PnL pledge,
- anticipated carry, VPI, fees, spreads, and other action economics stay outside terminal `K`; the book is synchronized
  only to actually installed PnL pledge and same-account claim state after settlement. The VPI reserve therefore does
  not inflate marked LP receivables or symmetric LP NAV,
- a user must not shield otherwise reachable settlement by parking it in queued committed margin right before terminal settlement,
- carry-adjusted close loss must be planned once and consumed live from that same canonical loss amount,
- price-gain-withheld or cash-collected frozen spread becomes LP revenue and never treasury margin; same-account claim
  netting remains exclusive to exact price loss,
- assessed spread must equal paid spread plus waived spread,
- preview and live close paths should share one close-accounting kernel and expose the same assessed/paid/waived result; successful nonzero assessments emit `FrozenCloseSpreadSettled`.

The engine lens close preview separates fresh payout destinations:

- `payoutToPnlPledgeAssets`: cash price profit locked as collateral for a remaining position;
- `payoutToFreeSettlementAssets`: paid action rebates and full-close price profit credited without a position pledge;
- `deferredPayoutAssets`: new unpaid price profit recorded as a trader claim, excluding pre-existing claims.

`immediatePayoutAssets` is the sum of the two cash destinations, not a withdrawable amount.
The three destinations sum to `freshTraderPayoutAssets`; existing claims remain separately reported.
Released pre-existing collateral is outside these fresh payout fields. Even a free-settlement credit is not a
withdrawal-capacity quote: account reservations, carry, and Engine withdrawal guards still apply. See
[CLOSE_PREVIEW.md](CLOSE_PREVIEW.md) for field interpretation and integration examples.

### Open projection

The planner projects carry collection before pricing a trade or evaluating its resulting collateral. It updates the
position and side borrow bases consistently and adds only collected cash to pool assets. Net VPI rebates credit free
settlement and may fund the dedicated VPI reserve; they do not directly become price-risk pledge.

Admission then checks the resulting pledge plus same-account claim, after the VPI-reserve funding and
liquidation-reserve carve-out. It also checks the pool's post-trade settlement buffer. An order above the configured
skew cap is allowed only when it strictly reduces the existing imbalance without making its own side heavier.

An open must match the position projected through earlier queued orders. A full queued close can project the account
flat and permit an opposite-side open, but execution rechecks actual state if that earlier close fails. Similarly, a
queued close must match the live position's side at execution. Unsupported numeric inputs are rejected explicitly
rather than admitted as orders that can only fail with arithmetic errors.

Preview and execution use the same planner for carry, exact entry basis, rebate credit, reserve funding, collateral
health, and solvency. [Order timing](CANONICAL_ENTRYPOINTS.md#order-timing) describes admission versus execution rules.

Engine open, close, and liquidation execution obtains planner deltas through its immutable `CfdEnginePlanningReader`.
The reader forwards the settlement sidecar's canonical snapshot to the configured planner through read-only calls;
the Engine still validates the returned deltas and applies settlement through its existing sidecar. The reader does
not hold balances or change the accounting rules.

### Treasury fee withdrawals

- protocol fee withdrawal is a standard `MarginClearinghouse` withdrawal from the configured treasury account,
- `MarginClearinghouse.balanceAssets(CfdEngine.protocolTreasury())` reports the configured treasury account balance,
- rotating the treasury changes the recipient of future fees; existing balances stay with the previous account and remain withdrawable by it,
- an optional treasury commitment activates immediately and blocks both immediate treasury setters until its expiry; it does not restrict withdrawals or move balances,
- immediate commitments accept durations from 1 second to 90 days (7,776,000 seconds), inclusive; a pending successor accepts zero to 90 days, with zero leaving it unlocked. This cap applies to each lock's duration, not the time from proposal submission until the successor's lock expires,
- during an active lock, the owner can propose, replace, or cancel a pending successor without changing the current expiry; at that expiry the latest pending address becomes effective automatically, with no confirmation or keeper transaction,
- all future protocol credits use the effective `CfdEngine.protocolTreasury()` at the credit timestamp; the pending successor's optional lock starts at its scheduled activation time, even if the next interaction occurs later,
- only cash-collected execution or liquidation fees and free-cash-funded top-ups become treasury margin,
- uncredited fee amounts are not withdrawable protocol inventory,
- frozen-close spread is LP-owned trading revenue and never becomes treasury margin,
- withdrawing treasury margin must not consume `HousePool` cash, trader claims, or LP withdrawal reserves.

<a id="liquidations"></a>

### Liquidation settlement

Use `CfdEngineLens.previewRouterLiquidation(account, oraclePrice)` to include the Router's preceding risk-off
refunds. It releases remaining committed margin and order/protection bounties for cutoff-invalid pending opens
in a memory snapshot before evaluating liquidation. Those refunds can cover unpaid carry and restore solvency;
the result reports both the refund amounts and the subsequent liquidation preview. Refunds make settlement free
inside the clearinghouse; they are not wallet transfers. `previewLiquidation` and `simulateLiquidation` remain
Engine-level diagnostics that omit this Router cleanup. All use caller-supplied prices and do not validate oracle
policy or predict intervening transactions or other accounts in a batch.

In the liquidation preview, `settlementRetainedAssets` is the projected settlement balance after all liquidation
debits and any immediate price payout. `immediatePayoutAssets` is already included in that total and must not be
added again. `traderClaimBalanceAssets` reports outstanding claims separately; deferred payouts are not cash in
`settlementRetainedAssets`. For example, $100 left after debits plus a $30 immediate payout gives retained
settlement of $130, not $160. If that $30 is deferred instead, retained settlement stays $100 and the claim
balance increases by $30. Retained settlement is an account-balance projection, not a withdrawal-capacity quote.

Liquidation must:

1. collect margin-first carry and position price loss from the reduced PnL pledge and explicitly nettable claim,
   matching the cap after carry collection,
2. allocate the capped liquidation charge using the configured `keeperShareBps` and `protocolShareBps`, crediting the
   keeper and protocol-treasury shares through clearinghouse settlement and transferring the exact LP remainder to
   `HousePool` claimant revenue,
3. preserve residual trader value when positive,
4. report uncollateralized price loss above the cap as a diagnostic write-off rather than protocol debt or terminal deficit,
5. delete the position,
6. re-evaluate degraded-mode containment.

Risk-off refunds and their existing early health check occur first. A separate inner rollback frame then authenticates
pending reservations, forfeits unpaid opening bounties where applicable, settles zero close records, invokes the
Engine liquidation health/settlement path, and finalizes account-local queue cleanup. If the account is healthy,
roll back this entire inner frame: its pending orders remain and no liquidation bounty is earned. Previously completed
outer risk-off refunds persist. Without such outer work, the single-call
solvent revert and batch skipped-solvent behavior are preserved. Only the exact direct Engine solvent failure receives
that classification; unrelated errors do not become healthy outcomes. Other accounts retain their relative FIFO order.

Liquidation-charge rule:

- assess the configured `bountyBps` rate and `minBountyAssets` floor as one total charge,
- cap the total charge by physically reachable liquidation collateral,
- require `keeperShareBps + protocolShareBps <= 10_000`,
- set `keeperAllocation = floor(totalCharge * keeperShareBps / 10_000)` and credit it to the keeper,
- set `protocolAllocation = floor(totalCharge * protocolShareBps / 10_000)` and credit it to the protocol treasury,
- allocate `totalCharge - keeperAllocation - protocolAllocation` to LPs so all rounding remainder belongs to LPs and
  the three destinations conserve the collected charge exactly,
- allow the total charge to exceed positive equity as an explicit liquidation subsidy,
- use eligible collateral after earlier settlement debits, rather than treating all clearinghouse cash as available.

Required property:

- liquidation eligibility first projects carry from active position margin and then free settlement, and uses the
  reduced pledge for exact price-risk equity. Carry left uncovered by both sources independently makes the account
  liquidatable; same-account claims remain exclusive to price-loss netting,
- liquidation charge caps and residual planning use their typed physically eligible sources rather than folding carry
  into the price channel,
- negative accrued VPI does not reduce pledge-plus-claim price-risk equity. Its gross target must instead remain fully backed by the
  dedicated VPI reserve; underfunding sets the diagnostic account-health liquidation flag but causes liquidation
  planning to revert. With sufficient backing, the clawback is consumed from that reserve or replaced by an equivalent
  withheld trader gain before excess reserve is released,
- the keeper/protocol charge is capped by its dedicated reserve and other explicitly eligible charge funds; it must
  never raid PnL pledge needed by price settlement,
- an uncollectible terminal action charge is waived rather than reclassified as protocol debt or price loss,
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

Close and liquidation settlement latch it when their post-operation solvency check finds:

```text
E < L
```

This is the raw solvency boundary. The settlement buffer is deliberately excluded: a close or liquidation may leave
`L <= E < L + B` without entering degraded mode. The owner may clear an existing latch once `E >= L`; restoring the
full buffer is not a clear condition. Subsequent opens and increases still fail their separate `E >= L + B`
admission check.

Allowed while degraded:

- closes,
- liquidations,
- mark updates,
- recapitalization,
- owner action to clear the mode after solvency is genuinely restored.

Blocked while degraded:

- new opens,
- other risk-increasing modifications,
- trader withdrawals while the account has a live position,
- new LP epoch settlement, including redemption funding and deposit activation.

Already-funded LP claims remain claimable from vault escrow; they no longer depend on pool withdrawal capacity.
The latch is set by settlement checks, not by a background process. A raw token-balance shortfall can affect current
solvency before a transaction updates the latch.

Required properties:

- both close and liquidation re-check containment,
- preview and simulation should expose both `triggersDegradedMode` and `postOpDegradedMode`.

## Oracle And Freshness Policy

Accounting uses the price admitted by each action's oracle policy. A preview that accepts a caller-supplied price does
not itself authenticate that price or make an order executable.

| Action | Accounting consequence |
| --- | --- |
| Open/increase | Requires admissible fresh post-commit data; stale or missing data leaves the order pending. |
| Live or FAD-only close | Uses adverse-confidence execution pricing; no frozen-close spread. |
| Oracle-frozen close | Uses the frozen-close policy and the fixed LP-owned spread; ordinary VPI and lifetime clamp still apply. |
| Liquidation | Uses its liquidation oracle policy and never assesses the voluntary frozen-close spread. |
| LP redemption funding | Requires the LP mark policy and physical cash reserves; oracle-frozen funding applies the tranche exit surcharge. |
| LP deposit activation | Requires the live entry gate; oracle-frozen activation is deferred. |
| Claim of already-funded LP assets or shares | Releases fixed vault escrow without a new price or fee. |

## Order State Model

Ordinary orders retain `None`, `Pending`, `Executed`, or `Failed` status. Executability is derived; expiry resolves
through `Failed`. Terminal execution or failure consumes each reservation exactly once. Retryable oracle or unknown
failures preserve the pending item. An exact replay of an account/client order id and its original request returns the
existing order id without collecting carry or allocating another reservation; changing the request under that id
conflicts.

Once `block.timestamp > executionDeadline`, anyone may call `expireOrder(id)` without oracle data. Equality is still
live. Expiry may remove a non-head order; live execution remains FIFO. Expiry does not guarantee the position closes.

Users cannot cancel a binding ordinary order. The protocol risk-off cutoff invalidates affected pending opens and
refunds their remaining committed margin, execution bounty, and attached unpaid protection reward to internal free
settlement. It pays no cleanup bounty, performs no carry collection or terminal-NAV mutation, and remains effective
after unpausing.

Protection has a separate lifecycle. Armed or latched protection is off queue; triggered protection links one live
full-close attempt. A failed attempt may latch for retry without a second trigger payment. Consult
[Order timing](CANONICAL_ENTRYPOINTS.md#order-timing) and [ORACLE_SYNCHRONIZATION.md](ORACLE_SYNCHRONIZATION.md) for timing and oracle
rules, and [reservation ownership and queues](#reservation-ownership-and-queues) for accounting boundaries.

## Required Global Invariants

The main accounting invariants are:

1. Pool physical assets are `min(rawAssets, accountedAssets)`; treasury margin is outside pool custody.
2. LP redemption funding reserves trader claims, maximum directional liability, the settlement buffer, pending
   claimant inflows, and unassigned assets before allocating cash.
3. Eligible Senior redemption demand precedes Junior funding; Junior funding also preserves the Senior-share covenant.
4. Every funded LP claim is backed by vault escrow and can be claimed at most once.
5. Exact position entry cost is conserved across increases and partial closes; rounded average entry price is not a
   settlement basis.
6. Every terminal book curve matches live lots, exact entry cost, side, and the `pledge + same-account claim` cap.
7. LP entry and exit use the same terminal-NAV accounting. Marked receivables do not fund cash redemptions, and a
   nonzero current terminal deficit blocks deposit activation.
8. Claims may net against their beneficiary's price loss exactly once. They cannot pay carry or action charges.
9. Reservations cannot be withdrawn or reused; negative lifetime VPI remains backed by its dedicated reserve.
10. Collected carry is pool revenue once; uncollected carry is not an LP receivable.
11. Price-loss write-offs, action-charge waivers, deferred price claims, and terminal deficit remain separate quantities.
12. Successful opens/increases meet `E >= L + B`. Closes and liquidations may consume the buffer and complete into
    degraded mode; they do not revert solely to preserve pre-close pool solvency.
13. Frozen-close spread and frozen LP exit fees stay with LPs; they never become protocol treasury margin.
14. Ordinary and protection close attempts authenticate zero bounty records without reserving or paying a close bounty.
15. LP request ids use the same five-minute cutoff for both tranches and both directions; maturity does not fix a price.

### Implementation references

The implementation is split by the economic question being answered:

| Area | Core source | Representative checks |
| --- | --- | --- |
| Physical solvency and buffer | [SolvencyAccountingLib.sol](src/libraries/SolvencyAccountingLib.sol) | [EngineAccountingViews.t.sol](test/perps/differential/EngineAccountingViews.t.sol) |
| Exact terminal curves | [TerminalNavBookV2.sol](src/TerminalNavBookV2.sol), [CfdMath.sol](src/CfdMath.sol) | [PerpTerminalNavBruteForceInvariant.t.sol](test/perps/invariant/properties/PerpTerminalNavBruteForceInvariant.t.sol) |
| Tranche reconciliation | [HousePoolAccountingLib.sol](src/libraries/HousePoolAccountingLib.sol), [HousePoolWaterfallAccountingLib.sol](src/libraries/HousePoolWaterfallAccountingLib.sol) | [LpEntryExitNavParity.t.sol](test/perps/differential/LpEntryExitNavParity.t.sol), [SeniorCouponCheckpoints.t.sol](test/perps/accounting/waterfall/SeniorCouponCheckpoints.t.sol) |
| Carry and collateral | [PositionRiskAccountingLib.sol](src/libraries/PositionRiskAccountingLib.sol), [MarginClearinghouseAccountingLib.sol](src/libraries/MarginClearinghouseAccountingLib.sol) | [MarginFirstCarry.t.sol](test/perps/accounting/carry/MarginFirstCarry.t.sol), [CarryLpOwnership.t.sol](test/perps/accounting/carry/CarryLpOwnership.t.sol) |
| Close and liquidation plans | [CfdEnginePlanLib.sol](src/libraries/CfdEnginePlanLib.sol), [CloseAccountingLib.sol](src/libraries/CloseAccountingLib.sol), [LiquidationAccountingLib.sol](src/libraries/LiquidationAccountingLib.sol) | [EngineClosePreview.t.sol](test/perps/differential/EngineClosePreview.t.sol), [EngineLiquidationPreview.t.sol](test/perps/differential/EngineLiquidationPreview.t.sol) |
| Junior dilution | [JuniorMaintenanceFeeMathLib.sol](src/libraries/JuniorMaintenanceFeeMathLib.sol) | [JuniorMaintenanceFee.t.sol](test/perps/accounting/fees/JuniorMaintenanceFee.t.sol) |

See [SECURITY.md](SECURITY.md) for the broader security invariants and trust assumptions.

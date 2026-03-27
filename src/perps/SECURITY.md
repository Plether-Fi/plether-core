# Security Assumptions & Known Limitations — Perpetuals Engine

This document outlines the security assumptions, trust model, known limitations, and emergency procedures for the Plether Perpetuals Engine.

For the repo's intended semantic model for solvency, withdrawals, liquidation equity, pending-order escrow, and oracle-policy separation, see [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md).
For a concise definition of the accounting terms used here (`raw assets`, `accounted assets`, `effective solvency assets`, etc.), see the Accounting Glossary in [`README.md`](README.md).

## Upgradeability

All perpetuals contracts are **non-upgradeable**. Once deployed, the bytecode cannot be changed.

- **No proxy patterns**: No UUPS, Transparent, or Beacon proxies
- **Immutable logic**: Contract behavior is fixed at deployment
- **Immutable parameters**: `CAP_PRICE`, `USDC` address, oracle feed IDs, basket weights, and base prices are set at construction

**Mutable admin state:**

| Parameter | Contract | Guard |
|-----------|----------|-------|
| `riskParams` (VPI, funding curve, margins, bounty) | CfdEngine | `onlyOwner` — 48-hour propose-finalize timelock |
| `fadDayOverrides` | CfdEngine | `onlyOwner` — 48-hour propose-finalize timelock |
| `fadMaxStaleness` | CfdEngine | `onlyOwner`, must be > 0 — 48-hour timelock |
| `fadRunwaySeconds` | CfdEngine | `onlyOwner`, max 24 hours — 48-hour timelock |
| `engineMarkStalenessLimit` | CfdEngine | `onlyOwner`, must be > 0 — 48-hour timelock |
| `seniorRateBps` | HousePool | `onlyOwner` — 48-hour propose-finalize timelock |
| `markStalenessLimit` | HousePool | `onlyOwner` — 48-hour propose-finalize timelock |
| `orderExecutionStalenessLimit` | OrderRouter | `onlyOwner` — 48-hour propose-finalize timelock |
| `liquidationStalenessLimit` | OrderRouter | `onlyOwner` — 48-hour propose-finalize timelock |
| `maxOrderAge` | OrderRouter | `onlyOwner` — 48-hour propose-finalize timelock |
**One-time setters** (cannot be changed after initial configuration):

| Setter | Contract |
|--------|----------|
| `setVault(address)` | CfdEngine |
| `setOrderRouter(address)` | CfdEngine |
| `setEngine(address)` | MarginClearinghouse |
| `setSeniorVault(address)` | HousePool |
| `setJuniorVault(address)` | HousePool |
| `setOrderRouter(address)` | HousePool |

## Protocol Invariants

These properties must always hold. Violation indicates a critical bug.

### Solvency Invariants

| Invariant | Description |
|-----------|-------------|
| **Vault Solvency** | `vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)` is enforced on risk-increasing opens, where `vault.totalAssets()` is canonical physical backing (`min(rawAssets, accountedAssets)`) rather than raw token balance. If a profitable close later reveals insolvency, `degradedMode` contains the breach instead of trapping the close |
| **Degraded Containment** | If a close realizes cash outflow that pushes `effectiveAssets` below the remaining liability bound, `degradedMode` latches: new opens and risky withdrawals are blocked until recapitalization restores solvency and the owner clears the mode |
| **Bounded Payout** | No trade's maximum profit exceeds `size × CAP_PRICE / USDC_TO_TOKEN_SCALE` — payouts are deterministic at inception |
| **Withdrawal Firewall** | `freeUSDC = balance - max(bullMaxProfit, bearMaxProfit) - accumulatedFees - fundingWithdrawalReserve - deferredPayoutLiabilities` — LPs cannot withdraw encumbered capital |
| **Senior High-Water Mark** | After a loss impairs `seniorPrincipal`, revenue restores it to `seniorHighWaterMark` before any surplus flows to junior. Increases additively on deposits, scales proportionally on withdrawals (along with `unpaidSeniorYield`), and resets on the first post-wipeout recapitalization. Deposits stay blocked while partially impaired (`0 < seniorPrincipal < seniorHighWaterMark`) |

### Position Invariants

| Invariant | Description |
|-----------|-------------|
| **Single Direction** | An `accountId` holds at most one directional position (BULL or BEAR). Opening the opposite side requires closing first |
| **Minimum Notional** | Every position's notional × `bountyBps` >= `minBountyUsdc × 10,000` — keeper bounty is always economically viable |
| **No Dust Positions** | Partial closes revert if remaining `pos.margin < minBountyUsdc` — prevents unliquidatable dust where keeper bounty < gas cost |
| **Margin Sufficiency** | `pos.margin >= IMR` after every open (checked post-fee against final position state), where `IMR` should come from an explicit `initMarginBps` policy surface rather than being implicitly derived from `MMR` |
| **Queue Execution** | Execution always starts from the current global queue head. Retryable slippage misses are requeued behind the global tail with cooldown instead of being terminally failed, while terminal invalid / expired orders still consume escrow according to policy. Risk-increasing orders reserve an execution bounty bounded to `[0.05 USDC, 1.00 USDC]` by seizing free settlement into router custody. Close orders also reserve a flat `1.00 USDC` bounty upfront at commit time, sourcing it from free settlement first and then active position margin if needed, so head-of-queue execution stays economically backed even for fully margined accounts |
| **VPI Stateful Bound** | Each position tracks `vpiAccrued` (cumulative charges/rebates). On close, `proportionalAccrued + closeVpi` is bounded ≥ 0 — users can never extract net VPI profit regardless of depth changes |

### Mark-to-Market Invariants

| Invariant | Description |
|-----------|-------------|
| **Per-Side Zero Clamp** | `getVaultMtmAdjustment()` caps negative funding by collectible side margin, then computes per-side `(PnL + funding)` and clamps negative totals to zero — the vault never recognizes unrealized trader losses as assets or uncollectible funding receivables as offsets. Conservative: may temporarily undercount assets until traders settle, but eliminates phantom profits from per-side netting |
| **Asymmetric Withdrawals** | `getFreeUSDC()` only reserves for vault liabilities (positive funding/PnL). Illiquid receivables never reduce physical reserves |
| **Margin Tracking** | `sides[BULL].totalMargin + sides[BEAR].totalMargin == Σ pos.margin` across all open positions, maintained through `processOrder` and `liquidatePosition` |

### Funding Invariants

| Invariant | Description |
|-----------|-------------|
| **Zero-Sum Funding** | `bullFundingIndex` and `bearFundingIndex` move symmetrically — majority side pays, minority side receives |
| **No Silent Drain** | If funding debt exceeds margin on an open order, the engine reverts with `FundingExceedsMargin` (position must be liquidated instead) |

### Clearinghouse Invariants

| Invariant | Description |
|-----------|-------------|
| **Balance Integrity** | `balanceUsdc(accountId)` always equals tracked settlement USDC attributable to that account |
| **Withdrawal Guard** | Users can only withdraw if `remainingEquity >= lockedMarginUsdc` and `balanceUsdc(accountId) >= lockedMarginUsdc`. Free equity above locked margin is withdrawable even with open positions |
| **Seizure Bound** | `seizeUsdc` reverts if the tracked settlement balance is below `amount` (no negative balances) |

## Trust Assumptions

### External Protocol Dependencies

#### Pyth Network (FX Price Feeds)

- **Assumption**: Pyth provides accurate, timely price data for all basket FX pairs (EUR/USD, JPY/USD, GBP/USD, CAD/USD, SEK/USD, CHF/USD)
- **Architecture**: OrderRouter aggregates multiple Pyth feeds into a weighted basket price replicating the spot BasketOracle formula
- **Mitigation (MEV)**: Commit-Reveal pipeline with `publishTime > commitTime` check defeats oracle latency arbitrage while the oracle is live. During genuine frozen-oracle windows this ordering check is intentionally bypassed for close execution so traders can still reduce risk against the last valid oracle price.
- **Mitigation (Staleness)**: Order execution and manual mark refresh use the router's `orderExecutionStalenessLimit` (default 60s), liquidations use the router's stricter `liquidationStalenessLimit` (default 15s), engine-side withdraw/bounty-backing guards use `engineMarkStalenessLimit` (default 60s), and HousePool reconciliation/withdrawal freshness stays governed by `markStalenessLimit` (default 60s). All four switch to `fadMaxStaleness` (default 3 days) during frozen oracle windows
- **Mitigation (Mark Freshness)**: `lastMarkTime` is set from the Pyth VAA `publishTime` (not `block.timestamp`) across all engine paths (`processOrder`, `liquidatePosition`, `updateMarkPrice`). This prevents stale VAAs from appearing fresh to the HousePool's mark staleness checks
- **Mitigation (Negative/Zero)**: `_normalizePythPrice` reverts on non-positive prices; `_computeBasketPrice` reverts if basket sum is zero
- **Risk (Weekend Gaps)**: Pyth FX feeds stop publishing Friday ~22:00 UTC. The two-state oracle model (FAD window vs oracle frozen) handles this explicitly, but the frozen-oracle policy is liveness-first: voluntary closes can execute at the last valid Friday price until the oracle resumes publishing.
- **Risk (Feed Compromise)**: If any single Pyth feed is compromised, the basket price is affected proportionally to that feed's weight. The weakest-link `minPublishTime` prevents selective staleness attacks
- **Risk (Exponent Variation)**: Different Pyth feeds may use different exponents. `_normalizePythPrice` normalizes all to 8 decimals but truncates on scale-down

#### USDC (Circle)

- **Assumption**: USDC maintains its $1 peg and operates as a standard ERC-20 token
- **Risk (Blacklisting)**: Circle can blacklist addresses. If the HousePool, MarginClearinghouse, or TrancheVault contracts are blacklisted, the protocol cannot process payouts or withdrawals
- **Risk (Upgradeability)**: USDC is an upgradeable proxy. Circle could modify transfer logic or add fees
- **Risk (Fee-on-Transfer)**: MarginClearinghouse expects standard USDC transfers. HousePool and TrancheVault also assume standard ERC-20 transfers
- **Mitigation**: None. These are fundamental risks of using USDC as collateral

### External Library Dependencies

#### OpenZeppelin Contracts

- **Assumption**: OpenZeppelin's implementations of ERC20, ERC4626, Ownable2Step, ReentrancyGuard, and SafeERC20 are secure
- **Mitigation**: Pinned versions; OpenZeppelin is the most widely audited Solidity library
- **Usage**: CfdEngine (Ownable2Step, ReentrancyGuard), OrderRouter (Ownable2Step, Pausable), HousePool (Ownable2Step, Pausable), TrancheVault (ERC4626), MarginClearinghouse (Ownable2Step, SafeERC20)

### Internal Trust Model

#### Owner/Admin Role

The protocol owner can (all subject to 48-hour timelock):
- Adjust all risk parameters (`vpiFactor`, funding curve, margin BPS, bounty)
- Add/remove FAD day overrides for FX market holidays
- Configure `fadMaxStaleness` and `fadRunwaySeconds`
- Set the senior tranche interest rate and mark staleness limit
- Configure max order age

The owner can (instant, no timelock):
- Pause/unpause OrderRouter (blocks new `commitOrder`, allows executions/liquidations)
- Pause/unpause HousePool (blocks new deposits, allows withdrawals)
- Withdraw accumulated execution fees to any recipient (post-solvency check)
- Bind the MarginClearinghouse to the CfdEngine once via `setEngine(address)`
- Transfer ownership (via Ownable2Step two-step pattern)

The owner **cannot**:
- Change `CAP_PRICE` after deployment
- Change the OrderRouter, HousePool, or TrancheVault addresses after initial setup
- Directly mint, burn, or move user margin
- Bypass the solvency invariant (fee withdrawal checks post-solvency)
- Modify oracle feed IDs, weights, or base prices (immutable in OrderRouter constructor)

**Timelock Protection**: All risk parameter changes are subject to a 48-hour propose-finalize delay. This gives users and monitoring systems time to detect and react to proposed changes before they take effect. Proposals can be cancelled by the owner at any time.

#### Keepers

Keepers are permissionless — anyone can execute orders and liquidations:
- **Order Execution**: Keepers push Pyth price payloads. At commit time the router seizes the reserved execution bounty into router custody, quoting risk-increasing orders from `lastMarkPrice()` in the engine with a `$1.00` fallback before the first mark is observed. Close intents pull from free settlement first and may fall back to active position margin so traders are not forced to deposit fresh idle cash just to request a risk-reducing exit
- **Binding orders**: Traders cannot cancel queued opens or closes once committed, preventing delayed close intents from becoming a free timing option against keepers
- **Per-account queue cap**: No account may have more than `5` pending orders at once, bounding account-local liquidation cleanup and queue-griefing surface
- **Execution bounty floor**: Risk-increasing orders reserve at least `0.05 USDC`, preventing dust orders from entering FIFO with zero economic incentive. Close intents reserve a flat `1.00 USDC` router escrow at commit so clearers are paid from user-funded escrow instead of vault subsidy
- **Bounded close-margin tradeoff**: Close intents may source that flat `1.00 USDC` escrow from active position margin when free settlement is exhausted. This is an intentional bounded liveness tradeoff: with the `MAX_PENDING_ORDERS = 5` cap, at most `5 USDC` of live position margin can be parked in router custody before execution/liquidation cleanup
- **Liquidation**: Keepers trigger liquidations and receive USDC bounties from the vault
- **MEV Protection**: Commit-Reveal prevents keepers from seeing user intent before committing oracle prices in live markets. Frozen-oracle windows are an intentional exception: no fresh oracle publish exists, so the protocol preserves close liveness at the last valid oracle price instead of enforcing an impossible publish-time ordering check.
- **Failed Orders**: Retryable market-state misses such as slippage do not burn the order or pay the clearer; they emit `OrderSkipped`, keep the order pending with its escrow intact, and requeue it behind the current tail with a short retry cooldown. A shared order-failure policy now classifies both router-local pre-execution failures and engine-typed reverts, and the engine/planner expose semantic policy categories rather than router-owned raw code lists: `previewOpenFailurePolicyCategory(...)` returns `CfdEnginePlanTypes.OpenFailurePolicyCategory`, while `processOrderTyped()` reverts with `CfdEngine__TypedOrderFailure(CfdEnginePlanTypes.ExecutionFailurePolicyCategory, uint8, bool)`. Commit-time open rejection is intentionally limited to `CommitTimeRejectable` current-state failures, while execution-time `ProtocolStateInvalidated` opens (including close-only transitions detected in the router) refund the trader bounty. Expired and otherwise terminal `UserInvalid` orders pay their reserved execution bounty to the executor from router escrow. Because close orders now prefund the flat clearer bounty in router escrow, terminal invalid and expired closes no longer tax LP equity or depend on vault liquidity, even when the bounty was sourced from active position margin rather than idle free settlement.
- **Canonical Transition Staging**: Mark refresh, preview, and live settlement paths are expected to share the same economic stage ordering: funding may only accrue across fresh live-mark windows, router escrow forfeiture/liquidity moves happen after any required funding checkpoint, and preview/live paths must agree on when protocol-fee tagging becomes visible to solvency math.
- **Spendability vs Equity**: Deferred trader receivables improve economic equity but are not physically spendable margin until paid. Planner validation must therefore reject opens that could pass a pure-equity check yet still fail later when the clearinghouse tries to unlock physical position margin.

#### Engine / Router Trust Boundary

The MarginClearinghouse authorizes only the configured `engine` and the router returned by `engine.orderRouter()`. Those trusted protocol actors can:
- Lock/unlock margin on user accounts
- Settle USDC (credit or debit balances)
- Seize USDC from accounts (for losses, fees, and bad debt)
- Seize execution-bounty reserves from trader settlement into router custody for later clearer/protocol distribution

These actors **cannot**:
- Use `seizeUsdc()` to withdraw user funds to arbitrary addresses (the seize recipient must equal `msg.sender`)
- Create negative balances (seizure reverts if balance insufficient)

`OrderRouter` now uses the semantic `previewOpenFailurePolicyCategory(...)` and `processOrderTyped()` boundaries instead of maintaining its own raw engine revert-code taxonomy. `CfdEngine__TypedOrderFailure(...)` carries `CfdEnginePlanTypes.ExecutionFailurePolicyCategory`, so the router only decides policy from semantic categories plus router-local close-only / expiry events.

## Known Limitations

### Oracle Edge Cases

#### Price at or Above CAP

- **Behavior**: CfdEngine clamps `currentOraclePrice` to `CAP_PRICE` in both `processOrder` and `liquidatePosition`. OrderRouter clamps before slippage check.
- **Impact**: BEAR positions hit maximum profit; BULL positions hit maximum loss. The protocol is solvent by construction at CAP.
- **Limitation**: If the oracle price genuinely exceeds CAP for extended periods, BEAR traders cannot capture additional upside beyond CAP.

#### Basket Price Truncation

- **Behavior**: `_computeBasketPrice()` computes `Σ (price × quantity) / (basePrice × 1e10)`. Each term truncates independently.
- **Impact**: With 6 feeds, cumulative truncation error is at most 6 wei in 8-decimal space (~$0.00000006). Negligible for all practical purposes.

### Zero-Clamped MtM Conservatism

#### Temporary Junior NAV Dilution

- **Behavior**: `getVaultMtmAdjustment()` first caps each side's negative funding at collectible side margin, then clamps each side's unrealized `(PnL + funding)` at zero. When the vault has physically paid out to winning traders but losing traders have not fully settled yet, the MtM still refuses to recognize those unrealized receivables as assets beyond collectible backing.
- **Impact**: `_reconcile()` sees `distributable < claimedEquity` and triggers `_absorbLoss()`, writing down `juniorPrincipal`. When losers eventually settle (close or liquidation), cash flows in as revenue, but recovery goes through the waterfall (senior restoration → senior yield → junior), so junior doesn't recover dollar-for-dollar.
- **Severity**: Proportional to unsettled funding. In testing: ~0.3% dip ($3k on $1M) after 90 days of skewed funding with one side settled. Could be larger with sustained heavy skew.
- **Secondary effect**: New LP depositors during the dip get underpriced shares, diluting existing junior LPs.
- **Rationale**: Accepted trade-off to eliminate phantom profit bugs (C-02/C-03). The vault can never overestimate its position, which is strictly safer than the alternative where paper MtM profits get withdrawn as real USDC. This follows the accounting conservatism principle: recognize liabilities (trader profits), don't recognize unrealized assets (trader losses) until realized through physical settlement.
- **Why this is the chosen O(1) solution**: The ideal fix would be per-position capping (`Σ min(loss_i, margin_i)`), but `min()` is nonlinear — each position clips at a different threshold depending on its entry price and margin, so it cannot be decomposed into global accumulators. The live implementation therefore uses a conservative two-step approximation: cap negative funding by aggregate collectible side margin, then zero-clamp each side's `(PnL + funding)` total. This can still undercount assets, but it prevents phantom profits from uncollectible funding receivables while keeping the accounting O(1).

### Funding Precision

Funding accumulators use 18-decimal precision (WAD). At extreme low values:
- `fundingDelta = (annRate × timeDelta) / SECONDS_PER_YEAR` — at 0.01% APY with 1-second blocks, this is ~3.17e5 (non-zero)
- `step = (price × fundingDelta) / 1e8` — with price=1e8, step=3.17e5 per second. Accumulates correctly.
- **Lower bound**: Funding truncates to zero only when `annRate × timeDelta < SECONDS_PER_YEAR / price`, which at $1.00 means annRate × timeDelta < 315. At 12s blocks, this requires annRate < 26, i.e., < 2.6e-17 APY. Practically unreachable.

### Liquidation Mechanics

#### Keeper Bounty Capping

The bounty is calculated as `max(notional × bountyBps, minBountyUsdc)`, then capped:
- **Positive equity**: Capped at `uint256(equityUsdc)` — keeper cannot extract more than the position's equity
- **Non-positive equity**: Capped at physically reachable liquidation collateral — keeper cannot extract more than the terminal settlement path can actually seize from the account

This means keepers may receive less than `minBountyUsdc` when equity is small but positive. The minimum position size guard ensures this gap is bounded: at the threshold ($3,333 notional), the proportional bounty equals `minBountyUsdc`, so the cap only binds when PnL has eroded equity. Additionally, partial closes that would leave remaining margin below `minBountyUsdc` revert (`DustPosition`), preventing creation of positions too small for economic liquidation.

#### Bad Debt Socialization

When a position goes underwater (equity < 0):
- **Liquidation**: Vault seizes all position margin + available free USDC from clearinghouse. Remaining deficit is absorbed as bad debt by the House Pool.
- **Self-Close**: `_processDecrease` seizes `min(available, owed)` from the user. Any shortfall is absorbed by the vault.
- **Risk**: Sustained bad debt erodes LP capital. The funding curve's "wall of APY" at 40% skew is designed to prevent this by forcing deleveraging before extremes.

#### Deferred Profitable Close Payouts

- **Behavior**: If a profitable close realizes more USDC than the House Pool can immediately transfer, the position is still closed and the unpaid gain is recorded in `deferredPayoutUsdc[accountId]`
- **Claim path**: Deferred payouts are serviced through an oldest-first queue. Once liquidity returns, anyone may call `claimDeferredPayout(accountId)` for the queue head and the vault pays the currently available amount into the `MarginClearinghouse`, which credits the recorded trader's USDC balance there. Trader deferred payouts are coalesced to one active queue node per account, so additional deferred value for an already-queued account inherits that account's current queue position rather than appending as a fresh later-aged node. Partial returning liquidity still services the current queue head before later claimants, and queue-head servicing is senior to protocol-fee withdrawals.
- **Impact**: Traders are not forced to remain exposed just because the vault is temporarily illiquid, but payment finality becomes a two-step process: economic close first, clearinghouse settlement later
- **Operational note**: Monitoring should track deferred payout balances and available free cash, since deferred balances represent senior claims on future vault liquidity and are counted in reserve/solvency accounting

#### Deferred Liquidation Bounties

- **Behavior**: If the House Pool cannot immediately fund a liquidation bounty from cash left after reserving existing deferred claims and protocol-fee inventory, the state transition still completes and the unpaid amount is recorded in the deferred bounty liability bucket. Order-execution bounties are router-custodied and therefore do not share this vault-liability path.
- **Claim path**: Deferred clearer bounties share the same oldest-first queue. Once liquidity returns and a clearer bounty reaches the queue head, anyone may call `claimDeferredClearerBounty()` and the currently available USDC is paid into `MarginClearinghouse`, which credits the recorded keeper's address-derived account there. Queue-head servicing remains senior to protocol-fee withdrawals and no longer depends on direct USDC wallet transfer success for the keeper.
- **Impact**: Terminal execution remains live during temporary vault illiquidity; clearer bounty payment finality becomes deferred rather than blocking the state transition
- **Operational note**: Deferred liquidation bounties are counted in reserve, solvency, and LP reconciliation accounting until paid

#### Deferred Payout as Explicit Netting, Not Generic Collateral

- **Behavior**: Existing `deferredPayoutUsdc[accountId]` is no longer treated as generic collateral in withdraw checks, close-bounty backing, or generic position views.
- **Effect**: `getPositionView()` now reports physically reachable collateral separately from same-account deferred payout. Generic account-health paths only use the physical clearinghouse bucket, while terminal close/liquidation settlement can still net the same-account deferred payout explicitly.
- **Security benefit**: This removes a hidden abstraction leak where a vault IOU could accidentally be reused as if it were immediately reachable account cash.

#### Explicit Initial Margin Policy

- **Behavior**: Withdraw-facing risk checks now target initial-margin headroom rather than only maintenance margin.
- **Effect**: Traders cannot withdraw themselves to the liquidation cliff and then become liquidatable from a trivial adverse move.
- **Design note**: `initMarginBps` is an explicit policy surface distinct from `maintMarginBps` / `fadMarginBps`, and open / withdraw margin checks should read that configured value directly.

#### Failed Open Bounty Policy

- **Behavior**: Typed open-order failures now distinguish user-invalid insufficiency from genuine post-commit protocol-state invalidation. `MARGIN_DRAINED_BY_FEES` is treated as user-invalid, so the clearer receives the reserved bounty instead of refunding it to the trader.
- **Effect**: Keepers do not need to guess whether executing a fee-drained open will pay them; only true protocol-state invalidations on opens refund the trader bounty.
- **Trade-off**: Some execution-time failures still depend on post-commit state drift, so bounty routing is intentionally tied to the engine's semantic execution failure category rather than a blanket refund rule.

#### Liquidation Preview / Live Consistency

- **Behavior**: Before liquidation, the router forfeits any queued execution-bounty escrow for the liquidated account into the vault. Liquidation preview and live execution now both use the same post-forfeiture vault-depth view.
- **Impact**: Keeper tooling and live liquidation agree on keeper bounty, deferred payout, bad debt, and post-op solvency outputs instead of mixing pre-sweep and post-sweep depth.

#### Stale-Mark Funding Policy

- **Behavior**: Outside genuine frozen/FAD oracle mode, funding accrual stops once the live mark becomes older than the engine's live staleness limit. Funding resumes only after a fresh mark update arrives.
- **Effect**: Funding can no longer keep advancing off stale weekday marks while other protocol paths are already freshness-gated.
- **Trade-off**: Tests and integrations must not assume long stale intervals keep accumulating funding during ordinary live-market operation.

#### Bounded Queue Cleanup

- **Behavior**: Global expired-order cleanup is bounded per call. `executeOrder()` only auto-skips a fixed number of expired head orders, `executeOrderBatch()` stops after a fixed global scan budget, and `pruneExpiredOrders()` lets keepers advance the expired head in explicit bounded slices.
- **Effect**: Queue liveness no longer depends on a potentially unbounded scan across stale sybil orders.
- **Trade-off**: Draining a heavily expired queue may now take multiple keeper calls by design, but each call has predictable bounded work.

#### Three-Bucket Liquidation Residual Accounting

- **Behavior**: Liquidation residuals are modeled explicitly in three buckets: settlement retained on-ledger in the clearinghouse, legacy deferred payout consumed/remaining, and any fresh trader payout created by the liquidation itself.
- **Effect**: Preview and execution no longer infer trader value by subtracting a target residual from `settlement + deferred`. Positive residuals above reachable settlement now become a fresh payout path instead of trying to over-allocate the legacy deferred claim.
- **Security benefit**: This removes underflow/liveness risk when positive pnl or funding makes residual trader value exceed `settlementReachableUsdc + deferredPayoutForAccount`, and it gives auditors a single end-to-end mental model for liquidation settlement.

#### Terminal Queue Continuity

- **Behavior**: Full closes do not scan the global queue to cancel later intents for the same account, while liquidations perform bounded eager account-local cleanup of that liquidated account's pending orders
- **Effect**: Terminal settlement still avoids any global FIFO scan. Full-close stale tails fail lazily when they eventually reach the queue head, while liquidation invalidation happens immediately but only across the liquidated account's capped local queue
- **Trade-off**: Integrators must treat queued orders as contingent on the continued existence of the account's live position. The protocol keeps cleanup bounded by the per-account pending-order cap rather than requiring any global queue scan during liquidation

#### OrderRouter Queue and Escrow Invariants

- **Single order source of truth**: `getOrderRecord(orderId)` exposes the canonical `OrderRecord` for each order. Its `core`, `status`, reserved execution bounty, and queue pointers must move together so lifecycle and queue proofs read from one record instead of parallel mappings, while committed-order reservation amounts come from the clearinghouse reservation ledger.
- **Dual-queue structure**: Each account maintains two intrusive FIFO lists. The general pending queue (`pendingHeadOrderId`, `pendingTailOrderId`) contains every live pending order through `OrderRecord.nextPendingOrderId` / `OrderRecord.prevPendingOrderId`. The margin queue (`marginHeadOrderId`, `marginTailOrderId`) contains only live pending orders whose clearinghouse reservation record still has positive `remainingAmountUsdc`, linked through `OrderRecord.nextMarginOrderId` / `OrderRecord.prevMarginOrderId`.
- **Global execution FIFO**: `nextExecuteId` remains the sole execution head. Orders still execute or expire in global commit order even though committed-margin accounting now traverses an account-local list.
- **Dual-queue membership invariant**: An order may appear in the margin queue if and only if `OrderRecord.status == Pending` and its clearinghouse reservation record still has positive `remainingAmountUsdc`. Close orders and zero-margin orders must never enter the margin queue, and any order whose reservation residual reaches zero must be unlinked from it eagerly.
- **Finalization invariant**: Any path that fails or finalizes an order must unlink that order from the general pending queue exactly once, unlink it from the margin queue if present, release or consume its clearinghouse reservation by `orderId` exactly once, clear or distribute its reserved execution bounty, and set the terminal `OrderRecord.status` without erasing immutable order metadata.
- **Queue-sync invariant**: `syncMarginQueue(accountId)` only prunes zero-remaining reservations out of the account-local margin queue; it does not own reservation amounts or bucket consumption policy.
- **Queue/accounting agreement**: `pendingOrderCounts[accountId]` should equal the number of orders reachable from `pendingHeadOrderId[accountId]`. Separately, the orders reachable from `marginHeadOrderId[accountId]` should be exactly the pending orders whose clearinghouse reservations have positive `remainingAmountUsdc`, and `getAccountEscrow(accountId).committedMarginUsdc` should equal the active committed reservation total reported by the clearinghouse.

#### No Partial Liquidation

- **Behavior**: `liquidatePosition` always closes the entire position
- **Impact**: Users with large positions face all-or-nothing liquidation. No opportunity to partially reduce and restore margin requirements.
- **Rationale**: Simplifies accounting and prevents liquidation gaming (partially closing to reduce notional while keeping the riskiest portion open)

### VPI (Virtual Price Impact)

#### Liquidation Skips VPI

- **Behavior**: `liquidatePosition` does not compute or charge VPI. Only voluntary opens and closes include VPI in their cost/rebate.
- **Impact**: The vault misses the VPI charge that would be applied on a voluntary close. For MM positions that earned a rebate at open, the vault doesn't recover the matching charge at liquidation.
- **Mitigation**: VPI rebates at open are locked into `pos.margin` via `netMarginChange`. When the position is liquidated, margin is seized back to the vault, partially recovering the rebate. The net leakage is bounded by the VPI charge at close, which is typically small relative to the position.
- **Rationale**: Computing VPI during liquidation adds complexity and gas. In bad-debt liquidations, the user can't pay the VPI charge anyway, so it would only increase the deficit.

#### Depth Sensitivity

- **Behavior**: VPI uses live `vault.totalAssets()` as depth `D` at both open and close. If vault depth changes between open and close, the VPI charge/rebate differs.
- **Impact**: MMs opening when the vault is small (earning large rebates) and closing when the vault is large (paying small charges) net a small profit from VPI alone.
- **Mitigation**: This is symmetric risk — vault depth could also decrease between open and close, increasing the VPI charge. The MM bears directional risk during the holding period. The effect is bounded by vault depth volatility over the position's lifetime.

#### Bidirectional VPI Clamp Zeroes MM Rebates

- **Behavior**: On close, `proportionalAccrual + vpiUsdc` is clamped ≥ 0. An MM who heals skew on both open (earning a rebate) and close (also healing skew) has the close rebate cancelled: the clamp forces `vpiUsdc = -proportionalAccrual`, netting the lifetime VPI to zero.
- **Impact**: MMs cannot profit from VPI rebates alone. Both the open rebate and the close rebate are zeroed out over the position lifetime.
- **Why this is necessary**: Removing the bidirectional clamp to allow MM rebate retention enables the C02a depth-change attack: a trader opens at low vault depth (earning a large rebate), an LP inflates the vault, the trader closes at high depth (paying a small charge), netting ~$15/round-trip. This is infinitely repeatable via LP sandwich and strictly worse than zeroing MM rebates.
- **Rationale**: MMs must earn spread through directional price movement, not VPI rebates. The protocol prioritizes preventing infinite extraction over rewarding market-making.

#### Linear VPI Chunking on Partial Close

- **Behavior**: On partial close, VPI accrual is released proportionally to the fraction of size closed (`vpiAccrued × sizeDelta / originalSize`). This is a linear approximation of the quadratic VPI cost curve.
- **Impact**: Closing in N chunks costs slightly more than closing all at once. Measured: ~$4 error on a 2-chunk close of $400k notional (0.001%).
- **Rationale**: Accepted approximation. The quadratic integral is path-independent for same start/end skew, but computing exact quadratic chunking would require tracking per-chunk entry skew. The linear approximation is bounded, simple, and prevents the C02a depth attack.

### FAD (Friday Auto-Deleverage) Edge Cases

#### DST Transitions

- **Behavior**: FAD window uses fixed UTC thresholds. Oracle frozen uses asymmetric thresholds: Friday 22:00 UTC (latest possible FX close) and Sunday 21:00 UTC (earliest possible FX open).
- **Impact (Winter)**: The 21:00 Sunday unfreeze causes a ~1-hour liveness gap where 60s staleness rejects the ~47-hour-old frozen price. Orders submitted during this gap will fail until fresh prices arrive.
- **Rationale**: Safe failure mode — no trades execute on stale prices. Liveness resumes within minutes of market open.

#### Admin FAD Days Without Runway

- **Behavior**: Admin holidays lack the natural 3-hour deleverage runway (Friday 19:00→22:00). `fadRunwaySeconds` provides this synthetically.
- **Risk**: If `fadRunwaySeconds` is set to 0, keepers have no time to liquidate over-leveraged positions before the oracle freezes on admin FAD days.
- **Mitigation**: Default `fadRunwaySeconds = 3 hours`. Owner can increase up to 24 hours.

### Clearinghouse Limitations

#### V1: USDC-Only Cross-Margin

- **Behavior**: `MarginClearinghouse` is USDC-only. All margin locking, settlement debits/credits, and seizure paths operate on settlement USDC (`lockMargin`, `seizeUsdc`, `settleUsdc`).
- **Guard**: `lockMargin` enforces `balanceUsdc(accountId) >= lockedMarginUsdc[accountId] + amountUsdc` — physical USDC must back every dollar of locked margin.
- **Impact**: Trader losses can only socialize once the account's settlement USDC and locked margin are exhausted.

#### No Oracle Staleness in Clearinghouse

- **Behavior**: Not applicable in V1 because the clearinghouse does not price non-USDC collateral.
- **Impact**: Clearinghouse valuation does not depend on external asset oracles.
- **Mitigation**: Future multi-asset support would need explicit staleness and pricing rules before reintroduction.

### HousePool Limitations

#### Seed Lifecycle Gate

- **Behavior**: Once bootstrap seeding begins for either tranche, the protocol does not allow new risk-increasing order commits or ordinary tranche deposits until both tranche seed positions exist on-chain. Even after both seeds exist, steady-state trading/liquidity stays disabled until the owner explicitly activates it.
- **Impact**: This prevents the protocol from drifting into a partially seeded or accidentally live trading state before initialization is intentionally complete, which would otherwise create ambiguous ownership for early revenue and recapitalization flows.

#### ERC-4626 Deposit View Parity

- **Behavior**: `TrancheVault.maxDeposit()` and `maxMint()` now use the same `HousePool.canAcceptTrancheDeposits()` gate as live deposits.
- **Effect**: ERC-4626 max views return `0` not only when lifecycle or senior-impairment rules block deposits, but also when tranche deposits are paused, mark freshness is required but stale, or bootstrap assignment is pending through `unassignedAssets`.
- **Integration note**: Offchain routers and frontends can now treat `maxDeposit() == 0` / `maxMint() == 0` as a truthful signal that ordinary tranche deposits would currently revert.

#### Stale Mark Blocks Withdrawals and Yield Accrual

- **Behavior**: When open positions exist and `lastMarkTime` exceeds `markStalenessLimit` (default 60s), `_reconcile()` skips yield accrual and MtM distribution entirely without resetting `lastReconcileTime`, `withdrawSenior`/`withdrawJunior` revert via `_requireFreshMark()`, and `finalizeSeniorRate()` updates the configured rate without accruing stale-window senior yield. During genuine oracle-frozen windows, these paths use `fadMaxStaleness` instead.
- **Impact**: During stale oracle periods, LP withdrawals are blocked and senior yield does not accrue or get backfilled via rate finalization; if governance finalizes a new senior rate while the mark is stale, that stale-window elapsed accrual time is intentionally truncated rather than preserved. This prevents withdrawals at stale NAV while still allowing already-funded pending recapitalization / zero-principal trading buckets to settle without stale mark-dependent repricing.
- **Clock semantics**: HousePool maintains a separate senior-yield checkpoint clock from the waterfall reconcile clock. Any stale-path principal mutation resets the senior-yield checkpoint before mutating principal, preventing later fresh reconciles from accruing yield over time that belonged to the pre-mutation principal base.
- **Resolution**: Any keeper or user can call `router.updateMarkPrice()` with a fresh Pyth payload to unblock operations.

#### Senior Yield is a Preferred Return, Not a Fixed Coupon

- **Behavior**: `unpaidSeniorYield` accrues continuously but is only paid from surplus revenue in `_distributeRevenue`. During break-even periods (no trading surplus), yield accumulates without being transferred from junior to senior.
- **Impact**: Senior LPs receive 0% during break-even while their capital is locked behind position liabilities. `unpaidSeniorYield` has waterfall priority — it is paid first from future surplus, before any revenue flows to junior.
- **Rationale**: Design choice to preserve junior's loss-absorption buffer. Transferring yield from junior capital during inactivity would create a death-spiral risk: junior shares decline -> LPs withdraw -> smaller buffer -> pool fragility. Execution fees are protocol revenue and are excluded from LP equity; LP yield comes from VPI charges, funding spreads, and realized trader losses.
- **Alternative considered**: Transferring yield from `juniorPrincipal` to `seniorPrincipal` each reconciliation (true fixed coupon). Rejected because it weakens the loss buffer and introduces reflexive withdrawal incentives for junior LPs.

### TrancheVault Limitations

#### Deposit Cooldown

- **Behavior**: 1-hour cooldown after depositing prevents same-block or near-block withdrawal. Self-deposits reset the receiver cooldown, and meaningful third-party top-ups (≥5% of receiver's balance) also reset the receiver cooldown.
- **Impact**: Users cannot deposit and immediately withdraw, even if the vault's share price has not changed.
- **Griefing surface**: A third party can reset a victim's cooldown by depositing ≥5% of the victim's balance to their address. This requires permanently donating that USDC (it becomes the victim's LP shares), making the attack economically irrational. Integrators should be aware of this if building time-sensitive withdrawal flows.
- **Rationale**: Prevents share price manipulation via flash loans or MEV sandwich attacks on LP deposits.

### Emergency Pause

- **OrderRouter**: Owner can instantly pause via `pause()`. When paused, `commitOrder` reverts (`EnforcedPause`). `executeOrder`, `executeLiquidation`, `updateMarkPrice`, and `claimEth` remain operational — protective actions are never blocked.
- **HousePool**: Owner can instantly pause via `pause()`. When paused, `depositSenior` and `depositJunior` revert. Withdrawals via TrancheVault remain operational — users can always exit.
- **CfdEngine**: Not directly pausable (all entry is gated by OrderRouter's `commitOrder`).
- **MarginClearinghouse**: Not pausable (users must always be able to deposit/withdraw margin and exit positions).

### Decimal Handling

| Asset/Oracle | Decimals | Notes |
|--------------|----------|-------|
| USDC | 6 | Collateral token |
| Position Size | 18 | Synthetic token units |
| Oracle Price | 8 | Pyth normalized output |
| Basket Price | 8 | `_computeBasketPrice()` output |
| Funding Index | 18 | WAD precision accumulators |
| PnL | 6 | `size(18) × priceDiff(8) / 1e20 = USDC(6)` |
| Funding PnL | 6 | `size(18) × indexDelta(18) / 1e30 = USDC(6)` |
| TrancheVault Offset | 3 | 1000x inflation attack protection |

### Fee Structure

| Fee | Rate | Notes |
|-----|------|-------|
| Execution Fee | 4 bps (0.04%) | Charged on notional at open and close |
| Funding | Variable | Kinked curve: 0→15% APY (linear), 15%→300% APY (quadratic) |
| Keeper Bounty | 15 bps (0.15%) | Floor: $5 USDC. Paid from vault on liquidation |

Fees are hardcoded (execution = 4 bps, bounty = 15 bps). Funding curve parameters are admin-configurable via `proposeRiskParams()`/`finalizeRiskParams()`.

## Emergency Procedures

### Emergency Pause Procedure

1. Owner calls `router.pause()` and/or `pool.pause()` — takes effect immediately
2. No new trades can be committed; no new LP deposits accepted
3. Existing orders continue executing; liquidations remain operational; LP withdrawals allowed
4. Investigate the incident
5. Owner calls `router.unpause()` and/or `pool.unpause()` to restore normal operations

### Suspected Oracle Manipulation

1. Owner calls `router.pause()` — immediately blocks all new order commitments
2. Existing orders still execute (keepers drain the queue) but no new ones can enter
3. Liquidations remain operational with fresh oracle prices
4. Investigate the oracle issue
5. Owner calls `router.unpause()` when resolved

### Keeper Infrastructure Failure

1. Orders queue up in the FIFO queue but are not executed
2. Orders still expire once `maxOrderAge` elapses, but users cannot cancel queued intents manually
3. Users can continue committing orders (they queue)
4. Resume keeper bots to drain the queue
5. **Risk**: Stale orders may execute at unfavorable prices. Users should use `targetPrice` for slippage protection.

### Extreme Skew

1. The funding curve's quadratic Zone 2 (25%→40% skew) creates a "wall of APY" at up to 300% annualized
2. At 40% skew ratio, no new orders on the majority side are accepted (VPI becomes extremely expensive)
3. If skew persists, owner can adjust `maxSkewRatio` downward to force earlier rejection
4. MMs are financially incentivized to heal skew via VPI rebates

### Bad Debt Cascade

1. Multiple liquidations creating bad debt erode `vault.totalAssets()`
2. The solvency invariant (`vault >= maxLiability`) blocks new opens but allows closes and liquidations
3. LP withdrawals are restricted by the withdrawal firewall
4. If vault is critically depleted, owner should:
   - Set `fadMarginBps` very high (force all positions to be liquidatable)
   - Let keepers clear remaining positions
   - LPs bear losses pro-rata through reduced share value
5. After recapitalization or full position clearance:
   - `clearBadDebt()` resets the accumulated bad debt counter
   - `clearDegradedMode()` exits the degraded latch, re-enabling risk-increasing trades

## Strict Asset Isolation: No External Yield in Core Perpetuals

While the spot synthetic side of Plether utilizes idle USDC for yield generation (via Morpho), the Perpetuals HousePool strictly holds 100% pure, unencumbered USDC. External yield integrations (such as deploying excess House Pool capital to lending markets) are explicitly prohibited at the core clearing layer for the following security and solvency reasons:

### 1. Preservation of Mathematically Bounded Solvency

Plether's primary invariant is its O(1) solvency invariant: the Vault must always hold enough raw capital to pay out the absolute maximum liability of all open positions simultaneously (`vault.totalAssets() >= max(globalBullMaxProfit, globalBearMaxProfit)`).

Replacing physical USDC with third-party IOUs (e.g., ERC-4626 lending shares) degrades this mathematical guarantee into a third-party liquidity assumption. The protocol would no longer have the cash; it would only have a promise that an external protocol will provide the cash upon request.

### 2. Liquidity Mismatch and Correlation of Crises

Perpetual contracts require instantaneous liquidity. When a market volatility event occurs (e.g., a sudden crash in the US Dollar Index), winning traders will immediately realize profits and withdraw USDC.

However, in DeFi, liquidity crises are highly correlated. During extreme market volatility, lending markets frequently hit 100% utilization as borrowers scramble to avoid liquidations or lenders panic-withdraw. If House Pool capital were deployed to a lending protocol that reached 100% utilization, on-demand withdrawals would revert. This would functionally brick the perpetuals exchange, preventing winning traders from withdrawing their payouts precisely when they need them most.

### 3. Contagion and Smart Contract Risk

Integrating an external yield protocol into the HousePool forces all system participants — Traders, Junior LPs, and Senior LPs — to implicitly assume the smart contract risk, oracle risk, and bad debt risk of that external protocol. Maintaining a strictly isolated USDC pool ensures that an exploit or bad debt event on an external lending market cannot cause systemic contagion that drains the Plether clearinghouse.

### 4. Opt-In Yield via Overlay Vaults

Yield starvation for Senior LPs during low-volume periods is a recognized trade-off for systemic safety. If users demand baseline yield, it must be architected as a separate, opt-in overlay vault built on top of the base protocol. This allows yield-seeking LPs to voluntarily take on external smart contract and utilization risks without compromising the 100% pure USDC backing of the core CfdEngine and active traders.

## Security Contact

For responsible disclosure of security vulnerabilities, please contact:
contact@plether.com

## Audit Status

Not yet audited. The perpetuals engine is pre-deployment.

### Coverage

| Component | Status |
|-----------|--------|
| CfdEngine | Not yet audited |
| CfdMath | Not yet audited |
| OrderRouter | Not yet audited |
| MarginClearinghouse | Not yet audited |
| HousePool | Not yet audited |
| TrancheVault | Not yet audited |

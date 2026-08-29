# Plether Perps

Plether Perps is a bounded, delayed-order perpetuals engine for synthetic USD-directional exposure.

This package depends only on `shared` and third-party libraries. Build it independently from the repository root with
`forge build --root packages/perps` and test it with `forge test --root packages/perps`. Its package-owned tests live under
`packages/perps/test/perps/`.

For the formal market-design argument, common-mark liability theorem and
counterexample, empirical FX-basket analysis, and reproducible reference model,
read [`WHITEPAPER.md`](WHITEPAPER.md) or the
[publication PDF](../../output/pdf/plether-perps-bounded-credit-whitepaper.pdf).

Traders post USDC margin, submit delayed orders through `OrderRouter`, and take
`LONG` or `SHORT` exposure against a tranched USDC `HousePool`. LP capital sits
behind senior and junior tranche vaults. The system is designed so worst-case
trader liability is bounded at entry because the market price is capped:

```text
0 <= markPrice <= CAP_PRICE
```

If you want the accounting model first, read [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md). If you want the operational and trust assumptions, read [`SECURITY.md`](SECURITY.md). If you want a one-page system map, read [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md). If you are preparing for audit review, start with [`PRE_AUDIT_GUIDE.md`](PRE_AUDIT_GUIDE.md).

## Perps In 5 Minutes

### What traders are trading

- There is one bounded directional market.
- The instrument tracks Plether's dollar index through a raw FX-basket mark, not a raw DXY index print.
- That raw mark moves inversely to dollar strength.
- `LONG` profits when that mark falls (USD strengthens).
- `SHORT` profits when that mark rises (USD weakens).
- Payouts are bounded because the mark is clamped to `CAP_PRICE`.

### Who does what

- Traders deposit USDC into `MarginClearinghouse`, then submit delayed orders through `OrderRouter`.
- Keepers execute queued orders and liquidations using Pyth update data.
- LPs deposit USDC into `HousePool` through senior and junior `TrancheVault`s.
- `CfdEngine` is the canonical ledger. It does the math but does not custody raw tokens.
- Governance installs one `EmergencyPauseCoordinator` as the pauser on both `OrderRouterAdmin` and `HousePool`.
  Its separately rotatable guardian can trigger fixed risk-off, LP-settlement-only, or full-containment actions;
  governance alone retains every release and role-assignment authority.

### Core product rules

- Delayed orders only. There is no same-tx trader market-order path.
- Every externally committed ordinary order is a caller-bounded V2 request. It pins an exact target, deadline,
  allowed execution regimes, execution configuration, and financial limits before capital is reserved. The only
  configuration-unpinned requests are internally constructed TP/SL parent and close-attempt orders authenticated by the
  Router's immutable position-protection path.
- `clientOrderId` values are permanent inside each account namespace. Exact request replay returns the original
  order id without side effects; reusing the id for a different request reverts.
- One live position per account address at a time. Side flips must pass through a close.
- Every open, increase, and close size is an exact multiple of the canonical 100-token lot (`1e20` raw size units).
- Ordinary FIFO orders are binding once committed. Users cannot cancel queued opens, closes, or a close attempt generated
  by a triggered protection. The emergency exception is an administrator-recorded, monotonic risk-off cutoff: opens at or
  below that cutoff are terminally invalidated and their remaining margin and execution bounty are refunded to
  internal settlement.
- An off-queue `PendingOpen` or `Armed` protection can be cancelled or replaced before it triggers.
- Each account may have one full-position OCO take-profit/stop-loss protection at a time.
- Queue execution is FIFO from the global head.
- LP-capital carry is used instead of side-to-side funding.
- The optional Junior maintenance fee is share dilution, not a performance fee. It deploys disabled at `0 bps` and
  can be enabled only through the vault's 48-hour governance delay.
- If the HousePool is short on cash, trader profits can become senior trader claims instead of reverting the state transition; keeper bounties are funded from reserved trader margin inside the clearinghouse.

### Units and accounts

- USDC amounts and margin accounting use 6 decimals.
- Prices use 8 decimals.
- Position size uses 18 decimals and must be divisible by `1e20` (100 tokens).
- Accounts are tracked directly by trader address.

## Canonical Entrypoints

For the intended product-facing surface, see [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md).

In practice, the compact public API is:

- Traders:
  - `MarginClearinghouse.depositMargin(uint256)`
  - `MarginClearinghouse.withdrawMargin(uint256)`
- Ordinary trade actions:
  - `OrderRouter.commitOrder(OrderV2Types.OrderRequest)`
- Protection actions, called directly on the immutable Book returned by `OrderRouter.positionProtectionBook()`:
  - `PositionProtectionBook.commitOpenOrderWithProtection(...,PositionProtectionParams)`
  - `PositionProtectionBook.createPositionProtection(PositionProtectionParams)`
  - `PositionProtectionBook.replacePositionProtection(uint64,PositionProtectionParams)`
  - `PositionProtectionBook.cancelPositionProtection(uint64)`
- Keepers:
  - `OrderRouter.executeOrder(uint64,bytes[]) -> OrderV2Types.ExecutionResult`
  - `OrderRouter.executeOrderBatch(uint64,bytes[]) -> OrderV2Types.BatchResult`
  - `OrderRouter.updateMarkPrice(bytes[])`
  - `PositionProtectionBook.triggerPositionProtection(uint64,bytes[])`
  - `PositionProtectionBook.retryPositionProtectionClose(uint64)`
  - `OrderRouter.executeLiquidation(address,bytes[])`
  - `OrderRouter.executeLiquidationBatch(address[],bytes[])`
  - `OrderRouter.clearRiskOffOrder(uint64)` for unpaid, oracle-free emergency-open cleanup
  - LP epoch clearing through the route reported by `SettlementMonitorLens.requiredExecutionPath`:
    `HousePool.settleLpEpoch(uint256,uint256)` for `CachedMark` or `OrderRouter.settleLpEpoch(bytes[])` for
    `AtomicOracleRefresh`
- LPs:
  - the configured Senior or Junior `TrancheVault`: asynchronous `requestDeposit` / `requestRedeem`, request
    cancellation and status views, and funded-request claims through `deposit` / `mint` or `withdraw` / `redeem`
  - permissionless synchronized clearing through the Lens-selected direct-Pool or Router route; on
    `AtomicOracleRefresh`, the Router validates one Pyth mark under the reported minimum-publish-time policy and settles
    the bounded batch atomically
- Readers:
  - `PerpsPublicLens`, including `getTrancheQueues(bool)` for synchronized heads/backlog and
    `getLpRequestState(bool,uint256,address)` for controller request balances. LP, queue, and protocol status expose
    `lpEpochSettlementPaused`; request admission may remain enabled while settlement/withdrawal funding is not live.
  - `PositionProtectionBook.activePositionProtectionId(address)` /
    `PositionProtectionBook.getPositionProtection(uint64)` for canonical retained protection state. `linkedOrderId`
    is the latest attempt; combine attempt events with lifecycle outcomes for complete history.
  - `SettlementMonitorLens` for explicitly observed epoch operations, fail-soft oracle diagnostics, and bounded
    accounting/custody health checks; it is an operator/security surface, not the product API or a settlement
    authorization oracle
  - the independently predeployed, exactly Router-bound `OrderLifecycleBook` exposed by `lifecycleBook()`:
    `currentExecutionConfigHash()`,
    `resolveClientIntent(...)`, `clientIntent(...)`, `pendingIntent(...)`, `pendingPolicy(...)`,
    `isProtectionAttempt(...)`,
    `lifecycleStatus(...)`, and `outcome(...)`
  - the read-only `IHousePool` capacity getters exposed by `HousePool`:
    `getSeniorDepositCapacity()`, `reservedSeniorDepositAssetsUsdc()`, and
    `areSeniorDepositReservationsWithinLimits()`
  - `CfdEngineLens.previewOpen(...)` / `previewClose(...)` for trade-ticket simulations using caller-supplied oracle prices

The simplified public interfaces live in `packages/perps/src/interfaces/`:

- `IMarginAccount.sol`
- `IPerpsTraderActions.sol`
- `IPositionProtectionActions.sol`
- `IPositionProtectionViews.sol`
- `PositionProtectionTypes.sol`
- `IPerpsTraderViews.sol`
- `ICfdEngineLens.sol` for `previewOpen(...)` / `previewClose(...)` trade-ticket previews
- `IPerpsLPActions.sol` for configured-vault-to-pool integration hooks, not direct LP calls
- `IPerpsLPViews.sol`
- `IAsyncTrancheVault.sol` for the complete asynchronous LP request, cancellation, estimate, and claim surface
- `IERC7540.sol` and `IERC7575.sol` for the standard operator/request/claim and vault-entry fragments
- `IPerpsKeeper.sol`
- `IOrderLifecycleBook.sol` and `OrderV2Types.sol` for V2 intent policy, lifecycle state, receipts, and
  machine-readable execution results
- `IProtocolViews.sol`
- `PerpsViewTypes.sol`
- `ISettlementMonitorLens.sol` and `SettlementMonitorViewTypes.sol` for bounded operator/security observations

The wider engine, clearinghouse, router, and house-pool interfaces still exist for tests, admin tooling, and deep accounting inspection, but they are not the recommended product integration surface.
The three capacity getters above are the deliberate direct-read exception. The active vault-authorized hooks declared
by `IHousePool` / `IPerpsLPActions` are Senior deposit reservation and release. Permissionless LP clearing follows the
route reported by `SettlementMonitorLens`: direct `HousePool` settlement for `CachedMark`, or
`OrderRouter.settleLpEpoch(bytes[])` for `AtomicOracleRefresh`. With open positions outside oracle-frozen mode, the
HousePool callback is Router-only. Frozen mode selects the cached route only while the mark is fresh under the
applicable frozen-mode limit; a frozen stale mark selects atomic refresh. LP applications must perform actions through
the relevant `TrancheVault`.

### Trade-ticket previews

Frontends should use `CfdEngineLens.previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime)` to simulate opens and same-side increases before committing an order. The lens is read-only: it uses the caller-supplied `oraclePrice` and `publishTime`, does not fetch Hermes data, does not ingest Pyth updates, and does not mutate engine mark state.

Preview units match the rest of perps:

- USDC amounts, fees, VPI, margin, equity, and PnL use 6 decimals.
- Oracle prices and returned execution/liquidation prices use 8 decimals.
- Position sizes use 18 decimals.
- Signed fields such as `vpiUsdc`, `tradeCostUsdc`, `postVpiAccrued`, `postUnrealizedPnlUsdc`, and `postEquityUsdc` may be negative.

`executionPrice` is clamped to `CAP_PRICE`. `valid`, `invalidReason`, and `failureCategory` are authoritative for whether the order would pass planner validation. For invalid previews, numeric economics or post-trade fields may be zero or partial depending on where planning stopped.

For valid previews, `postSize`, `postMarginUsdc`, `postEntryPrice`, `postVpiAccrued`, post-trade health, and liquidation fields are projected from the same planner/accounting logic used by live execution. `hasLiquidationPrice == false` means no liquidation threshold exists inside `[0, CAP_PRICE]`. For `LONG` positions, `liquidationPrice` is the lowest price in the high-price liquidatable region. For `SHORT` positions, it is the highest price in the low-price liquidatable region.

Close previews expose frozen-market pricing separately from VPI. `frozenSpreadUsdc` is the fixed spread assessed on the reduced notional, `frozenSpreadPaidUsdc` is the portion actually retained or collected for LPs, and `frozenSpreadWaivedUsdc` is the uncollectible portion waived on a terminal full close. These values are zero outside `oracleFrozen`, and a valid preview preserves `frozenSpreadUsdc == frozenSpreadPaidUsdc + frozenSpreadWaivedUsdc`. Successful closes with a nonzero assessment emit `FrozenCloseSpreadSettled(account, assessedUsdc, paidUsdc, waivedUsdc)` from `CfdEngineSettlementSidecar`, so the live result is reconstructible from durable logs.

## Runtime Components

The main runtime and read surfaces are:

- `MarginClearinghouse`: trader custody and typed margin buckets.
- `OrderRouter`: thin external shell for bounded delayed-order commits, queue custody, authenticated sidecar
  callbacks, and clearinghouse-reserved keeper bounties.
- `OrderLifecycleBook`: independently predeployed source for permanent account-scoped idempotency, pending execution
  policy, compact terminal outcomes, and canonical full receipt events. It is immutable-bound to the predicted Router
  and exact Engine, Clearinghouse, and HousePool dependencies.
- `CfdOrderPolicyEvaluator`: separately deployed stateless coordinator that rebuilds the Engine's authoritative
  snapshot, calls the configured planner, and applies the order's financial bounds before Engine mutation.
- `OrderRouterV2ExecutionSidecar`: separately deployed stateless delegate module for single/batch oracle
  orchestration, policy classification, Engine execution, and receipt construction.
- `PositionProtectionBook`: stateful Router-deployed action/view surface and retained TP/SL lifecycle store.
- `OrderRouterLiquidationBatchSidecar`: separately predeployed, immutable, stateless keeper implementation for mark
  refresh, protection-trigger oracle resolution and orchestration, single liquidation, risk-off-aware liquidation
  batches, atomic-refresh LP-epoch settlement, and the active-oracle portion of authenticated Router configuration.
  Despite its historical name, it serves all of those Router code-size-split paths.
  `OrderRouter.liquidationBatchSidecar()` returns this contract, which is distinct from the protection Book.
- `CfdEngine`: canonical execution ledger and solvency boundary.
- `TerminalNavBookV2`: Engine-only exact terminal price-PnL index used symmetrically for LP entry and exit NAV.
- `CfdEngineSettlementSidecar`: externalized open/close/liquidation settlement orchestration used by the engine.
- `CfdEnginePlanner`: externalized open/close/liquidation plan builder wired into the engine after deployment.
- `HousePool`: LP capital, liabilities, reserves, and tranche waterfall.
- `HousePoolRedemptionMathSidecar`: separately deployed stateless pure redemption-budget math used by its immutable
  HousePool binding to preserve bytecode headroom; it has no mutable state, authorization, or upgrade path.
- `TrancheVault`: ERC-4626 LP vault wrappers for senior and junior capital.
- `PerpsPublicLens`: compact product-facing read layer.
- `SettlementMonitorLens`: read-only epoch-settlement, oracle, and invariant diagnostics for keepers and security
  monitoring. Its constructor-created `SettlementMonitorLensSidecar` is a facade-bound code-size implementation
  detail, not a second public or canonical read surface.
- `EmergencyPauseCoordinator`: least-authority guardian boundary exposing exactly three fixed actions: Router
  risk-off plus LP-entry pause, LP-settlement-only hold, and atomic full containment. It cannot unpause, set prices,
  change protocol configuration, move funds, or invoke arbitrary targets.
- `CfdEngineAccountLens` / `CfdEngineProtocolLens`: richer audit and operator read layers.

### Intended boundaries

- `CfdEngine` and `ICfdEngineCore` are the canonical runtime truth for execution, liquidation, and protocol status.
- `CfdEngineSettlementSidecar` executes open, close, and liquidation settlement choreography, while `CfdEngine` remains the storage owner.
- `CfdEngine`, `TerminalNavBookV2`, `CfdEnginePlanner`, `CfdEngineSettlementSidecar`, and `CfdEngineAdmin` are
  deployed separately. The empty immutable-bound terminal book is wired once through
  `CfdEngine.setTerminalNavBook(...)`; the planner, sidecar, and admin are wired once through
  `CfdEngine.setDependencies(...)`.
- `MarginClearinghouse` owns trader settlement balances and locked-margin custody buckets.
- `OrderRouter` owns only live queue records while execution-bounty value remains reserved in
  `MarginClearinghouse`. A terminal transition unlinks and fully deletes the Router record; permanent identity and
  outcome state live in `OrderLifecycleBook`.
- `OrderLifecycleBook` is independently predeployed with the predicted Router, Engine, Clearinghouse, and HousePool
  bindings and accepts mutations only from that Router. The Router receives it as its eighth and final constructor
  dependency and validates its code and all four immutable bindings before accepting it. The Book has no owner,
  setter, upgrade, or migration path.
- `PositionProtectionBook` owns retained position-protection records and emits their lifecycle events. `PendingOpen`,
  `Armed`, and `Latched` records are off queue. A successful trigger or permissionless retry creates one ordinary
  queued close attempt; at most one attempt is live for a protection at a time.
- The Router accepts the predeployed lifecycle Book and creates the position-protection Book in its constructor. It
  exposes them through `lifecycleBook()` and `positionProtectionBook()`. The Router does not forward public protection
  selectors: clients call the discovered protection Book directly. That Book has no token custody and cannot mutate
  FIFO by itself; it invokes narrow Router host paths for the parent open, trigger mark refresh, and close-attempt
  append.
- `CfdOrderPolicyEvaluator` and `OrderRouterV2ExecutionSidecar` are deployed separately and supplied to a fresh
  Router. The execution sidecar is fixed by the Router, has no mutable storage or upgrade path, and rejects direct
  stateful calls. Router execution entrypoints delegate to it so external Clearinghouse, lifecycle Book, Oracle, and
  Engine calls retain the Router as caller. The reusable sidecar does not claim that every delegatecaller is the
  protocol Router; lifecycle Book, Clearinghouse, and Engine caller checks prevent another host context from acquiring
  protocol authority.
- Each prepared V2 execution item crosses a Router self-call boundary before the Router delegates back to the
  execution sidecar. The callback is self-only. This creates an item-local rollback frame: retryable Engine, policy,
  or receipt failures leave that order and its reservation pending without undoing earlier terminal items. Oracle/Pyth
  preparation and the Engine mark update remain the explicitly documented outer transaction boundary.
- Public mark refresh, single liquidation, risk-off-aware liquidation batch, and atomic-refresh LP-epoch settlement
  remain Router selectors. Their large stateless implementations are reached only by Router `delegatecall` into
  the separately deployed `OrderRouterLiquidationBatchSidecar`. The delegated code reads integrations through external
  Router getters and does not read or write Router storage by layout. Router-owned mutations use authorized external
  self/item calls. Direct calls to those selectors on the sidecar revert.
  The delegate frame preserves the Router entrypoint's `msg.sender`, uses the Router as `address(this)` and direct-event
  address, and makes downstream contracts see the Router as caller. Events emitted by an external callee still originate
  from that callee. On a protection trigger, the Book remains the authenticated Router caller and its trailing
  keeper/protection-id payload preserves the keeper's refund and bounty identity.
- The lifecycle Book, keeper sidecar, and Router are deployed as consecutive `CREATE`s with the Router address
  predicted two nonces ahead: Book first, sidecar second, Router third. The Router constructor accepts the Book only
  when its four core bindings match and accepts the sidecar only when code is present and its immutable `ROUTER()`
  equals the Router being constructed.
  Its logic reads the persistent risk-off cutoff, rejects direct and foreign-context execution, and can reach Router
  state-changing callbacks only through self-only item calls. There is no setter or upgrade path.
- `HousePool` owns LP capital and pays engine-authorized obligations that must leave the pool.
- `HousePool` also owns an LP-entry pause and an independent epoch-settlement hold. The hold blocks both direct and
  Router-mediated epoch clearing without blocking new requests, reconciliation, or already-funded claims.
- `PerpsPublicLens` is the default read surface for product consumers.
- `SettlementMonitorLens` is the default bounded settlement-monitoring surface for keeper and security automation.
  Its internal sidecar accepts diagnostic-builder calls only from its constructor-bound facade; the sidecar's public
  bindings are constructor-set storage with no setter or delegatecall path.
- `EmergencyPauseCoordinator` is immutable-bound to the exact RouterAdmin and HousePool. The monitor remains
  advisory: off-chain monitoring archives its evidence and the configured guardian independently decides whether to
  call the coordinator with reason/evidence hashes.
- The account and protocol lenses are for deeper diagnostics, tests, audits, and operator tooling.

## Trader Lifecycle

1. Deposit USDC into `MarginClearinghouse`.
2. Read `OrderLifecycleBook.currentExecutionConfigHash()` and the Engine, Clearinghouse, Pool, and Oracle state needed
   to choose an exact target and financial policy.
3. Submit `OrderRouter.commitOrder(OrderV2Types.OrderRequest)`. The request carries a nonzero account-scoped
   `clientOrderId`, the trade fields, and mandatory `ExecutionBounds`.
4. For a new id, the Book permanently binds the full intent hash, the Router records a live FIFO order, and
   `MarginClearinghouse` reserves committed margin plus the quoted keeper bounty. The transaction is atomic.
5. A keeper later calls `executeOrder(...)` or `executeOrderBatch(...)` with Pyth update data. The V2 execution
   sidecar resolves the first valid post-commit tick in live/FAD-only markets, or the validated stored basket under
   oracle-frozen policy, then checks queue, deadline, configuration, mode, slippage, gas, and financial policy.
6. Inside an item-local rollback frame, the Clearinghouse releases the order reservation without checkpointing carry,
   `CfdOrderPolicyEvaluator` reconstructs the canonical Engine settlement snapshot and calls the configured planner,
   and `CfdEngine.processOrderTyped(...)` deterministically applies the same transition.
7. A terminal transition settles the bounty, fully deletes the Router's live order record, and finalizes the Book
   last. The Book stores a compact outcome and emits the complete `OrderFinalized` receipt. A retryable failure rolls
   back the item, including its reservation release, so it remains pending.

Important details:

- `targetPrice` is mandatory and cannot be zero. V2 has no zero-target market-order sentinel.
- Client ids are permanent per account. Exact replay is resolved before deadline, configuration, market-state, or
  lifecycle validation, so replay still returns the original id after execution or failure and never creates a
  second reservation, queue entry, counter increment, or event. A same-account id with any changed request field is
  a conflict; another account may independently use the same bytes32 value.
- There is no user cancellation path.
- Non-lot sizes are rejected at commit, before any order id or margin/bounty reservation is created.
- Open orders are rejected during degraded mode and close-only windows.
- Deadline equality is valid. An order expires only when `block.timestamp > validUntil`.
- Typed planner rejections, typed policy violations, slippage, expiry, and pinned-configuration mismatch are
  terminal. Close-only, same-block/MEV boundaries, unavailable historical data, insufficient execution gas,
  mark-price ordering, and unknown, panic, out-of-gas, empty, or malformed dependency failures are retryable and
  leave the FIFO head pending.
- The Router keeps an explicit post-Engine gas reserve for settlement, Book finalization, and result construction.
  It never treats an unrecognized revert shape as a terminal business-policy decision.
- A RouterAdmin emergency pause records an inclusive, monotonic `riskOffOrderCutoff`. Pending opens at or below it
  can never execute, even after governance unpauses. Permissionless cleanup returns their remaining committed margin
  and complete execution bounty to the trader's free internal settlement without an oracle or Engine checkpoint;
  the protocol incident keeper pays cleanup gas and receives no bounty.
- Execution-time user-invalid opens, protocol-state invalidations, and terminal-invalid closes pay the keeper from reservation so FIFO cleanup remains incentive compatible.
- Close orders can still execute during genuine frozen-oracle windows using the last valid mark subject to the relaxed frozen-market rules and the fixed LP-owned frozen-close spread.
- Close-intent queue validation is account-local and bounded by the per-account pending-order queue.

### Take-profit and stop-loss protection

Position protection is a conditional full-position close, not an immediate or guaranteed-price stop. One account may
have one combined OCO protection containing a take-profit leg, a stop-loss leg, or both. Zero disables one leg; both
cannot be disabled.

All protection actions and canonical protection reads target the `PositionProtectionBook` returned by
`OrderRouter.positionProtectionBook()`. Indexers must subscribe to protection lifecycle events at that Book address;
ordinary `OrderCommitted` and order-terminal events for every linked close attempt still originate from the Router.

Protection can be created against an existing position or staged in the same transaction as a new opening commitment:

```text
commit open with protection
        |
        v
    PendingOpen -- parent open succeeds --> Armed
        |                                  |
        | parent fails/expires             | valid trigger atomically queues attempt #1
        v                                  v
      Failed                           Triggered
                                      /        \
                              executes          fails/expires
                                 |                    |
                                 v             exact position remains?
                              Executed             /       \
                                                 yes        no
                                                  |          |
                                                  v          v
                                               Latched     Failed
                                                  |
                                        permissionless retry
                                                  |
                                                  +----> Triggered
```

- The opening position still appears only when its delayed FIFO order executes. Successful opening execution arms the
  protection atomically against the resulting side and full size, so there is no externally observable unprotected
  position between those two state changes.
- Parent-open failure or expiry terminally fails the staged protection and releases its two protection bounties. The
  parent opening execution bounty retains the ordinary terminal-order policy.
- Cancelling `PendingOpen` protection detaches it but does not cancel the binding parent open. That open may later
  execute without protection.
- `createPositionProtection(...)`, `replacePositionProtection(...)`, and
  `commitOpenOrderWithProtection(...)` are nonpayable trader calls. They validate trigger geometry against the engine's
  cached fresh neutral mark and do not ingest Pyth data.
- Protection bounties are locked before safety is evaluated. For an existing position, the post-lock gate uses the
  Engine-configured canonical planner's V2 exact-price predicate rather than duplicating risk math. It supplies exact
  entry basis and price-risk equity of only PnL pledge (`position.margin`) plus the same-account trader claim plus exact
  capped unrealized PnL. Free settlement and generic action, order, liquidation, VPI, and protection reserves are not
  price collateral. Any uncovered carry or underfunded `max(-vpiAccrued, 0)` reserve fails closed, and exact-price equity
  must be strictly above the stricter of initial margin and the active normal/FAD maintenance requirement. An attached
  open locks protection value first, so the ordinary open planner sees the remaining balances when it admits and later
  executes the parent.
- `triggerPositionProtection(...)` is a permissionless payable keeper call. It ingests current Pyth data, requires a
  later block and publish time after arming, and cannot trigger while `oracleFrozen`.
- A valid trigger pays the trigger keeper, permanently latches the observed leg, mark, and publish time, and appends
  one full-size market-style close attempt to the ordinary global FIFO
  tail using the internal side-dependent nonbinding target sentinel (`CAP_PRICE` for a LONG close and `1` for a SHORT
  close). While that attempt is live the protection is `Triggered`. The linked close is binding and inherits ordinary
  post-commit oracle timing, adverse execution pricing, expiry, terminal failure, and liquidation behavior.
- If a linked attempt fails without liquidation and the account still has the exact protected side and size, the
  protection returns to `Latched` rather than becoming terminal. Its trigger evidence and trade lock remain unchanged.
  A missing or mismatched position instead resolves the protection as `Failed` and follows ordinary paid attempt
  cleanup. The attempt is permanently retained in the lifecycle Book, while `linkedOrderId` continues to identify the
  most recent attempt.
- `retryPositionProtectionClose(...)` is permissionless and nonpayable. It is valid only for a `Latched` protection,
  requires that the exact protected side and size still exist and that the account has no pending Router order, does
  not refresh or re-evaluate the trigger, and appends a fresh attempt at the current FIFO tail with a new order id,
  commit timestamp, deadline, and live/FAD historical-oracle window. Retry remains available while protection commits
  are disabled, the Router is paused, the Engine is degraded, or the oracle is frozen; a frozen attempt executes under
  the ordinary frozen-close policy rather than the live/FAD historical window.
- Both the attached parent open and all protection close attempts are typed V2 requests constructed inside the authenticated
  protection path. Only those requests use `expectedConfigHash == bytes32(0)` as an internal unpinned marker. Fresh
  external `OrderRouter.commitOrder(...)` calls reject zero, and no external caller can opt an ordinary order out of
  configuration pinning.
- Relatched failure cleanup does not automatically enqueue the replacement and pays no keeper bounty. Instead, the
  original close execution bounty is rolled back into Book attribution and recycled into the next attempt without a
  second trader reservation. The bounty is paid once on eventual execution or forfeited once on liquidation.
- `PositionProtectionCloseAttemptQueued` identifies the first and every retried attempt and links it to the previous
  attempt id (`0` for the first attempt).
  `PositionProtectionCloseAttemptFailed` records the terminal reason and whether the exact-position check relatched the
  protection; `PositionProtectionTerminal` remains reserved for final protection resolution.
- While protection is `PendingOpen`, `Armed`, `Latched`, or `Triggered`, conflicting discretionary trade commitments are blocked;
  adding position margin remains available.

The raw basket-price conditions follow the protocol's position sides:

| Protected side | Take profit | Stop loss |
|---|---:|---:|
| `LONG` | mark at or below TP | mark at or above SL |
| `SHORT` | mark at or above TP | mark at or below SL |

Frontends that display the inverse dollar-oriented price must convert both values and inequalities before submitting
the 8-decimal raw basket triggers.

### V2 execution authority

`ExecutionBounds` defines the complete financial authority granted to a keeper. Every comparison is inclusive. Zero
is a real zero allowance, not an unbounded sentinel; use the relevant integer type's maximum when an application
intends no practical ceiling. Fields that are independently required nonzero on fresh external requests, including
`validUntil`, `expectedConfigHash`, `allowedExecutionModes`, and `maxPostLeverageBps`, cannot use zero. The sole
`expectedConfigHash` exception is the Router-authenticated TP/SL marker described above.

| Field | Meaning |
|-------|---------|
| `validUntil` | Absolute execution deadline; fresh commits require it after the current time and no later than the Router's current `maxOrderAge` |
| `allowedExecutionModes` | Bitmask authorizing `Live`, `Fad`, and/or `Frozen` execution |
| `expectedConfigHash` | Exact execution-critical configuration digest that must still be active for an external request; zero is reserved for authenticated internal TP/SL parent/attempt orders |
| `maxExecutionBountyUsdc` | Maximum quoted keeper bounty reserved at commit |
| `maxExecutionNotionalUsdc` | Maximum execution notional assessed by the canonical planner |
| `maxGrossAccountDebitUsdc` | Maximum evaluator-reported gross account debit, including settlement debit, consumed trader claims, and the reserved execution bounty |
| `maxActionChargeUsdc` | Maximum net planner-assessed action charge across carry, VPI, fee, and frozen spread as applicable |
| `maxExplicitFeesUsdc` | Maximum explicit execution fees |
| `maxPostPositionSize` | Maximum live size after execution |
| `minPostSettlementBalanceUsdc` | Minimum total internal settlement balance after execution and bounty disposition, including value classified in locked buckets |
| `minPostPositionEquityUsdc` | Minimum resulting live-position equity |
| `maxPostLeverageBps` | Maximum resulting leverage in basis points |

A terminal full close applies every non-position bound but skips post-position equity and leverage checks because no
position survives. No other path silently relaxes a caller bound.

### Trader claim balance

Profitable closes and some liquidation residuals can create a trader claim balance if the HousePool cannot immediately fund them.

- Trader claim balance is tracked by beneficiary balance: `traderClaimBalanceUsdc[account]`.
- There is no FIFO trader-claim queue.
- `settleTraderClaim(account)` is beneficiary-only and requires the caller to own `account`.
- Settlement is all-or-nothing for the account claim and only succeeds when aggregate trader claim liabilities are fully cash-covered.
- Claimed amounts are credited into `MarginClearinghouse`, not sent directly to the wallet.
- If the beneficiary still has a live position, settled claim value is credited directly into its PnL pledge instead
  of free settlement so value already counted in terminal NAV cannot be withdrawn and reused.

### Keeper bounty credit

Order and liquidation bounties are margin transfers inside `MarginClearinghouse`.

- Open and close execution bounties are locked from eligible free settlement as action reserve at commit time; they
  do not increase or consume the position's PnL pledge.
- Live-position custody is split between a price-PnL pledge and a dedicated liquidation-charge reserve. Pending-order
  and action reserves are separate again; only the PnL pledge enters the terminal price-loss cap.
- Position protection snapshots and reserves a trigger bounty plus a linked-close execution bounty at creation. The
  default reserve is `0.20 + 0.20 = 0.40 USDC`, funded from free settlement only.
- Cancellation before trigger refunds the unpaid protection reserve. Triggering pays the trigger portion exactly once
  and transfers attribution of the remaining portion to the generated close without reserving it again.
- A non-liquidation failure for which the exact protected position remains marks that attempt receipt
  `RetainedForProtectionRetry`, names no bounty recipient, and returns the same execution-bounty attribution to the
  latched protection. That relatching cleanup is intentionally unpaid; retry moves the retained amount into the fresh
  attempt without reserving or charging the trader again. Position mismatch instead uses ordinary paid cleanup.
- Successful execution credits the keeper's clearinghouse settlement balance from the reservation.
- The configured liquidation charge is capped by liquidation-reachable collateral, then allocated using timelocked
  `keeperShareBps` and `protocolShareBps` values whose sum cannot exceed `10_000`.
- The rounded-down keeper and protocol shares are credited directly inside `MarginClearinghouse`; the protocol share
  goes to `protocolTreasury`, while the exact remainder, including division dust, is transferred to `HousePool` as
  claimant-owned LP revenue.
- Liquidation forfeits any unpaid protection bounty to the treasury under the same exact-once reservation accounting.
  A `Triggered` protection's remaining bounty is owned by its live ordinary attempt, while a `Latched` protection owns
  the recycled bounty directly; neither is counted twice.

Protocol fees settle into the treasury clearinghouse account only when they are cash-collected from trader settlement or when remaining free `HousePool` cash can fund a top-up after senior trader claims and immediate trader payouts. The simplified custody model does not create protocol-fee receivables; uncredited fee portions stay in pool backing rather than becoming withdrawable treasury margin.

## LP Lifecycle

LPs provide USDC to the `HousePool`, which is split into senior and junior ERC-4626 tranche vaults.

- Senior gets a target coupon funded from junior NAV, plus last-loss protection.
- Junior absorbs first loss and receives residual upside.
- LP redemption requests escrow shares after the holder cooldown and size checks. Pending shares remain outstanding and
  exposed to tranche profit and loss until an epoch settlement funds and burns them.
- Ordinary tranche deposits and partial redemption requests must be at least `1 USDC` at the current estimate,
  preventing dust flows from forcing checkpoint churn while still allowing a complete dust exit.
- During `oracleFrozen`, matured redemption funding uses the stale-window policy with a fixed tranche-local
  surcharge, while deposit activation is deferred. Requests do not lock a price or fee; settlement fixes both.
- During `oracleFrozen`, bootstrap admin flows stay blocked: `initializeSeedPosition(...)` and `assignUnassignedAssets(...)` must wait for the oracle to become live again instead of inheriting the stale-window LP fee path.

Junior alone supports a governance-configurable maintenance fee. It starts at `0 bps` with no recipient, is capped at
`1,000 bps` nominal APR, and can change only after a 48-hour proposal delay. Accrued fees are paid by minting ordinary
transferable Junior shares to the recipient; no USDC leaves HousePool and no tranche principal, HWM, reserve, or
waterfall value is rewritten. Pricing and estimates use raw supply plus pending fee shares even before those shares
are minted. Pending deposits begin paying only when activated, while pending redemption shares pay until they are
funded and burned. Because accrual advances on completed Unix-hour boundaries, a mid-hour activation can receive less
than one hour of pre-activation fee exposure, while a mid-hour funded redemption can avoid less than one hour of
exposure. This bounded timing shift is the intended cost of hourly rather than per-second accounting.

Accrual uses completed Unix-hour periods and crystallizes only before an actual Junior supply mutation or fee-config
finalization; there is no public fee checkpoint. Each crystallization charges at most 8,760 hours and forgives any
older backlog. Accrual continues through settlement holds, oracle freezes, losses, and zero NAV. At zero NAV the
recipient's newly minted shares are initially worthless but participate in any later recovery. This is a maintenance
fee regardless of performance—there is no Junior HWM, cost basis, equalization, or fee assessed specifically at LP
exit.

Senior and Junior deposits and redemptions all use one five-minute request cutoff. Let `t = block.timestamp`,
`e = floor(t / 3,600)`, and `b = (e + 1) * 3,600`, the next round-hour boundary. Every request is routed as follows:

```text
requestEpoch(t) = e + 1, when t < b - 300
requestEpoch(t) = e + 2, when t >= b - 300
```

Equality belongs to the later epoch. An otherwise-valid request included during the final five minutes does not
revert; it rolls forward by one epoch. The numeric target is continuous across the hour boundary: for example,
requests included from 12:55:00 through 13:54:59 all target 14:00. The returned request id and emitted event are
authoritative, so a transaction submitted before the cutoff but included after it intentionally receives the later
id. Existing authorization, cooldown, pause, lifecycle, size, balance, and capacity checks still apply.

`TrancheVault.getRequestEpochWindow()` exposes the currently selected epoch and the next future timestamp at which
that target changes. `PerpsPublicLens.getTrancheQueues(bool)` relays the same pair as `nextRequestEpoch` and
`nextRequestCutoffTime`; both tranches report identical values at the same block. For every successful request, the
target epoch start is more than 300 and at most 3,900 seconds after inclusion.

LP share pricing uses one exact signed terminal-NAV snapshot for both deposits and redemptions. Each position stores
whole 100-token lots and exact entry cost. `TerminalNavBookV2` evaluates its marked LP-side price PnL and caps a
positive LP receivable by that trader's dedicated PnL pledge plus nettable same-account claim. Marked trader profits
reduce NAV; only collectible marked trader losses increase NAV. Carry, VPI, fees, frozen spreads, order margin,
liquidation reserves, and action reserves are excluded from this pre-close price-PnL book.

The snapshot derives both distributable equity and an explicit terminal deficit from:

```text
physicalAssets - traderClaims + signedTerminalLpPriceDelta
```

A current deficit, stale/frozen entry state, degraded mode, Senior impairment, or invalid zero-NAV state defers
deposit activation. The deposited USDC stays in request escrow under the asynchronous cancellation rules; an entrant
is never activated at a different NAV from the one applied to exits.

The withdrawal firewall is the key LP safety mechanism:

```text
baseWithdrawalReservedUsdc = traderClaims + maxLiability + settlementBuffer
freeUSDC = max(totalAssets - withdrawalReservedUsdc, 0)
```

Only unencumbered physical USDC can be committed to funded LP claims. A positive terminal receivable can price shares
but cannot fund a withdrawal before collection. Funded assets then leave `HousePool` for vault claim escrow and
cannot be reused by later settlements.

Both vaults use the same round-hour epoch clock. The request cutoff changes queue membership only: during the final
five minutes no new request can increase the epoch about to mature, although cancellations may shrink it and trading,
claims, accounting, and oracle state remain live. No later request can add to that locked epoch after it matures; at
the boundary, requests may instead join the new imminent epoch until its own cutoff. Settlement maturity remains
`currentEpoch >= requestId`.
Permissionless clearing follows the route reported by `SettlementMonitorLens.requiredExecutionPath`:
`HousePool.settleLpEpoch(uint256,uint256)` for `CachedMark`, or `OrderRouter.settleLpEpoch(bytes[])` for
`AtomicOracleRefresh`. On the atomic route, the Router validates a `PoolReconcile` Pyth basket under the reported
minimum-publish-time policy, installs that exact Engine mark, and invokes the Router-only HousePool callback in the
same transaction. A nonzero `minimumAtomicPublishTime` enforces the current-round-hour floor; frozen stale-mark
recovery reports zero and uses the frozen oracle policy instead. HousePool then applies one accounting snapshot in
this order:

1. matured Senior redemption demand,
2. matured Junior redemption demand from the remaining liquidity and covenant capacity,
3. matured Junior deposits,
4. matured Senior deposits.

Deposits activated in that transaction do not fund withdrawals in the same transaction. User claims remain separate
controller/operator pull actions and stay available while new deposit requests or entry activation are paused;
redemption requests remain available so exit demand can queue during a pause.
`HousePool.lpEpochSettlementPaused()` is an independent no-expiry hold. While active, both direct cached/no-position
and Router atomic-refresh settlement revert, so no pending deposit activates and no new redemption is funded. New
deposit and redemption requests, Senior reservations, existing cancellation paths, trading, reconciliation, and
already-funded claims remain available. Deposits can therefore accumulate in escrow under the existing cancellation
rules; neither the hold nor its release repairs state or guarantees later settlement.
Each redemption or deposit phase examines at most 16 nonempty epochs. Reaching the Senior redemption processing bound
with an eligible Senior head still pending ends the call before Junior funding; a later call resumes from that head.
If a call cannot advance any queued epoch, it reverts and rolls back its reconcile and carry checkpoints; keepers should
retry after an epoch matures or the blocking liquidity, capacity, pause, or safety condition changes.
The same rollback frame includes the Pyth update and Engine mark/carry update. Low confidence, stale or inconsistent
live oracle data therefore leaves the queue untouched. The direct cached-mark HousePool route is selected when there
are no open positions or when `oracleFrozen` and the cached mark remains fresh under the applicable frozen-mode limit;
a frozen stale mark selects atomic refresh. Frozen withdrawals retain their tranche-local surcharge and deposits
remain deferred.

`SettlementMonitorLens` packages the bounded state needed to operate this flow without copying protocol arithmetic
off chain. Callers choose the epoch to observe explicitly, so after the five-minute cutoff they can continue tracking
the closed epoch while new requests target the following one. The observed epoch does not select what the Router
settles; eligible FIFO heads remain authoritative. Its observations distinguish recoverable operational conditions
from critical invariant failures and dependency-read failures, and they report whether the current state calls for a
cached-mark path or an atomic Router oracle refresh. Cutoff totals are maximum membership, not immutable snapshots:
eligible cancellations can only shrink them. The lens is read-only and intentionally does not expose an authoritative
`canSettle`; keepers must still simulate the exact route-specific call before broadcasting: direct `HousePool`
settlement with the cached mark and time for `CachedMark`, or `OrderRouter` with the exact Pyth bytes and fee for
`AtomicOracleRefresh`.

The monitor reads the settlement hold fail-soft. A readable active hold is intentional state, not a critical fault:
`lpEpochSettlementPaused` is true, both `OperationalBlocker.LpEpochSettlementPaused` and
`DepositDeferral.LpEpochSettlementPaused` are reported, and the cached-versus-atomic route remains visible for
post-recovery planning. A failed hold read instead marks the Pool dependency unknown and the composite incomplete.
The included `LpEpochKeeper` aborts on an active hold before decoding a payload, quoting a Pyth fee, or broadcasting.
The settlement hold previously bumped the monitor configuration schema and observation domain to V2. Including the
active Junior maintenance-fee rate and recipient in observable configuration bumped both to V3. Including
`settlementBufferBps` in the observable Engine-policy digest now bumps both to V4; off-chain consumers must not
compare V1, V2, V3, and V4 digests as if they shared a domain.

Use `getSettlementStatus(observedEpoch)` as the lighter high-frequency polling surface. The composite
`getSettlementObservation(observedEpoch)` is intentionally a checkpoint and alert-investigation read: its ABI return
is roughly 6 KB and representative `eth_call` execution is about 0.8–1.3 million gas. It is suitable for a
block-pinned preflight record, not every monitoring tick.

The bounded monitoring API is:

- `getSettlementStatus(uint256 observedEpoch)`: epoch clock, queue endpoints and observed-epoch totals, current
  execution-path diagnosis, and separate operational blocker, warning, and deposit-deferral masks.
  `executionPathDependencyMask` isolates read failures that prevent choosing cached-mark versus atomic-refresh
  routing; `dependencyFailureMask` is the broader set of unknown status inputs. Canonical matured-head getters alone
  select the reported route; auxiliary lifecycle, link, membership, and endpoint inconsistencies degrade health or
  raise queue faults rather than rewriting known route evidence. `ActivationNotConfirmed` combines the projected
  `HousePool.canSettleDepositEntries()` common gate with canonical redemption evidence. The Pool view projects
  post-reconcile accounting, including residual pending claimants; the Lens remains conservative while matured Senior
  redemptions can still change principal/HWM rounding before either tranche activates, and while matured Junior
  redemptions can reduce capacity before Senior activation. HousePool rechecks the exact live gates after redemption
  funding. That tranche-neutral Pool view reports pending-epoch
  activation only; it is not a quote for admitting a new deposit request. The Senior deposit-deferral mask
  describes activation and existing-reservation-limit conditions; it is not additional admission capacity for a new
  request. Use the vault admission view or `HousePool.getSeniorDepositCapacity()` for that quote.
- `getSettlementHealth()`: observable wiring, NAV aggregate, pool backing, vault escrow, and seed-floor checks, with
  distinct critical-fault and dependency-failure masks. Construction rejects a Router whose immutable settlement pool
  differs from `Engine.pool()`. Runtime binding checks include the constructor-pinned Engine
  planner address/code hash and its settlement-critical carry-index and market-calendar ABIs; seed receiver/floor
  configuration must be a consistent zero/zero or nonzero/nonzero pair.
- `getPoolReconcileOracleStatus()`: fail-soft diagnostic for the current validated PoolReconcile observation; it
  cannot certify a future Hermes payload.
- `getSettlementObservation(uint256 observedEpoch)`: block-pinned composite observation, always-computed
  `observationDigest`, explicit `observationComplete`, and `completeObservationDigest` that equals the observation hash
  only when every required section is complete and otherwise remains zero. Completeness requires every Oracle
  dependency read to succeed even for cached-mark or no-work routing; current feed-policy validity is required only
  when the selected route is atomic refresh.
- `observableConfigDigest()`: domain-separated digest of the observable active configuration, including
  `settlementBufferBps` in the Engine policy section and the active Junior maintenance-fee APR and recipient in the
  pool-policy section.

All digests are unauthenticated advisory comparison aids, not trusted batch commitments, and none is consumed by the
Router.

If an aggregate deposit quote or unfunded redemption remainder rounds to zero, settlement moves that request into a
terminal refundable state instead of silently consuming value. `PerpsPublicLens.getLpRequestState(...)` exposes
`refundableDepositAssets`, `refundableRedeemShares`, and `redeemRefundPending`. The last flag may remain true when a
controller's pro-rata refund rounds to zero; the controller or its operator must still acknowledge that refund and
clear an oldest terminal head before the standard claim methods advance to a later request.

### HousePool basics

- `rawAssets`: literal USDC balance held by `HousePool`.
- `accountedAssets`: canonical protocol-owned assets recognized by pool accounting.
- `excessAssets`: unsolicited positive transfers that have not been admitted into protocol economics.
- `totalAssets()`: conservative physically backed depth derived from `min(rawAssets, accountedAssets)`.

Operationally:

- unsolicited donations stay quarantined as `excessAssets` until explicitly accounted or swept,
- raw-balance shortfalls reduce effective backing immediately,
- reconcile, solvency, and withdrawal logic all consume this canonical depth source rather than the raw token balance.

### Senior / junior waterfall

- Senior principal is restored before junior receives surplus if senior has been impaired.
- `seniorHighWaterMark` is a compounded protected senior claim watermark, not a principal-only watermark.
- When the junior-funded coupon increases `seniorPrincipal`, the paid coupon also ratchets `seniorHighWaterMark` upward and remains senior-protected after later losses.
- The mark increases additively on deposits. When an epoch funds `fundedShares` of Senior redemptions against the
  pre-burn Senior share supply `preBurnSupply`, it removes the same pro-rata protected claim:
  `H' = H - floor(H * fundedShares / preBurnSupply)`. This is share-based and therefore independent of any frozen exit
  fee or net asset payout. It resets cleanly after wipeout plus recapitalization.
- Ordinary deposits into both tranches remain blocked while senior is impaired; recovery capital must arrive through explicit recapitalization or realized pool revenue.

### Senior capacity covenant

Governance configures a finite `maxSeniorExposureUsdc` and a `maxSeniorShareBps` below 100% through the 48-hour
`HousePool` timelock. Active protected exposure is
`E = max(projected senior principal, projected senior high-water mark)`. Counted admission exposure is `C = E + R`,
where `R` is the gross USDC reserved by all pending senior deposits. The absolute and share admission tests use `C`;
the share test compares it with projected junior principal. Raw pool cash, unassigned assets, and trader balances are
not junior subordination.

The constructor starts with neutral bootstrap sentinels: unlimited absolute exposure (`type(uint256).max`) and a 100%
senior share (`10,000` bps). Governance cannot propose those values: a finalized operational configuration must use a
finite absolute limit and a share limit below `10,000` bps. Either limit may be zero to close senior admission.

- New Senior deposit requests may use only the smaller absolute and ratio headrooms.
- A pending senior request reserves gross-asset headroom. Finalization revalidates the complete reservation book under
  the then-active limits; if a cap reduction or accounting change makes it invalid, affected owners may cancel after
  the request epoch matures and recover their escrowed USDC rather than remain locked.
- Junior redemption funding preserves the configured senior share using active `E` only. It uses liquidity remaining
  after all eligible matured Senior demand has been accounted for; dormant Senior NAV is not itself a cash
  reservation. Pending Senior deposits remain refundable reservations and do not lock Junior withdrawal liquidity, so
  Junior funding may instead invalidate the provisional deposit-reservation book and unlock refunds.
- Coupon transfers, waterfall losses, revenue restoration, and privileged claimant recapitalization are not clipped to
  manufacture compliance. They may create a passive overage, which closes new senior capacity without haircutting or
  forcibly withdrawing existing senior claims. Recapitalization routed through
  `recordClaimantInflow(..., Recapitalization, ...)` may therefore restore protected senior claims above a newly
  reduced cap; it does not mint new senior LP shares.
- Funded Senior redemptions and Junior deposits can cure an overage. Governance limit reductions are prospective for
  active Senior shares, but unfinalized reservations must either fit the active limits at finalization or be refunded.

### Reachability domains

- Generic collateral reachability excludes queued committed-order and reserved-settlement buckets.
- Project and realize pending carry from eligible free settlement before evaluating position health. Carry fully funded
  there does not reduce the separate exact price-risk health basis. Any uncovered carry blocks trader withdrawal and
  independently makes the position liquidatable.
- PnL pledge plus same-account claim backs only exact price risk; neither can offset uncovered carry.
- Terminal collateral reachability may consume queued/reserved buckets, but only in full-close and liquidation settlement paths that explicitly unlock them.

### Bootstrap and withdrawal gates

- Trading does not become live until finite senior limits are finalized, both tranche seed positions exist within
  those limits, and the owner activates trading.
- Activation rejects the constructor's neutral senior-limit defaults, requires both permanent seed positions, and
  requires projected protected senior exposure plus any accepted senior reservations to satisfy both active limits
  against projected junior principal.
- Risk-increasing order commits and new tranche-deposit requests stay blocked during the seed lifecycle.
- `TrancheVault.maxRequestDeposit()` reports request capacity. ERC-4626 `maxDeposit()` / `maxMint()` report only
  activated deposit-claim capacity for the controller, independent of the eventual receiver, while
  `previewDeposit()` / `previewMint()` revert for the asynchronous flow. A share-delivering claim, redemption
  cancellation, or redemption refund may target another account only if that account has no existing vault shares;
  this prevents unsolicited dust from resetting the account's whole-balance cooldown. Self-receipt is always allowed.
- `TrancheVault.requestDeposit()` funds LP entry through pending deposit epochs; requests are funded
  up front and reserve senior capacity when applicable. A complete pending deposit is cancellable before its request
  epoch matures. At or after maturity, cancellation remains available only under the existing epoch rejection,
  projected terminal-wipe, Senior-impairment, or Senior-reservation escape conditions.
- `TrancheVault.requestRedeem()` enforces cooldown, allowance, seed-floor, and minimum-request rules. ERC-4626
  `maxWithdraw()` / `maxRedeem()` report only already-funded claim capacity; `previewWithdraw()` / `previewRedeem()`
  revert for the asynchronous redemption flow. Use the vault's explicit estimate views for pending requests. A
  complete redemption request is cancellable only while it is unmatured, wholly unfunded, and outside refund state;
  returned shares restart the receiver's existing cooldown.

### Reconcile / freshness nuance

`HousePool` separates mark-dependent reconcile math from already-funded pending buckets.

- If mark freshness is required and stale, it skips mark-dependent revenue/loss waterfall math.
- The senior coupon still checkpoints against existing junior NAV, so future junior entrants are not charged for prior time.
- `finalizePoolConfig()` cannot change `seniorRateBps` while the mark is stale; governance must refresh the mark first.
- Already-funded pending recapitalization or trading-revenue buckets may still apply through the same settlement entrypoint.

This is why the LP docs distinguish freshness-gated repricing from already-funded cash movements.

## Accounting Model

### Bounded solvency at entry

Before increasing risk, the engine checks that effective HousePool assets can cover both the worst-case directional
payout and the configured settlement-liquidity buffer after the trade.

```text
P = HousePool.totalAssets()
C = totalTraderClaimBalance
E = max(P - C, 0)
L = max(globalLongMaxProfit, globalShortMaxProfit)
B = ceil(L * settlementBufferBps / 10_000)

open/increase admission: E >= L + B
```

The default `settlementBufferBps` is `25` bps; governance may set it from `0` through `1,000` bps under the 48-hour
Engine risk-config timelock. `B` is headroom, not an extra payout, trader claim, NAV adjustment, yield source, or
separately custodied reserve. The LP withdrawal firewall nevertheless protects the same amount, making its base
reserve `C + L + B`.

Closes, liquidations, and triggered TP/SL closes may consume this headroom. Attached TP/SL protection inherits the
parent open's admission check, while protection added to an existing position does not create exposure and therefore
does not apply this gate. Trader upside remains bounded without iterating positions.

### LP-capital carry

Plether Perps uses utilization-indexed carry on each side's fixed borrow base rather than a side-to-side rate
mechanism.

```text
borrowBaseUsdc = max(positionMaxProfitUsdc - activePositionMarginUsdc, 0)
sideUtilizationBps = min(sideBorrowBaseUsdc / poolAssetsUsdc, 100%)
positionCarryUsdc = borrowBaseUsdc * (sideCarryIndex - positionLastCarryIndex)
```

Carry behavior:

- Accrues continuously by wall-clock time.
- Continues accruing even during stale or frozen oracle windows.
- Is assessed per position on a stored borrow base, not on a checkpoint-time mark price.
- Both `LONG` and `SHORT` positions can accrue carry at the same time if both sides have nonzero borrow base.
- Can be checkpointed into `unsettledCarryUsdc` when a basis-changing settlement credit occurs before physical collection is possible.
- Is realized before margin, pool-asset, or risk-parameter mutations change the carry base/rate denominator.
- On deposit, realized carry may be collected from post-deposit settlement in the same transaction.
- On withdraw, carry is realized before settlement balance is reduced.
- Flows to LP trading revenue once realized.
- Is first projected against eligible free settlement for guard and risk checks. Fully funded carry leaves exact
  price-risk health unchanged; any uncovered remainder blocks withdrawal and independently makes the position
  liquidatable. PnL pledge and same-account claim cannot cover that remainder.

Close and liquidation use the planner's canonical carry-adjusted settlement/equity outputs; the live executor does not recompute a separate carry-blind loss or liquidation kernel.

Open-risk projection credits skew-reducing trade rebates into reachable collateral before the initial-margin check, so preview and execution do not conservatively reject rebate-backed but valid opens.

### Trader claim liabilities

The system can complete terminal transitions even when immediate pool cash is insufficient.

- Trader gains can become trader claim balances.
- Keeper bounties are direct clearinghouse credits funded from trader margin and do not become vault liabilities.
- Trader claim balance is included in reserve and solvency accounting.
- Trader claim balances are beneficiary-based, not queue-based.

### Exact symmetric LP accounting

The Engine exports one signed terminal price-PnL adjustment for both LP entry and exit share pricing.

- Unrealized trader profits are exact marked LP liabilities.
- Unrealized trader losses count only up to that account's PnL pledge plus nettable claim.
- Price basis comes from exact entry-cost atoms, not a rounded average entry price.
- The resulting marked receivable affects NAV but is not physical withdrawal cash before collection.
- A negative terminal equity is exposed as an explicit deficit and blocks deposit activation.
- On a partial close, realized price gains are either credited to the surviving position's PnL pledge or recorded as
  a nettable same-account claim. On a full close, they are paid to free settlement or recorded as a claim.
- The gross negative lifetime-VPI clawback target is `max(-vpiAccrued, 0)`. It is held as a dedicated,
  nonwithdrawable sub-balance of action reserve; generic action charges cannot spend below the combined floor of
  protected execution bounties plus this VPI reserve.
- VPI does not add to or subtract from P+C price-risk equity. Reserve below the target independently blocks withdrawal
  and makes the account liquidatable; reserve above the target never adds price collateral.
- An open/increase that makes lifetime VPI more negative must fully fund the higher target from eligible settlement or
  newly supplied pledge, otherwise it is rejected. A close or liquidation consumes reserve when the clawback is
  realized and releases only value no longer required after equivalent withholding or a lower surviving target.
- A new close-time action rebate is still paid only from pool cash free of protected trader claims, with any unfunded
  portion waived rather than claim-backed. The protected lifetime-VPI reserve and all anticipated action economics
  remain outside terminal `K` and symmetric LP NAV, so LPs cannot extract the reserve before settlement.

This removes the deposit/withdrawal pricing asymmetry: a new depositor neither inherits old marked liabilities without
discount nor receives credit for uncollectible trader debt.
Ordinary LP entry always moves through pending deposit epochs: the user funds the request up front and later claims
the batch-priced shares after synchronized pool settlement. A request included one second before the cutoff waits five
minutes and one second for its target epoch to mature; a request included at the cutoff rolls to the following epoch.
A complete pending deposit is cancellable before its request epoch matures. At or after maturity, cancellation remains
available only under the existing epoch rejection, projected terminal-wipe, Senior-impairment, or Senior-reservation
escape conditions. This keeps request submission separate from the fresh symmetric NAV fixed at activation.

### Accounting domains

The perps system intentionally splits accounting into separate kernels:

- `CloseAccountingLib`: proportional exact-basis PnL, signed VPI, execution fee, frozen-close spread, and residual-position
  math for voluntary decreases; the planner separately caps price collection and waives terminal action shortfall.
- `LiquidationAccountingLib`: reachable collateral, keeper/protocol/LP charge allocation, and residual payout for forced
  close; price loss above the precommitted collectible cap is a diagnostic write-off.
- `SolvencyAccountingLib`: effective assets, bounded max liability, withdrawal reserves, and free pool cash.
- `TerminalNavBookV2`: exact account-capped terminal price-PnL aggregation for symmetric LP share pricing.
- `OrderReservationAccounting`: clearinghouse-reserved execution bounty accounting and margin-queue bookkeeping.
- `OrderRouterBase` / `OrderCommitHandler` / Router handler modules: live queue storage, bounded commit validation,
  authenticated V2 sidecar callbacks, liquidation, bounty accounting, mark refresh, LP settlement, and emergency
  cleanup. `OrderRouterV2ExecutionSidecar`, `CfdOrderPolicyEvaluator`, and `OrderLifecycleBook` own V2 single/batch
  orchestration, financial-policy assessment, and permanent lifecycle evidence respectively.
- `HousePool.recordClaimantInflow(amount, kind, cashMode)`: claimant-owned value routing for both revenue and recapitalization, with explicit cash-arrival vs retained-value modes.

These domains answer different questions. They should not silently share assumptions just because the inputs look similar.

## Order Routing and Oracle Model

`OrderRouter` is a delayed-order FIFO queue with commit-now / execute-later semantics.

### Commit rules

- The only production commit ABI is `commitOrder(OrderV2Types.OrderRequest)`.
- `clientOrderId`, `targetPrice`, `validUntil`, `allowedExecutionModes`, a nonzero `expectedConfigHash`, and a nonzero
  `maxPostLeverageBps` are mandatory for fresh external commits. The authenticated TP/SL parent/attempt paths alone
  construct the internal zero-config marker.
- An exact account-scoped replay is returned before any current-state validation. Conflicting reuse of a client id
  reverts, and the binding is never cleared.
- Fresh external commits must pin `OrderLifecycleBook.currentExecutionConfigHash()` and choose a deadline inside the
  current `maxOrderAge`.
- All financial maxima are inclusive ceilings and all minima are inclusive floors. Zero is meaningful rather than
  shorthand for unbounded authority.
- Opens are blocked while paused, degraded, or close-only.
- The router may reject predictably invalid opens at commit time using engine-lens prechecks.
- Partial closes must meet the same notional floor used for new positions; only full closes may clear a smaller residual.
- Each account may have at most the current `maxPendingOrders` limit (default `5`, timelocked range `1..32`).
- The router reserves the execution bounty in `MarginClearinghouse` at commit time.
- A `PendingOpen` or `Armed` protection is not a pending order and does not occupy the global FIFO. An account with an
  active protection cannot commit a conflicting discretionary order.

### Authoritative execution configuration

`OrderLifecycleBook.currentExecutionConfigHash()` commits to the schema, chain, lifecycle Book, Router, Engine,
Clearinghouse, HousePool, V2 execution sidecar, policy evaluator, Plether oracle, RouterAdmin and its
`activeConfigVersion`, Engine planner, Engine settlement sidecar, EngineAdmin and its `activeConfigVersion`, protocol
treasury, terminal NAV book, and HousePool mark staleness policy. Both admin versions start at one and advance only
after a successful applicable configuration finalization.

The digest deliberately excludes changing market and runtime state such as current price, pool depth, position skew,
FAD/frozen mode, Router/HousePool pause state, the LP settlement hold, and the emergency risk-off cutoff. It also
excludes the immutable HousePool redemption-math sidecar because that module affects LP redemption budgeting rather
than order execution. The request separately authorizes execution modes and financial outcomes. For a config-pinned
external request, a different digest at execution is a terminal `ConfigMismatch`; an application that accepts new
governance policy must submit a new client id because the original id remains permanently bound. The internal TP/SL
zero marker deliberately skips only this digest-equality gate; its execution modes and financial/order policy remain
protocol-authored and enforced, and its receipt still records the observed digest.

This execution-authority digest is distinct from `SettlementMonitorLens.observableConfigDigest()`. The former is
enforced by commit and execution; the latter is an advisory monitoring fingerprint with different coverage and never
authorizes settlement.

### Queue and bounty economics

- Execution always starts from the global queue head.
- Risk-increasing orders reserve an execution bounty quoted from the engine mark and bounded to `[0.01 USDC, 0.20 USDC]`.
- Close intents reserve a flat governance-configured bounty capped at `1 USDC` (default `0.20 USDC`).
- Position protection reserves a governance-configured trigger bounty capped at `1 USDC` plus the snapshotted close
  bounty. Both come from free settlement; the protection path never uses the active-position-margin close fallback.
- Partial close size is floored by the engine `minBountyUsdc / bountyBps` notional threshold at the commit reference price, preventing dust closes from occupying the FIFO queue for a flat bounty.
- Open bounties come from free settlement.
- Close bounties also come exclusively from free settlement after the engine attempts to collect carry. PnL pledge is never reclassified to keep a close intent committable.
- Failed-order rewards stay independent from pool liquidity because they are paid from clearinghouse-reserved trader value rather than LP cash.

### Execute rules

- Keepers execute from the global queue head.
- Pyth update data is required for live-market execution and the caller must attach ETH for the Pyth fee.
- Live order settlement uses Pyth's unique historical parse over `(commitTime, commitTime + orderSettlementWindow]`, capped at `block.timestamp`, rather than the latest reveal-time price.
- `executeOrderBatch` caches a successfully parsed historical basket and reuses it for later FIFO orders whose `commitTime` is still strictly before the cached tick and covered by the same unique range, avoiding repeated Pyth parsing for clustered commits.
- A keeper cannot skip an unfavorable post-commit tick by submitting a later tick: the unique parse requires the previous publish time to be no later than the order's `commitTime`.
- A protection trigger is separate from close execution. It uses a fresh neutral mark to create a market-style close at
  the FIFO tail; the ordinary execution keeper then settles that close against its first eligible post-trigger tick.
- Before Engine mutation, the stateless policy evaluator reconstructs the same authoritative snapshot consumed by
  the configured planner and evaluates every caller bound in canonical `ConstraintKind` order. Equality passes.
- Reservation release for execution/terminal classification does not checkpoint carry. The evaluator and Engine
  account for carry from the canonical Engine state; if the item is retryable, its rollback frame restores the
  reservation.
- Slippage, expiry, config mismatch, exact-shape typed planner rejection, execution-mode rejection, and financial
  constraint violation finalize the order. Risk-off and account liquidation are separate terminal reasons.
- Close-only, same-block/MEV, historical-price availability, insufficient-gas, and mark-ordering gates do not consume
  the FIFO head. Unrecognized selectors, panic, out-of-gas, empty revert data, malformed revert data, and malformed
  success payloads also remain retryable rather than being guessed into a terminal policy category.
- The execution sidecar withholds an explicit gas tail after the Engine call. Batch execution also caps each item
  self-call and retains a separate outer tail; Router and Oracle ETH refunds cap recipient-call gas and defer
  rejected refunds.
  Book finalization is last and fail closed: a failure there rolls back every state change for that item without a
  later gas-burning item or refund recipient rolling back an already finalized prefix.
- `executeOrder(...)` returns an `ExecutionResult` containing the order id, lifecycle status, terminal reason or
  pending reason, and receipt hash when the call completes. `executeOrderBatch(...)` returns a `BatchResult` with the
  next head, terminal count, and stop reason; reaching either cleanup work cap reports `CleanupLimit`. Per-item Router
  self-calls prevent a later prepared-item failure from
  rolling back earlier completed batch items. Oracle/Pyth preparation and the resulting Engine mark update occur in
  the outer batch frame: a revert there reverts the complete batch, so keepers should bound `maxOrderId` and split
  pre-oracle cleanup from price-dependent work when they need a strict progress boundary.

### Lifecycle evidence and receipts

`OrderLifecycleBook` separates live Router state from permanent integration state:

- `clientIntent(account, clientOrderId)` permanently resolves a client id to its order id and canonical intent hash.
- `IntentRegistered` emits the complete `OrderRequest` preimage, canonical intent hash, and actually reserved bounty,
  so an independent indexer can reconstruct the authorization without private client state.
- `pendingIntent(orderId)` and `pendingPolicy(orderId)` expose the identity, actual reserved bounty, and caller bounds
  while the order is live.
- `lifecycleStatus(orderId)` returns `None`, `Pending`, `Executed`, or `Failed`.
- `outcome(orderId)` keeps the compact permanent terminal result and the hash of the complete receipt.
- `OrderFinalized` emits the complete fixed-shape receipt. Its hash also commits to the chain, Book, Router, terminal
  block, and terminal time.

Every terminal order path emits one receipt: success, expiry, slippage, configuration mismatch, typed planner or policy
rejection, emergency risk-off, and account liquidation. The receipt binds client/order identity, expected and
observed configuration, execution regime and executor, adverse execution price, neutral mark, pool depth, oracle
time, whether the price reached the Engine, exact bounty recipient/disposition, typed failure evidence, and normalized
economics fields. Full receipt data remains in the event; compact state remains queryable on chain after the Router
fully deletes its terminal order record. A liquidation-driven queued-order receipt uses the state observed after
liquidation in both state-summary slots; the position's liquidation economics remain canonical in the Engine's
liquidation events, while the order receipt separately records its exact forfeited bounty.

Pre-oracle expiry and config-mismatch receipts use `PriceSource.None`, zero execution price and oracle time, and
`priceReachedEngine == false`; the cached neutral mark and pool depth may still be reported as accounting context.
Risk-off receipts likewise use `RiskOff`, execution mode and price source `None`, and the permissionless cleaner as
executor. A nonzero reserved bounty is returned to the account with `RefundedToAccount`; the cleaner receives
nothing. Liquidation cleanup records `AccountLiquidated`, retains the original keeper as executor, and marks a
nonzero remaining queued-order bounty `Forfeited` to the Engine's protocol-treasury account. On every terminal path,
a zero bounty requires `BountyDisposition.None` and the zero recipient rather than a paid/refunded/forfeited label.
A failed registered protection attempt records its nonzero bounty as
`BountyDisposition.RetainedForProtectionRetry` with a zero recipient only while the exact protected position still
matches, because custody remains reserved for the next attempt. A missing or mismatched position instead records
ordinary `Paid` cleanup and terminally resolves the protection as `Failed`.

### Basket oracle and publish-time checks

The router is configured with a `PletherOracle` contract. The oracle instance owns the Pyth endpoint plus the basket feed ids, quantities, base prices, and inversion flags set at deployment.

- `PletherOracle` normalizes each feed to 8 decimals while computing the basket price.
- The oracle computes the weighted basket price in the same shape as the spot basket oracle.
- Basket confidence is propagated conservatively by summing each normalized component contribution multiplied by that feed's confidence-to-price ratio, with each contribution floored independently.
- `PletherOracle.getLatestPoolReconcilePrice()` exposes the already-validated neutral PoolReconcile snapshot together
  with that aggregate 8-decimal confidence for monitoring; it performs no Pyth update and preserves the ordinary
  freshness, confidence-width, divergence, and publish-order reverts.
- Full `SettlementMonitorLens` current-feed diagnostics require that updated return ABI. Binding the monitor to a
  stack whose Router still uses an older `PletherOracle` is fail-soft: the current-feed section is unknown,
  `observationComplete` is false, and `completeObservationDigest` is zero until a compatible oracle is
  timelock-rotated into the Router.
- The reported confidence belongs to the neutral pre-cap basket, while the returned execution mark may be capped.
  Consumers therefore cannot always reproduce the configured confidence ratio by dividing confidence by the capped
  mark. Use `policyValid` and the configured ratio for monitoring; do not reinterpret that post-cap quotient as an
  independent oracle-policy proof.
- The neutral, pre-cap basket is accepted when `basketConfidence * 10_000 <= basketPrice * basketMaxConfidenceRatioBps`. The initial `basketMaxConfidenceRatioBps` is `10` (0.10%), equality passes, and there is no separate per-component confidence ceiling.
- Opening orders and live/FAD-only closing orders use the adverse side of the confidence interval for the trader's side: `LONG` opens are priced lower, `SHORT` opens are priced higher, `LONG` closes are priced higher, and `SHORT` closes are priced lower. Oracle-frozen voluntary closes instead use the unshifted validated basket price and pay the fixed frozen-close spread.
- Liquidation checks also use the side-adverse confidence-adjusted mark for the liquidated account.
- Component publish times must stay within `maxComponentPublishTimeDivergence`; if one basket leg is too far from the others, live opens are blocked rather than mixing fresh and stale components.
- The minimum `publishTime` across feeds remains the basket publish time passed to the engine; historical order fills can use an older post-commit price without rewinding a newer cached engine mark.
- Frozen-oracle close-only windows are the only regime that relaxes historical live-market settlement.
- Protection creation, replacement, and triggering are disabled while `oracleFrozen`. A close generated before the
  freeze remains an ordinary close and may execute under the existing frozen-close policy.
- The router's `PletherOracle` address is recoverable through `OrderRouterAdmin`'s timelocked oracle-config flow; changing the Pyth endpoint or basket arrays requires deploying a new oracle and timelocking the router onto it.
- The execution price is clamped to `CAP_PRICE` before the slippage check so the user sees the same price the engine executes.

### Frozen oracle behavior

The system distinguishes between:

- `FAD window`: elevated margin and close-only risk policy while FX markets are approaching closure.
- `Oracle frozen`: relaxed staleness and relaxed commit-time publish ordering once FX feeds are actually offline.

LP policy follows that split as well:

- `FAD` alone does not change LP entry/exit pricing.
- Voluntary close/reduce execution keeps the normal signed quadratic VPI curve and lifetime rebate clamp in every oracle regime, so a skew-reducing frozen close can still earn the same bounded negative VPI as a live close.
- During `oracleFrozen` only, voluntary close/reduce execution assesses `frozenCloseSpreadBps` on the reduced position notional instead of applying Pyth's adverse-confidence price shift. The spread is fixed rather than staleness-dependent, belongs entirely to LPs, and never credits the protocol treasury. Aggregate basket confidence-width validation remains active.
- Live and FAD-only closes retain Pyth's adverse-confidence price adjustment and do not pay the frozen-close spread.
- A partial close must fully settle required charges such as the frozen spread. Price loss beyond the account's PnL
  pledge plus nettable claim is instead a diagnostic write-off and does not block the close. If a terminal full close
  cannot collect the entire spread, the uncollectible portion is waived without creating a protocol liability or
  terminal deficit.
- Liquidations do not assess the frozen-close spread and retain their existing settlement rules.
- `oracleFrozen` keeps eligible synchronized LP redemption settlement live. Senior and Junior stale-window funding
  pays fixed surcharges that compensate incumbent LPs in that same tranche; deposit activation waits for the live
  symmetric-NAV entry gate.

This preserves close and liquidation liveness during real market closures without turning normal live trading into a free option.

### Stored vs derived order state

- Permanent lifecycle states in `OrderLifecycleBook` are `None`, `Pending`, `Executed`, and `Failed`.
- Router order records exist only while pending and are fully deleted on a terminal transition.
- `Executable` is derived from head-of-queue status plus freshness/oracle checks.
- `Expired` is represented by the failure path, not a separate persistent state bucket.

Position protection has a separate retained state machine: `None`, `PendingOpen`, `Armed`, `Triggered`, `Executed`,
`Failed`, `Cancelled`, `Liquidated`, and `Latched`. `Latched` is appended so existing status ordinals remain stable.
It means the trigger is irreversible and no close attempt is currently live; `Triggered` means exactly one attempt is
live. `BountyDisposition.RetainedForProtectionRetry` is likewise appended at ordinal `4`, preserving the existing
disposition ordinals. Protection state must not be inferred from or folded into the ordinary order status enum.

![Order lifecycle](../../assets/diagrams/perps-order-lifecycle.svg)

![Oracle regimes](../../assets/diagrams/perps-oracle-regimes.svg)

## Risk and Failure Containment

See [EMERGENCY_RESPONSE_GUIDE.md](EMERGENCY_RESPONSE_GUIDE.md) for the complete operator capability matrix,
recommended monitor triggers and non-triggers, containment/recovery runbook, and the controls that intentionally do
not exist. In particular, the guardian cannot disable trader closes or reductions.

### Degraded mode

If a close or liquidation leaves raw post-op effective assets `E` below maximum liability `L`, the engine latches
`degradedMode`.

While degraded:

- new opens are blocked,
- position-backed withdrawals are blocked,
- closes, liquidations, mark updates, and recapitalization remain available.

This is a containment latch, not a pause or a settlement-buffer alarm. A transition may leave `L <= E < L + B`
without entering degraded mode. Governance may clear an existing latch once `E >= L`; the next open or increase
still must satisfy the stricter `E >= L + B` admission rule. The protocol continues to allow transitions that reduce
risk or move the system back toward solvency.

### Liquidations

- Liquidations are proportional and bounded by actually reachable collateral.
- Liquidations are designed to avoid price-impact-driven cascades: positions settle against an external bounded oracle mark, not forced selling into an AMM or order book, so one liquidation does not mechanically move the execution price for the next. Large oracle moves can still make many positions independently liquidatable.
- The total liquidation charge is proportional with a floor and is allocated using the configured keeper and protocol
  shares; LPs receive the exact remainder after both rounded-down allocations.
- Liquidation does not compute a fresh VPI delta, but it settles the full negative lifetime-VPI clawback from the
  dedicated reserve or equivalent withheld trader gain before residual planning; a separate uncollectible action
  charge is waived rather than mixed into the price-loss write-off or terminal-deficit path.
- Residual trader value is preserved when positive.
- Same-account trader claim balance backs that account's price-risk health and is netted exactly once against its
  price loss, but it is never cash or action-charge collateral.
- Position price loss above the account's collectible PnL cap is a diagnostic write-off, not socialized LP debt.
- Voluntary closes seize price loss only from the account's dedicated PnL pledge and nettable claim. Any excess was
  excluded from marked LP receivables and is written off rather than turned into a claim or deficit; an
  uncollectible terminal frozen-close spread is separately waived.
- Liquidation terminally removes the account's active protection in O(1). An armed protection forfeits both unpaid
  bounties; a `Triggered` protection forfeits its live attempt's execution bounty; and a `Latched` protection forfeits
  the recycled Book-attributed execution bounty. Each path consumes the value exactly once.

### Friday Auto-Deleverage (FAD)

The protocol raises margin requirements around FX market closure windows.

The recurring calendar follows Pyth's 17:00 New York FX close/open and calculates US daylight-saving transitions
on-chain. FAD provides a 30-minute live-oracle shoulder before Friday's close and a 15-minute live-oracle shoulder
after Sunday's open:

| Regime | New York time | UTC during daylight time | UTC during standard time |
|--------|---------------|--------------------------|--------------------------|
| FAD only, oracle live | Friday 16:30–17:00 | Friday 20:30–21:00 | Friday 21:30–22:00 |
| FAD and oracle frozen | Friday 17:00–Sunday 17:00 | Friday 21:00–Sunday 21:00 | Friday 22:00–Sunday 22:00 |
| FAD only, oracle live again | Sunday 17:00–17:15 | Sunday 21:00–21:15 | Sunday 22:00–22:15 |

Friday and Sunday can use different UTC offsets on the weekends when daylight saving starts or ends. Governance
override days and their optional runway remain keyed to UTC days.

| Window | Margin basis | Max leverage |
|--------|--------------|--------------|
| Normal | `maintMarginBps = 1%` | 100x |
| FAD | `fadMarginBps = 3%` | 33x |

The owner can also add admin FAD days for expected FX-market holidays.

### Position and side invariants

The important runtime invariants are:

- each account holds at most one live directional position,
- side-local cached accounting stays consistent with the live position set and never overstates bounded payoff or margin state,
- the sum of `LONG`-side and `SHORT`-side `totalMargin` equals `sum(pos.margin)` across live positions,
- commit-time open preview must not admit orders the router can already classify as commit-time rejectable, and close/liquidation preview math must match live accounting semantics,
- clearinghouse USDC execution-bounty reservations and admin-custodied ETH refund claims are each conserved across their respective lifecycle transitions.
- each account has at most one `PendingOpen`, `Armed`, `Latched`, or `Triggered` protection; `Armed` and `Latched` are
  off queue, `Triggered` links exactly one live full reduce-only attempt, and one protection may produce many terminal
  attempt order ids whose outcomes and event evidence persist,
- the two OCO legs collectively trigger at most once, and every protection bounty unit is exactly one of reserved, paid,
  retained for retry, refunded, or forfeited,
- a terminal protection owns no reserve, and liquidation leaves no active protection or linked-order residue.

## Governance and Admin Controls

Most risk-sensitive parameter changes are timelocked for 48 hours.
Engine risk controls live on `CfdEngineAdmin`, and router risk controls plus pause state now live on `OrderRouterAdmin`, with both deployed admin contracts finalizing changes onto their host contracts.

Timelocked surfaces include:

- `CfdEngineAdmin.EngineRiskConfig` -> `CfdEngine.riskParams`, `CfdEngine.executionFeeBps`,
  `CfdEngine.frozenCloseSpreadBps`, `CfdEngine.settlementBufferBps`
- `CfdEngineAdmin.EngineCalendarConfig` -> `CfdEngine.fadDayOverrides`, `CfdEngine.fadRunwaySeconds`
- `CfdEngineAdmin.EngineFreshnessConfig` -> `CfdEngine.fadMaxStaleness`, `CfdEngine.engineMarkStalenessLimit`
- `HousePool.PoolConfig` -> one six-field proposal containing `seniorRateBps`, `markStalenessLimit`,
  `seniorFrozenLpFeeBps`, `juniorFrozenLpFeeBps`, `maxSeniorExposureUsdc`, and `maxSeniorShareBps`
- `OrderRouterAdmin` -> `OrderRouter.RouterConfig`
- `OrderRouterAdmin` -> `OrderRouter.OracleConfig` for the configured `PletherOracle` address

Instant controls remain for one-time wiring and fee withdrawal. `OrderRouterAdmin.pause()` is callable by its owner
or configured pauser, while `unpause()` is owner-only; neither control lives on the router itself. The installed
coordinator can add any of its three fixed restriction combinations but exposes no unpause method; governance
recovers Router risk-off, Pool entry, and Pool settlement separately and deliberately. Manual restrictions do not
expire.

Each valid `PoolConfig` proposal supplies all six fields, replaces any earlier pending proposal, and restarts the
48-hour timelock. Finalization atomically replaces the entire active configuration, so a proposal intended to change
only one field must repeat the desired active values for the other five.

`CfdEngineAdmin.activeConfigVersion` and `OrderRouterAdmin.activeConfigVersion` start at one. The Engine version
increments after successful risk, calendar, or freshness finalization; the Router version increments after successful
router-policy or oracle-address finalization. These counters are monotonic inputs to the execution-config digest, so a
finalized change invalidates the pinned configuration of an otherwise pending V2 order. The request ABI and intent
hash remain V2; the latched-retry release bumps the receipt type and execution-config schema domains to V3 because
protection-attempt registration and `RetainedForProtectionRetry` change authenticated terminal meaning.

### Fresh V2 deployment boundary

V2 is a fresh-stack architecture, not an in-place migration. Deploy and verify the evaluator and execution sidecar;
predict the Router; deploy its empty lifecycle Book and keeper sidecar against that prediction; then construct the
Router with the lifecycle Book as its eighth and final dependency. Complete the normal one-time Engine,
Clearinghouse, Pool, vault, monitor, and emergency-coordinator wiring, and activate trading only after every reciprocal
binding is correct. Do not mix a V2 Router/Book with legacy Router queue state or reuse an already-wired Engine; V1
pending orders, client ids, and outcomes are not imported. Recovery from a Book or immutable-binding fault likewise
requires containment and a new compatible stack rather than storage repair.

The latched-retry lifecycle is likewise a fresh-stack boundary. The Router-created stateful protection Book and the
predeployed lifecycle Book cannot be upgraded or populated from the old stack. Before switching application manifests,
contain new admission on the old deployment and resolve or explicitly account for every old active protection and
pending order; then deploy and verify the complete new graph and start its indexer and keepers from the new addresses.

### Pause behavior

- The guardian selects one fixed coordinator action: `triggerEmergencyPause(reasonHash,evidenceHash)` for Router
  risk-off plus LP entry, `triggerLpEpochSettlementHold(reasonHash,evidenceHash)` for epoch settlement only, or
  `triggerFullContainment(reasonHash,evidenceHash)` for all three restrictions atomically. Calls are idempotent;
  downstream failure rolls back the call while preserving pre-existing restrictions. The unified
  `EmergencyContainmentTriggered` event records the action, hashes, cutoff, and previous/new masks. The hashes are
  advisory incident metadata, not an on-chain proof from `SettlementMonitorLens`.
- Router pausing blocks new risk-increasing commits and permanently snapshots the highest existing order id. Opens at
  or below that cutoff are refunded internally when lazily cleaned; closes, liquidations, mark refresh, and other
  protective paths remain available. Unpausing never revives invalidated opens.
- Router pause and `positionProtectionCommitsEnabled == false` block new protection creation, replacement, and attached
  opens. They do not strand cancellation, valid triggering, latched retry, linked-attempt execution, terminal cleanup,
  or liquidation. Risk-off cleanup of an attached parent open also terminally fails its `PendingOpen` protection and
  refunds the unpaid protection bounties.
- HousePool pausing is entry-only: it blocks new LP deposit requests and deposit activation. Redemption requests,
  synchronized reconciliation/redemption funding, and funded claims remain live. A matured pending deposit is not
  made cancellable merely by the pause; it can be recovered only through the pre-existing rejection, terminal-wipe,
  Senior-impairment, or Senior-reservation escape conditions, or activated after recovery.
- HousePool settlement hold blocks every synchronized epoch mutation, including both cached/no-position and Router
  atomic-refresh routes. It does not block new deposit or redemption requests, Senior reservations, existing
  cancellation paths, reconciliation, trading, or already-funded claims. Pending requests may accumulate; the hold
  creates no new cancellation right and has no expiry. Only the HousePool owner can release it.
- The guardian cannot unpause, rotate itself, change configuration, set prices, move funds, or call arbitrary
  contracts. Governance may rotate/disable it and owns staged recovery.
- Trader closes/reductions, liquidations, redemption requests, and already-funded claims are deliberately
  unpausable. There is no redemption-request-off or global all-LP-request freeze, arbitrary restriction mask,
  corrupted-queue quarantine, emergency price setter, or global protocol freeze.
- A breaker contains transitions; it does not repair accounting, oracle, custody, liquidity, or queue state, and
  releasing it is not a promise that the next transaction succeeds. Off-chain automatic triggering is out of scope.
- The canonical operator guide, including off-chain guardian requirements and hard limitations, is
  [EMERGENCY_RESPONSE_GUIDE.md](EMERGENCY_RESPONSE_GUIDE.md).

## Default Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maintMarginBps` | 100 (1%) | Maintenance margin requirement |
| `initMarginBps` | 150 (1.5%) | Initial margin requirement |
| `fadMarginBps` | 300 (3%) | FAD margin requirement |
| `baseCarryBps` | 500 (5%) | Annualized carry on LP-backed notional |
| `bountyBps` | 10 (0.10%) | Total liquidation-charge rate |
| `minBountyUsdc` | 1,000,000 ($1) | Total liquidation-charge floor |
| `keeperShareBps` | 5,000 (50%) | Keeper share of the collected liquidation charge |
| `protocolShareBps` | 0 (0%) | Protocol-treasury share of the collected charge; LPs receive the remainder after both shares |
| `executionFeeBps` | 4 (0.04%) | Timelocked protocol trading fee |
| `frozenCloseSpreadBps` | 50 (0.50%) | Fixed LP-owned spread on voluntary close/reduce notional during `oracleFrozen` |
| `settlementBufferBps` | 25 (0.25%) | Liability-scaled admission and LP-withdrawal headroom; governed range 0-1,000 bps |
| Open execution bounty | 0.01 to 0.20 USDC | Timelocked router reserve bounds |
| Close execution bounty | 0.20 USDC | Timelocked router reserve amount |
| Position-protection trigger bounty | 0.20 USDC | Timelocked activation-keeper reserve, capped at 1 USDC |
| Position-protection commits | disabled | Fresh deployments require a later timelocked enablement |
| Full default protection reserve | 0.40 USDC | Snapshotted trigger plus linked-close bounties, funded from free settlement |
| Normal execution staleness | 60s | Normal order execution freshness |
| Order settlement window | 15s | Historical Pyth search window after order commit |
| Component publish divergence | 5s | Max basket-leg publish-time skew for live settlement |
| `basketMaxConfidenceRatioBps` | 10 (0.10%) | Maximum weighted aggregate confidence relative to the neutral pre-cap basket price |
| Adverse confidence multiplier | 2,000 (0.2x) | Applied to live/FAD order execution and liquidation marks; waived for oracle-frozen voluntary closes |
| Liquidation staleness | 15s | Live-market liquidation freshness |
| `engineMarkStalenessLimit` | 60s | Engine-side mark freshness |
| `markStalenessLimit` | 60s | HousePool mark freshness |
| FAD override days | empty | Admin-set calendar override set |
| `fadMaxStaleness` | 3 days | Frozen-market max staleness |
| `fadRunwaySeconds` | 3 hours | Admin FAD pre-close runway |
| `seniorRateBps` | 800 (8% APY) | Senior target coupon rate funded from junior NAV |
| `maxSeniorExposureUsdc` | Timelocked, finite | Absolute counted-admission limit (`E +` pending senior reservations) |
| `maxSeniorShareBps` | Timelocked, <10,000 | Maximum counted senior admission share; active `E` also governs Junior redemption funding |
| `LP_REQUEST_CUTOFF_DURATION` | 5 minutes | Shared deposit/redemption roll-forward cutoff before each round-hour boundary |
| `DEPOSIT_COOLDOWN` | 1 hour | LP anti-flash cooldown |

The two senior-capacity rows describe the required post-timelock operating configuration. Fresh deployments initially
use the neutral constructor sentinels `type(uint256).max` and `10,000` bps, which cannot pass trading activation.

OrderRouter also exposes timelocked admin control over `positionProtectionCommitsEnabled`,
`positionProtectionTriggerBountyUsdc`, `maxPendingOrders`, `minEngineGas`, and `maxPruneOrdersPerCall`.
`maxOrderAge` must stay nonzero and cannot exceed one hour, so close-only windows cannot be indefinitely pinned by an old FIFO head.

`frozenCloseSpreadBps` is timelocked with the rest of `EngineRiskConfig`, must remain nonzero, and is hard-capped at `1,000` bps (10%).

`settlementBufferBps` is timelocked with the same config and may range from `0` (disabled) through `1,000` bps (10%),
inclusive. It scales maximum directional liability, not pool assets or position notional.

`keeperShareBps` and `protocolShareBps` are also timelocked with `EngineRiskConfig`. Each allocation rounds down, their
sum must not exceed `10_000`, and LPs receive the exact charge remainder. The defaults are `5_000` keeper, `0` protocol,
and therefore `5_000` LP.

## Off-Chain Applications and Workers

The product applications and supporting services live in the [`plether-app`](https://github.com/Plether-Fi/plether-app) repository:

- [Frontend application](https://github.com/Plether-Fi/plether-app/tree/master/apps/frontend): provides the trader and LP web interface for reading protocol state and submitting transactions.
- [Backend API](https://github.com/Plether-Fi/plether-app/tree/master/apps/backend): provides a read-only API for cached market data, account history, Pyth payloads, and other product-facing queries; it does not submit protocol transactions.
- [Order and liquidation keeper](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/Keeper.hs): monitors pending orders and unhealthy positions, then submits eligible executions and liquidations.
- Position-protection trigger worker: discovers armed records, compares a current neutral Pyth mark to their OCO
  thresholds, and submits `triggerPositionProtection(...)` directly to the Book discovered from the Router. This is a
  distinct liveness job from executing the linked FIFO close; the existing order keeper discovers that close through
  the Router's ordinary `OrderCommitted` event.
- Position-protection retry worker: discovers `Latched` records, reconciles the most recent attempt's terminal receipt,
  confirms the exact position and zero pending-order preconditions, and submits
  `retryPositionProtectionClose(...)` without Pyth data. The protocol-operated worker automatically retries only
  `Expired` attempts, only when live Pyth data (or frozen-close execution) is available, and only when projected
  head-arrival is at most `maxOrderAge - 15 seconds` (45 seconds under defaults). Other terminal reasons stay latched
  and raise an operator alert keyed by reason plus failure fingerprint; they are retried only after remediation. The
  worker budget pays for any otherwise-unrewarded expiry-pruning transaction. It must tolerate races because retry is
  permissionless and only the first caller can create the next live attempt. Indexers must model one protection to
  many attempt order ids rather than overwriting history when `linkedOrderId` advances, and retain lifecycle-Book
  `ProtectionAttemptRegistered` evidence after its pending marker is deleted at finalization.
- [Pyth basket cache worker](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/BasketWorker.hs): fetches current and historical Pyth FX data and stores basket snapshots and update payloads for the API and keeper flows.
- [On-chain oracle updater](https://github.com/Plether-Fi/plether-app/blob/master/apps/frontend/scripts/perps-oracle-worker.mjs): reads fresh cached Pyth payloads from the backend and submits `updateMarkPrice` transactions.
- [Perps history indexer](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/PerpsIndexer.hs): indexes confirmed perps contract events into the backend database for historical queries.

Operators should monitor armed, latched, and triggered counts; time spent latched without a live attempt; retry count;
trigger-to-first-attempt and per-attempt queue-to-terminal latency; unpaid failed-attempt cleanup; keeper profitability;
liquidation-before-fill; and the equality between Book-attributed dormant/recycled protection reserves plus
Router-attributed live-order reserves and clearinghouse reserved settlement. TP/SL should be described as an
irreversible trigger followed by retryable market-close attempts, never as an automatic or guaranteed-price close.

## Further Reading

- [`WORKING_WITH_AI_AGENTS.md`](WORKING_WITH_AI_AGENTS.md): bounded autonomous trading, machine-readable execution,
  and independent intent/outcome verification
- [`ACCOUNTING_SPEC.md`](ACCOUNTING_SPEC.md): full accounting and reserve model
- [`SECURITY.md`](SECURITY.md): trust assumptions, liveness tradeoffs, and security posture
- [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md): intended product-facing integration surface
- [`INTERNAL_ARCHITECTURE_MAP.md`](INTERNAL_ARCHITECTURE_MAP.md): one-page component and custody map

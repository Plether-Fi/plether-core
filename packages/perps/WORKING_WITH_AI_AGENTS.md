# Working with AI Agents

Plether Perps is designed so autonomous software can operate capital without asking an observer to trust its private
memory, interpretation of protocol state, or report of what happened. The protocol does not give an AI agent special
privileges. For externally submitted bounded orders, it gives every account a typed, financially bounded and
permanently identified intent. Position-protection actions add retained OCO geometry and synthesize typed parent or
linked-close orders. Both paths have deterministic execution semantics and authenticated terminal evidence.

This document explains the core protocol surfaces available to agent developers. It covers order integration, policy
enforcement, execution, and verification. Wallet delegation, session keys, strategy design, model hosting, market-data
selection, and user-facing approvals remain application-layer concerns.

## Dollar-index exposure for agents

Plether Perps lets an agent isolate or partially hedge USD direction as a bounded sleeve of a larger portfolio,
without changing unrelated positions.

The contract's raw FX-basket mark moves opposite to dollar strength, so agents must use this mapping:

| Product instruction | Positive price PnL when the raw mark | Solidity encoding |
|---------------------|--------------------------------------|-------------------|
| **LONG dollar index** | Falls | `CfdTypes.Side.LONG` (`0`) |
| **SHORT dollar index** | Rises | `CfdTypes.Side.SHORT` (`1`) |

Use LONG/SHORT dollar index consistently in policies, calldata, and reports. BULL/BEAR are names for the spot tokens,
not perps directions. Bind the intended market through the Router's verified Oracle and execution configuration hash.

## Why the protocol is suitable for autonomous capital

| Requirement | Protocol guarantee | Primary tool |
|-------------|--------------------|--------------|
| Authoritative state | Live state comes from the Router, Engine, Clearinghouse, HousePool, and Oracle; permanent order identity and outcomes come from a predeployed immutable lifecycle Book whose exact bindings the Router validates | `IOrderLifecycleBook`, `PerpsPublicLens`, `PletherOracle`, Engine preview lenses |
| Protocol meaning | Dollar-index direction, requests, policy constraints, execution regimes, terminal reasons, pending reasons, bounty disposition, and economics have an explicit machine mapping | `CfdTypes.Side`, `OrderV2Types`, `CfdOrderPolicyEvaluator` |
| Bounded authority | Fresh externally submitted bounded orders pin a deadline, modes, configuration, and inclusive financial limits; protection actions bind explicit OCO geometry and synthesize a documented internal envelope | `OrderV2Types.ExecutionBounds`, `IPositionProtectionActions` |
| Financial policy | The evaluator reconstructs authoritative Engine state and checks the registered intent's limits before the Engine applies the transition | `CfdOrderPolicyEvaluator`, configured Engine planner |
| Composable execution | Bounded-order submission is client-id idempotent; execution and protection triggering are permissionless; bounded calls return machine-readable results | `IPerpsTraderActions`, `IPerpsKeeper`, `IPositionProtectionActions` |
| Verifiable outcome | The lifecycle Book proves queued-order intent and outcome; the protection Book retains OCO thresholds, trigger evidence, and parent/close linkage | `IntentRegistered`, `OrderFinalized`, `IOrderLifecycleBook.outcome`, `IPositionProtectionViews` |

The practical result is that an agent can separate three questions that are often conflated:

1. **What am I authorizing?** For externally submitted bounded orders, the complete `OrderRequest` and
   `ExecutionBounds` answer this.
   For position protection, the action parameters and retained OCO record answer it, while the protocol synthesizes
   the parent or linked-close request.
2. **What is the protocol currently willing to do?** Canonical state, previews, and the execution configuration hash
   answer this at a particular block.
3. **What actually happened?** The lifecycle status, compact outcome, receipt event, and receipt hash answer this after
   inclusion without relying on the agent's own logs.

## System boundary

```text
user policy / risk mandate
            |
            v
smart account or session-key controller        permissionless keeper + Pyth data
            |                                                |
            v                                                v
       OrderRouter  --------------------------> bounded-order execution sidecar
            |  \                                             |
            |   +--> Router-bound keeper sidecar              v
            v                                      policy evaluator + Engine
predeployed OrderLifecycleBook <----------------------------  |
            |                                      Clearinghouse + HousePool
            +------ permanent evidence
```

For public `OrderRouter.commitOrder`, `msg.sender` is the trading account and client-id namespace. Trader calls on the
Router-discovered position-protection Book likewise use their caller as the account. Only the authenticated
Book/Router protection path may carry the recorded account explicitly; a trigger keeper cannot select the protected
account or generated request. A smart account therefore holds the Clearinghouse balance and acts through these
surfaces; if an EOA calls them directly, the EOA itself is the account.

The account layer should decide *who* may act. The external protocol request—or the protection action plus its
documented synthesized envelope—decides *what financial result is allowed*. Keeping those controls independent gives
a user protection if an agent key, model, relayer, or keeper behaves incorrectly.

Bounded-order limits are per-order execution authority. They are not wallet-wide delegation, a rolling portfolio
limit, a withdrawal policy, or a revocation mechanism; those controls belong in the account layer.

## Core integration tools

### Trader actions

Use `IPerpsTraderActions` for the production order entrypoint:

```solidity
function commitOrder(
    OrderV2Types.OrderRequest calldata request
) external returns (uint64 orderId);
```

`OrderRouter.commitOrder` has no scalar production overload or zero-price market-order sentinel. Its `targetPrice` is
mandatory, and the resulting FIFO order cannot be cancelled, so agents should use short, intentional deadlines.

Position protection is a separate canonical surface. Discover the stateful Book through
`OrderRouter.positionProtectionBook()` and use `IPositionProtectionActions` to create, replace, cancel, trigger, or
atomically attach protection to an opening order. `commitOpenOrderWithProtection` accepts a caller target of zero for
no practical slippage limit and translates it to a nonzero bounded-order sentinel before registration. Cancelling a
`PendingOpen` protection detaches and refunds the protection but does not cancel its already-committed parent order;
an already `Triggered` linked close is binding.

### Authoritative order reads

Use the predeployed, Router-validated `IOrderLifecycleBook`, not a local database or deleted Router record, for
durable order state:

- `currentExecutionConfigHash()` returns the execution-critical configuration that a fresh public request must pin.
- `hashOrderRequest(account, request)` computes the canonical chain-, Router-, and account-bound intent hash.
- `resolveClientIntent(account, request)` classifies a proposed id as unused, exact replay, or conflict.
- `clientIntent(account, clientOrderId)` permanently resolves a client id to its order id and intent hash.
- `pendingIntent(orderId)` returns pending identity, the actually reserved bounty, and all bounds.
- `pendingPolicy(orderId)` returns the bounds while the order is pending.
- `lifecycleStatus(orderId)` returns `None`, `Pending`, `Executed`, or `Failed`.
- `outcome(orderId)` returns the permanent compact terminal outcome and receipt hash.

The Book owns no funds and has no owner, upgrade, migration, or arbitrary mutation path. Only its immutable Router may
register and finalize records.

The Book is deployed with immutable `ROUTER`, `ENGINE`, `CLEARINGHOUSE`, and `HOUSE_POOL` bindings before the Router
exists. Deployment predicts the Router two nonces ahead, then creates the Book, the exactly Router-bound keeper
sidecar, and the Router as three consecutive `CREATE`s. The Router constructor rejects missing code or any Book/core
binding mismatch before accepting the deployment.

The Book is the Router's eighth and final constructor dependency. The Router separately creates the stateful
`PositionProtectionBook` during construction and exposes it through `positionProtectionBook()`.

### Product and preview reads

Use the smallest canonical surface that answers the decision:

- `PerpsPublicLens` for compact account, position, tranche, and protocol status.
- `OrderRouter.pletherOracle()` and the deployed `PletherOracle` configuration for the exact FX-basket market bound
  to the Router.
- `ICfdEngineLens.previewOpen(...)` and `previewClose(...)` for trade-ticket simulation.
- `IOrderLifecycleBook` for order identity, pinned policy, lifecycle, and outcome.
- `PerpsPublicLens.getActivePositionProtection(...)` and `getPositionProtection(...)`, or direct
  `IPositionProtectionViews`, for retained protection thresholds, status, trigger evidence, and order linkage.
- `SettlementMonitorLens` for LP epoch routing and operational health only. Its observations are advisory and do not
  authorize order execution or settlement.

Rich Engine, Clearinghouse, and HousePool lenses remain useful for risk engines and independent accounting checks,
but they are not a replacement for the canonical product and lifecycle surfaces.

Engine previews consume caller-supplied price and time inputs. They do not fetch Hermes/Pyth data, ingest an oracle
update, validate Router oracle freshness or publish-time policy, or reproduce FIFO, pause, MEV, and slippage gates.
Treat a preview as a candidate Engine transition, not an execution promise.

### Permissionless execution

Use `IPerpsKeeper` for execution:

- `executeOrder(orderId, pythUpdateData)` returns `ExecutionResult`.
- `executeOrderBatch(maxOrderId, pythUpdateData)` returns `BatchResult` and never processes beyond the inclusive id
  bound.
- `clearRiskOffOrder(orderId)` performs unpaid, oracle-free cleanup of an invalidated pre-cutoff open and refunds its
  remaining margin and bounty to the account's internal Clearinghouse settlement, not directly to its wallet.
- `executeLiquidation(account, pythUpdateData)` and `executeLiquidationBatch(accounts, pythUpdateData)` are the
  permissionless liquidation surfaces.
- `settleLpEpoch(pythUpdateData)` is the atomic-oracle route for refreshing the Pool mark and clearing eligible LP
  epoch work; the Settlement Monitor's `requiredExecutionPath` output selects that route or direct cached-mark
  settlement through the HousePool.
- `IPositionProtectionActions.triggerPositionProtection(protectionId, pythUpdateData)` is the payable permissionless
  protection-trigger surface. Call it directly on the Router-discovered protection Book; the Router does not forward
  public protection selectors.

The submitting agent does not have to be the executor. Any keeper may execute an order. For a freshly submitted
bounded-order request, execution remains inside the limits pinned by the account. Protection parent and linked-close
orders instead use the documented protocol-synthesized envelope and remain subject to ordinary Router, evaluator,
Engine, and protection-state checks. Bounty economics differ: self-execution credits the stored order bounty to the
account while an external keeper receives it. Receipts encode self-execution as `Paid` to `executor == account`;
`RefundedToAccount` is reserved for risk-off cleanup.

The Router delegates to two separately deployed stateless modules. Its exactly Router-bound keeper sidecar performs
commit validation and orchestrates mark refresh, LP settlement, protection triggers, and liquidation; its bounded-order
execution sidecar (`OrderRouterV2ExecutionSidecar`) applies oracle, policy, rollback-isolation, and receipt logic.
Integrations must still call the Router or the Router-discovered protection Book. Direct sidecar calls are not
alternative protocol entrypoints and cannot acquire Router authority.

Solidity return structs are useful for `eth_call`, simulation, and contract-to-contract composition. A normal RPC
transaction receipt does not expose Solidity return data, so after broadcast an off-chain agent should reconcile the
`OrderFinalized` log and Book state instead of depending on a locally predicted return value.

### Existing off-chain components

The separate [`plether-app`](https://github.com/Plether-Fi/plether-app) repository contains reference infrastructure
that an agent integration can use or replace:

- the [read-only backend API](https://github.com/Plether-Fi/plether-app/tree/master/apps/backend) for cached market and
  account queries;
- the [order and liquidation keeper](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/Keeper.hs)
  for permissionless execution;
- the [Pyth FX-basket cache worker](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/BasketWorker.hs)
  for current and historical payload preparation;
- the [perps event indexer](https://github.com/Plether-Fi/plether-app/blob/master/apps/backend/app/PerpsIndexer.hs) for
  searchable history.

These services improve availability and ergonomics but are not authoritative. Agents should verify mutation targets,
payload acceptance, lifecycle state, and terminal evidence against the contracts.

## The bounded-order envelope

Every public `OrderRequest` contains an account-scoped `clientOrderId`, trade direction and size, margin delta,
target price, open/close flag, and mandatory `ExecutionBounds`.

Use protocol-native units: USDC amounts use 6 decimals, prices use 8 decimals, position sizes use 18 decimals and must
be divisible by `1e20` (the 100-token lot), timestamps are Unix seconds, and leverage values are basis points.

All on-chain order prices are the raw 8-decimal FX-basket quote, not an inverted dollar-oriented display price.
`targetPrice` is tested against the side-adverse execution price rather than the neutral mark. In product terms:

`targetPrice` is a direction-aware inclusive execution boundary:

| Product action | Accepted raw FX-basket execution price |
|----------------|----------------------------------------|
| Open/increase LONG dollar index | `executionPrice >= targetPrice` |
| Open/increase SHORT dollar index | `executionPrice <= targetPrice` |
| Close/reduce LONG dollar index | `executionPrice <= targetPrice` |
| Close/reduce SHORT dollar index | `executionPrice >= targetPrice` |

If an application derives an inverse, dollar-oriented display price, it must convert both the submitted value and
the comparison direction. Never submit a display-price limit directly as a raw `targetPrice`.

All ceilings and floors are inclusive. Zero means zero; it never means "unbounded." Use an integer type's maximum
only when the account policy deliberately wants no practical ceiling. For fresh public commits, independently
mandatory fields such as the deadline, expected configuration hash, execution-mode mask, and maximum post-trade
leverage cannot be zero.

Fresh commits additionally require a nonzero `clientOrderId`, a nonzero lot-aligned `sizeDelta`,
`validUntil > block.timestamp`, and `validUntil - block.timestamp <= OrderRouter.maxOrderAge`. Close requests require
`marginDelta == 0`, the same side as the account's bounded queued-position projection, and a size no larger than that
projection. Fresh public client ids must not start with `0x504c455448455221`; that prefix is reserved for
protocol-generated position-protection orders.

| Bound | What it limits |
|-------|----------------|
| `validUntil` | Absolute execution deadline; equality is executable and expiry begins one second later |
| `allowedExecutionModes` | Authorization mask bits: `Live = 1 << 0` (`1`), `Fad = 1 << 1` (`2`), `Frozen = 1 << 2` (`4`) |
| `expectedConfigHash` | Exact execution-critical configuration accepted by a public intent; zero is internal-only |
| `maxExecutionBountyUsdc` | Keeper bounty that may be reserved at commit |
| `maxExecutionNotionalUsdc` | Canonical planner-assessed execution notional |
| `maxGrossAccountDebitUsdc` | Settlement debit, consumed trader claims, and reserved bounty in aggregate |
| `maxActionChargeUsdc` | Net assessed action charge after applicable carry, signed VPI, execution fee, and frozen spread composition |
| `maxExplicitFeesUsdc` | Open execution fee, or close execution fee plus frozen spread when applicable |
| `maxPostPositionSize` | Resulting live position size |
| `minPostSettlementBalanceUsdc` | Resulting total internal settlement custody, including locked buckets |
| `minPostPositionEquityUsdc` | Resulting live-position equity |
| `maxPostLeverageBps` | Resulting live-position leverage |

A terminal full close still enforces every non-position bound. It skips post-position equity and leverage checks only
because no position survives.

Router-authenticated position-protection parent and trigger orders are the only zero-config exception. Those internal
requests use `expectedConfigHash == bytes32(0)` as an unpinned marker, enable every execution mode, use
`validUntil = block.timestamp + maxOrderAge`, set upper bounds to their integer maxima and minimum bounds to zero,
and record the configuration actually observed at execution. They remain subject to ordinary protocol safety policy,
but they are not a caller-selected financial envelope. This exception is unavailable through public `commitOrder`:
an agent-supplied fresh request with a zero configuration hash is rejected.

For `commitOpenOrderWithProtection`, a caller target of zero is translated before registration to `1` for a LONG
dollar-index open or `CAP_PRICE` for a SHORT dollar-index open. Trigger-generated market-style closes use the reverse
nonbinding sentinels: `CAP_PRICE` for a LONG dollar-index close and `1` for a SHORT dollar-index close.
`IntentRegistered` contains the translated nonzero target. Separately, zero in a TP/SL threshold disables that OCO
leg; both threshold legs cannot be zero.

The evaluator checks these constraints against an authoritative snapshot reconstructed from the Engine and
Clearinghouse immediately before mutation. A caller cannot satisfy a bound by supplying its own accounting inputs.

The authorization mask is not the same encoding as the `ExecutionMode` enum in results and receipts. Enum values are
`None = 0`, `Live = 1`, `Fad = 2`, and `Frozen = 3`; decode them as enums rather than mask bits.

Bounds do not promise execution, fill, profit, liveness, or immediately withdrawable USDC. Profitable settlement may
be represented by a senior trader claim until the HousePool can fund it, and wallet-level authority remains outside
the order envelope.

## Bounded-order idempotency that survives process failure

`clientOrderId` is permanent within one chain, Router/Book deployment, and account namespace. It is not a temporary
nonce.

- The first successful submission binds the complete canonical intent hash to an order id.
- An exact replay returns the original order id before current deadline, configuration, market-state, or lifecycle
  validation and causes no second reservation, queue entry, counter increment, or event.
- Reusing the same id with any changed request field is a conflict.
- Another account may independently use the same bytes32 id.
- Execution or failure does not release the id for reuse.

This allows an agent to retry after an RPC timeout, relayer failure, restart, or uncertain transaction submission
without risking a duplicate position. A useful client-id policy is to derive the id from a stable strategy decision
identifier, account, and action sequence—not from data that changes between retries.

Protection actions do not accept a caller-supplied client id. Before retrying an uncertain
`commitOpenOrderWithProtection`, create, replace, cancel, or trigger transaction, reconcile the retained protection
record, its events, and the account's pending-order state. Blind application-level retries do not receive the public
bounded-order exact-replay guarantee.

If governance configuration changes or the strategy wants different bounds, create a new client id. The old id still
describes the old authorization and must remain immutable.

## Pinning protocol meaning

Before constructing a fresh public request, read `OrderLifecycleBook.currentExecutionConfigHash()` at the intended
chain and deployment. The digest commits to the configuration schema, chain, lifecycle Book, Router, Engine,
Clearinghouse, HousePool, Oracle, policy evaluator, bounded-order execution sidecar, planners, settlement modules,
treasury, terminal NAV book, finalized admin versions, and Pool mark-staleness policy.

The hash deliberately does not freeze dynamic market state. Current price, depth, skew, FAD/frozen regime, pauses,
LP settlement hold, and the emergency risk-off cutoff can change without changing the digest. Those conditions are
handled by the request's mode and financial bounds or by runtime safety policy.

The digest does not include the Router-bound keeper sidecar or Router-created protection Book as separate fields;
verify those through Router getters, immutable bindings, and the deployment manifest. It also excludes the immutable
HousePool redemption-math sidecar because that module affects LP redemption budgeting, not order execution. Admin
domains contribute their finalized active configuration versions; pending timelock proposals are not active execution
policy and therefore are not committed.

For a nonzero externally pinned expectation, a later mismatch terminalizes as `ConfigMismatch` unless risk-off,
expiry, account liquidation, or another terminal cleanup path finalizes the order first. Authenticated protection
requests use the zero marker, skip equality, and record `observedConfigHash` in their receipt.

## Price selection is protocol-defined

A keeper supplies Pyth update payloads, not an arbitrary execution price. In Live and FAD execution, the Router parses
the unique historical FX-basket tick in
`(commitTime, min(commitTime + orderSettlementWindow, block.timestamp)]`. The tick immediately preceding that range
must have a publish time no later than `commitTime`, preventing a keeper from skipping an earlier eligible tick in
favor of a later one.

The Oracle derives the side-adverse execution price from the validated FX basket and confidence interval. It caps that
price before applying the request's directional target boundary. Frozen execution follows the separate validated
stored FX-basket policy and fixed frozen-close spread rules. This makes price selection part of protocol meaning
rather than keeper discretion.

## Machine-readable execution semantics

`ExecutionResult` distinguishes a terminal transition from a pending stop:

- `orderId`
- `status`
- `terminalReason`
- `pendingReason`
- `receiptHash` when terminal

The `orderId` argument to `executeOrder` may be a later committed id used as an inclusive pre-oracle terminal-cleanup
bound. The returned `ExecutionResult.orderId` identifies the item actually classified; an integration must not assume
it always equals the argument.

Terminal reasons include execution, expiry, slippage, configuration mismatch, disallowed execution mode, risk-off,
typed planner rejection, financial constraint violation, and account liquidation.

Pending reasons include close-only policy, same-block and MEV boundaries, unavailable historical price, insufficient
gas, mark-price ordering, unknown Engine failure, receipt failure, and cleanup limit. Pending means the authorization
and reservations remain live; it is not a successful no-op and should not be recorded as terminal by the agent.

The protocol terminalizes only exact, typed business-policy failures. Panics, out-of-gas, empty reverts, unknown
selectors, malformed typed failures, and malformed success payloads remain retryable. This prevents infrastructure
faults from being guessed into financial meaning.

`BatchResult` contains:

- `nextOrderId`: the next live FIFO head, or zero after a complete drain;
- `terminalCount`: how many orders finalized in this call;
- `stopReason`: why bounded progress stopped.

Inspect `nextOrderId` even when `stopReason == None`: the call may have completed its inclusive `maxOrderId` bound
while a later FIFO head still exists.

Each prepared order executes in an item-local rollback frame. A retryable item failure does not undo an already
finalized prefix. Oracle/Pyth preparation and the resulting Engine mark update happen in the outer batch frame and
remain batch-atomic, so agents that require strict progress boundaries should bound `maxOrderId` and separate
pre-oracle cleanup from price-dependent execution.

## Verifying what actually happened

For an externally submitted bounded order, use both on-chain state and the canonical event:

1. Resolve `(account, clientOrderId)` with `clientIntent` and compare the stored intent hash with
   `hashOrderRequest(account, request)`.
2. While pending, compare `pendingIntent` and `pendingPolicy` with the instruction approved by the account layer.
3. On terminal status, read `outcome(orderId)` from the Book.
4. Fetch the corresponding `OrderFinalized` event using the Book address and indexed order/account/client-id fields.
5. Recompute
   `keccak256(abi.encode(RECEIPT_TYPEHASH, chainId, book, router, terminalBlock, terminalTime, receipt))` and compare it
   with both the event and `outcome(orderId).receiptHash`.
6. Independently reconcile the receipt economics with Engine, Clearinghouse, and pool events when the strategy's risk
   policy requires deeper accounting assurance.

`IntentRegistered` emits the complete registered `OrderRequest`, its canonical intent hash, and the order bounty
actually reserved. For a public bounded-order commit, this is the account's original request. For a protection parent
or linked close, it is the protocol-generated request and does not by itself prove the original scalar protection
action.

`OrderFinalized` emits the complete fixed-shape receipt, including:

- client and order identity;
- expected and observed configuration hashes;
- lifecycle status, terminal reason, execution regime, executor, and price source;
- adverse execution price, neutral mark, pool depth, and oracle publish time;
- whether the price reached the Engine;
- that queued order's exact stored execution bounty, recipient, and disposition;
- typed failure evidence and revert-data hash;
- normalized execution economics and post-state summaries.

Receipt validation is terminal-reason specific. Expiry, config mismatch, and risk-off are valid no-price,
non-Engine receipts with `PriceSource.None`, zero execution price and oracle time, and
`priceReachedEngine == false`. A risk-off receipt can still be finalized inside a liquidation transaction after that
transaction performs oracle and mark work. Liquidation uses `PriceSource.Liquidation` and a liquidation price but
still sets `priceReachedEngine == false`. A verifier must not apply one blanket nonzero-price or reached-Engine rule
to every receipt.

For TP/SL, also reconcile the retained protection record and `PositionProtectionCreated`,
`PositionProtectionReplaced`, `PositionProtectionArmed`, `PositionProtectionCancelled`,
`PositionProtectionTriggered`, and `PositionProtectionTerminal` events from the protection Book. They prove the
thresholds, protection status, triggered leg, trigger mark and publish time, and
`parentOrderId`/`linkedOrderId` association that an order receipt does not contain. The receipt bounty covers only the
queued order's stored execution bounty. Protection trigger bounties and protection reserves that are separately
refunded or forfeited require the protection and Clearinghouse/Engine evidence; once a linked-close bounty transfers
into ordinary order accounting, its close receipt covers that stored bounty.

The Router deletes terminal live-order records. This is intentional: use the Book's permanent compact outcome and
receipt hash for durable state, and the canonical event for the full receipt.

For `AccountLiquidated`, the order receipt proves queued-order cleanup and bounty disposition. The Engine's
liquidation events remain canonical for the position's liquidation economics. Both receipt state-summary slots use
the observed post-liquidation state.

## Recommended bounded-order workflow

### 1. Bind the deployment

- Resolve the intended chain, Router, Book, Engine, Clearinghouse, Pool, Oracle, evaluator, execution sidecar, keeper
  sidecar, and protection Book addresses from a trusted deployment manifest.
- Verify `Book.ROUTER/ENGINE/CLEARINGHOUSE/HOUSE_POOL`, the keeper sidecar's exact `ROUTER`, the protection Book's
  `ROUTER/ENGINE`, and the Router's Book, evaluator, both sidecars, protection Book, Oracle, Engine, and Pool bindings.
  Require code at every address and the intended components to be pairwise distinct before funding the account.
- Pin chain id and contract addresses in the agent's own allowlist. Do not discover a mutation target from an
  unauthenticated API response.

### 2. Read and model

- Read compact market/account state from `PerpsPublicLens`.
- Verify that the Router-bound Oracle and execution configuration identify the intended dollar-index market.
- Translate the strategy's LONG/SHORT dollar-index decision to the ABI side and raw FX-basket price domain.
- Use Engine previews for the intended trade.
- Read `currentExecutionConfigHash()` from the Book.
- Choose a nonzero target, finite deadline, allowed regimes, and bounds derived from the user's risk mandate.

Pin related reads and simulations to one block. If the RPC cannot serve a coherent block, restart the decision rather
than combining observations from different states. Previews describe a block-specific candidate Engine transition
under supplied price/time inputs; bounds remain the enforceable authorization if state moves before execution.

### 3. Resolve idempotency before submission

- Construct the complete `OrderRequest` once.
- Call `resolveClientIntent(account, request)`.
- Continue only for `Unused` or `ExactReplay`; escalate a `Conflict` as an integrity error.
- Simulate the exact smart-account call and then submit it.

### 4. Confirm registration

- Read the returned or emitted order id.
- Verify `clientIntent`, `lifecycleStatus`, and `pendingIntent` from the Book.
- Confirm the actually reserved bounty does not exceed the request bound.
- Treat transaction inclusion without matching Book state as unsuccessful integration, even if a relayer reports
  success.

### 5. Monitor and execute

- Observe FIFO position and lifecycle status.
- Obtain Pyth payloads from a trusted source and quote the exact fee.
- Simulate the exact `executeOrder` or bounded `executeOrderBatch` calldata at a recent block.
- Submit with enough gas for the Router's post-Engine settlement tail.
- If the result is pending, classify `PendingReason` and retry only when its prerequisite changes.

An agent may operate its own keeper, use a shared keeper network, or do both. The same per-order limits are enforced
regardless of who executes, with the documented self-execution versus external-keeper bounty treatment.

### 6. Reconcile independently

- Confirm terminal Book status and compact outcome.
- Verify the full receipt and receipt hash.
- Reconcile balances, position state, and bounty disposition.
- Persist block number and block hash so reorg handling can invalidate off-chain observations cleanly.

## Position-protection workflow

TP/SL thresholds are also raw 8-decimal FX-basket prices. Their product-facing direction is:

| Product position | Take-profit condition | Stop-loss condition |
|------------------|-----------------------|---------------------|
| LONG dollar index | raw mark at or below TP | raw mark at or above SL |
| SHORT dollar index | raw mark at or above TP | raw mark at or below SL |

1. Discover the protection Book from the verified Router and read the account's active protection plus current
   position, pending orders, cached mark, feature flag, and configured bounties at one block.
2. Authorize explicit OCO thresholds and action selectors. Zero disables one threshold leg, but both legs cannot be
   zero. A trigger threshold authorizes queuing a delayed full-position market-style close; it does not guarantee a
   fill at the threshold.
3. Simulate the exact direct Book call. An attached-open caller target may be zero and will be translated into the
   documented nonbinding bounded-order sentinel.
4. After submission—or before any retry after uncertain inclusion—reconcile the protection record and events plus
   the parent order's lifecycle state. Protection calls do not have caller-controlled client-id replay protection.
5. To trigger, submit `triggerPositionProtection` directly to the Book with Pyth data and the quoted fee. Then monitor
   the retained `linkedOrderId` and execute that ordinary FIFO close through the Router keeper interface.
6. Reconcile both evidence domains: protection state/events for OCO intent and trigger facts, and lifecycle Book
   state/receipts for the synthesized parent and linked-close orders. Account separately for trigger and order
   bounties.

## Smart-account and session-key policy

The core protocol does not issue agent permissions. A production account layer should normally restrict:

- allowed chain and target contract addresses;
- callable selectors, especially separating trading from withdrawals and arbitrary transfers;
- the Router-discovered protection Book as a separate target, with only the create/replace/cancel/attach/trigger
  selectors that the user actually authorized;
- token approvals and maximum value sent with payable keeper calls;
- per-order and rolling exposure limits;
- deadline and execution-mode policy;
- strategy-level client-id namespace;
- session expiry, revocation, and emergency owner recovery;
- whether the agent may execute orders, commit orders, manage margin, or only propose transactions.

The safest default is to prevent the agent key from directly withdrawing margin or making arbitrary calls. It can be
allowed to submit a bounded `OrderRequest`, while the smart account independently validates the same high-level user
mandate. Protocol bounds are then a second enforcement layer rather than the only one. Position-protection selectors
should be allowlisted only when the account policy separately validates their OCO geometry, retry behavior, and
protocol-synthesized execution envelope.

## Operational cautions

- **FIFO cancellation:** ordinary FIFO orders—including protected parent opens and triggered linked closes—cannot be
  cancelled. Use deliberate deadlines and do not submit speculative placeholders. Expiry does not automatically
  delete an order; a permissionless execution/cleanup call must reach it and record the terminal outcome. A
  `PendingOpen` or `Armed` protection record can be replaced or cancelled, but cancelling `PendingOpen` does not
  cancel its parent order.
- **FIFO:** a retryable head can delay later orders. Monitor `PendingReason` and use bounded cleanup/execution calls.
- **Governance changes:** for an externally submitted bounded-order intent, a pinned configuration change terminally
  fails the old intent unless risk-off, expiry, liquidation, or another terminal cleanup path finalizes it first; it
  does not authorize a new one. Internal protection orders are deliberately unpinned and record the observed
  configuration instead.
- **Dynamic state:** the configuration hash is not a price, liquidity, pause, or oracle-regime snapshot. Use bounds
  and fresh reads as well.
- **Index basis:** a dollar-index sleeve is not a perfect portfolio hedge; model basket, cap, and correlation basis.
- **Oracle dependency:** live execution requires valid Pyth data and ETH for its fee. A data API is not authoritative;
  the contracts validate payloads and publish-time policy.
- **Event finality:** wait for the confirmation depth appropriate to the chain and handle reorgs before treating an
  indexed receipt as final. Full receipts are event-backed, so historical verification also needs reliable log or
  archive access.
- **Advisory lenses:** monitoring and preview outputs help plan a transaction but do not override mutation-time
  checks.
- **Gas and batches:** per-item rollback isolation starts after outer oracle preparation. Keep batch bounds small when
  a strict, predictable progress boundary matters.
- **Contract size:** several core contracts operate close to EIP-170. Integrations should not assume new convenience
  methods can be added to the core contracts; prefer stable interfaces and off-chain composition.
- **Audit status:** the protocol remains pre-deployment and formal production audit coverage, including the agent
  execution-authority components, is pending. Check [`SECURITY.md`](SECURITY.md) against the exact deployment commit.

## Integration checklist

- [ ] Use the canonical deployment and verify immutable bindings.
- [ ] Put agent authority behind a revocable smart account or session policy.
- [ ] Use LONG/SHORT dollar-index terminology consistently in policies, calldata, and reports.
- [ ] Verify the bound Oracle/configuration and model basis against the portfolio exposure being managed.
- [ ] For bounded orders, read the Book's current execution configuration hash.
- [ ] For bounded orders, use a permanent account-scoped client id and resolve it before submission.
- [ ] For bounded orders, set every financial bound explicitly; never treat zero as unbounded.
- [ ] For bounded orders, use a nonzero target and a finite deadline.
- [ ] For protection, verify the separate Book target, OCO geometry, active record, and non-idempotent retry state.
- [ ] Simulate the exact smart-account and keeper calldata.
- [ ] For every queued order, confirm registration from the lifecycle Book, not only from an RPC response.
- [ ] Distinguish terminal and pending outcomes mechanically.
- [ ] For every terminal queued order, verify `OrderFinalized` against the compact on-chain receipt hash.
- [ ] Reconcile position, custody, claims, and bounty disposition after finalization.
- [ ] Handle confirmation depth, reorgs, RPC disagreement, and Pyth data availability.

## Reference map

- [`CfdTypes.sol`](src/CfdTypes.sol): current perps ABI side encoding and core position types; apply the product-facing
  direction mapping defined above.
- [`PletherOracle.sol`](src/PletherOracle.sol): authoritative dollar-index pricing configuration and timing policy.
- [`OrderV2Types.sol`](src/OrderV2Types.sol): request, bounds, lifecycle, failure, economics, and result types.
- [`IOrderLifecycleBook.sol`](src/interfaces/IOrderLifecycleBook.sol): authoritative identity, policy, outcome, and
  configuration reads.
- [`IPerpsTraderActions.sol`](src/interfaces/IPerpsTraderActions.sol): canonical order submission ABI.
- [`IPerpsKeeper.sol`](src/interfaces/IPerpsKeeper.sol): canonical order, liquidation, and LP settlement execution ABI.
- [`IPositionProtectionActions.sol`](src/interfaces/IPositionProtectionActions.sol): direct trader and trigger-keeper
  protection actions.
- [`IPositionProtectionViews.sol`](src/interfaces/IPositionProtectionViews.sol): active and retained protection reads.
- [`PositionProtectionTypes.sol`](src/interfaces/PositionProtectionTypes.sol): OCO parameters, status, trigger leg, and
  retained evidence types.
- [`CANONICAL_ENTRYPOINTS.md`](CANONICAL_ENTRYPOINTS.md): complete product-facing integration boundary.
- [`README.md`](README.md): protocol lifecycle, accounting, oracle, and governance behavior.
- [`SECURITY.md`](SECURITY.md): trust assumptions, failure handling, and known limitations.
- [`DEPLOYMENT.md`](DEPLOYMENT.md): deployment and binding verification.

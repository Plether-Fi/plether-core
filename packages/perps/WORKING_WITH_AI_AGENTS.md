# Working with AI Agents

This guide is for developers building autonomous trading agents on Plether Perps. Start with the
[protocol overview](README.md), then use this guide to construct bounded orders, manage take-profit/stop-loss
protection, and verify outcomes. The same interfaces and checks apply to human-operated accounts.

The protocol provides permanent order identity, explicit execution limits, and authenticated receipts. Your
application supplies wallet delegation, session keys, strategy policy, user approvals, and monitoring. Protocol
bounds apply to individual orders; portfolio limits and key revocation belong in the account layer.

## Account and deployment setup

The caller of `OrderRouter.commitOrder` is the trading account and owns its client-id namespace. Trader actions on
`OrderRouter.positionProtectionBook()` likewise use their caller as the account. If a smart account submits the
call, query positions, margin, claims, and orders by the smart-account address rather than its owner EOA.
Permissionless keepers can execute orders and trigger protection, but cannot replace the account's authorized intent.

Before funding an account:

1. Select a trusted deployment manifest and verify the chain, contract code, and component bindings using
   [DEPLOYMENT.md](DEPLOYMENT.md). Source interfaces alone do not establish that a deployed release supports them.
2. Discover `lifecycleBook()` and `positionProtectionBook()` from the verified Router. Check the lifecycle Book's
   immutable `ROUTER`, `ENGINE`, `CLEARINGHOUSE`, and `HOUSE_POOL` bindings and the protection Book's `ROUTER` and
   `ENGINE` bindings. Include the Router's sidecars, evaluator, and Oracle in deployment verification.
3. Restrict the agent's account permissions to approved targets and selectors, token allowances, ETH value, exposure,
   and session duration. Trading authority does not need to include withdrawals or arbitrary transfers.

Approve the Clearinghouse to spend settlement USDC, then call `depositMargin(amount)` from the trading account.
This credits margin custody and checkpoints carry. Alternatively, a payer can call `depositFor(account, amount)`;
that credits the beneficiary's free settlement without collecting carry or granting the payer trading authority.
Existing carry remains due. `Deposit` and `DepositFor` describe one credit with additional payer metadata, not two
credits. See [BRIDGE_FUNDING.md](BRIDGE_FUNDING.md) for bridge-specific evidence and fallback handling.

The Router and its sidecars do not custody trader USDC. Call the Router for orders and execution, and its discovered
protection Book for protection actions. Sidecars are implementation modules, not alternate trader entrypoints.

## Direction, prices, and units

The raw FX-basket mark moves opposite to dollar strength:

| Product position | Positive price PnL when the raw mark | ABI encoding |
| --- | --- | --- |
| LONG dollar index | Falls | `CfdTypes.Side.LONG` (`0`) |
| SHORT dollar index | Rises | `CfdTypes.Side.SHORT` (`1`) |

Use LONG/SHORT dollar index consistently in policy and reports. BULL/BEAR name the separate spot tokens.
All order and protection prices use the raw FX-basket quote, even if your UI displays its inverse.

| Quantity | Contract units |
| --- | --- |
| USDC amounts | 6 decimals: `1e6` is 1 USDC |
| Prices | 8 decimals: `1e8` is a raw price of 1 |
| Position size | 18 decimals, in lots of `1e20` (100 tokens) |
| Time | Unix seconds |
| Leverage | Basis points: `10_000` is 1× |

`targetPrice` is a nonzero, inclusive execution boundary. It is checked against the side-adverse execution price,
not the neutral mark:

| Action | Accepted raw execution price |
| --- | --- |
| Open/increase LONG dollar index | `executionPrice >= targetPrice` |
| Open/increase SHORT dollar index | `executionPrice <= targetPrice` |
| Close/reduce LONG dollar index | `executionPrice <= targetPrice` |
| Close/reduce SHORT dollar index | `executionPrice >= targetPrice` |

For example, opening LONG with `targetPrice = 95_000_000` accepts a raw execution price of 0.95 or higher.
If your UI uses an inverse price, convert both the submitted value and comparison direction.

## Building an order

Submit the complete `OrderV3Types.OrderRequest` through `IPerpsTraderActions.commitOrder(request)`. It contains
`clientOrderId`, `side`, `sizeDelta`, `marginDelta`, `targetPrice`, `isClose`, and `bounds`.

Fresh requests require:

- A nonzero account-scoped `clientOrderId`. The prefix `0x504c455448455221` is reserved for protocol-generated orders.
- A nonzero, lot-aligned size and nonzero target price.
- `submitBy >= block.timestamp` and `0 < executionWindowSeconds <= OrderRouter.maxExecutionWindowSeconds()`.
- The current nonzero configuration hash, a nonempty valid execution-mode mask, and nonzero `maxPostLeverageBps`.
- For closes, `marginDelta == 0`, the same side as the account's queued-position projection, and a size no larger
  than that projection. Partial closes also face minimum-notional admission checks.

Committed orders enter a global first-in, first-out (FIFO) queue and cannot be cancelled. `submitBy` limits when a
fresh commitment may occur; the execution deadline is the actual commitment time plus `executionWindowSeconds`.
Use deliberate execution windows. Passing a deadline does not remove the order until a cleanup or execution call
records its terminal outcome.

### Financial limits

Every ceiling and floor is inclusive. Zero is a real zero allowance, never shorthand for unlimited. Use an integer
maximum only when your account policy intentionally permits that exposure.

| Bound | Meaning |
| --- | --- |
| `submitBy` | Last permitted fresh-commit timestamp |
| `executionWindowSeconds` | Duration from commitment to execution deadline |
| `allowedExecutionModes` | Mask: Live `1`, Fad `2`, Frozen `4`; combine permitted bits |
| `expectedConfigHash` | Exact execution configuration accepted by the account |
| `maxExecutionBountyUsdc` | Maximum order bounty reserved at commitment |
| `maxExecutionNotionalUsdc` | Maximum planner-assessed execution notional |
| `maxGrossAccountDebitUsdc` | Maximum aggregate settlement debit, consumed trader claims, and reserved bounty |
| `maxActionChargeUsdc` | Maximum assessed action charge after carry, signed virtual price impact (VPI), fees, and frozen spread are combined |
| `maxExplicitFeesUsdc` | Maximum execution fee plus any frozen-close spread |
| `maxPostPositionSize` | Maximum resulting position size |
| `minPostSettlementBalanceUsdc` | Minimum total internal settlement custody, including locked value; restrictions below |
| `minPostPositionEquityUsdc` | Minimum resulting position equity |
| `maxPostLeverageBps` | Maximum resulting position leverage |

The evaluator constructs authoritative Engine and Clearinghouse state immediately before execution. An agent cannot
satisfy a limit by supplying its own accounting inputs. Full closes skip post-position equity and leverage checks
because no position remains; other limits still apply.

A **positive settlement floor** is supported only for an open from a flat account with no pending orders, including
an attached protected open. It is rejected for increases, closes, and overlapping orders. The account must fund at
least `minPostSettlementBalanceUsdc + maxGrossAccountDebitUsdc` in total custody at commitment. While this order is
pending, withdrawals preserve that amount and new orders are blocked; exact replays remain valid. The floor is
released when the order becomes terminal. A positive floor combined with an unlimited gross-debit ceiling cannot
be funded. Use zero for requests outside this supported case.

Limits do not guarantee execution or immediately withdrawable USDC. Profitable settlement may create a senior trader
claim until the HousePool can fund it. `minPostSettlementBalanceUsdc` is a custody floor, not a wallet cash balance.

### Configuration and execution modes

Read `OrderLifecycleBook.currentExecutionConfigHash()` before constructing a fresh request. The hash binds execution
components and finalized configuration versions. A later mismatch fails a pinned order as `ConfigMismatch`, unless
another terminal path such as expiry, risk-off cleanup, or liquidation takes precedence.

Price, liquidity, skew, pauses, emergency cutoffs, and the current oracle regime are dynamic and are not frozen by
that hash. Use current reads, financial limits, and the permitted-mode mask together. Live, FAD (Friday Afternoon
Deleverage), and Frozen policy are explained in [README.md](README.md). Authorizing a mode does not bypass its
protocol restrictions.

The mask differs from the `ExecutionMode` enum in results: enum values are `None = 0`, `Live = 1`, `Fad = 2`, and
`Frozen = 3`. Decode receipt enums separately from authorization bits.

### Idempotency

`clientOrderId` is permanent within a chain, Router/Book deployment, and account namespace:

- The first successful submission binds the complete request hash to an order id.
- An identical replay returns that id before current timing, configuration, market-state, or lifecycle validation.
  It creates no second reservation, queue entry, or registration event.
- Any changed request field with the same id is a conflict. Execution or failure does not free the id for reuse.

Persist the complete request before broadcasting. Derive the id from a stable strategy decision or action sequence,
not values that change on every retry. Use `resolveClientIntent(account, request)` to distinguish `Unused`,
`ExactReplay`, and `Conflict`; use `clientIntent(account, clientOrderId)` to recover an order after uncertain inclusion.
A changed authorization needs a new id, but that does not cancel the earlier pending order.

This guarantee applies to ordinary `commitOrder`. Composite protection actions require fresh requests and do not
provide the same replay guarantee; reconcile their state before retrying.

## Reads, previews, and submission

Use related reads at one block so the decision is based on coherent state:

| Surface | Purpose |
| --- | --- |
| `PerpsPublicLens` | Compact account, position, tranche, protocol, and protection state |
| Router-bound `PletherOracle` | Market configuration, oracle policy, and fee quotes |
| `ICfdEngineLens.previewOpen` / `previewClose` | Candidate trade economics at a supplied price |
| `CfdClosePreview.previewClose` | Prospective close including commitment-time carry |
| `ICfdEngineLens.previewRouterLiquidation` | Liquidation economics after Router risk-off refunds |
| `IOrderLifecycleBook` | Permanent identity, pending limits, timing, and terminal outcome |
| `IPositionProtectionViews` | Retained protection state and separate `closeFinancialLimits` |
| `SettlementMonitorLens` | Advisory LP settlement routing and operational health |

Previews do not ingest Pyth data or reproduce every Router oracle, FIFO, pause, MEV, slippage, and gas check. They
are candidate transitions, not execution promises. Inspect validity and failure fields before interpreting economics,
and simulate the exact account call before broadcasting.

The bounded-request overload of `CfdClosePreview.previewClose` resolves client identity first. A nonzero
`replayOrderId` means no new close would be submitted; commitment and assessment fields are empty. Read the existing
order's lifecycle instead of interpreting those zero fields as a quote. For an execution assessment of a pending
order, use the policy evaluator's `assessCommittedOrder`.

A practical order loop is:

1. Read state, preview the trade, and read the current configuration hash at one block.
2. Construct and persist the complete request, resolve its client id, and simulate the exact account call.
3. Submit, then confirm the matching `clientIntent` and `IntentRegistered` evidence. If still pending, compare
   `pendingIntent` and `pendingPolicy` with the authorized request and reserved bounty.
4. Monitor lifecycle and FIFO progress. Execute yourself or let a permissionless keeper do so.
5. Reconcile the authenticated terminal receipt, position, balances, claims, and bounty movement.

Inclusion is distinct from execution. A normal RPC transaction receipt also does not expose Solidity return values;
after broadcast use logs and Book state. Persist the RPC block hash and log location for reorg handling.

## Execution and cleanup

Call `IPerpsKeeper` on the Router:

| Action | Use |
| --- | --- |
| `executeOrder(orderId, pythUpdateData)` | Execute the head or advance terminal-head cleanup through an inclusive id bound |
| `executeOrderBatch(maxOrderId, pythUpdateData)` | Process FIFO orders through an inclusive committed id bound |
| `expireOrder(orderId)` | Clean up an expired order without oracle data |
| `clearInvalidOrders(orderIds)` | Clear expired or config-invalid ids, including non-head orders; returns progress |
| `clearRiskOffOrder(orderId)` | Refund a pre-cutoff opening order invalidated by risk-off, including a non-head order |
| `executeLiquidation(account, pythUpdateData)` | Test and liquidate an unsafe account |
| `executeLiquidationBatch(accounts, pythUpdateData)` | Process account candidates with one shared oracle update; resume at `nextIndex` |
| `settleLpEpoch(pythUpdateData)` | Atomically refresh the mark and settle eligible LP epoch work |

The keeper supplies Pyth payloads rather than an arbitrary execution price. Live and FAD orders use a unique
historical basket in `(commitTime, min(commitTime + orderSettlementWindow, block.timestamp)]`, with predecessor
checks that prevent skipping an earlier eligible tick. The Oracle applies adverse confidence adjustment and price
caps; the Router enforces the target boundary. Frozen closes use the stored-mark policy and frozen-close spread.
Quote the applicable oracle fee and simulate the exact call with sufficient gas for settlement and receipt creation.

`ExecutionResult` reports `orderId`, lifecycle `status`, `terminalReason`, `pendingReason`, and a terminal
`receiptHash`. Its returned order id can differ from the requested inclusive cleanup bound.

- **Terminal:** execution, expiry, slippage, configuration mismatch, disallowed mode, risk-off, typed planner or
  financial-limit rejection, liquidation, or expiry with reservation-mismatch recovery. Read the receipt.
- **Pending:** close-only policy, same-block or MEV timing, unavailable history, insufficient gas, mark ordering,
  unknown Engine failure, receipt failure, cleanup cap, or historical parser failure. The order remains live;
  retry when the prerequisite changes.

Only recognized, correctly encoded business-policy failures are terminalized. Panics, empty or malformed reverts,
unknown failures, and malformed success payloads remain retryable. `HistoricalPriceUnavailable` means the supplied
payload lacks a qualifying update; it does not prove no such history exists.

`BatchResult.nextOrderId` identifies the next live head, `terminalCount` counts completed orders, and `stopReason`
explains the stop. Inspect `nextOrderId` even when `stopReason == None`: later orders may remain beyond the requested
bound. Each prepared item has a separate rollback boundary, so a retryable item or historical-parser failure can
preserve earlier progress. Other outer Oracle/Pyth preparation failures can revert the batch. Bound batches when a
predictable amount of progress matters.

Opening orders may reserve a bounty. Successful self-execution releases it to the account's free settlement;
external execution credits the keeper's Clearinghouse account. Ordinary and protection-generated closes have zero
order bounty, including failed-close cleanup. Risk-off cleanup refunds remaining margin and bounty to internal
settlement and pays no cleaner. Liquidation can forfeit unpaid opening and protection-trigger bounties. Interpret
actual receipt amounts rather than assuming every terminal outcome paid a keeper.

## Take-profit and stop-loss protection

Protection is a full-position one-cancels-the-other (OCO) instruction. Call `IPositionProtectionActions` directly on
the Router-discovered protection Book. One account can have one active protection record; ordinary orders are blocked
while it is active, except through the documented protection actions.

| Position | Take-profit trigger | Stop-loss trigger |
| --- | --- | --- |
| LONG dollar index | Raw neutral mark at or below TP | Raw neutral mark at or above SL |
| SHORT dollar index | Raw neutral mark at or above TP | Raw neutral mark at or below SL |

Zero disables a leg; both legs cannot be zero. A threshold authorizes queuing a delayed full-position close, so it
does not guarantee execution at the threshold price. Creation and replacement require enabled thresholds to be on
the untriggered side of a fresh mark and no higher than `CAP_PRICE`. Creation, replacement, and initial triggering
require an unfrozen oracle; an already-latched retry does not re-evaluate the trigger.

Supply `PositionProtectionParams` with thresholds and four `closeLimits`: maximum execution notional, gross account
debit, action charge, and explicit fees. All use six-decimal USDC and zero means zero allowance. Read retained limits
with `closeFinancialLimits(protectionId)`; they are separate from `getPositionProtection`.

| Action | Requirements and effect |
| --- | --- |
| `createPositionProtection(params)` | Existing full position, no active protection or pending orders; reserves the trigger bounty |
| `commitOpenOrderWithProtection(request, params)` | Flat account with no pending orders; fresh bounded parent open and staged protection |
| `replacePositionProtection(id, params)` | Owner updates thresholds and close limits while `PendingOpen` or `Armed` |
| `cancelPositionProtection(id)` | Owner cancels while `PendingOpen` or `Armed`, refunding the unpaid trigger bounty |
| `cancelPositionProtectionAndCommitClose(id, request)` | Owner atomically cancels matching `Armed` protection and submits a fresh bounded full close |
| `triggerPositionProtection(id, pythUpdateData)` | Permissionlessly evaluates an `Armed` protection and queues a close if crossed |
| `amendLatchedPositionProtectionCloseLimits(id, limits)` | Owner changes financial limits after a failed attempt has become `Latched` |
| `retryPositionProtectionClose(id)` | Permissionlessly queues a new attempt for `Latched` protection without re-evaluating the trigger |

An attached parent uses the same complete bounded request as ordinary `commitOrder`, including its nonzero target
and current configuration hash. Parent success normally arms protection even if the fill tick crossed a staged
threshold; triggering requires a later block and newer basket publication. If the accepted live basket is newer than
the Engine mark or disagrees at the same timestamp after the fill, protection fails and refunds its trigger bounty
while the parent remains executed.
Parent failure also fails the protection and releases its unpaid trigger bounty. Cancelling `PendingOpen` protection
does not cancel its already-queued parent.

Triggering pays the reserved trigger bounty once and queues a zero-bounty close at the global FIFO tail. The
protocol-generated close permits all execution modes, is intentionally unpinned (`expectedConfigHash == 0`), and
uses the current maximum execution window. It copies the four retained close limits into each attempt. Other upper
bounds use their type maxima, minimum bounds are zero, and the nonbinding target is `CAP_PRICE` for a LONG close or
`1` for a SHORT close. Public `commitOrder` cannot use this zero-config exception.

These limits apply per attempt, including commitment charges, not cumulatively across retries. If commitment would
exceed a limit, triggering reverts and the owner can replace the `Armed` protection. If a queued close fails and the
protected side and size still match, protection becomes `Latched`; the owner may amend its limits before retrying.
Each retry gets a new id, commitment time, execution deadline, and oracle window. It requires no pending Router
orders and does not re-test the original trigger. Missing or changed positions end protection as `Failed` instead.

`Triggered` and `Latched` protection remain binding and cannot be cancelled or replaced. While Router pause blocks
new protection and replacement, cancellation, trigger, retry, and atomic cancel-and-close remain available. The
atomic exit also works during frozen markets; its close still obeys FIFO and the caller's mode and financial limits.
If commitment fails, cancellation and bounty refund roll back. If it succeeds, later close failure or expiry does
not restore protection.

Composite actions are not idempotent replays of their parent order. After uncertain inclusion, reconcile the retained
protection record, events, and parent/child lifecycle before resubmitting. Keep every attempt id; `linkedOrderId`
contains only the latest attempt. Track the separate trigger reward independently of the zero-bounty close receipts.

## Verifying outcomes

The immutable `OrderLifecycleBook` owns permanent identity and terminal summaries. The Router deletes terminal
live-order records, and pending Book policy is removed at finalization. `orderTiming(orderId)` remains available.

For each queued order:

1. Resolve `(account, clientOrderId)` with `clientIntent` and compare its intent hash with
   `hashOrderRequest(account, request)`.
2. Read `lifecycleStatus` and `terminalOutcome`. If pending, use `pendingIntent` and `pendingPolicy` instead.
3. Find `OrderFinalized` emitted by the verified Book, matching its indexed order, account, and client id.
4. Authenticate the complete event receipt against the stored summary with `verifyReceipt(receipt, terminalTime)`,
   or recompute `keccak256(abi.encode(RECEIPT_TYPEHASH, chainId, book, router, terminalBlock, terminalTime, receipt))`.
   Compare indexed identity, terminal status/reason, and the event hash with the stored outcome as well.
5. Reconcile the actual economics with position, custody, claims, and Engine/Clearinghouse events as needed.

The repository's [terminal-history helper](../perps-aa-client/src/terminalHistory.ts),
`decodeVerifiedOrderFinalized`, performs the receipt and identity checks locally. The current source uses a V3
request/intent domain and V5 receipt/config domains. Use ABIs and manifests matching the actual deployment; archived
releases must retain their own schemas.

`IntentRegistered` contains the complete request, reserved bounty, and commitment timing. For a generated protection
close, this proves the generated intent; the original OCO instruction requires protection state and events as well.

`OrderFinalized` includes expected/observed configuration, execution regime and price source, failure details,
commitment effects, assessed economics, post-state summaries, and actual bounty disposition. Carry in the assessment
is not necessarily a separate settlement debit: full-close collection or waiver is reflected in the aggregate charge
and close-accounting fields. Avoid summing overlapping diagnostic fields as independent debits.

Validate receipt fields according to the terminal reason. Expiry, config mismatch, and risk-off can have no execution
price or oracle timestamp, even though cached mark and pool context are present. Liquidation cleanup can report a
liquidation price while `priceReachedEngine == false`; the Engine's liquidation events describe the position's
liquidation economics. Neither a nonzero execution price nor `priceReachedEngine` is a universal terminal invariant.

| Bounty disposition | Value | Meaning |
| --- | --- | --- |
| `None` | 0 | No bounty movement or recipient |
| `Paid` | 1 | Paid to executor, including release on self-execution |
| `Forfeited` | 2 | Credited to treasury |
| `RefundedToAccount` | 3 | Refunded to the source account |

Read the paid, refunded, forfeited, and discrepancy amounts. Reservation-mismatch expiry can recover an amount that
differs from the recorded entitlement. A valid receipt hash authenticates evidence; independent accounting checks
can still be useful.

For protection, also retain creation/replacement, close-limit updates, arming, cancellation, trigger, close-attempt,
and terminal events. They establish thresholds, immutable trigger facts, changing close limits, parent linkage, and
all retries. An order receipt alone does not contain that full history or the separate trigger bounty movement.

Use RPC log block numbers and hashes to locate events and handle reorgs. The Book's `terminalBlock` is Solidity's
`block.number`, which is not an RPC L2 log locator on Arbitrum. Historical verification needs reliable event access;
the compact on-chain outcome does not store the full receipt.

## Further references

- [CANONICAL_ENTRYPOINTS.md](CANONICAL_ENTRYPOINTS.md): complete supported integration surface.
- [OrderV3Types.sol](src/OrderV3Types.sol): requests, bounds, timing, enums, economics, and receipts.
- [IOrderLifecycleBook.sol](src/interfaces/IOrderLifecycleBook.sol): identity, policy, timing, and evidence reads.
- [IPerpsKeeper.sol](src/interfaces/IPerpsKeeper.sol): execution, cleanup, liquidation, and LP settlement.
- [IPositionProtectionActions.sol](src/interfaces/IPositionProtectionActions.sol) and
  [IPositionProtectionViews.sol](src/interfaces/IPositionProtectionViews.sol): protection actions and reads.
- [SECURITY.md](SECURITY.md): trust assumptions, limitations, and audit status.

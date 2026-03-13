# Perps Hardening Roadmap

This document captures the highest-value post-audit hardening work for the perps system. The current codebase is in much better shape than the starting point, but the next level of quality comes from turning accounting boundaries and settlement semantics into explicit architecture instead of relying on conventions.

## Goals

- Make collateral and liability domains explicit in code
- Prevent cross-domain accounting drift
- Unify preview and execution semantics
- Standardize fail-soft liability handling
- Complete the order lifecycle with explicit cancel semantics

## 1. Formalize The Clearinghouse Bucket Model

Highest priority.

The system already behaves as if account collateral is split into distinct buckets, but the model is still implicit. Make those buckets first-class in `src/perps/MarginClearinghouse.sol` and `src/perps/interfaces/IMarginClearinghouse.sol`.

Target buckets:

- settlement balance
- reserved settlement
- active position margin
- other locked margin
- free settlement

Recommended changes:

- add typed bucket accessors instead of relying on raw balance math
- add typed consume/release primitives for each operation class
- avoid raw `balances(accountId, settlementAsset)` reads in engine settlement code
- encode which buckets are consumable by funding, close, liquidation, and order-bounty flows

Expected payoff:

- large reduction in semantic accounting bugs
- simpler audit review of reachability rules
- fewer regressions when future features touch collateral movement

## 2. Split Accounting By Domain

The four accounting domains should become real code modules, not just a conceptual model in specs and review notes.

Recommended libraries/modules:

- `SolvencyAccounting`
- `WithdrawalAccounting`
- `LiquidationAccounting`
- `OrderEscrowAccounting`

Primary refactor targets:

- `src/perps/CfdEngine.sol`
- `src/perps/HousePool.sol`
- `src/perps/OrderRouter.sol`
- `src/perps/libraries/`

Rules:

- each module owns its own snapshots and derived views
- cross-domain helper reuse must be deliberate and obvious
- reserve, equity, and distributable-cash concepts should not share generic helpers unless they truly match

Expected payoff:

- fewer cases of using the wrong reserve definition in the wrong path
- clearer code review boundaries
- easier reasoning about protocol health vs user withdrawals vs order escrow

## 3. Unify Preview And Execution Through Shared Settlement Kernels

Preview and execution logic should run through the same internal settlement kernels whenever possible.

Principle:

- one internal kernel computes canonical settlement outputs
- preview functions expose those outputs without state writes
- execution functions apply those same outputs with state writes

Good candidates:

- close settlement
- liquidation settlement
- open-cost and fee previews where practical

Primary targets:

- `src/perps/CfdEngine.sol`
- new internal settlement libraries if needed

Expected payoff:

- fewer false previews
- lower review burden
- less divergence between UX-facing data and live execution semantics

## 4. Finish The Fail-Soft Liability Model

The clean architectural end state is that every terminal vault-paid receivable follows the same rule:

- pay immediately if cash exists
- otherwise record a deferred liability
- include that deferred liability in solvency, withdrawal, and NAV accounting immediately

This is already in place for deferred trader payouts and deferred liquidation bounties. The remaining work is to make the model uniform everywhere the vault owes terminal value.

Important boundary:

- terminal receivables should be fail-soft
- live margin credits should remain immediate-only unless the protocol intentionally adopts a new deferred-margin-credit model

That means profitable closes, positive liquidation residuals, and liquidation bounties fit the fail-soft pattern. By contrast, positive funding credits and open-path rebates are not simple receivables; they immediately change live collateralization and margin health. Converting those paths to the existing deferred-payout mechanism would silently change position semantics, so they should not be folded into the fail-soft model without a separate design.

Primary targets:

- `src/perps/CfdEngine.sol`
- `src/perps/HousePool.sol`
- accounting libraries under `src/perps/libraries/`

Expected payoff:

- one consistent terminal receivable/liability model
- cleaner behavior under temporary liquidity stress
- easier audit reasoning about what happens when vault cash is low

## 5. Add Explicit Cancel Semantics

The order lifecycle is still missing a fully explicit cancel path.

Even if lazy failure remains acceptable for stale tail orders, adding user cancel semantics makes the state machine more complete and easier to reason about.

Recommended behavior to define:

- who can cancel and when
- how committed margin is released
- how reserved execution bounty escrow is refunded
- how FIFO interacts with user-initiated cancellation
- what happens to expired vs cancelled vs invalid orders

Primary targets:

- `src/perps/OrderRouter.sol`
- `test/perps/OrderRouter.t.sol`

Expected payoff:

- cleaner user experience
- easier queue/liveness reasoning
- simpler long-term maintenance of the order state machine

## Suggested Implementation Order

1. Formalize the clearinghouse bucket model
2. Split accounting by domain
3. Unify preview and execution through shared settlement kernels
4. Finish the fail-soft liability model
5. Add explicit cancel semantics

This order prioritizes architectural correctness before state-machine completeness.

## Test And Invariant Work

These changes should come with stronger model-level verification, not just path-local unit tests.

Add invariants for:

- bucket preservation across all settlement paths
- reserved execution bounty escrow never consumed by funding or liquidation settlement
- deferred liabilities always reduce effective solvency and withdrawal capacity
- preview/live parity for close and liquidation flows

Add scenario tests for:

- funding loss with only locked active margin available
- liquidation with queued orders and protected execution-bounty escrow
- mixed deferred payouts and liquidity stress
- explicit cancel and refund semantics once implemented

## Risk / Payoff Summary

- Clearinghouse bucket model: high effort, very high payoff
- Domain accounting modules: medium-high effort, very high payoff
- Shared preview/execution kernels: medium effort, high payoff
- Universal fail-soft liabilities: medium effort, high payoff
- Explicit cancel semantics: medium effort, medium payoff

## Main Takeaway

The biggest remaining opportunity is not adding more isolated tests. It is making the accounting domains and settlement reachability rules explicit enough that the wrong mental model becomes hard to encode in code.

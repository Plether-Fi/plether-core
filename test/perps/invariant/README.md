# Perps Invariant Suites

This directory contains stateful Foundry invariant suites for the perps system.

## Suites

- `PerpAccountingInvariant.t.sol`
  - Catches hidden-collateral and split-accounting bugs
  - Verifies router-held execution bounty escrow reconciles with live orders
  - Verifies liquidated accounts cannot keep pending orders, live reserves, or recover value later
  - Verifies ghost-tracked committed margin and deferred clearer bounty stay aligned with protocol state
  - Verifies a stricter per-order committed-margin state machine across commit, execution, cancellation, failure, and liquidation
  - Verifies pending-order and margin-order FIFO queues keep consistent head/tail pointers, links, counts, and ordering

- `PerpPreviewInvariant.t.sol`
  - Catches view-layer drift between previews and core engine/accounting state
  - Verifies empty positions preview as inactive
  - Verifies liquidation reachable collateral previews match clearinghouse accounting
  - Verifies degraded-mode trigger flags behave as transition flags rather than persistent state flags

- `PerpDeferredPayoutInvariant.t.sol`
  - Catches deferred trader payout and liquidity-gating bugs
  - Verifies deferred payout status matches engine storage and current vault liquidity
  - Verifies deferred trader payout ghost accounting stays fully model-derived and reconciles with engine totals
  - Verifies close and liquidation previews use all-or-nothing immediate vs deferred payout gating

- `PerpEconomicConservationInvariant.t.sol`
  - Catches protocol-wide ledger drift and conservation bugs
  - Verifies known actor and protocol balances conserve total USDC supply
  - Verifies clearinghouse custody matches tracked account balances
  - Verifies the compact per-account ledger view stays aligned with clearinghouse buckets, router escrow, deferred payouts, and pending order counts
  - Verifies the expanded per-account ledger snapshot stays aligned with collateral, position-health, and settlement-reachability views
  - Verifies tracked per-account settlement, escrow, and deferred payouts aggregate cleanly into protocol custody and obligation buckets
  - Verifies deposit/withdraw transitions preserve monotonic reachability expectations
  - Verifies no orphaned account-risk state remains once an account has no position and no pending orders
  - Verifies the expanded account ledger snapshot fully subsumes compact, collateral, and position views
  - Verifies per-account settlement buckets reconcile with clearinghouse storage
  - Verifies the canonical protocol accounting snapshot stays aligned with accessors and house-pool snapshots
  - Verifies house-pool input/status snapshots stay aligned with vault assets, fees, deferred liabilities, and engine status
  - Verifies withdrawal reserves include liabilities, fees, and deferred obligations
  - Verifies tracked bad debt only remains after reachable tracked account value is exhausted
  - Verifies ghost-tracked deferred trader payouts match engine storage and totals

## Harness Pieces

- `BasePerpInvariantTest.sol`
  - Shared invariant deployment harness using a deterministic mock vault

- `handlers/PerpAccountingHandler.sol`
  - Stateful fuzz actor that performs deposits, withdrawals, order commits, execution, liquidation, payout claims, and vault mode changes

- `ghost/PerpGhostLedger.sol`
  - Independent ghost model for liquidation snapshots, committed margin ownership, and deferred clearer bounty tracking

- `mocks/MockInvariantVault.sol`
  - Deterministic test vault that can force router payout success or failure and directly control available vault liquidity

## Typical Commands

```bash
forge test --match-contract PerpAccountingInvariantTest
forge test --match-contract PerpPreviewInvariantTest
forge test --match-contract PerpDeferredPayoutInvariantTest
forge test --match-contract PerpEconomicConservationInvariantTest
```

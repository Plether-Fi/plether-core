# Perps Invariant Suites

This directory contains stateful Foundry invariant suites for the perps system.

## Suites

- `PerpAccountingInvariant.t.sol`
  - Catches hidden-collateral and split-accounting bugs
  - Verifies router-held execution bounty escrow reconciles with live orders
  - Verifies liquidated accounts cannot keep pending orders, live reserves, or recover value later
  - Verifies ghost-tracked committed margin and deferred clearer bounty stay aligned with protocol state

- `PerpPreviewInvariant.t.sol`
  - Catches view-layer drift between previews and core engine/accounting state
  - Verifies empty positions preview as inactive
  - Verifies liquidation reachable collateral previews match clearinghouse accounting
  - Verifies degraded-mode trigger flags behave as transition flags rather than persistent state flags

- `PerpDeferredPayoutInvariant.t.sol`
  - Catches deferred trader payout and liquidity-gating bugs
  - Verifies deferred payout status matches engine storage and current vault liquidity
  - Verifies close and liquidation previews use all-or-nothing immediate vs deferred payout gating

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
```

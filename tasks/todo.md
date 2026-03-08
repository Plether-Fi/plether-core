# Perps Audit Fix Plan

Fixes ordered by severity and dependency. Each fix gets a failing test first, then the code fix.

## Critical

- [x] **C5**: Funding traps profitable positions (committed `1be0a07`)
- [x] **C2**: No initial margin check — zero-margin vault drain (committed `1be0a07`)
- [x] **C1**: Keeper steals user ETH on order cancellation (committed `1be0a07`)
- [x] **C3**: Flash-loan depth manipulation reduces VPI charges (committed `1be0a07`)

## High

- [x] **H8**: entryPrice truncation causes globalMaxProfit underflow
  - Track cumulative `maxProfitUsdc` in Position struct. Proportional reduction on close.
  - Files: `CfdTypes.sol`, `CfdEngine.sol`, all test files (struct field update)

- [x] **H6**: Senior tranche yield erasure via reconcile spam
  - `unpaidSeniorYield` accumulator decouples yield accrual from revenue availability.
  - Files: `HousePool.sol` (_reconcile, _distributeRevenue)

- [x] **H9**: Solvency deadlock blocks voluntary closes during insolvency
  - Skip `_assertPostSolvency()` for close orders. Closes always reduce liability; blocking users from exiting doesn't fix the underlying problem.
  - Files: `CfdEngine.sol` (processOrder)

## Medium

- [x] **M11**: Liquidation ignores unencumbered cross-margin equity
  - After seizing posMargin in bad-debt branch, seize from user's free USDC balance to cover remaining deficit.
  - Files: `CfdEngine.sol` (liquidatePosition), `IMarginClearinghouse.sol` (added balances/lockedMarginUsdc)

- [x] **M12**: getFreeUSDC doesn't reserve accumulated fees
  - Subtract `accumulatedFeesUsdc` in `getFreeUSDC()` so LPs can't withdraw fee-earmarked USDC.
  - Files: `HousePool.sol` (getFreeUSDC)

- [x] **M10**: JIT LP attack via unrealized PnL
  - Mitigated by C3 deposit cooldown (1-hour capital lockup). Full fix (streaming revenue) deferred to V2.
  - Files: test only (cooldown already in TrancheVault)

## Not Fixing

- **H7** (slippage reversed): Invalid — verified logic is correct
- **C4** (USDC-only seizure): V1 is USDC-only by design. Will address when adding non-USDC collateral in V2

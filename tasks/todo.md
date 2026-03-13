- [x] Inspect the USDC keeper-fee change for lost anti-griefing protections
- [x] Restore an upfront per-order USDC reserve that keeps queue clearing incentivized on failures and expiries
- [x] Update tests and docs for the reserved-fee model
- [x] Verify targeted perps suites still pass
- [x] Add failing regression test for open-path skew double-count on the hard skew cap
- [x] Add failing regression test for queued keeper-fee reserves overstating liquidation equity
- [x] Run targeted forge tests to confirm both new regressions fail on current code

- [x] Inspect harness and current audit regressions for the newly verified findings
- [x] Add failing tests for each verified valid finding (#1, #2, #3, #4, #5, #6, #8)
- [x] Run targeted forge tests and record the current failure reasons

- [x] Run the perps tests to enumerate all current failures and group by root cause
- [x] Implement contract fixes for the verified audit issues and any overlapping failing regressions
- [x] Re-run targeted suites plus broader `test/perps` coverage until the regressions pass
- [x] Record the final status and any remaining follow-up work

Review:
- `test_C3_OpenSkewCapMustUseSingleSizeDelta` currently fails with `CfdEngine__SkewTooHigh()`.
- `test_C4_KeeperFeeReserveMustReduceLiquidationEquity` currently fails with `CfdEngine__PositionIsSolvent()`.
- `forge test --match-path test/perps/AuditVerifiedFindingsFailing.t.sol` now fails 8/8 as intended for findings #1, #2a, #2b, #3, #4, #5, #6, and #8.
- The new failure set covers funding netting, empty-market skew bypass, skew double-counting, stale-keeper fee theft, underwater partial closes, cooldown proxy bypass, free-equity keeper-fee seizure, and liquidation degraded-mode bypass.
- Implemented fixes in `src/perps/CfdEngine.sol`, `src/perps/OrderRouter.sol`, `src/perps/HousePool.sol`, `src/perps/TrancheVault.sol`, and updated interfaces.
- Verified green: `AuditVerifiedFindingsFailing.t.sol`, `AuditLatestStateFindingsFailing_*`, and `AuditConfirmedFindingsFailing_OpenSkewCap`.
- Broader `test/perps/*.t.sol` still contains legacy exploit/expectation tests that now fail because behavior changed (for example stale single-order execution now reverts instead of refunding, third-party cooldown bypass tests invert, and old skew-bypass PoCs no longer execute). These need expectation updates if the entire historical suite must be green.

- [x] Inspect `executeOrderBatch` keeper payout flow against single-order execution
- [x] Reuse deferred keeper reward fallback for batched vault payouts
- [x] Add regression coverage for illiquid-vault batched close execution
- [x] Attempt targeted verification for the new regression

Review:
- Updated `src/perps/OrderRouter.sol` so batched keeper payouts use the same `try/catch -> recordDeferredKeeperReward` fallback as `_finalizeExecution()`.
- Added `test_BatchDeferredKeeperReward_DoesNotRevertLaterOrders` in `test/perps/OrderRouter.t.sol` to cover a profitable close plus a later order in the same batch while vault cash is drained.
- Verification is currently blocked by an unrelated compile error already present in the worktree: `src/perps/CfdEngine.sol:1111` references `pos.entryNotionalUsdc`, but `CfdTypes.Position` has no such member.

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

- [x] Design the next architecture-focused test plan for escrow, solvency, and queue invariants
- [x] Add high-value failing regression coverage for the currently unguarded architectural gaps
- [x] Run the new regression file and record the newly confirmed failures

Review:
- Added `test/perps/ArchitectureRegression.t.sol` with six targeted failing regressions covering escrow reachability, seizure protection, liquidation solvency reachability, deferred-liability reconciliation, fee-withdraw solvency consistency, and free invalid close commits.
- `forge test --match-path test/perps/ArchitectureRegression.t.sol` fails 6/6 on the current branch, which is expected and confirms the gaps still exist.
- While writing the suite, uncovered an extra live bug: liquidation solvency still counts locked position margin as reachable equity, so a clearly underwater BULL position at `1.11e8` incorrectly reverts with `CfdEngine__PositionIsSolvent()` instead of liquidating.

- [x] Extend queue tests with larger adversarial scenarios and poisoned-head coverage
- [x] Extend the invariant suite with cross-module solvency/liquidity differentials
- [x] Run targeted and broader queue/invariant suites to verify the new guardrails

Review:
- Added three larger queue regressions in `test/perps/OrderRouter.t.sol` covering a 200-order adversarial batch tail execution, a poisoned-head failed close that must not pin later orders, and a full close that still succeeds with a large foreign queue behind it.
- Extended `test/perps/PerpInvariant.t.sol` with cross-module differentials for protocol accounting views, deferred-liability inclusion in withdrawal reserves, pool liquidity view consistency, and preview-vs-live liquidation agreement.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol` (93 passed) and `forge test --match-path test/perps/PerpInvariant.t.sol` (17 passed).

- [x] Add a stateful adversarial invariant handler that mixes queue spam, close failures, and liquidity starvation
- [x] Add invariants around adversarial escrow backing, queue pointer safety, and cross-module liquidity consistency
- [x] Verify the full invariant file stays green with the new adversarial handler enabled

Review:
- Added `AdversarialPerpHandler` and `AdversarialPerpInvariantTest` in `test/perps/PerpInvariant.t.sol` to fuzz mixed queue spam, invalid close intents, LP liquidity starvation, liquidity replenishment, and batched execution in one stateful run.
- The adversarial suite now asserts that queued keeper escrow stays backed, queue pointers remain ordered, pool/router custody assumptions hold, and engine/pool liquidity views remain consistent while those mixed actions execute.
- Verified green: `forge test --match-path test/perps/PerpInvariant.t.sol --match-contract AdversarialPerpInvariantTest` and `forge test --match-path test/perps/PerpInvariant.t.sol`.

- [x] Analyze current order execution and close fee accounting paths
- [x] Implement flat close keeper bounty reservation in `OrderRouter`
- [x] Update `CfdEngine` close accounting so collectible close fees accrue to protocol
- [x] Adjust tests and audit regressions for the new fee model
- [x] Run targeted Foundry tests and document results

Review:
- Close orders now reserve a flat `1 USDC` keeper bounty in `src/perps/OrderRouter.sol`, while open orders keep their notional-based bounded reserve.
- `src/perps/CfdEngine.sol` now books collectible close execution fees into `accumulatedFeesUsdc`; order execution no longer depends on vault-funded keeper payouts.
- Updated queue/accounting docs in `src/perps/README.md` and `src/perps/SECURITY.md`, plus router/engine/audit tests that previously assumed close fees paid keepers.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterTest`, `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterPythTest`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test PhantomExecFee`, `forge test --match-path test/perps/AuditLatestFindingsFailing.t.sol`, `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-contract AuditRemainingCoverageFindingsFailing_CloseLiquidityAndFees`, and `forge test --match-path test/perps/AuditRemainingFindingsFailing.t.sol`.

- [x] Audit fee-related naming, views, interfaces, and Natspec across perps modules
- [x] Apply semantic cleanup for execution bounty vs protocol fee terminology
- [x] Expand README with a dedicated fees section covering opens, closes, keepers, and edge cases
- [x] Update tests/docs references and run targeted verification

Review:
- Renamed router-facing order escrow semantics from keeper-fee language to execution-bounty language in `src/perps/OrderRouter.sol`, including public views/getters like `executionBountyReserves`, `quoteOpenOrderExecutionBountyUsdc()`, and `quoteCloseOrderExecutionBountyUsdc()`.
- Renamed deferred liquidation-keeper accounting in `src/perps/CfdEngine.sol`, `src/perps/interfaces/ICfdEngine.sol`, and `src/perps/HousePool.sol` so the interface now clearly distinguishes deferred trader payouts from deferred liquidation bounties.
- Expanded `src/perps/README.md` with a dedicated fees section covering protocol execution fees, order execution bounties, deferred liabilities, and the rationale for separating take-rate from executor incentives; updated `src/perps/SECURITY.md` and `src/perps/ACCOUNTING_SPEC.md` to match.
- Verified green: `forge build`, `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterTest`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test DeferredPayoutStatus`, `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-contract AuditRemainingCoverageFindingsFailing_CloseLiquidityAndFees`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-contract PerpInvariantTest`.

- [x] Inspect current clearinghouse and engine settlement interfaces for funding/liquidation spend paths
- [x] Implement clearinghouse spend primitives for funding loss and liquidation residual settlement
- [x] Refactor engine funding and liquidation settlement to use canonical clearinghouse helpers
- [x] Add/update regression tests for locked-margin funding and liquidation escrow preservation
- [x] Run targeted Forge tests and document results

Review:
- Added `consumeFundingLoss()` and `consumeLiquidationResidual()` to `src/perps/MarginClearinghouse.sol` and `src/perps/interfaces/IMarginClearinghouse.sol` so free settlement, active position margin, reserved execution bounty escrow, and unrelated locked margin now have explicit operation-specific consumption rules.
- Refactored `src/perps/CfdEngine.sol` to route negative funding settlement through `consumeFundingLoss()` and liquidation residual settlement through `consumeLiquidationResidual()`, eliminating the old seize-before-unlock flow and the raw-balance liquidation mismatch.
- Added targeted regressions in `test/perps/CfdEngine.t.sol` proving that (1) funding loss can consume locked position margin when free settlement is zero and (2) liquidation preserves reserved settlement escrow.
- Verified green: `forge build`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "FundingLoss_CanConsumeLockedPositionMargin_WhenFreeSettlementIsZero|Liquidation_PreservesReservedSettlementEscrow|C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable"`, and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "C1_FullCloseMustNotTreatQueuedCommittedMarginAsLossShield|H1_QueuedCollateralPreventsPrematureLiquidation"` (with `C1` now passing and `H1` still failing because its revert expectation no longer matches the current liquidation semantics).

- [x] Identify stale liquidation tests that still assume pre-reachability semantics
- [x] Rewrite failing liquidation tests to assert new reserved-escrow-preserving behavior
- [x] Run targeted Forge tests for updated liquidation expectations

Review:
- Rewrote `test_H1_QueuedCollateralPreventsPrematureLiquidation` into `test_H1_LiquidationMustPreserveQueuedCollateralBuckets` in `test/perps/AuditRemainingCoverageFindingsFailing.t.sol` so it now asserts the new liquidation semantics directly: liquidation clears the live position while preserving the queued order's committed margin and reserved execution bounty escrow.
- Verified green: `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "H1_LiquidationMustPreserveQueuedCollateralBuckets|C1_FullCloseMustNotTreatQueuedCommittedMarginAsLossShield"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold|Liquidation_PreservesReservedSettlementEscrow"`.

- [x] Inspect `previewClose` VPI handling and locate trust/cooldown doc mismatches
- [x] Fix negative-VPI panic in `previewClose`
- [x] Update docs for `payReservedSettlementUsdc` trust surface and TrancheVault cooldown behavior
- [x] Run targeted Forge tests and record results

Review:
- Updated `src/perps/CfdEngine.sol` so `previewClose()` now carries a signed `vpiDeltaUsdc` field, clamps the legacy positive-only `vpiUsdc` field to charges only, and computes net settlement from the signed delta. This removes the negative-VPI panic while preserving rebate visibility.
- Clarified the operator trust surface in `src/perps/MarginClearinghouse.sol`, `src/perps/README.md`, and `src/perps/SECURITY.md`: `payReservedSettlementUsdc()` can route reserved execution bounty escrow to an arbitrary recipient, while `seizeAsset()` remains self-recipient only.
- Updated the TrancheVault cooldown docs in `src/perps/README.md` and `src/perps/SECURITY.md` to match the actual meaningful-third-party-top-up reset behavior in `src/perps/TrancheVault.sol`.
- Verified green: `forge build` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_ReturnsDeferredAndImmediateSettlementBreakdown|PreviewClose_NegativeVpiDoesNotPanic"`.

- [x] Inspect remaining failing perps tests and map each failure to stale fee or liquidation expectations
- [x] Rewrite stale 4 bps fee expectations in audit and engine tests
- [x] Rewrite liquidation bounty and reachability expectations to current semantics
- [x] Run targeted Forge tests for the updated failing slices

Review:
- Updated stale fee-model expectations across `test/perps/CfdEngine.t.sol`, `test/perps/AuditFindings.t.sol`, `test/perps/AuditLatestFindingsFailing.t.sol`, and `test/perps/AuditRemainingFindingsFailing.t.sol` so they now reflect the live 4 bps execution fee model instead of the old 6 bps assumptions.
- Updated stale liquidation expectations across `test/perps/CfdEngine.t.sol`, `test/perps/AuditFollowupFindingsFailing.t.sol`, `test/perps/AuditCurrentFindingsVerification.t.sol`, `test/perps/AuditRemainingCoverageFindingsFailing.t.sol`, and `test/perps/AuditFullSecurityFailing.t.sol` to match the current positive-equity bounty cap and reachable-collateral settlement behavior.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "OpenTradeCostCannotSeizeReservedSettlementEscrow|WithdrawFees|MarginDrained_ByFees_Reverts|LiquidationBounty_CappedByPositiveEquity|OpenPosition_SolvencyCheck|VpiDepthManipulation_NeutralizedByStatefulBound|MM_RebateZeroed_DesignTradeoff"`, `forge test --match-path test/perps/AuditFindings.t.sol --match-test "C03_PostFeeMarginBelowImr"`, `forge test --match-path test/perps/AuditFollowupFindingsFailing.t.sol --match-test "H1_PositiveEquityLiquidationCapsAtRemainingEquity"`, `forge test --match-path test/perps/AuditCurrentFindingsVerification.t.sol --match-test "M2_KeeperBountyShouldUsePositiveEquityNotPositionMargin"`, `forge test --match-path test/perps/AuditFullSecurityFailing.t.sol --match-test "C1_LiquidationMustConsumeFreeUsdcCountedInEquity"`, `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "H2_PositiveEquityLiquidationBountyMustCapAtRemainingEquity"`, `forge test --match-path test/perps/AuditLatestFindingsFailing.t.sol --match-test "M1_ExecutionFeesAccrueToProtocolNotLpEquity"`, and `forge test --match-path test/perps/AuditRemainingFindingsFailing.t.sol --match-test "M1_ExecutionFeesAreProtocolRevenue"`.

- [x] Inspect failing `HousePool` reserve-accounting test and current `getFreeUSDC` logic
- [x] Patch `HousePool` fee reserve accounting to match current execution-bounty/protocol-fee semantics
- [x] Run targeted HousePool test and final full perps suite

Review:
- Confirmed `src/perps/HousePool.sol` was already using the correct reserve source (`ENGINE.getWithdrawalReservedUsdc()`), and the sole remaining failure in `test/perps/HousePool.t.sol` was a stale fee expectation still pinned to the old 6 bps execution fee.
- Updated `test_M12_GetFreeUSDC_ReservesFees` in `test/perps/HousePool.t.sol` to expect the live 4 bps fee accrual (`40_000_000`) and to use current execution-bounty terminology.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "M12_GetFreeUSDC_ReservesFees"` and `forge test --match-path "test/perps/*.t.sol"`.

- [x] Verify the latest audit findings against current code and spec
- [x] Trace queue cancellation, seizure reachability, fee routing, liquidation bounty, and commit-time validation paths
- [x] Cross-check each claim against `ACCOUNTING_SPEC.md` and existing regression coverage
- [x] Record a finding-by-finding verdict with supporting file references

Review:
- Verified by code inspection and targeted Forge runs.
- Rejected as stale/fixed: queue-cancel O(N) liquidation brick, seizure-poison-pill liquidation brick, and close-fee-to-keeper/vault-drain claim.
- Rejected as security findings: commit-time invalid-close validation is intentional, and positive-equity liquidation bounty capping is explicitly documented/tested behavior rather than an accidental regression.
- Verified green: `forge test --match-path test/perps/ArchitectureRegression.t.sol`, `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "C1_FullCloseMustNotTreatQueuedCommittedMarginAsLossShield|H1_LiquidationMustPreserveQueuedCollateralBuckets"`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PhantomExecFee|PreviewLiquidation_ReturnsBountyAndLiquidatableFlag"`.
- One legacy audit regression still fails because its expectation is stale: `forge test --match-path test/perps/AuditLatestFindingsFailing.t.sol --match-test test_M1_ExecutionFeesAccrueToProtocolNotLpEquity` expects `120e6`, but the current 4 bps fee model correctly accrues `80e6`.

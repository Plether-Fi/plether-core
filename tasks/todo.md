- [x] Inspect current `HousePool`/`CfdEngine` accounting handoff and identify every getter the pool stitches together
- [x] Add one canonical `HousePoolInputSnapshot` engine view and refactor `HousePool` to consume it everywhere
- [x] Update interfaces/tests/docs as needed and run targeted perps verification

Review:
- Added `ICfdEngine.HousePoolInputSnapshot` plus `getHousePoolInputSnapshot(uint256 markStalenessLimit)` so the engine now hands HousePool one typed accounting/freshness boundary instead of many loosely coupled getters.
- Refactored `src/perps/HousePool.sol` and `src/perps/libraries/HousePoolAccountingLib.sol` so withdrawal accounting, reconcile accounting, and mark-freshness policy all derive from that single engine snapshot.
- Added targeted engine tests in `test/perps/CfdEngine.t.sol` covering both normal-market and frozen-oracle snapshot semantics.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "GetHousePoolInputSnapshot|GetProtocolAccountingView_ReflectsDeferredLiabilities"` and `forge test --match-path test/perps/HousePool.t.sol --match-test "M12_GetFreeUSDC_ReservesFees|GetVaultLiquidityView_ReturnsCurrentPoolState|FrozenOracle_UsesRelaxedMarkFreshnessForWithdrawals|StaleMarkBlocksWithdrawal"`.

- [x] Extend `HousePoolInputSnapshot` with mark timestamp and view-only status flags
- [x] Refactor `HousePool` to use the fully self-contained snapshot for freshness + liquidity view reads
- [x] Update snapshot tests and rerun targeted perps verification

Review:
- Extended `HousePoolInputSnapshot` with `lastMarkTime`, `oracleFrozen`, and `degradedMode`, making the engine handoff self-contained for both freshness enforcement and liquidity-view status reporting.
- Refactored `src/perps/HousePool.sol` to stop reaching back into standalone engine getters for mark timestamp and view flags once the snapshot has been fetched.
- Expanded `test/perps/CfdEngine.t.sol` assertions so snapshot fields are checked against engine state in both normal-market and frozen-oracle paths.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "GetHousePoolInputSnapshot|GetProtocolAccountingView_ReflectsDeferredLiabilities"` and `forge test --match-path test/perps/HousePool.t.sol --match-test "GetVaultLiquidityView_ReturnsCurrentPoolState|FrozenOracle_UsesRelaxedMarkFreshnessForWithdrawals|StaleMarkBlocksWithdrawal"`.

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

- [x] Verify the new external security review against the current refactor state

Review:
- Invalid: the claimed infinite close-order drain is blocked in two places in the live code: `pendingCloseSize[accountId] + sizeDelta <= positionSize` is enforced in `src/perps/OrderRouter.sol`, and failed close orders use `FailedOrderBountyPolicy.None`, so reverting duplicate closes do not pay a keeper bounty.
- Invalid: the claimed liquidation-evasion via open-order escrow shielding is neutralized by `executeLiquidation()` restoring router-held open-order bounties back into the clearinghouse before `engine.liquidatePosition()`, which is also covered by `test_ExecuteLiquidation_RestoresEscrowedOpenBountiesBeforeBadDebt` and `test_ExecuteLiquidation_PreventsPostLiquidationEscrowRecovery`.
- Valid issue remains: close orders are still cancellable by the owner in `src/perps/OrderRouter.sol`, while open orders are binding, so there is still a free/cheap option style cancellation surface for delayed closes.
- Preview/DST/dead-code findings are not current security bugs: the degraded-mode preview flag is intentionally transition-only (`PerpPreviewInvariant` asserts this), Sunday unfreezes at `21:00 UTC` by design and is covered by `test_SundayDst_OracleUnfrozenAt21`, and `_seizeUsdcToVault` is already absent from the current `src/perps/CfdEngine.sol`.
- Re-verified the previously claimed fixes: zero-clamped MtM in `getVaultMtmAdjustment()`, the stateful VPI bound in `CloseAccountingLib`, and batch gas `break` behavior all exist in code and their targeted regressions pass.

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

- [x] Refactor clearinghouse reachability and consume paths around one internal bucket snapshot
- [x] Update related tests to assert bucket preservation across writes
- [x] Run targeted Forge tests for clearinghouse settlement paths

Review:
- Added the first explicit bucket-model implementation slice in `src/perps/MarginClearinghouse.sol` and `src/perps/interfaces/IMarginClearinghouse.sol`: `getAccountUsdcBuckets()` now exposes settlement balance, reserved settlement, total locked margin, active position margin, other locked margin, and free settlement as first-class fields instead of leaving those partitions implicit.
- Extended `src/perps/CfdEngine.sol` collateral views to surface `activePositionMarginUsdc` and `otherLockedMarginUsdc`, so perps-facing diagnostics now reflect the clearinghouse bucket model directly.
- Added regression coverage in `test/perps/MarginClearinghouse.t.sol` and `test/perps/CfdEngine.t.sol` proving both read-side and write-side bucket preservation.
- Extracted the bucket math into `src/perps/libraries/MarginClearinghouseAccountingLib.sol` so the clearinghouse now uses one shared kernel for bucket construction, funding-loss consumption planning, and reachable-balance planning.
- Verified green: `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "GetAccountUsdcBuckets|ConsumeFundingLoss_PreservesOtherLockedAndReservedBuckets|ConsumeLiquidationResidual_PreservesOtherLockedAndReservedBuckets|FreeSettlementBalance_TracksLockedUsdcOnly"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "GetAccountCollateralView_ReturnsCurrentBuckets"`.

- [x] Identify liquidation-specific math/snapshot logic in `CfdEngine` for extraction
- [x] Add `LiquidationAccounting` library for preview/live shared calculations
- [x] Wire `CfdEngine` liquidation preview/live paths to the new library without behavior changes
- [x] Run targeted liquidation tests and record results

Review:
- Added `src/perps/libraries/LiquidationAccountingLib.sol` to hold the shared liquidation kernel: equity composition, maintenance margin, bounty capping, and residual settlement planning are now computed in one place.
- Updated `src/perps/CfdEngine.sol` so both `previewLiquidation()` and live liquidation call the same liquidation accounting builder, reducing preview/live drift and making the domain boundary explicit.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewLiquidation_ReturnsBountyAndLiquidatableFlag|LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold|Liquidation_PreservesReservedSettlementEscrow|LiquidationBounty_CappedByPositiveEquity"` and `forge test --match-path test/perps/AuditCurrentFindingsVerification.t.sol --match-test "M2_KeeperBountyShouldUsePositiveEquityNotPositionMargin"`.

- [x] Inspect oracle freeze / market-closed logic duplicated in `src/perps/CfdEngine.sol` and `src/perps/OrderRouter.sol`
- [x] Extract a shared calendar/freeze helper that preserves the current Sunday freeze and oracle-freeze semantics exactly
- [x] Route engine and router call sites through the shared helper without changing behavior
- [x] Add/update targeted tests that assert router and engine agree on market-open / market-closed boundaries
- [x] Run focused Forge verification for the refactor slice

Review:
- Goal: remove the remaining router/engine drift risk around calendar-closed execution by moving both modules onto one shared helper while keeping semantics identical.
- Success criteria: market-open and market-closed boundary behavior stays unchanged, and both contracts derive those answers from the same implementation.
- Added `src/perps/libraries/MarketCalendarLib.sol` so the weekend/FAD/oracle-freeze calendar boundaries now live in one pure helper instead of being re-encoded across modules.
- Updated `src/perps/CfdEngine.sol` and `src/perps/OrderRouter.sol` to consume that shared helper for FAD and oracle-frozen answers without changing the live Sunday boundary behavior.
- Added `test_MarketCalendar_SundayBoundariesMatchLiveSemantics` in `test/perps/CfdEngine.t.sol` and revalidated the existing Sunday router/liquidation boundary tests.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "MarketCalendar_SundayBoundariesMatchLiveSemantics|GetHousePoolInputSnapshot_UsesFrozenOracleFreshnessLimit"`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "SundayDst_OracleUnfrozenAt21|SundayDst_MevEnforcedAt21|SundayDst_StillFadAt21|SundayDst_WinterStalenessRejects"`, and `forge test --match-path test/perps/Liquidation.t.sol --match-test "testIsFadWindow_Weekend"`.

- [ ] Extract one shared post-funding close-settlement planner that both `previewClose()` and live close execution use
- [ ] Make the shared planner simulate funding settlement first, including vault cash outflow / clearinghouse margin-credit effects for positive funding and uncovered-funding handling for negative funding
- [ ] Rebuild clearinghouse bucket snapshots from the simulated post-funding state for partial closes instead of mutating only `otherLockedMarginUsdc`
- [ ] Route both preview and live close loss planning through the rebuilt bucket snapshot so committed-order reservations are excluded consistently and `IncompleteReservationCoverage` cannot appear after a valid preview
- [ ] Align preview post-close solvency modeling with live execution by rolling the remaining side exposure onto the preview funding index exactly as `_settleFunding()` does before size reduction finalization
- [ ] Include simulated funding payout cash movement in preview solvency deltas so `valid`, `badDebtUsdc`, `effectiveAssetsAfterUsdc`, `triggersDegradedMode`, and `postOpDegradedMode` match live execution for positive-funding partial closes
- [ ] Add focused regression tests in `test/perps/CfdEngine.t.sol` for: partial close with committed margin excluded, accrued-funding partial close parity, positive-funding vault cash outflow parity, and preview-invalid/live-revert agreement
- [ ] Extend `test/perps/PreviewExecutionDifferential.t.sol` with partial-close cases that compare preview outputs against live execution across negative funding, positive funding, and queued committed-margin scenarios
- [ ] Strengthen `test/perps/invariant/PerpPreviewInvariant.t.sol` so partial closes preserve preview/live parity for validity, bad debt, degraded-mode transitions, and reachable collateral accounting under funding accrual
- [ ] Update `src/perps/ACCOUNTING_SPEC.md` Unrealized MtM Liability wording to include the collectible side-margin cap before the per-side zero clamp
- [ ] Update `src/perps/SECURITY.md` MtM rationale so it matches the current capped-negative-funding code path and no longer describes aggregate-side-margin capping as rejected when that is what the code now does
- [ ] Re-run targeted verification: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_|CloseLoss_|Funding"`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`, `forge test --match-path test/perps/invariant/PerpPreviewInvariant.t.sol`, and any affected audit regression slices

Review:
- Goal: eliminate the last known partial-close preview/live divergence by making preview and execution consume the same post-funding close-settlement model, then align the docs that still describe the pre-cap MtM semantics.
- Success criteria: a partial close that previews valid must not fail live because committed reservations were implicitly needed, and previewed solvency/degraded-mode outputs must match live execution after funding accrual on both positive- and negative-funding paths.

- [x] Inspect `OrderRouter` committed-margin lifecycle and identify every counter-dependent path
- [x] Draft a concrete patch plan for single-source committed margins plus an account-local pending-order queue

Review:
- `src/perps/OrderRouter.sol` currently has a transitional mix: `noteCommittedMarginConsumed()` already decrements per-order `committedMargins`, but `getAccountEscrow()`, `_unlockCommittedMargin()`, and `_releaseCommittedMarginForExecution()` still reconcile against `consumedCommittedMarginUsdc`.
- The next patch should finish that refactor by removing the account-level consumed counter, adding account-local pending-order pointers, linking/unlinking orders in `commitOrder()` / `_deleteOrder()`, and making all release paths consume only the residual stored in `committedMargins[orderId]`.

- [x] Update tests and invariants for single-source committed margin accounting
- [x] Run targeted forge tests for OrderRouter, CfdEngine, and invariants
- [x] Review failures and finalize follow-up changes

Review:
- Updated `test/perps/PerpInvariant.t.sol` so queued committed-margin conservation now compares `getAccountEscrow(accountId).committedMarginUsdc` directly against the residual per-order sum instead of referencing the removed `consumedCommittedMarginUsdc` getter.
- Verified green after the `OrderRouter` refactor: `forge test --match-path test/perps/OrderRouter.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "CloseLoss_ConsumesQueuedCommittedMarginBeforeBadDebt"`, and `forge test --match-path test/perps/PerpInvariant.t.sol`.

- [x] Add dedicated OrderRouter tests for account queue pointers and unlink edge cases
- [x] Run targeted OrderRouter tests for new queue coverage
- [x] Draft formal invariants and a commit message for the refactor

Review:
- Added four focused queue-structure regressions in `test/perps/OrderRouter.t.sol` covering per-account FIFO pointer isolation, middle unlink on cancel, tail unlink on cancel, and head unlink on execution with foreign-account orders interleaved.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "PendingOrderPointers_|CancelOrder_Unlinks|ExecuteOrder_UnlinksAccountHeadWithoutAffectingForeignQueuePointers"` and a full `forge test --match-path test/perps/OrderRouter.t.sol` run (105 passed).

- [x] Identify withdrawal/solvency snapshot logic shared between `CfdEngine` and `HousePool`
- [x] Extract a dedicated accounting library for perps reserve/solvency views
- [x] Wire engine/pool callsites to the new library without behavior changes
- [x] Run targeted reserve/solvency tests and record results

Review:
- Added `src/perps/libraries/CfdEngineReserveAccountingLib.sol` so deferred trader payouts, deferred liquidation bounties, withdrawal reserve construction, and pending vault-payout solvency adjustments now run through one shared reserve/solvency kernel instead of inline arithmetic in `src/perps/CfdEngine.sol`.
- Updated `src/perps/CfdEngine.sol` to use the new reserve-accounting library for `getWithdrawalReservedUsdc()`, adjusted solvency snapshots, and degraded-mode pending payout handling.
- Verified green: `forge test --match-path test/perps/ArchitectureRegression.t.sol --match-test "WithdrawFees_MustHonorDeferredKeeperLiabilities|Reconcile_MustSubtractDeferredLiquidationBounties"`, `forge test --match-path test/perps/HousePool.t.sol --match-test "M12_GetFreeUSDC_ReservesFees|GetVaultLiquidityView_ReturnsCurrentPoolState"`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "GetProtocolAccountingView|GetDeferredPayoutStatus_ReflectsClaimability"`.

- [x] Identify repeated order-escrow aggregation logic in `OrderRouter` for extraction
- [x] Add `OrderEscrowAccounting` library for queued order summaries/views
- [x] Wire `OrderRouter` escrow view/summary paths to the new library without behavior changes
- [x] Run targeted order-router escrow tests and record results

Review:
- Added `src/perps/libraries/OrderEscrowAccountingLib.sol` so queued-order escrow aggregation now has an explicit domain helper for account matching, escrow totals, summary totals, and pending-order view construction.
- Updated `src/perps/OrderRouter.sol` to route `getAccountEscrow()`, `getAccountOrderSummary()`, and `getPendingOrdersForAccount()` through the shared order-escrow accounting helper instead of repeating hand-rolled queue aggregation logic in three separate paths.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "AccountEscrowView_TracksPendingOrders|GetAccountOrderSummary_ReturnsAggregateOrderState|GetPendingOrdersForAccount_ReturnsQueuedOrderDetails|CloseCommit_RequiresFlatKeeperBountyReserve"` and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "BatchExecution_AllSucceed|BatchExecution_MixedResults"`.

- [x] Design explicit queued-order cancel semantics that preserve FIFO safety and escrow correctness
- [x] Implement cancel path in `OrderRouter` for eligible pending orders
- [x] Add tests for cancel authorization, escrow refunds, and head-order restrictions
- [x] Run targeted OrderRouter tests and broader verification if needed

Review:
- Added explicit queued-order cancellation to `src/perps/OrderRouter.sol` via `cancelOrder(uint64 orderId)`. Order owners can now cancel any still-pending order, including the FIFO head, with committed margin and reserved execution bounty escrow released immediately.
- Cancellation preserves FIFO safety by only advancing `nextExecuteId` when the cancelled order is the current head; cancelling a later order leaves a hole that existing queue scans already skip safely.
- Added focused coverage in `test/perps/OrderRouter.t.sol` for owner-only cancellation, non-pending revert, head cancellation advancing the queue, and non-head cancellation releasing escrow without disturbing the head.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "CancelOrder_|AccountEscrowView_TracksPendingOrders|GetAccountOrderSummary_ReturnsAggregateOrderState|GetPendingOrdersForAccount_ReturnsQueuedOrderDetails|BatchExecution_AllSucceed|BatchExecution_MixedResults|UnbrickableQueue_OnEngineRevert|MultiPendingOrders_DoNotCorruptLockedMarginOnFail|DeferredPayout_CloseDoesNotBlockLaterQueuedOrders"`.

- [x] Identify close-preview and close-execution math to extract into one shared kernel
- [x] Add a close accounting library/shared settlement builder
- [x] Wire `previewClose()` and live close execution to the shared kernel without changing behavior
- [x] Run targeted close/deferred payout regressions and record results

Review:
- Added `src/perps/libraries/CloseAccountingLib.sol` so close-path realized PnL, released margin, max-profit reduction, proportional VPI accrual, clamped VPI delta, execution fee, and net settlement are now computed in one canonical kernel.
- Updated `src/perps/CfdEngine.sol` so both `_processDecrease()` and `previewClose()` use the same close accounting builder. This removes the remaining preview/live drift on proportional `vpiAccrued` rebate capping and centralizes the core close math.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_ReturnsDeferredAndImmediateSettlementBreakdown|PreviewClose_NegativeVpiDoesNotPanic|ProfitableClose_RecordsDeferredPayoutWhenVaultIlliquid|C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable|OpenTradeCostCannotSeizeReservedSettlementEscrow"` and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "C1_FullCloseMustNotTreatQueuedCommittedMarginAsLossShield|H1_LiquidationMustPreserveQueuedCollateralBuckets"`.

- [x] Design bucket-aware margin-credit and open-cost primitives in `MarginClearinghouse`
- [x] Implement clearinghouse primitives and route `_settleFunding()` positive path through them
- [x] Route `_processIncrease()` through the new bucket-aware primitive set
- [x] Add/update regressions for positive funding credits and open-cost application
- [x] Run targeted tests and record results

Review:
- Added bucket-aware clearinghouse primitives in `src/perps/MarginClearinghouse.sol` and `src/perps/interfaces/IMarginClearinghouse.sol`: `creditSettlementAndLockMargin(...)` for positive funding credits and `applyOpenCost(...)` for open/increase trade-cost settlement plus lock/unlock updates.
- Updated `src/perps/CfdEngine.sol` so `_settleFunding()` positive funding credits and `_processIncrease()` now route through those clearinghouse primitives instead of hand-rolled settlement + lock/unlock sequences.
- Added direct primitive regressions in `test/perps/MarginClearinghouse.t.sol` and revalidated the existing engine-level funding/open-cost behavior in `test/perps/CfdEngine.t.sol`.
- Verified green: `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "CreditSettlementAndLockMargin_CreditsAndLocksSameBucket|ApplyOpenCost_PreservesReservedSettlementOnDebit|ConsumeCloseLoss_PreservesProtectedBuckets|ConsumeFundingLoss_PreservesOtherLockedAndReservedBuckets"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "FundingSettlement_SyncsClearinghouse|OpenTradeCostCannotSeizeReservedSettlementEscrow|MarginDrained_ByFees_Reverts|WithdrawFees"`.

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

- [x] Re-verify the latest external audit claims against current perps code and tests

Review:
- Re-verified the latest 5 reported findings against current `src/perps` code and targeted Forge runs.
- Confirmed stale/fixed: `_cleanupOrder` already advances the queue head again, and close-loss settlement no longer routes through `seizeAsset()`.
- Confirmed intentional-by-spec behavior: liquidation and funding reachability still preserve queued committed margin while protecting reserved execution-bounty escrow, and the focused coverage in `test/perps/AuditRemainingCoverageFindingsFailing.t.sol` passes.
- Confirmed one still-live issue: `src/perps/MarginClearinghouse.sol` `_lockMargin()` still omits `reservedSettlementUsdc[accountId]` from its physical-USDC backing check, so the reviewer's double-encumbrance claim remains valid.
- Confirmed intentional UX tradeoff: close commits still require the flat reserved bounty up front, and `test_CloseCommit_RequiresFlatKeeperBountyReserve` passes.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_UnbrickableQueue_OnEngineRevert|test_CancelOrder_HeadAdvancesNextExecuteId|test_CloseCommit_RequiresFlatKeeperBountyReserve"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_CloseLoss_DoesNotConsumeQueuedCommittedMargin|test_OpenTradeCostCannotSeizeReservedSettlementEscrow|test_C5_CloseSucceeds_WhenFundingExceedsMargin_ButPositionProfitable|test_Liquidation_PreservesReservedSettlementEscrow"`, `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "test_LockMargin_RequiresPhysicalUsdcBacking_WhenBuyingPowerComesFromOtherCollateral|test_LockMargin_AcceptsNonUsdcEquity|test_ConsumeCloseLoss_PreservesProtectedBuckets"`, and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "test_H1_LiquidationMustPreserveQueuedCollateralBuckets|test_C1_FullCloseMustPreserveQueuedCommittedMarginBuckets"`.

- [x] Extract first-class solvency and withdrawal accounting modules and reroute engine views through them

Review:
- Added `src/perps/libraries/SolvencyAccountingLib.sol` to own protocol-level solvency state construction, effective-asset math, max-liability selection, and degraded-mode pending-payout adjustments.
- Added `src/perps/libraries/WithdrawalAccountingLib.sol` to own withdrawal reserve construction, including protocol fees, funding liabilities, and deferred payout liabilities.
- Updated `src/perps/CfdEngine.sol` to route `getProtocolAccountingView()`, `_getWithdrawalReservedUsdc()`, `_assertPostSolvency()`, degraded-mode latching, and max-liability-after-close calculations through those first-class accounting modules instead of inline arithmetic.
- Preserved the legacy `CfdEngineSnapshotsLib.SolvencySnapshot` return shape for compatibility by rebuilding it from the new solvency state at the boundary.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_GetProtocolAccountingView_ReflectsDeferredLiabilities|test_DegradedMode_ClearRequiresRecapitalization|test_DegradedMode_LatchesAndBlocksNewOpens|test_H9_SolvencyDeadlock_CloseAllowedDuringInsolvency"`, `forge test --match-path test/perps/HousePool.t.sol --match-test "test_M12_GetFreeUSDC_ReservesFees|test_GetVaultLiquidityView_ReturnsCurrentPoolState"`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_ProtocolAccountingViewMatchesAccessors|invariant_WithdrawalReserveIncludesDeferredLiabilities|invariant_PoolLiquidityViewMatchesProtocolAccounting"`.

- [x] Split perps keeper reserves out of trader collateral and route user-cancelled reserves to protocol revenue

Review:
- `src/perps/OrderRouter.sol` now seizes keeper execution reserves out of trader collateral at commit time into router custody instead of using `reservedSettlementUsdc` inside `MarginClearinghouse`.
- Successful/failed execution now pays the router-custodied reserve directly to the executor, while `cancelOrder()` refunds only committed margin and routes the forfeited keeper reserve into protocol revenue via `CfdEngine.absorbRouterCancellationFee()`.
- `src/perps/CfdEngine.sol` now absorbs router cancellation fees into the vault and books them in `accumulatedFeesUsdc`, preserving protocol-fee accounting and fee withdrawals.
- `src/perps/ACCOUNTING_SPEC.md` now explicitly states that keeper execution reserve is non-trader-owned once committed and that user-cancelled reserves route to protocol revenue instead of back to the trader.
- Updated queue/invariant regressions in `test/perps/OrderRouter.t.sol`, `test/perps/AuditRemainingCoverageFindingsFailing.t.sol`, and `test/perps/PerpInvariant.t.sol` to reflect router custody rather than `clearinghouse.reservedSettlementUsdc`.
- Verified green: targeted router/audit/invariant runs plus full `forge test --match-path "test/perps/*.t.sol"` with `449 tests passed, 0 failed, 0 skipped`.

- [x] Extract shared position-risk and funding accounting across view/preview/live paths

Review:
- Added `src/perps/libraries/PositionRiskAccountingLib.sol` as the shared kernel for pending-funding calculation, projected funding accrual, equity, maintenance margin, current notional, and liquidatable-state derivation.
- Updated `src/perps/CfdEngine.sol` so `checkWithdraw()`, `getPendingFunding()`, `getPositionView()`, `previewLiquidation()`, and live liquidation all route through the shared position-risk/funding library instead of recomputing those answers inline.
- Reused the same projected funding helper for liquidation preview and close-preview funding simulation, reducing preview/live drift in funding accrual logic.
- Preserved existing close/liquidation settlement libraries; this refactor only centralized the duplicated funding and position-risk math that fed those paths.
- Verified green: targeted risk/funding parity runs and full `forge test --match-path "test/perps/*.t.sol"` with `449 tests passed, 0 failed, 0 skipped`.

- [x] Extract open-position accounting into a first-class module

Review:
- Added `src/perps/libraries/OpenAccountingLib.sol` to centralize open-path entry-price averaging, added max-profit liability, post-trade skew/VPI cost, execution fee, trade cost, and initial-margin requirement construction.
- Updated `src/perps/CfdEngine.sol` so `_processIncrease()` now consumes the shared open-accounting state instead of re-embedding the full open-trade math inline.
- Preserved original revert precedence by continuing to check vault solvency before skew-cap enforcement while still computing VPI and skew against the true post-trade open interest.
- Verified green: targeted open-path/audit regressions plus full `forge test --match-path "test/perps/*.t.sol"` with `449 tests passed, 0 failed, 0 skipped`.

- [x] Unify close preview/live around shared terminal-settlement planning

Review:
- Added shared terminal close-settlement planning in `src/perps/libraries/CfdEngineSettlementLib.sol` using `MarginClearinghouseAccountingLib.planTerminalLossConsumption(...)` so preview and live close-loss handling derive seized collateral, shortfall, fee collection, and bad debt from the same kernel.
- Updated `src/perps/CfdEngine.sol` so live `_settleCloseNetSettlement()` and `previewClose()` both use the shared close-loss planner, with preview explicitly modeling the post-unlock bucket state before terminal loss collection.
- Kept the existing close accounting kernel in `CloseAccountingLib`; this change specifically removes the remaining divergence in terminal settlement planning after close accounting has already produced `netSettlementUsdc`.
- Added preview/live parity coverage in `test/perps/CfdEngine.t.sol`, including a new regression asserting preview bad debt matches live full-close settlement.
- Verified green: targeted close regressions plus full `forge test --match-path "test/perps/*.t.sol"` with `450 tests passed, 0 failed, 0 skipped`.

- [x] Extract HousePool waterfall accounting into a first-class module

Review:
- Added `src/perps/libraries/HousePoolWaterfallAccountingLib.sol` to own senior-yield accrual, reconcile planning, senior-withdraw scaling, revenue distribution, and loss absorption.
- Updated `src/perps/HousePool.sol` so `_reconcile()`, `_accrueSeniorYieldOnly()`, `withdrawSenior()`, `_distributeRevenue()`, and `_absorbLoss()` now route through the shared waterfall library instead of embedding the waterfall math inline.
- Kept `HousePoolAccountingLib` focused on withdrawal/reconcile snapshots and mark freshness while moving tranche waterfall policy into the new dedicated domain library.
- Existing HousePool and invariant coverage was sufficient to validate the refactor; no new test logic was needed beyond the existing waterfall/HWM/reconcile regressions.
- Verified green: targeted HousePool/invariant runs plus full `forge test --match-path "test/perps/*.t.sol"` with `450 tests passed, 0 failed, 0 skipped`.

- [x] Fix blocker accounting bugs in partial-close terminal settlement and in-flight solvency timing

Review:
- Fixed partial-close terminal loss planning in `src/perps/libraries/MarginClearinghouseAccountingLib.sol` so protected residual active margin is excluded from both reachability and consumption attribution, and terminal loss mutation now applies exactly the planned active/other locked consumption without recomputation.
- Added `consumedCommittedMarginUsdc` accounting in `src/perps/OrderRouter.sol` so terminally-consumed queued committed margin is charged against later cancel refunds instead of unlocking below the surviving protected position margin.
- Fixed in-flight solvency timing in `src/perps/CfdEngine.sol` by synchronizing `totalBullMargin` / `totalBearMargin` immediately after funding settlement and again after the main open/close mutation, so solvency and degraded-mode checks no longer read stale side-margin mirrors.
- Added focused blocker coverage in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol`; the new H-01/H-02 tests now pass.
- Verified green: targeted blocker/engine/router/invariant runs plus full `forge test --match-path "test/perps/*.t.sol"` with `465 tests passed, 0 failed, 0 skipped`.

- [x] Extract a clearinghouse bucket mutation layer

Review:
- Extended `src/perps/libraries/MarginClearinghouseAccountingLib.sol` with shared bucket-mutation outputs for funding loss, terminal close loss, and liquidation residual application, so planning and storage-application now live in the same accounting domain.
- Updated `src/perps/MarginClearinghouse.sol` so `consumeFundingLoss()`, `consumeCloseLoss()`, and `consumeLiquidationResidual()` all apply bucket updates, settlement debits, and unlock semantics through the shared mutation layer instead of hand-writing each mutation path inline.
- Preserved existing behavior and event semantics while reducing the remaining planning-vs-application drift surface in the clearinghouse.
- Verified green: targeted clearinghouse/engine/invariant runs plus full `forge test --match-path "test/perps/*.t.sol"` with `451 tests passed, 0 failed, 0 skipped`.

- [x] Fix remaining audit issues in router bounty custody, cancellation binding, and batch gas handling

Review:
- Updated `src/perps/OrderRouter.sol` so failed order execution bounties are now forfeited to protocol revenue instead of paid to arbitrary executors, eliminating stale-order reclaimability for router-custodied keeper reserves.
- Made open orders economically binding by rejecting `cancelOrder()` for non-close orders, while keeping close-order cancellation semantics intact.
- Changed `executeOrderBatch()` to `break` rather than revert when the per-order gas floor is no longer met, so completed batch work persists.
- Added/updated regression coverage in `test/perps/OrderRouter.t.sol`, `test/perps/AuditConfirmedFindingsFailing.t.sol`, and `test/perps/AuditV3.t.sol` for failed-order bounty forfeiture, open-order cancellation binding, and mixed batch payout semantics.
- Verified green: focused router/invariant/blocker runs plus full `forge test --match-path "test/perps/*.t.sol"` with `470 tests passed, 0 failed, 0 skipped`.

- [x] Scan `src/perps` for duplicated code patterns
- [x] Inspect the strongest duplication candidates and classify intentional vs risky repetition
- [x] Report the highest-value refactor opportunities with file references

Review:
- Scanned `src/perps` with a normalized repeated-window pass plus function-similarity checks, then manually reviewed the strongest clusters.
- Highest-risk duplication remains preview/live business logic that still repeats around liquidation and close flows in `src/perps/CfdEngine.sol`.
- Cross-contract duplication exists in timelocked admin proposal flows and oracle-freeze calendar logic shared between `src/perps/CfdEngine.sol` and `src/perps/OrderRouter.sol`; these are good cleanup targets but lower urgency than the trading-path logic.
- Tranche senior/junior branching in `src/perps/HousePool.sol` and `src/perps/TrancheVault.sol` is mostly intentional and only worth light deduplication.

- [x] Refactor liquidation preview/live into one shared transition planner in `src/perps/CfdEngine.sol`
- [ ] Refactor close preview/live post-settlement and solvency wiring into a shared planner or builder
- [ ] Centralize oracle freeze / market-closed calendar logic shared by `CfdEngine` and `OrderRouter`
- [ ] Evaluate local deduplication of `OrderRouter` queue unlink helpers without obscuring invariants
- [ ] Leave tranche senior/junior branching mostly explicit unless a tiny helper clearly improves readability
- [ ] After each refactor slice, run the narrowest affected Forge suites plus a final `test/perps/*.t.sol` pass

Review:
- Priority order is safety-first: preview/live parity before governance or cosmetic deduplication.
- `CfdEngine` liquidation parity is the best first target because it duplicates critical solvency and payout logic across view and live paths.
- Close-path dedup is next, but only if the shared abstraction stays domain-shaped and does not hide accounting transitions.
- Oracle calendar centralization is a medium-risk consistency cleanup with good payoff because router/engine disagreement would change execution semantics.
- Timelock admin flow dedup is intentionally deferred because the payoff is lower and typed proposal state makes over-abstraction easy.
Review:
- Added `LiquidationComputation` plus `_buildLiquidationComputation(...)` in `src/perps/CfdEngine.sol` so liquidation preview and live execution now share the same reachable-collateral, risk-state, bounty, and settlement planning kernel.
- `previewLiquidation()` and `_liquidatePosition()` now consume that shared computation instead of rebuilding the liquidation math inline.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewLiquidation_ReturnsBountyAndLiquidatableFlag|LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold|Liquidation_PreservesReservedSettlementEscrow|LiquidationBounty_CappedByPositiveEquity"` and `forge test --match-path "test/perps/*.t.sol"` (`484 passed, 0 failed`).

- [x] Scan `src/perps` for dead code candidates (unused internal/private funcs, structs, vars, branches)
- [x] Verify each candidate manually to avoid false positives from tests/interfaces/inheritance
- [x] Report safe removals vs intentionally retained code with file references

Review:
- Dead code in `src/perps` is limited; the strongest candidates are orphaned helpers/types rather than unreachable branches.
- High-confidence safe removals are `CfdEngineSnapshotsLib.buildSolvencySnapshot`, `CfdEngine._seizeUsdcToVault`, and the duplicate `MarginClearinghouse.SettlementConsumption` struct.
- Several low-reference symbols in `TrancheVault` are not dead code because OpenZeppelin `ERC4626` reaches them through overrides.
Review:
- Removed three high-confidence dead-code items: `CfdEngine._seizeUsdcToVault`, the duplicate `MarginClearinghouse.SettlementConsumption` struct, and the orphaned `CfdEngineSnapshotsLib.buildSolvencySnapshot` helper.
- Verified green with `forge test --match-path test/perps/CfdEngine.t.sol` and `forge test --match-path test/perps/MarginClearinghouse.t.sol` (`110 passed, 0 failed`).
- Current net LOC across the cleanup files is `-18` (`101 added, 119 removed`), with the dead-code deletion slice itself contributing the reduction.

- [x] Make queued close orders binding instead of user-cancellable
- [x] Update router tests and docs for binding close-order semantics
- [x] Run targeted Forge verification for cancel-path regressions

Review:
- Updated `src/perps/OrderRouter.sol` so `cancelOrder()` now always reverts with `OrderRouter__OrdersAreBinding()` after ownership/pending checks, making close orders binding just like opens.
- Rewrote the affected cancel-path tests in `test/perps/OrderRouter.t.sol` to assert that close-order cancellation attempts revert without mutating queue pointers, escrow, or FIFO head state; updated the audit regression in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` to the renamed binding error.
- Documented the new binding-intent policy in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md`.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CancelOrder_CloseOrdersAreBinding|test_CancelOrder_MiddleCloseRevertsAndPreservesAccountHeadTail|test_CancelOrder_TailCloseRevertsAndPreservesAccountTail|test_CancelOrder_NonHeadCloseRevertsWithoutChangingEscrow|test_CancelOrder_HeadCloseRevertsWithoutAdvancingNextExecuteId|test_CancelOrder_OnlyOwnerCanCancel|test_CancelOrder_OpenOrdersAreBinding|test_CancelOrder_NonPendingReverts"` and `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test test_H1_PhaseBoundary_PartialCloseThenCancelMustNotUnlockProtectedResidualMargin`.

- [x] Inspect preview solvency structs and call sites for degraded-mode reporting semantics
- [x] Implement a clearer post-operation degraded-state signal for integrators
- [x] Update tests/docs and run targeted preview verification

Review:
- Extended `ClosePreview`, `LiquidationPreview`, and `ICfdEngine.LiquidationPreview` to expose `postOpDegradedMode`, `effectiveAssetsAfterUsdc`, and `maxLiabilityAfterUsdc` alongside the existing transition-only `triggersDegradedMode` flag.
- Updated `SolvencyAccountingLib.previewPostOpSolvency()` to compute both the raw post-op degraded state and the existing latch-transition flag so integrators can distinguish "would still be degraded" from "newly triggers degraded mode."
- Added unit/invariant coverage in `test/perps/CfdEngine.t.sol` and `test/perps/invariant/PerpPreviewInvariant.t.sol`, plus docs in `src/perps/README.md` and `src/perps/ACCOUNTING_SPEC.md`.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_PreviewClose_TriggersDegradedModeMatchesLiveClose|test_PreviewClose_RecomputesPostOpFundingClipForDegradedModeWithPendingAccrual|test_PreviewClose_ReportsPostOpDegradedStateAfterLatch|test_LiquidationPreview_InterfaceMatchesContractStructLayout|test_PreviewLiquidation_TriggersDegradedModeMatchesLiveLiquidation|test_PreviewLiquidation_RecomputesPostOpFundingClipForDegradedModeWithPendingAccrual"` and `forge test --match-path test/perps/invariant/PerpPreviewInvariant.t.sol`.

- [x] Clean stale USDC-only and bounty wording in IMarginClearinghouse, MarginClearinghouse, and SECURITY docs
- [x] Verify doc text is consistent with current code paths

Review:
- Updated `src/perps/interfaces/IMarginClearinghouse.sol` to describe the clearinghouse as USDC-only settlement accounting and removed the stale LTV-haircut wording from `getAccountEquityUsdc()`.
- Updated `src/perps/MarginClearinghouse.sol` bucket-view Natspec to describe the current USDC-only model instead of referencing non-USDC collateral.
- Corrected the stale FIFO execution line in `src/perps/SECURITY.md` so close orders are described as zero-escrow-at-commit and vault-funded only on the documented close clearer path.
- Verified the targeted stale phrases are gone; the remaining `non-USDC collateral` mention in `src/perps/SECURITY.md` is intentional historical context for a "not applicable in V1" note, not a live behavior description.

- [x] Refactor close-order bounty flow to reserve router escrow at commit and remove vault-funded close bounty settlement path
- [x] Update router/engine interfaces, docs, and tests for symmetric open/close escrow payout behavior
- [x] Run targeted Foundry tests covering close execution, expiry, invalid closes, and liquidation interactions

Review:
- Updated `src/perps/OrderRouter.sol` so close orders now reserve the flat close bounty at commit, all successful/failed/expired orders pay clearers from router-held escrow, and liquidation restores every queued order bounty back into the clearinghouse before terminal cleanup.
- Removed the now-obsolete `settleCloseOrderExecutionBounty()` engine path from `src/perps/CfdEngine.sol` and `src/perps/interfaces/ICfdEngine.sol`, leaving deferred clearer claims as liquidation-only vault liabilities.
- Updated docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md`, plus regression coverage in `test/perps/OrderRouter.t.sol`, `test/perps/AuditRemainingCoverageFindingsFailing.t.sol`, `test/perps/AuditRemainingFindingsFailing.t.sol`, and `test/perps/AuditLatestFindingsFailing.t.sol`.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CloseCommit_ReservesPrefundedKeeperBounty|test_ExitedAccount_ExpiredCloseOrderPaysClearerBounty|test_ExitedAccount_InvalidCloseOrderPaysEscrowedBounty|test_CloseCommit_RevertsWhenPendingCloseSizeWouldExceedPosition|test_CancelOrder_CloseOrdersAreBinding|test_ExecuteLiquidation_RestoresEscrowedOpenBountiesBeforeBadDebt|test_ExecuteLiquidation_RestoresEscrowedCloseBountiesBeforeClearingOrders|test_ExecuteLiquidation_PreventsPostLiquidationEscrowRecovery"`, `forge test --match-path test/perps/AuditRemainingFindingsFailing.t.sol --match-test test_M1_ExecutionFeesAreProtocolRevenue`, `forge test --match-path test/perps/AuditLatestFindingsFailing.t.sol --match-test test_M1_ExecutionFeesAccrueToProtocolNotLpEquity`, and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "test_M2_CloseCommitRequiresPrefundedKeeperBounty|test_H5_CloseKeeperRewardMustDeferInsteadOfRevertingOnCashShortage"`.

- [x] Add a hard MAX_PENDING_ORDERS cap to OrderRouter commit flow
- [x] Update tests and docs for the new per-account pending order limit
- [x] Run targeted Foundry tests for queue-cap and liquidation interactions

Review:
- Added `MAX_PENDING_ORDERS = 5` and `OrderRouter__TooManyPendingOrders()` to `src/perps/OrderRouter.sol`, enforcing the cap before any new order commit reserves escrow.
- Updated queue-related docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` to describe the bounded per-account queue model.
- Reworked the queue-stress regressions in `test/perps/OrderRouter.t.sol` and `test/perps/AuditRemainingCoverageFindingsFailing.t.sol` around the new bounded model, and added an explicit cap-revert test.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitOrder_RevertsWhenPendingOrderCountHitsCap|test_BoundedForeignQueue_FullCloseExecutesAndLeavesTailLive|test_ExecuteLiquidation_RestoresEscrowedOpenBountiesBeforeBadDebt|test_ExecuteLiquidation_RestoresEscrowedCloseBountiesBeforeClearingOrders"` and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test test_M3_TerminalCloseMustRemainExecutableUnderBoundedForeignQueue`.

- [x] Freeze deferred-claim servicing whenever physical cash falls below aggregate deferred liabilities
- [x] Update deferred-claim unit/integration/regression tests for explicit freeze semantics
- [x] Run targeted Forge verification for deferred-claim behavior after the freeze change

Review:
- Updated `src/perps/libraries/CashPriorityLib.sol` so `reserveDeferredClaim(...)` now freezes all deferred-claim servicing whenever `physicalAssetsUsdc < totalDeferredClaimsUsdc`. Under aggregate deferred shortfall the library returns zero claimable cash, and `CfdEngine` continues to surface that as `CfdEngine__InsufficientVaultLiquidity`.
- Reworked deferred-claim coverage in `test/perps/CashPriorityLib.t.sol`, `test/perps/DeferredClaimsMatrix.t.sol`, `test/perps/CfdEngine.t.sol`, and `test/perps/ArchitectureRegression.t.sol` to assert the new all-claimants freeze semantics instead of partial claimant-vs-claimant servicing.
- Clarified the policy in `src/perps/ACCOUNTING_SPEC.md`: deferred claims remain senior to fees, but servicing is fully frozen while aggregate deferred liabilities exceed physical vault cash.
- Verified green with `forge test --match-path test/perps/CashPriorityLib.t.sol`, `forge test --match-path test/perps/DeferredClaimsMatrix.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClaimDeferredTraderCredit_RevertsUntilDeferredLiabilitiesAreFullyCovered|test_ClaimDeferredTraderCredit_RevertsDuringAggregateShortfallEvenForLargestClaimant|test_WithdrawFees_ThenDeferredClaims_DrainsResidualCashWithoutDeadlock"`, `forge test --match-path test/perps/ArchitectureRegression.t.sol --match-test "test_DeferredClaims_FreezeForAllClaimantsDuringAggregateShortfall"`, and `forge test --match-path test/perps/invariant/PerpDeferredCreditInvariant.t.sol --match-test "invariant_DeferredCreditStatusMatchesEngineAndVaultLiquidity"`.

- [x] Make deferred claims strictly senior to protocol fee withdrawals in `CashPriorityLib`
- [x] Update focused deferred-claim tests and invariant expectations for the new priority order
- [x] Run targeted Forge verification for cash-priority and deferred-claim suites

Review:
- Updated `src/perps/libraries/CashPriorityLib.sol` so deferred-claim servicing now subtracts only other deferred liabilities, not protocol fees. Fee withdrawals still only use cash above the full deferred-liability reserve, which removes the circular shortfall deadlock and makes deferred claims strictly senior when cash is scarce.
- Rewrote the focused library and engine matrix tests in `test/perps/CashPriorityLib.t.sol` and `test/perps/DeferredClaimsMatrix.t.sol` to assert the new policy, including the deadlock repro shape where residual cash must now drain to deferred claims rather than getting stranded behind fee accounting.
- Updated `test/perps/invariant/PerpDeferredCreditInvariant.t.sol` so claimability is derived from `CashPriorityLib.availableCashForDeferredBeneficiaryClaim(...)` instead of the old `any vault cash` heuristic, keeping the invariant aligned with the actual reservation model.
- Clarified the normative priority rule in `src/perps/ACCOUNTING_SPEC.md`: deferred claim servicing outranks protocol fee withdrawals during cash shortfalls.
- Verified green with `forge test --match-path test/perps/CashPriorityLib.t.sol`, `forge test --match-path test/perps/DeferredClaimsMatrix.t.sol`, and `forge test --match-path test/perps/invariant/PerpDeferredCreditInvariant.t.sol --match-test "invariant_DeferredCreditStatusMatchesEngineAndVaultLiquidity"`.

- [x] Add end-to-end `CfdEngine` regression for the `100/60/60 -> 20/20/20` cash-shortfall sequence

Review:
- Added `test_WithdrawFees_ThenDeferredClaims_DrainsResidualCashWithoutDeadlock()` to `test/perps/CfdEngine.t.sol`. The test seeds `100e6` vault cash, `60e6` accumulated fees, `40e6` deferred trader credit, and `20e6` deferred keeper credit, then performs a real `engine.withdrawFees(treasury, 40e6)` followed by trader and keeper deferred-claim calls.
- The regression now proves the protocol reaches the exact intermediate `20e6 assets / 20e6 fees / 20e6 deferred keeper credit` state after the fee withdrawal and trader claim, and that the final keeper claim can still drain the last `20e6` instead of deadlocking at zero claimable cash.
- Verified green with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_WithdrawFees_ThenDeferredClaims_DrainsResidualCashWithoutDeadlock|test_WithdrawFees_RespectsSeniorCashReservation|test_ClaimDeferredKeeperCredit_UsesFeeOnlyLiquidityWhenAtQueueHead"`.

- [x] Add failing H-01 test proving fallback ETH refunds are not actually funded in `OrderRouterAdmin`
- [x] Add failing H-02 test proving the open prefilter misses `executionFeeBps`-driven invalid opens
- [x] Run targeted Forge tests to confirm both repros fail on current code

Review:
- Added `test/perps/AuditExecutionPathFindingsFailing.t.sol` with two isolated repros. `test_H1_FallbackRefundMustFundRouterAdminClaimBalance()` drives the real `MockPyth` overpay refund path through a rejecting receiver and fails because `routerAdmin.claimableEth(receiver)` increases while `address(routerAdmin).balance` stays zero.
- Added `test_H2_CommitPrefilterMustRejectFeeDrainedOpen()`, which opens the exact-threshold margin case (`100_000e18` at `$1.00` with `1_500e6` margin) and fails because `engineLens.previewOpenRevertCode(...)` returns `OK` instead of `INSUFFICIENT_INITIAL_MARGIN`, proving the lens omitted `executionFeeBps`.
- Verified with `forge test --match-path test/perps/AuditExecutionPathFindingsFailing.t.sol`, which fails as intended on both tests.

- [x] Fund `OrderRouterAdmin` during fallback ETH refund crediting and enforce credited-value parity
- [x] Populate `executionFeeBps` in `CfdEngineLens` raw snapshots
- [x] Update the oracle refund invariant to track corrected admin-side ETH custody
- [x] Re-run focused Forge coverage for the fixed findings and adjacent refund/prefilter paths

Review:
- Updated `src/perps/OrderRouter.sol` so failed `_sendEth(...)` refunds now forward `value: amount` into `OrderRouterAdmin.creditClaimableEth(...)` instead of only incrementing accounting.
- Updated `src/perps/OrderRouterAdmin.sol` so `creditClaimableEth(...)` is `payable` and reverts on ETH/accounting mismatches via `OrderRouterAdmin__EthAmountMismatch()`.
- Updated `src/perps/CfdEngineLens.sol` so `_buildRawSnapshot(...)` now includes `snap.executionFeeBps = engineContract.executionFeeBps()` and commit-time preview/open planning uses the same execution fee as the live engine.
- Updated `test/perps/invariant/PerpOraclePathInvariant.t.sol` to assert stranded refund ETH is custodied by `OrderRouterAdmin`, and synced the suite's local `routerAdmin` handle after router deployment.
- Verified green with `forge test --match-path test/perps/AuditExecutionPathFindingsFailing.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitOrder_RevertsOnPredictableInsufficientInitialMargin|test_CommitOrder_RevertsOnPredictableMustCloseOpposing"`, and `forge test --match-path test/perps/invariant/PerpOraclePathInvariant.t.sol`.

- [x] Remove CfdEngine constructor-side sidecar deployments so initcode drops under EIP-3860
- [x] Rewire tests and local deployment paths to call `CfdEngine.setDependencies(...)` after deploy
- [x] Verify CfdEngine runtime/initcode limits and focused engine/router smoke tests after explicit sidecar wiring

Review:
- `CfdEngine` no longer deploys `CfdEnginePlanner`, `CfdEngineSettlementModule`, or `CfdEngineAdmin` inside its constructor. Instead, the engine now starts with those addresses unset and exposes a one-time owner-only `setDependencies(planner, settlementModule, admin)` wiring step.
- This keeps the runtime architecture intact while cutting constructor payload dramatically. The engine still stores and exposes the same planner/admin/settlement addresses after wiring; only the deployment sequence changed.
- Updated the shared perps harnesses (`BasePerpTest`, invariant base) to deploy the planner, settlement module, and admin sidecars explicitly and wire them into the engine before the rest of setup proceeds. Patched standalone setups in fork, gas-profile, router, clearinghouse, and a few audit-history tests that instantiate their own engines outside the shared harness.
- Updated perps docs to note that `CfdEngine`, `CfdEnginePlanner`, `CfdEngineSettlementModule`, and `CfdEngineAdmin` are now deployed separately and wired once through `setDependencies(...)` rather than being constructor-created by the engine.
- Verified with `forge build --skip test --sizes`: `CfdEngine` runtime is now `23,108` bytes and initcode is `23,875` bytes, both under EIP-170 / EIP-3860. Focused verification also passed with `forge test --match-path test/perps/TimelockPause.t.sol --match-test "test_ProposeMaxOrderAge_TimelockFlow|test_OrderRouter_OnlyOwner"`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_SetMaxOrderAge_OnlyOwner|test_StaleOrderExecutesViaExecuteOrder"`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ConfiguringPhase"`.

- [x] Extract OrderRouter timelocked governance surface into a dedicated admin contract and rewire pause ownership
- [x] Finish router admin test/harness migration, including standalone perps and invariant helpers
- [x] Trim cold router read/claim surface enough to bring deployed runtime below EIP-170

Review:
- Added `src/perps/OrderRouterAdmin.sol` plus `IOrderRouterAdminHost` so router governance now mirrors the engine pattern: `maxOrderAge`, `orderExecutionStalenessLimit`, `liquidationStalenessLimit`, `pythMaxConfidenceRatioBps`, and router pause state are all owner-controlled through a dedicated `OrderRouterAdmin` sidecar deployed by `OrderRouter` and exposed at `router.admin()`.
- Finished the router-admin sweep across the shared perps harnesses and the standalone router/fork tests. `BasePerpTest`, invariant bases/handlers, fork tests, and standalone router regressions now sync and use `routerAdmin` instead of assuming timelocked config and pause entrypoints live directly on `OrderRouter`.
- Removed genuinely cold/non-product router bytecode instead of pushing more hot-path execution into cross-contract calls: dropped the dead external `pruneExpiredOrders(...)` entrypoint, moved stranded ETH claims from `OrderRouter` into `OrderRouterAdmin`, and removed the legacy production `getOrderRecord(...)` getter. Tests now decode order-record storage directly through shared helper code instead of depending on that production-only raw getter.
- To clear the final few bytes, collapsed several router-only custom errors into adjacent existing reverts where the distinction was not worth dedicated bytecode. The meaningful queue/oracle/risk behavior remains intact, and focused tests were updated where they asserted the older selector.
- Updated `src/perps/README.md` and `src/perps/SECURITY.md` so they now describe `OrderRouterAdmin` as the owner-facing timelock/pause surface instead of claiming the router itself owns those flows.
- Verified with `forge build --skip test --sizes`: `OrderRouter` runtime is now `24,567` bytes, under the EIP-170 runtime limit. `OrderRouterAdmin` runtime is `3,173` bytes. Focused green coverage includes `forge test --match-path test/perps/TimelockPause.t.sol --match-test "test_ProposeMaxOrderAge_TimelockFlow|test_FinalizeMaxOrderAge_NoProposal_Reverts|test_OrderRouter_OnlyOwner|test_CommitOrder_RevertsWhenPaused|test_ExecuteOrder_WorksWhenPaused|test_ExecuteLiquidation_WorksWhenPaused|test_UpdateMarkPrice_WorksWhenPaused|test_Pause_OnlyOwner|test_Unpause_RestoresCommitOrder"` and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_OrderExecution_UsesRouterExecutionStalenessLimit_NotPoolMarkLimit|test_PythConfidenceTooWide_RevertsExecution|test_BatchExecution_UncommittedMaxId_Reverts|test_SetMaxOrderAge_OnlyOwner"`.
- Remaining note: the repository still reports an initcode-size issue (`CfdEngine` initcode over EIP-3860) even though both `CfdEngine` and `OrderRouter` are now under the deployed runtime cap.

- [x] Extract CfdEngine timelocked governance surface into a dedicated admin contract to reduce runtime size
- [x] Rewire focused tests/docs to use the new engine admin module
- [x] Verify CfdEngine deployed bytecode drops below EIP-170 limit and run focused admin-path Forge coverage

Review:
- Added `src/perps/CfdEngineAdmin.sol` plus `ICfdEngineAdminHost` so the 48-hour governance workflow for `riskParams`, FAD overrides, `fadMaxStaleness`, `fadRunwaySeconds`, and `engineMarkStalenessLimit` now lives outside `CfdEngine` and applies finalized values back onto the engine through a narrow trusted host interface.
- Kept hot-path reads and immediate owner operations on `CfdEngine` itself: live risk config values still sit on-engine for cheap execution-time reads, while one-time wiring (`setVault`, `setOrderRouter`) and immediate maintenance controls (`withdrawFees`, `clearBadDebt`, `sweepToken`, `clearDegradedMode`) remain direct owner actions on the engine.
- `CfdEngine` now deploys and exposes its dedicated admin module at `engine.admin()`, adds `onlyAdmin` setters for finalized config application, and drops the old proposal state / proposal-finalize-cancel entrypoints from the engine bytecode.
- Updated the shared perps test harnesses to track `engineAdmin`, rewired focused governance/timelock assertions to use the new module, and cleaned up standalone tests that instantiate fresh engines outside `BasePerpTest`.
- Updated `src/perps/README.md` and `src/perps/SECURITY.md` so the docs no longer claim the engine itself holds the timelock workflow.
- Verified with `forge build --skip test --sizes`, which now reports `CfdEngine` runtime size `23,527` bytes and `CfdEngineAdmin` runtime size `4,841` bytes. `CfdEngine` is back under the EIP-170 `24,576` byte limit. Focused coverage also passed with `forge test --match-path test/perps/TimelockPause.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_CheckWithdraw_UsesMinimumOfEngineAndPoolMarkStalenessLimits|helper_CheckWithdrawParity_NoCarryProjectionWithoutPriorSync|test_CheckWithdraw_UsesExplicitInitMarginBps|test_SyncState_DoesNotAdvanceOnFrozenMarkPastFadMaxStaleness|test_ProtocolAccounting_DoesNotProjectCarryFromFrozenMarkPastFadMaxStaleness"`, and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_Admin_AddFadDay|test_Admin_RemoveFadDay|test_Admin_SetFadMaxStaleness|test_Admin_SetFadMaxStaleness_ZeroReverts|test_Admin_AddFadDays_NonOwner_Reverts|test_Runway_SetFadRunway|test_OrderExecution_UsesRouterExecutionStalenessLimit_NotPoolMarkLimit"`.
- [x] Patch router oracle prep to apply frozen-market freshness before basket resolution
- [x] Add focused frozen-market regressions for mark refresh and liquidation
- [x] Run targeted Forge verification for the new frozen-market coverage

Review:
- Updated `src/perps/modules/OrderOracleExecution.sol` so order execution, mark refresh, and liquidation all derive frozen-window freshness before calling `_resolveOraclePrice(...)`, and they now use that same dynamic bound for cross-feed publish-time divergence as well.
- Added a focused frozen mark-refresh regression in `test/perps/OrderRouter.t.sol` and strengthened the existing frozen liquidation regression to assert the stale Friday publish time is accepted and stored during the Saturday frozen window.
- Restored the local test harnesses in `test/perps/OrderRouter.t.sol` after the router oracle extraction by inlining the basket/normalization helpers they used to reach through the old internal functions.
- Verified green with `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_FadWindow_(Liquidation_AcceptsStalePrice|MarkRefresh_AcceptsStaleFridayPrice)"`.

- [x] Add a real `HousePool`/`TrancheVault` invariant harness covering seed lifecycle, trading activation, ordinary LP deposits/withdrawals, share cooldown transfer semantics, seed-floor preservation, and tranche/principal parity
- [ ] Add governance/timelock invariants for `CfdEngine`, `OrderRouter`, and `HousePool` covering propose/finalize/cancel/pause state machines
- [x] Add real-router oracle invariants covering mark refresh, publish-time monotonicity, staleness windows, and Pyth ETH refund accounting
- [ ] Add multi-keeper isolation invariants for deferred keeper credit and stranded ETH claims

Review:
- Coverage gap backlog from the perps invariant sweep:
- The focused invariant suites under `test/perps/invariant/` are strong on engine/router accounting, queue bookkeeping, preview parity, and deferred-credit conservation.
- The largest remaining blind spot is that those suites run against `MockInvariantVault`, so they do not stress the real `HousePool`/`TrancheVault` lifecycle and share-accounting state machine.
- Implemented `test/perps/invariant/PerpHousePoolLifecycleInvariant.t.sol`, a real-stack invariant harness on `BasePerpTest` that fuzzes seed initialization, trading activation, pool pause/unpause, tranche deposits, withdrawals, redeems, share transfers, time passage, and excess accounting against the actual `HousePool` and `TrancheVault` contracts.
- The first property set proves lifecycle-flag consistency, seed-floor preservation, positive deposit capacity only during an active lifecycle, reconcile-first withdraw bounds for both tranches, raw-assets/excess accounting parity, and cooldown timestamp propagation across share transfers.
- Verified green with `forge test --match-path test/perps/invariant/PerpHousePoolLifecycleInvariant.t.sol`.
- Implemented `test/perps/invariant/PerpOraclePathInvariant.t.sol`, which deploys a real `OrderRouter` against `MockPyth` and fuzzes order-execution/liquidation staleness-limit updates, real mark refresh attempts, stale/divergent publish-time rejection, out-of-order publish-time rejection, overpaid Pyth-fee refunds, and stranded-ETH claims.
- The oracle properties prove that engine mark state matches the last successful refresh, router ETH custody equals tracked stranded refunds, and both live staleness limits remain positive under timelocked admin updates.
- Made a minimal compile fix in `src/perps/modules/OrderExecutionOrchestrator.sol` so `_revertOraclePublishTimeOutOfOrder()` correctly overrides the declaration inherited from `OrderOracleExecution`.
- Verified green with `forge test --match-path test/perps/invariant/PerpOraclePathInvariant.t.sol`.
- The next highest-value additions after that are admin/timelock invariants, followed by multi-keeper isolation checks.

- [x] Rename deferred clearer bounty surfaces to deferred keeper credit across engine, views, tests, and docs
- [x] Collapse deferred liability increment/claim bookkeeping into shared helpers for trader payout and keeper credit
- [x] Sweep perps docs and lens/type names so deferred liabilities read cleanly after the rename

Review:
- Renamed the keeper-side deferred liability surface from `clearer bounty` to `keeper credit` across the live perps code: `recordDeferredKeeperCredit(...)`, `claimDeferredKeeperCredit()`, `deferredKeeperCreditUsdc`, `totalDeferredKeeperCreditUsdc`, `DeferredKeeperCreditRecorded/Claimed`, and the corresponding protocol/HousePool/view-type fields.
- Updated shared accounting libraries so the underlying solvency/cash-priority model now reads as one generic deferred-liability system with two explicit beneficiaries: `deferredTraderPayoutUsdc` and `deferredKeeperCreditUsdc`. `SolvencyAccountingLib` and `CashPriorityLib` no longer carry liquidation-specific naming, and `CfdEngine` now uses shared `_increaseDeferredLiability(...)` / `_decreaseDeferredLiability(...)` helpers for both liability classes.
- Tightened the keeper-claim semantics instead of regressing them: `claimDeferredKeeperCredit()` now checkpoints carry when a fresh mark exists but still remains claimable when the keeper's own mark is stale, preserving the old liveness property while sharing more of the trader-credit accounting model.
- Swept the docs and lens-facing type names in `src/perps/README.md`, `PRE_AUDIT_GUIDE.md`, `SECURITY.md`, `ACCOUNTING_SPEC.md`, `INTERNAL_ARCHITECTURE_MAP.md`, `ProtocolLensViewTypes.sol`, `HousePoolEngineViewTypes.sol`, and `DeferredEngineViewTypes.sol` so the terminology now matches the implementation.
- Verified green with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_DeferredKeeperCredit_Lifecycle|test_DeferredKeeperCredit_CoalescesPerKeeperAndSupportsPartialClaims|test_ClaimDeferredKeeperCredit_UsesFeeOnlyLiquidityWhenAtQueueHead|test_ClaimDeferredKeeperCredit_RealizesCarryBeforeCreditingSettlement|test_GetDeferredCreditStatus_ReflectsClaimability|test_GetDeferredCreditStatus_ExposesClaimabilityWithoutHeadOrdering|test_ClaimDeferredKeeperCredit_IgnoresKeeperWalletTransferBlacklist|test_ClaimDeferredKeeperCredit_DoesNotRequireFreshMarkForKeeperPosition"`, `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`, `forge test --match-path test/perps/PerpsReadParity.t.sol`, `forge test --match-path test/perps/HousePoolSnapshotParity.t.sol`, `forge test --match-path test/perps/DeferredClaimsMatrix.t.sol`, `forge test --match-path test/perps/ArchitectureRegression.t.sol`, `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol --match-test "invariant_DeferredCreditStatusMatchesEngineAndVaultLiquidity"`, `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_ProtocolViewMirrorsEngineAccounting|invariant_WithdrawalReserveIncludesDeferredLiabilities|invariant_AdversarialLiquidationPayoutFailureOnlyDefersBounty|invariant_DeferredKeeperCreditTotalsConserveClaims"`, and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse|test_ExecuteLiquidation_DefersKeeperCreditPerPreviewWhenVaultPayoutFails|test_ExecuteLiquidation_ForfeitedEscrowFeedsPostForfeitureVaultDepth"`.

- [x] Eliminate special liquidation wallet payout mode and route keeper value through clearinghouse credit
- [x] Update payout/liquidation parity tests and matrices for the unified credit-first policy
- [x] Run focused Forge verification for liquidation, deferred clearer bounty, and payout parity suites

Review:
- Removed the last special USDC keeper payout branch from `src/perps/OrderRouter.sol`: liquidation now uses the same default policy as other keeper value flows by paying the vault out to `clearinghouse` and calling `engine.creditKeeperExecutionBounty(...)`, with fallback to `recordDeferredClearerBounty(...)` when fresh cash is unavailable.
- Kept the deferred clearer claim path unchanged because it already matches the target model: deferred keeper value remains claimable only as clearinghouse credit via `claimDeferredClearerBounty()`.
- Updated payout/liquidation tests and helpers in `test/perps/BasePerpTest.sol`, `test/perps/PayoutModesMatrix.t.sol`, `test/perps/PreviewExecutionDifferential.t.sol`, `test/perps/OrderRouter.t.sol`, and `test/perps/CfdEngine.t.sol` so keeper liquidation value is measured as clearinghouse settlement credit plus deferred liability, not wallet transfer.
- Verified green with `forge test --match-path test/perps/PayoutModesMatrix.t.sol`, `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse|test_ExecuteLiquidation_DefersKeeperCreditPerPreviewWhenVaultPayoutFails|test_ExecuteLiquidation_ForfeitedEscrowFeedsPostForfeitureVaultDepth|test_ExecuteLiquidation_ForfeitsEscrowedCloseBountiesBeforeClearingOrders|test_ExecuteLiquidation_ForfeitsEscrowedOpenBountiesWithoutCreditingTraderSettlement|test_ExecuteLiquidation_PreventsPostLiquidationEscrowRecovery|test_ExecuteLiquidation_ClearsOnlyLiquidatedAccountsPendingOrders"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_DeferredClearerBounty_Lifecycle|test_DeferredClearerBounty_CoalescesPerKeeperAndSupportsPartialClaims|test_ClaimDeferredClearerBounty_IgnoresKeeperWalletTransferBlacklist|test_Liquidation_ConsumesDeferredPayoutBeforeRecordingBadDebt"`, and `forge test --match-path test/perps/AuditRemainingCoverageFindingsFailing.t.sol --match-test "test_H6_LiquidationKeeperRewardMustDeferInsteadOfRevertingOnCashShortage"`.

- [x] Audit open-path apply-time economic preconditions across clearinghouse, engine, and settlement flow
- [x] Centralize shared open-cost economic preconditions into one accounting helper
- [x] Add planner/live parity regressions for free-settlement exhaustion and position-margin underflow
- [x] Run focused Forge verification for planner, clearinghouse, engine, and router failure policy

Review:
- Enumerated the live open-path economic guards that can fail after planning: carry realization affordability, open-cost settlement debit + re-lock affordability, and physical position-margin availability during net margin unlocks.
- Centralized the clearinghouse-side open-cost economics in `src/perps/libraries/MarginClearinghouseAccountingLib.sol` via `planOpenCostApplication(...)`, which now simulates the exact `applyOpenCost(...)` mutation order and exposes the two meaningful insufficiency states: free-equity exhaustion and position-margin underflow.
- Rewired `src/perps/libraries/CfdEnginePlanLib.sol` to use that shared helper for open-path typed rejection, so the planner and clearinghouse now derive open-cost validity from the same logic instead of duplicate local checks.
- Rewired `src/perps/MarginClearinghouse.sol` to consume the same helper before mutating storage, preserving the live revert semantics (`InsufficientFreeEquity` / `InsufficientBucketMargin`) while removing drift from the plan/apply path.
- Added focused live regressions in `test/perps/MarginClearinghouse.t.sol` for both failure modes, and kept the planner/engine/router parity coverage in `test/perps/CfdEnginePlanRegression.t.sol`, `test/perps/CfdEngine.t.sol`, and `test/perps/OrderRouterPolicyMatrix.t.sol`.
- Verified green with `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance|test_ApplyOpenCost_UnlocksPositionMarginBeforeDebitingTradeCost|test_ApplyOpenCost_RevertsWhenTradeCostAndMarginLockExceedFreeSettlement|test_ApplyOpenCost_RevertsWhenUnlockExceedsPositionMargin"`, `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol --match-test "test_PlanOpen_RejectsWhenCarryLeavesFreeSettlementBelowMarginDelta|test_PlanOpen_RejectsInsufficientPhysicalMargin"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_PreviewOpen_ClassifiesCarryDrainedReleasedFreeSettlementAsUserInvalid|test_MarginDrained_ByFees_Reverts"`, and `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol --match-test "test_MarginDrainedByFeesTypedRevertMapsToClearerFull|test_UserInvalidPaysClearer|test_ProtocolInvalidationRefundsTrader"`.

- [x] Fuzz shared open-cost planning against live clearinghouse apply
- [x] Sweep close/liquidation preconditions for planner/apply drift and centralization gaps
- [x] Add close/liquidation live parity tests around the shared accounting helpers

Review:
- Added `MarginClearinghouseAccountingHarness` in `test/perps/MarginClearinghouse.t.sol` to expose the shared pure accounting helpers used by the planner and clearinghouse.
- Added `testFuzz_ApplyOpenCost_MatchesSharedOpenPlan(...)`, which fuzzes settlement balance, locked buckets, margin delta, and trade cost, then proves the live `applyOpenCost(...)` result or revert selector matches `planOpenCostApplication(...)` across 256 runs.
- Swept the close and liquidation apply paths: `consumeCloseLoss(...)` already shares `planTerminalLossConsumption(...)`/`applyTerminalLossMutation(...)` with the planner, and liquidation already shares `planLiquidationResidual(...)` with the planner. The remaining apply-only reverts are reservation-ledger integrity checks (`IncompleteReservationCoverage`) rather than uncovered economic preconditions.
- Added live parity tests `test_ConsumeCloseLoss_MatchesSharedTerminalLossPlan()` and `test_ApplyLiquidationSettlementPlan_MatchesSharedResidualPlan()` so future drift between the shared helpers and the clearinghouse mutation path is caught immediately without adding unnecessary production refactors.
- Verified green with `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "testFuzz_ApplyOpenCost_MatchesSharedOpenPlan|test_ConsumeCloseLoss_MatchesSharedTerminalLossPlan|test_ApplyLiquidationSettlementPlan_MatchesSharedResidualPlan|test_ApplyOpenCost_RevertsWhenTradeCostAndMarginLockExceedFreeSettlement|test_ApplyOpenCost_RevertsWhenUnlockExceedsPositionMargin"`, plus the focused planner/engine/router suites already covering the typed failure path.

- [x] Add broader preview/live property tests for open, close, and liquidation execution parity

Review:
- Extended `test/perps/PreviewExecutionDifferential.t.sol` with `testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution(...)`, which fuzzes same-side increase orders after optional carry accrual and proves that `previewOpenRevertCode == OK` plus `previewOpenFailurePolicyCategory == None` does not devolve into an untyped live open-path revert on same-state execution.
- Tightened the existing fuzzed full-close and liquidation preview tests to assert observed clearinghouse bucket mutations, not just payout/bad-debt outcomes. The differential suite now checks settlement-balance and locked-position-margin transitions against the preview deltas for both liquid and illiquid vault states.
- The first draft of the open property test surfaced `CfdEngine__Unauthorized()` because the low-level test call bypassed the normal router-authorized invocation style; switching to `try/catch` under `vm.startPrank(address(router))` fixed the harness and confirmed the real property.
- Verified green with `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`, plus the accounting, planner, and router-policy suites to keep the whole prevention chain aligned.

- [x] Fix generic vs terminal collateral-basis drift in carry, withdraw, and margin-basis paths
- [x] Allow stale-mark close bounty reservation on risk-reducing close commits when a last mark exists
- [x] Align senior high-water mark docs with compounded protected-claim semantics and add coverage
- [x] Include `unsettledCarryUsdc` in withdrawable views and verify product/read parity

Review:
- Added `getGenericReachableUsdc(...)` to `src/perps/libraries/MarginClearinghouseAccountingLib.sol` and switched the non-terminal carry/risk callers to it. Generic reachability now excludes queued `CommittedOrder` / `ReservedSettlement` buckets, while liquidation and terminal settlement paths continue to use terminal reachability.
- Updated `src/perps/CfdEngine.sol`, `src/perps/MarginClearinghouse.sol`, `src/perps/libraries/CfdEnginePlanLib.sol`, and `src/perps/CfdEngineAccountLens.sol` so carry basis changes, `checkWithdraw`, `addMargin`, deferred-claim carry realization, open planning, and account-lens withdrawability no longer count queued reservations as generic collateral.
- Relaxed `CfdEngine.reserveCloseOrderExecutionBounty(...)` to use the latest stored mark price when present instead of requiring freshness, removing the stale-mark liveness block on risk-reducing close commits that need margin-backed bounty sourcing.
- Kept the current HousePool economic model and aligned docs to it instead of rewriting waterfall math: paid senior yield now remains part of the protected `seniorHighWaterMark` claim, and that behavior is documented in `src/perps/README.md` / `src/perps/PRE_AUDIT_GUIDE.md` and covered by `test_SeniorHighWaterMark_RatchetsPaidYieldIntoProtectedClaim()`.
- Added/updated focused regressions in `test/perps/CfdEnginePlanRegression.t.sol`, `test/perps/CfdEngine.t.sol`, `test/perps/PerpsPublicLens.t.sol`, and `test/perps/HousePool.t.sol` to prove the confirmed issues stay fixed.
- Verified green with:
  - `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol --match-test "test_PlanOpen_CarryBasisExcludesQueuedReservations|test_PlanOpen_RejectsWhenCarryLeavesFreeSettlementBelowMarginDelta|test_PlanOpen_RejectsInsufficientPhysicalMargin"`
  - `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ReserveCloseOrderExecutionBounty_AllowsStaleLastMarkPrice|test_ReserveCloseOrderExecutionBounty_ExcludesQueuedReservationsFromGenericReachability|test_CheckWithdraw_UsesEngineMarkStalenessLimit_NotPoolMarkLimit"`
  - `forge test --match-path test/perps/PerpsPublicLens.t.sol`
  - `forge test --match-path test/perps/PerpsReadParity.t.sol`
  - `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "test_ApplyOpenCost_DebitsSettlementAndLeavesRemainingFreeBalance|test_ApplyOpenCost_UnlocksPositionMarginBeforeDebitingTradeCost|testFuzz_ApplyOpenCost_MatchesSharedOpenPlan|test_ConsumeCloseLoss_MatchesSharedTerminalLossPlan|test_ApplyLiquidationSettlementPlan_MatchesSharedResidualPlan"`
  - `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`
  - `forge test --match-path test/perps/HousePool.t.sol --match-test "test_SeniorHighWaterMark_RatchetsPaidYieldIntoProtectedClaim|test_SeniorPrincipal_RestoredBeforeJuniorSurplus|test_SeniorHWM_ProportionalOnWithdraw|test_SeniorHWM_PreservedOnFullWipeout"`

- [x] Add a small canonical account-domain layer for bucket-derived semantics
- [x] Migrate remaining ambiguous callers to named account-domain helpers
- [x] Add a dedicated account-domain parity suite

Review:
- Extended `src/perps/libraries/MarginClearinghouseAccountingLib.sol` with named account-domain accessors: `getSettlementBalanceUsdc(...)`, `getFreeSettlementUsdc(...)`, `getPositionMarginUsdc(...)`, and `getQueuedReservedUsdc(...)`, then rewired the existing generic/terminal helpers and shared accounting planners to consume those named domains instead of raw bucket fields.
- Refactored the remaining ambiguous business-logic callers in `src/perps/CfdEngineAccountLens.sol`, `src/perps/OrderRouter.sol`, `src/perps/modules/OrderEscrowAccounting.sol`, `src/perps/MarginClearinghouse.sol`, and the planner mutation path in `src/perps/libraries/CfdEnginePlanLib.sol` so new code reads as “which domain is this?” instead of “which raw bucket field happens to work here?”.
- Added `test/perps/AccountDomainParity.t.sol` as the dedicated safety net for this lesson. It proves the helper layer separates generic vs terminal reachability and that the account/public read surfaces keep using the same canonical domain logic.
- Verified green with `forge test --match-path test/perps/AccountDomainParity.t.sol`, `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol --match-test "test_PlanOpen_CarryBasisExcludesQueuedReservations|test_PlanOpen_RejectsWhenCarryLeavesFreeSettlementBelowMarginDelta|test_PlanOpen_RejectsInsufficientPhysicalMargin"`, `forge test --match-path test/perps/PerpsReadParity.t.sol`, and `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`.

- [x] Reduce `CfdEngine` and `OrderRouter` deployed bytecode below EIP-170

Review:
- Trimmed `CfdEngine` by removing redundant position wrapper getters in favor of the existing `positions(...)` getter and by consolidating deferred-claim preparation/claim settlement helpers. The engine now measures `24,525` bytes via `forge inspect src/perps/CfdEngine.sol:CfdEngine deployedBytecode`.
- Trimmed `OrderRouter` with a sequence of low-risk cuts: shared uint timelock helpers, removal of the unused `TerminalFailureKind` / unused `_processTypedOrderExecution(...)` args, pruning-loop deduplication, collapsing the duplicate `submitOrder(...)` wrapper, removing public getters for `MAX_PENDING_ORDERS` / `TIMELOCK_DELAY`, internalizing claimable-balance mappings, inlining the single-caller commit path, and consolidating the stranded-balance claim entrypoint. The router now measures `24,495` bytes via `forge inspect src/perps/OrderRouter.sol:OrderRouter deployedBytecode`.
- Added an end-to-end stale-mark close-commit regression in `test/perps/OrderRouter.t.sol` to ensure the size pass did not regress the new risk-reducing close-bounty behavior.
- Verified green with focused suites that reflect the current clearinghouse-credit policy and preview/live parity:
  - `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol`
  - `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol`
  - `forge test --match-path test/perps/PerpsReadParity.t.sol`
  - `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`
  - `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CloseCommit_CanReserveKeeperBountyFromPositionMarginWhenFullyUtilized|test_CloseCommit_CanReserveKeeperBountyFromPositionMarginWithStaleStoredMark|test_ReserveCloseOrderExecutionBounty_RevertsWhenMarginBackedBountyWouldBreakMaintenance"`
- Note: the legacy catch-all `test/perps/OrderRouter.t.sol` mega-suite still contains numerous older wallet-payout assertions that do not match the current clearinghouse-credit bounty/refund model, so it is not a reliable green gate for this size pass without a broader expectation update.

- [x] Start simplifying the router policy surface by extracting oracle/policy logic into a dedicated module

Review:
- Added `src/perps/modules/OrderOracleExecution.sol` as the router’s dedicated oracle/policy module. It now owns Pyth feed configuration, staleness settings, router execution context construction, basket price resolution, slippage semantics, commit prefilter helpers, and oracle-frozen/close-only policy helpers.
- `src/perps/OrderRouter.sol` now inherits `OrderOracleExecution` and is correspondingly narrower: it focuses on queue traversal, escrow cleanup, failure policy, and liquidation/order orchestration instead of mixing those with price-resolution details.
- Preserved `OrderRouter`’s external error surface by keeping custom-error declarations on the child contract and letting the new module call small virtual revert hooks. This avoided breaking the large existing test surface that references `OrderRouter.OrderRouter__*.selector` directly.
- Verified green with `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_BatchExecution_MEVCheckPerOrder|test_BatchExecution_MixedResults|test_ExpiredOpenOrderRefundsUsdcBountyToTrader_NotKeeper|test_CloseSlippageFailPaysClearerWhenBountyIsMarginBacked|test_Constructor_ZeroEngineLensReverts|test_BasketPrice_RevertsWhenFeedPublishTimesDivergeTooFar"`, and `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`.

- [x] Continue router simplification by extracting queue-book responsibilities into a dedicated module

Review:
- Added `src/perps/modules/OrderQueueBook.sol` to own global queue linking/unlinking, pending-order lookup, and queued-position composition from live positions plus pending account orders.
- `src/perps/OrderRouter.sol` now composes three dedicated modules: `OrderOracleExecution` (oracle/policy), `OrderQueueBook` (queue structure), and `OrderEscrowAccounting` (escrow bookkeeping). This leaves the child contract materially closer to pure execution orchestration and admin surface.
- Kept the extraction low-risk: account/margin queue link helpers remain in `OrderEscrowAccounting`, while the new queue module only owns the global queue and read-side queue composition. That split reduces concern density without entangling execution with storage migration.
- Verified green with the same high-signal router suites: `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_BatchExecution_MEVCheckPerOrder|test_BatchExecution_MixedResults|test_ExpiredOpenOrderRefundsUsdcBountyToTrader_NotKeeper|test_CloseSlippageFailPaysClearerWhenBountyIsMarginBacked|test_Constructor_ZeroEngineLensReverts|test_BasketPrice_RevertsWhenFeedPublishTimesDivergeTooFar"`, and `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_ValidPreviewOpen_DoesNotUntypedRevertOnSameStateExecution|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_LiquidVault|testFuzz_PreviewClose_FullCloseMatchesLiveExecution_IlliquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`.

- [x] Fix open-path post-realization risk check so pending carry is not double-counted
- [x] Add a carry-aware keeper bounty credit path for clearinghouse settlement credits
- [x] Add regressions covering both verified findings and run targeted Forge verification

Review:
- Updated `src/perps/libraries/CfdEnginePlanLib.sol` so the post-open projected risk state now treats the snapshot as already carry-realized after `_applyPendingCarryRealizationToOpenSnapshot(...)` and no longer subtracts `pendingCarryUsdc` a second time during the projected equity check.
- Added `creditKeeperExecutionBounty(...)` to `src/perps/CfdEngine.sol` plus the engine interfaces, and routed `src/perps/modules/OrderEscrowAccounting.sol` through that helper so keeper bounty credits realize carry first when the beneficiary account has an open position before settlement balance is increased.
- Added a planner regression in `test/perps/CfdEnginePlanRegression.t.sol` proving an open in the old double-count window now stays valid, and added a keeper-bounty regression in `test/perps/OrderRouterPolicyMatrix.t.sol` proving the new helper debits accrued carry before crediting settlement.
- Verified green with `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol --match-test "test_PlanOpen_DoesNotDoubleCountRealizedCarryInProjectedRisk|test_PlanOpen_ReportsPendingCarry"` and `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol --match-test "test_ExpiredClosePaysClearer|test_SlippageClosePaysClearer|test_UserInvalidPaysClearer|test_CreditKeeperExecutionBounty_RealizesCarryBeforeCreditingSettlement"`.

- [x] Rewrite `src/perps/README.md` into a basics-first audit packet entry doc
- [x] Sweep core perps NatSpec for stale funding / queue / deferred-claim language
- [x] Add missing high-signal NatSpec on public lenses and settlement surfaces
- [x] Review edited docs for consistency against current delayed-order + carry architecture

Review:
- Planned scope: make `src/perps/README.md` readable to a new auditor before they dive into the accounting docs, and clean up the highest-signal NatSpec drift left by the funding->carry and deferred-queue simplifications.
- Rewrote `src/perps/README.md` into a basics-first document with: market model, actors, units, trader/LP lifecycles, runtime boundaries, carry/deferred-liability overview, router/oracle behavior, and links into the deeper specs.
- Updated stale queue wording so the docs now describe terminal failed-order cleanup rather than a retry/requeue lane.
- Cleaned up NatSpec drift across `src/perps/CfdEngine.sol`, `src/perps/HousePool.sol`, `src/perps/MarginClearinghouse.sol`, `src/perps/OrderRouter.sol`, `src/perps/CfdEngineSettlementModule.sol`, `src/perps/CfdEngineAccountLens.sol`, `src/perps/CfdEngineProtocolLens.sol`, `src/perps/PerpsPublicLens.sol`, and the main perps interfaces/type modules.
- Removed stale deferred FIFO helper structs from `src/perps/interfaces/DeferredEngineViewTypes.sol` and dropped the unused `Cancelled` public order-status variant from `src/perps/interfaces/PerpsViewTypes.sol` so the public docs better match the current state machine.
- Verified the edited source still compiles with `forge build --skip test`.

- [x] Refactor perps accounting symmetry around legacy deferred payouts and pending HousePool waterfall updates
- [x] Add regressions for close-path deferred payout seizure and pending-bucket yield checkpoint preservation

Review:
- Planned refactor scope: (1) make close and liquidation share the same legacy deferred-payout consumption semantics so deferred value is consumed exactly once before bad debt is socialized, and (2) stop `HousePool._applyPendingBucketsLive()` from writing a stale cached waterfall struct back over freshly checkpointed `unpaidSeniorYield`.
- Verification target: focused Forge coverage in `test/perps/CfdEngine.t.sol` and `test/perps/HousePool.t.sol`, plus any lightweight planner-level regression harnesses needed for preview/live parity.
- Implemented a shared deferred-consumption planner helper in `src/perps/libraries/CfdEnginePlanLib.sol`, extended close deltas/previews in `src/perps/CfdEnginePlanTypes.sol` and `src/perps/CfdEngine.sol`, and wired `_applyClose()` to actually consume legacy deferred payout before socializing close bad debt.
- Updated `src/perps/HousePool.sol` so pending-bucket application refreshes the cached waterfall `unpaidSeniorYield` after checkpointing, preventing the subsequent `_setWaterfallState(...)` write from clobbering freshly accrued yield.
- Added regressions in `test/perps/CfdEngine.t.sol` for liquidation negative-residual deferred consumption and close-path deferred seizure, plus a fresh-mark pending-recap yield preservation regression in `test/perps/HousePool.t.sol`.
- Verified green with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_PlanLiquidation_NegativeResidualFullyConsumesLegacyDeferredWithoutReducingBadDebt|test_Close_ConsumesDeferredPayoutBeforeRecordingBadDebt|test_Liquidation_ConsumesDeferredPayoutBeforeRecordingBadDebt"`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "Close"`, and `forge test --match-path test/perps/HousePool.t.sol --match-test "test_FreshPendingSeniorMutation_PreservesCheckpointedUnpaidYield|test_StalePendingSeniorMutation_CapsFutureYieldToPostCheckpointInterval|test_MaxDepositAndMaxMint_ReopenForPendingSeniorRecapAfterWipeout"`.
- Follow-up policy change: made deferred queue-head claims explicitly senior to protocol-fee withdrawals in `src/perps/libraries/CashPriorityLib.sol`, updated the accounting/security docs to match, and rewrote the deferred-bounty regression so fee-only liquidity now services the queue head instead of deadlocking cash.
- Verified policy change with `forge test --match-path test/perps/CashPriorityLib.t.sol` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_WithdrawFees_RespectsSeniorCashReservation|test_ClaimDeferredClearerBounty_UsesFeeOnlyLiquidityWhenAtQueueHead"`.
- Deferred-queue follow-up: indexed trader payout claims by account in `src/perps/CfdEngine.sol`/`src/perps/interfaces/ICfdEngine.sol` so close/liquidation deferred-consumption walks the account-local chain instead of scanning the global deferred queue, while preserving global FIFO head servicing.
- Verified the queue refactor with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_Close_ConsumesDeferredPayoutBeforeRecordingBadDebt|test_Close_ConsumesInterleavedDeferredPayoutWithoutTouchingGlobalHead|test_Liquidation_ConsumesDeferredPayoutBeforeRecordingBadDebt|test_ClaimDeferredPayout_HeadConsumesPartialLiquidityBeforeLaterClaims"` and `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`.

- [x] Design a perps internal architecture diagram that matches the repo Mermaid conventions
- [x] Add the new diagram to `scripts/render-diagrams.mjs`
- [x] Render and embed the new SVG in the internal architecture map

Review:
- Added `perpsInternalArchitecture` to `scripts/render-diagrams.mjs` and wired it into the shared render pipeline as `assets/diagrams/perps-internal-architecture-map.svg`.
- Embedded the rendered SVG in `src/perps/INTERNAL_ARCHITECTURE_MAP.md` so the one-page architecture note now opens with a visual custody-and-flow map before the detailed tables.
- Verified by running `npm ci` to install the local diagram dependency and `node scripts/render-diagrams.mjs`, which rendered the new diagram successfully.

- [x] Add a one-page perps internal architecture map for asset ownership and value flows
- [x] Link the new architecture map from the perps README

Review:
- Added `src/perps/INTERNAL_ARCHITECTURE_MAP.md` as a one-page ops map with four compact sections: asset buckets, mutation boundaries, accounting readers, and cross-domain value flows.
- Linked the new map from `src/perps/README.md` so auditors and contributors can jump from the narrative overview into the custody/accounting matrix without digging through the full spec first.

- [x] Tighten HousePool freshness wording so docs match stale-mark pending-bucket behavior
- [x] Clean up `TrancheVault.maxDeposit()` / `maxMint()` receiver forwarding

Review:
- Updated `src/perps/ACCOUNTING_SPEC.md` and `src/perps/SECURITY.md` so the docs now say freshness gates only mark-dependent reconcile/waterfall math; already-funded pending recapitalization and zero-principal trading buckets may still apply through the same HousePool settlement entrypoint when marks are stale.
- Cleaned up `src/perps/TrancheVault.sol` so `maxDeposit(address receiver)` / `maxMint(address receiver)` forward the actual receiver to `super` instead of hardcoding `address(0)`.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_WipedSeededTranche_IsTerminallyNonDepositable"`.

- [x] Fix uncovered full-close funding-loss accounting in planner close buckets/solvency preview
- [x] Fix fresh-account open planning to use global side margin baseline
- [x] Add regression coverage for both plan/apply mismatches and run targeted Forge tests

Review:
- Updated `src/perps/libraries/CfdEnginePlanLib.sol` so planner-side funding-loss accounting treats `LOSS_UNCOVERED_CLOSE` the same as `LOSS_CONSUMED` everywhere physical USDC was already seized during apply: close settlement bucket construction, immediate-vs-deferred payout cash checks, and close solvency preview deltas.
- Fixed `planOpen(...)` to seed `delta.totalMarginBefore` from the live side snapshot even for fresh accounts, so open-path solvency checks no longer wipe the side's global margin down to the new order's isolated margin.
- Added `test/perps/CfdEnginePlanRegression.t.sol` with two regressions: one proving uncovered-funding full-close preview fees/effective-assets match live post-close state, and one proving fresh-account open planning inherits the current side margin and remains executable.
- Verified green: `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol`, `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_SolvencyUsesPostCloseOiForFunding|PreviewLiquidation_SolvencyUsesPostLiquidationFundingState"`.

- [x] Fix partial-close settlement reachability so queued committed/reserved collateral stays excluded from both preview and live loss consumption
- [x] Add/adjust regressions proving partial closes cannot implicitly spend queued collateral
- [x] Run targeted Forge coverage for clearinghouse + close preview/live parity

Review:
- Added `buildPartialCloseUsdcBuckets(...)` in `src/perps/libraries/MarginClearinghouseAccountingLib.sol` and switched both `src/perps/libraries/CfdEnginePlanLib.sol` and `src/perps/MarginClearinghouse.sol` to use it whenever partial closes must exclude queued committed/reserved collateral from reachable settlement.
- Added a clearinghouse regression in `test/perps/MarginClearinghouse.t.sol` proving `consumeCloseLoss(..., false, ...)` now stops at free settlement plus released live margin and leaves queued reservations untouched.
- Tightened `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` H1 coverage around the new partial-close helper semantics without relying on stateful preview/live interleaving.
- Verified green: `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "ConsumeCloseLoss"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_UnderwaterPartialMatchesLiveRevert|PreviewClose_PartialLossUsesSettlementFreedByReleasedMargin"`, and `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "H1_"`.

- [x] Sweep remaining perps docs for stale deferred-close-bounty language and numbering drift
- [x] Remove dead `bountyDeferred` compatibility state from `OrderRouter`
- [x] Re-run focused perps verification for close-bounty accounting

Review:
- Updated `src/perps/SECURITY.md` and `src/perps/ACCOUNTING_SPEC.md` so the audit packet now matches the current close-order semantics and the refactor invariant list is renumbered cleanly through item 11.
- Removed the now-unreachable `bountyDeferred` branch from `src/perps/OrderRouter.sol`, simplifying escrow views, liquidation forfeiture, and keeper payout flow to the single remaining upfront-reserve model.
- Updated `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` to assert full close-bounty escrow directly instead of checking a dead deferred-state flag.
- Verified clean grep for stale deferred close-bounty language / `bountyDeferred`, plus focused green Forge coverage: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "OrderRecord_UnifiesPendingState|GetAccountEscrow_ReturnsCommittedMarginAndExecutionBounties|CloseOrderCommitsRequireUpfrontExecutionBounty|H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit"` and `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "test_H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit"`.

- [x] Inspect the verified audit regressions and identify the implementation paths to change
- [x] Fix close-order bounty escrow, partial-close loss reachability, stale senior-rate finalization, and forfeited-bounty fee booking
- [x] Re-run targeted Forge coverage for the new regressions and adjacent suites

Review:
- Updated `src/perps/OrderRouter.sol` so close orders now require the same upfront execution-bounty backing as opens, and liquidation-forfeited queued order bounties now book protocol fees through `engine.recordRouterProtocolFee(...)` after the router funds the vault.
- Updated `src/perps/libraries/CfdEnginePlanLib.sol`, `src/perps/MarginClearinghouse.sol`, and `src/perps/CfdEngine.sol` so partial closes no longer reach into queued committed/reserved order buckets; only full closes pass `includeOtherLockedMargin = true` to close-loss settlement.
- Updated `src/perps/HousePool.sol` so stale `finalizeSeniorRate()` windows stop accruing senior yield instead of checkpointing stale-window growth.
- Updated audit and adjacent tests in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol`, `test/perps/AuditRemainingCoverageFindingsFailing.t.sol`, `test/perps/HousePool.t.sol`, `test/perps/OrderRouter.t.sol`, and `test/perps/MarginClearinghouse.t.sol` to reflect the fixed semantics.
- Verified green: targeted audit regressions (`8 passed`), close-bounty router tests (`3 passed`), stale senior-rate tests (`2 passed`), and clearinghouse close-loss tests (`3 passed`).

- [x] Review the current audit-report findings against existing regression coverage
- [x] Add failing regressions for head-of-queue economic clearability and related accounting mismatches
- [x] Run targeted Forge tests and record the current failure deltas

Review:
- Added queue-liveness regressions in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` asserting that a head close order is economically backed at commit time and that head close expiry/slippage terminal paths still pay keepers.
- Added inverse regression coverage for the partial-close reservation boundary in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol`, so partial closes now explicitly fail if they consume queued committed margin.
- Added stale-mark / fee-ownership regressions in `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` and `test/perps/AuditRemainingCoverageFindingsFailing.t.sol` asserting that stale `finalizeSeniorRate()` must not accrue senior yield and liquidation-forfeited queued order bounties must accrue protocol fees.
- Verified current failures with targeted runs: `test_H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit` (`0 < 1e6`), `test_H2_SlippageFailedDeferredHeadCloseMustStillPayKeeper` (`0 != 1e6`), `test_H2_ExpiredDeferredHeadCloseMustStillPayKeeper` (`0 != 1e6`), `test_H1_PartialCloseMustNotConsumeCommittedMarginReservation` (`3_457_400_000 != 4_000_000_000`), `test_L1_FinalizeSeniorRate_StaleMarkMustNotAccrueYield` (`87_732_623 != 0`), and `test_L1_LiquidationForfeitedOrderBountyMustAccrueProtocolFees` (`0 != 1e6`).

- [x] Add explicit HousePool protocol inflow accounting restricted to the engine
- [x] Wire endogenous vault inflows into canonical accounting across engine settlement paths
- [x] Add regression tests for protocol inflows vs unsolicited excess
- [x] Run targeted forge verification and record results

Review:
- Added `recordProtocolInflow(uint256)` to `src/perps/interfaces/ICfdVault.sol` and `src/perps/HousePool.sol` so canonical vault assets can be advanced explicitly for endogenous inflows while unsolicited donations still flow through `accountExcess()` / `sweepExcess()`.
- Updated `src/perps/CfdEngine.sol` to account every protocol-owned positive vault inflow immediately after it lands: router cancellation fees, bad-debt recapitalization, positive trade-cost transfers, funding-loss seizures, close-loss seizures, and liquidation seizures.
- Added focused regression coverage in `test/perps/CfdEngine.t.sol` and `test/perps/HousePool.t.sol` to prove endogenous inflows raise canonical assets without being stranded as excess and that only the engine can use the new inflow path.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol` (102 passed), `forge test --match-path test/perps/OrderRouter.t.sol` (117 passed), `forge test --match-path test/perps/invariant/PerpEconomicConservationInvariant.t.sol` (14 passed), and focused HousePool inflow tests (4 passed). The full `test/perps/HousePool.t.sol` suite still has a pre-existing unrelated failure in `test_SeniorHWMResetPreventsRestoration()`.

- [x] Record a cleanup plan for stale perps preview/accounting surfaces
- [x] Remove dead enum/struct/helper code and simplify liquidation reachability API
- [x] Update affected tests for the API cleanup
- [x] Run targeted forge verification and record results

Review:
- Removed dead semantic leftovers in the perps surface: deleted the unused `OpenPreview` struct, the unused `viewDataMaxLiabilityAfterClose()` helper, and the stale close-preview enum member `InsufficientVaultLiquidity`.
- Simplified the clearinghouse liquidation reachability API in `src/perps/interfaces/IMarginClearinghouse.sol` and `src/perps/MarginClearinghouse.sol` so `getLiquidationReachableUsdc()` now takes only `accountId`, matching its actual behavior.
- Updated engine and invariant/unit tests to use the tightened API and kept the collateral-view assertions intact in `test/perps/CfdEngine.t.sol`, `test/perps/PerpInvariant.t.sol`, and `test/perps/invariant/PerpPreviewInvariant.t.sol`.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol` (97 passed), `forge test --match-path test/perps/PerpInvariant.t.sol` (28 passed), and `forge test --match-path test/perps/invariant/PerpPreviewInvariant.t.sol` (7 passed). `forge build` did not finish within a 300s timeout in this environment.

- [x] Inspect current `HousePool`/`CfdEngine` accounting handoff and identify every getter the pool stitches together
- [x] Add one canonical `HousePoolInputSnapshot` engine view and refactor `HousePool` to consume it everywhere
- [x] Update interfaces/tests/docs as needed and run targeted perps verification

Review:
- Added `ICfdEngine.HousePoolInputSnapshot` plus `getHousePoolInputSnapshot(uint256 markStalenessLimit)` so the engine now hands HousePool one typed accounting/freshness boundary instead of many loosely coupled getters.
- Refactored `src/perps/HousePool.sol` and `src/perps/libraries/HousePoolAccountingLib.sol` so withdrawal accounting, reconcile accounting, and mark-freshness policy all derive from that single engine snapshot, while already-funded pending buckets can still settle through the shared HousePool entrypoint when stale marks skip reconcile waterfall math.
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

## InvarCoin P0/P1 Remediation (Mar 13 2026)

- [x] Preserve pro-rata LP claims in emergency mode by keeping LP accounting intact until assets are actually recovered
- [x] Require balanced LP redemption in `lpWithdraw()` even during emergency mode
- [x] Harden gauge onboarding with explicit approval + LP token validation
- [x] Replace persistent gauge approvals with exact-per-call approvals
- [x] Update unit and fork tests for new emergency/gauge behavior

### Verification
- `forge test --match-path test/InvarCoin.t.sol`
- `forge test --match-path test/fork/InvarCoinGaugeFork.t.sol`

## InvarCoin P1/P2 Hardening (Mar 13 2026)

- [x] Replace direct `stakedInvarCoin` setter with validated propose/finalize timelock flow
- [x] Validate staking vault code exists and `asset() == INVAR`
- [x] Add timelocked `gaugeRewardsReceiver` configuration
- [x] Add protected reward token sweep path and block arbitrary rescue of protected rewards
- [x] Update scripts and tests for the new integration flow

### Verification
- `forge test --match-path test/InvarCoin.t.sol`
- `forge test --match-path test/fork/InvarCoinGaugeFork.t.sol`
- `forge build`

---

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

## Perps Invariant Refactor Plan (Mar 20 2026)

- [ ] Introduce one shared execution-reservation primitive for vault cash in `CfdEngine` / `OrderRouter`
- [ ] Introduce one shared normalization entrypoint for `HousePool` state-dependent admin and view paths
- [ ] Split risk-increasing vs risk-reducing execution gates across engine/router/clearinghouse
- [ ] Collapse projected-vs-live withdrawal/reconcile accounting onto shared helpers with explicit mode flags
- [ ] Add cross-module invariant suites for cash seniority, liveness, stale-mark handling, and projection parity

Review plan:
- Add a canonical cash-priority helper set in `src/perps/libraries/` and consume it everywhere live vault cash moves are decided. Minimum target API: `reservedSeniorCashUsdc(...)`, `availableCashForFreshPayouts(...)`, and `canWithdrawProtocolFees(...)`. Route `CfdEngine._payOrRecordDeferredTraderPayout`, `CfdEngine.claimDeferredPayout`, `CfdEngine.claimDeferredClearerBounty`, `CfdEngine.withdrawFees`, and `OrderRouter._payOrDeferLiquidationBounty` through the same primitive so deferred claims, fees, and fresh payouts cannot diverge.
- Create a `HousePool` normalization boundary: a single helper that fetches `ENGINE.syncFunding()`, snapshot freshness, pending buckets, and projected waterfall state before sensitive paths execute. Use it for `assignUnassignedAssets`, stale-mark-sensitive admin paths, and projected withdrawal views so stale storage reads and projected/live double counting cannot drift independently.
- Refactor liveness rules into two explicit categories: risk-increasing paths (`open`, fee-withdraw-like owner actions, tranche assignment) keep strict solvency/freshness/liquidity gating; risk-reducing paths (`close`, `addMargin`, liquidation cleanup, deferred-claim settlement) use permissive gates that are allowed in degraded mode if they strictly improve or preserve protocol safety. This likely means replacing scattered `_assertPostSolvency()` / free-settlement-only checks with action-specific helpers proving non-worsening state transitions.
- Replace ad hoc projected accounting in `HousePool` and preview surfaces with shared helper modes rather than duplicated math. Concretely: teach `_buildWithdrawalSnapshot` / pending tranche projection helpers whether they are operating on raw-live vs already-projected pending buckets, and ensure pending buckets are mapped exactly once.
- Add dedicated invariant suites rather than only point regressions. New targets: `test/perps/invariant/PerpCashPriorityInvariant.t.sol` for deferred-claim seniority vs fresh payouts/fees; `test/perps/invariant/PerpLivenessInvariant.t.sol` for close/add-margin/deleveraging availability under degraded or fully-utilized conditions; `test/perps/invariant/HousePoolNormalizationInvariant.t.sol` for stale-mark clock behavior, pending-bucket application, HWM reset, and projected/live withdrawal parity. Reuse the existing handler pattern plus a ghost ledger for deferred senior cash, pending buckets, and risk-reducing action reachability.
- Keep a thin layer of deterministic regression tests for each prior exploit shape even after invariants land. Minimum named regressions: deferred-claim leapfrog, fee-withdraw priority inversion, fully-margined close commit, slippage-failed head order bounty semantics, stale-mark reconcile clock preservation, assign-unassigned stale normalization, wiped-pool HWM reset, projected withdrawal double-count, and add-margin during degraded mode.

Review:
- Implemented the first refactor slice around shared cash-priority enforcement by adding `src/perps/libraries/CashPriorityLib.sol` and routing `src/perps/CfdEngine.sol`, `src/perps/OrderRouter.sol`, and `src/perps/libraries/CfdEnginePlanLib.sol` through the same deferred-claim senior-cash rules for fresh payouts, deferred claims, liquidation bounties, fee withdrawals, and preview parity.
- Updated perps docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so the written accounting model now explicitly states that live payout/claim/fee-withdrawal paths reserve outstanding deferred claims before using vault cash.
- Added deterministic regressions in `test/perps/ArchitectureRegression.t.sol` and `test/perps/CfdEngine.t.sol` covering deferred-claim leapfrogging, deferred-claim claimability under competing senior claims, and fee-withdraw priority behavior; updated `test/perps/invariant/PerpDeferredPayoutInvariant.t.sol` so status/preview invariants follow the same senior-cash rule.
- Verified green: `forge test --match-path test/perps/ArchitectureRegression.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "ClaimDeferredPayout|GetDeferredPayoutStatus"`, `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "DeferredPayout|SlippageFailedCloseOrderPaysEscrowedClearerBounty|BatchDeferredKeeperReward|ExecuteLiquidation"`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_.*Deferred|LiquidationPreview_IlliquidDeferredPayoutMatchesLiveOutcome|DeferredClearerBounty_Lifecycle|WithdrawFees"`.

- [x] Inspect current add-margin and close-order liveness gates plus existing regressions for slice 2
- [x] Implement risk-reducing liveness refactor for close commits and addMargin
- [x] Add/update regressions and invariants for fully-margined closes and degraded-mode addMargin
- [x] Run targeted Forge verification for slice 2 and record results

Review:
- Implemented the second refactor slice around risk-reducing liveness by adding `reserveCloseOrderExecutionBounty(...)` to `src/perps/CfdEngine.sol` and `seizePositionMarginUsdc(...)` to `src/perps/MarginClearinghouse.sol`, then updating `src/perps/OrderRouter.sol` so close-order keeper bounty escrow is sourced from free settlement first and falls back to active position margin when the account is otherwise fully utilized.
- Kept the degraded-mode `addMargin()` path intentionally unchanged in `src/perps/CfdEngine.sol` because the current code already allows risk-reducing margin adds; instead, the slice locks that behavior in with explicit regression coverage.
- Updated perps docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so close-order bounty semantics now describe the free-settlement-then-position-margin fallback model instead of requiring idle settlement.
- Added regressions in `test/perps/ArchitectureRegression.t.sol`, `test/perps/OrderRouter.t.sol`, and `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` proving fully margined accounts can still commit close orders while escrow remains fully funded, and re-verified `test_DegradedMode_AllowsAddMarginToExistingPosition` in `test/perps/CfdEngine.t.sol`.
- Verified green: `forge test --match-path test/perps/ArchitectureRegression.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "CloseCommit_|SlippageFailedCloseOrderPaysEscrowedClearerBounty|Expired|ExecuteLiquidation"`, `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "H2_"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "DegradedMode_AllowsAddMarginToExistingPosition"`, and `forge test --match-path test/perps/invariant/PerpEconomicConservationInvariant.t.sol`.

- [x] Inspect HousePool reconcile, senior-yield clock, unassigned-asset assignment, and projected withdrawal paths
- [x] Implement HousePool normalization boundary and projected-vs-live accounting fixes
- [x] Add/update regressions and invariants for stale-mark clocks, pending buckets, HWM reset, and projection parity
- [x] Run targeted Forge verification for HousePool slice and record results

Review:
- Implemented the third refactor slice in `src/perps/HousePool.sol` by adding a shared `HousePoolContext`, routing `assignUnassignedAssets()` through a sync + fresh-mark + reconcile normalization boundary, preserving `lastReconcileTime` across stale reconcile/rate-finalization paths, applying pending buckets even when stale skips waterfall math, resetting the senior HWM on post-wipeout unassigned-asset bootstraps, and teaching `_buildWithdrawalSnapshot(...)` to distinguish projected vs live pending-bucket reservation.
- Updated docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so stale HousePool semantics now state that stale windows do not destroy accrual time, pending buckets can still settle, and projected withdrawal views reserve pending buckets exactly once.
- Added/updated deterministic regressions in `test/perps/HousePool.t.sol`, `test/perps/AuditHousePoolViewFindingsFailing.t.sol`, `test/perps/AuditLatestStateFindingsFailing.t.sol`, `test/perps/AuditValidFindingsFailing.t.sol`, and `test/perps/AuditConfirmedFindingsFailing.t.sol` covering stale clock preservation, pending-bucket application during stale marks, assign-unassigned stale normalization, post-wipeout HWM reset on bootstrap, and projected recapitalization withdrawal parity.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol`, `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`, `forge test --match-path test/perps/AuditLatestStateFindingsFailing.t.sol`, `forge test --match-path test/perps/AuditValidFindingsFailing.t.sol --match-test "M2_|M1_|Senior"`, `forge test --match-path test/perps/AuditConfirmedFindingsFailing.t.sol --match-test "HWM|Senior|Recap"`, and `forge test --match-path test/perps/PerpInvariant.t.sol`.

- [x] Inspect current order failure policy and queue semantics for retryable vs terminal failures
- [x] Implement retryable slippage/market-state handling without terminal bounty burn
- [x] Add/update regressions and invariants for retryable head-order behavior and escrow preservation
- [x] Run targeted Forge verification for order-failure-policy slice and record results

Review:
- Implemented the fourth refactor slice in `src/perps/OrderRouter.sol` by reclassifying slippage misses as retryable market-state failures: single-order execution now leaves the order pending and preserves escrow, and batched execution stops at a slippage-blocked head instead of terminally deleting it and paying the clearer.
- Updated protocol docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so retryable slippage misses are now documented alongside stale-oracle misses as non-terminal queue states, while only expired / terminal-invalid orders consume bounty escrow.
- Added and updated regressions in `test/perps/OrderRouter.t.sol` and `test/perps/AuditBlockingAccountingFindingsFailing.t.sol` proving that retryable close/open slippage leaves queue head and escrow intact, does not pay the keeper, pins the tail until the head becomes marketable again, and still preserves the existing expiry-based liveness path for terminal cleanup.
- Re-verified adversarial queue/escrow invariants with `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_AdversarialBatchProcessingRemainsLive|invariant_AdversarialEscrowStaysBacked|invariant_AdversarialRouterCustodiesOnlyPendingKeeperReserves|invariant_AdversarialViewsStayConsistent"`.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "PoisonedHead_|StateMachine_BatchLeavesRetryableSlippageHeadPending|SlippageFailurePreservesEscrowAndQueue|SlippageFailedCloseOrderPreservesEscrowedBounty|DeferredPayout_CloseDoesNotBlockLaterQueuedOrders"`, `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "H2_Slippage|H2_ExpiredHeadCloseMustStillPayKeeper|H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit"`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "ExpiredOrderFeeRefundedToUser|BatchExpiredFeeRefundedToUser|StaleOracleRevertPreservesEscrowAndQueue|StateMachine_BatchCancelsTerminalHeadAndPreservesNonTerminalTail"`, and the targeted adversarial invariants above.

Review:
- Added dedicated invariant coverage in `test/perps/PerpInvariant.t.sol` for the two architectural bug classes we just refactored: `invariant_HousePoolPendingStateMatchesReconcileFirstState()` now checks projected-vs-live HousePool parity by comparing `getPendingTrancheState()` to a same-tx reconcile-first state, and `invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow()` now proves retryable slippage misses keep the FIFO head and keeper escrow intact immediately after adversarial batch attempts.
- Extended `AdversarialPerpHandler` ghost tracking to capture retryable-slippage batch transitions (before/after queue pointer, order status, escrow, router balance) so the invariant reasons about the exact transition that occurred rather than a later mutated state.
- Verified green with `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_HousePoolPendingStateMatchesReconcileFirstState|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow|invariant_AdversarialBatchProcessingRemainsLive|invariant_AdversarialEscrowStaysBacked|invariant_AdversarialRouterCustodiesOnlyPendingKeeperReserves|invariant_AdversarialViewsStayConsistent"`.

Review:
- Did a cleanup pass on the new refactor helpers without changing behavior: removed the unused `markFreshForReconcile` field from `src/perps/HousePool.sol`, collapsed the duplicated stale-rate-finalization branch there, removed the dead `positions[accountId]` read in `src/perps/CfdEngine.sol`, and extracted `_reserveCloseExecutionBounty(...)` in `src/perps/OrderRouter.sol` so close-bounty reservation logic now lives in one helper instead of inline.
- Re-verified the touched paths with `forge test --match-path test/perps/OrderRouter.t.sol --match-test "CloseCommit_|PoisonedHead_|SlippageFailurePreservesEscrowAndQueue|SlippageFailedCloseOrderPreservesEscrowedBounty"`, `forge test --match-path test/perps/HousePool.t.sol --match-test "FinalizeSeniorRate_|AssignUnassignedAssets_|GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets|RecordRecapitalizationInflow_StaleMarkCheckpointsWithoutAccruingYield"`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_HousePoolPendingStateMatchesReconcileFirstState|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow"`.

Review:
- Consolidated a bit further by extracting `_saturatingSub(...)` in `src/perps/libraries/CashPriorityLib.sol`, reusing a single `_buildCurrentHousePoolContext()` in `src/perps/HousePool.sol`, and adding `_availableCashForFreshVaultPayouts()` in `src/perps/CfdEngine.sol` so the cash-priority layer now reads more like a shared policy surface instead of repeated direct calls.
- Re-verified with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "ClaimDeferredPayout|GetDeferredPayoutStatus|WithdrawFees"`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "CloseCommit_|PoisonedHead_|SlippageFailurePreservesEscrowAndQueue|SlippageFailedCloseOrderPreservesEscrowedBounty"`, `forge test --match-path test/perps/HousePool.t.sol --match-test "FinalizeSeniorRate_|AssignUnassignedAssets_|GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets"`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_HousePoolPendingStateMatchesReconcileFirstState|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow"`.

Review:
- Implemented PR A in `src/perps/OrderRouter.sol` by turning retryable slippage misses into explicit skip-to-tail transitions: orders now carry `retryAfterTimestamp`, the router emits `OrderSkipped(...)`, keeps escrow intact, requeues the skipped order behind the global tail, and applies a short cooldown so later queued orders can progress without bounty farming or permanent head blocking.
- Added global queue-link state to `OrderRouter` so execution order now follows the live pending queue rather than raw numeric order ids, and updated pending-order views to expose retry cooldowns. Also updated invariant helper scans in `test/perps/PerpInvariant.t.sol`, `test/perps/invariant/handlers/PerpAccountingHandler.sol`, `test/perps/invariant/PerpMultiAccountInvariant.t.sol`, and `test/perps/invariant/PerpAccountingInvariant.t.sol` so pending-order accounting no longer assumes `nextExecuteId..nextCommitId` is a contiguous live range after requeues.
- Updated docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so retryable slippage is now documented as `OrderSkipped` + tail requeue + cooldown rather than a terminal failure or permanent head pin.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "PoisonedHead_|StateMachine_BatchSkipsRetryableSlippageHeadToTail|SlippageFailurePreservesEscrowAndRequeuesOrder|SlippageFailedCloseOrderPreservesEscrowedBounty|CloseCommit_"`, `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "H2_Slippage|H2_ExpiredHeadCloseMustStillPayKeeper|H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit"`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow|invariant_AdversarialBatchProcessingRemainsLive|invariant_AdversarialEscrowStaysBacked|invariant_AdversarialRouterCustodiesOnlyPendingKeeperReserves|invariant_AdversarialViewsStayConsistent"`.

Review:
- Implemented PR B in `src/perps/HousePool.sol` by splitting the senior-yield checkpoint clock from `lastReconcileTime`: the pool now tracks `lastSeniorYieldCheckpointTime`, uses that clock for both live reconcile and projected pending-state yield accrual, and checkpoints it before any principal-changing stale-path mutation instead of letting pending-bucket principal changes inherit pre-mutation time.
- Updated direct senior-principal mutation paths (`initializeSeedPosition`, `depositSenior`, stale pending-bucket application) so they explicitly checkpoint the senior-yield clock, while stale non-senior bucket routing leaves the senior-yield base untouched. `lastReconcileTime` now remains a reconcile/waterfall clock instead of doubling as the only yield base.
- Added and updated HousePool regressions in `test/perps/HousePool.t.sol` covering seeded-principal checkpointing, stale recapitalization without retroactive accrual, and an upper-bound regression showing stale senior-principal restoration cannot accrue more than the post-checkpoint interval. Re-verified the projected/live parity invariant in `test/perps/PerpInvariant.t.sol`.
- Updated `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so stale HousePool semantics now explicitly describe the dual-clock model and the rule that principal-changing stale mutations checkpoint the senior-yield base before principal changes.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "FinalizeSeniorRate_|InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation|RecordRecapitalizationInflow_StaleMarkCheckpointsWithoutAccruingYield|StalePendingSeniorMutation_CapsFutureYieldToPostCheckpointInterval|AssignUnassignedAssets_"` and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_HousePoolPendingStateMatchesReconcileFirstState"`.

Review:
- Implemented PR C in `src/perps/CfdEngine.sol` by replacing coarse deferred-claim claimability with an exact oldest-first deferred-claim queue. Deferred trader payouts and deferred clearer bounties now append queue nodes, direct claims can only service the current head, and partial returning liquidity is allowed to pay down the head claim without unlocking later claims out of order.
- Kept aggregate per-account/per-keeper deferred balances and protocol-wide deferred totals for accounting compatibility, while adding queue-head state and `getDeferredClaimHead()` for observability. `withdrawFees()` and fresh immediate payouts still respect the aggregate senior reservation, but actual claim servicing is now exact rather than all-or-nothing.
- Updated regressions in `test/perps/CfdEngine.t.sol` and `test/perps/ArchitectureRegression.t.sol` to cover partial head claims, blocked non-head claimant calls, queue-head status exposure, and oldest-first servicing under partial liquidity. Updated `test/perps/invariant/PerpDeferredPayoutInvariant.t.sol` so claimability invariants now follow queue-head semantics instead of coarse total-liability coverage.
- Updated `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so deferred claim servicing is now documented as one oldest-first queue shared by trader payouts and clearer bounties.

## Order Failure Policy Refactor Plan (Mar 25 2026)

- [x] Patch the two confirmed policy bugs in `src/perps/OrderRouter.sol`
- [x] Introduce one canonical order-failure policy helper in `src/perps/libraries/OrderFailurePolicyLib.sol`
- [x] Normalize router-local and engine-typed failures into one internal routed-failure representation
- [x] Route all commit/execution/batch failure decisions through the canonical policy helper only
- [x] Add direct matrix tests for policy classification plus one integration regression per execution path
- [x] Update perps docs to explicitly separate commit-time rejectable opens from execution-time failure ownership

Review plan:
- Bug 1 patch: replace the inline `previewOpenRevertCode(...)` allowlist in `src/perps/OrderRouter.sol:327` with a policy call so commit-time open prefilter rejects at least `MUST_CLOSE_OPPOSING`, `POSITION_TOO_SMALL`, `INSUFFICIENT_INITIAL_MARGIN`, `SKEW_TOO_HIGH`, and `SOLVENCY_EXCEEDED`. Keep the prefilter open-only and only on the existing commit-mark path.
- Bug 2 patch: remove the hardcoded close-only `FailedOrderBountyPolicy.ClearerFull` branches in `src/perps/OrderRouter.sol:527`, `src/perps/OrderRouter.sol:655`, and any matching expiry/post-commit invalidation path; instead build a typed routed-failure context and let policy return `RefundUser` for open orders invalidated after commit by close-only / oracle-frozen / FAD state.
- Canonical helper shape: add `src/perps/libraries/OrderFailurePolicyLib.sol` with a small API surface only: `isPredictablyInvalidOpen(uint8 revertCode) -> bool` and `bountyPolicyForFailure(FailureContext memory) -> OrderRouter.FailedOrderBountyPolicy`. Define enums for failure source (`RouterPolicy`, `EngineTyped`, `UntypedRevert`, `Expired`) and routed domain (`UserInvalid`, `ProtocolStateInvalidated`, `Retryable`, `Expired`).
- Normalization step: add an internal `RoutedFailure` / `FailureContext` struct in or next to the new library, then convert every order-failure source into it before cleanup: typed engine reverts via `_decodeTypedOrderFailure(...)`, router close-only boundaries from `OrderOraclePolicyLib`, expiries from `maxOrderAge`, and panic/untyped engine reverts as conservative clearer-paid failures unless explicitly classified otherwise. Keep slippage on the existing retry/requeue path and out of terminal bounty handling.
- Router refactor target: `commitOrder()` should only ask the policy helper whether an open revert code is predictably invalid. `executeOrder()` and `executeOrderBatch()` should only ask the policy helper for the failed-order bounty decision. Delete local ad hoc `_isRefundableProtocolStateFailure(...)`, typed-close special casing, and direct `ClearerFull` branches where the result is really policy-driven.
- Engine compatibility: keep `ICfdEngine.OrderExecutionFailureClass` for now, but make `OrderFailurePolicyLib` own the mapping from `OpenRevertCode` / `CloseRevertCode` / router-local failure sources into routed semantic domains. If the engine already exposes enough information, avoid widening the external engine interface in the first slice.
- Test matrix: add one focused policy test file (for example `test/perps/OrderFailurePolicyLib.t.sol`) with table-driven cases spanning open vs close, router-detected vs engine-detected, user-invalid vs protocol-state-invalidated, close-only / FAD / oracle-frozen / degraded, and expected queue+bounty outcomes. Minimum named rows: deterministic open too small rejects at commit; deterministic opposing open rejects at commit; open invalidated by close-only after commit refunds trader; typed user-invalid open pays clearer; typed protocol-state-invalidated open refunds trader; invalid close pays clearer; expiry refunds or pays according to the documented domain.
- Integration coverage: keep one regression each in `test/perps/OrderRouter.t.sol` (single execute), `test/perps/OrderRouter.t.sol` batch execution path, and any existing audit regression files currently asserting the wrong bounty recipient so both router-local and engine-typed paths prove they hit the same classifier.
- Documentation scope: update `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` to define the four explicit policy buckets: commit-time rejectable, execution-time user-invalid, execution-time protocol-state-invalidated, and execution-time retryable. Document that commit-time filtering is intentionally narrower than execution-time failure ownership.
- Verification target: run `forge test --match-path test/perps/OrderFailurePolicyLib.t.sol`, targeted router regressions in `test/perps/OrderRouter.t.sol`, the failing-audit regression files that cover refund-vs-clearer semantics, and then `forge fmt --check` if the new helper changes multiple files.

Review:
- Added `src/perps/libraries/OrderFailurePolicyLib.sol` as the canonical order-failure classifier. It now owns the deterministic commit-time open prefilter list and the single `bountyPolicyForFailure(...)` decision over normalized routed failures.
- Refactored `src/perps/OrderRouter.sol` so `commitOrder()` calls only `OrderFailurePolicyLib.isPredictablyInvalidOpen(...)`, while `executeOrder()` / `executeOrderBatch()` convert router close-only boundaries, typed engine failures, untyped reverts, and expiry into one `FailureContext` before asking the policy helper who should receive the failed-order bounty.
- Patched the two concrete bugs: commit-time open prefilter now rejects `MUST_CLOSE_OPPOSING` and `POSITION_TOO_SMALL`, and router-detected close-only invalidation of queued opens now routes the bounty to `RefundUser` instead of `ClearerFull` in both single and batched execution.
- Added matrix coverage in `test/perps/OrderFailurePolicyLib.t.sol` plus router regressions in `test/perps/OrderRouter.t.sol` covering deterministic opposing/dust opens, router-detected close-only invalidation refunds, typed protocol-state invalidations refunding traders, and typed user-invalid opens still paying the clearer.
- Updated `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so the docs now explicitly distinguish commit-time deterministic rejection from execution-time user-invalid, protocol-state-invalidated, retryable, and expired handling.
- Verified green with `forge test --match-path test/perps/OrderFailurePolicyLib.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitOrder_RevertsOnPredictableMustCloseOpposing|test_CommitOrder_RevertsOnPredictablePositionTooSmall|test_FadWindow_InvalidOpenOrderPaysClearerAtExecution|test_FadWindow_BatchInvalidOpenOrderRefundsUserAtExecution|test_PostCommitSkewInvalidationRefundsUserBounty|test_BatchPostCommitSkewInvalidationRefundsUserBounty|test_PostCommitMarginDrainInvalidationPaysClearerBounty|test_BatchPostCommitMarginDrainInvalidationPaysClearerBounty"`, and `forge fmt --check src/perps/libraries/OrderFailurePolicyLib.sol src/perps/OrderRouter.sol test/perps/OrderFailurePolicyLib.t.sol test/perps/OrderRouter.t.sol`.

## Phase 6 Semantic Failure Categories (Mar 25 2026)

- [x] Move open preview policy classification from raw revert-code lists to planner-defined semantic categories
- [x] Move typed execution failures from coarse router-owned code mapping to planner/engine semantic categories
- [x] Keep `OrderFailurePolicyLib` focused on commit-time rejection and bounty ownership over semantic categories
- [x] Extend tests to assert semantic-category behavior and rerun router/audit coverage

## Canonical State Transition Refactor (Mar 26 2026)

- [x] Replace mark-refresh funding backfill with a canonical stale-aware checkpoint path in `src/perps/CfdEngine.sol`
- [x] Prevent open planning from treating deferred funding IOUs as physically unlockable trade-cost margin in `src/perps/libraries/CfdEnginePlanLib.sol`
- [x] Make liquidation preview stage funding on pre-forfeit depth and solvency/payout checks on post-forfeit depth+fees
- [x] Add targeted regressions for stale mark refresh, illiquid deferred-funding opens, and liquidation preview/live parity
- [x] Update `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` to describe the staged transition model explicitly

Review:
- `src/perps/CfdEngine.sol` now checkpoints `lastFundingTime` instead of backfilling stale live-mark windows when `updateMarkPrice()` refreshes a stale mark, and liquidation preview explicitly applies queued-order escrow forfeiture as a post-funding vault-cash/protocol-fee mutation.
- `src/perps/CfdEnginePlanTypes.sol` adds `fundingVaultDepthUsdc` so planner funding can use pre-mutation depth while payout/solvency math reads the post-mutation asset/cash state.
- `src/perps/libraries/CfdEnginePlanLib.sol` now rejects opens that only pass because deferred funding is counted as equity even though the physical position-margin bucket cannot pay the negative trade-cost delta.
- Added targeted regressions in `test/perps/CfdEngine.t.sol` and `test/perps/CfdEnginePlanRegression.t.sol`, then verified them with focused `forge test` runs plus `forge fmt --check` on the changed Solidity files.

Review:
- Added semantic planner enums in `src/perps/CfdEnginePlanTypes.sol` for commit-time open policy (`CommitTimeRejectable`, `ExecutionTimeUserInvalid`, `ExecutionTimeProtocolStateInvalidated`) and typed execution ownership (`UserInvalid`, `ProtocolStateInvalidated`).
- Added canonical semantic mapping helpers in `src/perps/libraries/CfdEnginePlanLib.sol`, so the engine now owns how raw `OpenRevertCode` / `CloseRevertCode` values collapse into policy categories instead of leaving that mapping in `src/perps/OrderRouter.sol`.
- Extended `src/perps/interfaces/ICfdEngine.sol` and `src/perps/CfdEngine.sol` with `previewOpenFailurePolicyCategory(...)`, and changed typed order failures to emit the semantic execution category directly. `src/perps/OrderRouter.sol` now consumes those semantic categories for commit-time filtering and typed-failure normalization.
- Simplified `src/perps/libraries/OrderFailurePolicyLib.sol` so it no longer knows individual engine revert codes; it now answers policy questions over semantic categories plus normalized router-local failures only.
- Updated docs in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` to note that the planner/engine now expose semantic policy categories rather than forcing the router to maintain raw revert-code ownership rules.
- Verified green with `forge test --match-path test/perps/OrderFailurePolicyLib.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ProcessOrderTyped_.*|test_FundingSettlement_ExceedsMargin_Reverts|test_AsyncFundingDoesNotBlockLegitOrders"`, `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitOrder_RevertsOnPredictableMustCloseOpposing|test_CommitOrder_RevertsOnPredictablePositionTooSmall|test_PostCommitSkewInvalidationRefundsUserBounty|test_PostCommitMarginDrainInvalidationPaysClearerBounty|test_FadWindow_InvalidOpenOrderPaysClearerAtExecution|test_FadWindow_BatchInvalidOpenOrderRefundsUserAtExecution"`, `forge test --match-path test/perps/AuditV3.t.sol`, `forge test --match-path test/perps/AuditFindings.t.sol`, `forge test --match-path test/perps/OrderRouter.t.sol`, and `forge fmt --check src/perps/CfdEnginePlanTypes.sol src/perps/libraries/CfdEnginePlanLib.sol src/perps/interfaces/ICfdEngine.sol src/perps/CfdEngine.sol src/perps/libraries/OrderFailurePolicyLib.sol src/perps/OrderRouter.sol test/perps/CfdEngine.t.sol test/perps/OrderFailurePolicyLib.t.sol`.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "ClaimDeferredPayout|ClaimDeferredClearerBounty_RevertsWhenTraderClaimIsAheadInQueue|GetDeferredPayoutStatus|DeferredClearerBounty_Lifecycle"`, `forge test --match-path test/perps/ArchitectureRegression.t.sol --match-test "DeferredClaim|FreshClosePayout"`, and `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`.

Review:
- Followed up on the remaining design concerns by making deferred-claim head servicing permissionless in `src/perps/CfdEngine.sol`: anyone can now service the queue head, but payouts still go to the recorded trader account or keeper beneficiary. This removes the head-of-line liveness dependency on the beneficiary showing up while preserving oldest-first fairness.
- Strengthened router queue coverage in `test/perps/PerpInvariant.t.sol` by removing the last contiguous-`nextExecuteId..nextCommitId` assumptions, adding `invariant_GlobalQueueLinksRemainConsistent()`, and updating pending-order accounting to scan actual pending records instead of numeric gaps. This specifically hardens requeue/cooldown/liquidation interactions under adversarial batch processing.
- Added an on-chain seed lifecycle gate for new risk-increasing order commits via `OrderRouter__SeedLifecycleIncomplete` in `src/perps/OrderRouter.sol`, and exposed `isSeedLifecycleComplete()` from `src/perps/HousePool.sol` / `src/perps/interfaces/ICfdVault.sol` so trading cannot start before both tranche seeds exist on-chain.
- Documented the close-bounty-from-margin path as an explicit bounded policy tradeoff in `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md`, including the per-account `MAX_PENDING_ORDERS * 1 USDC` reachability bound.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-contract CfdEngineTest --match-test "ClaimDeferredPayout|ClaimDeferredClearerBounty_RevertsWhenTraderClaimIsAheadInQueue|DeferredClearerBounty_Lifecycle|GetDeferredPayoutStatus"`, `forge test --match-path test/perps/HousePool.t.sol --match-contract HousePoolSeedLifecycleGateTest`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_PendingKeeperReservesBackedByRouterUsdc|invariant_CommittedMarginOwnershipAccountingConservesQueuedExposure|invariant_GlobalQueueLinksRemainConsistent|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow|invariant_AdversarialBatchProcessingRemainsLive"`.

Review:
- Attempted the broader recursive perps suite with `forge test --match-path "test/perps/**/*.t.sol"`. The suite does not pass yet. The dominant failure mode is the new trading seed-lifecycle gate: many legacy order-router / engine / liquidation tests intentionally operate in a zero-seed setup and now revert with `OrderRouter__SeedLifecycleIncomplete` before reaching their original assertions.
- I narrowed the gate once already so it only blocks trading in a partially seeded state (not the fully unseeded state), but the broader suite still reveals many test fixtures that initialize only one seed or depend on older unseeded trading assumptions. This means the new lifecycle policy is still incompatible with a significant portion of the current test harness.
- The broader suite also surfaced that warnings remain largely pre-existing and widespread across invariant/audit test files and some older library signatures. I did not do a repo-wide warning cleanup yet because the broader-suite compatibility issue is the more important blocker.

Review:

- [x] Revisit remaining audit follow-ups around senior-cash reservation, seed-init funding sync, and zero-mark withdraw guarding
- [x] Reserve protocol-fee inventory inside the shared cash-priority kernel and wire live/preview payout gating through it
- [x] Sync funding before `HousePool.initializeSeedPosition()` mutates pool depth/accounting
- [x] Tighten `CfdEngine.checkWithdraw()` so open positions cannot pass with `lastMarkPrice == 0`
- [x] Add focused regressions and rerun targeted Forge verification

Review:
- Updated `src/perps/libraries/CashPriorityLib.sol`, `src/perps/CfdEngine.sol`, `src/perps/OrderRouter.sol`, and `src/perps/libraries/CfdEnginePlanLib.sol` so the shared cash-priority kernel now takes `accumulatedFeesUsdc`, reserves protocol-fee inventory from fresh payouts / deferred claims / liquidation bounty payments, and exposes the separate fee-withdraw path that can only consume fee inventory left after queued senior claims.
- Updated `src/perps/HousePool.sol` so `initializeSeedPosition(...)` now calls `ENGINE.syncFunding()` before adding raw/accounted seed depth, preventing retroactive funding relief from same-tx seed bootstraps.
- Updated `src/perps/CfdEngine.sol` so `checkWithdraw(...)` now treats `lastMarkPrice == 0` as stale when an open position exists instead of silently allowing the withdrawal guard to no-op.
- Added focused regressions in `test/perps/CashPriorityLib.t.sol`, `test/perps/CfdEngine.t.sol`, and `test/perps/HousePool.t.sol`, and updated `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so the docs match the tighter cash-priority and funding-sync semantics.
- Verified green: `forge test --match-path test/perps/CashPriorityLib.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "WithdrawFees|ClaimDeferredClearerBounty_RespectsProtocolFeeReservation|CheckWithdraw_UsesPoolMarkStalenessLimit|CheckWithdraw_RevertsWhenOpenPositionHasZeroMarkPrice"`, and `forge test --match-path test/perps/HousePool.t.sol --match-test "InitializeSeedPosition_(MintsPermanentSeedShares|SyncsFundingBeforeAddingDepth)"`.
- Reworked the lifecycle policy to the chosen engineering/product balance: `src/perps/HousePool.sol` now tracks explicit `seniorSeedInitialized`, `juniorSeedInitialized`, and `isTradingActive` state, exposes `hasSeedLifecycleStarted()` / `isSeedLifecycleComplete()` / `isTradingActive()`, and adds owner-only `activateTrading()` gated on both seeds existing. `src/perps/OrderRouter.sol` now blocks risk-increasing commits only when seeding is partially complete, or when both seeds exist but trading has not been explicitly activated.
- Updated `test/perps/BasePerpTest.sol` so seeded test setups auto-activate trading once both initial seeds are installed, preserving compatibility for fixtures that already model a fully seeded live system. Added targeted lifecycle regressions in `test/perps/HousePool.t.sol` for both partial-seed blocking and full-seed pre-activation blocking.
- Re-verified targeted compatibility after the redesign: `forge test --match-path test/perps/HousePool.t.sol --match-contract HousePoolSeedLifecycleGateTest`, `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterTest --match-test "BatchExecution_AllSucceed|AccountEscrowView_TracksPendingOrders|CommitOrder_DualWritesReservationAndRouterCommittedMarginState"`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_PendingKeeperReservesBackedByRouterUsdc|invariant_CommittedMarginOwnershipAccountingConservesQueuedExposure|invariant_GlobalQueueLinksRemainConsistent|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow|invariant_AdversarialBatchProcessingRemainsLive"`.
- The full recursive perps suite still does not pass yet, but the remaining broad-suite failures are now a smaller follow-up set of legacy tests that build a partially seeded state or assume activation semantics that do not match the new explicit lifecycle policy. The activation design itself is now stable; the remaining work is harmonizing older test fixtures rather than redesigning the runtime logic again.

Review:
- Fixed the remaining concrete queue issues in `src/perps/OrderRouter.sol`: `executeOrder()` now enforces `retryAfterTimestamp` just like batch execution, and the global queue now uses `0` as the only empty-queue sentinel. Single-order execution now reverts with `OrderRouter__RetryCooldownActive` during cooldown, and empty-queue execution reverts cleanly with `OrderRouter__NoOrdersToExecute` instead of relying on `nextCommitId` as a pseudo-head.
- Added explicit lifecycle gating for ordinary LP deposits in `src/perps/TrancheVault.sol`: once seed lifecycle has started, ordinary `deposit()` / `mint()` calls are blocked until owner activation via `TrancheVault__TradingNotActive`, matching the same lifecycle policy used for new risk-increasing order commits.
- Tightened lifecycle semantics further by switching `HousePool` seed readiness from share-supply inference to explicit `seniorSeedInitialized` / `juniorSeedInitialized` flags, which avoids accidental false positives from ordinary LP deposits and makes activation conditions unambiguous.
- Updated docs to remove the stale “strict commitment sequence” wording and to state that ordinary LP deposits, like new opens, are gated behind seed completion plus explicit activation.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterTest --match-test "SingleExecute_|BatchExecution_AllSucceed|AccountEscrowView_TracksPendingOrders|CommitOrder_DualWritesReservationAndRouterCommittedMarginState"`, `forge test --match-path test/perps/HousePool.t.sol --match-contract HousePoolSeedLifecycleGateTest`, and `forge test --match-path test/perps/PerpInvariant.t.sol --match-test "invariant_PendingKeeperReservesBackedByRouterUsdc|invariant_CommittedMarginOwnershipAccountingConservesQueuedExposure|invariant_GlobalQueueLinksRemainConsistent|invariant_AdversarialRetryableSlippageMissPreservesHeadAndEscrow|invariant_AdversarialBatchProcessingRemainsLive"`.

Review:
- Did one last warning-noise pass on the touched code and tests. Cleaned unused parameters in `src/perps/libraries/MarginClearinghouseAccountingLib.sol`, `src/perps/CfdEngine.sol`, and `src/perps/MarginClearinghouse.sol`; removed an unused local in `test/perps/HousePool.t.sol`; and marked the read-only invariant checks in `test/perps/PerpInvariant.t.sol` as `view` while removing a couple of unused tuple locals there.
- Re-ran the targeted verification command after the cleanup. The compiler now reports `Compiler run successful!` with no warning spam for those targeted suites; only the expected invariant cache notice remains.

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

- [x] Extract one shared post-funding close-settlement planner that both `previewClose()` and live close execution use
- [x] Make the shared planner simulate funding settlement first, including vault cash outflow / clearinghouse margin-credit effects for positive funding and uncovered-funding handling for negative funding
- [x] Rebuild clearinghouse bucket snapshots from the simulated post-funding state for partial closes instead of mutating only `otherLockedMarginUsdc`
- [x] Route both preview and live close loss planning through the rebuilt bucket snapshot so committed-order reservations are excluded consistently and `IncompleteReservationCoverage` cannot appear after a valid preview
- [x] Align preview post-close solvency modeling with live execution by rolling the remaining side exposure onto the preview funding index exactly as `_settleFunding()` does before size reduction finalization
- [x] Include simulated funding payout cash movement in preview solvency deltas so `valid`, `badDebtUsdc`, `effectiveAssetsAfterUsdc`, `triggersDegradedMode`, and `postOpDegradedMode` match live execution for positive-funding partial closes
- [x] Add focused regression tests in `test/perps/CfdEngine.t.sol` for: partial close with committed margin excluded, accrued-funding partial close parity, positive-funding vault cash outflow parity, and preview-invalid/live-revert agreement
- [x] Extend `test/perps/PreviewExecutionDifferential.t.sol` with partial-close cases that compare preview outputs against live execution across negative funding, positive funding, and queued committed-margin scenarios
- [x] Strengthen `test/perps/invariant/PerpPreviewInvariant.t.sol` so partial closes preserve preview/live parity for validity, bad debt, degraded-mode transitions, and reachable collateral accounting under funding accrual
- [x] Update `src/perps/ACCOUNTING_SPEC.md` Unrealized MtM Liability wording to include the collectible side-margin cap before the per-side zero clamp
- [x] Update `src/perps/SECURITY.md` MtM rationale so it matches the current capped-negative-funding code path and no longer describes aggregate-side-margin capping as rejected when that is what the code now does
- [x] Re-run targeted verification: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "PreviewClose_|CloseLoss_|Funding"`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`, `forge test --match-path test/perps/invariant/PerpPreviewInvariant.t.sol`, and any affected audit regression slices

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

- [x] Verify HousePool / TrancheVault audit claims for zero-principal capture, empty-tranche revenue, stale-window accrual, projected-funding views, and withdrawal-cap getters

Review:
- Verified by code inspection plus targeted Forge checks.
- Valid: zero-principal unassigned cash is still capturable by the next junior depositor because `HousePool._reconcile()` / `_previewReconciledWaterfallState()` short-circuit at zero claimed equity while `TrancheVault.totalAssets()` still prices the tranche from `getPendingTrancheState()` as zero.
- Valid: junior revenue can still accrue while junior share supply is zero, creating a positive-principal / zero-supply tranche that later deposits enter at distorted ERC4626 pricing.
- Valid: stale-mark `reconcile()` still leaves `lastReconcileTime` unchanged (`test_M2_StaleReconcileMustNotAdvanceClock` passes), so a later fresh reconcile can backfill elapsed time; the existing stale-yield test only proves no immediate principal mint without revenue.
- Valid: `getPositionView()` / `getAccountLedgerSnapshot()` use stored funding via `getPendingFunding(pos)`, while liquidation preview/live paths first project funding indices in `CfdEnginePlanLib.planGlobalFunding(...)`.
- Valid: `HousePool.getMaxSeniorWithdraw()` / `getMaxJuniorWithdraw()` remain accounting-only and ungated by stale marks or degraded mode, while `TrancheVault.maxWithdraw()` / `maxRedeem()` apply the safer liveness gate.
- Verified green support checks: `forge test --match-path test/perps/CfdEngine.t.sol --match-test test_ClearBadDebt_ReducesOutstandingDebt`, `forge test --match-path test/perps/AuditValidFindingsFailing.t.sol --match-test test_M2_StaleReconcileMustNotAdvanceClock`, and `forge test --match-path test/perps/AuditTightenedFindingsFailing.t.sol --match-test test_L1_StaleIntervalsMustNotAccrueSeniorYield`.

- [x] Add failing regressions for the newly verified HousePool / view-accounting findings (H-01, M-01, L-01, L-02, L-03)

Review:
- Added `test/perps/AuditHousePoolViewFindingsFailing.t.sol` with five focused failing regressions covering: zero-principal junior cash capture, empty-junior revenue assignment, stale reconcile checkpointing, projected-funding drift in simple health views, and ungated HousePool withdrawal-cap getters.
- Verified the new file fails 5/5 on the current branch with the expected signatures: H-01 attacker redemption profits from stranded cash (`1999999999 > 1000000000`), M-01 empty junior still accrues principal (`99086505 != 0`), L-01 stale reconcile leaves `lastReconcileTime` unchanged (`1709532000 != 1712124000`), L-02 position/account views report stored instead of projected funding (`0 != -1643769865`), and L-03 `getMaxSeniorWithdraw()` stays positive while withdrawals are not live (`100000000000 != 0`).
- Verification: `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`.

- [x] Fix HousePool / view-accounting findings (H-01, M-01, L-01, L-02, L-03)

Review:
- Fixed HousePool bootstrap/orphan handling in `src/perps/HousePool.sol`: zero-principal distributable cash is now quarantined in `orphanedJuniorAssets`, first junior deposits sweep that bucket into principal before minting, stale reconciles checkpoint `lastReconcileTime`, and zero-supply junior revenue is redirected into the orphan bucket instead of live principal.
- Fixed view/accounting drift in `src/perps/CfdEngine.sol` by projecting funding in `getPositionView()` and `getAccountLedgerSnapshot()` with the same global-funding planning path used by liquidation previews.
- Fixed withdrawal-cap getters in `src/perps/HousePool.sol` to return zero whenever withdrawals are not live, matching the safer vault-facing behavior.
- Verified green: `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`, `forge test --match-path test/perps/HousePool.t.sol`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClearBadDebt_ReducesOutstandingDebt|test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState|test_GetPositionView_ReturnsLivePositionState"`.

- [x] Redesign HousePool bootstrap/orphan handling to be explicit rather than silently assigning assets to the next LP

Review:
- Strengthened the redesign further by making bootstrap assignment share-backed instead of raw principal mutation: `src/perps/HousePool.sol` now computes pre-bootstrap share issuance, assigns `unassignedAssets` to the chosen tranche, and mints matching shares to the specified receiver through pool-only `bootstrapMint` in `src/perps/TrancheVault.sol`.
- Updated the external surface in `src/perps/interfaces/IHousePool.sol` and added `src/perps/interfaces/ITrancheVaultBootstrap.sol`; the owner path is now `assignUnassignedAssets(bool toSenior, address receiver)` so quarantined value always gets an explicit owner at assignment time.
- Updated the invariant docs in `src/perps/ACCOUNTING_SPEC.md` and added coverage in `test/perps/HousePool.t.sol` plus the audit regression file to verify blocked deposits before bootstrap and share-backed ownership creation during bootstrap.
- Verified green: `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`, `forge test --match-path test/perps/HousePool.t.sol`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClearBadDebt_ReducesOutstandingDebt|test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState|test_GetPositionView_ReturnsLivePositionState"`.

- [x] Start implementing permanent seed-share architecture to reduce ownerless tranche states in steady state

Review:
- Added seed-position infrastructure in `src/perps/HousePool.sol` and `src/perps/TrancheVault.sol`: owner-only `initializeSeedPosition(bool,uint256,address)` seeds a tranche with real USDC, mints share-backed seed ownership, and registers a permanent `seedShareFloor` enforced by the vault.
- Extended `src/perps/interfaces/IHousePool.sol` and `src/perps/interfaces/ITrancheVaultBootstrap.sol`, and updated `src/perps/ACCOUNTING_SPEC.md` to document the preferred steady state: seeded tranches should stay owner-backed so ordinary LP exits do not force value into `unassignedAssets`.
- Added coverage in `test/perps/HousePool.t.sol` for seed initialization, seed-floor enforcement, and the seeded-junior revenue path that keeps normal revenue out of quarantine after the last user LP exits.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_InitializeSeedPosition_MintsPermanentSeedShares|test_SeedReceiverCannotRedeemBelowFloor|test_SeededJuniorRevenueStaysOwnedAfterLastUserExits|test_AssignUnassignedAssets_MintsMatchingSharesToReceiver"`, `forge test --match-path test/perps/HousePool.t.sol`, `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClearBadDebt_ReducesOutstandingDebt|test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState|test_GetPositionView_ReturnsLivePositionState"`.

- [x] Wire seed initialization into the shared perps test setup path

Review:
- Updated `test/perps/BasePerpTest.sol` with optional `_initialJuniorSeedDeposit()`, `_initialSeniorSeedDeposit()`, `_juniorSeedReceiver()`, and `_seniorSeedReceiver()` hooks so canonical perps setup can now seed either tranche before ordinary LP deposits without changing existing tests that leave the hooks at zero.
- Added `HousePoolSeededBaseSetupTest` in `test/perps/HousePool.t.sol` to prove the shared setup path can boot both senior and junior seed positions and register their floors correctly.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_BasePerpTest_CanBootstrapSeededSetup|test_InitializeSeedPosition_MintsPermanentSeedShares|test_SeedReceiverCannotRedeemBelowFloor|test_SeededJuniorRevenueStaysOwnedAfterLastUserExits"`, `forge test --match-path test/perps/HousePool.t.sol`, and `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`.

- [x] Classify known recapitalization inflows so seeded steady state hits `unassignedAssets` less often

Review:
- Added source-aware recap routing in `src/perps/HousePool.sol` via `recordRecapitalizationInflow(uint256)`: engine-owned bad-debt recap now restores seeded senior principal immediately up to the high-water mark, and if seeded senior shares exist with zero live principal it reattaches the recapitalization directly to that claimant set instead of falling back to generic quarantine.
- Updated `src/perps/interfaces/ICfdVault.sol` and switched `src/perps/CfdEngine.sol` `clearBadDebt()` to call the new recap-specific hook instead of generic `recordProtocolInflow()`.
- Added coverage in `test/perps/HousePool.t.sol` for both seeded-senior restoration and the zero-principal-but-seeded-supply case, and updated the invariant mock vault in `test/perps/invariant/mocks/MockInvariantVault.sol` for the extended vault interface.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting|test_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist|test_BasePerpTest_CanBootstrapSeededSetup"`, `forge test --match-path test/perps/HousePool.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test test_ClearBadDebt_ReducesOutstandingDebt`, and `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`.

- [x] Finish the ownership-routing model: classify LP-owned trading inflows, document canonical seed lifecycle, and push `unassignedAssets` toward exceptional-only use

Review:
- Added `recordTradingRevenueInflow(uint256)` to `src/perps/HousePool.sol` and `src/perps/interfaces/ICfdVault.sol`, then switched realized LP-revenue paths in `src/perps/CfdEngine.sol` (trade-cost capture, collectible funding losses, close-loss seizures, liquidation residual seizures) to this hook instead of generic `recordProtocolInflow()`.
- Implemented seeded zero-principal routing in `src/perps/HousePool.sol`: when both tranche principals are zero but seed claimants exist, known LP trading revenue now restores seeded senior up to its HWM first and then attaches residual value to seeded junior, avoiding `unassignedAssets` for these normal economic flows.
- Documented the final model end-to-end in `src/perps/ACCOUNTING_SPEC.md`, including controlled inflow families, canonical deployment lifecycle, and the intended role of `unassignedAssets` as an exceptional fallback rather than a routine state.
- Tightened external documentation in `src/perps/interfaces/IHousePool.sol` to state that canonical deployment should initialize both tranche seeds before ordinary LP operation.
- Added coverage in `test/perps/HousePool.t.sol` for seeded trading revenue attaching directly to junior and for seeded zero-principal waterfall routing across both tranches; updated `test/perps/invariant/mocks/MockInvariantVault.sol` to satisfy the expanded vault interface.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists|test_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero|test_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting|test_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist"`, `forge test --match-path test/perps/HousePool.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClearBadDebt_ReducesOutstandingDebt|test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState|test_GetPositionView_ReturnsLivePositionState"`, and `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`.

- [x] Fix post-review issues in HousePool quarantine and direct-principal accrual handling

Review:
- Fixed withdrawal leakage in `src/perps/HousePool.sol` by reserving `unassignedAssets` inside the pool withdrawal snapshot, making `getFreeUSDC()` / pending tranche caps exclude quarantined assets, and additionally marking withdrawals not live while bootstrap assignment remains pending.
- Fixed retroactive senior-yield accrual in `src/perps/HousePool.sol` by checkpointing the senior-yield clock before every direct principal mutation path (`recordRecapitalizationInflow`, `recordTradingRevenueInflow`, `assignUnassignedAssets`, `initializeSeedPosition`).
- Added regressions in `test/perps/HousePool.t.sol` for both behaviors: quarantined assets no longer appear withdrawable, and seeded principal initialization no longer mints retroactive senior yield after a long idle period.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_UnassignedAssets_AreReservedFromWithdrawalLiquidity|test_InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation|test_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero|test_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting"`, `forge test --match-path test/perps/HousePool.t.sol`, `forge test --match-path test/perps/AuditHousePoolViewFindingsFailing.t.sol`, and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ClearBadDebt_ReducesOutstandingDebt|test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState|test_GetPositionView_ReturnsLivePositionState"`.

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

## Margin Unlock Sequencing Fix (Mar 19 2026)

- [x] Reproduce and document the valid-open / zero-free-settlement failure path
- [x] Reorder `applyOpenCost()` so negative net margin changes unlock before fee debit checks
- [x] Add regression coverage for execution success and keeper-bounty preservation
- [x] Run targeted perps verification and record results

Review:
- Updated `src/perps/MarginClearinghouse.sol` so `applyOpenCost()` now computes `netMarginChangeUsdc` first, credits rebates, unlocks negative position-margin deltas before checking free settlement, then debits positive trade costs and locks any positive residual margin.
- Added a direct primitive regression in `test/perps/MarginClearinghouse.t.sol` proving a zero-free-settlement account can still pay open trade costs out of unlocked active position margin.
- Added an end-to-end router regression in `test/perps/OrderRouter.t.sol` proving a valid increase order with zero free settlement at execution still fills and still pays the reserved execution bounty to the keeper.
- Verified green: `forge test --match-path test/perps/MarginClearinghouse.t.sol --match-test "test_ApplyOpenCost_"` and `forge test --match-path test/perps/OrderRouter.t.sol --match-contract OrderRouterTest --match-test "test_IncreaseOrder_UsesUnlockedPositionMarginToPayTradeCost"`.

## TrancheVault Preview Parity Fix (Mar 19 2026)

- [x] Add read-only HousePool helpers that simulate reconciled tranche principals and withdrawal caps
- [x] Update `TrancheVault` preview/max paths to consume reconciled view state instead of stale stored principals
- [x] Add regressions covering previewDeposit/maxWithdraw parity against live reconcile-first execution
- [x] Run targeted HousePool/TrancheVault verification and record results

Review:
- Added `IHousePool.getPendingTrancheState()` plus a `HousePool` view-only reconcile preview that simulates pending senior/junior principals and tranche withdrawal caps without mutating storage.
- Updated `src/perps/TrancheVault.sol` so `totalAssets()`, `maxWithdraw()`, and `maxRedeem()` all consume the simulated reconcile-first tranche state, aligning ERC4626 preview/max behavior with the live deposit/withdraw paths that call `POOL.reconcile()` first.
- Added regressions in `test/perps/HousePool.t.sol` proving `previewDeposit()` matches reconcile-first share minting for senior deposits and that `maxWithdraw()` remains executable after junior loss reconciliation.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_SeniorPreviewDeposit_MatchesReconcileFirstDeposit|test_JuniorMaxWithdraw_MatchesReconcileFirstWithdraw"`.

## TrancheVault Funding Snapshot Parity Fix (Mar 19 2026)

- [x] Project pending funding in `CfdEngine` house-pool view snapshots
- [x] Route `HousePool`/`TrancheVault` max-withdraw previews through projected funding liabilities
- [x] Add regressions for `maxWithdraw()` / `maxRedeem()` under accrued funding
- [x] Run targeted verification and record results

Review:
- Updated `src/perps/CfdEngine.sol` so house-pool view snapshots now project pending funding indices from `lastFundingTime` to `block.timestamp` using the same `PositionRiskAccountingLib.computeFundingStep()` math as plan-time previews before building withdrawal-funding and MtM liabilities.
- This preserves the earlier `HousePool.getPendingTrancheState()`/`TrancheVault.maxWithdraw()` architecture while removing the remaining stale-funding gap that could cause `maxWithdraw()`/`maxRedeem()` to overestimate executable liquidity.
- Added regressions in `test/perps/HousePool.t.sol` proving both `maxWithdraw()` and `maxRedeem()` remain executable during frozen-oracle windows with unsynced accrued funding.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_MaxWithdraw_RemainsExecutableWithPendingFundingAccrual|test_MaxRedeem_RemainsExecutableWithPendingFundingAccrual|test_JuniorMaxWithdraw_MatchesReconcileFirstWithdraw|test_SeniorPreviewDeposit_MatchesReconcileFirstDeposit"`.

## Liquidation Escrow Funding Ordering Fix (Mar 19 2026)

- [x] Sync funding before router-forfeited escrow mutates vault assets during liquidation
- [x] Keep router protocol-fee bookkeeping side-effect free after cash transfer
- [x] Add regression proving forfeited escrow cannot retroactively soften elapsed funding
- [x] Run targeted liquidation/funding verification and record results

Review:
- Updated `src/perps/OrderRouter.sol` so liquidation forfeiture now calls `engine.syncFunding()` before transferring escrowed bounty USDC into the vault and recognizing it as canonical inflow.
- Updated `src/perps/CfdEngine.sol` so `recordRouterProtocolFee()` is now pure post-transfer bookkeeping and no longer re-syncs funding against already-mutated vault depth.
- Added a liquidation regression in `test/perps/OrderRouter.t.sol` that records logs and proves `FundingUpdated` fires before `ProtocolInflowAccounted` when queued execution escrow is forfeited during liquidation, preventing retroactive depth softening for the elapsed funding interval.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_ExecuteLiquidation_ForfeitsEscrowedOpenBountiesWithoutCreditingTraderSettlement|test_ExecuteLiquidation_ForfeitedEscrowDoesNotRetroactivelySoftenFunding|test_ExecuteLiquidation_ForfeitsEscrowedCloseBountiesBeforeClearingOrders"`.
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

- [x] Verify the new external audit report finding-by-finding against current perps code
- [x] Run or inspect focused evidence for each claimed issue and note whether it is live, fixed, or invalid
- [x] Record a concise verdict with supporting file references and any follow-up verification gaps

Review:
- Re-verified the six findings in the latest “Plether Perpetuals Engine” audit draft against current `src/perps` code and focused Forge coverage.
- Confirmed one live bug: frozen-oracle order execution still disables MEV publish-time checks in `src/perps/libraries/OrderOraclePolicyLib.sol`, and `test_CloseOrderExecutesAtStaleFridayPrice` still passes in `test/perps/OrderRouter.t.sol`.
- Confirmed two formerly valid blocker findings are fixed on this branch: partial-close committed-margin accounting now routes through shared bucket planning, and close commits now require upfront bounty backing instead of relying on deferred close-bounty behavior.
- Confirmed the senior-tranche dust deadlock remains live in `src/perps/HousePool.sol` because only exact-zero principal resets the high-water mark; any `0 < seniorPrincipal < seniorHighWaterMark` still reverts deposits.
- Informational notes are accurate and already documented/tested: the VPI zero-floor tradeoff is explicit in `src/perps/libraries/CloseAccountingLib.sol`, and `src/perps/TrancheVault.sol` still lets a third party reset cooldown with a meaningful top-up.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CloseOrderExecutesAtStaleFridayPrice|test_SundayDst_MevEnforcedAt21"` and `forge test --match-path test/perps/AuditBlockingAccountingFindingsFailing.t.sol --match-test "test_H1_PartialCloseWithPendingOrderDoesNotRevert|test_H1_PartialCloseLossConsumesCommittedMarginReservation|test_H2_FullyUtilizedTraderCanSubmitAndExecuteCloseOrder"`.
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
- [x] Refactor close preview/live post-settlement and solvency wiring into a shared planner or builder
- [x] Centralize oracle freeze / market-closed calendar logic shared by `CfdEngine` and `OrderRouter`
- [x] Evaluate local deduplication of `OrderRouter` queue unlink helpers without obscuring invariants
- [x] Leave tranche senior/junior branching mostly explicit unless a tiny helper clearly improves readability
- [x] After each refactor slice, run the narrowest affected Forge suites plus a final `test/perps/*.t.sol` pass

Review:
- Evaluated deduplication for `OrderRouter` queue link/unlink helpers. Due to the lack of generic pointers in Solidity, sharing the logic would require either wrapping pointers in generic `Node` arrays (which obscures memory layout) or adding branchy `if (isPendingQueue)` logic inside the helper, which hides invariants. Decided to leave `_unlinkPendingOrder` and `_unlinkMarginOrder` explicitly separated as they are small and clearly readable.
- Left tranche senior/junior branching explicit in `HousePool` and `TrancheVault` because the logic is intentional and cleanly readable without over-abstraction.
- Final full suite run executed across all refactor slices.

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
- [x] Fix frozen-window close liveness in `OrderRouter` / `OrderOraclePolicyLib`
- [x] Introduce canonical accounted depth in `HousePool` and route `CfdEngine` funding/accounting reads through it
- [x] Add typed failure classification and bounty routing in `OrderRouter`
- [x] Sweep remaining funding-sync gaps and add regression coverage

## Perps Architecture Remediation Plan (Mar 19 2026)

### Phase 1 - Frozen-window close liveness

- [x] Inspect `OrderOraclePolicyLib.getOracleExecutionPolicy()` and `OrderRouter` MEV enforcement call sites
- [x] Disable publish-time MEV ordering checks when execution is allowed under frozen-oracle close-only policy
- [x] Add/update targeted regressions proving frozen-window close orders execute while opens remain blocked
- [x] Verify with focused Forge runs for frozen-oracle and Sunday boundary execution paths

Review:
- Updated `src/perps/libraries/OrderOraclePolicyLib.sol` so `OrderExecution` keeps MEV checks active in live/FAD execution but disables them during `oracleFrozen` close-only windows, preserving relaxed frozen-window close liveness without changing staleness bounds.
- Updated `test/perps/OrderRouter.t.sol` frozen-window regressions so close orders committed during the freeze now execute successfully instead of expecting `OrderRouter__MevDetected`.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_FadWindow_(CloseOrder_AllowedDuringFrozenWithPreFreezeCommit|OpenOrder_BlockedDuringFrozen|MevCheckDisabledDuringFrozen|ExcessStaleness_CloseGracefullyCancelled)|test_CloseOrderCommittedDuringFrozenCanUseStaleFridayPrice|test_FadBatch_CloseAllowedDuringFrozenWithPreFreezeCommit|test_FadBatch_ExcessStaleness_FrozenReverts|test_SundayDst_(OracleUnfrozenAt21|MevEnforcedAt21|StillFadAt21|WinterStalenessRejects)"`.
- Verified green: `forge test --match-path test/perps/AuditV2.t.sol --match-test test_C03_CloseOrderBlockedDuringOracleFrozen`, `forge test --match-path test/perps/AuditV3.t.sol --match-test test_C01_CloseOrderBlockedByOpenInFrozenQueue`, and `forge test --match-path test/perps/AuditV3.t.sol --match-test test_C01_OpenOrderHardRevertsInsteadOfSoftFailing`.

### Phase 2 - Canonical accounted depth

- [x] Design a canonical accounted-depth source in `HousePool` that is not rewritten by raw `USDC.balanceOf(address(this))`
- [x] Decide and document unsolicited-transfer handling semantics (`quarantine`, `sweep`, or explicit accounting path)
- [x] Route `CfdEngine` funding depth, house-pool snapshots, and reconcile/withdraw accounting through the canonical depth source
- [x] Add regressions proving unsolicited USDC transfers do not retroactively rewrite elapsed funding economics or LP distributable accounting
- [ ] Update any affected docs/spec text describing vault assets, funding depth, or pool accounting boundaries

Review:
- Added canonical accounted-depth tracking in `src/perps/HousePool.sol` via `accountedAssets` and changed `totalAssets()` to return `min(accountedAssets, rawBalance)`, so unsolicited positive transfers no longer rewrite economic depth while real raw-balance shortfalls still reduce backing.
- Added explicit unsolicited-transfer handling in `src/perps/HousePool.sol`: `accountExcess()` converts quarantined excess into accounted protocol assets after `ENGINE.syncFunding()`, and `sweepExcess()` removes quarantined donations without changing economics.
- Because `ICfdVault.totalAssets()` now represents canonical economic backing, `CfdEngine` and `OrderRouter` automatically consume accounted depth for funding, solvency snapshots, and house-pool accounting while preserving the raw-balance shortfall signal.
- Added regressions in `test/perps/HousePool.t.sol` and `test/perps/CfdEngine.t.sol` proving raw donations stay quarantined until explicitly accounted and that engine protocol snapshots follow canonical assets rather than raw pool balance.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_(RevenueDistribution|RevenueDistribution_SeniorCapped|SeniorRateChange|ShareAccounting_AfterRevenue|SharePrice_NoFreeDilution|UnaccountedDonation_IgnoredUntilExplicitlyAccounted|SweepExcess_RemovesDonationWithoutChangingAccountedAssets|M10_JitLP_BlockedByCooldown|M12_GetFreeUSDC_ReservesFees|SeniorPrincipal_RestoredBeforeJuniorSurplus|Reconcile_AllowsStaleMarkWithoutLiveLiability|FrozenOracle_UsesRelaxedMarkFreshnessForWithdrawals|StaleSharePriceOnDeposit)"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(GetProtocolAccountingView_ReflectsDeferredLiabilities|GetProtocolAccountingSnapshot_ReflectsCanonicalLedgerState|ProtocolAccountingSnapshot_IgnoresUnaccountedPoolDonationUntilAccounted)"`.

### Phase 3 - Typed execution failure and bounty routing

- [x] Enumerate router-visible execution failure classes: user/order fault, oracle/policy fault, and protocol-state-changed-after-commit
- [x] Add typed engine/router signaling so post-commit protocol-state invalidations are distinguishable from clearer-earned failures
- [x] Update `OrderRouter` failed-order bounty policy to refund user bounty for protocol-state invalidations while preserving clearer payout where appropriate
- [x] Add regressions for degraded-mode, skew, and solvency invalidations that arise after a valid commit
- [x] Re-verify batch and single-order execution behavior for the new failure typing

Review:
- Updated `src/perps/OrderRouter.sol` to decode low-level engine revert selectors instead of treating every caught execution failure the same. The router now refunds the user bounty for post-commit protocol-state invalidations on open orders (`CfdEngine__DegradedMode`, `CfdEngine__SkewTooHigh`, `CfdEngine__VaultSolvencyExceeded`) while preserving clearer-paid behavior for ordinary user/order failures.
- Kept the engine execution flow unchanged; the router-side selector classifier is the typed boundary for bounty routing, so no preview/live plan logic changed in `src/perps/CfdEngine.sol`.
- Added focused regressions in `test/perps/OrderRouter.t.sol` covering degraded-mode, skew, and solvency invalidations after a valid commit, plus a batch execution case proving the same refund path is used in `executeOrderBatch()`.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_(PostCommitDegradedModeRefundsUserBounty|PostCommitSkewInvalidationRefundsUserBounty|PostCommitSolvencyInvalidationRefundsUserBounty|BatchPostCommitSkewInvalidationRefundsUserBounty|Slippage_CancelsGracefully|ExitedAccount_ExpiredCloseOrderPaysClearerBounty|ExitedAccount_InvalidCloseOrderPaysEscrowedBounty)"`.

### Phase 4 - Funding-sync completion and hardening

- [x] Audit every vault-cash mutation path and funding-dependent accounting mutation across `HousePool`, `CfdEngine`, and related helpers
- [x] Add missing `syncFunding()` calls to remaining protocol paths such as `HousePool.finalizeSeniorRate()` and `CfdEngine.absorbRouterCancellationFee()`
- [x] Add targeted regressions asserting funding is synced before admin/internal cash mutations and reconcile paths
- [x] Run focused perps suites covering `HousePool`, `CfdEngine`, `OrderRouter`, and audit regression files

Review:
- Added the remaining missing funding syncs in `src/perps/HousePool.sol` and `src/perps/CfdEngine.sol`: `finalizeSeniorRate()` now calls `ENGINE.syncFunding()` before snapshot/reconcile logic, and `absorbRouterCancellationFee()` now calls `_syncFunding()` before moving router-held USDC into the vault.
- Re-swept the main vault-cash mutation and funding-sensitive accounting paths in `HousePool`, `CfdEngine`, and `MarginClearinghouse`; no additional unsynced protocol cash-mutation path in the reviewed scope remains beyond the two fixed entrypoints.
- Added targeted regressions in `test/perps/HousePool.t.sol` and `test/perps/CfdEngine.t.sol` proving these paths advance `lastFundingTime` before doing their accounting/cash mutation.
- Verified green: `forge test --match-path test/perps/HousePool.t.sol --match-test "test_(FinalizeSeniorRate_SyncsFundingBeforeReconcile|FinalizeSeniorRate_StaleMarkAccruesCheckpointedYield|SeniorRateChange)"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(AbsorbRouterCancellationFee_SyncsFundingBeforeVaultCashMutation|FundingAccumulation)"`.

### Verification / exit criteria

- [ ] `forge test --match-path test/perps/OrderRouter.t.sol --match-test "Frozen|Sunday|Mev|CloseOrderCommittedDuringFrozen"`
- [ ] `forge test --match-path test/perps/HousePool.t.sol`
- [ ] `forge test --match-path test/perps/CfdEngine.t.sol --match-test "Funding|HousePoolInputSnapshot|Withdrawal|Absorb|Sync"`
- [ ] `forge test --match-path test/perps/AuditLatest*.t.sol`
- [ ] `forge test --match-path test/perps/AuditRemaining*.t.sol`
- [ ] Update `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` for any behavior/accounting boundary changes

## Perps Preview API Boundary Plan (Mar 21 2026)

- [x] Inspect `src/perps` preview entrypoints and call sites for externally supplied vault-depth inputs
- [x] Split canonical preview APIs from hypothetical simulation APIs so canonical previews read vault depth internally
- [x] Update tests/docs to use the new preview vs simulation boundary and run focused Forge verification

Review:
- Updated `src/perps/CfdEngine.sol` so canonical `previewClose()` and `previewLiquidation()` now source depth from `vault.totalAssets()` internally, while new `simulateClose()` / `simulateLiquidation()` entrypoints own the caller-supplied what-if depth path.
- Updated `src/perps/interfaces/ICfdEngine.sol`, `src/perps/README.md`, and `src/perps/ACCOUNTING_SPEC.md` to make the canonical-preview vs hypothetical-simulation boundary explicit for integrators.
- Repointed perps preview call sites and tests to canonical previews by default, and moved the cash-illiquidity / alternate-depth cases onto explicit simulation coverage in `test/perps/CfdEngine.t.sol`.
- Verified green: `forge fmt --check` on touched files, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(PreviewClose_UsesCanonicalVaultDepthWhileSimulateCloseAllowsWhatIfDepth|PreviewLiquidation_UsesCanonicalVaultDepthWhileSimulateLiquidationAllowsWhatIfDepth|SimulateClose_FullCloseWithPositiveFunding_ShowsDeferredPayoutWhenVaultIlliquid|SimulateClose_PartialCloseWithPositiveFunding_ShowsDeferredPayoutWhenVaultIlliquid|SimulateClose_DeferredFundingCountsTowardPostCloseDegradedMode|LiquidationPreview_InterfaceMatchesContractStructLayout)"`, `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol`, `forge test --match-path test/perps/invariant/PerpPreviewInvariant.t.sol`, and `forge test --match-path test/perps/invariant/PerpClosePreviewParityInvariant.t.sol`.

## Perps Senior Cash Reservation Kernel Plan (Mar 21 2026)

- [x] Inspect fee withdrawal, fresh payout, liquidation bounty, and deferred-claim cash reservation logic for drift
- [x] Implement one canonical senior-cash reservation kernel and route those paths through it
- [x] Update docs/tests and run focused perps verification for the shared reservation policy

Review:
- Expanded `src/perps/libraries/CashPriorityLib.sol` into the canonical senior-cash reservation kernel, with one shared reservation struct covering total senior claims, reserved senior cash, fresh free cash, and queue-head claim serviceability.
- Routed `src/perps/CfdEngine.sol`, `src/perps/OrderRouter.sol`, and `src/perps/libraries/CfdEnginePlanLib.sol` through that shared kernel so fee withdrawal, fresh trader payouts, fresh liquidation bounty payments, deferred-claim servicing, and previews all answer the same cash-priority question.

## Perps Order / Liquidation Hardening Plan (Apr 11 2026)

- [x] Enforce live-market `publishTime > commitTime` ordering in `OrderRouter` while preserving frozen-window relaxations
- [x] Replace liquidation account-order cleanup scans over `1..nextCommitId` with bounded per-account traversal
- [x] Make post-open planner margin validation carry-aware to match live execution state
- [x] Route typed `UserInvalid` execution failures to clearer-paid outcomes
- [x] Prevent terminal-invalid close slippage from refunding margin-backed bounty escrow to trader wallets
- [x] Add focused router/engine regressions and update perps docs for the tightened policy

Review:
- Updated `src/perps/OrderRouter.sol` and `src/perps/modules/OrderEscrowAccounting.sol` to keep a per-account pending-order queue, use that bounded traversal for liquidation cleanup, enforce live-market `oraclePublishTime > order.commitTime`, pay clearers on typed `UserInvalid` engine failures, and stop terminal close slippage from refunding potentially margin-backed escrow to trader wallets.
- Updated `src/perps/libraries/CfdEnginePlanLib.sol` so post-open risk validation now uses carry-aware equity, matching the carry realization that already happens before live open settlement.
- Updated `src/perps/README.md`, `src/perps/SECURITY.md`, and `src/perps/ACCOUNTING_SPEC.md` so the documented MEV ordering, close-failure escrow handling, and bounded liquidation cleanup model match the implementation.
- Verified green: `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_(PublishTimeBeforeCommit_Reverts|FreshPublishAfterCommit_Executes|TypedUserInvalidOpenPaysClearer|CloseSlippageFailPaysClearerWhenBountyIsMarginBacked|ExecuteLiquidation_ClearsOnlyLiquidatedAccountsPendingOrders)"` and `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_ProcessOrderTyped_RevertsWhenTruePostTradeEquityFailsImr"`.
- Full `forge build` in this workspace still exceeded the available tool timeout even after the targeted compile failures were cleared, so verification here is focused rather than repository-wide.

### Follow-up review

- Switched liquidation semantics in `src/perps/libraries/CfdEnginePlanLib.sol` to the `ACCOUNTING_SPEC.md` model: liquidation eligibility, equity, carry base, and keeper-bounty capping now use only physically reachable clearinghouse collateral, while same-account deferred payout is netted exactly once only against terminal liquidation shortfall.
- Updated `test/perps/CfdEngine.t.sol` regressions to prove the new split across both positive and negative liquidation branches: positive physical residual preserves the legacy deferred claim, negative physical residual consumes deferred payout only as shortfall netting, and liquidation eligibility no longer changes when deferred payout is present.
- Added planner-level fuzz regressions in `test/perps/CfdEngine.t.sol` covering nonzero deferred payout across a wide range of settlement reachability and legacy deferred balances in both positive-residual and negative-residual liquidation branches.
- Updated `src/perps/README.md` and `src/perps/SECURITY.md` so the public docs explicitly state that deferred payout does not support liquidation reachability.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test(Fuzz)?_(PlanLiquidation_PositiveResidualPreservesDeferredAndUsesOnlyPhysicalReachability|PlanLiquidation_NegativeResidualNetsDeferredExactlyOnce|PlanLiquidation_PositiveResidualAboveDeferredDoesNotUnderflow|PlanLiquidation_NegativeResidualFullyConsumesLegacyDeferredWithoutReducingBadDebt|LiquidationPreview_DeferredPayout_DoesNotAffectLiquidationEligibility|PreviewLiquidation_PreservesLegacyDeferredOnPositivePhysicalResidual)"`.

### Invariant review

- Re-reviewed `test/perps/invariant/*` for assumptions tied to the old deferred-liquidation model.
- Found one stale assumption in `test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`: liquidation payout gating treated legacy deferred balance as if it were part of the fresh liquidation payout decision.
- Updated that invariant to gate only the fresh liquidation payout (`immediatePayoutUsdc + freshDeferredPayoutUsdc`), while allowing untouched legacy deferred payout to remain alongside an immediate fresh payout.
- Verified green: `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`.

## Canonical Settlement / Carry Hook Refactor (Apr 11 2026)

- [x] Make close execution consume the planner's canonical carry-adjusted loss amount instead of recomputing a raw close loss
- [x] Make liquidation use carry-aware equity for liquidation eligibility, bounty capping, and residual planning
- [x] Add clearinghouse-triggered carry realization hooks before user deposit/withdraw balance mutations
- [x] Add focused regressions for close carry parity, liquidation carry eligibility, and anti-evasion deposit/withdraw carry realization
- [x] Update accounting and security docs for the canonical kernels and clearinghouse carry hooks

Review:
- Added `lossUsdc` to `CloseDelta` and changed `CfdEngineSettlementModule.executeClose()` to consume the planner's canonical carry-adjusted close loss instead of recomputing from raw `closeState.netSettlementUsdc`.
- Changed liquidation planning to use `buildPositionRiskStateWithCarry(...)` and to feed carry-adjusted equity directly into `LiquidationAccountingLib`, so liquidation eligibility, keeper bounty capping, and residual math now share one carry-aware kernel.
- Added `realizeCarryBeforeMarginChange(bytes32)` to the engine core interface and wired `MarginClearinghouse` deposit/withdraw paths through it so user balance mutations realize carry before changing the reachable-collateral basis.
- Updated `README.md`, `SECURITY.md`, and `ACCOUNTING_SPEC.md` to document the canonical close/liquidation kernels and the clearinghouse carry hook behavior.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(DepositWithdrawMargin_RealizesCarryBeforeBalanceMutation|CloseExecution_UsesCarryAdjustedLossKernel|PlanLiquidation_PendingCarryCanTriggerLiquidation|PlanLiquidation_PositiveResidualAboveDeferredDoesNotUnderflow|PlanLiquidation_NegativeResidualFullyConsumesLegacyDeferredWithoutReducingBadDebt|PreviewLiquidation_PreservesLegacyDeferredOnPositivePhysicalResidual)"` and `forge test --match-path test/perps/MarginClearinghouse.t.sol`.
- Full `forge build` still exceeded the 300s tool timeout in this workspace, so repository-wide verification remains incomplete.

### Follow-up cleanup

- Rewrote `OrderRouter._getQueuedPositionView()` to traverse the per-account pending-order queue instead of scanning `1..nextCommitId`, so close-intent validation is now bounded and account-local like liquidation cleanup.
- Updated `_buildPostOpenRiskState()` to credit skew-reducing negative `tradeCostUsdc` into reachable collateral before the IMR check, removing the conservative rebate omission.
- Added partial fee withdrawal support in `CfdEngine.withdrawFees(address,uint256)` while keeping the existing full-withdraw wrapper.
- Updated `README.md`, `SECURITY.md`, and `ACCOUNTING_SPEC.md` to document bounded close projection, rebate-aware open validation, and partial fee withdrawal behavior.
- Verified green: `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(WithdrawFees_AllowsPartialWithdrawal|WithdrawFees_RespectsSeniorCashReservation)"`, `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol --match-test "test_PlanOpen_CreditsNegativeTradeCostIntoReachableCollateral"`, and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitClose_UsesOnlyAccountLocalQueuedPositionProjection"`.

### Broader verification follow-up

- Fixed a preview/live parity leak in `CfdEngineLens` and `CfdEngineAccountLens`: both were rebuilding positions from `engine.positions(...)`, which omits `lastCarryTimestamp`, so carry-aware previews silently zeroed the carry clock while live execution used the real timestamp.
- Added `getPositionLastCarryTimestamp(bytes32)` to `CfdEngine` / `ICfdEngine` and wired both lenses to use it, restoring carry-aware close/liquidation preview parity.
- Updated stale `OrderRouter.t.sol` expectations to the current security model: publish-time MEV ordering remains enforced, terminal close slippage pays the clearer, batch execution stops at publish-time MEV violations, degraded-mode tests use a stable `stdstore` toggle, and rebate-aware open validation now allows rebate-backed commits.
- Verified green broader slice:
  - `forge test --match-path test/perps/CfdEngine.t.sol`
  - `forge test --match-path test/perps/OrderRouter.t.sol`
  - `forge test --match-path test/perps/MarginClearinghouse.t.sol`
  - `forge test --match-path test/perps/CfdEnginePlanRegression.t.sol`
  - `forge test --match-path test/perps/invariant/PerpDeferredPayoutInvariant.t.sol`

## Pre-Audit Clarity Pass (Apr 11 2026)

- [x] Draft one unified pre-audit guide with policy tables, quantity ownership table, liveness-vs-safety choices, read-surface rules, invariants, and test map
- [x] Add explicit close and liquidation transaction narratives
- [x] Cross-link existing perps docs to the pre-audit guide
- [x] Annotate legacy-named shared test helpers so obsolete carry/spread terminology is clearly marked historical
- [x] Improve audit readability of test intent through a grouped test map in docs

Review:
- Added `src/perps/PRE_AUDIT_GUIDE.md` consolidating the order lifecycle state machine, failure-policy table, bounty-flow table, oracle-regime table, quantity ownership table, liveness/safety tradeoffs, close and liquidation narratives, read-surface canonicality rules, invariants, and a high-signal test map.
- Cross-linked `README.md`, `SECURITY.md`, `ACCOUNTING_SPEC.md`, `CANONICAL_ENTRYPOINTS.md`, and `INTERNAL_ARCHITECTURE_MAP.md` to the new pre-audit guide so auditors have one obvious starting point.
- Added explicit historical-context comments to `test/perps/BasePerpTest.sol` legacy helper names so auditors do not mistake them for live accounting concepts.
- This pass intentionally improved test readability through documentation and annotations rather than renaming or moving large test files immediately before audit.

### Carry rescue / public lens follow-up

- Fixed clearinghouse deposit carry realization so rescue top-ups can fund pre-mutation carry in the same transaction: `MarginClearinghouse` now snapshots the pre-mutation reachable-collateral basis, credits the deposit, and then calls `realizeCarryBeforeMarginChange(accountId, basis)` so carry is computed from the old basis but settled from post-deposit cash.
- Updated `CfdEngineAccountLens` to compute `pendingCarryUsdc` and use `buildPositionRiskStateWithCarry(...)`, which makes `PerpsPublicLens.getTraderAccount(...)`, `getPosition(...)`, and `isLiquidatable(...)` inherit carry-aware equity and liquidation state.
- Added focused regressions:
  - `test_DepositMargin_CanRescueAccountWhenIncomingCashCoversCarry`
  - `test_GetTraderAccount_UsesCarryAwareNetEquity`
  - `test_IsLiquidatable_UsesCarryAwareLensState`
- Verified green:
  - `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(DepositMargin_CanRescueAccountWhenIncomingCashCoversCarry|DepositWithdrawMargin_RealizesCarryBeforeBalanceMutation)"`
  - `forge test --match-path test/perps/PerpsPublicLens.t.sol`
  - `forge test --match-path test/perps/MarginClearinghouse.t.sol`
- Added regression coverage in `test/perps/CfdEngine.t.sol` and `test/perps/CashPriorityLib.t.sol` for fee-withdrawal reservation, queue-head priority under partial liquidity, and the pure reservation math.
- Verified green: `forge fmt --check src/perps/CfdEngine.sol src/perps/OrderRouter.sol src/perps/libraries/CashPriorityLib.sol src/perps/libraries/CfdEnginePlanLib.sol src/perps/README.md src/perps/ACCOUNTING_SPEC.md test/perps/CfdEngine.t.sol test/perps/CashPriorityLib.t.sol`, `forge test --match-path test/perps/CashPriorityLib.t.sol`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(ClaimDeferredPayout_HeadConsumesPartialLiquidityBeforeLaterClaims|WithdrawFees_RespectsSeniorCashReservation|ClaimDeferredPayout_AllowsPartialHeadClaimWhenLiquidityReturnsGradually|DeferredClearerBounty_Lifecycle|GetDeferredPayoutStatus_OnlyExposesHeadClaim)"`, and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_ExecuteLiquidation_ForfeitsEscrowedOpenBountiesWithoutCreditingTraderSettlement"`.
- [x] Thread negative accrued VPI into liquidation shortfall planning
- [x] Add a liquidation regression for depth-manipulated VPI rebate stranding
- [x] Update perps docs to reflect liquidation VPI clawback semantics

Review:
- Updated `src/perps/libraries/CfdEnginePlanLib.sol` so liquidations now convert negative stored `vpiAccrued` into a liquidation-only clawback by reducing liquidation equity before keeper-bounty and residual planning. This prevents rebate debt from being stranded when a position is deleted through liquidation.
- Updated `src/perps/CfdEngineLens.sol` so liquidation preview equity now reports the clawback-adjusted liquidation equity used by the planner, keeping preview/live semantics aligned.
- Added `test_PlanLiquidation_ClawsBackNegativeAccruedVpiIntoBadDebt()` plus a small planner harness extension in `test/perps/CfdEngine.t.sol` to pin the exact bad-debt delta from negative accrued VPI.
- Added `test_Liquidation_ClawsBackDepthManipulatedVpiRebate_EndToEnd()` in `test/perps/CfdEngine.t.sol`, which uses real junior-vault depth inflation/withdrawal, opens the rebate-bearing skew-healing leg at the manipulated shallow depth, withdraws the attacker’s headroom, and proves the subsequent live liquidation includes the stored negative VPI in liquidation equity and bad debt.
- Updated `src/perps/README.md`, `src/perps/ACCOUNTING_SPEC.md`, and `src/perps/SECURITY.md` so the audit packet now describes the liquidation-time VPI clawback accurately.
- Verified green with `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_PlanLiquidation_ClawsBackNegativeAccruedVpiIntoBadDebt|test_Liquidation_ClawsBackDepthManipulatedVpiRebate_EndToEnd|test_LiquidationPreviewAndPositionView_UseCurrentNotionalThreshold|testFuzz_PlanLiquidation_NegativeResidualNetsDeferredExactlyOnce|testFuzz_PlanLiquidation_PositiveResidualPreservesDeferredAndUsesOnlyPhysicalReachability"` and `forge test --match-path test/perps/PreviewExecutionDifferential.t.sol --match-test "testFuzz_PreviewLiquidation_MatchesLiveExecution_LiquidVault|testFuzz_PreviewLiquidation_MatchesLiveExecution_IlliquidVault"`.
- [x] Route batched successful orders through executed finalization
- [x] Add regression for successful batched order terminal status

Review:
- Updated `src/perps/modules/OrderExecutionOrchestrator.sol` so `_finalizeOrCleanupOrder` now branches on `success` rather than `refundEthNow`. Successful batch executions now consume escrow with `success = true`, delete the order with `OrderStatus.Executed`, and only gate the ETH refund transfer on `refundEthNow`.
- Strengthened `test_BatchExecution_AllSucceed()` in `test/perps/OrderRouter.t.sol` to assert all successfully batched orders end in `OrderStatus.Executed`.
- Added `test_BatchExecution_SuccessfulOrdersEndExecuted()` in `test/perps/OrderRouter.t.sol` to pin the terminal executed status and cleared margin/bounty escrow for successful batched orders.
- Verified green with `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_(StateMachine_BatchClearsSlippageFailedHeadAndContinues|BatchExecution_AllSucceed|BatchExecution_SuccessfulOrdersEndExecuted|BatchExecution_MixedResults|OrderRecord_PreservesExecutedLifecycle)"`.
- [x] Preserve deferred-claim carry basis during stale windows
- [x] Simulate live carry realization in withdrawable lens
- [x] Remove engine/router freshness drift on keeper credit finalization
- [x] Add regressions for stale deferred claims, withdrawable parity, and staleness drift

Review:
- Updated `src/perps/CfdEngine.sol` so deferred payout and deferred keeper-credit claims now checkpoint carry against the cached mark even when the live mark is stale, preserving the basis-change invariant without blocking already-owed claims.
- Removed the redundant staleness gate from `creditKeeperExecutionBounty()` in `src/perps/CfdEngine.sol` so router-validated executions/refunds/liquidation payouts cannot roll back later during settlement credit finalization due to stricter engine-side freshness policy.
- Updated `src/perps/CfdEngineAccountLens.sol` so `getWithdrawableUsdc()` now simulates the same carry-realization loss consumption as the live withdraw path before computing post-carry free settlement and IMR headroom.
- Added stale-window deferred-claim regressions in `test/perps/CfdEngine.t.sol` for both trader deferred payouts and deferred keeper credits, proving cached-mark carry checkpointing still occurs before settlement credit.
- Added `test_GetTraderAccount_WithdrawableMatchesLiveCarryRealizationSequence()` in `test/perps/PerpsPublicLens.t.sol` to pin the account/public-lens withdrawable amount against the actual live withdraw sequence under material carry drag.
- Added router freshness regressions in `test/perps/OrderRouter.t.sol` and `test/perps/OrderRouterPolicyMatrix.t.sol` showing router-validated refund/credit flows complete even when the engine helper would previously have considered the publish time stale.
- Verified green with:
- `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_(ClaimDeferredPayout_UsesCachedMarkToCheckpointCarryWhenStale|ClaimDeferredKeeperCredit_UsesCachedMarkToCheckpointCarryWhenStale|ClaimDeferredPayout_RealizesCarryBeforeCreditingSettlement|ClaimDeferredKeeperCredit_RealizesCarryBeforeCreditingSettlement)"`
- `forge test --match-path test/perps/PerpsPublicLens.t.sol --match-test "test_(GetTraderAccount_WithdrawableMatchesLiveCarryRealizationSequence|GetTraderAccount_WithdrawableIncludesUnsettledCarryParity)"`
- `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_(OrderRefund_DoesNotRevertWhenRouterLimitExceedsEngineHelperLimit|OrderExecution_UsesRouterExecutionStalenessLimit_NotPoolMarkLimit)"`
- `forge test --match-path test/perps/OrderRouterPolicyMatrix.t.sol --match-test "test_(CreditKeeperExecutionBounty_RealizesCarryBeforeCreditingSettlement|CreditKeeperExecutionBounty_UsesCachedMarkWhenCurrentMarkIsStale|OpenRefundRealizesTraderCarryBeforeCreditingSettlement)"`
- [x] Collapse HousePool claimant inflow API into one entrypoint
- [x] Migrate engine and settlement modules to claimant inflow enums
- [x] Update HousePool/docs/tests for the simplified inflow surface

Review:
- Replaced the old dual claimant-owned inflow surface in `src/perps/interfaces/ICfdVault.sol` (`recordRecapitalizationInflow`, `routeLpValue`, `LpValueMode`) with one explicit `recordClaimantInflow(amount, kind, cashMode)` API and the new `ClaimantInflowKind` / `ClaimantInflowCashMode` enums.
- Updated `src/perps/HousePool.sol` so claimant-owned value now enters through one function while preserving the existing economics: `Revenue` still only queues `pendingTradingRevenueUsdc` when no live claimants exist, `Recapitalization` still queues `pendingRecapitalizationUsdc`, and only `CashArrived` increments `accountedAssets`.
- Migrated all live callers in `src/perps/CfdEngine.sol` and `src/perps/CfdEngineSettlementModule.sol` to the new surface, leaving `recordProtocolInflow(...)` as the only separate protocol-owned inflow concept.
- Updated the invariant mock vault plus the HousePool/audit tests to use the new claimant-inflow enums, keeping recap/revenue semantics explicit without exposing routing mechanics as a first-class API.
- Updated `src/perps/README.md`, `PRE_AUDIT_GUIDE.md`, `INTERNAL_ARCHITECTURE_MAP.md`, and `ACCOUNTING_SPEC.md` so the documentation now describes the simplified inflow model consistently.
- Verified green with `forge test --match-path test/perps/HousePool.t.sol --match-test "test_(RecordImplicitTradingRevenue_RestoresSeededSeniorBeforeJuniorWhenBothAreZero|Reconcile_RestoresSeededClaimantsBeforeUnassignedWhenClaimedEquityZero|SeniorPrincipal_RestoredBeforeJuniorSurplus)"`, `forge test --match-path test/perps/CfdEngine.t.sol --match-test "test_Liquidation_ClawsBackDepthManipulatedVpiRebate_EndToEnd"`, and `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_(OrderRefund_DoesNotRevertWhenRouterLimitExceedsEngineHelperLimit|BatchExecution_SuccessfulOrdersEndExecuted)"`.
- [x] Start `OrderRouter` size reduction by extracting shared oracle execution prep into `OrderOracleExecution`

Review:
- Extracted the repeated order-execution, mark-refresh, and liquidation oracle-preparation boilerplate into `src/perps/modules/OrderOracleExecution.sol` via `_prepareOrderExecutionOracle(...)`, `_prepareMarkRefreshOracle(...)`, and `_prepareLiquidationOracle(...)`.
- Slimmed `src/perps/OrderRouter.sol` so the four entrypoints now delegate their oracle resolution, staleness validation, mark monotonicity checks, CAP clamping, and mark updates to the module before continuing with queue/liquidation orchestration.
- Verified green with `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_BatchExecution_MixedResults|test_BasketPrice_RevertsWhenFeedPublishTimesDivergeTooFar|test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse|test_ExecuteLiquidation_DefersKeeperCreditPerPreviewWhenVaultPayoutFails"`.
- Measured `OrderRouter` deployed runtime size at `27,342` bytes via `forge inspect src/perps/OrderRouter.sol:OrderRouter deployedBytecode`, down slightly from the prior `27,386`-byte baseline. This confirms the abstraction is behavior-safe but that the next meaningful reduction likely requires moving heavier oracle/runtime code across a real external call boundary rather than just inherited internal helpers.
- [x] Start `commitOrder` runtime-size reduction in `OrderRouter`

Review:
- Tightened `src/perps/OrderRouter.sol`'s `commitOrder(...)` without changing its external surface: the open path now computes the commit reference price once and reuses it for both the predictable-open prefilter and the open-order bounty quote.
- Folded the pending-order cap check into the final `pendingOrderCounts[accountId]` increment, removing the separate precheck branch while preserving revert semantics via full-transaction rollback.
- Verified green with `forge test --match-path test/perps/OrderRouter.t.sol --match-test "test_CommitOrder_RevertsWhenPendingOrderCountHitsCap|test_CommitOrder_RevertsOnPredictableInsufficientInitialMargin|test_CommitOrder_RevertsOnPredictableMustCloseOpposing|test_CommitOrder_RevertsOnPredictablePositionTooSmall|test_CommitOrder_DoesNotUseStaleCachedMarkForPredictableOpenPrefilter|test_CommitOrder_RevertsOnPredictableSkewInvalidation|test_CommitOrder_RevertsOnPredictableSolvencyInvalidation"`.
- Measured `OrderRouter` deployed runtime size at `27,304` bytes via `forge inspect src/perps/OrderRouter.sol:OrderRouter deployedBytecode`, down `38` bytes from the prior `27,342`-byte baseline. `commitOrder` is therefore a real but weak size lever compared with the remaining larger targets.
- [ ] Add a dedicated perps pauser role to `OrderRouter` and `HousePool`
- [ ] Cover pauser assignment and pause authorization with focused Forge tests
- [ ] Update perps admin docs/interfaces for the new emergency role split
- [x] Add a dedicated perps pauser role to `OrderRouter` and `HousePool`
- [x] Cover pauser assignment and pause authorization with focused Forge tests
- [x] Update perps admin docs/interfaces for the new emergency role split

Review:
- Added owner-assigned `pauser` storage, `setPauser(...)`, and `onlyPauserOrOwner` pause gating to `src/perps/OrderRouter.sol` and `src/perps/HousePool.sol`, while keeping `unpause()` owner-only.
- Extended `src/perps/interfaces/IPerpsAdmin.sol` and the perps docs so the emergency-role split is explicit: owner assigns the pauser, both owner and pauser can trigger `pause()`, and only owner can resume.
- Verified green with `forge test --match-path test/perps/TimelockPause.t.sol`.

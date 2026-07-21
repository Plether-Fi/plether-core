// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEngineSettlementLib} from "@plether/perps/libraries/CfdEngineSettlementLib.sol";
import {CloseAccountingLib} from "@plether/perps/libraries/CloseAccountingLib.sol";
import {LiquidationAccountingLib} from "@plether/perps/libraries/LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "@plether/perps/libraries/OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @title CfdEnginePlanTypes
/// @notice Snapshot and delta structs for the plan→apply architecture.
/// @dev Plan functions are pure over a `RawSnapshot` and return typed deltas. Apply functions consume deltas to
///      perform state mutations and external calls. Unless stated otherwise, USDC amounts use 6 decimals, prices use
///      8 decimals, position sizes and open interest use 18 decimals, basis-point values use a 10,000 denominator,
///      and timestamps are Unix seconds.
library CfdEnginePlanTypes {

    /// @notice Failure-lifecycle classification used by router open-order policy.
    enum OpenFailurePolicyCategory {
        /// @notice The plan succeeded or the code has no open-failure policy.
        None,
        /// @notice Current inputs or state allow the router to reject the order at commit time.
        CommitTimeRejectable,
        /// @notice Execution failed because the user's order or collateral became invalid.
        ExecutionTimeUserInvalid,
        /// @notice Execution failed because protocol state changed after commitment.
        ExecutionTimeProtocolStateInvalidated
    }

    /// @notice Router classification for a failure discovered during execution.
    enum ExecutionFailurePolicyCategory {
        /// @notice The plan succeeded and no failure policy applies.
        None,
        /// @notice The order is invalid because of user-controlled inputs or collateral.
        UserInvalid,
        /// @notice The order was invalidated by changed protocol state.
        ProtocolStateInvalidated
    }

    // ──────────────────────────────────────────────
    //  SNAPSHOT (input to all plan functions)
    // ──────────────────────────────────────────────

    /// @notice Aggregate planning state for one position side.
    /// @param maxProfitUsdc Maximum-profit liability envelope for the side.
    /// @param openInterest Aggregate synthetic-token size, with 18 decimals.
    /// @param entryNotional Aggregate raw `size * entryPrice` value, with 26 decimals.
    /// @param totalMargin Aggregate canonical position margin for the side.
    /// @param borrowBaseUsdc Aggregate LP-backed amount on which side carry accrues.
    /// @param carryIndex Current cumulative carry index, scaled by 1e18.
    struct SideSnapshot {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
        uint256 borrowBaseUsdc;
        uint256 carryIndex;
    }

    /// @notice Complete read-only engine input supplied to a planner call.
    /// @dev Some context fields are retained for plan/apply parity even when the current planner does not read them.
    ///      Callers must construct a mutually consistent snapshot; the planner does not authenticate or reload it.
    /// @param position Account's current canonical position.
    /// @param account Clearinghouse account whose collateral and claims are represented.
    /// @param currentTimestamp Snapshot timestamp in Unix seconds; retained as context but currently not read by plans.
    /// @param lastMarkPrice Latest stored mark price; retained as context but currently not read by plans.
    /// @param lastMarkTime Latest stored mark publish time; retained as context but currently not read by plans.
    /// @param positionBorrowBaseUsdc Position carry borrow base.
    /// @param positionLastCarryIndex Side carry index last checkpointed for the position, scaled by 1e18.
    /// @param bullSide Aggregate BULL-side state.
    /// @param bearSide Aggregate BEAR-side state.
    /// @param poolAssetsUsdc Planner pool-depth/physical-asset input used for VPI, skew, and close/liquidation solvency.
    /// @param poolCashUsdc Physical-asset basis for open solvency and cash available for payouts and fee top-ups.
    /// @param accountBuckets Aggregate clearinghouse custody buckets for `account`.
    /// @param lockedBuckets Typed clearinghouse margin buckets for `account`.
    /// @param marginReservationIds Reserved legacy context; canonical builders leave it empty and plans do not read it.
    /// @param accumulatedBadDebtUsdc Protocol bad debt at snapshot time; diagnostic context not read by current plans.
    /// @param unsettledCarryUsdc Carry already checkpointed but not yet realized for `account`.
    /// @param totalTraderClaimBalanceUsdc Aggregate outstanding trader-claim liability.
    /// @param traderClaimBalanceForAccount Outstanding trader claim owned by `account`.
    /// @param degradedMode Whether the engine was already in degraded mode.
    /// @param capPrice Maximum execution and risk price, with 8 decimals.
    /// @param riskParams Risk, carry, VPI, and bounty parameters.
    /// @param executionFeeBps Execution fee charged on trade notional, in basis points.
    /// @param isFadWindow Whether FAD margin policy is active.
    /// @param oracleFrozen Whether frozen-market close-spread policy is active.
    /// @param frozenCloseSpreadBps Spread charged on oracle-frozen close notional, in basis points.
    struct RawSnapshot {
        CfdTypes.Position position;
        address account;

        uint256 currentTimestamp;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;
        uint256 positionBorrowBaseUsdc;
        uint256 positionLastCarryIndex;

        SideSnapshot bullSide;
        SideSnapshot bearSide;

        uint256 poolAssetsUsdc;
        uint256 poolCashUsdc;

        IMarginClearinghouse.AccountUsdcBuckets accountBuckets;
        IMarginClearinghouse.LockedMarginBuckets lockedBuckets;

        uint64[] marginReservationIds;

        uint256 accumulatedBadDebtUsdc;
        uint256 unsettledCarryUsdc;
        uint256 totalTraderClaimBalanceUsdc;
        uint256 traderClaimBalanceForAccount;
        bool degradedMode;

        uint256 capPrice;
        CfdTypes.RiskParams riskParams;
        uint256 executionFeeBps;
        bool isFadWindow;
        bool oracleFrozen;
        uint256 frozenCloseSpreadBps;
    }

    /// @notice Projected protocol solvency state after a close or liquidation.
    /// @param effectiveAssetsAfterUsdc Physical assets after planned cash flow, net of trader claims.
    /// @param maxLiabilityAfterUsdc Maximum remaining side-liability envelope.
    /// @param triggersDegradedMode Whether this operation newly crosses into degraded mode.
    /// @param postOpDegradedMode Whether projected effective assets are below projected maximum liability.
    struct SolvencyPreview {
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
    }

    // ──────────────────────────────────────────────
    //  OPEN DELTA
    // ──────────────────────────────────────────────

    /// @notice Typed business-rule result returned by open/increase planning.
    enum OpenRevertCode {
        /// @notice Planning completed successfully.
        OK,
        /// @notice The account has a position on the opposite side and must close it first.
        MUST_CLOSE_OPPOSING,
        /// @notice New exposure is disabled because the engine is in degraded mode.
        DEGRADED_MODE,
        /// @notice Resulting notional cannot support the configured minimum liquidation bounty.
        POSITION_TOO_SMALL,
        /// @notice Post-trade side skew exceeds the configured pool-relative limit.
        SKEW_TOO_HIGH,
        /// @notice Carry, settlement debits, or planned margin locking/unlocking exceed eligible account collateral.
        MARGIN_DRAINED_BY_FEES,
        /// @notice Post-trade position margin or equity fails the initial-margin and liquidation checks.
        INSUFFICIENT_INITIAL_MARGIN,
        /// @notice Projected effective solvency assets fall below the maximum liability envelope.
        SOLVENCY_EXCEEDED
    }

    /// @notice Planned open/increase result and all values needed by the settlement sidecar.
    /// @dev On failure, `valid` is false and fields populated before the failing check remain diagnostic only.
    /// @param valid Whether all planning checks passed.
    /// @param revertCode Typed failure code, or `OK` on success.
    /// @param openState Detailed notional, VPI, fee, margin-requirement, and entry-price calculation.
    /// @param posSide Side of the resulting position.
    /// @param newPosSize Resulting position size, with 18 decimals.
    /// @param newPosEntryPrice Resulting volume-weighted entry price, with 8 decimals.
    /// @param posVpiAccruedDelta Signed 6-decimal USDC VPI added to accrual; positive is a charge, negative a rebate.
    /// @param posMaxProfitIncrease Increase in the position maximum-profit envelope, in 6-decimal USDC.
    /// @param positionMarginAfterOpen Resulting clearinghouse position-margin bucket in 6-decimal USDC.
    /// @param sideOiIncrease Increase in aggregate side open interest, with 18 decimals.
    /// @param sideEntryNotionalDelta Signed change in raw side `size * entryPrice`, with 26 decimals.
    /// @param sideEntryCarryContribution Reserved diagnostic field; current planning sets zero and apply does not use it.
    /// @param sideMaxProfitIncrease Increase in the aggregate side maximum-profit envelope, in 6-decimal USDC.
    /// @param tradeCostUsdc Signed VPI plus execution fee; positive debits the account and negative rebates it.
    /// @param marginDeltaUsdc Order margin supplied for the open/increase.
    /// @param netMarginChange Signed 6-decimal USDC `marginDeltaUsdc - tradeCostUsdc` position-margin change.
    /// @param poolRebatePayoutUsdc Pool-funded cash needed when `tradeCostUsdc` is negative.
    /// @param executionFeeUsdc Execution fee included in `tradeCostUsdc`.
    /// @param pendingCarryUsdc Total checkpointed and indexed carry to realize before opening.
    /// @param sideTotalMarginBefore Aggregate selected-side margin after carry and before the open, in 6-decimal USDC.
    /// @param sideTotalMarginAfterOpen Projected aggregate selected-side margin, in 6-decimal USDC.
    /// @param account Account copied from the order and mutated during settlement.
    /// @param sizeDelta Order size increase, with 18 decimals.
    /// @param price Execution price capped at `RawSnapshot.capPrice`, with 8 decimals.
    struct OpenDelta {
        bool valid;
        OpenRevertCode revertCode;

        OpenAccountingLib.OpenState openState;

        CfdTypes.Side posSide;
        uint256 newPosSize;
        uint256 newPosEntryPrice;
        int256 posVpiAccruedDelta;
        uint256 posMaxProfitIncrease;
        uint256 positionMarginAfterOpen;

        uint256 sideOiIncrease;
        int256 sideEntryNotionalDelta;
        int256 sideEntryCarryContribution;
        uint256 sideMaxProfitIncrease;

        int256 tradeCostUsdc;
        uint256 marginDeltaUsdc;
        int256 netMarginChange;
        uint256 poolRebatePayoutUsdc;

        uint256 executionFeeUsdc;
        uint256 pendingCarryUsdc;

        uint256 sideTotalMarginBefore;
        uint256 sideTotalMarginAfterOpen;

        address account;
        uint256 sizeDelta;
        uint256 price;
    }

    // ──────────────────────────────────────────────
    //  CLOSE DELTA
    // ──────────────────────────────────────────────

    /// @notice Typed business-rule result returned by close/decrease planning.
    enum CloseRevertCode {
        /// @notice Planning completed successfully.
        OK,
        /// @notice Requested close size exceeds the snapshot position size.
        CLOSE_SIZE_EXCEEDS,
        /// @notice A partial close would leave less margin than the configured minimum bounty.
        DUST_POSITION,
        /// @notice A partial close has an uncollectible loss while position margin must remain locked.
        PARTIAL_CLOSE_UNDERWATER
    }

    /// @notice Sign of the close settlement after realized PnL, VPI, fees, spread, and pending carry.
    enum SettlementType {
        /// @notice Net settlement is exactly zero.
        ZERO,
        /// @notice The close creates value payable to the trader.
        GAIN,
        /// @notice The close requires collateral collection from the trader.
        LOSS
    }

    /// @notice Planned close/decrease result and all values needed by the settlement sidecar.
    /// @dev On failure, `valid` is false and fields populated before the failing check remain diagnostic only.
    /// @param valid Whether all planning checks passed.
    /// @param revertCode Typed failure code, or `OK` on success.
    /// @param closeState Detailed PnL, VPI, fee, spread, released-margin, and remaining-position calculation.
    /// @param postBullOi Projected BULL open interest, with 18 decimals.
    /// @param postBearOi Projected BEAR open interest, with 18 decimals.
    /// @param posMarginAfter Canonical position margin remaining after the close, in 6-decimal USDC.
    /// @param posSizeDelta Position size removed, with 18 decimals.
    /// @param posMaxProfitReduction Reduction in the position maximum-profit envelope, in 6-decimal USDC.
    /// @param posVpiAccruedReduction Signed proportional lifetime VPI removed, in 6-decimal USDC.
    /// @param deletePosition Whether settlement removes the entire position.
    /// @param side Side of the position being reduced.
    /// @param sideOiDecrease Reduction in aggregate side open interest, with 18 decimals.
    /// @param sideEntryNotionalReduction Reduction in raw side `size * entryPrice`, with 26 decimals.
    /// @param sideMaxProfitReduction Reduction in aggregate side maximum-profit envelope, in 6-decimal USDC.
    /// @param unlockMarginUsdc Proportional position margin unlocked before settlement collection.
    /// @param settlementType Sign of carry-adjusted net settlement.
    /// @param lossUsdc Magnitude to collect when `settlementType` is `LOSS`; otherwise zero.
    /// @param freshTraderPayoutUsdc New trader value created by a `GAIN`; zero for other settlement types.
    /// @param freshPayoutIsImmediate `GAIN`-only forecast that unreserved pool cash can service the fresh payout.
    /// @param freshPayoutCreatesClaim `GAIN`-only forecast that the fresh payout remains a trader-claim liability.
    /// @param existingTraderClaimConsumedUsdc `LOSS`-only existing claim value netted against collection shortfall.
    /// @param existingTraderClaimRemainingUsdc `LOSS`-only account claim remaining after netting; otherwise default zero.
    /// @param traderClaimFeeRecoveryUsdc `LOSS`-only consumed claim allocated to an uncollected execution fee.
    /// @param lossResult `LOSS`-only seized collateral, fee collection, shortfall, and pre-netting bad-debt breakdown.
    /// @param lossConsumption `LOSS`-only clearinghouse buckets consumed to collect the close loss.
    /// @param syncMarginQueueAmount `LOSS`-only other locked margin consumed; nonzero requests router queue sync.
    /// @param executionFeeUsdc Fee included in close economics; for a loss it is limited to retained, collected, and
    ///        claim-recovered amounts.
    /// @param protocolFeeTopUpUsdc Additional unreserved pool cash planned for the protocol treasury fee credit.
    /// @param badDebtUsdc Loss still uncovered after collateral and existing-claim netting.
    /// @param pendingCarryUsdc Total checkpointed and indexed carry included in close settlement.
    /// @param totalMarginBefore Aggregate selected-side position margin before the close, in 6-decimal USDC.
    /// @param totalMarginAfterClose Projected aggregate selected-side margin after the close, in 6-decimal USDC.
    /// @param solvency Projected post-close solvency and degraded-mode flags.
    /// @param account Account copied from the order and mutated during settlement.
    /// @param sizeDelta Requested size reduction, with 18 decimals.
    /// @param price Execution price capped at `RawSnapshot.capPrice`, with 8 decimals.
    /// @param realizedPnlUsdc Signed realized price PnL before VPI, fee, spread, and carry.
    struct CloseDelta {
        bool valid;
        CloseRevertCode revertCode;

        CloseAccountingLib.CloseState closeState;
        uint256 postBullOi;
        uint256 postBearOi;

        uint256 posMarginAfter;
        uint256 posSizeDelta;
        uint256 posMaxProfitReduction;
        int256 posVpiAccruedReduction;
        bool deletePosition;

        CfdTypes.Side side;
        uint256 sideOiDecrease;
        uint256 sideEntryNotionalReduction;
        uint256 sideMaxProfitReduction;

        uint256 unlockMarginUsdc;

        SettlementType settlementType;
        uint256 lossUsdc;

        uint256 freshTraderPayoutUsdc;
        bool freshPayoutIsImmediate;
        bool freshPayoutCreatesClaim;
        uint256 existingTraderClaimConsumedUsdc;
        uint256 existingTraderClaimRemainingUsdc;
        uint256 traderClaimFeeRecoveryUsdc;

        CfdEngineSettlementLib.CloseSettlementResult lossResult;
        MarginClearinghouseAccountingLib.SettlementConsumption lossConsumption;
        uint256 syncMarginQueueAmount;

        uint256 executionFeeUsdc;
        uint256 protocolFeeTopUpUsdc;
        uint256 badDebtUsdc;
        uint256 pendingCarryUsdc;

        uint256 totalMarginBefore;
        uint256 totalMarginAfterClose;

        SolvencyPreview solvency;

        address account;
        uint256 sizeDelta;
        uint256 price;
        int256 realizedPnlUsdc;
    }

    // ──────────────────────────────────────────────
    //  LIQUIDATION DELTA
    // ──────────────────────────────────────────────

    /// @notice Planned full-position liquidation and all values needed by the settlement sidecar.
    /// @dev When `liquidatable` is false, only pre-check diagnostic fields are authoritative.
    /// @param liquidatable Whether equity is at or below the active maintenance/FAD requirement.
    /// @param riskState Price PnL, carry-adjusted equity, notional, margin requirement, and liquidation test.
    /// @param liquidationState Liquidation equity and keeper-bounty calculation.
    /// @param side Side of the position being liquidated.
    /// @param posSize Full position size removed, with 18 decimals.
    /// @param posMargin Canonical position margin before liquidation, in 6-decimal USDC.
    /// @param posMaxProfit Position maximum-profit envelope removed from aggregate liability, in 6-decimal USDC.
    /// @param posEntryPrice Position entry price, with 8 decimals.
    /// @param sideOiDecrease Reduction in aggregate side open interest, with 18 decimals.
    /// @param sideMaxProfitDecrease Reduction in aggregate side maximum-profit envelope, in 6-decimal USDC.
    /// @param sideEntryNotionalReduction Reduction in raw side `size * entryPrice`, with 26 decimals.
    /// @param sideTotalMarginReduction Diagnostic 6-decimal USDC margin reduction; current apply uses `posMargin` instead.
    /// @param keeperBountyUsdc Bounty credited to the keeper through clearinghouse settlement.
    /// @param liquidationReachableCollateralUsdc Terminal account settlement reachable before keeper bounty and settlement.
    /// @param residualUsdc Signed 6-decimal USDC liquidation equity remaining after the keeper bounty.
    /// @param residualPlan Clearinghouse mutation plan whose nested bad debt is the raw negative residual before keeper-
    ///        subsidy adjustment and existing-claim recovery; final recognized debt is `badDebtUsdc`.
    /// @param settlementRetainedUsdc Existing account settlement retained to satisfy positive residual equity.
    /// @param freshTraderPayoutUsdc Positive residual equity not already present in retained settlement.
    /// @param freshPayoutIsImmediate Whether current unreserved pool cash can service the fresh payout.
    /// @param freshPayoutCreatesClaim Whether the fresh payout is expected to remain a trader-claim liability.
    /// @param existingTraderClaimConsumedUsdc Existing claim value netted against liquidation bad debt.
    /// @param existingTraderClaimRemainingUsdc Account claim balance remaining after planned netting.
    /// @param syncMarginQueueAmount Other locked margin unlocked; a nonzero value requests router queue sync.
    /// @param badDebtUsdc Liquidation loss still uncovered after existing-claim netting.
    /// @param pendingCarryUsdc Total checkpointed and indexed carry included in liquidation equity.
    /// @param solvency Projected post-liquidation solvency and degraded-mode flags.
    /// @param account Account copied from the snapshot and liquidated during settlement.
    /// @param price Liquidation price capped at `RawSnapshot.capPrice`, with 8 decimals.
    struct LiquidationDelta {
        bool liquidatable;

        PositionRiskAccountingLib.PositionRiskState riskState;
        LiquidationAccountingLib.LiquidationState liquidationState;

        CfdTypes.Side side;
        uint256 posSize;
        uint256 posMargin;
        uint256 posMaxProfit;
        uint256 posEntryPrice;

        uint256 sideOiDecrease;
        uint256 sideMaxProfitDecrease;
        uint256 sideEntryNotionalReduction;
        uint256 sideTotalMarginReduction;

        uint256 keeperBountyUsdc;
        uint256 liquidationReachableCollateralUsdc;

        int256 residualUsdc;
        MarginClearinghouseAccountingLib.LiquidationResidualPlan residualPlan;

        uint256 settlementRetainedUsdc;
        uint256 freshTraderPayoutUsdc;
        bool freshPayoutIsImmediate;
        bool freshPayoutCreatesClaim;
        uint256 existingTraderClaimConsumedUsdc;
        uint256 existingTraderClaimRemainingUsdc;

        uint256 syncMarginQueueAmount;

        uint256 badDebtUsdc;
        uint256 pendingCarryUsdc;

        SolvencyPreview solvency;

        address account;
        uint256 price;
    }

}

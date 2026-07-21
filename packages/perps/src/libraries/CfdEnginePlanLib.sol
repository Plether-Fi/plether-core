// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";
import {CfdEngineSettlementLib} from "@plether/perps/libraries/CfdEngineSettlementLib.sol";
import {CloseAccountingLib} from "@plether/perps/libraries/CloseAccountingLib.sol";
import {LiquidationAccountingLib} from "@plether/perps/libraries/LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "@plether/perps/libraries/OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";

/// @title CfdEnginePlanLib
/// @notice Pure accounting and validation plans for the CfdEngine plan-to-apply architecture.
/// @dev The primary planners consume a caller-built `RawSnapshot` and return typed deltas for a separate settlement
///      sidecar to apply. No function authenticates snapshots, reads storage, or makes external calls. Unless noted,
///      USDC uses 6 decimals, prices use 8 decimals, sizes/open interest use 18 decimals, raw entry notional uses
///      26 decimals, ratios use 1e18 WAD, rates use a 10,000 basis-point denominator, and timestamps use Unix seconds.
library CfdEnginePlanLib {

    /// @notice Returns the collateral clawback associated with a negative lifetime VPI accrual.
    /// @dev This parity helper is currently not called by the primary planners; risk-state construction performs the
    ///      same calculation in `PositionRiskAccountingLib`. Negating `type(int256).min` reverts.
    /// @param vpiAccrued Signed lifetime VPI; negative values represent trader rebates.
    /// @return Magnitude of negative VPI, or zero for nonnegative VPI.
    function _liquidationVpiClawbackUsdc(
        int256 vpiAccrued
    ) private pure returns (uint256) {
        return vpiAccrued < 0 ? uint256(-vpiAccrued) : 0;
    }

    // ──────────────────────────────────────────────
    //  HELPERS
    // ──────────────────────────────────────────────

    /// @notice Applies a signed net change to position margin and reports whether it would go below zero.
    /// @dev Exactly zero is not considered drained. Inputs must be within the supported signed range; the explicit
    ///      unsigned-to-signed conversion otherwise follows Solidity's fixed-width conversion semantics.
    /// @param marginAfterCarry Position margin after carry realization.
    /// @param netMarginChange Signed margin change; positive adds margin and negative removes it.
    /// @return drained Whether the mathematical result is negative.
    /// @return marginAfter Updated margin, or zero when drained.
    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) internal pure returns (bool drained, uint256 marginAfter) {
        int256 computedMarginAfterSigned = int256(marginAfterCarry) + netMarginChange;
        if (computedMarginAfterSigned < 0) {
            return (true, 0);
        }
        return (false, uint256(computedMarginAfterSigned));
    }

    /// @notice Replaces one position's post-carry margin inside its aggregate side-margin total.
    /// @dev Computes `sideTotalMarginAfterCarry + positionMarginAfterOpen - effectivePositionMarginAfterCarry` using
    ///      signed intermediates. Callers must maintain a nonnegative aggregate result and values representable as
    ///      signed 256-bit integers; inconsistent inputs can wrap on explicit conversion to `uint256`.
    /// @param sideTotalMarginAfterCarry Aggregate selected-side margin after carry realization.
    /// @param effectivePositionMarginAfterCarry The account position's contribution contained in that aggregate.
    /// @param positionMarginAfterOpen Replacement contribution after the open/increase.
    /// @return sideTotalMarginAfterOpen Updated aggregate selected-side margin.
    function computeSideTotalMarginAfterOpen(
        uint256 sideTotalMarginAfterCarry,
        uint256 effectivePositionMarginAfterCarry,
        uint256 positionMarginAfterOpen
    ) internal pure returns (uint256 sideTotalMarginAfterOpen) {
        return uint256(
            int256(sideTotalMarginAfterCarry) + int256(positionMarginAfterOpen)
                - int256(effectivePositionMarginAfterCarry)
        );
    }

    /// @notice Classifies an open planner result for commit-time and execution-time order policy.
    /// @dev Opposing-side, too-small, skew, initial-margin, and solvency failures are commit-time rejectable. Degraded
    ///      mode is an execution-time protocol-state invalidation; fee-drained margin is execution-time user invalid.
    /// @param code Open planner result code.
    /// @return Policy category, or `None` for `OK` and unrecognized/default cases.
    function getOpenFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal pure returns (CfdEnginePlanTypes.OpenFailurePolicyCategory) {
        if (
            code == CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
                || code == CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL
                || code == CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH
                || code == CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN
                || code == CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED
        ) {
            return CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable;
        }

        if (code == CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE) {
            return CfdEnginePlanTypes.OpenFailurePolicyCategory.ExecutionTimeProtocolStateInvalidated;
        }

        if (code == CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES) {
            return CfdEnginePlanTypes.OpenFailurePolicyCategory.ExecutionTimeUserInvalid;
        }

        return CfdEnginePlanTypes.OpenFailurePolicyCategory.None;
    }

    /// @notice Classifies an open failure discovered during delayed-order execution.
    /// @dev Degraded mode, skew, and solvency failures are protocol-state invalidations. Every other non-OK open code
    ///      is classified as user invalid.
    /// @param code Open planner result code.
    /// @return Execution failure policy category.
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        if (code == CfdEnginePlanTypes.OpenRevertCode.OK) {
            return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None;
        }

        if (
            code == CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE
                || code == CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH
                || code == CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED
        ) {
            return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated;
        }

        return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid;
    }

    /// @notice Classifies a close failure discovered during delayed-order execution.
    /// @dev Every current non-OK close code is user invalid; only `OK` maps to `None`.
    /// @param code Close planner result code.
    /// @return Execution failure policy category.
    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None;
        }

        return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid;
    }

    /// @notice Selects the snapshot for `side` and the snapshot for the opposing side.
    /// @param snap Complete planner snapshot.
    /// @param side Side to select.
    /// @return selected Snapshot for `side`.
    /// @return opposite Snapshot for the other side.
    function _selectedAndOpposite(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side
    )
        private
        pure
        returns (CfdEnginePlanTypes.SideSnapshot memory selected, CfdEnginePlanTypes.SideSnapshot memory opposite)
    {
        if (side == CfdTypes.Side.BULL) {
            selected = snap.bullSide;
            opposite = snap.bearSide;
        } else {
            selected = snap.bearSide;
            opposite = snap.bullSide;
        }
    }

    /// @notice Selects one aggregate side snapshot.
    /// @param snap Complete planner snapshot.
    /// @param side Side to select.
    /// @return selected BULL snapshot for `BULL`, otherwise BEAR snapshot.
    function _selectedSide(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side
    ) private pure returns (CfdEnginePlanTypes.SideSnapshot memory selected) {
        selected = side == CfdTypes.Side.BULL ? snap.bullSide : snap.bearSide;
    }

    /// @notice Computes all carry currently payable by the snapshot position.
    /// @dev Starts with checkpointed `unsettledCarryUsdc`. Indexed carry is added only for a nonzero position and borrow
    ///      base whose selected-side carry index exceeds the position checkpoint. Index conversion rounds down.
    /// @param snap Position, side-index, borrow-base, and unsettled-carry snapshot.
    /// @return Pending carry in 6-decimal USDC.
    function _pendingCarryUsdc(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) private pure returns (uint256) {
        if (snap.position.size == 0 || snap.positionBorrowBaseUsdc == 0) {
            return snap.unsettledCarryUsdc;
        }
        CfdEnginePlanTypes.SideSnapshot memory side = _selectedSide(snap, snap.position.side);
        if (side.carryIndex <= snap.positionLastCarryIndex) {
            return snap.unsettledCarryUsdc;
        }
        return snap.unsettledCarryUsdc
            + PositionRiskAccountingLib.computeIndexedCarryUsdc(
            snap.positionBorrowBaseUsdc, side.carryIndex - snap.positionLastCarryIndex
        );
    }

    /// @notice Computes absolute directional open-interest skew at a price.
    /// @dev Each side is independently converted from size to USDC with floor division before taking the difference.
    /// @param bull BULL aggregate side snapshot.
    /// @param bear BEAR aggregate side snapshot.
    /// @param price Price used to value both sides.
    /// @return Absolute BULL-versus-BEAR skew in 6-decimal USDC.
    function _absSkewUsdc(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear,
        uint256 price
    ) private pure returns (uint256) {
        uint256 bullUsdc = (bull.openInterest * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bear.openInterest * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

    /// @notice Computes absolute skew after adding an order's size to one side.
    /// @dev Each post-trade side notional is independently rounded down to USDC before taking the difference.
    /// @param bull BULL aggregate state before the open.
    /// @param bear BEAR aggregate state before the open.
    /// @param side Side receiving the size increase.
    /// @param sizeDelta Size added to the selected side.
    /// @param price Price used to value open interest.
    /// @return Post-open absolute skew in 6-decimal USDC.
    function _postOpenSkewUsdc(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 price
    ) private pure returns (uint256) {
        uint256 bullOi = bull.openInterest;
        uint256 bearOi = bear.openInterest;
        if (side == CfdTypes.Side.BULL) {
            bullOi += sizeDelta;
        } else {
            bearOi += sizeDelta;
        }
        uint256 postBullUsdc = (bullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (bearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;
    }

    /// @notice Computes absolute skew from explicit BULL and BEAR open-interest values.
    /// @dev Each side is independently rounded down to USDC before taking the difference.
    /// @param bullOi BULL open interest, with 18 decimals.
    /// @param bearOi BEAR open interest, with 18 decimals.
    /// @param price Price used to value both sides, with 8 decimals.
    /// @return Absolute directional skew in 6-decimal USDC.
    function _skewUsdc(
        uint256 bullOi,
        uint256 bearOi,
        uint256 price
    ) private pure returns (uint256) {
        uint256 bullUsdc = (bullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

    /// @notice Plans use of an account's existing trader claim against settlement shortfall.
    /// @dev Normally claim consumption is capped by shortfall and reduces bad debt one-for-one. When
    ///      `shortfallAlreadyIncludesTraderClaim` is true, the entire claim is marked consumed, the supplied shortfall
    ///      is left unchanged as bad debt, and no amount remains; this mode assumes upstream shortfall already netted
    ///      the claim. A zero claim returns zero remaining balance and treats all shortfall as bad debt.
    /// @param traderClaimBalanceUsdc Existing claim owned by the settling account.
    /// @param shortfallUsdc Settlement amount not covered by reachable collateral.
    /// @param shortfallAlreadyIncludesTraderClaim Whether shortfall was computed after incorporating the full claim.
    /// @return consumedUsdc Existing claim consumed by settlement.
    /// @return remainingUsdc Existing claim left after settlement.
    /// @return badDebtUsdc Shortfall classified as bad debt after the selected claim treatment.
    function _planTraderClaimConsumption(
        uint256 traderClaimBalanceUsdc,
        uint256 shortfallUsdc,
        bool shortfallAlreadyIncludesTraderClaim
    ) private pure returns (uint256 consumedUsdc, uint256 remainingUsdc, uint256 badDebtUsdc) {
        if (traderClaimBalanceUsdc == 0) {
            return (0, 0, shortfallUsdc);
        }

        if (shortfallAlreadyIncludesTraderClaim) {
            return (traderClaimBalanceUsdc, 0, shortfallUsdc);
        }

        consumedUsdc = traderClaimBalanceUsdc < shortfallUsdc ? traderClaimBalanceUsdc : shortfallUsdc;
        remainingUsdc = traderClaimBalanceUsdc - consumedUsdc;
        badDebtUsdc = shortfallUsdc - consumedUsdc;
    }

    /// @notice Allocates an existing trader claim against a close-loss shortfall, fee recovery first.
    /// @dev Claim consumption is capped by `lossResult.shortfallUsdc`. Consumed value first recovers the gross execution
    ///      fee not already retained or collected, then reduces base-loss bad debt; any remainder corresponds to other
    ///      non-bad-debt shortfall such as frozen spread. If claim or shortfall is zero, no claim is consumed. The loss
    ///      result must have been derived from the same gross execution fee so retained plus collected fee cannot exceed it.
    /// @param traderClaimBalanceUsdc Existing claim owned by the closing account.
    /// @param lossResult Collateral collection and charge allocation before claim netting.
    /// @param executionFeeUsdc Gross close execution fee before recovery constraints.
    /// @return consumedUsdc Existing claim consumed against total shortfall.
    /// @return remainingUsdc Existing claim remaining after netting.
    /// @return feeRecoveredUsdc Consumed claim allocated to uncollected execution fee.
    /// @return badDebtUsdc Base bad debt remaining after claim recovery.
    function _planCloseTraderClaimConsumption(
        uint256 traderClaimBalanceUsdc,
        CfdEngineSettlementLib.CloseSettlementResult memory lossResult,
        uint256 executionFeeUsdc
    )
        private
        pure
        returns (uint256 consumedUsdc, uint256 remainingUsdc, uint256 feeRecoveredUsdc, uint256 badDebtUsdc)
    {
        if (traderClaimBalanceUsdc == 0 || lossResult.shortfallUsdc == 0) {
            return (0, traderClaimBalanceUsdc, 0, lossResult.badDebtUsdc);
        }

        consumedUsdc =
            traderClaimBalanceUsdc < lossResult.shortfallUsdc ? traderClaimBalanceUsdc : lossResult.shortfallUsdc;
        remainingUsdc = traderClaimBalanceUsdc - consumedUsdc;

        uint256 uncollectedExecFeeUsdc =
            executionFeeUsdc - lossResult.retainedExecFeeUsdc - lossResult.collectedExecFeeUsdc;
        feeRecoveredUsdc = consumedUsdc < uncollectedExecFeeUsdc ? consumedUsdc : uncollectedExecFeeUsdc;

        uint256 recoveryRemainingUsdc = consumedUsdc - feeRecoveredUsdc;
        uint256 badDebtRecoveredUsdc =
            recoveryRemainingUsdc < lossResult.badDebtUsdc ? recoveryRemainingUsdc : lossResult.badDebtUsdc;
        badDebtUsdc = lossResult.badDebtUsdc > badDebtRecoveredUsdc ? lossResult.badDebtUsdc - badDebtRecoveredUsdc : 0;
    }

    // ──────────────────────────────────────────────
    //  PLAN OPEN
    // ──────────────────────────────────────────────

    /// @notice Plans an open or same-side increase from a complete engine snapshot.
    /// @dev Execution price is capped by `snap.capPrice`. For a live position, pending carry is first projected into a
    ///      memory copy of the snapshot and must be fully collectible; a zero-size position skips that realization even
    ///      if an inconsistent snapshot supplies unsettled carry. The planner then rejects an opposing live position,
    ///      degraded mode, a position too small to support the minimum bounty, insufficient clearinghouse funds,
    ///      post-operation insolvency, insufficient initial margin/equity, or pool-relative skew above the configured
    ///      maximum. The ratio-based skew check is skipped when pool assets are zero. On a
    ///      business-rule failure `valid` remains false, `revertCode` identifies the first failed check, and previously
    ///      populated fields are diagnostic only. VPI, notional, fee, margin, and skew-ratio divisions round down in
    ///      their respective calculations. `publishTime` is retained for planner-interface parity but is not read.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param order Open/increase order; account, side, size, and margin are consumed by this planner.
    /// @param executionPrice Oracle execution price before the protocol cap.
    /// @param publishTime Oracle publish timestamp; currently unused by pure planning.
    /// @return delta Complete open mutation plan or the first typed failure result.
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        CfdEnginePlanTypes.RawSnapshot memory effectiveSnap = snap;
        delta.account = order.account;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        delta.posSide = order.side;
        publishTime;
        delta.pendingCarryUsdc = _pendingCarryUsdc(effectiveSnap);

        if (_applyPendingCarryRealizationToOpenSnapshot(effectiveSnap, delta.pendingCarryUsdc)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
            return delta;
        }

        if (effectiveSnap.position.size > 0 && effectiveSnap.position.side != order.side) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING;
            return delta;
        }

        if (effectiveSnap.degradedMode) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE;
            return delta;
        }

        CfdEnginePlanTypes.SideSnapshot memory bull = effectiveSnap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = effectiveSnap.bearSide;
        delta.sideTotalMarginBefore = order.side == CfdTypes.Side.BULL ? bull.totalMargin : bear.totalMargin;

        uint256 preSkewUsdc = _absSkewUsdc(bull, bear, price);
        uint256 postSkewUsdc = _postOpenSkewUsdc(bull, bear, order.side, order.sizeDelta, price);

        OpenAccountingLib.OpenState memory openState = OpenAccountingLib.buildOpenState(
            OpenAccountingLib.OpenInputs({
                currentSize: snap.position.size,
                currentEntryPrice: snap.position.entryPrice,
                side: order.side,
                sizeDelta: order.sizeDelta,
                price: price,
                capPrice: effectiveSnap.capPrice,
                preSkewUsdc: preSkewUsdc,
                postSkewUsdc: postSkewUsdc,
                poolDepthUsdc: effectiveSnap.poolAssetsUsdc,
                executionFeeBps: effectiveSnap.executionFeeBps,
                riskParams: effectiveSnap.riskParams
            })
        );
        delta.openState = openState;

        uint256 resultingNotionalUsdc = (openState.newSize * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        if (
            resultingNotionalUsdc * effectiveSnap.riskParams.bountyBps < effectiveSnap.riskParams.minBountyUsdc * 10_000
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL;
            return delta;
        }

        delta.tradeCostUsdc = openState.tradeCostUsdc;
        delta.marginDeltaUsdc = order.marginDelta;
        delta.netMarginChange = int256(order.marginDelta) - openState.tradeCostUsdc;
        delta.poolRebatePayoutUsdc = openState.tradeCostUsdc < 0 ? uint256(-openState.tradeCostUsdc) : 0;

        MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan =
            MarginClearinghouseAccountingLib.planOpenCostApplication(
                effectiveSnap.accountBuckets, delta.marginDeltaUsdc, delta.tradeCostUsdc
            );
        if (openCostPlan.insufficientFreeEquity || openCostPlan.insufficientPositionMargin) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
            return delta;
        }

        delta.newPosSize = openState.newSize;
        delta.newPosEntryPrice = openState.newEntryPrice;
        delta.posVpiAccruedDelta = openState.vpiUsdc;
        delta.posMaxProfitIncrease = openState.addedMaxProfitUsdc;
        delta.positionMarginAfterOpen = openCostPlan.resultingPositionMarginUsdc;

        delta.sideOiIncrease = order.sizeDelta;
        if (openState.newEntryNotional >= openState.oldEntryNotional) {
            delta.sideEntryNotionalDelta = int256(openState.newEntryNotional - openState.oldEntryNotional);
        } else {
            delta.sideEntryNotionalDelta = -int256(openState.oldEntryNotional - openState.newEntryNotional);
        }
        delta.sideEntryCarryContribution = 0;
        delta.sideMaxProfitIncrease = openState.addedMaxProfitUsdc;

        delta.executionFeeUsdc = openState.executionFeeUsdc;
        delta.sideTotalMarginAfterOpen = computeSideTotalMarginAfterOpen(
            delta.sideTotalMarginBefore, effectiveSnap.position.margin, delta.positionMarginAfterOpen
        );

        if (_isOpenInsolventAfterPlan(effectiveSnap, order.side, delta, bull, bear)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;
            return delta;
        }

        PositionRiskAccountingLib.PositionRiskState memory postOpenRiskState =
            _buildPostOpenRiskState(effectiveSnap, delta);
        if (
            delta.positionMarginAfterOpen < openState.initialMarginRequirementUsdc || postOpenRiskState.liquidatable
                || postOpenRiskState.equityUsdc < int256(openState.initialMarginRequirementUsdc)
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
            return delta;
        }

        if (
            effectiveSnap.poolAssetsUsdc > 0
                && ((postSkewUsdc * CfdMath.WAD) / effectiveSnap.poolAssetsUsdc) > effectiveSnap.riskParams.maxSkewRatio
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
            return delta;
        }

        delta.valid = true;
    }

    /// @notice Projects collectible pending carry into a memory snapshot before open validation.
    /// @dev Does nothing for zero carry or a zero-size position. Carry is collected from free settlement then active
    ///      position margin; any uncovered amount returns `true` without mutation. On full coverage, the helper debits
    ///      settlement, active/canonical position margin, and aggregate side margin, credits pool assets and cash by
    ///      the full carry amount, and rebuilds account buckets. It does not clear carry checkpoint fields because this
    ///      is only a projection. Snapshot consistency must ensure settlement, position-margin, canonical-margin, and
    ///      aggregate-side subtractions are all valid.
    /// @param snap Memory snapshot to mutate in place.
    /// @param pendingCarryUsdc Carry requested for realization.
    /// @return hasShortfall Whether eligible free settlement plus active margin cannot cover all carry.
    function _applyPendingCarryRealizationToOpenSnapshot(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc
    ) private pure returns (bool hasShortfall) {
        if (pendingCarryUsdc == 0 || snap.position.size == 0) {
            return false;
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(snap.accountBuckets, pendingCarryUsdc);
        if (consumption.uncoveredUsdc > 0) {
            return true;
        }

        uint256 settlementBalanceUsdc = snap.accountBuckets.settlementBalanceUsdc - consumption.totalConsumedUsdc;
        snap.lockedBuckets.positionMarginUsdc -= consumption.activeMarginConsumedUsdc;
        snap.position.margin -= consumption.activeMarginConsumedUsdc;
        snap.poolAssetsUsdc += pendingCarryUsdc;
        snap.poolCashUsdc += pendingCarryUsdc;

        snap.accountBuckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            settlementBalanceUsdc,
            snap.lockedBuckets.positionMarginUsdc,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.lockedBuckets.reservedSettlementUsdc
        );

        if (snap.position.side == CfdTypes.Side.BULL) {
            snap.bullSide.totalMargin -= consumption.activeMarginConsumedUsdc;
        } else {
            snap.bearSide.totalMargin -= consumption.activeMarginConsumedUsdc;
        }

        return false;
    }

    /// @notice Builds risk state for the position projected by a successful open-cost plan.
    /// @dev Canonical position margin excludes any negative-trade-cost rebate. Reachable collateral is computed from
    ///      the already carry-adjusted snapshot and then reduced by a positive trade cost or increased by a rebate;
    ///      it is not otherwise changed for lock reclassification. No pending carry is passed to risk construction:
    ///      live-position carry was projected earlier, while carry on an inconsistent zero-size snapshot is ignored.
    ///      The active threshold is FAD margin during the FAD window and maintenance margin otherwise.
    /// @param snap Carry-adjusted snapshot before applying the new open.
    /// @param delta Partially built open delta containing resulting position and trade-cost values.
    /// @return riskState Projected PnL, equity, notional, threshold, and liquidation status.
    function _buildPostOpenRiskState(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure returns (PositionRiskAccountingLib.PositionRiskState memory riskState) {
        CfdTypes.Position memory projectedPosition = snap.position;
        projectedPosition.side = delta.posSide;
        projectedPosition.size = delta.newPosSize;
        projectedPosition.margin =
            OpenAccountingLib.effectiveMarginAfterTradeCost(delta.positionMarginAfterOpen, delta.tradeCostUsdc);
        projectedPosition.entryPrice = delta.newPosEntryPrice;
        projectedPosition.vpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;

        uint256 reachableCollateralUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(snap.accountBuckets);
        if (delta.tradeCostUsdc > 0) {
            uint256 tradeCostUsdc = uint256(delta.tradeCostUsdc);
            reachableCollateralUsdc =
                reachableCollateralUsdc > tradeCostUsdc ? reachableCollateralUsdc - tradeCostUsdc : 0;
        } else if (delta.tradeCostUsdc < 0) {
            reachableCollateralUsdc += uint256(-delta.tradeCostUsdc);
        }

        riskState = PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            projectedPosition,
            delta.price,
            snap.capPrice,
            0,
            reachableCollateralUsdc,
            snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps
        );
    }

    /// @notice Tests whether a planned open would leave effective pool assets below maximum directional liability.
    /// @dev The selected side copies are increased by the delta. Current assets use `snap.poolCashUsdc`; the physical
    ///      asset delta is trade cost net of execution fee, so only VPI enters pool assets. Trader claims and pending
    ///      payouts are unchanged. This helper returns the strict projected insolvency comparison and does not mutate
    ///      storage. It does mutate the supplied memory side views (and any memory aliases) while projecting the result.
    /// @param snap Current pool, claim, degradation, and side-liability snapshot.
    /// @param side Side receiving the open/increase.
    /// @param delta Partially built open delta with side and economic changes.
    /// @param bull BULL side copy after any projected pending-carry realization.
    /// @param bear BEAR side copy after any projected pending-carry realization.
    /// @return Whether projected effective assets are strictly below projected maximum liability.
    function _isOpenInsolventAfterPlan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side,
        CfdEnginePlanTypes.OpenDelta memory delta,
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear
    ) private pure returns (bool) {
        if (side == CfdTypes.Side.BULL) {
            bull.openInterest += delta.sideOiIncrease;
            bull.maxProfitUsdc += delta.sideMaxProfitIncrease;
            bull.totalMargin = delta.sideTotalMarginAfterOpen;
        } else {
            bear.openInterest += delta.sideOiIncrease;
            bear.maxProfitUsdc += delta.sideMaxProfitIncrease;
            bear.totalMargin = delta.sideTotalMarginAfterOpen;
        }

        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiability(bull.maxProfitUsdc, bear.maxProfitUsdc);

        int256 physicalAssetsDeltaUsdc = delta.tradeCostUsdc - int256(delta.executionFeeUsdc);

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolCashUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalTraderClaimBalanceUsdc
        );
        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDeltaUsdc,
                maxLiabilityAfterUsdc: postMaxLiability,
                traderClaimDeltaUsdc: 0,
                pendingPoolPayoutUsdc: 0
            }),
            snap.degradedMode
        );
        return result.effectiveAssetsAfterUsdc < result.maxLiabilityAfterUsdc;
    }

    // ──────────────────────────────────────────────
    //  PLAN CLOSE
    // ──────────────────────────────────────────────

    /// @notice Plans a full or partial close, including PnL, carry, charges, collection, claims, and solvency.
    /// @dev Execution price is capped by `snap.capPrice`; the live position side is authoritative and `order.side` is
    ///      not read. Carry is deducted from the pre-carry close settlement. A positive result creates an immediate
    ///      payout only when pool cash left after reserving existing aggregate trader claims is sufficient; otherwise
    ///      it creates a new trader claim. A negative result consumes eligible clearinghouse buckets and then the
    ///      account's existing claim. The typed failures are oversized close, remaining-margin dust, and any partial
    ///      close collection shortfall. A valid close may still project degraded mode; solvency is reported rather than
    ///      rejected. Callers must prevalidate a live position and nonzero close size—zero size against a zero-size
    ///      position can reach division by zero instead of a typed failure. Close proration, notional, VPI, fee, and
    ///      spread calculations use integer division with the rounding described by `CloseAccountingLib`.
    ///      `publishTime` is currently unused.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param order Close order; account and size are consumed, while side is taken from `snap.position`.
    /// @param executionPrice Oracle execution price before the protocol cap.
    /// @param publishTime Oracle publish timestamp; retained for interface parity and currently unused.
    /// @return delta Complete close mutation and solvency plan or the first typed failure result.
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.account = order.account;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        publishTime;
        delta.pendingCarryUsdc = _pendingCarryUsdc(snap);

        CfdTypes.Position memory pos = snap.position;
        delta.side = pos.side;

        if (pos.size < order.sizeDelta) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS;
            return delta;
        }

        (delta.totalMarginBefore, delta.postBullOi, delta.postBearOi) =
            _closeOpenInterest(snap, pos.side, order.sizeDelta);

        delta.closeState = _buildCloseState(snap, pos, order.sizeDelta, price, delta.postBullOi, delta.postBearOi);

        CloseAccountingLib.CloseState memory cs = delta.closeState;
        delta.posMarginAfter = cs.remainingMarginUsdc;
        delta.posSizeDelta = order.sizeDelta;
        delta.posMaxProfitReduction = cs.maxProfitReductionUsdc;
        delta.posVpiAccruedReduction = cs.proportionalAccrualUsdc;
        delta.deletePosition = pos.size == order.sizeDelta;

        delta.sideOiDecrease = order.sizeDelta;
        delta.sideEntryNotionalReduction = order.sizeDelta * pos.entryPrice;
        delta.sideMaxProfitReduction = cs.maxProfitReductionUsdc;

        delta.unlockMarginUsdc = cs.marginToFreeUsdc;

        uint256 remainingSize = pos.size - order.sizeDelta;
        if (remainingSize > 0 && cs.remainingMarginUsdc < snap.riskParams.minBountyUsdc) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION;
            return delta;
        }

        uint256 effectivePoolCash = snap.poolCashUsdc;

        delta.executionFeeUsdc = cs.executionFeeUsdc;
        delta.realizedPnlUsdc = cs.realizedPnlUsdc;

        uint256 availableCashForFreshPayouts =
            CashPriorityLib.reserveFreshPayouts(effectivePoolCash, snap.totalTraderClaimBalanceUsdc).freeCashUsdc;

        int256 carryAdjustedSettlementUsdc = cs.netSettlementUsdc - int256(delta.pendingCarryUsdc);

        if (carryAdjustedSettlementUsdc > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.GAIN;
            delta.freshTraderPayoutUsdc = uint256(carryAdjustedSettlementUsdc);
            delta.freshPayoutIsImmediate = availableCashForFreshPayouts >= delta.freshTraderPayoutUsdc;
            delta.freshPayoutCreatesClaim = !delta.freshPayoutIsImmediate;
            if (delta.freshPayoutIsImmediate) {
                uint256 cashAfterTraderPayout = availableCashForFreshPayouts - delta.freshTraderPayoutUsdc;
                delta.protocolFeeTopUpUsdc =
                    delta.executionFeeUsdc < cashAfterTraderPayout ? delta.executionFeeUsdc : cashAfterTraderPayout;
            }
        } else if (carryAdjustedSettlementUsdc < 0) {
            delta = _applyCloseLossSettlement(
                snap,
                delta,
                cs.marginToFreeUsdc,
                cs.remainingMarginUsdc,
                cs.executionFeeUsdc,
                remainingSize == 0,
                uint256(-carryAdjustedSettlementUsdc)
            );

            if (delta.revertCode != CfdEnginePlanTypes.CloseRevertCode.OK) {
                return delta;
            }
        } else {
            delta.protocolFeeTopUpUsdc = delta.executionFeeUsdc < availableCashForFreshPayouts
                ? delta.executionFeeUsdc
                : availableCashForFreshPayouts;
        }

        delta.totalMarginAfterClose = delta.totalMarginBefore
            + (cs.remainingMarginUsdc > pos.margin ? cs.remainingMarginUsdc - pos.margin : 0)
            - (pos.margin > cs.remainingMarginUsdc ? pos.margin - cs.remainingMarginUsdc : 0);

        delta.solvency = _computeCloseSolvency(snap, delta);
        delta.valid = true;
    }

    /// @notice Projects side open interest after removing close size from the selected side.
    /// @dev Assumes `sizeDelta` does not exceed selected-side open interest. The opposite side is copied unchanged.
    /// @param snap Aggregate BULL and BEAR side snapshots.
    /// @param side Side whose open interest is reduced.
    /// @param sizeDelta Position size being closed.
    /// @return totalMarginBefore Aggregate margin of the selected side before the close.
    /// @return postBullOi Projected BULL open interest.
    /// @return postBearOi Projected BEAR open interest.
    function _closeOpenInterest(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) private pure returns (uint256 totalMarginBefore, uint256 postBullOi, uint256 postBearOi) {
        (CfdEnginePlanTypes.SideSnapshot memory selected, CfdEnginePlanTypes.SideSnapshot memory opposite) =
            _selectedAndOpposite(snap, side);

        totalMarginBefore = selected.totalMargin;

        uint256 selectedOiAfter = selected.openInterest - sizeDelta;
        uint256 oppositeOi = opposite.openInterest;
        postBullOi = side == CfdTypes.Side.BULL ? selectedOiAfter : oppositeOi;
        postBearOi = side == CfdTypes.Side.BEAR ? selectedOiAfter : oppositeOi;
    }

    /// @notice Builds detailed close economics from projected post-close open interest.
    /// @dev Pre- and post-close skew are valued at `price`. The delegated close calculation prorates margin,
    ///      max-profit, and lifetime VPI, clamps lifetime close VPI from becoming negative, and calculates fees/spread.
    /// @param snap Current side, pool-depth, cap, frozen-market, fee, and risk snapshot.
    /// @param pos Position being reduced.
    /// @param sizeDelta Size being closed.
    /// @param price Capped execution price.
    /// @param postBullOi Projected BULL open interest.
    /// @param postBearOi Projected BEAR open interest.
    /// @return Detailed close state before pending carry and collateral collection.
    function _buildCloseState(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Position memory pos,
        uint256 sizeDelta,
        uint256 price,
        uint256 postBullOi,
        uint256 postBearOi
    ) private pure returns (CloseAccountingLib.CloseState memory) {
        uint256 preSkewUsdc = _absSkewUsdc(snap.bullSide, snap.bearSide, price);
        uint256 postSkewUsdc = _skewUsdc(postBullOi, postBearOi, price);
        return CloseAccountingLib.buildCloseState(
            CloseAccountingLib.CloseInputs({
                position: pos,
                sizeDelta: sizeDelta,
                oraclePrice: price,
                capPrice: snap.capPrice,
                preSkewUsdc: preSkewUsdc,
                postSkewUsdc: postSkewUsdc,
                poolDepthUsdc: snap.poolAssetsUsdc,
                vpiFactor: snap.riskParams.vpiFactor,
                frozenCloseSpreadBps: snap.frozenCloseSpreadBps,
                oracleFrozen: snap.oracleFrozen,
                executionFeeBps: snap.executionFeeBps
            })
        );
    }

    /// @notice Adds clearinghouse collection, existing-claim netting, recognized fees, and bad debt to a close loss.
    /// @dev Remaining position margin is protected from collection. `marginToFreeUsdc` has already been removed from
    ///      active margin in the settlement-bucket projection. Full closes may consume committed-order margin, while
    ///      partial closes protect it. Existing claims recover uncollected execution fee first and base bad debt second.
    ///      The recognized execution-fee field is replaced by retained, collateral-collected, and claim-recovered fee.
    ///      Any collection shortfall makes a close with nonzero remaining margin `PARTIAL_CLOSE_UNDERWATER`, including
    ///      shortfall attributable only to charges.
    /// @param snap Account collateral, lock, pool-cash, and claim snapshot.
    /// @param delta Partially built close delta to enrich and return.
    /// @param marginToFreeUsdc Pro-rata margin released by the closed size.
    /// @param remainingMarginUsdc Position margin protected for the remaining position.
    /// @param executionFeeUsdc Gross execution fee before collection constraints.
    /// @param includeOtherLockedMargin Whether terminal collection may consume committed-order margin.
    /// @param lossUsdc Magnitude of carry-adjusted negative close settlement.
    /// @return Updated close delta with collection, claim, fee, top-up, and failure values.
    function _applyCloseLossSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint256 marginToFreeUsdc,
        uint256 remainingMarginUsdc,
        uint256 executionFeeUsdc,
        bool includeOtherLockedMargin,
        uint256 lossUsdc
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory) {
        delta.settlementType = CfdEnginePlanTypes.SettlementType.LOSS;
        delta.lossUsdc = lossUsdc;

        IMarginClearinghouse.AccountUsdcBuckets memory closeBuckets =
            _buildCloseSettlementBuckets(snap, marginToFreeUsdc, includeOtherLockedMargin);
        delta.lossConsumption =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(closeBuckets, remainingMarginUsdc, lossUsdc);
        delta.lossResult = CfdEngineSettlementLib.closeSettlementResult(
            delta.lossConsumption.totalConsumedUsdc, lossUsdc, executionFeeUsdc, delta.closeState.frozenSpreadUsdc
        );
        delta.syncMarginQueueAmount = delta.lossConsumption.otherLockedMarginConsumedUsdc;
        (
            delta.existingTraderClaimConsumedUsdc,
            delta.existingTraderClaimRemainingUsdc,
            delta.traderClaimFeeRecoveryUsdc,
            delta.badDebtUsdc
        ) = _planCloseTraderClaimConsumption(snap.traderClaimBalanceForAccount, delta.lossResult, executionFeeUsdc);
        delta.executionFeeUsdc = delta.lossResult.collectedExecFeeUsdc + delta.traderClaimFeeRecoveryUsdc
            + delta.lossResult.retainedExecFeeUsdc;
        delta.protocolFeeTopUpUsdc = _closeLossProtocolFeeTopUpUsdc(snap, delta);

        if (delta.lossResult.shortfallUsdc > 0 && remainingMarginUsdc > 0) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER;
        }

        return delta;
    }

    /// @notice Computes post-close effective assets, maximum liability, and degraded-mode transition.
    /// @dev Maximum liability removes the close's pro-rata max-profit envelope. Physical assets include seized
    ///      collateral and subtract collected/top-up protocol fee plus any immediate payout. A deferred fresh payout
    ///      instead increases trader claims; consumed existing claims reduce them. No pending payout is separately
    ///      supplied because immediate and deferred treatment is already encoded in those deltas.
    /// @param snap Pre-close pool, side-liability, trader-claim, and degraded-mode snapshot.
    /// @param delta Planned close economics and settlement allocation.
    /// @return sp Projected effective assets, liability, and degradation flags.
    function _computeCloseSolvency(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (CfdEnginePlanTypes.SolvencyPreview memory sp) {
        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc, delta.side, delta.posMaxProfitReduction
        );

        int256 physicalAssetsDelta = _closePoolPhysicalAssetsDelta(delta);

        uint256 traderClaimIncrease = delta.freshPayoutCreatesClaim ? delta.freshTraderPayoutUsdc : 0;

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolAssetsUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalTraderClaimBalanceUsdc
        );

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDelta,
                maxLiabilityAfterUsdc: postMaxLiability,
                traderClaimDeltaUsdc: int256(traderClaimIncrease) - int256(delta.existingTraderClaimConsumedUsdc),
                pendingPoolPayoutUsdc: 0
            }),
            snap.degradedMode
        );
        sp.effectiveAssetsAfterUsdc = result.effectiveAssetsAfterUsdc;
        sp.maxLiabilityAfterUsdc = result.maxLiabilityAfterUsdc;
        sp.triggersDegradedMode = result.triggersDegradedMode;
        sp.postOpDegradedMode = result.postOpDegradedMode;
    }

    /// @notice Caps the pool-cash top-up used to credit recognized close fees not collected directly as fee.
    /// @dev The uncredited amount is recognized `delta.executionFeeUsdc` minus collateral already identified as
    ///      collected execution fee. Available cash is measured after adding seized collateral, removing that direct
    ///      fee, and reserving aggregate trader claims after this account's claim consumption. The result is the lesser
    ///      of uncredited fee and unreserved cash.
    /// @param snap Pre-close pool cash and aggregate trader claims.
    /// @param delta Close-loss result after claim recovery and recognized-fee replacement.
    /// @return topUpUsdc Additional pool cash available for protocol fee credit.
    function _closeLossProtocolFeeTopUpUsdc(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (uint256 topUpUsdc) {
        uint256 uncreditedFeeUsdc = delta.executionFeeUsdc - delta.lossResult.collectedExecFeeUsdc;
        if (uncreditedFeeUsdc == 0) {
            return 0;
        }

        uint256 poolCashAfterSeizure =
            snap.poolCashUsdc + delta.lossResult.seizedUsdc - delta.lossResult.collectedExecFeeUsdc;
        uint256 traderClaimAfterConsumption = snap.totalTraderClaimBalanceUsdc - delta.existingTraderClaimConsumedUsdc;
        uint256 freeCashUsdc =
            CashPriorityLib.reserveFreshPayouts(poolCashAfterSeizure, traderClaimAfterConsumption).freeCashUsdc;
        return uncreditedFeeUsdc < freeCashUsdc ? uncreditedFeeUsdc : freeCashUsdc;
    }

    /// @notice Computes the signed physical-pool-asset change caused by planned close settlement.
    /// @dev Adds seized collateral and subtracts directly collected execution fee, protocol fee top-up, and only an
    ///      immediate fresh trader payout. A payout represented by a trader claim does not remove physical assets here.
    /// @param delta Planned close settlement values.
    /// @return Signed physical asset delta in 6-decimal USDC.
    function _closePoolPhysicalAssetsDelta(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (int256) {
        return int256(delta.lossResult.seizedUsdc) - int256(delta.lossResult.collectedExecFeeUsdc)
            - int256(delta.protocolFeeTopUpUsdc)
            - int256(delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0);
    }

    /// @notice Builds the effective clearinghouse buckets eligible for close-loss collection.
    /// @dev Released pro-rata margin is removed from active position margin with a zero floor. Reserved settlement is
    ///      always removed from effective balance. When `includeOtherLockedMargin` is true, committed-order margin
    ///      remains classified and reachable after free/active collateral; otherwise it is also excluded from the
    ///      effective balance by the partial-close bucket builder.
    /// @param snap Account settlement and typed locked-margin snapshot.
    /// @param marginToFreeUsdc Position margin released before loss collection.
    /// @param includeOtherLockedMargin Whether committed-order margin may remain reachable.
    /// @return Effective account buckets for terminal loss planning.
    function _buildCloseSettlementBuckets(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 marginToFreeUsdc,
        bool includeOtherLockedMargin
    ) private pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        uint256 adjustedPosMargin = snap.lockedBuckets.positionMarginUsdc > marginToFreeUsdc
            ? snap.lockedBuckets.positionMarginUsdc - marginToFreeUsdc
            : 0;
        uint256 reservedSettlementUsdc = snap.lockedBuckets.reservedSettlementUsdc;
        uint256 settlementBalance = snap.accountBuckets.settlementBalanceUsdc > reservedSettlementUsdc
            ? snap.accountBuckets.settlementBalanceUsdc - reservedSettlementUsdc
            : 0;
        if (includeOtherLockedMargin) {
            return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                settlementBalance, adjustedPosMargin, snap.lockedBuckets.committedOrderMarginUsdc, 0
            );
        }

        return MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
            settlementBalance, adjustedPosMargin, snap.lockedBuckets.committedOrderMarginUsdc, 0
        );
    }

    // ──────────────────────────────────────────────
    //  PLAN LIQUIDATION
    // ──────────────────────────────────────────────

    /// @notice Plans eligibility and full settlement for liquidating a snapshot position.
    /// @dev Execution price is capped by `snap.capPrice`. A zero-size position returns a nonliquidatable delta after
    ///      populating account and price. Otherwise equity deducts pending carry and negative lifetime-VPI clawback and
    ///      uses all terminal settlement balance as reachable collateral. The liquidation threshold uses FAD margin in
    ///      the FAD window and normal maintenance margin otherwise, with equality liquidatable. A nonliquidatable
    ///      result stops after risk diagnostics; a liquidatable result removes the entire position, plans bounty and
    ///      residual settlement, and previews solvency. Notional, margin requirement, and rate-based bounty calculations
    ///      round down. `publishTime` is retained for interface parity but is not read.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param executionPrice Oracle liquidation price before the protocol cap.
    /// @param publishTime Oracle publish timestamp; currently unused by pure planning.
    /// @return delta Liquidation eligibility diagnostics and, when eligible, full settlement and solvency plan.
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.account = snap.account;
        delta.price = price;

        CfdTypes.Position memory pos = snap.position;
        if (pos.size == 0) {
            return delta;
        }

        delta.side = pos.side;
        delta.posSize = pos.size;
        delta.posMargin = pos.margin;
        delta.posMaxProfit = pos.maxProfitUsdc;
        delta.posEntryPrice = pos.entryPrice;

        uint256 maintMarginBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        uint256 settlementReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(snap.accountBuckets);
        delta.liquidationReachableCollateralUsdc = settlementReachableUsdc;
        publishTime;
        delta.pendingCarryUsdc = _pendingCarryUsdc(snap);

        delta.riskState = PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            pos, price, snap.capPrice, delta.pendingCarryUsdc, settlementReachableUsdc, maintMarginBps
        );

        if (!delta.riskState.liquidatable) {
            return delta;
        }
        delta.liquidatable = true;

        delta = _applyLiquidationSettlement(snap, delta, pos, price, settlementReachableUsdc, maintMarginBps);
        delta.solvency = _computeLiquidationSolvency(snap, delta, pos);
    }

    /// @notice Adds keeper bounty, full-position removal, residual settlement, claim netting, and payout routing.
    /// @dev Bounty is the maximum of the notional rate and minimum bounty, capped by terminal reachable collateral.
    ///      Residual equity is risk equity minus bounty. Positive residual retains existing account settlement first,
    ///      then creates a fresh payout; negative residual seizes post-bounty settlement. When pre-bounty equity is
    ///      nonnegative but below bounty, the resulting bounty subsidy is removed from reported liquidation bad debt.
    ///      Remaining bad debt consumes this account's existing trader claim. A fresh payout is immediate only when
    ///      pool cash, after reserving aggregate claims net of consumed account claims, can pay it in full.
    /// @param snap Account, pool cash, claims, risk parameters, and aggregate side snapshot.
    /// @param delta Liquidatable delta containing precomputed risk state.
    /// @param pos Entire position being liquidated.
    /// @param price Capped liquidation price.
    /// @param settlementReachableUsdc Terminal account settlement reachable before bounty.
    /// @param maintMarginBps Active maintenance or FAD rate used for liquidation state.
    /// @return Updated liquidation delta containing all position, bounty, residual, claim, and payout effects.
    function _applyLiquidationSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 settlementReachableUsdc,
        uint256 maintMarginBps
    ) private pure returns (CfdEnginePlanTypes.LiquidationDelta memory) {
        int256 liquidationEquityUsdc = delta.riskState.equityUsdc;

        delta.liquidationState = LiquidationAccountingLib.buildLiquidationState(
            pos.size,
            price,
            settlementReachableUsdc,
            liquidationEquityUsdc,
            maintMarginBps,
            snap.riskParams.minBountyUsdc,
            snap.riskParams.bountyBps,
            CfdMath.USDC_TO_TOKEN_SCALE
        );
        delta.keeperBountyUsdc = delta.liquidationState.keeperBountyUsdc;

        delta.sideOiDecrease = pos.size;
        delta.sideMaxProfitDecrease = pos.maxProfitUsdc;
        delta.sideEntryNotionalReduction = pos.size * pos.entryPrice;
        delta.sideTotalMarginReduction = pos.margin;

        delta.residualUsdc = liquidationEquityUsdc - int256(delta.keeperBountyUsdc);
        delta.residualPlan = MarginClearinghouseAccountingLib.planLiquidationResidual(
            snap.accountBuckets, delta.residualUsdc, delta.keeperBountyUsdc
        );
        delta.settlementRetainedUsdc = delta.residualPlan.settlementRetainedUsdc;
        uint256 liquidationBadDebtUsdc = delta.residualPlan.badDebtUsdc;
        if (liquidationEquityUsdc >= 0) {
            uint256 equityUsdc = uint256(liquidationEquityUsdc);
            uint256 keeperSubsidyUsdc = delta.keeperBountyUsdc > equityUsdc ? delta.keeperBountyUsdc - equityUsdc : 0;
            liquidationBadDebtUsdc =
                liquidationBadDebtUsdc > keeperSubsidyUsdc ? liquidationBadDebtUsdc - keeperSubsidyUsdc : 0;
        }
        (delta.existingTraderClaimConsumedUsdc, delta.existingTraderClaimRemainingUsdc, delta.badDebtUsdc) =
            _planTraderClaimConsumption(snap.traderClaimBalanceForAccount, liquidationBadDebtUsdc, false);
        delta.syncMarginQueueAmount = delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc;

        if (delta.residualPlan.freshTraderPayoutUsdc > 0) {
            delta.freshTraderPayoutUsdc = delta.residualPlan.freshTraderPayoutUsdc;
            uint256 traderClaimAfterConsumption =
                snap.totalTraderClaimBalanceUsdc - delta.existingTraderClaimConsumedUsdc;
            delta.freshPayoutIsImmediate = CashPriorityLib.reserveFreshPayouts(
                    snap.poolCashUsdc, traderClaimAfterConsumption
                )
                .freeCashUsdc >= delta.freshTraderPayoutUsdc;
            delta.freshPayoutCreatesClaim = !delta.freshPayoutIsImmediate;
        }

        return delta;
    }

    /// @notice Computes post-liquidation effective assets, maximum liability, and degraded-mode transition.
    /// @dev The entire position max-profit envelope is removed from its side. Physical assets gain settlement seized
    ///      after bounty and lose only an immediate fresh payout; the keeper bounty is an internal account transfer and
    ///      is excluded. Deferred payout increases trader claims, while existing claim consumption decreases them.
    /// @param snap Pre-liquidation pool, side-liability, claims, and degraded-mode snapshot.
    /// @param delta Planned liquidation settlement and payout routing.
    /// @param pos Position whose maximum-profit liability is removed.
    /// @return sp Projected effective assets, liability, and degradation flags.
    function _computeLiquidationSolvency(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        CfdTypes.Position memory pos
    ) private pure returns (CfdEnginePlanTypes.SolvencyPreview memory sp) {
        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc, pos.side, pos.maxProfitUsdc
        );

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolAssetsUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalTraderClaimBalanceUsdc
        );

        int256 physicalAssetsDelta = int256(delta.residualPlan.settlementSeizedUsdc)
            - int256(delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0);

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDelta,
                maxLiabilityAfterUsdc: postMaxLiability,
                traderClaimDeltaUsdc: int256(delta.freshPayoutCreatesClaim ? delta.freshTraderPayoutUsdc : 0)
                - int256(delta.existingTraderClaimConsumedUsdc),
                pendingPoolPayoutUsdc: 0
            }),
            snap.degradedMode
        );

        sp.effectiveAssetsAfterUsdc = result.effectiveAssetsAfterUsdc;
        sp.maxLiabilityAfterUsdc = result.maxLiabilityAfterUsdc;
        sp.triggersDegradedMode = result.triggersDegradedMode;
        sp.postOpDegradedMode = result.postOpDegradedMode;
    }

}

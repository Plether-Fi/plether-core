// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";
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

    /// @notice A canonical snapshot omitted settlement backing required by negative lifetime VPI.
    error CfdEnginePlanLib__VpiRebateReserveUnderfunded();

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

    /// @notice Returns the exact nonwithdrawable backing required by a signed lifetime-VPI balance.
    function _negativeVpiReserveTarget(
        int256 vpiAccruedUsdc
    ) private pure returns (uint256 targetUsdc) {
        if (vpiAccruedUsdc < 0) {
            // This form also supports `type(int256).min` without negating it directly.
            targetUsdc = uint256(-(vpiAccruedUsdc + 1)) + 1;
        }
    }

    /// @notice Projects release of no-longer-required VPI backing into an account-bucket snapshot.
    function _accountBucketsAfterVpiReserveRelease(
        IMarginClearinghouse.AccountUsdcBuckets memory buckets,
        uint256 releaseUsdc
    ) private pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        if (releaseUsdc == 0) {
            return buckets;
        }
        buckets.otherLockedMarginUsdc -= releaseUsdc;
        buckets.totalLockedMarginUsdc -= releaseUsdc;
        buckets.freeSettlementUsdc = buckets.settlementBalanceUsdc > buckets.totalLockedMarginUsdc
            ? buckets.settlementBalanceUsdc - buckets.totalLockedMarginUsdc
            : 0;
        return buckets;
    }

    /// @notice Classifies an open planner result for commit-time and execution-time order policy.
    /// @dev Opposing-side, too-small, skew, initial-margin, solvency, quantum, and unfunded-reserve failures are
    ///      commit-time rejectable. Degraded mode is an execution-time protocol-state invalidation; fee-drained margin
    ///      is execution-time user invalid.
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
                || code == CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM
                || code == CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED
                || code == CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED
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

    /// @notice Computes skew state after adding an order's size to one side.
    /// @dev Each post-trade side notional is independently rounded down to USDC before taking the difference.
    /// @param bull BULL aggregate state before the open.
    /// @param bear BEAR aggregate state before the open.
    /// @param side Side receiving the size increase.
    /// @param sizeDelta Size added to the selected side.
    /// @param price Price used to value open interest.
    /// @return postSkewUsdc Post-open absolute skew in 6-decimal USDC.
    /// @return orderSideIsPostOpenHeavy Whether the side receiving the open is heavier after the trade.
    function _postOpenSkewUsdc(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 price
    ) private pure returns (uint256 postSkewUsdc, bool orderSideIsPostOpenHeavy) {
        uint256 bullOi = bull.openInterest;
        uint256 bearOi = bear.openInterest;
        if (side == CfdTypes.Side.BULL) {
            bullOi += sizeDelta;
        } else {
            bearOi += sizeDelta;
        }
        uint256 postBullUsdc = (bullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (bearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        postSkewUsdc = postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;
        orderSideIsPostOpenHeavy =
            side == CfdTypes.Side.BULL ? postBullUsdc > postBearUsdc : postBearUsdc > postBullUsdc;
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

    // ──────────────────────────────────────────────
    //  PLAN OPEN
    // ──────────────────────────────────────────────

    /// @notice Plans an open or same-side increase from a complete engine snapshot.
    /// @dev Execution price is capped by `snap.capPrice`. For a live position, pending carry is first projected into a
    ///      memory copy of the snapshot and must be fully collectible; a zero-size position skips that realization even
    ///      if an inconsistent snapshot supplies unsettled carry. The planner then rejects an opposing live position,
    ///      degraded mode, a position too small to support the minimum bounty, insufficient clearinghouse funds,
    ///      post-operation insolvency, insufficient initial margin/equity, or pool-relative skew above the configured
    ///      maximum unless the order strictly reduces an existing imbalance without making its side the heavier side.
    ///      The skew-cap check is skipped when pool assets are zero. On a
    ///      business-rule failure `valid` remains false, `revertCode` identifies the first failed check, and previously
    ///      populated fields are diagnostic only. VPI, notional, fee, margin, and skew-cap divisions round down in
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

        if (order.sizeDelta == 0 || order.sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM;
            return delta;
        }

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
        (uint256 postSkewUsdc, bool orderSideIsPostOpenHeavy) =
            _postOpenSkewUsdc(bull, bear, order.side, order.sizeDelta, price);

        OpenAccountingLib.OpenState memory openState = OpenAccountingLib.buildOpenState(
            OpenAccountingLib.OpenInputs({
                currentSize: snap.position.size,
                currentEntryCostUsdcAtoms: snap.positionEntryCostUsdcAtoms,
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
        delta.poolRebatePayoutUsdc = openState.tradeCostUsdc < 0 ? uint256(-openState.tradeCostUsdc) : 0;

        delta.vpiRebateReserveBeforeUsdc = effectiveSnap.vpiRebateReserveUsdc;
        if (delta.vpiRebateReserveBeforeUsdc < _negativeVpiReserveTarget(effectiveSnap.position.vpiAccrued)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED;
            return delta;
        }
        delta.vpiRebateReserveAfterUsdc =
            _negativeVpiReserveTarget(effectiveSnap.position.vpiAccrued + openState.vpiUsdc);
        uint256 vpiReserveReleaseUsdc = delta.vpiRebateReserveBeforeUsdc > delta.vpiRebateReserveAfterUsdc
            ? delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc
            : 0;
        IMarginClearinghouse.AccountUsdcBuckets memory openCostBuckets =
            _accountBucketsAfterVpiReserveRelease(effectiveSnap.accountBuckets, vpiReserveReleaseUsdc);

        MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan =
            MarginClearinghouseAccountingLib.planOpenCostApplication(
                openCostBuckets, delta.marginDeltaUsdc, delta.tradeCostUsdc
            );
        if (openCostPlan.insufficientFreeEquity || openCostPlan.insufficientPositionMargin) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
            return delta;
        }

        _planOpenReserveFunding(effectiveSnap, openCostPlan, delta);
        if (delta.revertCode != CfdEnginePlanTypes.OpenRevertCode.OK) {
            return delta;
        }

        delta.newPosSize = openState.newSize;
        delta.newPosEntryPrice = openState.newEntryPrice;
        delta.newPosEntryCostUsdcAtoms = openState.newEntryCostUsdcAtoms;
        delta.posVpiAccruedDelta = openState.vpiUsdc;
        delta.posMaxProfitIncrease = openState.addedMaxProfitUsdc;
        delta.netMarginChange = int256(delta.positionMarginAfterOpen) - int256(effectiveSnap.position.margin);

        delta.sideOiIncrease = order.sizeDelta;
        if (openState.newEntryNotional >= openState.oldEntryNotional) {
            delta.sideEntryNotionalDelta = int256(openState.newEntryNotional - openState.oldEntryNotional);
        } else {
            delta.sideEntryNotionalDelta = -int256(openState.oldEntryNotional - openState.newEntryNotional);
        }
        delta.sideMaxProfitIncrease = openState.addedMaxProfitUsdc;

        delta.executionFeeUsdc = openState.executionFeeUsdc;
        delta.sideTotalMarginAfterOpen = computeSideTotalMarginAfterOpen(
            delta.sideTotalMarginBefore, effectiveSnap.position.margin, delta.positionMarginAfterOpen
        );

        (bool hasSettlementBuffer, uint256 requiredEffectiveAssetsAfterUsdc) =
            _openSettlementBufferAfterPlan(effectiveSnap, delta);
        if (!hasSettlementBuffer) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;
            return delta;
        }
        delta.requiredEffectiveAssetsAfterUsdc = requiredEffectiveAssetsAfterUsdc;

        PositionRiskAccountingLib.PositionRiskState memory postOpenRiskState =
            _buildPostOpenRiskState(effectiveSnap, delta);
        if (
            postOpenRiskState.liquidatable
                || postOpenRiskState.equityUsdc < int256(openState.initialMarginRequirementUsdc)
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
            return delta;
        }

        if (effectiveSnap.poolAssetsUsdc > 0) {
            uint256 maxSkewUsdc =
                Math.mulDiv(effectiveSnap.poolAssetsUsdc, effectiveSnap.riskParams.maxSkewRatio, CfdMath.WAD);
            if (postSkewUsdc > maxSkewUsdc && (postSkewUsdc >= preSkewUsdc || orderSideIsPostOpenHeavy)) {
                delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
                return delta;
            }
        }

        delta.valid = true;
    }

    /// @notice Allocates newly required VPI and liquidation reserves from free cash and new position pledge.
    function _planOpenReserveFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure {
        delta.liquidationReserveBeforeUsdc = snap.liquidationReserveUsdc;
        delta.liquidationReserveAfterUsdc = delta.openState.liquidationReserveTargetUsdc;
        if (delta.liquidationReserveAfterUsdc < delta.liquidationReserveBeforeUsdc) {
            delta.liquidationReserveAfterUsdc = delta.liquidationReserveBeforeUsdc;
        }
        uint256 reserveIncreaseUsdc = delta.liquidationReserveAfterUsdc - delta.liquidationReserveBeforeUsdc;

        uint256 newPledgeAvailableUsdc = openCostPlan.resultingPositionMarginUsdc > snap.position.margin
            ? openCostPlan.resultingPositionMarginUsdc - snap.position.margin
            : 0;
        uint256 vpiReserveIncreaseUsdc = delta.vpiRebateReserveAfterUsdc > delta.vpiRebateReserveBeforeUsdc
            ? delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveBeforeUsdc
            : 0;
        uint256 vpiReserveFromFreeUsdc = vpiReserveIncreaseUsdc < openCostPlan.resultingFreeSettlementUsdc
            ? vpiReserveIncreaseUsdc
            : openCostPlan.resultingFreeSettlementUsdc;
        delta.vpiRebateReserveFromPledgeUsdc = vpiReserveIncreaseUsdc - vpiReserveFromFreeUsdc;
        if (delta.vpiRebateReserveFromPledgeUsdc > newPledgeAvailableUsdc) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED;
            return;
        }

        newPledgeAvailableUsdc -= delta.vpiRebateReserveFromPledgeUsdc;
        if (reserveIncreaseUsdc > newPledgeAvailableUsdc) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED;
            return;
        }
        delta.positionMarginAfterOpen =
            openCostPlan.resultingPositionMarginUsdc - delta.vpiRebateReserveFromPledgeUsdc - reserveIncreaseUsdc;
    }

    /// @notice Projects collectible pending carry into a memory snapshot before open validation.
    /// @dev Does nothing for zero carry or a zero-size position. Carry is collected exclusively from free settlement;
    ///      PnL pledge and all reserve buckets remain protected. Any uncovered amount returns `true` without mutation.
    ///      On full coverage, the helper debits settlement, credits pool assets and cash by the full carry amount, and
    ///      rebuilds account buckets without changing locked classifications. It does not clear carry fields because this
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
        snap.poolAssetsUsdc += pendingCarryUsdc;
        snap.poolCashUsdc += pendingCarryUsdc;

        snap.accountBuckets = MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
            settlementBalanceUsdc,
            snap.lockedBuckets.positionMarginUsdc,
            snap.liquidationReserveUsdc,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.lockedBuckets.reservedSettlementUsdc
        );

        return false;
    }

    /// @notice Builds risk state for the position projected by a successful open-cost plan.
    /// @dev Canonical PnL pledge already excludes action charges, rebates, and the liquidation-reserve carve-out, so it
    ///      is used directly without reapplying `tradeCostUsdc`. The active threshold is FAD margin during the FAD
    ///      window and maintenance margin otherwise.
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
        projectedPosition.margin = delta.positionMarginAfterOpen;
        projectedPosition.entryPrice = delta.newPosEntryPrice;
        projectedPosition.vpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;

        uint256 reachableCollateralUsdc = delta.positionMarginAfterOpen + snap.traderClaimBalanceForAccount;

        riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.newPosEntryCostUsdcAtoms,
            delta.price,
            snap.capPrice,
            reachableCollateralUsdc,
            snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps
        );
    }

    /// @notice Tests whether a planned open preserves maximum liability plus protected settlement headroom.
    /// @dev The selected side copies are increased by the delta. Current assets use `snap.poolCashUsdc`; the physical
    ///      asset delta is trade cost net of execution fee, so only VPI enters pool assets. Trader claims and pending
    ///      payouts are unchanged. The protected buffer is liability-scaled and rounded up. This helper does not mutate
    ///      storage, but it does mutate the supplied memory side views (and any memory aliases) while projecting them.
    /// @param snap Current pool, claim, degradation, and side-liability snapshot.
    /// @param delta Partially built open delta with side and economic changes.
    /// @return satisfied Whether projected effective assets cover liability and the configured settlement buffer.
    /// @return requiredEffectiveAssetsAfterUsdc Minimum effective assets the apply-time backstop must observe.
    function _openSettlementBufferAfterPlan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure returns (bool satisfied, uint256 requiredEffectiveAssetsAfterUsdc) {
        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;
        if (delta.posSide == CfdTypes.Side.BULL) {
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
        satisfied = SolvencyAccountingLib.hasRequiredSettlementBuffer(
            result.effectiveAssetsAfterUsdc, result.maxLiabilityAfterUsdc, snap.settlementBufferBps
        );
        if (satisfied) {
            requiredEffectiveAssetsAfterUsdc = result.maxLiabilityAfterUsdc
                + SolvencyAccountingLib.settlementBufferTargetUsdc(
                    result.maxLiabilityAfterUsdc, snap.settlementBufferBps
                );
        }
    }

    // ──────────────────────────────────────────────
    //  PLAN CLOSE
    // ──────────────────────────────────────────────

    /// @notice Plans a full or partial close, including PnL, carry, charges, collection, claims, and solvency.
    /// @dev Execution price is capped by `snap.capPrice`; the live position side is authoritative and `order.side` is
    ///      not read. Carry is deducted from the pre-carry close settlement. A positive result creates an immediate
    ///      payout only when pool cash left after reserving existing aggregate trader claims is sufficient; otherwise
    ///      it creates a new trader claim. A negative result consumes eligible clearinghouse buckets and then the
    ///      account's existing claim. Price loss beyond the account-local collectible cap is an explicit write-off and
    ///      never blocks a partial close. A valid close may still project degraded mode; solvency is reported rather than
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

        if (order.sizeDelta == 0 || order.sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.INVALID_SIZE_QUANTUM;
            return delta;
        }

        if (pos.size < order.sizeDelta) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS;
            return delta;
        }

        if (snap.vpiRebateReserveUsdc < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.VPI_REBATE_RESERVE_UNDERFUNDED;
            return delta;
        }

        (delta.totalMarginBefore, delta.postBullOi, delta.postBearOi) =
            _closeOpenInterest(snap, pos.side, order.sizeDelta);

        delta.closeState = _buildCloseState(snap, pos, order.sizeDelta, price, delta.postBullOi, delta.postBearOi);

        CloseAccountingLib.CloseState memory cs = delta.closeState;
        delta.posSizeDelta = order.sizeDelta;
        delta.posEntryCostAfterUsdcAtoms = cs.remainingEntryCostUsdcAtoms;
        if (cs.remainingSize > 0) {
            delta.posEntryPriceAfter = cs.remainingEntryCostUsdcAtoms / CfdMath.sizeToLots(cs.remainingSize);
        }
        delta.posMaxProfitReduction = cs.maxProfitReductionUsdc;
        delta.posVpiAccruedReduction = cs.proportionalAccrualUsdc;
        delta.deletePosition = pos.size == order.sizeDelta;

        delta.sideOiDecrease = order.sizeDelta;
        delta.sideEntryNotionalReduction = cs.closedEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        delta.sideMaxProfitReduction = cs.maxProfitReductionUsdc;

        delta.unlockMarginUsdc = cs.marginToFreeUsdc;

        uint256 remainingSize = pos.size - order.sizeDelta;
        uint256 reserveTargetUsdc;
        if (remainingSize > 0) {
            reserveTargetUsdc = (CfdMath.sizeToLots(remainingSize) * price * snap.riskParams.bountyBps) / 10_000;
            if (reserveTargetUsdc < snap.riskParams.minBountyUsdc) {
                reserveTargetUsdc = snap.riskParams.minBountyUsdc;
            }
        }
        if (snap.liquidationReserveUsdc > reserveTargetUsdc) {
            delta.liquidationReserveReleaseUsdc = snap.liquidationReserveUsdc - reserveTargetUsdc;
        }
        delta.realizedPnlUsdc = cs.realizedPnlUsdc;
        delta = _planIsolatedCloseSettlement(snap, delta, cs);

        if (remainingSize > 0 && delta.actionChargeWaivedUsdc > 0) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE;
            return delta;
        }

        if (remainingSize > 0 && delta.pricePayoutIsImmediate) {
            delta.posMarginAfter += delta.pricePayoutUsdc;
        }

        delta.totalMarginAfterClose = delta.totalMarginBefore
            + (delta.posMarginAfter > pos.margin ? delta.posMarginAfter - pos.margin : 0)
            - (pos.margin > delta.posMarginAfter ? pos.margin - delta.posMarginAfter : 0);

        delta.solvency = _computeCloseSolvency(snap, delta);
        delta.valid = true;
    }

    /// @notice Separates price PnL from action economics so realized settlement matches the terminal NAV cap.
    function _planIsolatedCloseSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory) {
        if (cs.realizedPnlUsdc >= 0) {
            delta.priceGainUsdc = uint256(cs.realizedPnlUsdc);
        } else {
            delta.priceLossUsdc = uint256(-cs.realizedPnlUsdc);
            delta.lossUsdc = delta.priceLossUsdc;
            delta.pricePnlClaimConsumedUsdc = snap.traderClaimBalanceForAccount < delta.priceLossUsdc
                ? snap.traderClaimBalanceForAccount
                : delta.priceLossUsdc;
            uint256 lossAfterClaimUsdc = delta.priceLossUsdc - delta.pricePnlClaimConsumedUsdc;
            delta.pricePnlPledgeConsumedUsdc =
                cs.marginToFreeUsdc < lossAfterClaimUsdc ? cs.marginToFreeUsdc : lossAfterClaimUsdc;
            uint256 minimumRecoveryUsdc = _minimumPartialLossRecoveryPreservingTerminalCap(snap, cs, delta.price);
            uint256 minimumPledgeConsumptionUsdc = minimumRecoveryUsdc > delta.pricePnlClaimConsumedUsdc
                ? minimumRecoveryUsdc - delta.pricePnlClaimConsumedUsdc
                : 0;
            uint256 maximumPledgeConsumptionUsdc =
                lossAfterClaimUsdc < snap.position.margin ? lossAfterClaimUsdc : snap.position.margin;
            if (minimumPledgeConsumptionUsdc > maximumPledgeConsumptionUsdc) {
                minimumPledgeConsumptionUsdc = maximumPledgeConsumptionUsdc;
            }
            if (minimumPledgeConsumptionUsdc > delta.pricePnlPledgeConsumedUsdc) {
                delta.pricePnlPledgeConsumedUsdc = minimumPledgeConsumptionUsdc;
            }
            delta.priceLossWrittenOffUsdc = lossAfterClaimUsdc - delta.pricePnlPledgeConsumedUsdc;
        }

        delta.unlockMarginUsdc = _maxPricePledgeUnlockPreservingTerminalCap(snap, delta, cs);
        delta.posMarginAfter = snap.position.margin - delta.pricePnlPledgeConsumedUsdc - delta.unlockMarginUsdc;
        delta.existingTraderClaimConsumedUsdc = delta.pricePnlClaimConsumedUsdc;
        delta.existingTraderClaimRemainingUsdc = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedUsdc;

        delta.vpiRebateReserveBeforeUsdc = snap.vpiRebateReserveUsdc;
        delta.vpiRebateReserveAfterUsdc =
            _negativeVpiReserveTarget(snap.position.vpiAccrued - cs.proportionalAccrualUsdc);

        _planCloseActionSettlement(snap, delta, cs);

        delta.pricePayoutUsdc = delta.priceGainUsdc - delta.actionChargeWithheldUsdc;
        uint256 claimsAfterPriceNettingUsdc = snap.totalTraderClaimBalanceUsdc - delta.pricePnlClaimConsumedUsdc;
        uint256 poolCashAfterCollectionsUsdc = snap.poolCashUsdc + delta.pricePnlPledgeConsumedUsdc
            + delta.actionChargeCollectedUsdc - delta.actionProtocolFeeCreditedUsdc;
        uint256 freePoolCashUsdc =
            CashPriorityLib.reserveFreshPayouts(poolCashAfterCollectionsUsdc, claimsAfterPriceNettingUsdc).freeCashUsdc;
        if (delta.pricePayoutUsdc > 0) {
            delta.pricePayoutIsImmediate = freePoolCashUsdc >= delta.pricePayoutUsdc;
            delta.pricePayoutCreatesClaim = !delta.pricePayoutIsImmediate;
            if (delta.pricePayoutIsImmediate) {
                poolCashAfterCollectionsUsdc -= delta.pricePayoutUsdc;
            } else {
                claimsAfterPriceNettingUsdc += delta.pricePayoutUsdc;
            }
        }

        freePoolCashUsdc =
        CashPriorityLib.reserveFreshPayouts(poolCashAfterCollectionsUsdc, claimsAfterPriceNettingUsdc).freeCashUsdc;
        if (delta.actionRebateUsdc > 0) {
            delta.actionRebatePaidUsdc =
                delta.actionRebateUsdc < freePoolCashUsdc ? delta.actionRebateUsdc : freePoolCashUsdc;
            delta.actionRebateWaivedUsdc = delta.actionRebateUsdc - delta.actionRebatePaidUsdc;
            poolCashAfterCollectionsUsdc -= delta.actionRebatePaidUsdc;
        }

        delta.freshTraderPayoutUsdc = delta.pricePayoutUsdc + delta.actionRebatePaidUsdc;
        delta.freshPayoutIsImmediate = !delta.pricePayoutCreatesClaim;
        delta.freshPayoutCreatesClaim = delta.pricePayoutCreatesClaim;

        freePoolCashUsdc =
        CashPriorityLib.reserveFreshPayouts(poolCashAfterCollectionsUsdc, claimsAfterPriceNettingUsdc).freeCashUsdc;
        uint256 feeTopUpUsdc = delta.executionFeeUsdc - delta.actionProtocolFeeCreditedUsdc;
        delta.protocolFeeTopUpUsdc = feeTopUpUsdc < freePoolCashUsdc ? feeTopUpUsdc : freePoolCashUsdc;

        if (delta.pricePayoutUsdc > 0 || delta.actionRebatePaidUsdc > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.GAIN;
        } else if (delta.priceLossUsdc > 0 || delta.actionChargeCollectedUsdc > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.LOSS;
        }
        return delta;
    }

    /// @notice Separates close action charges and rebates from price PnL and allocates the collected execution fee.
    function _planCloseActionSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure {
        int256 actionNetUsdc =
            cs.vpiDeltaUsdc + int256(cs.executionFeeUsdc + cs.frozenSpreadUsdc + delta.pendingCarryUsdc);
        uint256 vpiClawbackWithheldUsdc;
        if (actionNetUsdc > 0) {
            delta.actionChargeAssessedUsdc = uint256(actionNetUsdc);
            delta.actionChargeWithheldUsdc = delta.priceGainUsdc < delta.actionChargeAssessedUsdc
                ? delta.priceGainUsdc
                : delta.actionChargeAssessedUsdc;
            delta.actionChargeToCollectUsdc = delta.actionChargeAssessedUsdc - delta.actionChargeWithheldUsdc;
            uint256 vpiClawbackUsdc =
                _negativeVpiReserveTarget(snap.position.vpiAccrued) - delta.vpiRebateReserveAfterUsdc;
            vpiClawbackWithheldUsdc =
                delta.actionChargeWithheldUsdc < vpiClawbackUsdc ? delta.actionChargeWithheldUsdc : vpiClawbackUsdc;
            delta.vpiRebateReserveConsumedUsdc = vpiClawbackUsdc - vpiClawbackWithheldUsdc;
            uint256 remainingActionChargeToCollectUsdc =
                delta.actionChargeToCollectUsdc - delta.vpiRebateReserveConsumedUsdc;
            uint256 protectedActionReserveUsdc = snap.protectedExecutionBountyUsdc + snap.vpiRebateReserveUsdc;
            uint256 spendableActionReserveUsdc = snap.actionReserveUsdc > protectedActionReserveUsdc
                ? snap.actionReserveUsdc - protectedActionReserveUsdc
                : 0;
            delta.actionReserveConsumedUsdc = remainingActionChargeToCollectUsdc < spendableActionReserveUsdc
                ? remainingActionChargeToCollectUsdc
                : spendableActionReserveUsdc;
            uint256 actionChargeAfterReserveUsdc = remainingActionChargeToCollectUsdc - delta.actionReserveConsumedUsdc;
            uint256 releasedVpiReserveUsdc =
                delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveConsumedUsdc;
            uint256 collectibleFreeSettlementUsdc = snap.accountBuckets.freeSettlementUsdc + releasedVpiReserveUsdc;
            uint256 freeConsumedUsdc = actionChargeAfterReserveUsdc < collectibleFreeSettlementUsdc
                ? actionChargeAfterReserveUsdc
                : collectibleFreeSettlementUsdc;
            uint256 actionChargeAfterFreeUsdc = actionChargeAfterReserveUsdc - freeConsumedUsdc;
            if (cs.remainingSize == 0) {
                delta.actionCommittedMarginConsumedUsdc = actionChargeAfterFreeUsdc
                    < snap.lockedBuckets.committedOrderMarginUsdc
                    ? actionChargeAfterFreeUsdc
                    : snap.lockedBuckets.committedOrderMarginUsdc;
            }
            delta.actionChargeCollectedUsdc = delta.vpiRebateReserveConsumedUsdc + delta.actionReserveConsumedUsdc
                + freeConsumedUsdc + delta.actionCommittedMarginConsumedUsdc;
            delta.actionChargeWaivedUsdc = delta.actionChargeToCollectUsdc - delta.actionChargeCollectedUsdc;
        } else if (actionNetUsdc < 0) {
            delta.actionRebateUsdc = uint256(-actionNetUsdc);
        }

        uint256 nonClawbackWithheldUsdc = delta.actionChargeWithheldUsdc - vpiClawbackWithheldUsdc;
        uint256 nonVpiReserveCollectedUsdc = delta.actionChargeCollectedUsdc - delta.vpiRebateReserveConsumedUsdc;
        uint256 executionFeeEligibleUsdc = nonClawbackWithheldUsdc + nonVpiReserveCollectedUsdc;
        delta.executionFeeUsdc =
            cs.executionFeeUsdc < executionFeeEligibleUsdc ? cs.executionFeeUsdc : executionFeeEligibleUsdc;
        uint256 feeWithheldUsdc =
            delta.executionFeeUsdc < nonClawbackWithheldUsdc ? delta.executionFeeUsdc : nonClawbackWithheldUsdc;
        uint256 feeToCollectUsdc = delta.executionFeeUsdc - feeWithheldUsdc;
        delta.actionProtocolFeeCreditedUsdc =
            feeToCollectUsdc < nonVpiReserveCollectedUsdc ? feeToCollectUsdc : nonVpiReserveCollectedUsdc;
    }

    /// @notice Returns the greatest close allocation that can leave PnL pledge without changing terminal price NAV.
    /// @dev A losing close realizes only the claim and pledge actually consumed. Any otherwise-unused pro-rata pledge
    ///      remains attached to a live remainder when it is needed to preserve
    ///      `preTerminalDelta = realizedLpDelta + postTerminalDelta` at the same mark. Trader-profit curves are
    ///      uncapped, so they can release the entire unused close allocation. Full closes always release the remainder.
    function _maxPricePledgeUnlockPreservingTerminalCap(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (uint256 unlockUsdc) {
        uint256 unusedCloseAllocationUsdc = cs.marginToFreeUsdc > delta.pricePnlPledgeConsumedUsdc
            ? cs.marginToFreeUsdc - delta.pricePnlPledgeConsumedUsdc
            : 0;
        if (cs.remainingSize == 0 || unusedCloseAllocationUsdc == 0) {
            return unusedCloseAllocationUsdc;
        }

        (bool remainingTraderProfit, uint256 requiredPostCapUsdc) = _requiredPostCloseTerminalCapUsdc(snap, delta, cs);
        if (remainingTraderProfit) {
            return unusedCloseAllocationUsdc;
        }

        uint256 remainingClaimUsdc = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedUsdc;
        uint256 requiredPledgeUsdc =
            requiredPostCapUsdc > remainingClaimUsdc ? requiredPostCapUsdc - remainingClaimUsdc : 0;
        uint256 pledgeBeforeUnlockUsdc = snap.position.margin - delta.pricePnlPledgeConsumedUsdc;
        uint256 capPreservingUnlockUsdc =
            pledgeBeforeUnlockUsdc > requiredPledgeUsdc ? pledgeBeforeUnlockUsdc - requiredPledgeUsdc : 0;
        return unusedCloseAllocationUsdc < capPreservingUnlockUsdc ? unusedCloseAllocationUsdc : capPreservingUnlockUsdc;
    }

    /// @notice Computes the post-close collectible cap required to preserve the pre-close terminal price curve.
    function _requiredPostCloseTerminalCapUsdc(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (bool remainingTraderProfit, uint256 requiredPostCapUsdc) {
        (bool traderProfit, uint256 traderPnlAbsUsdc) = CfdMath.calculateExactPnl(
            CfdMath.sizeToLots(snap.position.size),
            snap.positionEntryCostUsdcAtoms,
            snap.position.side,
            delta.price,
            snap.capPrice
        );
        int256 preTraderPnlUsdc = traderProfit ? int256(traderPnlAbsUsdc) : -int256(traderPnlAbsUsdc);
        int256 preRawLpDeltaUsdc = -preTraderPnlUsdc;
        int256 remainingRawLpDeltaUsdc = preRawLpDeltaUsdc + cs.realizedPnlUsdc;

        // A negative LP curve (remaining trader profit) is not limited by collectible collateral.
        if (remainingRawLpDeltaUsdc <= 0) {
            return (true, 0);
        }

        uint256 preCollectibleCapUsdc = snap.position.margin + snap.traderClaimBalanceForAccount;
        int256 preTerminalLpDeltaUsdc =
            preRawLpDeltaUsdc > int256(preCollectibleCapUsdc) ? int256(preCollectibleCapUsdc) : preRawLpDeltaUsdc;
        int256 realizedLpDeltaUsdc = cs.realizedPnlUsdc < 0
            ? int256(delta.pricePnlClaimConsumedUsdc + delta.pricePnlPledgeConsumedUsdc)
            : -int256(delta.priceGainUsdc);
        int256 targetPostTerminalLpDeltaUsdc = preTerminalLpDeltaUsdc - realizedLpDeltaUsdc;
        requiredPostCapUsdc = targetPostTerminalLpDeltaUsdc > 0 ? uint256(targetPostTerminalLpDeltaUsdc) : 0;
    }

    /// @notice Computes the minimum collectible loss that must be realized before removing a partial price curve.
    /// @dev Exact proportional basis can assign the closed lots more loss than their pro-rata pledge allocation by one
    ///      or more atoms. Recovery must therefore be at least `preTerminal - remainingRawLoss`; otherwise close
    ///      partitioning would reduce LP terminal NAV. The bound is always payable from same-account claim plus pledge
    ///      because the pre-close terminal value is itself capped by those sources.
    function _minimumPartialLossRecoveryPreservingTerminalCap(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CloseAccountingLib.CloseState memory cs,
        uint256 price
    ) private pure returns (uint256 minimumRecoveryUsdc) {
        if (cs.remainingSize == 0 || cs.realizedPnlUsdc >= 0) {
            return 0;
        }

        (bool traderProfit, uint256 traderPnlAbsUsdc) = CfdMath.calculateExactPnl(
            CfdMath.sizeToLots(snap.position.size),
            snap.positionEntryCostUsdcAtoms,
            snap.position.side,
            price,
            snap.capPrice
        );
        int256 preRawLpDeltaUsdc = traderProfit ? -int256(traderPnlAbsUsdc) : int256(traderPnlAbsUsdc);
        int256 remainingRawLpDeltaUsdc = preRawLpDeltaUsdc + cs.realizedPnlUsdc;
        uint256 preCollectibleCapUsdc = snap.position.margin + snap.traderClaimBalanceForAccount;
        int256 preTerminalLpDeltaUsdc =
            preRawLpDeltaUsdc > int256(preCollectibleCapUsdc) ? int256(preCollectibleCapUsdc) : preRawLpDeltaUsdc;
        if (preTerminalLpDeltaUsdc <= 0) {
            return 0;
        }

        uint256 remainingRawLossUsdc = remainingRawLpDeltaUsdc > 0 ? uint256(remainingRawLpDeltaUsdc) : 0;
        uint256 preTerminalLossUsdc = uint256(preTerminalLpDeltaUsdc);
        minimumRecoveryUsdc =
            preTerminalLossUsdc > remainingRawLossUsdc ? preTerminalLossUsdc - remainingRawLossUsdc : 0;
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
                positionEntryCostUsdcAtoms: snap.positionEntryCostUsdcAtoms,
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

        uint256 traderClaimIncrease = delta.pricePayoutCreatesClaim ? delta.pricePayoutUsdc : 0;

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

    /// @notice Computes the signed physical-pool-asset change caused by planned close settlement.
    /// @dev Adds price-PnL pledge and non-protocol action cash collected into the pool. It subtracts protocol-fee
    ///      top-up, immediate price payout, and the actually paid (never claim-backed) action rebate.
    /// @param delta Planned close settlement values.
    /// @return Signed physical asset delta in 6-decimal USDC.
    function _closePoolPhysicalAssetsDelta(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (int256) {
        uint256 cashInflowUsdc =
            delta.pricePnlPledgeConsumedUsdc + delta.actionChargeCollectedUsdc - delta.actionProtocolFeeCreditedUsdc;
        uint256 cashOutflowUsdc = delta.protocolFeeTopUpUsdc + delta.actionRebatePaidUsdc
            + (delta.pricePayoutIsImmediate ? delta.pricePayoutUsdc : 0);
        return int256(cashInflowUsdc) - int256(cashOutflowUsdc);
    }

    // ──────────────────────────────────────────────
    //  PLAN LIQUIDATION
    // ──────────────────────────────────────────────

    /// @notice Plans eligibility and full settlement for liquidating a snapshot position.
    /// @dev Execution price is capped by `snap.capPrice`. A zero-size position returns a nonliquidatable delta after
    ///      populating account and price. Otherwise exact price health excludes pending carry and uses only price-risk
    ///      collateral. Pending carry is projected against eligible free settlement; any uncovered amount is an
    ///      independent delinquency condition. The liquidation threshold uses FAD margin in
    ///      the FAD window and normal maintenance margin otherwise, with equality liquidatable. A nonliquidatable
    ///      result stops after risk diagnostics; a liquidatable result removes the entire position, plans the split
    ///      charge and residual settlement, and previews solvency. Notional, margin requirement, and rate-based charge
    ///      calculations round down. `publishTime` is retained for interface parity but is not read.
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
        if (snap.vpiRebateReserveUsdc < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            revert CfdEnginePlanLib__VpiRebateReserveUnderfunded();
        }

        delta.side = pos.side;
        delta.posSize = pos.size;
        delta.posMargin = pos.margin;
        delta.posMaxProfit = pos.maxProfitUsdc;
        delta.posEntryPrice = pos.entryPrice;
        delta.posEntryCostUsdcAtoms = snap.positionEntryCostUsdcAtoms;

        uint256 maintMarginBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        // Terminal settlement can reach the dedicated VPI reserve only for its matching clawback; exact price health
        // below deliberately uses PnL pledge plus same-account claim only.
        uint256 settlementReachableUsdc = pos.margin + snap.traderClaimBalanceForAccount + snap.vpiRebateReserveUsdc;
        delta.liquidationReachableCollateralUsdc = settlementReachableUsdc;
        publishTime;
        delta.pendingCarryUsdc = _pendingCarryUsdc(snap);
        MarginClearinghouseAccountingLib.SettlementConsumption memory carryConsumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(snap.accountBuckets, delta.pendingCarryUsdc);

        delta.riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            snap.positionEntryCostUsdcAtoms,
            price,
            snap.capPrice,
            pos.margin + snap.traderClaimBalanceForAccount,
            maintMarginBps
        );

        if (!delta.riskState.liquidatable && carryConsumption.uncoveredUsdc == 0) {
            return delta;
        }
        delta.riskState.liquidatable = true;
        delta.liquidatable = true;

        delta = _applyLiquidationSettlement(snap, delta, pos, price, settlementReachableUsdc, maintMarginBps);
        delta.solvency = _computeLiquidationSolvency(snap, delta, pos);
    }

    /// @notice Separates full-liquidation price PnL, action charges, and the dedicated liquidation reserve.
    /// @dev Price loss consumes only the same-account claim and PnL pledge; excess is a diagnostic write-off. The
    ///      keeper/protocol/LP charge is capped by `liquidationReserveUsdc`. Carry and negative lifetime VPI are action
    ///      charges recovered from new price gain first, then action reserve and pre-existing free settlement, with the
    ///      remainder waived. No shortfall becomes protocol bad debt or reaches order/liquidation/PnL buckets.
    /// @param snap Account, pool cash, claims, risk parameters, and aggregate side snapshot.
    /// @param delta Liquidatable delta containing precomputed risk state.
    /// @param pos Entire position being liquidated.
    /// @param price Capped liquidation price.
    /// @param settlementReachableUsdc Terminal account settlement reachable before the liquidation charge.
    /// @param maintMarginBps Active maintenance or FAD rate used for liquidation state.
    /// @return Updated liquidation delta containing all position, charge-split, residual, claim, and payout effects.
    function _applyLiquidationSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 settlementReachableUsdc,
        uint256 maintMarginBps
    ) private pure returns (CfdEnginePlanTypes.LiquidationDelta memory) {
        delta.liquidationState = _buildLiquidationState(
            snap.riskParams, pos.size, price, snap.liquidationReserveUsdc, delta.riskState.equityUsdc, maintMarginBps
        );
        delta.liquidationChargeUsdc = delta.liquidationState.liquidationChargeUsdc;
        delta.keeperBountyUsdc = delta.liquidationState.keeperBountyUsdc;
        delta.protocolLiquidationFeeUsdc = delta.liquidationState.protocolLiquidationFeeUsdc;
        delta.lpLiquidationFeeUsdc = delta.liquidationState.lpLiquidationFeeUsdc;

        delta.sideOiDecrease = pos.size;
        delta.sideMaxProfitDecrease = pos.maxProfitUsdc;
        delta.sideEntryNotionalReduction = snap.positionEntryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE;
        delta.sideTotalMarginReduction = pos.margin;

        if (delta.riskState.unrealizedPnlUsdc >= 0) {
            delta.priceGainUsdc = uint256(delta.riskState.unrealizedPnlUsdc);
        } else {
            delta.priceLossUsdc = uint256(-delta.riskState.unrealizedPnlUsdc);
            delta.pricePnlClaimConsumedUsdc = snap.traderClaimBalanceForAccount < delta.priceLossUsdc
                ? snap.traderClaimBalanceForAccount
                : delta.priceLossUsdc;
            uint256 lossAfterClaimUsdc = delta.priceLossUsdc - delta.pricePnlClaimConsumedUsdc;
            delta.pricePnlPledgeConsumedUsdc = pos.margin < lossAfterClaimUsdc ? pos.margin : lossAfterClaimUsdc;
            delta.priceLossWrittenOffUsdc = lossAfterClaimUsdc - delta.pricePnlPledgeConsumedUsdc;
        }

        delta.existingTraderClaimConsumedUsdc = delta.pricePnlClaimConsumedUsdc;
        delta.existingTraderClaimRemainingUsdc = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedUsdc;

        _planLiquidationActionSettlement(snap, pos, delta);

        delta.freshTraderPayoutUsdc = delta.priceGainUsdc - delta.actionChargeWithheldUsdc;
        delta.settlementSeizedUsdc = delta.pricePnlPledgeConsumedUsdc + delta.lpLiquidationFeeUsdc;
        delta.residualUsdc = delta.riskState.equityUsdc - int256(delta.liquidationChargeUsdc);
        delta.residualPlan.liquidationChargeUsdc = delta.liquidationChargeUsdc;
        delta.residualPlan.settlementSeizedUsdc = delta.pricePnlPledgeConsumedUsdc;
        delta.residualPlan.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        delta.residualPlan.mutation.positionMarginUnlockedUsdc = pos.margin;

        if (delta.freshTraderPayoutUsdc > 0) {
            uint256 claimsAfterPriceNettingUsdc = snap.totalTraderClaimBalanceUsdc - delta.pricePnlClaimConsumedUsdc;
            uint256 poolCashAfterCollectionsUsdc =
                snap.poolCashUsdc + delta.settlementSeizedUsdc + delta.actionChargeCollectedUsdc;
            delta.freshPayoutIsImmediate = CashPriorityLib.reserveFreshPayouts(
                    poolCashAfterCollectionsUsdc, claimsAfterPriceNettingUsdc
                )
                .freeCashUsdc >= delta.freshTraderPayoutUsdc;
            delta.freshPayoutCreatesClaim = !delta.freshPayoutIsImmediate;
        }

        uint256 settlementAfterDebitsUsdc = snap.accountBuckets.settlementBalanceUsdc - delta.pricePnlPledgeConsumedUsdc
            - delta.actionChargeCollectedUsdc - delta.liquidationChargeUsdc;
        delta.settlementRetainedUsdc =
            settlementAfterDebitsUsdc + (delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0);
        delta.residualPlan.settlementRetainedUsdc = delta.settlementRetainedUsdc;

        settlementReachableUsdc;
        return delta;
    }

    /// @notice Allocates liquidation carry and VPI clawback across price gain, reserves, and account cash.
    function _planLiquidationActionSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Position memory pos,
        CfdEnginePlanTypes.LiquidationDelta memory delta
    ) private pure {
        uint256 vpiClawbackUsdc = _negativeVpiReserveTarget(pos.vpiAccrued);
        delta.vpiRebateReserveBeforeUsdc = snap.vpiRebateReserveUsdc;
        delta.vpiRebateReserveAfterUsdc = 0;
        delta.actionChargeAssessedUsdc = delta.pendingCarryUsdc + vpiClawbackUsdc;
        delta.actionChargeWithheldUsdc =
            delta.priceGainUsdc < delta.actionChargeAssessedUsdc ? delta.priceGainUsdc : delta.actionChargeAssessedUsdc;
        delta.actionChargeToCollectUsdc = delta.actionChargeAssessedUsdc - delta.actionChargeWithheldUsdc;
        uint256 vpiClawbackWithheldUsdc =
            delta.actionChargeWithheldUsdc < vpiClawbackUsdc ? delta.actionChargeWithheldUsdc : vpiClawbackUsdc;
        delta.vpiRebateReserveConsumedUsdc = vpiClawbackUsdc - vpiClawbackWithheldUsdc;
        uint256 remainingActionChargeToCollectUsdc =
            delta.actionChargeToCollectUsdc - delta.vpiRebateReserveConsumedUsdc;
        uint256 protectedActionReserveUsdc = snap.protectedExecutionBountyUsdc + snap.vpiRebateReserveUsdc;
        uint256 spendableActionReserveUsdc = snap.actionReserveUsdc > protectedActionReserveUsdc
            ? snap.actionReserveUsdc - protectedActionReserveUsdc
            : 0;
        delta.actionReserveConsumedUsdc = remainingActionChargeToCollectUsdc < spendableActionReserveUsdc
            ? remainingActionChargeToCollectUsdc
            : spendableActionReserveUsdc;
        uint256 actionChargeAfterReserveUsdc = remainingActionChargeToCollectUsdc - delta.actionReserveConsumedUsdc;
        uint256 releasedVpiReserveUsdc =
            delta.vpiRebateReserveBeforeUsdc - delta.vpiRebateReserveAfterUsdc - delta.vpiRebateReserveConsumedUsdc;
        uint256 collectibleFreeSettlementUsdc = snap.accountBuckets.freeSettlementUsdc + releasedVpiReserveUsdc;
        uint256 freeConsumedUsdc = actionChargeAfterReserveUsdc < collectibleFreeSettlementUsdc
            ? actionChargeAfterReserveUsdc
            : collectibleFreeSettlementUsdc;
        uint256 actionChargeAfterFreeUsdc = actionChargeAfterReserveUsdc - freeConsumedUsdc;
        delta.actionCommittedMarginConsumedUsdc = actionChargeAfterFreeUsdc
            < snap.lockedBuckets.committedOrderMarginUsdc
            ? actionChargeAfterFreeUsdc
            : snap.lockedBuckets.committedOrderMarginUsdc;
        delta.actionChargeCollectedUsdc = delta.vpiRebateReserveConsumedUsdc + delta.actionReserveConsumedUsdc
            + freeConsumedUsdc + delta.actionCommittedMarginConsumedUsdc;
        delta.actionChargeWaivedUsdc = delta.actionChargeToCollectUsdc - delta.actionChargeCollectedUsdc;
    }

    function _buildLiquidationState(
        CfdTypes.RiskParams memory riskParams,
        uint256 size,
        uint256 price,
        uint256 settlementReachableUsdc,
        int256 liquidationEquityUsdc,
        uint256 maintMarginBps
    ) private pure returns (LiquidationAccountingLib.LiquidationState memory) {
        return LiquidationAccountingLib.buildLiquidationState(
            size,
            price,
            settlementReachableUsdc,
            liquidationEquityUsdc,
            maintMarginBps,
            riskParams.minBountyUsdc,
            riskParams.bountyBps,
            riskParams.keeperShareBps,
            riskParams.protocolShareBps,
            CfdMath.USDC_TO_TOKEN_SCALE
        );
    }

    /// @notice Computes post-liquidation effective assets, maximum liability, and degraded-mode transition.
    /// @dev The entire position max-profit envelope is removed. Physical assets gain collected price pledge, the LP
    ///      liquidation fee, and action cash, then lose an immediate price payout. Deferred price gain increases claims;
    ///      same-account claim consumption reduces them. Diagnostic write-off and waived actions never enter assets.
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

        int256 physicalAssetsDelta = int256(delta.settlementSeizedUsdc + delta.actionChargeCollectedUsdc)
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

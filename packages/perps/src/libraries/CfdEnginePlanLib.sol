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
///      settlement token uses 6 decimals, prices use 8 decimals, sizes/open interest use 18 decimals, raw entry notional uses
///      26 decimals, ratios use 1e18 WAD, rates use a 10,000 basis-point denominator, and timestamps use Unix seconds.
library CfdEnginePlanLib {

    /// @notice A canonical snapshot omitted settlement backing required by negative lifetime VPI.
    error CfdEnginePlanLib__VpiRebateReserveUnderfunded();

    // ──────────────────────────────────────────────
    //  HELPERS
    // ──────────────────────────────────────────────

    /// @notice Replaces one position's post-carry margin inside its aggregate side-margin total.
    /// @dev Subtracts the replaced contribution first, avoiding an artificial signed-intermediate limit. Callers
    ///      supply a consistent aggregate and check headroom for the new contribution.
    /// @param sideTotalMarginAfterCarry Aggregate selected-side margin after carry realization.
    /// @param effectivePositionMarginAfterCarry The account position's contribution contained in that aggregate.
    /// @param positionMarginAfterOpen Replacement contribution after the open/increase.
    /// @return sideTotalMarginAfterOpen Updated aggregate selected-side margin.
    function computeSideTotalMarginAfterOpen(
        uint256 sideTotalMarginAfterCarry,
        uint256 effectivePositionMarginAfterCarry,
        uint256 positionMarginAfterOpen
    ) internal pure returns (uint256 sideTotalMarginAfterOpen) {
        return sideTotalMarginAfterCarry - effectivePositionMarginAfterCarry + positionMarginAfterOpen;
    }

    /// @notice Returns the exact nonwithdrawable backing required by a signed lifetime-VPI balance.
    function _negativeVpiReserveTarget(
        int256 vpiAccruedAssets
    ) private pure returns (uint256 targetAssets) {
        if (vpiAccruedAssets < 0) {
            // This form also supports `type(int256).min` without negating it directly.
            targetAssets = uint256(-(vpiAccruedAssets + 1)) + 1;
        }
    }

    /// @notice Projects release of no-longer-required VPI backing into an account-bucket snapshot.
    function _accountBucketsAfterVpiReserveRelease(
        IMarginClearinghouse.AccountAssetBuckets memory buckets,
        uint256 releaseAssets
    ) private pure returns (IMarginClearinghouse.AccountAssetBuckets memory) {
        if (releaseAssets == 0) {
            return buckets;
        }
        buckets.otherLockedMarginAssets -= releaseAssets;
        buckets.totalLockedMarginAssets -= releaseAssets;
        buckets.freeSettlementAssets = buckets.settlementBalanceAssets > buckets.totalLockedMarginAssets
            ? buckets.settlementBalanceAssets - buckets.totalLockedMarginAssets
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
                || code == CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED
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
                || code == CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED
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
        if (side == CfdTypes.Side.LONG) {
            selected = snap.longSide;
            opposite = snap.shortSide;
        } else {
            selected = snap.shortSide;
            opposite = snap.longSide;
        }
    }

    /// @notice Selects one aggregate side snapshot.
    /// @param snap Complete planner snapshot.
    /// @param side Side to select.
    /// @return selected LONG snapshot for `LONG`, otherwise SHORT snapshot.
    function _selectedSide(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side
    ) private pure returns (CfdEnginePlanTypes.SideSnapshot memory selected) {
        selected = side == CfdTypes.Side.LONG ? snap.longSide : snap.shortSide;
    }

    /// @notice Computes all carry currently payable by the snapshot position.
    /// @dev Starts with checkpointed `unsettledCarryAssets`. Indexed carry is added only for a nonzero position and borrow
    ///      base whose selected-side carry index exceeds the position checkpoint. Index conversion rounds down.
    /// @param snap Position, side-index, borrow-base, and unsettled-carry snapshot.
    /// @return Pending carry in 6-decimal settlement token.
    function _pendingCarryAssets(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) private pure returns (uint256) {
        if (snap.position.size == 0 || snap.positionBorrowBaseAssets == 0) {
            return snap.unsettledCarryAssets;
        }
        CfdEnginePlanTypes.SideSnapshot memory side = _selectedSide(snap, snap.position.side);
        if (side.carryIndex <= snap.positionLastCarryIndex) {
            return snap.unsettledCarryAssets;
        }
        return snap.unsettledCarryAssets
            + PositionRiskAccountingLib.computeIndexedCarryAssets(
            snap.positionBorrowBaseAssets, side.carryIndex - snap.positionLastCarryIndex
        );
    }

    /// @notice Computes absolute directional open-interest skew at a price.
    /// @dev Each side is independently converted from size to settlement token with floor division before taking the difference.
    /// @param long LONG aggregate side snapshot.
    /// @param short SHORT aggregate side snapshot.
    /// @param price Price used to value both sides.
    /// @return Absolute LONG-versus-SHORT skew in 6-decimal settlement token.
    function _absSkewAssets(
        CfdEnginePlanTypes.SideSnapshot memory long,
        CfdEnginePlanTypes.SideSnapshot memory short,
        uint256 price
    ) private pure returns (uint256) {
        uint256 longAssets = (long.openInterest * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        uint256 shortAssets = (short.openInterest * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        return longAssets > shortAssets ? longAssets - shortAssets : shortAssets - longAssets;
    }

    /// @notice Computes skew state after adding an order's size to one side.
    /// @dev Each post-trade side notional is independently rounded down to settlement token before taking the difference.
    /// @param long LONG aggregate state before the open.
    /// @param short SHORT aggregate state before the open.
    /// @param side Side receiving the size increase.
    /// @param sizeDelta Size added to the selected side.
    /// @param price Price used to value open interest.
    /// @return postSkewAssets Post-open absolute skew in 6-decimal settlement token.
    /// @return orderSideIsPostOpenHeavy Whether the side receiving the open is heavier after the trade.
    function _postOpenSkewAssets(
        CfdEnginePlanTypes.SideSnapshot memory long,
        CfdEnginePlanTypes.SideSnapshot memory short,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 price
    ) private pure returns (uint256 postSkewAssets, bool orderSideIsPostOpenHeavy) {
        uint256 longOi = long.openInterest;
        uint256 shortOi = short.openInterest;
        if (side == CfdTypes.Side.LONG) {
            longOi += sizeDelta;
        } else {
            shortOi += sizeDelta;
        }
        uint256 postLongAssets = (longOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        uint256 postShortAssets = (shortOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        postSkewAssets =
            postLongAssets > postShortAssets ? postLongAssets - postShortAssets : postShortAssets - postLongAssets;
        orderSideIsPostOpenHeavy =
            side == CfdTypes.Side.LONG ? postLongAssets > postShortAssets : postShortAssets > postLongAssets;
    }

    /// @notice Computes absolute skew from explicit LONG and SHORT open-interest values.
    /// @dev Each side is independently rounded down to settlement token before taking the difference.
    /// @param longOi LONG open interest, with 18 decimals.
    /// @param shortOi SHORT open interest, with 18 decimals.
    /// @param price Price used to value both sides, with 8 decimals.
    /// @return Absolute directional skew in 6-decimal settlement token.
    function _skewAssets(
        uint256 longOi,
        uint256 shortOi,
        uint256 price
    ) private pure returns (uint256) {
        uint256 longAssets = (longOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        uint256 shortAssets = (shortOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        return longAssets > shortAssets ? longAssets - shortAssets : shortAssets - longAssets;
    }

    // ──────────────────────────────────────────────
    //  PLAN OPEN
    // ──────────────────────────────────────────────

    /// @notice Plans an open or same-side increase from a complete engine snapshot.
    /// @dev Execution price is capped by `snap.capPrice`. For a live position, pending carry is first projected into a
    ///      local memory snapshot and must be fully collectible; a zero-size position skips that realization even
    ///      if an inconsistent snapshot supplies unsettled carry. The planner then rejects an opposing live position,
    ///      degraded mode, a position too small to support the minimum bounty, insufficient clearinghouse funds,
    ///      post-operation insolvency, insufficient initial margin/equity, or pool-relative skew above the configured
    ///      maximum unless the order strictly reduces an existing imbalance without making its side the heavier side.
    ///      Zero or non-quantized order sizes and underfunded dedicated reserves are rejected. Zero economic depth
    ///      rejects all opens. On a business-rule failure `valid` remains false, `revertCode` identifies
    ///      the first failed check, and previously populated fields are diagnostic only. VPI, notional, fee, margin, and skew-cap divisions round down in
    ///      their respective calculations.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param order Open/increase order; account, side, size, and margin are consumed by this planner.
    /// @param executionPrice Oracle execution price before the protocol cap.
    /// @return delta Complete open mutation plan or the first typed failure result.
    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        CfdEnginePlanTypes.RawSnapshot memory effectiveSnap = snap;
        delta.account = order.account;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        delta.posSide = order.side;

        if (order.sizeDelta == 0 || order.sizeDelta % CfdTypes.SIZE_QUANTUM != 0) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INVALID_SIZE_QUANTUM;
            return delta;
        }
        if (
            order.sizeDelta / CfdTypes.SIZE_QUANTUM > type(uint112).max || order.marginDelta > uint256(type(int256).max)
        ) {
            return _numericOpenFailure(delta);
        }
        delta.pendingCarryAssets = _pendingCarryAssets(effectiveSnap);

        if (
            effectiveSnap.position.size > 0
                && _applyPendingCarryRealizationToSnapshot(effectiveSnap, delta.pendingCarryAssets)
                    != delta.pendingCarryAssets
        ) {
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

        _planOpenState(effectiveSnap, order, delta);
        if (delta.revertCode != CfdEnginePlanTypes.OpenRevertCode.OK) {
            return delta;
        }
        OpenAccountingLib.OpenState memory openState = delta.openState;
        CfdEnginePlanTypes.SideSnapshot memory selected = _selectedSide(effectiveSnap, order.side);
        delta.sideTotalMarginBefore = selected.totalMargin;

        delta.tradeCostAssets = openState.tradeCostAssets;
        delta.marginDeltaAssets = order.marginDelta;
        delta.poolRebatePayoutAssets = openState.tradeCostAssets < 0 ? uint256(-openState.tradeCostAssets) : 0;

        if (
            !_lifetimeVpiAdditionFits(effectiveSnap.position.vpiAccrued, openState.vpiAssets)
                || delta.poolRebatePayoutAssets
                    > type(uint256).max - effectiveSnap.accountBuckets.settlementBalanceAssets
        ) {
            return _numericOpenFailure(delta);
        }

        delta.vpiRebateReserveBeforeAssets = effectiveSnap.vpiRebateReserveAssets;
        if (delta.vpiRebateReserveBeforeAssets < _negativeVpiReserveTarget(effectiveSnap.position.vpiAccrued)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED;
            return delta;
        }
        delta.vpiRebateReserveAfterAssets =
            _negativeVpiReserveTarget(effectiveSnap.position.vpiAccrued + openState.vpiAssets);
        {
            uint256 vpiReserveReleaseAssets = delta.vpiRebateReserveBeforeAssets > delta.vpiRebateReserveAfterAssets
                ? delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
                : 0;
            IMarginClearinghouse.AccountAssetBuckets memory openCostBuckets =
                _accountBucketsAfterVpiReserveRelease(effectiveSnap.accountBuckets, vpiReserveReleaseAssets);

            MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan =
                MarginClearinghouseAccountingLib.planOpenCostApplication(
                    openCostBuckets, delta.marginDeltaAssets, delta.tradeCostAssets
                );
            if (openCostPlan.insufficientFreeEquity) {
                delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
                return delta;
            }

            _planOpenReserveFunding(effectiveSnap, openCostPlan, delta);
        }
        if (delta.revertCode != CfdEnginePlanTypes.OpenRevertCode.OK) {
            return delta;
        }
        if (
            effectiveSnap.position.margin > uint256(type(int256).max)
                || delta.positionMarginAfterOpen > type(uint144).max
                || effectiveSnap.traderClaimBalanceForAccount > type(uint144).max - delta.positionMarginAfterOpen
                || delta.positionMarginAfterOpen
                    > type(uint256).max - (delta.sideTotalMarginBefore - effectiveSnap.position.margin)
                || openState.newEntryNotional - openState.oldEntryNotional > type(uint256).max - selected.entryNotional
                || openState.addedMaxProfitAssets > type(uint256).max - selected.maxProfitAssets
        ) {
            return _numericOpenFailure(delta);
        }
        // The terminal book reads P+C into uint144. Close commitment reserves no pledge and cannot increase P+C.

        delta.newPosSize = openState.newSize;
        delta.newPosEntryPrice = openState.newEntryPrice;
        delta.newPosEntryCostAssetAtoms = openState.newEntryCostAssetAtoms;
        delta.posVpiAccruedDelta = openState.vpiAssets;
        delta.posMaxProfitIncrease = openState.addedMaxProfitAssets;
        delta.netMarginChange = int256(delta.positionMarginAfterOpen) - int256(effectiveSnap.position.margin);

        delta.sideOiIncrease = order.sizeDelta;
        if (openState.newEntryNotional >= openState.oldEntryNotional) {
            delta.sideEntryNotionalDelta = int256(openState.newEntryNotional - openState.oldEntryNotional);
        } else {
            delta.sideEntryNotionalDelta = -int256(openState.oldEntryNotional - openState.newEntryNotional);
        }
        delta.sideMaxProfitIncrease = openState.addedMaxProfitAssets;

        delta.executionFeeAssets = openState.executionFeeAssets;
        delta.sideTotalMarginAfterOpen = computeSideTotalMarginAfterOpen(
            delta.sideTotalMarginBefore, effectiveSnap.position.margin, delta.positionMarginAfterOpen
        );

        {
            uint256 projectedLiability = selected.maxProfitAssets + delta.sideMaxProfitIncrease;
            uint256 oppositeLiability = order.side == CfdTypes.Side.LONG
                ? effectiveSnap.shortSide.maxProfitAssets
                : effectiveSnap.longSide.maxProfitAssets;
            if (oppositeLiability > projectedLiability) {
                projectedLiability = oppositeLiability;
            }
            if (
                projectedLiability > type(uint256).max - effectiveSnap.totalTraderClaimBalanceAssets
                    || (openState.vpiAssets > 0
                        && uint256(openState.vpiAssets) > type(uint256).max - effectiveSnap.poolCashAssets)
            ) {
                return _numericOpenFailure(delta);
            }
        }

        if (!_applyOpenSettlementBufferAfterPlan(effectiveSnap, delta)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;
            return delta;
        }

        (bool riskFits, PositionRiskAccountingLib.PositionRiskState memory postOpenRiskState) =
            _buildPostOpenRiskState(effectiveSnap, delta);
        if (!riskFits || openState.initialMarginRequirementAssets > uint256(type(int256).max)) {
            return _numericOpenFailure(delta);
        }
        if (
            postOpenRiskState.liquidatable
                || postOpenRiskState.equityAssets <= int256(openState.initialMarginRequirementAssets)
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
            return delta;
        }

        delta.valid = true;
    }

    /// @notice Applies aggregate-domain and skew policy before constructing checked open economics once.
    function _planOpenState(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure {
        uint256 netDepthAssets =
            PositionRiskAccountingLib.computeNetPoolDepthAssets(snap.poolAssets, snap.totalTraderClaimBalanceAssets);
        if (netDepthAssets == 0) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;
            return;
        }
        if (!_openTerminalBookEnvelopeFits(snap, order, delta.price)) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED;
            return;
        }
        uint256 selectedOi = _selectedSide(snap, order.side).openInterest;
        if (
            order.sizeDelta > type(uint256).max - selectedOi
                || snap.longSide.openInterest > type(uint256).max / snap.capPrice
                || snap.shortSide.openInterest > type(uint256).max / snap.capPrice
                || selectedOi + order.sizeDelta > type(uint256).max / snap.capPrice
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED;
            return;
        }
        OpenAccountingLib.OpenInputs memory inputs;
        inputs.preSkewAssets = _absSkewAssets(snap.longSide, snap.shortSide, delta.price);
        bool orderSideIsPostOpenHeavy;
        (inputs.postSkewAssets, orderSideIsPostOpenHeavy) =
            _postOpenSkewAssets(snap.longSide, snap.shortSide, order.side, order.sizeDelta, delta.price);
        uint256 maxSkewAssets = Math.mulDiv(netDepthAssets, snap.riskParams.maxSkewRatio, CfdMath.WAD);
        if (
            inputs.postSkewAssets > maxSkewAssets
                && (inputs.postSkewAssets >= inputs.preSkewAssets || orderSideIsPostOpenHeavy)
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
            return;
        }
        inputs.currentSize = snap.position.size;
        inputs.currentEntryCostAssetAtoms = snap.positionEntryCostAssetAtoms;
        inputs.side = order.side;
        inputs.sizeDelta = order.sizeDelta;
        inputs.price = delta.price;
        inputs.capPrice = snap.capPrice;
        inputs.poolDepthAssets = netDepthAssets;
        inputs.executionFeeBps = snap.executionFeeBps;
        inputs.riskParams = snap.riskParams;
        bool valid;
        uint256 rawLiquidationRequirementAssets;
        (valid, delta.openState, rawLiquidationRequirementAssets) = OpenAccountingLib.tryBuildOpenState(inputs);
        if (!valid) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED;
            return;
        }
        // floor(notional*bps/10_000) >= minimum is equivalent to the original cross-product comparison.
        if (rawLiquidationRequirementAssets < snap.riskParams.minBountyAssets) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL;
        }
    }

    /// @notice Keeps opens inside the terminal book's signed aggregate coefficient budgets without extra snapshot data.
    /// @dev Gross lots are exact. For the intercept budget, LONG entry+effective-cap <= lots*CAP_PRICE; SHORT
    ///      entry+effective-cap <= 2*entry. This sufficient envelope is conservative only near astronomical aggregate
    ///      limits (at the default 2e8 cap, the gross-lot limit already implies it). Existing in-domain rounding is unchanged.
    function _openTerminalBookEnvelopeFits(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 price
    ) private pure returns (bool) {
        uint256 maxLots = uint256(int256(type(int112).max));
        uint256 longLots = snap.longSide.openInterest / CfdTypes.SIZE_QUANTUM;
        uint256 shortLots = snap.shortSide.openInterest / CfdTypes.SIZE_QUANTUM;
        uint256 addedLots = order.sizeDelta / CfdTypes.SIZE_QUANTUM;
        if (longLots > maxLots || shortLots > maxLots - longLots || addedLots > maxLots - longLots - shortLots) {
            return false;
        }
        uint256 shortEntry = snap.shortSide.entryNotional / CfdMath.ASSETS_TO_TOKEN_SCALE;
        if (order.side == CfdTypes.Side.LONG) {
            longLots += addedLots;
        } else {
            shortEntry += addedLots * price;
        }
        // Canonical entry costs never exceed their lots*cap. The gross-lot check and uint32 cap bound all products
        // and this sum below uint256, including snapshots at the preexisting terminal-book boundary.
        return longLots * snap.capPrice + 2 * shortEntry <= uint256(int256(type(int144).max));
    }

    function _numericOpenFailure(
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure returns (CfdEnginePlanTypes.OpenDelta memory) {
        delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED;
        return delta;
    }

    function _lifetimeVpiAdditionFits(
        int256 previous,
        int256 change
    ) private pure returns (bool) {
        return previous != type(int256).min && (change <= 0 || previous <= type(int256).max - change)
            && (change >= 0 || previous > type(int256).min - change);
    }

    /// @notice Allocates newly required VPI and liquidation reserves from free cash and new position pledge.
    function _planOpenReserveFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        MarginClearinghouseAccountingLib.OpenCostPlan memory openCostPlan,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure {
        delta.liquidationReserveBeforeAssets = snap.liquidationReserveAssets;
        delta.liquidationReserveAfterAssets = delta.openState.liquidationReserveTargetAssets;
        if (delta.liquidationReserveAfterAssets < delta.liquidationReserveBeforeAssets) {
            delta.liquidationReserveAfterAssets = delta.liquidationReserveBeforeAssets;
        }
        uint256 reserveIncreaseAssets = delta.liquidationReserveAfterAssets - delta.liquidationReserveBeforeAssets;

        uint256 newPledgeAvailableAssets = openCostPlan.resultingPositionMarginAssets > snap.position.margin
            ? openCostPlan.resultingPositionMarginAssets - snap.position.margin
            : 0;
        uint256 vpiReserveIncreaseAssets = delta.vpiRebateReserveAfterAssets > delta.vpiRebateReserveBeforeAssets
            ? delta.vpiRebateReserveAfterAssets - delta.vpiRebateReserveBeforeAssets
            : 0;
        uint256 vpiReserveFromFreeAssets = vpiReserveIncreaseAssets < openCostPlan.resultingFreeSettlementAssets
            ? vpiReserveIncreaseAssets
            : openCostPlan.resultingFreeSettlementAssets;
        delta.vpiRebateReserveFromPledgeAssets = vpiReserveIncreaseAssets - vpiReserveFromFreeAssets;
        if (delta.vpiRebateReserveFromPledgeAssets > newPledgeAvailableAssets) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED;
            return;
        }

        newPledgeAvailableAssets -= delta.vpiRebateReserveFromPledgeAssets;
        if (reserveIncreaseAssets > newPledgeAvailableAssets) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED;
            return;
        }
        delta.positionMarginAfterOpen =
            openCostPlan.resultingPositionMarginAssets - delta.vpiRebateReserveFromPledgeAssets - reserveIncreaseAssets;
    }

    /// @notice Projects the same size-independent carry collection used by open planning, in place.
    /// @dev Quote bounds must use this projected depth and pledge. A false result rules out every open size.
    ///      Callers needing the original snapshot must copy it before calling this function.
    /// @param snap Canonical snapshot to update with projected carry collection.
    /// @return fullyCollectible Whether all pending carry can be collected, or there is no live position.
    function projectOpenCarry(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal pure returns (bool fullyCollectible) {
        if (snap.position.size == 0) {
            return true;
        }
        uint256 pending = _pendingCarryAssets(snap);
        return _applyPendingCarryRealizationToSnapshot(snap, pending) == pending;
    }

    /// @notice Projects the carry checkpoint performed by close commitment, preserving any unpaid carry.
    /// @dev Mutates the snapshot in place. Execution planning starts from this post-commit state so collected carry
    ///      is not charged twice. The live engine checkpoints its index/timestamp even when no carry is due.
    function projectCloseCommitCarry(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal pure returns (uint256 collectedAssets) {
        collectedAssets = _applyPendingCarryRealizationToSnapshot(snap, _pendingCarryAssets(snap));
        snap.positionLastCarryIndex = _selectedSide(snap, snap.position.side).carryIndex;
        snap.position.lastCarryTimestamp = uint64(snap.currentTimestamp);
    }

    /// @notice Projects margin-first carry collection before trade validation and terminal settlement.
    /// @dev Mutates the existing local snapshot in place, including custody, pledge, side margin, borrow base, and
    ///      pool depth. Uncovered carry remains available for existing terminal recovery/waiver rules.
    /// @param snap Canonical, internally consistent snapshot to mutate.
    /// @param pendingCarryAssets Carry requested for realization.
    /// @return realizedCarryAssets Carry covered by active position margin and free settlement.
    function _applyPendingCarryRealizationToSnapshot(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryAssets
    ) private pure returns (uint256 realizedCarryAssets) {
        if (pendingCarryAssets == 0 || snap.position.size == 0) {
            return 0;
        }
        (
            MarginClearinghouseAccountingLib.SettlementConsumption memory consumption,
            IMarginClearinghouse.AccountAssetBuckets memory afterBuckets
        ) = MarginClearinghouseAccountingLib.projectCarryLoss(snap.accountBuckets, pendingCarryAssets);
        realizedCarryAssets = consumption.totalConsumedAssets;
        snap.accountBuckets = afterBuckets;
        snap.position.margin = afterBuckets.activePositionMarginAssets;
        snap.lockedBuckets.positionMarginAssets = afterBuckets.activePositionMarginAssets;
        snap.lockedBuckets.totalLockedMarginAssets = afterBuckets.totalLockedMarginAssets;
        CfdEnginePlanTypes.SideSnapshot memory selected = _selectedSide(snap, snap.position.side);
        selected.totalMargin -= consumption.activeMarginConsumedAssets;
        uint256 borrowBaseAfterAssets =
            PositionRiskAccountingLib.computeBorrowBaseAssets(snap.position.maxProfitAssets, snap.position.margin);
        selected.borrowBaseAssets = selected.borrowBaseAssets - snap.positionBorrowBaseAssets + borrowBaseAfterAssets;
        snap.positionBorrowBaseAssets = borrowBaseAfterAssets;
        snap.positionLastCarryIndex = selected.carryIndex;
        snap.unsettledCarryAssets = consumption.uncoveredAssets;
        snap.poolAssets += realizedCarryAssets;
        snap.poolCashAssets += realizedCarryAssets;
        if (snap.poolQueuesTradingRevenue) {
            snap.poolAdditionalReservedAssets += realizedCarryAssets;
        }
    }

    /// @notice Builds risk state for the position projected by a successful open-cost plan.
    /// @dev Canonical PnL pledge already excludes action charges, rebates, and the liquidation-reserve carve-out, so it
    ///      is used directly without reapplying `tradeCostAssets`. The active threshold is FAD margin during the FAD
    ///      window and maintenance margin otherwise.
    /// @param snap Carry-adjusted snapshot before applying the new open.
    /// @param delta Partially built open delta containing resulting position and trade-cost values.
    /// @return valid Whether the actual equity operands and sum fit signed accounting.
    /// @return riskState Projected PnL, equity, notional, threshold, and liquidation status.
    function _buildPostOpenRiskState(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure returns (bool valid, PositionRiskAccountingLib.PositionRiskState memory riskState) {
        CfdTypes.Position memory projectedPosition = snap.position;
        projectedPosition.side = delta.posSide;
        projectedPosition.size = delta.newPosSize;
        projectedPosition.margin = delta.positionMarginAfterOpen;
        projectedPosition.entryPrice = delta.newPosEntryPrice;
        projectedPosition.vpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;

        if (snap.traderClaimBalanceForAccount > uint256(type(int256).max) - delta.positionMarginAfterOpen) {
            return (false, riskState);
        }
        uint256 reachableCollateralAssets = delta.positionMarginAfterOpen + snap.traderClaimBalanceForAccount;
        (bool isProfit, uint256 pnlAbs) = CfdMath.calculateExactPnl(
            delta.newPosSize / CfdTypes.SIZE_QUANTUM,
            delta.newPosEntryCostAssetAtoms,
            delta.posSide,
            delta.price,
            snap.capPrice
        );
        if (isProfit && reachableCollateralAssets > uint256(type(int256).max) - pnlAbs) {
            return (false, riskState);
        }

        riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.newPosEntryCostAssetAtoms,
            delta.price,
            snap.capPrice,
            reachableCollateralAssets,
            snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps
        );
        return (true, riskState);
    }

    /// @notice Applies the effective-asset requirement when a planned open preserves protected settlement headroom.
    /// @dev The selected side copies are increased by the delta. Current assets use `snap.poolCashAssets`; the physical
    ///      asset delta reflects the fee actually credited from trade cost and affordable post-open pool cash. Trader
    ///      claims and pending payouts are unchanged. The protected buffer is liability-scaled and rounded up. This
    ///      helper writes the required effective-asset target into `delta` on success.
    /// @param snap Current pool, claim, degradation, and side-liability snapshot.
    /// @param delta Partially built open delta with side and economic changes.
    /// @return satisfied Whether projected effective assets cover liability and the configured settlement buffer.
    function _applyOpenSettlementBufferAfterPlan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure returns (bool satisfied) {
        uint256 postMaxLiability;
        {
            CfdEnginePlanTypes.SideSnapshot memory long = snap.longSide;
            CfdEnginePlanTypes.SideSnapshot memory short = snap.shortSide;
            if (delta.posSide == CfdTypes.Side.LONG) {
                long.openInterest += delta.sideOiIncrease;
                long.maxProfitAssets += delta.sideMaxProfitIncrease;
                long.totalMargin = delta.sideTotalMarginAfterOpen;
            } else {
                short.openInterest += delta.sideOiIncrease;
                short.maxProfitAssets += delta.sideMaxProfitIncrease;
                short.totalMargin = delta.sideTotalMarginAfterOpen;
            }
            postMaxLiability = SolvencyAccountingLib.getMaxLiability(long.maxProfitAssets, short.maxProfitAssets);
        }

        uint256 directlyCreditedAssets =
            delta.tradeCostAssets > 0 ? Math.min(uint256(delta.tradeCostAssets), delta.executionFeeAssets) : 0;
        int256 cashDeltaBeforeTopUp = delta.tradeCostAssets - int256(directlyCreditedAssets);
        uint256 poolCashBeforeTopUp;
        if (cashDeltaBeforeTopUp >= 0) {
            (bool fits, uint256 cash) = Math.tryAdd(snap.poolCashAssets, uint256(cashDeltaBeforeTopUp));
            if (!fits) {
                return false;
            }
            poolCashBeforeTopUp = cash;
        } else {
            uint256 rebateAssets = uint256(-cashDeltaBeforeTopUp);
            if (rebateAssets > snap.poolCashAssets) {
                return false;
            }
            poolCashBeforeTopUp = snap.poolCashAssets - rebateAssets;
        }
        uint256 newRevenueReserveAssets =
            snap.poolQueuesTradingRevenue && cashDeltaBeforeTopUp > 0 ? uint256(cashDeltaBeforeTopUp) : 0;
        uint256 feeShortfallAssets = delta.executionFeeAssets - directlyCreditedAssets;
        uint256 topUpAssets = feeShortfallAssets == 0
            ? 0
            : Math.min(
                feeShortfallAssets,
                _freePoolCashAfterLiabilityReserves(
                    snap,
                    poolCashBeforeTopUp,
                    postMaxLiability,
                    snap.totalTraderClaimBalanceAssets,
                    newRevenueReserveAssets
                )
            );
        if (cashDeltaBeforeTopUp < type(int256).min + int256(topUpAssets)) {
            return false;
        }
        int256 physicalAssetsDeltaAssets = cashDeltaBeforeTopUp - int256(topUpAssets);

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolCashAssets,
            SolvencyAccountingLib.getMaxLiability(snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets),
            snap.totalTraderClaimBalanceAssets
        );
        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaAssets: physicalAssetsDeltaAssets,
                maxLiabilityAfterAssets: postMaxLiability,
                traderClaimDeltaAssets: 0,
                pendingPoolPayoutAssets: 0
            }),
            snap.degradedMode
        );
        satisfied = SolvencyAccountingLib.hasRequiredSettlementBuffer(
            result.effectiveAssetsAfterAssets, result.maxLiabilityAfterAssets, snap.settlementBufferBps
        );
        if (satisfied) {
            delta.requiredEffectiveAssetsAfterAssets = result.maxLiabilityAfterAssets
                + SolvencyAccountingLib.settlementBufferTargetAssets(
                    result.maxLiabilityAfterAssets, snap.settlementBufferBps
                );
        }
    }

    // ──────────────────────────────────────────────
    //  PLAN CLOSE
    // ──────────────────────────────────────────────

    /// @notice Plans a full or partial close, including PnL, carry, charges, collection, claims, and solvency.
    /// @dev Execution price is capped by `snap.capPrice`; a close direction differing from a nonzero live position is
    ///      rejected before carry. Carry is collected from active margin, then free settlement before close economics are calculated;
    ///      any unpaid remainder enters the separate action charge. Price losses consume the same-account claim first
    ///      and then eligible PnL pledge, with excess written off. Partial-close pledge consumption and release preserve
    ///      the remaining terminal price curve. Action charges use new price gain, dedicated VPI backing, spendable
    ///      action reserve, free settlement, safely released pledge, and (for a full close only) committed order margin; uncollectible action
    ///      charges reject a partial close but are waived on a full close. Net price gain is paid in full or becomes a
    ///      trader claim after existing claims are reserved. Action rebates use remaining cash, may be paid partially,
    ///      and never create claims. Zero/non-quantized sizes and sizes exceeding the position return typed failures.
    ///      A valid close may project degraded mode; solvency is reported rather than rejected. Rounding follows
    ///      `CloseAccountingLib`.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param order Close order; side must match the nonzero live position before account and size are consumed.
    /// @param executionPrice Oracle execution price before the protocol cap.
    /// @return delta Complete close mutation and solvency plan or the first typed failure result.
    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.account = order.account;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        if (snap.position.size != 0 && order.side != snap.position.side) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.SIDE_MISMATCH;
            return delta;
        }
        delta.pendingCarryAssets = _pendingCarryAssets(snap);
        delta.realizedCarryAssets = _applyPendingCarryRealizationToSnapshot(snap, delta.pendingCarryAssets);

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

        if (snap.vpiRebateReserveAssets < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.VPI_REBATE_RESERVE_UNDERFUNDED;
            return delta;
        }

        return _planValidatedClose(snap, delta);
    }

    function _planValidatedClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory) {
        CfdTypes.Position memory pos = snap.position;
        (delta.totalMarginBefore, delta.postLongOi, delta.postShortOi) =
            _closeOpenInterest(snap, pos.side, delta.sizeDelta);

        delta.closeState =
            _buildCloseState(snap, pos, delta.sizeDelta, delta.price, delta.postLongOi, delta.postShortOi);

        CloseAccountingLib.CloseState memory cs = delta.closeState;
        delta.posSizeDelta = delta.sizeDelta;
        delta.posEntryCostAfterAssetAtoms = cs.remainingEntryCostAssetAtoms;
        if (cs.remainingSize > 0) {
            delta.posEntryPriceAfter = cs.remainingEntryCostAssetAtoms / CfdMath.sizeToLots(cs.remainingSize);
        }
        delta.posMaxProfitReduction = cs.maxProfitReductionAssets;
        delta.posVpiAccruedReduction = cs.proportionalAccrualAssets;
        delta.deletePosition = pos.size == delta.sizeDelta;

        delta.sideOiDecrease = delta.sizeDelta;
        delta.sideEntryNotionalReduction = cs.closedEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE;
        delta.sideMaxProfitReduction = cs.maxProfitReductionAssets;

        delta.unlockMarginAssets = cs.marginToFreeAssets;

        uint256 remainingSize = pos.size - delta.sizeDelta;
        uint256 reserveTargetAssets;
        if (remainingSize > 0) {
            reserveTargetAssets = (CfdMath.sizeToLots(remainingSize) * delta.price * snap.riskParams.bountyBps) / 10_000;
            if (reserveTargetAssets < snap.riskParams.minBountyAssets) {
                reserveTargetAssets = snap.riskParams.minBountyAssets;
            }
        }
        if (snap.liquidationReserveAssets > reserveTargetAssets) {
            delta.liquidationReserveReleaseAssets = snap.liquidationReserveAssets - reserveTargetAssets;
        }
        delta.realizedPnlAssets = cs.realizedPnlAssets;
        delta = _planIsolatedCloseSettlement(snap, delta, cs);
        if (delta.revertCode != CfdEnginePlanTypes.CloseRevertCode.OK) {
            return delta;
        }

        if (remainingSize > 0 && delta.actionChargeWaivedAssets > 0) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE;
            return delta;
        }

        if (remainingSize > 0 && delta.pricePayoutIsImmediate) {
            delta.posMarginAfter += delta.pricePayoutAssets;
        }

        if (remainingSize > 0 && !_postCloseHealthy(snap, delta, cs)) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY;
            return delta;
        }

        delta.totalMarginAfterClose = delta.totalMarginBefore
            + (delta.posMarginAfter > pos.margin ? delta.posMarginAfter - pos.margin : 0)
            - (pos.margin > delta.posMarginAfter ? pos.margin - delta.posMarginAfter : 0);

        delta.solvency = _computeCloseSolvency(snap, delta);
        delta.valid = true;
        return delta;
    }

    /// @notice Separates price PnL from action economics so realized settlement matches the terminal NAV cap.
    function _planIsolatedCloseSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory) {
        if (cs.realizedPnlAssets >= 0) {
            delta.priceGainAssets = uint256(cs.realizedPnlAssets);
        } else {
            delta.priceLossAssets = uint256(-cs.realizedPnlAssets);
            delta.lossAssets = delta.priceLossAssets;
            delta.pricePnlClaimConsumedAssets = snap.traderClaimBalanceForAccount < delta.priceLossAssets
                ? snap.traderClaimBalanceForAccount
                : delta.priceLossAssets;
            uint256 lossAfterClaimAssets = delta.priceLossAssets - delta.pricePnlClaimConsumedAssets;
            delta.pricePnlPledgeConsumedAssets =
                cs.marginToFreeAssets < lossAfterClaimAssets ? cs.marginToFreeAssets : lossAfterClaimAssets;
            uint256 minimumRecoveryAssets = _minimumPartialLossRecoveryPreservingTerminalCap(snap, cs, delta.price);
            uint256 minimumPledgeConsumptionAssets = minimumRecoveryAssets > delta.pricePnlClaimConsumedAssets
                ? minimumRecoveryAssets - delta.pricePnlClaimConsumedAssets
                : 0;
            uint256 maximumPledgeConsumptionAssets =
                lossAfterClaimAssets < snap.position.margin ? lossAfterClaimAssets : snap.position.margin;
            if (minimumPledgeConsumptionAssets > maximumPledgeConsumptionAssets) {
                minimumPledgeConsumptionAssets = maximumPledgeConsumptionAssets;
            }
            if (minimumPledgeConsumptionAssets > delta.pricePnlPledgeConsumedAssets) {
                delta.pricePnlPledgeConsumedAssets = minimumPledgeConsumptionAssets;
            }
            delta.priceLossWrittenOffAssets = lossAfterClaimAssets - delta.pricePnlPledgeConsumedAssets;
        }

        delta.unlockMarginAssets = _maxPricePledgeUnlockPreservingTerminalCap(snap, delta, cs);
        if (cs.remainingSize > 0 && !_limitCloseReleaseByHealth(snap, delta, cs)) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY;
            return delta;
        }
        delta.safeMarginReleaseAssets = delta.unlockMarginAssets;
        delta.posMarginAfter = snap.position.margin - delta.pricePnlPledgeConsumedAssets - delta.unlockMarginAssets;
        delta.existingTraderClaimConsumedAssets = delta.pricePnlClaimConsumedAssets;
        delta.existingTraderClaimRemainingAssets = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedAssets;

        delta.vpiRebateReserveBeforeAssets = snap.vpiRebateReserveAssets;
        delta.vpiRebateReserveAfterAssets =
            _negativeVpiReserveTarget(snap.position.vpiAccrued - cs.proportionalAccrualAssets);

        _planCloseActionSettlement(snap, delta, cs);

        delta.pricePayoutAssets = delta.priceGainAssets - delta.actionChargeWithheldAssets;
        uint256 claimsAfterPriceNettingAssets = snap.totalTraderClaimBalanceAssets - delta.pricePnlClaimConsumedAssets;
        uint256 poolCashAfterCollectionsAssets = snap.poolCashAssets + delta.pricePnlPledgeConsumedAssets
            + delta.actionChargeCollectedAssets - delta.actionProtocolFeeCreditedAssets;
        uint256 freePoolCashAssets =
            CashPriorityLib.reserveFreshPayouts(poolCashAfterCollectionsAssets, claimsAfterPriceNettingAssets)
        .freeCashAssets;
        if (delta.pricePayoutAssets > 0) {
            delta.pricePayoutIsImmediate = freePoolCashAssets >= delta.pricePayoutAssets;
            delta.pricePayoutCreatesClaim = !delta.pricePayoutIsImmediate;
            if (delta.pricePayoutIsImmediate) {
                poolCashAfterCollectionsAssets -= delta.pricePayoutAssets;
            } else {
                claimsAfterPriceNettingAssets += delta.pricePayoutAssets;
            }
        }

        freePoolCashAssets =
        CashPriorityLib.reserveFreshPayouts(poolCashAfterCollectionsAssets, claimsAfterPriceNettingAssets)
        .freeCashAssets;
        if (delta.actionRebateAssets > 0) {
            delta.actionRebatePaidAssets =
                delta.actionRebateAssets < freePoolCashAssets ? delta.actionRebateAssets : freePoolCashAssets;
            delta.actionRebateWaivedAssets = delta.actionRebateAssets - delta.actionRebatePaidAssets;
            poolCashAfterCollectionsAssets -= delta.actionRebatePaidAssets;
        }

        delta.freshTraderPayoutAssets = delta.pricePayoutAssets + delta.actionRebatePaidAssets;
        delta.freshPayoutIsImmediate = !delta.pricePayoutCreatesClaim;
        delta.freshPayoutCreatesClaim = delta.pricePayoutCreatesClaim;

        uint256 feeTopUpAssets = delta.executionFeeAssets - delta.actionProtocolFeeCreditedAssets;
        freePoolCashAssets =
            _freePoolCashForProtocolFee(snap, delta, poolCashAfterCollectionsAssets, claimsAfterPriceNettingAssets);
        delta.protocolFeeTopUpAssets = feeTopUpAssets < freePoolCashAssets ? feeTopUpAssets : freePoolCashAssets;

        if (delta.pricePayoutAssets > 0 || delta.actionRebatePaidAssets > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.GAIN;
        } else if (delta.priceLossAssets > 0 || delta.actionChargeCollectedAssets > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.LOSS;
        }
        return delta;
    }

    /// @dev Mirrors HousePool's live settlement reserve after the close side delta and cash movements preceding
    ///      the protocol-fee top-up. Fresh trader payouts and rebates retain their separate cash-priority policy.
    function _freePoolCashForProtocolFee(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint256 poolCashAssets,
        uint256 traderClaimsAssets
    ) private pure returns (uint256) {
        uint256 maxLiabilityAssets = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets, delta.side, delta.posMaxProfitReduction
        );
        uint256 newRevenueReserveAssets;
        if (snap.poolQueuesTradingRevenue) {
            uint256 cashArrivedRevenueAssets = delta.pricePnlPledgeConsumedAssets + delta.actionChargeCollectedAssets
                - delta.actionProtocolFeeCreditedAssets;
            uint256 retainedRevenueAssets =
                delta.actionChargeWithheldAssets - (delta.executionFeeAssets - delta.actionProtocolFeeCreditedAssets);
            newRevenueReserveAssets = cashArrivedRevenueAssets + retainedRevenueAssets;
        }
        return _freePoolCashAfterLiabilityReserves(
            snap, poolCashAssets, maxLiabilityAssets, traderClaimsAssets, newRevenueReserveAssets
        );
    }

    /// @dev Matches HousePool's settlement-free cash reserve after a projected side update and queued revenue.
    function _freePoolCashAfterLiabilityReserves(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 poolCashAssets,
        uint256 maxLiabilityAssets,
        uint256 traderClaimsAssets,
        uint256 newRevenueReserveAssets
    ) private pure returns (uint256) {
        uint256 reservedAssets = maxLiabilityAssets + traderClaimsAssets
            + SolvencyAccountingLib.settlementBufferTargetAssets(maxLiabilityAssets, snap.settlementBufferBps)
            + snap.poolAdditionalReservedAssets + newRevenueReserveAssets;
        return poolCashAssets > reservedAssets ? poolCashAssets - reservedAssets : 0;
    }

    /// @notice Separates close action charges and rebates from price PnL and allocates the collected execution fee.
    function _planCloseActionSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure {
        int256 actionNetAssets = cs.vpiDeltaAssets
            + int256(
                cs.executionFeeAssets + cs.frozenSpreadAssets + delta.pendingCarryAssets - delta.realizedCarryAssets
            );
        uint256 vpiClawbackWithheldAssets;
        if (actionNetAssets > 0) {
            delta.actionChargeAssessedAssets = uint256(actionNetAssets);
            delta.actionChargeWithheldAssets = delta.priceGainAssets < delta.actionChargeAssessedAssets
                ? delta.priceGainAssets
                : delta.actionChargeAssessedAssets;
            delta.actionChargeToCollectAssets = delta.actionChargeAssessedAssets - delta.actionChargeWithheldAssets;
            uint256 vpiClawbackAssets =
                _negativeVpiReserveTarget(snap.position.vpiAccrued) - delta.vpiRebateReserveAfterAssets;
            vpiClawbackWithheldAssets = delta.actionChargeWithheldAssets < vpiClawbackAssets
                ? delta.actionChargeWithheldAssets
                : vpiClawbackAssets;
            delta.vpiRebateReserveConsumedAssets = vpiClawbackAssets - vpiClawbackWithheldAssets;
            _planCloseCashSources(snap, delta, cs.remainingSize == 0);
        } else if (actionNetAssets < 0) {
            delta.actionRebateAssets = uint256(-actionNetAssets);
        }

        delta.netReleasedMarginAssets = delta.unlockMarginAssets - delta.actionChargeFromReleasedMarginAssets;
        uint256 nonClawbackWithheldAssets = delta.actionChargeWithheldAssets - vpiClawbackWithheldAssets;
        uint256 nonVpiReserveCollectedAssets = delta.actionChargeCollectedAssets - delta.vpiRebateReserveConsumedAssets;
        uint256 executionFeeEligibleAssets = nonClawbackWithheldAssets + nonVpiReserveCollectedAssets;
        delta.executionFeeAssets =
            cs.executionFeeAssets < executionFeeEligibleAssets ? cs.executionFeeAssets : executionFeeEligibleAssets;
        uint256 feeWithheldAssets =
            delta.executionFeeAssets < nonClawbackWithheldAssets ? delta.executionFeeAssets : nonClawbackWithheldAssets;
        uint256 feeToCollectAssets = delta.executionFeeAssets - feeWithheldAssets;
        delta.actionProtocolFeeCreditedAssets =
            feeToCollectAssets < nonVpiReserveCollectedAssets ? feeToCollectAssets : nonVpiReserveCollectedAssets;
    }

    function _postCloseHealthy(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (bool) {
        CfdTypes.Position memory remaining;
        remaining.side = snap.position.side;
        remaining.size = cs.remainingSize;
        uint256 claims =
            delta.existingTraderClaimRemainingAssets + (delta.pricePayoutCreatesClaim ? delta.pricePayoutAssets : 0);
        uint256 bps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        return !PositionRiskAccountingLib.buildExactPriceRiskState(
            remaining, cs.remainingEntryCostAssetAtoms, delta.price, snap.capPrice, delta.posMarginAfter + claims, bps
        )
        .liquidatable;
    }

    function _planCloseCashSources(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        bool terminal
    ) private pure {
        uint256 remainingActionChargeToCollectAssets =
            delta.actionChargeToCollectAssets - delta.vpiRebateReserveConsumedAssets;
        uint256 protectedActionReserveAssets = snap.protectedExecutionBountyAssets + snap.vpiRebateReserveAssets;
        uint256 spendableActionReserveAssets = snap.actionReserveAssets > protectedActionReserveAssets
            ? snap.actionReserveAssets - protectedActionReserveAssets
            : 0;
        delta.actionReserveConsumedAssets = remainingActionChargeToCollectAssets < spendableActionReserveAssets
            ? remainingActionChargeToCollectAssets
            : spendableActionReserveAssets;
        uint256 actionChargeAfterReserveAssets =
            remainingActionChargeToCollectAssets - delta.actionReserveConsumedAssets;
        uint256 releasedVpiReserveAssets = delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
            - delta.vpiRebateReserveConsumedAssets;
        uint256 collectibleFreeSettlementAssets = snap.accountBuckets.freeSettlementAssets + releasedVpiReserveAssets;
        if (terminal) {
            // The full-close reserve is released before pledge attribution and cash collection.
            collectibleFreeSettlementAssets += delta.liquidationReserveReleaseAssets;
        }
        uint256 freeConsumedAssets = actionChargeAfterReserveAssets < collectibleFreeSettlementAssets
            ? actionChargeAfterReserveAssets
            : collectibleFreeSettlementAssets;
        uint256 actionChargeAfterFreeAssets = actionChargeAfterReserveAssets - freeConsumedAssets;
        delta.actionChargeFromReleasedMarginAssets = actionChargeAfterFreeAssets < delta.unlockMarginAssets
            ? actionChargeAfterFreeAssets
            : delta.unlockMarginAssets;
        actionChargeAfterFreeAssets -= delta.actionChargeFromReleasedMarginAssets;
        if (terminal) {
            delta.actionCommittedMarginConsumedAssets = actionChargeAfterFreeAssets
                < snap.lockedBuckets.committedOrderMarginAssets
                ? actionChargeAfterFreeAssets
                : snap.lockedBuckets.committedOrderMarginAssets;
        }
        delta.actionChargeCollectedAssets = delta.vpiRebateReserveConsumedAssets + delta.actionReserveConsumedAssets
            + freeConsumedAssets + delta.actionChargeFromReleasedMarginAssets
            + delta.actionCommittedMarginConsumedAssets;
        delta.actionChargeWaivedAssets = delta.actionChargeToCollectAssets - delta.actionChargeCollectedAssets;
    }

    /// @dev Claims are health collateral, never cash funding. Net gains contribute once whether paid or deferred.
    function _limitCloseReleaseByHealth(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (bool) {
        uint256 pledge = snap.position.margin - delta.pricePnlPledgeConsumedAssets;
        uint256 claims = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedAssets;
        PositionRiskAccountingLib.PositionRiskState memory risk;
        {
            int256 actionNet = cs.vpiDeltaAssets
                + int256(
                    cs.executionFeeAssets + cs.frozenSpreadAssets + delta.pendingCarryAssets - delta.realizedCarryAssets
                );
            uint256 withheld = actionNet > 0 ? uint256(actionNet) : 0;
            if (withheld > delta.priceGainAssets) {
                withheld = delta.priceGainAssets;
            }
            uint256 gain = delta.priceGainAssets - withheld;
            CfdTypes.Position memory remaining;
            remaining.side = snap.position.side;
            remaining.size = cs.remainingSize;
            uint256 bps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
            risk = PositionRiskAccountingLib.buildExactPriceRiskState(
                remaining, cs.remainingEntryCostAssetAtoms, delta.price, snap.capPrice, pledge + claims + gain, bps
            );
        }
        if (risk.liquidatable) {
            return false;
        }
        uint256 headroom = uint256(risk.equityAssets) - risk.maintenanceMarginAssets - 1;
        if (delta.unlockMarginAssets > headroom) {
            delta.unlockMarginAssets = headroom;
        }
        (bool profit, uint256 terminalTarget) = _requiredPostCloseTerminalCapAssets(snap, delta, cs);
        if (!profit && risk.unrealizedPnlAssets < 0) {
            uint256 rawLoss = uint256(-risk.unrealizedPnlAssets);
            uint256 cap = pledge - delta.unlockMarginAssets + claims;
            if ((rawLoss < cap ? rawLoss : cap) != terminalTarget) {
                return false;
            }
        }
        return true;
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
    ) private pure returns (uint256 unlockAssets) {
        uint256 unusedCloseAllocationAssets = cs.marginToFreeAssets > delta.pricePnlPledgeConsumedAssets
            ? cs.marginToFreeAssets - delta.pricePnlPledgeConsumedAssets
            : 0;
        if (cs.remainingSize == 0 || unusedCloseAllocationAssets == 0) {
            return unusedCloseAllocationAssets;
        }

        (bool remainingTraderProfit, uint256 requiredPostCapAssets) =
            _requiredPostCloseTerminalCapAssets(snap, delta, cs);
        if (remainingTraderProfit) {
            return unusedCloseAllocationAssets;
        }

        uint256 remainingClaimAssets = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedAssets;
        uint256 requiredPledgeAssets =
            requiredPostCapAssets > remainingClaimAssets ? requiredPostCapAssets - remainingClaimAssets : 0;
        uint256 pledgeBeforeUnlockAssets = snap.position.margin - delta.pricePnlPledgeConsumedAssets;
        uint256 capPreservingUnlockAssets =
            pledgeBeforeUnlockAssets > requiredPledgeAssets ? pledgeBeforeUnlockAssets - requiredPledgeAssets : 0;
        return unusedCloseAllocationAssets < capPreservingUnlockAssets
            ? unusedCloseAllocationAssets
            : capPreservingUnlockAssets;
    }

    /// @notice Computes the post-close collectible cap required to preserve the pre-close terminal price curve.
    function _requiredPostCloseTerminalCapAssets(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CloseAccountingLib.CloseState memory cs
    ) private pure returns (bool remainingTraderProfit, uint256 requiredPostCapAssets) {
        (bool traderProfit, uint256 traderPnlAbsAssets) = CfdMath.calculateExactPnl(
            CfdMath.sizeToLots(snap.position.size),
            snap.positionEntryCostAssetAtoms,
            snap.position.side,
            delta.price,
            snap.capPrice
        );
        int256 preTraderPnlAssets = traderProfit ? int256(traderPnlAbsAssets) : -int256(traderPnlAbsAssets);
        int256 preRawLpDeltaAssets = -preTraderPnlAssets;
        int256 remainingRawLpDeltaAssets = preRawLpDeltaAssets + cs.realizedPnlAssets;

        // A negative LP curve (remaining trader profit) is not limited by collectible collateral.
        if (remainingRawLpDeltaAssets <= 0) {
            return (true, 0);
        }

        uint256 preCollectibleCapAssets = snap.position.margin + snap.traderClaimBalanceForAccount;
        int256 preTerminalLpDeltaAssets = preRawLpDeltaAssets > int256(preCollectibleCapAssets)
            ? int256(preCollectibleCapAssets)
            : preRawLpDeltaAssets;
        int256 realizedLpDeltaAssets = cs.realizedPnlAssets < 0
            ? int256(delta.pricePnlClaimConsumedAssets + delta.pricePnlPledgeConsumedAssets)
            : -int256(delta.priceGainAssets);
        int256 targetPostTerminalLpDeltaAssets = preTerminalLpDeltaAssets - realizedLpDeltaAssets;
        requiredPostCapAssets = targetPostTerminalLpDeltaAssets > 0 ? uint256(targetPostTerminalLpDeltaAssets) : 0;
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
    ) private pure returns (uint256 minimumRecoveryAssets) {
        if (cs.remainingSize == 0 || cs.realizedPnlAssets >= 0) {
            return 0;
        }

        (bool traderProfit, uint256 traderPnlAbsAssets) = CfdMath.calculateExactPnl(
            CfdMath.sizeToLots(snap.position.size),
            snap.positionEntryCostAssetAtoms,
            snap.position.side,
            price,
            snap.capPrice
        );
        int256 preRawLpDeltaAssets = traderProfit ? -int256(traderPnlAbsAssets) : int256(traderPnlAbsAssets);
        int256 remainingRawLpDeltaAssets = preRawLpDeltaAssets + cs.realizedPnlAssets;
        uint256 preCollectibleCapAssets = snap.position.margin + snap.traderClaimBalanceForAccount;
        int256 preTerminalLpDeltaAssets = preRawLpDeltaAssets > int256(preCollectibleCapAssets)
            ? int256(preCollectibleCapAssets)
            : preRawLpDeltaAssets;
        if (preTerminalLpDeltaAssets <= 0) {
            return 0;
        }

        uint256 remainingRawLossAssets = remainingRawLpDeltaAssets > 0 ? uint256(remainingRawLpDeltaAssets) : 0;
        uint256 preTerminalLossAssets = uint256(preTerminalLpDeltaAssets);
        minimumRecoveryAssets =
            preTerminalLossAssets > remainingRawLossAssets ? preTerminalLossAssets - remainingRawLossAssets : 0;
    }

    /// @notice Projects side open interest after removing close size from the selected side.
    /// @dev Assumes `sizeDelta` does not exceed selected-side open interest. The opposite side is copied unchanged.
    /// @param snap Aggregate LONG and SHORT side snapshots.
    /// @param side Side whose open interest is reduced.
    /// @param sizeDelta Position size being closed.
    /// @return totalMarginBefore Aggregate margin of the selected side before the close.
    /// @return postLongOi Projected LONG open interest.
    /// @return postShortOi Projected SHORT open interest.
    function _closeOpenInterest(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side,
        uint256 sizeDelta
    ) private pure returns (uint256 totalMarginBefore, uint256 postLongOi, uint256 postShortOi) {
        (CfdEnginePlanTypes.SideSnapshot memory selected, CfdEnginePlanTypes.SideSnapshot memory opposite) =
            _selectedAndOpposite(snap, side);

        totalMarginBefore = selected.totalMargin;

        uint256 selectedOiAfter = selected.openInterest - sizeDelta;
        uint256 oppositeOi = opposite.openInterest;
        postLongOi = side == CfdTypes.Side.LONG ? selectedOiAfter : oppositeOi;
        postShortOi = side == CfdTypes.Side.SHORT ? selectedOiAfter : oppositeOi;
    }

    /// @notice Builds detailed close economics from projected post-close open interest.
    /// @dev Pre- and post-close skew are valued at `price`. The delegated calculation prorates margin, exact entry basis,
    ///      and lifetime VPI, derives the closed endpoint-profit envelope, clamps lifetime close VPI from becoming
    ///      negative, and calculates fees/spread.
    /// @param snap Current side, pool-depth, cap, frozen-market, fee, and risk snapshot.
    /// @param pos Position being reduced.
    /// @param sizeDelta Size being closed.
    /// @param price Capped execution price.
    /// @param postLongOi Projected LONG open interest.
    /// @param postShortOi Projected SHORT open interest.
    /// @return Detailed close economics after projected carry collection, excluding any still-unpaid carry and settlement.
    function _buildCloseState(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Position memory pos,
        uint256 sizeDelta,
        uint256 price,
        uint256 postLongOi,
        uint256 postShortOi
    ) private pure returns (CloseAccountingLib.CloseState memory) {
        uint256 preSkewAssets = _absSkewAssets(snap.longSide, snap.shortSide, price);
        uint256 postSkewAssets = _skewAssets(postLongOi, postShortOi, price);
        return CloseAccountingLib.buildCloseState(
            CloseAccountingLib.CloseInputs({
                position: pos,
                positionEntryCostAssetAtoms: snap.positionEntryCostAssetAtoms,
                sizeDelta: sizeDelta,
                oraclePrice: price,
                capPrice: snap.capPrice,
                preSkewAssets: preSkewAssets,
                postSkewAssets: postSkewAssets,
                poolDepthAssets: PositionRiskAccountingLib.computeNetPoolDepthAssets(
                    snap.poolAssets, snap.totalTraderClaimBalanceAssets
                ),
                vpiFactor: snap.riskParams.vpiFactor,
                frozenCloseSpreadBps: snap.frozenCloseSpreadBps,
                oracleFrozen: snap.oracleFrozen,
                executionFeeBps: snap.executionFeeBps
            })
        );
    }

    /// @notice Computes post-close effective assets, maximum liability, and degraded-mode transition.
    /// @dev Maximum liability removes the closed lots' exact max-profit envelope. Physical assets include seized
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
            snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets, delta.side, delta.posMaxProfitReduction
        );

        int256 physicalAssetsDelta = _closePoolPhysicalAssetsDelta(delta);

        uint256 traderClaimIncrease = delta.pricePayoutCreatesClaim ? delta.pricePayoutAssets : 0;

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolAssets,
            SolvencyAccountingLib.getMaxLiability(snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets),
            snap.totalTraderClaimBalanceAssets
        );

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaAssets: physicalAssetsDelta,
                maxLiabilityAfterAssets: postMaxLiability,
                traderClaimDeltaAssets: int256(traderClaimIncrease) - int256(delta.existingTraderClaimConsumedAssets),
                pendingPoolPayoutAssets: 0
            }),
            snap.degradedMode
        );
        sp.effectiveAssetsAfterAssets = result.effectiveAssetsAfterAssets;
        sp.maxLiabilityAfterAssets = result.maxLiabilityAfterAssets;
        sp.triggersDegradedMode = result.triggersDegradedMode;
        sp.postOpDegradedMode = result.postOpDegradedMode;
    }

    /// @notice Computes the signed physical-pool-asset change caused by planned close settlement.
    /// @dev Adds price-PnL pledge and non-protocol action cash collected into the pool. It subtracts protocol-fee
    ///      top-up, immediate price payout, and the actually paid (never claim-backed) action rebate.
    /// @param delta Planned close settlement values.
    /// @return Signed physical asset delta in 6-decimal settlement token.
    function _closePoolPhysicalAssetsDelta(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (int256) {
        uint256 cashInflowAssets = delta.pricePnlPledgeConsumedAssets + delta.actionChargeCollectedAssets
            - delta.actionProtocolFeeCreditedAssets;
        uint256 cashOutflowAssets = delta.protocolFeeTopUpAssets + delta.actionRebatePaidAssets
            + (delta.pricePayoutIsImmediate ? delta.pricePayoutAssets : 0);
        return int256(cashInflowAssets) - int256(cashOutflowAssets);
    }

    // ──────────────────────────────────────────────
    //  PLAN LIQUIDATION
    // ──────────────────────────────────────────────

    /// @notice Plans eligibility and full settlement for liquidating a snapshot position.
    /// @dev Execution price is capped by `snap.capPrice`. A zero-size position returns a nonliquidatable delta after
    ///      populating account and price. An underfunded negative-VPI reserve reverts before eligibility is evaluated.
    ///      Otherwise pending carry is projected against active margin first, then free
    ///      settlement. Exact price health uses the reduced pledge plus same-account claim; any uncovered carry is an
    ///      independent delinquency condition. The liquidation threshold uses FAD margin in
    ///      the FAD window and normal maintenance margin otherwise, with equality liquidatable. A nonliquidatable
    ///      result stops after risk diagnostics; a liquidatable result removes the entire position, plans the split
    ///      charge and residual settlement, and previews solvency. Notional, margin requirement, and rate-based charge
    ///      calculations round down.
    /// @param snap Caller-built position, side, pool, collateral, carry, claim, and risk snapshot.
    /// @param executionPrice Oracle liquidation price before the protocol cap.
    /// @return delta Liquidation eligibility diagnostics and, when eligible, full settlement and solvency plan.
    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice
    ) internal pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.account = snap.account;
        delta.price = price;

        CfdTypes.Position memory pos = snap.position;
        if (pos.size == 0) {
            return delta;
        }
        if (snap.vpiRebateReserveAssets < _negativeVpiReserveTarget(pos.vpiAccrued)) {
            revert CfdEnginePlanLib__VpiRebateReserveUnderfunded();
        }

        delta.pendingCarryAssets = _pendingCarryAssets(snap);
        delta.realizedCarryAssets = _applyPendingCarryRealizationToSnapshot(snap, delta.pendingCarryAssets);
        pos = snap.position;
        delta.side = pos.side;
        delta.posSize = pos.size;
        delta.posMargin = pos.margin;
        delta.posMaxProfit = pos.maxProfitAssets;
        delta.posEntryPrice = pos.entryPrice;
        delta.posEntryCostAssetAtoms = snap.positionEntryCostAssetAtoms;

        uint256 maintMarginBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        // Terminal settlement can reach the dedicated VPI reserve only for its matching clawback; exact price health
        // below deliberately uses PnL pledge plus same-account claim only.
        uint256 settlementReachableAssets = pos.margin + snap.traderClaimBalanceForAccount + snap.vpiRebateReserveAssets;
        delta.liquidationReachableCollateralAssets = settlementReachableAssets;

        delta.riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            pos,
            snap.positionEntryCostAssetAtoms,
            price,
            snap.capPrice,
            pos.margin + snap.traderClaimBalanceForAccount,
            maintMarginBps
        );

        if (!delta.riskState.liquidatable && delta.pendingCarryAssets == delta.realizedCarryAssets) {
            return delta;
        }
        delta.riskState.liquidatable = true;
        delta.liquidatable = true;

        delta = _applyLiquidationSettlement(snap, delta, pos, price, maintMarginBps);
        delta.solvency = _computeLiquidationSolvency(snap, delta, pos);
    }

    /// @notice Separates full-liquidation price PnL, action charges, and the dedicated liquidation reserve.
    /// @dev Price loss consumes only the same-account claim and PnL pledge; excess is a diagnostic write-off. The
    ///      keeper/protocol/LP charge is capped by `liquidationReserveAssets`. Still-unpaid carry and negative lifetime VPI
    ///      are action charges recovered from new price gain first, dedicated VPI backing for its clawback, spendable
    ///      action reserve, pre-existing free settlement (including released VPI backing), then committed order margin.
    ///      Any remainder is waived. These action charges cannot consume PnL pledge, liquidation reserve, or protected
    ///      execution-bounty reserves, and no shortfall becomes protocol debt.
    /// @param snap Account, pool cash, claims, risk parameters, and aggregate side snapshot.
    /// @param delta Liquidatable delta containing precomputed risk state.
    /// @param pos Entire position being liquidated.
    /// @param price Capped liquidation price.
    /// @param maintMarginBps Active maintenance or FAD rate used for liquidation state.
    /// @return Updated liquidation delta containing all position, charge-split, residual, claim, and payout effects.
    function _applyLiquidationSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.LiquidationDelta memory delta,
        CfdTypes.Position memory pos,
        uint256 price,
        uint256 maintMarginBps
    ) private pure returns (CfdEnginePlanTypes.LiquidationDelta memory) {
        delta.liquidationState = _buildLiquidationState(
            snap.riskParams,
            pos.size,
            price,
            snap.liquidationReserveAssets,
            delta.riskState.equityAssets,
            maintMarginBps
        );
        delta.liquidationChargeAssets = delta.liquidationState.liquidationChargeAssets;
        delta.keeperBountyAssets = delta.liquidationState.keeperBountyAssets;
        delta.protocolLiquidationFeeAssets = delta.liquidationState.protocolLiquidationFeeAssets;
        delta.lpLiquidationFeeAssets = delta.liquidationState.lpLiquidationFeeAssets;

        delta.sideOiDecrease = pos.size;
        delta.sideMaxProfitDecrease = pos.maxProfitAssets;
        delta.sideEntryNotionalReduction = snap.positionEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE;

        if (delta.riskState.unrealizedPnlAssets >= 0) {
            delta.priceGainAssets = uint256(delta.riskState.unrealizedPnlAssets);
        } else {
            delta.priceLossAssets = uint256(-delta.riskState.unrealizedPnlAssets);
            delta.pricePnlClaimConsumedAssets = snap.traderClaimBalanceForAccount < delta.priceLossAssets
                ? snap.traderClaimBalanceForAccount
                : delta.priceLossAssets;
            uint256 lossAfterClaimAssets = delta.priceLossAssets - delta.pricePnlClaimConsumedAssets;
            delta.pricePnlPledgeConsumedAssets = pos.margin < lossAfterClaimAssets ? pos.margin : lossAfterClaimAssets;
            delta.priceLossWrittenOffAssets = lossAfterClaimAssets - delta.pricePnlPledgeConsumedAssets;
        }

        delta.existingTraderClaimConsumedAssets = delta.pricePnlClaimConsumedAssets;
        delta.existingTraderClaimRemainingAssets = snap.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedAssets;

        _planLiquidationActionSettlement(snap, pos, delta);

        delta.freshTraderPayoutAssets = delta.priceGainAssets - delta.actionChargeWithheldAssets;
        delta.settlementSeizedAssets = delta.pricePnlPledgeConsumedAssets + delta.lpLiquidationFeeAssets;
        delta.residualAssets = delta.riskState.equityAssets - int256(delta.liquidationChargeAssets);
        delta.residualPlan.mutation.positionMarginUnlockedAssets = pos.margin;

        if (delta.freshTraderPayoutAssets > 0) {
            uint256 claimsAfterPriceNettingAssets =
                snap.totalTraderClaimBalanceAssets - delta.pricePnlClaimConsumedAssets;
            uint256 poolCashAfterCollectionsAssets =
                snap.poolCashAssets + delta.settlementSeizedAssets + delta.actionChargeCollectedAssets;
            delta.freshPayoutIsImmediate = CashPriorityLib.reserveFreshPayouts(
                    poolCashAfterCollectionsAssets, claimsAfterPriceNettingAssets
                )
                .freeCashAssets >= delta.freshTraderPayoutAssets;
            delta.freshPayoutCreatesClaim = !delta.freshPayoutIsImmediate;
        }

        uint256 settlementAfterDebitsAssets = snap.accountBuckets.settlementBalanceAssets
            - delta.pricePnlPledgeConsumedAssets - delta.actionChargeCollectedAssets - delta.liquidationChargeAssets;
        delta.settlementRetainedAssets =
            settlementAfterDebitsAssets + (delta.freshPayoutIsImmediate ? delta.freshTraderPayoutAssets : 0);
        return delta;
    }

    /// @notice Allocates still-unpaid liquidation carry and VPI clawback across price gain, reserves, and account cash.
    function _planLiquidationActionSettlement(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Position memory pos,
        CfdEnginePlanTypes.LiquidationDelta memory delta
    ) private pure {
        uint256 vpiClawbackAssets = _negativeVpiReserveTarget(pos.vpiAccrued);
        delta.vpiRebateReserveBeforeAssets = snap.vpiRebateReserveAssets;
        delta.vpiRebateReserveAfterAssets = 0;
        delta.actionChargeAssessedAssets = delta.pendingCarryAssets - delta.realizedCarryAssets + vpiClawbackAssets;
        delta.actionChargeWithheldAssets = delta.priceGainAssets < delta.actionChargeAssessedAssets
            ? delta.priceGainAssets
            : delta.actionChargeAssessedAssets;
        delta.actionChargeToCollectAssets = delta.actionChargeAssessedAssets - delta.actionChargeWithheldAssets;
        uint256 vpiClawbackWithheldAssets =
            delta.actionChargeWithheldAssets < vpiClawbackAssets ? delta.actionChargeWithheldAssets : vpiClawbackAssets;
        delta.vpiRebateReserveConsumedAssets = vpiClawbackAssets - vpiClawbackWithheldAssets;
        _collectLiquidationActionCharge(snap, delta);
    }

    /// @dev Collects the assessed action charge after fresh gain withholding and dedicated VPI reserve consumption.
    function _collectLiquidationActionCharge(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.LiquidationDelta memory delta
    ) private pure {
        uint256 remainingActionChargeToCollectAssets =
            delta.actionChargeToCollectAssets - delta.vpiRebateReserveConsumedAssets;
        {
            uint256 protectedActionReserveAssets = snap.protectedExecutionBountyAssets + snap.vpiRebateReserveAssets;
            uint256 spendableActionReserveAssets = snap.actionReserveAssets > protectedActionReserveAssets
                ? snap.actionReserveAssets - protectedActionReserveAssets
                : 0;
            delta.actionReserveConsumedAssets = remainingActionChargeToCollectAssets < spendableActionReserveAssets
                ? remainingActionChargeToCollectAssets
                : spendableActionReserveAssets;
        }
        uint256 actionChargeAfterReserveAssets =
            remainingActionChargeToCollectAssets - delta.actionReserveConsumedAssets;
        uint256 freeConsumedAssets;
        {
            uint256 releasedVpiReserveAssets = delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets
                - delta.vpiRebateReserveConsumedAssets;
            uint256 collectibleFreeSettlementAssets =
                snap.accountBuckets.freeSettlementAssets + releasedVpiReserveAssets;
            freeConsumedAssets = actionChargeAfterReserveAssets;
            if (freeConsumedAssets > collectibleFreeSettlementAssets) {
                freeConsumedAssets = collectibleFreeSettlementAssets;
            }
        }
        uint256 actionChargeAfterFreeAssets = actionChargeAfterReserveAssets - freeConsumedAssets;
        delta.actionCommittedMarginConsumedAssets = actionChargeAfterFreeAssets
            < snap.lockedBuckets.committedOrderMarginAssets
            ? actionChargeAfterFreeAssets
            : snap.lockedBuckets.committedOrderMarginAssets;
        delta.actionChargeCollectedAssets = delta.vpiRebateReserveConsumedAssets + delta.actionReserveConsumedAssets
            + freeConsumedAssets + delta.actionCommittedMarginConsumedAssets;
        delta.actionChargeWaivedAssets = delta.actionChargeToCollectAssets - delta.actionChargeCollectedAssets;
    }

    function _buildLiquidationState(
        CfdTypes.RiskParams memory riskParams,
        uint256 size,
        uint256 price,
        uint256 settlementReachableAssets,
        int256 liquidationEquityAssets,
        uint256 maintMarginBps
    ) private pure returns (LiquidationAccountingLib.LiquidationState memory) {
        return LiquidationAccountingLib.buildLiquidationState(
            size,
            price,
            settlementReachableAssets,
            liquidationEquityAssets,
            maintMarginBps,
            riskParams.minBountyAssets,
            riskParams.bountyBps,
            riskParams.keeperShareBps,
            riskParams.protocolShareBps,
            CfdMath.ASSETS_TO_TOKEN_SCALE
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
            snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets, pos.side, pos.maxProfitAssets
        );

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.poolAssets,
            SolvencyAccountingLib.getMaxLiability(snap.longSide.maxProfitAssets, snap.shortSide.maxProfitAssets),
            snap.totalTraderClaimBalanceAssets
        );

        int256 physicalAssetsDelta = int256(delta.settlementSeizedAssets + delta.actionChargeCollectedAssets)
            - int256(delta.freshPayoutIsImmediate ? delta.freshTraderPayoutAssets : 0);

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaAssets: physicalAssetsDelta,
                maxLiabilityAfterAssets: postMaxLiability,
                traderClaimDeltaAssets: int256(delta.freshPayoutCreatesClaim ? delta.freshTraderPayoutAssets : 0)
                - int256(delta.existingTraderClaimConsumedAssets),
                pendingPoolPayoutAssets: 0
            }),
            snap.degradedMode
        );

        sp.effectiveAssetsAfterAssets = result.effectiveAssetsAfterAssets;
        sp.maxLiabilityAfterAssets = result.maxLiabilityAfterAssets;
        sp.triggersDegradedMode = result.triggersDegradedMode;
        sp.postOpDegradedMode = result.postOpDegradedMode;
    }

}

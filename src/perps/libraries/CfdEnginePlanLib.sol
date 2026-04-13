// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {IMarginClearinghouse} from "../interfaces/IMarginClearinghouse.sol";
import {CashPriorityLib} from "./CashPriorityLib.sol";
import {CfdEngineSettlementLib} from "./CfdEngineSettlementLib.sol";
import {CloseAccountingLib} from "./CloseAccountingLib.sol";
import {LiquidationAccountingLib} from "./LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "./MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "./OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "./PositionRiskAccountingLib.sol";
import {SolvencyAccountingLib} from "./SolvencyAccountingLib.sol";

uint256 constant EXECUTION_FEE_BPS = 4;

/// @title CfdEnginePlanLib
/// @notice Pure plan functions for the CfdEngine plan→apply architecture.
///         Each function takes a RawSnapshot and returns a typed delta describing all effects.
///         No storage reads, no external calls — purely deterministic over memory inputs.
library CfdEnginePlanLib {

    // ──────────────────────────────────────────────
    //  HELPERS
    // ──────────────────────────────────────────────

    function computeOpenMarginAfter(
        uint256 marginAfterFunding,
        int256 netMarginChange
    ) internal pure returns (bool drained, uint256 marginAfter) {
        int256 computedMarginAfterSigned = int256(marginAfterFunding) + netMarginChange;
        if (computedMarginAfterSigned < 0) {
            return (true, 0);
        }
        return (false, uint256(computedMarginAfterSigned));
    }

    function computeSideTotalMarginAfterOpen(
        uint256 sideTotalMarginAfterFunding,
        uint256 effectivePositionMarginAfterFunding,
        uint256 positionMarginAfterOpen
    ) internal pure returns (uint256 sideTotalMarginAfterOpen) {
        return uint256(
            int256(sideTotalMarginAfterFunding) + int256(positionMarginAfterOpen)
                - int256(effectivePositionMarginAfterFunding)
        );
    }

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

    function getExecutionFailurePolicyCategory(
        CfdEnginePlanTypes.CloseRevertCode code
    ) internal pure returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory) {
        if (code == CfdEnginePlanTypes.CloseRevertCode.OK) {
            return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None;
        }

        return CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid;
    }

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

    function _absSkewUsdc(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear,
        uint256 price
    ) private pure returns (uint256) {
        uint256 bullUsdc = (bull.openInterest * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 bearUsdc = (bear.openInterest * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        return bullUsdc > bearUsdc ? bullUsdc - bearUsdc : bearUsdc - bullUsdc;
    }

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

    function _planDeferredPayoutConsumption(
        uint256 deferredPayoutUsdc,
        uint256 shortfallUsdc,
        bool shortfallAlreadyIncludesDeferred
    ) private pure returns (uint256 consumedUsdc, uint256 remainingUsdc, uint256 badDebtUsdc) {
        if (deferredPayoutUsdc == 0) {
            return (0, 0, shortfallUsdc);
        }

        if (shortfallAlreadyIncludesDeferred) {
            return (deferredPayoutUsdc, 0, shortfallUsdc);
        }

        consumedUsdc = deferredPayoutUsdc < shortfallUsdc ? deferredPayoutUsdc : shortfallUsdc;
        remainingUsdc = deferredPayoutUsdc - consumedUsdc;
        badDebtUsdc = shortfallUsdc - consumedUsdc;
    }

    function _planCloseDeferredPayoutConsumption(
        uint256 deferredPayoutUsdc,
        CfdEngineSettlementLib.CloseSettlementResult memory lossResult
    )
        private
        pure
        returns (uint256 consumedUsdc, uint256 remainingUsdc, uint256 feeRecoveredUsdc, uint256 badDebtUsdc)
    {
        if (deferredPayoutUsdc == 0 || lossResult.shortfallUsdc == 0) {
            return (0, deferredPayoutUsdc, 0, lossResult.badDebtUsdc);
        }

        consumedUsdc = deferredPayoutUsdc < lossResult.shortfallUsdc ? deferredPayoutUsdc : lossResult.shortfallUsdc;
        remainingUsdc = deferredPayoutUsdc - consumedUsdc;

        uint256 feeShortfallUsdc =
            lossResult.shortfallUsdc > lossResult.badDebtUsdc ? lossResult.shortfallUsdc - lossResult.badDebtUsdc : 0;
        feeRecoveredUsdc = consumedUsdc < feeShortfallUsdc ? consumedUsdc : feeShortfallUsdc;

        uint256 badDebtRecoveredUsdc = consumedUsdc - feeRecoveredUsdc;
        badDebtUsdc = lossResult.badDebtUsdc > badDebtRecoveredUsdc ? lossResult.badDebtUsdc - badDebtRecoveredUsdc : 0;
    }

    // ──────────────────────────────────────────────
    //  PLAN OPEN
    // ──────────────────────────────────────────────

    function planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        CfdEnginePlanTypes.RawSnapshot memory effectiveSnap = snap;
        delta.accountId = order.accountId;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        delta.posSide = order.side;
        uint256 carryTimeDelta = effectiveSnap.position.lastCarryTimestamp > 0
            && effectiveSnap.currentTimestamp > effectiveSnap.position.lastCarryTimestamp
            ? effectiveSnap.currentTimestamp - effectiveSnap.position.lastCarryTimestamp
            : 0;
        uint256 carryBaseUsdc = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(
            effectiveSnap.position.size, price, effectiveSnap.accountBuckets.settlementBalanceUsdc
        );
        delta.pendingCarryUsdc = effectiveSnap.unsettledCarryUsdc
            + PositionRiskAccountingLib.computePendingCarryUsdc(
                carryBaseUsdc, effectiveSnap.riskParams.baseCarryBps, carryTimeDelta
            );

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
                vaultDepthUsdc: effectiveSnap.vaultAssetsUsdc,
                executionFeeBps: EXECUTION_FEE_BPS,
                riskParams: effectiveSnap.riskParams
            })
        );
        delta.openState = openState;

        if (
            openState.notionalUsdc * effectiveSnap.riskParams.bountyBps
                < effectiveSnap.riskParams.minBountyUsdc * 10_000
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL;
            return delta;
        }

        delta.tradeCostUsdc = openState.tradeCostUsdc;
        delta.marginDeltaUsdc = order.marginDelta;
        delta.netMarginChange = int256(order.marginDelta) - openState.tradeCostUsdc;
        delta.vaultRebatePayoutUsdc = openState.tradeCostUsdc < 0 ? uint256(-openState.tradeCostUsdc) : 0;

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
        delta.sideEntryFundingContribution = 0;
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
            effectiveSnap.vaultAssetsUsdc > 0
                && ((postSkewUsdc * CfdMath.WAD) / effectiveSnap.vaultAssetsUsdc)
                    > effectiveSnap.riskParams.maxSkewRatio
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
            return delta;
        }

        delta.valid = true;
    }

    function _applyPendingCarryRealizationToOpenSnapshot(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc
    ) private pure returns (bool hasShortfall) {
        if (pendingCarryUsdc == 0 || snap.position.size == 0) {
            return false;
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planFundingLossConsumption(snap.accountBuckets, pendingCarryUsdc);
        if (consumption.uncoveredUsdc > 0) {
            return true;
        }

        snap.accountBuckets.settlementBalanceUsdc -= consumption.totalConsumedUsdc;
        snap.lockedBuckets.positionMarginUsdc -= consumption.activeMarginConsumedUsdc;
        snap.position.margin -= consumption.activeMarginConsumedUsdc;
        snap.vaultAssetsUsdc += pendingCarryUsdc;
        snap.vaultCashUsdc += pendingCarryUsdc;

        snap.accountBuckets = MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            snap.accountBuckets.settlementBalanceUsdc,
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

        uint256 reachableCollateralUsdc = snap.accountBuckets.settlementBalanceUsdc;
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

        int256 physicalAssetsDeltaUsdc = delta.tradeCostUsdc;

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.vaultCashUsdc,
            snap.accumulatedFeesUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalDeferredPayoutUsdc,
            snap.totalDeferredClearerBountyUsdc
        );
        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDeltaUsdc,
                protocolFeesDeltaUsdc: delta.executionFeeUsdc,
                maxLiabilityAfterUsdc: postMaxLiability,
                deferredTraderPayoutDeltaUsdc: 0,
                deferredLiquidationBountyDeltaUsdc: 0,
                pendingVaultPayoutUsdc: 0
            }),
            snap.degradedMode
        );
        return result.effectiveAssetsAfterUsdc < result.maxLiabilityAfterUsdc;
    }

    // ──────────────────────────────────────────────
    //  PLAN CLOSE
    // ──────────────────────────────────────────────

    function planClose(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.accountId = order.accountId;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        uint256 carryTimeDelta = snap.position.lastCarryTimestamp > 0
            && snap.currentTimestamp > snap.position.lastCarryTimestamp
            ? snap.currentTimestamp - snap.position.lastCarryTimestamp
            : 0;
        uint256 carryBaseUsdc = PositionRiskAccountingLib.computeLpBackedNotionalUsdc(
            snap.position.size, price, snap.accountBuckets.settlementBalanceUsdc
        );
        delta.pendingCarryUsdc = snap.unsettledCarryUsdc
            + PositionRiskAccountingLib.computePendingCarryUsdc(
                carryBaseUsdc, snap.riskParams.baseCarryBps, carryTimeDelta
            );

        CfdTypes.Position memory pos = snap.position;
        delta.side = pos.side;

        if (pos.size < order.sizeDelta) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS;
            return delta;
        }

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;

        (CfdEnginePlanTypes.SideSnapshot memory selected, CfdEnginePlanTypes.SideSnapshot memory opposite) =
            _selectedAndOpposite(snap, pos.side);

        delta.totalMarginBefore = selected.totalMargin;

        uint256 preSkewUsdc = _absSkewUsdc(bull, bear, price);

        uint256 selectedOiAfter = selected.openInterest - order.sizeDelta;
        uint256 oppositeOi = opposite.openInterest;
        delta.postBullOi = pos.side == CfdTypes.Side.BULL ? selectedOiAfter : oppositeOi;
        delta.postBearOi = pos.side == CfdTypes.Side.BEAR ? selectedOiAfter : oppositeOi;

        uint256 postBullUsdc = (delta.postBullOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postBearUsdc = (delta.postBearOi * price) / CfdMath.USDC_TO_TOKEN_SCALE;
        uint256 postSkewUsdc = postBullUsdc > postBearUsdc ? postBullUsdc - postBearUsdc : postBearUsdc - postBullUsdc;

        delta.closeState = CloseAccountingLib.buildCloseState(
            pos.size,
            pos.margin,
            pos.entryPrice,
            pos.maxProfitUsdc,
            pos.vpiAccrued,
            pos.side,
            order.sizeDelta,
            price,
            snap.capPrice,
            preSkewUsdc,
            postSkewUsdc,
            snap.vaultAssetsUsdc,
            snap.riskParams.vpiFactor,
            EXECUTION_FEE_BPS
        );

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

        uint256 effectiveVaultCash = snap.vaultCashUsdc;

        delta.executionFeeUsdc = cs.executionFeeUsdc;
        delta.realizedPnlUsdc = cs.realizedPnlUsdc;

        uint256 availableCashForFreshPayouts =
            CashPriorityLib.reserveFreshPayouts(
            effectiveVaultCash,
            snap.accumulatedFeesUsdc,
            snap.totalDeferredPayoutUsdc,
            snap.totalDeferredClearerBountyUsdc
        )
        .freeCashUsdc;

        int256 carryAdjustedSettlementUsdc = cs.netSettlementUsdc - int256(delta.pendingCarryUsdc);

        if (carryAdjustedSettlementUsdc > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.GAIN;
            delta.freshTraderPayoutUsdc = uint256(carryAdjustedSettlementUsdc);
            delta.freshPayoutIsImmediate = availableCashForFreshPayouts >= delta.freshTraderPayoutUsdc;
            delta.freshPayoutIsDeferred = !delta.freshPayoutIsImmediate;
        } else if (carryAdjustedSettlementUsdc < 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.LOSS;
            delta.lossUsdc = uint256(-carryAdjustedSettlementUsdc);
            bool includeOtherLockedMargin = remainingSize == 0;

            IMarginClearinghouse.AccountUsdcBuckets memory closeBuckets =
                _buildCloseSettlementBuckets(snap, cs.marginToFreeUsdc, includeOtherLockedMargin);
            delta.lossConsumption = MarginClearinghouseAccountingLib.planTerminalLossConsumption(
                closeBuckets, cs.remainingMarginUsdc, delta.lossUsdc
            );
            delta.lossResult = CfdEngineSettlementLib.closeSettlementResult(
                delta.lossConsumption.totalConsumedUsdc, delta.lossUsdc, cs.executionFeeUsdc
            );
            delta.syncMarginQueueAmount = delta.lossConsumption.otherLockedMarginConsumedUsdc;
            (
                delta.existingDeferredConsumedUsdc,
                delta.existingDeferredRemainingUsdc,
                delta.deferredFeeRecoveryUsdc,
                delta.badDebtUsdc
            ) = _planCloseDeferredPayoutConsumption(snap.deferredPayoutForAccount, delta.lossResult);
            delta.executionFeeUsdc = delta.lossResult.collectedExecFeeUsdc + delta.deferredFeeRecoveryUsdc;

            if (delta.lossResult.shortfallUsdc > 0 && cs.remainingMarginUsdc > 0) {
                delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER;
                return delta;
            }
        }

        delta.totalMarginAfterClose = delta.totalMarginBefore
            + (cs.remainingMarginUsdc > pos.margin ? cs.remainingMarginUsdc - pos.margin : 0)
            - (pos.margin > cs.remainingMarginUsdc ? pos.margin - cs.remainingMarginUsdc : 0);

        delta.solvency = _computeCloseSolvency(snap, delta, bull, bear);
        delta.valid = true;
    }

    function _computeCloseSolvency(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear
    ) private pure returns (CfdEnginePlanTypes.SolvencyPreview memory sp) {
        if (delta.side == CfdTypes.Side.BULL) {
            bull.openInterest -= delta.sideOiDecrease;
            bull.totalMargin = delta.totalMarginAfterClose;
        } else {
            bear.openInterest -= delta.sideOiDecrease;
            bear.totalMargin = delta.totalMarginAfterClose;
        }

        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc, delta.side, delta.posMaxProfitReduction
        );

        int256 physicalAssetsDelta = int256(delta.lossResult.seizedUsdc)
            - int256(delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0);

        uint256 deferredTraderPayoutIncrease = delta.freshPayoutIsDeferred ? delta.freshTraderPayoutUsdc : 0;

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.vaultAssetsUsdc,
            snap.accumulatedFeesUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalDeferredPayoutUsdc,
            snap.totalDeferredClearerBountyUsdc
        );

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDelta,
                protocolFeesDeltaUsdc: delta.executionFeeUsdc,
                maxLiabilityAfterUsdc: postMaxLiability,
                deferredTraderPayoutDeltaUsdc: int256(deferredTraderPayoutIncrease)
                    - int256(delta.existingDeferredConsumedUsdc),
                deferredLiquidationBountyDeltaUsdc: 0,
                pendingVaultPayoutUsdc: 0
            }),
            snap.degradedMode
        );
        sp.effectiveAssetsAfterUsdc = result.effectiveAssetsAfterUsdc;
        sp.maxLiabilityAfterUsdc = result.maxLiabilityAfterUsdc;
        sp.triggersDegradedMode = result.triggersDegradedMode;
        sp.postOpDegradedMode = result.postOpDegradedMode;
    }

    function _buildCloseSettlementBuckets(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 marginToFreeUsdc,
        bool includeOtherLockedMargin
    ) private pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        uint256 adjustedPosMargin = snap.lockedBuckets.positionMarginUsdc > marginToFreeUsdc
            ? snap.lockedBuckets.positionMarginUsdc - marginToFreeUsdc
            : 0;
        uint256 settlementBalance = snap.accountBuckets.settlementBalanceUsdc;
        if (includeOtherLockedMargin) {
            return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
                settlementBalance,
                adjustedPosMargin,
                snap.lockedBuckets.committedOrderMarginUsdc,
                snap.lockedBuckets.reservedSettlementUsdc
            );
        }

        return MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(
            settlementBalance,
            adjustedPosMargin,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.lockedBuckets.reservedSettlementUsdc
        );
    }

    // ──────────────────────────────────────────────
    //  PLAN LIQUIDATION
    // ──────────────────────────────────────────────

    function planLiquidation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.LiquidationDelta memory delta) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        delta.accountId = snap.accountId;
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

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;

        uint256 maintMarginBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        uint256 settlementReachableUsdc = MarginClearinghouseAccountingLib.getTerminalReachableUsdc(snap.accountBuckets);
        delta.liquidationReachableCollateralUsdc = settlementReachableUsdc;
        uint256 carryTimeDelta = snap.position.lastCarryTimestamp > 0
            && snap.currentTimestamp > snap.position.lastCarryTimestamp
            ? snap.currentTimestamp - snap.position.lastCarryTimestamp
            : 0;
        uint256 carryBaseUsdc =
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(snap.position.size, price, settlementReachableUsdc);
        delta.pendingCarryUsdc = snap.unsettledCarryUsdc
            + PositionRiskAccountingLib.computePendingCarryUsdc(
                carryBaseUsdc, snap.riskParams.baseCarryBps, carryTimeDelta
            );

        delta.riskState = PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            pos, price, snap.capPrice, delta.pendingCarryUsdc, settlementReachableUsdc, maintMarginBps
        );

        if (!delta.riskState.liquidatable) {
            return delta;
        }
        delta.liquidatable = true;

        delta.liquidationState = LiquidationAccountingLib.buildLiquidationState(
            pos.size,
            price,
            settlementReachableUsdc,
            delta.riskState.equityUsdc,
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

        delta.residualUsdc = delta.riskState.equityUsdc - int256(delta.keeperBountyUsdc);
        delta.residualPlan =
            MarginClearinghouseAccountingLib.planLiquidationResidual(snap.accountBuckets, delta.residualUsdc);
        delta.settlementRetainedUsdc = delta.residualPlan.settlementRetainedUsdc;
        (delta.existingDeferredConsumedUsdc, delta.existingDeferredRemainingUsdc, delta.badDebtUsdc) =
            _planDeferredPayoutConsumption(snap.deferredPayoutForAccount, delta.residualPlan.badDebtUsdc, false);
        delta.syncMarginQueueAmount = delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc;

        if (delta.residualPlan.freshTraderPayoutUsdc > 0) {
            delta.freshTraderPayoutUsdc = delta.residualPlan.freshTraderPayoutUsdc;
            uint256 deferredTraderPayoutAfterConsumption =
                snap.totalDeferredPayoutUsdc - delta.existingDeferredConsumedUsdc;
            delta.freshPayoutIsImmediate = CashPriorityLib.reserveFreshPayouts(
                    snap.vaultCashUsdc,
                    snap.accumulatedFeesUsdc,
                    deferredTraderPayoutAfterConsumption,
                    snap.totalDeferredClearerBountyUsdc
                )
                .freeCashUsdc >= delta.freshTraderPayoutUsdc;
            delta.freshPayoutIsDeferred = !delta.freshPayoutIsImmediate;
        }

        if (pos.side == CfdTypes.Side.BULL) {
            bull.openInterest -= pos.size;
            bull.totalMargin -= pos.margin;
        } else {
            bear.openInterest -= pos.size;
            bear.totalMargin -= pos.margin;
        }

        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            bull.maxProfitUsdc, bear.maxProfitUsdc, pos.side, pos.maxProfitUsdc
        );

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.vaultAssetsUsdc,
            snap.accumulatedFeesUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            snap.totalDeferredPayoutUsdc,
            snap.totalDeferredClearerBountyUsdc
        );

        int256 physicalAssetsDelta = int256(delta.residualPlan.settlementSeizedUsdc)
            - int256(delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0);

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDelta,
                protocolFeesDeltaUsdc: 0,
                maxLiabilityAfterUsdc: postMaxLiability,
                deferredTraderPayoutDeltaUsdc: int256(delta.freshPayoutIsDeferred ? delta.freshTraderPayoutUsdc : 0)
                    - int256(delta.existingDeferredConsumedUsdc),
                deferredLiquidationBountyDeltaUsdc: 0,
                pendingVaultPayoutUsdc: delta.keeperBountyUsdc
            }),
            snap.degradedMode
        );

        delta.solvency.effectiveAssetsAfterUsdc = result.effectiveAssetsAfterUsdc;
        delta.solvency.maxLiabilityAfterUsdc = result.maxLiabilityAfterUsdc;
        delta.solvency.triggersDegradedMode = result.triggersDegradedMode;
        delta.solvency.postOpDegradedMode = result.postOpDegradedMode;
    }

}

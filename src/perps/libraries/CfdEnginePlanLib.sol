// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdMath} from "../CfdMath.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {IMarginClearinghouse} from "../interfaces/IMarginClearinghouse.sol";
import {CfdEngineSettlementLib} from "./CfdEngineSettlementLib.sol";
import {CfdEngineSnapshotsLib} from "./CfdEngineSnapshotsLib.sol";
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

    function _computeGlobalFundingPnl(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear
    ) private pure returns (int256 bullFunding, int256 bearFunding) {
        bullFunding =
            (int256(bull.openInterest) * bull.fundingIndex - bull.entryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
        bearFunding =
            (int256(bear.openInterest) * bear.fundingIndex - bear.entryFunding) / int256(CfdMath.FUNDING_INDEX_SCALE);
    }

    function _solvencyCappedFundingPnl(
        CfdEnginePlanTypes.SideSnapshot memory bull,
        CfdEnginePlanTypes.SideSnapshot memory bear
    ) private pure returns (int256) {
        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl(bull, bear);
        return CfdEngineSnapshotsLib.buildFundingSnapshot(bullFunding, bearFunding, bull.totalMargin, bear.totalMargin)
        .solvencyFunding;
    }

    // ──────────────────────────────────────────────
    //  PLAN GLOBAL FUNDING (lightweight, for liquidation)
    // ──────────────────────────────────────────────

    function planGlobalFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime
    ) internal pure returns (CfdEnginePlanTypes.GlobalFundingDelta memory gfd) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        gfd.newLastMarkPrice = price;
        gfd.newLastMarkTime = publishTime;
        gfd.newLastFundingTime = uint64(snap.currentTimestamp);

        uint256 timeDelta =
            snap.currentTimestamp > snap.lastFundingTime ? snap.currentTimestamp - snap.lastFundingTime : 0;

        if (timeDelta > 0) {
            PositionRiskAccountingLib.FundingStepResult memory step = PositionRiskAccountingLib.computeFundingStep(
                PositionRiskAccountingLib.FundingStepInputs({
                    price: snap.lastMarkPrice,
                    bullOi: snap.bullSide.openInterest,
                    bearOi: snap.bearSide.openInterest,
                    timeDelta: timeDelta,
                    vaultDepthUsdc: snap.vaultAssetsUsdc,
                    riskParams: snap.riskParams
                })
            );
            gfd.bullFundingIndexDelta = step.bullFundingIndexDelta;
            gfd.bearFundingIndexDelta = step.bearFundingIndexDelta;
            gfd.fundingAbsSkewUsdc = step.absSkewUsdc;
        }
    }

    // ──────────────────────────────────────────────
    //  PLAN FUNDING (full, for open/close)
    // ──────────────────────────────────────────────

    function planFunding(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 executionPrice,
        uint64 publishTime,
        bool isClose,
        bool isFullClose
    ) internal pure returns (CfdEnginePlanTypes.FundingDelta memory fd) {
        uint256 price = executionPrice > snap.capPrice ? snap.capPrice : executionPrice;
        fd.newLastMarkPrice = price;
        fd.newLastMarkTime = publishTime;

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;

        uint256 timeDelta =
            snap.currentTimestamp > snap.lastFundingTime ? snap.currentTimestamp - snap.lastFundingTime : 0;
        fd.newLastFundingTime = uint64(snap.currentTimestamp);

        if (timeDelta > 0) {
            PositionRiskAccountingLib.FundingStepResult memory step = PositionRiskAccountingLib.computeFundingStep(
                PositionRiskAccountingLib.FundingStepInputs({
                    price: snap.lastMarkPrice,
                    bullOi: bull.openInterest,
                    bearOi: bear.openInterest,
                    timeDelta: timeDelta,
                    vaultDepthUsdc: snap.vaultAssetsUsdc,
                    riskParams: snap.riskParams
                })
            );
            fd.bullFundingIndexDelta = step.bullFundingIndexDelta;
            fd.bearFundingIndexDelta = step.bearFundingIndexDelta;
            fd.fundingAbsSkewUsdc = step.absSkewUsdc;
        }

        CfdTypes.Position memory pos = snap.position;
        if (pos.size == 0) {
            return fd;
        }

        int256 postFundingIndex = pos.side == CfdTypes.Side.BULL
            ? bull.fundingIndex + fd.bullFundingIndexDelta
            : bear.fundingIndex + fd.bearFundingIndexDelta;
        fd.pendingFundingUsdc = PositionRiskAccountingLib.getPendingFunding(pos, postFundingIndex);
        fd.newPosEntryFundingIndex = postFundingIndex;

        int256 fundingDelta = int256(pos.size) * (postFundingIndex - pos.entryFundingIndex);
        fd.sideEntryFundingDelta = fundingDelta;

        if (fd.pendingFundingUsdc != 0) {
            if (fd.pendingFundingUsdc > 0) {
                uint256 gain = uint256(fd.pendingFundingUsdc);
                if (isClose && isFullClose) {
                    fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.CLOSE_SETTLEMENT;
                    fd.closeFundingSettlementUsdc = int256(gain);
                } else if (snap.vaultCashUsdc >= gain) {
                    fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.MARGIN_CREDIT;
                    fd.posMarginIncrease = gain;
                    fd.fundingVaultPayoutUsdc = gain;
                    fd.fundingClearinghouseCreditUsdc = gain;
                } else {
                    fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.DEFERRED_PAYOUT;
                    fd.fundingVaultPayoutUsdc = 0;
                }
            } else {
                uint256 loss = uint256(-fd.pendingFundingUsdc);
                MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
                    MarginClearinghouseAccountingLib.planFundingLossConsumption(snap.accountBuckets, loss);
                fd.fundingLossConsumedFromMargin = consumption.activeMarginConsumedUsdc;
                fd.fundingLossConsumedFromFree = consumption.freeSettlementConsumedUsdc;
                fd.fundingLossUncovered = consumption.uncoveredUsdc;
                fd.posMarginDecrease = consumption.activeMarginConsumedUsdc;

                if (consumption.uncoveredUsdc > 0) {
                    if (!isClose) {
                        fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_REVERT;
                    } else if (!isFullClose) {
                        fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_CLOSE;
                    } else {
                        fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_CLOSE;
                        fd.closeFundingSettlementUsdc = -int256(consumption.uncoveredUsdc);
                    }
                } else {
                    fd.payoutType = CfdEnginePlanTypes.FundingPayoutType.LOSS_CONSUMED;
                }
            }
        }
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
        delta.accountId = order.accountId;
        delta.sizeDelta = order.sizeDelta;
        delta.price = price;
        delta.posSide = order.side;

        if (snap.position.size > 0 && snap.position.side != order.side) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING;
            return delta;
        }

        if (snap.degradedMode) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE;
            return delta;
        }

        delta.funding = planFunding(snap, executionPrice, publishTime, false, false);

        if (delta.funding.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_REVERT) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.FUNDING_EXCEEDS_MARGIN;
            return delta;
        }

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;
        bull.fundingIndex += delta.funding.bullFundingIndexDelta;
        bear.fundingIndex += delta.funding.bearFundingIndexDelta;

        uint256 posMarginAfterFunding =
            snap.position.margin + delta.funding.posMarginIncrease - delta.funding.posMarginDecrease;
        delta.totalMarginBefore =
            snap.position.size > 0 ? (order.side == CfdTypes.Side.BULL ? bull.totalMargin : bear.totalMargin) : 0;
        delta.totalMarginAfterFunding =
            delta.totalMarginBefore + delta.funding.posMarginIncrease - delta.funding.posMarginDecrease;

        uint256 preSkewUsdc = _absSkewUsdc(bull, bear, price);
        uint256 postSkewUsdc = _postOpenSkewUsdc(bull, bear, order.side, order.sizeDelta, price);

        OpenAccountingLib.OpenState memory openState = OpenAccountingLib.buildOpenState(
            OpenAccountingLib.OpenInputs({
                currentSize: snap.position.size,
                currentEntryPrice: snap.position.entryPrice,
                side: order.side,
                sizeDelta: order.sizeDelta,
                price: price,
                capPrice: snap.capPrice,
                preSkewUsdc: preSkewUsdc,
                postSkewUsdc: postSkewUsdc,
                vaultDepthUsdc: snap.vaultAssetsUsdc,
                executionFeeBps: EXECUTION_FEE_BPS,
                currentFundingIndex: order.side == CfdTypes.Side.BULL ? bull.fundingIndex : bear.fundingIndex,
                riskParams: snap.riskParams
            })
        );
        delta.openState = openState;

        if (openState.notionalUsdc * snap.riskParams.bountyBps < snap.riskParams.minBountyUsdc * 10_000) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL;
            return delta;
        }

        {
            uint256 bullMax = bull.maxProfitUsdc;
            uint256 bearMax = bear.maxProfitUsdc;
            if (order.side == CfdTypes.Side.BULL) {
                bullMax += openState.addedMaxProfitUsdc;
            } else {
                bearMax += openState.addedMaxProfitUsdc;
            }
            uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiability(bullMax, bearMax);
            SolvencyAccountingLib.SolvencyState memory solvency = SolvencyAccountingLib.buildSolvencyState(
                snap.vaultCashUsdc,
                snap.accumulatedFeesUsdc,
                postMaxLiability,
                _solvencyCappedFundingPnl(bull, bear),
                snap.totalDeferredPayoutUsdc,
                snap.totalDeferredClearerBountyUsdc
            );
            if (SolvencyAccountingLib.isInsolvent(solvency)) {
                delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;
                return delta;
            }
        }

        if (
            snap.vaultAssetsUsdc > 0
                && ((postSkewUsdc * CfdMath.WAD) / snap.vaultAssetsUsdc) > snap.riskParams.maxSkewRatio
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH;
            return delta;
        }

        delta.tradeCostUsdc = openState.tradeCostUsdc;
        delta.marginDeltaUsdc = order.marginDelta;
        delta.netMarginChange = int256(order.marginDelta) - openState.tradeCostUsdc;
        delta.vaultRebatePayoutUsdc = openState.tradeCostUsdc < 0 ? uint256(-openState.tradeCostUsdc) : 0;

        int256 marginChangeFromFunding =
            int256(delta.funding.posMarginIncrease) - int256(delta.funding.posMarginDecrease);
        int256 totalMarginDelta = marginChangeFromFunding + delta.netMarginChange;
        uint256 computedMarginAfter;
        if (totalMarginDelta >= 0) {
            computedMarginAfter = snap.position.margin + uint256(totalMarginDelta);
        } else {
            uint256 deficit = uint256(-totalMarginDelta);
            if (snap.position.margin < deficit) {
                delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
                return delta;
            }
            computedMarginAfter = snap.position.margin - deficit;
        }

        if (
            OpenAccountingLib.effectiveMarginAfterTradeCost(computedMarginAfter, openState.tradeCostUsdc)
                < openState.initialMarginRequirementUsdc
        ) {
            delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
            return delta;
        }

        delta.newPosSize = openState.newSize;
        delta.newPosEntryPrice = openState.newEntryPrice;
        delta.posVpiAccruedDelta = openState.vpiUsdc;
        delta.posMaxProfitIncrease = openState.addedMaxProfitUsdc;
        delta.posMarginAfter = computedMarginAfter;

        delta.sideOiIncrease = order.sizeDelta;
        if (openState.newEntryNotional >= openState.oldEntryNotional) {
            delta.sideEntryNotionalDelta = int256(openState.newEntryNotional - openState.oldEntryNotional);
        } else {
            delta.sideEntryNotionalDelta = -int256(openState.oldEntryNotional - openState.newEntryNotional);
        }
        delta.sideEntryFundingContribution = openState.positionFundingContribution;
        delta.sideMaxProfitIncrease = openState.addedMaxProfitUsdc;

        delta.executionFeeUsdc = openState.executionFeeUsdc;
        delta.totalMarginAfterOpen = delta.totalMarginAfterFunding
            + (computedMarginAfter > posMarginAfterFunding ? computedMarginAfter - posMarginAfterFunding : 0)
            - (posMarginAfterFunding > computedMarginAfter ? posMarginAfterFunding - computedMarginAfter : 0);

        delta.valid = true;
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

        CfdTypes.Position memory pos = snap.position;
        delta.side = pos.side;

        if (pos.size < order.sizeDelta) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS;
            return delta;
        }

        bool isFullClose = order.sizeDelta == pos.size;
        delta.funding = planFunding(snap, executionPrice, publishTime, true, isFullClose);

        if (delta.funding.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_UNCOVERED_CLOSE && !isFullClose) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.FUNDING_PARTIAL_CLOSE_UNDERWATER;
            return delta;
        }

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;
        bull.fundingIndex += delta.funding.bullFundingIndexDelta;
        bear.fundingIndex += delta.funding.bearFundingIndexDelta;

        uint256 posMarginAfterFunding = pos.margin + delta.funding.posMarginIncrease - delta.funding.posMarginDecrease;
        pos.margin = posMarginAfterFunding;

        (CfdEnginePlanTypes.SideSnapshot memory selected, CfdEnginePlanTypes.SideSnapshot memory opposite) =
            _selectedAndOpposite(snap, pos.side);
        selected.fundingIndex += pos.side == CfdTypes.Side.BULL
            ? delta.funding.bullFundingIndexDelta
            : delta.funding.bearFundingIndexDelta;

        delta.totalMarginBefore = selected.totalMargin;
        delta.totalMarginAfterFunding =
            selected.totalMargin + delta.funding.posMarginIncrease - delta.funding.posMarginDecrease;

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
            EXECUTION_FEE_BPS,
            delta.funding.closeFundingSettlementUsdc
        );

        CloseAccountingLib.CloseState memory cs = delta.closeState;
        delta.posMarginAfter = cs.remainingMarginUsdc;
        delta.posSizeDelta = order.sizeDelta;
        delta.posMaxProfitReduction = cs.maxProfitReductionUsdc;
        delta.posVpiAccruedReduction = cs.proportionalAccrualUsdc;
        delta.deletePosition = pos.size == order.sizeDelta;

        delta.sideOiDecrease = order.sizeDelta;
        delta.sideEntryNotionalReduction = order.sizeDelta * pos.entryPrice;
        delta.sideEntryFundingReduction = int256(order.sizeDelta) * delta.funding.newPosEntryFundingIndex;
        delta.sideMaxProfitReduction = cs.maxProfitReductionUsdc;

        delta.unlockMarginUsdc = cs.marginToFreeUsdc;

        uint256 remainingSize = pos.size - order.sizeDelta;
        if (remainingSize > 0 && cs.remainingMarginUsdc < snap.riskParams.minBountyUsdc) {
            delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION;
            return delta;
        }

        uint256 effectiveVaultCash = snap.vaultCashUsdc;
        if (delta.funding.fundingVaultPayoutUsdc > 0) {
            effectiveVaultCash -= delta.funding.fundingVaultPayoutUsdc;
        }
        if (delta.funding.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_CONSUMED) {
            effectiveVaultCash += delta.funding.fundingLossConsumedFromMargin
            + delta.funding.fundingLossConsumedFromFree;
        }

        delta.executionFeeUsdc = cs.executionFeeUsdc;
        delta.realizedPnlUsdc = cs.realizedPnlUsdc;

        if (cs.netSettlementUsdc > 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.GAIN;
            delta.traderPayoutUsdc = uint256(cs.netSettlementUsdc);
            delta.payoutIsImmediate = effectiveVaultCash >= delta.traderPayoutUsdc;
            delta.payoutIsDeferred = !delta.payoutIsImmediate;
        } else if (cs.netSettlementUsdc < 0) {
            delta.settlementType = CfdEnginePlanTypes.SettlementType.LOSS;
            uint256 lossUsdc = uint256(-cs.netSettlementUsdc);

            IMarginClearinghouse.AccountUsdcBuckets memory closeBuckets =
                _buildCloseSettlementBuckets(snap, cs.marginToFreeUsdc, delta.funding, cs.remainingMarginUsdc);
            delta.lossConsumption = MarginClearinghouseAccountingLib.planTerminalLossConsumption(
                closeBuckets, cs.remainingMarginUsdc, lossUsdc
            );
            delta.lossResult = CfdEngineSettlementLib.closeSettlementResult(
                delta.lossConsumption.totalConsumedUsdc, lossUsdc, cs.executionFeeUsdc
            );
            delta.syncMarginQueueAmount = delta.lossConsumption.otherLockedMarginConsumedUsdc;
            delta.badDebtUsdc = delta.lossResult.badDebtUsdc;
            delta.executionFeeUsdc = delta.lossResult.collectedExecFeeUsdc;

            if (delta.lossResult.shortfallUsdc > 0 && cs.remainingMarginUsdc > 0) {
                delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER;
                return delta;
            }
        }

        delta.totalMarginAfterClose = delta.totalMarginAfterFunding
            + (cs.remainingMarginUsdc > posMarginAfterFunding ? cs.remainingMarginUsdc - posMarginAfterFunding : 0)
            - (posMarginAfterFunding > cs.remainingMarginUsdc ? posMarginAfterFunding - cs.remainingMarginUsdc : 0);

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
            bull.totalMargin = delta.totalMarginAfterClose;
            bull.entryFunding =
                bull.entryFunding + delta.funding.sideEntryFundingDelta - delta.sideEntryFundingReduction;
        } else {
            bear.totalMargin = delta.totalMarginAfterClose;
            bear.entryFunding =
                bear.entryFunding + delta.funding.sideEntryFundingDelta - delta.sideEntryFundingReduction;
        }

        int256 solvencyFunding = _solvencyCappedFundingPnl(bull, bear);

        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc, delta.side, delta.posMaxProfitReduction
        );

        int256 physicalAssetsDelta = int256(delta.lossResult.seizedUsdc)
            - int256(delta.payoutIsImmediate ? delta.traderPayoutUsdc : 0)
            - int256(delta.funding.fundingVaultPayoutUsdc);
        if (delta.funding.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_CONSUMED) {
            physicalAssetsDelta += int256(
                delta.funding.fundingLossConsumedFromMargin + delta.funding.fundingLossConsumedFromFree
            );
        }

        SolvencyAccountingLib.SolvencyState memory currentState = SolvencyAccountingLib.buildSolvencyState(
            snap.vaultAssetsUsdc,
            snap.accumulatedFeesUsdc,
            SolvencyAccountingLib.getMaxLiability(snap.bullSide.maxProfitUsdc, snap.bearSide.maxProfitUsdc),
            solvencyFunding,
            snap.totalDeferredPayoutUsdc,
            snap.totalDeferredClearerBountyUsdc
        );

        SolvencyAccountingLib.PreviewResult memory result = SolvencyAccountingLib.previewPostOpSolvency(
            currentState,
            SolvencyAccountingLib.PreviewDelta({
                physicalAssetsDeltaUsdc: physicalAssetsDelta,
                protocolFeesDeltaUsdc: delta.executionFeeUsdc,
                maxLiabilityAfterUsdc: postMaxLiability,
                deferredTraderPayoutDeltaUsdc: delta.payoutIsDeferred ? delta.traderPayoutUsdc : 0,
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
        CfdEnginePlanTypes.FundingDelta memory fd,
        uint256 remainingPosMarginUsdc
    ) private pure returns (IMarginClearinghouse.AccountUsdcBuckets memory) {
        uint256 posMarginAfterFunding =
            snap.lockedBuckets.positionMarginUsdc + fd.posMarginIncrease - fd.posMarginDecrease;
        uint256 adjustedPosMargin =
            posMarginAfterFunding > marginToFreeUsdc ? posMarginAfterFunding - marginToFreeUsdc : 0;
        uint256 settlementBalance = snap.accountBuckets.settlementBalanceUsdc;
        if (fd.fundingClearinghouseCreditUsdc > 0) {
            settlementBalance += fd.fundingClearinghouseCreditUsdc;
        }
        if (fd.payoutType == CfdEnginePlanTypes.FundingPayoutType.LOSS_CONSUMED) {
            settlementBalance -= fd.fundingLossConsumedFromMargin + fd.fundingLossConsumedFromFree;
        }
        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
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
        delta.posEntryFundingIndex = pos.entryFundingIndex;

        delta.funding = planGlobalFunding(snap, executionPrice, publishTime);

        CfdEnginePlanTypes.SideSnapshot memory bull = snap.bullSide;
        CfdEnginePlanTypes.SideSnapshot memory bear = snap.bearSide;
        bull.fundingIndex += delta.funding.bullFundingIndexDelta;
        bear.fundingIndex += delta.funding.bearFundingIndexDelta;

        int256 postFundingIndex = pos.side == CfdTypes.Side.BULL ? bull.fundingIndex : bear.fundingIndex;
        int256 pendingFunding = PositionRiskAccountingLib.getPendingFunding(pos, postFundingIndex);

        uint256 maintMarginBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        uint256 reachableCollateralUsdc =
            MarginClearinghouseAccountingLib.getLiquidationReachableUsdc(snap.accountBuckets);

        delta.riskState = PositionRiskAccountingLib.buildPositionRiskState(
            pos, price, snap.capPrice, pendingFunding, reachableCollateralUsdc, maintMarginBps
        );

        if (!delta.riskState.liquidatable) {
            return delta;
        }
        delta.liquidatable = true;

        delta.liquidationState = LiquidationAccountingLib.buildLiquidationState(
            pos.size,
            price,
            reachableCollateralUsdc,
            delta.riskState.pendingFundingUsdc,
            delta.riskState.unrealizedPnlUsdc,
            maintMarginBps,
            snap.riskParams.minBountyUsdc,
            snap.riskParams.bountyBps,
            CfdMath.USDC_TO_TOKEN_SCALE
        );
        delta.keeperBountyUsdc = delta.liquidationState.keeperBountyUsdc;

        delta.sideOiDecrease = pos.size;
        delta.sideMaxProfitDecrease = pos.maxProfitUsdc;
        delta.sideEntryNotionalReduction = pos.size * pos.entryPrice;
        delta.sideEntryFundingReduction = int256(pos.size) * pos.entryFundingIndex;
        delta.sideTotalMarginReduction = pos.margin;

        delta.residualUsdc = delta.riskState.equityUsdc - int256(delta.keeperBountyUsdc);
        delta.residualPlan =
            MarginClearinghouseAccountingLib.planLiquidationResidual(snap.accountBuckets, delta.residualUsdc);
        delta.syncMarginQueueAmount = delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc;
        delta.badDebtUsdc = delta.residualPlan.badDebtUsdc;

        if (delta.residualPlan.payoutUsdc > 0) {
            delta.traderPayoutUsdc = delta.residualPlan.payoutUsdc;
            delta.payoutIsImmediate = snap.vaultCashUsdc >= delta.traderPayoutUsdc;
            delta.payoutIsDeferred = !delta.payoutIsImmediate;
        }

        uint256 postMaxLiability = SolvencyAccountingLib.getMaxLiabilityAfterClose(
            bull.maxProfitUsdc, bear.maxProfitUsdc, pos.side, pos.maxProfitUsdc
        );

        SolvencyAccountingLib.SolvencyState memory solvency = SolvencyAccountingLib.buildSolvencyState(
            snap.vaultAssetsUsdc,
            snap.accumulatedFeesUsdc,
            postMaxLiability,
            _solvencyCappedFundingPnl(bull, bear),
            snap.totalDeferredPayoutUsdc + (delta.payoutIsDeferred ? delta.traderPayoutUsdc : 0),
            snap.totalDeferredClearerBountyUsdc
        );
        uint256 effectiveAssetsAfter =
            SolvencyAccountingLib.effectiveAssetsAfterPendingPayout(solvency, delta.keeperBountyUsdc);

        delta.solvency.effectiveAssetsAfterUsdc = effectiveAssetsAfter;
        delta.solvency.maxLiabilityAfterUsdc = postMaxLiability;
        delta.solvency.triggersDegradedMode = !snap.degradedMode && effectiveAssetsAfter < postMaxLiability;
        delta.solvency.postOpDegradedMode = snap.degradedMode || effectiveAssetsAfter < postMaxLiability;
    }

}

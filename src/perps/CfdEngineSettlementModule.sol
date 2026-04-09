// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineSettlementHost} from "./interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementModule} from "./interfaces/ICfdEngineSettlementModule.sol";
import {ICfdVault} from "./interfaces/ICfdVault.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";

contract CfdEngineSettlementModule is ICfdEngineSettlementModule {

    function buildOpenApplyPlan(
        CfdEngineSettlementTypes.OpenApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan) {
        CfdEnginePlanTypes.OpenDelta calldata delta = inputs.delta;
        plan.position = CfdEngineSettlementTypes.PositionState({
            deletePosition: false,
            size: delta.newPosSize,
            entryPrice: delta.newPosEntryPrice,
            maxProfitUsdc: inputs.currentPosition.maxProfitUsdc + delta.posMaxProfitIncrease,
            lastUpdateTime: uint64(inputs.timestampNow),
            lastCarryTimestamp: uint64(inputs.timestampNow),
            vpiAccrued: inputs.currentPosition.vpiAccrued + delta.posVpiAccruedDelta,
            side: inputs.currentPosition.size == 0 ? delta.posSide : inputs.currentPosition.side
        });
        plan.sideDelta = CfdEngineSettlementTypes.SideDelta({
            side: delta.posSide,
            maxProfitDelta: int256(delta.sideMaxProfitIncrease),
            openInterestDelta: int256(delta.sideOiIncrease),
            entryNotionalDelta: delta.sideEntryNotionalDelta
        });
        plan.vaultInflow = CfdEngineSettlementTypes.VaultInflow({
            physicalCashReceivedUsdc: 0,
            protocolOwnedUsdc: 0,
            lpOwnedUsdc: 0
        });
        plan.accumulatedFeesDeltaUsdc = delta.executionFeeUsdc;
    }

    function buildCloseApplyPlan(
        CfdEngineSettlementTypes.CloseApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan) {
        CfdEnginePlanTypes.CloseDelta calldata delta = inputs.delta;
        uint256 newSize = inputs.currentPosition.size - delta.posSizeDelta;
        plan.position = CfdEngineSettlementTypes.PositionState({
            deletePosition: delta.deletePosition,
            size: newSize,
            entryPrice: inputs.currentPosition.entryPrice,
            maxProfitUsdc: inputs.currentPosition.maxProfitUsdc - delta.posMaxProfitReduction,
            lastUpdateTime: uint64(inputs.timestampNow),
            lastCarryTimestamp: uint64(inputs.timestampNow),
            vpiAccrued: inputs.currentPosition.vpiAccrued - delta.posVpiAccruedReduction,
            side: inputs.currentPosition.side
        });
        plan.sideDelta = CfdEngineSettlementTypes.SideDelta({
            side: delta.side,
            maxProfitDelta: -int256(delta.sideMaxProfitReduction),
            openInterestDelta: -int256(delta.sideOiDecrease),
            entryNotionalDelta: -int256(delta.sideEntryNotionalReduction)
        });
        plan.deferred = CfdEngineSettlementTypes.DeferredDelta({
            accountId: delta.accountId,
            existingDeferredConsumedUsdc: delta.existingDeferredConsumedUsdc,
            freshDeferredPayoutUsdc: delta.freshTraderPayoutUsdc
        });
        plan.vaultInflow = CfdEngineSettlementTypes.VaultInflow({
            physicalCashReceivedUsdc: 0,
            protocolOwnedUsdc: 0,
            lpOwnedUsdc: 0
        });
        plan.accumulatedFeesDeltaUsdc = delta.executionFeeUsdc;
        plan.badDebtDeltaUsdc = delta.badDebtUsdc;
        plan.syncMarginQueueAmountUsdc = delta.syncMarginQueueAmount;
    }

    function buildLiquidationApplyPlan(
        CfdEngineSettlementTypes.LiquidationApplyInputs calldata inputs
    ) external pure returns (CfdEngineSettlementTypes.MinimalApplyPlan memory plan) {
        CfdEnginePlanTypes.LiquidationDelta calldata delta = inputs.delta;
        plan.position = CfdEngineSettlementTypes.PositionState({
            deletePosition: true,
            size: 0,
            entryPrice: 0,
            maxProfitUsdc: 0,
            lastUpdateTime: uint64(inputs.timestampNow),
            lastCarryTimestamp: uint64(inputs.timestampNow),
            vpiAccrued: 0,
            side: delta.side
        });
        plan.sideDelta = CfdEngineSettlementTypes.SideDelta({
            side: delta.side,
            maxProfitDelta: -int256(delta.sideMaxProfitDecrease),
            openInterestDelta: -int256(delta.sideOiDecrease),
            entryNotionalDelta: -int256(delta.sideEntryNotionalReduction)
        });
        plan.deferred = CfdEngineSettlementTypes.DeferredDelta({
            accountId: delta.accountId,
            existingDeferredConsumedUsdc: delta.existingDeferredConsumedUsdc,
            freshDeferredPayoutUsdc: delta.freshTraderPayoutUsdc
        });
        plan.keeperBountyUsdc = delta.keeperBountyUsdc;
        plan.badDebtDeltaUsdc = delta.badDebtUsdc;
        plan.syncMarginQueueAmountUsdc = delta.syncMarginQueueAmount;
        plan.pendingVaultPayoutUsdc = delta.keeperBountyUsdc;
    }

    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external {
        host.settlementApplyFundingAndMark(delta.price, publishTime);
        uint256 marginBefore = IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.accountId).positionMarginUsdc;
        host.settlementSyncTotalSideMargin(delta.side, marginBefore, delta.posMarginAfter);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitReduction),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        IMarginClearinghouse(host.clearinghouse()).unlockPositionMargin(delta.accountId, delta.unlockMarginUsdc);

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.GAIN) {
            if (delta.freshTraderPayoutUsdc > 0) {
                host.settlementRecordDeferredTraderPayout(delta.accountId, delta.freshTraderPayoutUsdc);
            }
            if (delta.pendingCarryUsdc > 0) {
                ICfdVault(host.vault()).recordTradingRevenueInflow(delta.pendingCarryUsdc);
            }
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            uint64[] memory reservationOrderIds = IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.accountId);
            (uint256 seizedUsdc,) = IMarginClearinghouse(host.clearinghouse()).consumeCloseLoss(
                delta.accountId,
                reservationOrderIds,
                uint256(-delta.closeState.netSettlementUsdc),
                delta.posMarginAfter,
                delta.deletePosition,
                host.vault()
            );
            uint256 cashCollectedExecutionFeeUsdc = delta.executionFeeUsdc > delta.deferredFeeRecoveryUsdc
                ? delta.executionFeeUsdc - delta.deferredFeeRecoveryUsdc
                : 0;
            uint256 protocolFeeInflowUsdc = seizedUsdc > cashCollectedExecutionFeeUsdc ? cashCollectedExecutionFeeUsdc : seizedUsdc;
            if (seizedUsdc > 0) {
                if (protocolFeeInflowUsdc > 0) {
                    ICfdVault(host.vault()).recordProtocolInflow(protocolFeeInflowUsdc);
                }
                if (seizedUsdc > protocolFeeInflowUsdc) {
                    ICfdVault(host.vault()).recordTradingRevenueInflow(seizedUsdc - protocolFeeInflowUsdc);
                }
            }
            if (delta.syncMarginQueueAmount > 0) {
                IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.accountId);
            }
            if (delta.existingDeferredConsumedUsdc > 0) {
                host.settlementConsumeDeferredTraderPayout(delta.accountId, delta.existingDeferredConsumedUsdc);
            }
            if (delta.badDebtUsdc > 0) {
                host.settlementAccumulateBadDebt(delta.badDebtUsdc);
            }
        } else if (delta.pendingCarryUsdc > 0) {
            ICfdVault(host.vault()).recordTradingRevenueInflow(delta.pendingCarryUsdc);
        }

        if (delta.executionFeeUsdc > 0) {
            host.settlementAccumulateFees(delta.executionFeeUsdc);
        }

        if (delta.deletePosition) {
            host.settlementDeletePosition(delta.accountId);
        } else {
            host.settlementWritePosition(
                delta.accountId,
                CfdEngineSettlementTypes.PositionState({
                    deletePosition: false,
                    size: delta.closeState.remainingSize,
                    entryPrice: currentPosition.entryPrice,
                    maxProfitUsdc: currentPosition.maxProfitUsdc - delta.posMaxProfitReduction,
                    lastUpdateTime: uint64(block.timestamp),
                    lastCarryTimestamp: uint64(block.timestamp),
                    vpiAccrued: currentPosition.vpiAccrued - delta.posVpiAccruedReduction,
                    side: currentPosition.side
                })
            );
        }
    }

    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime
    ) external returns (uint256 keeperBountyUsdc) {
        host.settlementApplyFundingAndMark(delta.price, publishTime);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitDecrease),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );
        host.settlementSyncTotalSideMargin(delta.side, delta.posMargin, 0);

        keeperBountyUsdc = delta.keeperBountyUsdc;
        uint64[] memory reservationOrderIds = IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.accountId);
        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan = IMarginClearinghouse.LiquidationSettlementPlan({
            settlementRetainedUsdc: delta.settlementRetainedUsdc,
            settlementSeizedUsdc: delta.residualPlan.settlementSeizedUsdc,
            freshTraderPayoutUsdc: delta.freshTraderPayoutUsdc,
            badDebtUsdc: delta.badDebtUsdc,
            positionMarginUnlockedUsdc: delta.residualPlan.mutation.positionMarginUnlockedUsdc,
            otherLockedMarginUnlockedUsdc: delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc
        });
        uint256 seizedUsdc = IMarginClearinghouse(host.clearinghouse()).applyLiquidationSettlementPlan(
            delta.accountId, reservationOrderIds, settlementPlan, host.vault()
        );
        uint256 keeperBountyInflowUsdc = seizedUsdc > delta.keeperBountyUsdc ? delta.keeperBountyUsdc : seizedUsdc;
        if (seizedUsdc > 0) {
            if (keeperBountyInflowUsdc > 0) {
                ICfdVault(host.vault()).recordProtocolInflow(keeperBountyInflowUsdc);
            }
            if (seizedUsdc > keeperBountyInflowUsdc) {
                ICfdVault(host.vault()).recordTradingRevenueInflow(seizedUsdc - keeperBountyInflowUsdc);
            }
        }
        if (delta.syncMarginQueueAmount > 0) {
            IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.accountId);
        }
        if (delta.existingDeferredConsumedUsdc > 0) {
            host.settlementConsumeDeferredTraderPayout(delta.accountId, delta.existingDeferredConsumedUsdc);
        }
        if (delta.freshTraderPayoutUsdc > 0) {
            host.settlementRecordDeferredTraderPayout(delta.accountId, delta.freshTraderPayoutUsdc);
        }
        if (delta.badDebtUsdc > 0) {
            host.settlementAccumulateBadDebt(delta.badDebtUsdc);
        }
        host.settlementDeletePosition(delta.accountId);
    }
}

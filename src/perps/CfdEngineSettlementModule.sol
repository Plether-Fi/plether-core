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

/// @title CfdEngineSettlementModule
/// @notice Externalized settlement executor for `CfdEngine` close and liquidation flows.
/// @dev `CfdEngine` remains the storage owner and grants this module access only through narrow
///      settlement-host hooks. The module does not own independent protocol state.
contract CfdEngineSettlementModule is ICfdEngineSettlementModule {

    address public immutable ENGINE;

    error CfdEngineSettlementModule__Unauthorized();

    constructor(
        address engine_
    ) {
        ENGINE = engine_;
    }

    modifier onlyEngine() {
        if (msg.sender != ENGINE) {
            revert CfdEngineSettlementModule__Unauthorized();
        }
        _;
    }

    /// @notice Applies the live open/increase settlement plan produced by the planner.
    /// @dev Realizes carry, fee, and vault-flow side effects through the settlement host while keeping
    ///      the engine as the canonical state owner.
    function executeOpen(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngine {
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        CfdTypes.Side marginSide = currentPosition.size > 0 ? currentPosition.side : delta.posSide;
        uint256 marginBefore =
            IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.account).positionMarginUsdc;

        if (delta.vaultRebatePayoutUsdc > 0) {
            ICfdVault(host.vault()).payOut(host.clearinghouse(), delta.vaultRebatePayoutUsdc);
        }

        int256 netMarginChange = IMarginClearinghouse(host.clearinghouse())
            .applyOpenCost(delta.account, delta.marginDeltaUsdc, delta.tradeCostUsdc, host.vault());
        if (delta.tradeCostUsdc > 0) {
            uint256 protocolFeeInflowUsdc = uint256(delta.tradeCostUsdc) > delta.executionFeeUsdc
                ? delta.executionFeeUsdc
                : uint256(delta.tradeCostUsdc);
            if (protocolFeeInflowUsdc > 0) {
                ICfdVault(host.vault()).recordProtocolInflow(protocolFeeInflowUsdc);
            }
            if (uint256(delta.tradeCostUsdc) > protocolFeeInflowUsdc) {
                ICfdVault(host.vault())
                    .recordClaimantInflow(
                        uint256(delta.tradeCostUsdc) - protocolFeeInflowUsdc,
                        ICfdVault.ClaimantInflowKind.Revenue,
                        ICfdVault.ClaimantInflowCashMode.CashArrived
                    );
            }
        }

        uint256 marginAfterOpen =
            netMarginChange >= 0 ? marginBefore + uint256(netMarginChange) : marginBefore - uint256(-netMarginChange);
        host.settlementSyncTotalSideMargin(marginSide, marginBefore, marginAfterOpen);
        host.settlementApplySideDelta(
            delta.posSide,
            int256(delta.sideMaxProfitIncrease),
            int256(delta.sideOiIncrease),
            delta.sideEntryNotionalDelta
        );
        if (delta.executionFeeUsdc > 0) {
            host.settlementAccumulateFees(delta.executionFeeUsdc);
        }
        host.settlementWritePosition(
            delta.account,
            CfdEngineSettlementTypes.PositionState({
                deletePosition: false,
                size: delta.newPosSize,
                entryPrice: delta.newPosEntryPrice,
                maxProfitUsdc: currentPosition.maxProfitUsdc + delta.posMaxProfitIncrease,
                lastUpdateTime: uint64(block.timestamp),
                lastCarryTimestamp: uint64(block.timestamp),
                vpiAccrued: currentPosition.vpiAccrued + delta.posVpiAccruedDelta,
                side: currentPosition.size == 0 ? delta.posSide : currentPosition.side
            })
        );
    }

    /// @notice Applies the live close/decrease settlement plan produced by the planner.
    /// @dev Can record deferred trader credit, bad debt, and realized carry depending on the close result.
    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngine {
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        uint256 marginBefore =
            IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.account).positionMarginUsdc;
        host.settlementSyncTotalSideMargin(delta.side, marginBefore, delta.posMarginAfter);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitReduction),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );

        IMarginClearinghouse(host.clearinghouse()).unlockPositionMargin(delta.account, delta.unlockMarginUsdc);

        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.GAIN) {
            if (delta.freshTraderPayoutUsdc > 0) {
                host.settlementRecordDeferredTraderPayout(delta.account, delta.freshTraderPayoutUsdc);
            }
            if (delta.pendingCarryUsdc > 0) {
                ICfdVault(host.vault())
                    .recordClaimantInflow(
                        delta.pendingCarryUsdc,
                        ICfdVault.ClaimantInflowKind.Revenue,
                        ICfdVault.ClaimantInflowCashMode.AlreadyRetained
                    );
            }
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            uint64[] memory reservationOrderIds =
                IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.account);
            (uint256 seizedUsdc,) = IMarginClearinghouse(host.clearinghouse())
                .consumeCloseLoss(
                    delta.account,
                    reservationOrderIds,
                    delta.lossUsdc,
                    delta.posMarginAfter,
                    delta.deletePosition,
                    host.vault()
                );
            uint256 cashCollectedExecutionFeeUsdc = delta.executionFeeUsdc > delta.deferredFeeRecoveryUsdc
                ? delta.executionFeeUsdc - delta.deferredFeeRecoveryUsdc
                : 0;
            uint256 protocolFeeInflowUsdc =
                seizedUsdc > cashCollectedExecutionFeeUsdc ? cashCollectedExecutionFeeUsdc : seizedUsdc;
            if (seizedUsdc > 0) {
                if (protocolFeeInflowUsdc > 0) {
                    ICfdVault(host.vault()).recordProtocolInflow(protocolFeeInflowUsdc);
                }
                if (seizedUsdc > protocolFeeInflowUsdc) {
                    ICfdVault(host.vault())
                        .recordClaimantInflow(
                            seizedUsdc - protocolFeeInflowUsdc,
                            ICfdVault.ClaimantInflowKind.Revenue,
                            ICfdVault.ClaimantInflowCashMode.CashArrived
                        );
                }
            }
            if (delta.syncMarginQueueAmount > 0) {
                IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.account);
            }
            if (delta.existingDeferredConsumedUsdc > 0) {
                host.settlementConsumeDeferredTraderPayout(delta.account, delta.existingDeferredConsumedUsdc);
            }
            if (delta.badDebtUsdc > 0) {
                host.settlementAccumulateBadDebt(delta.badDebtUsdc);
            }
        } else if (delta.pendingCarryUsdc > 0) {
            ICfdVault(host.vault())
                .recordClaimantInflow(
                    delta.pendingCarryUsdc,
                    ICfdVault.ClaimantInflowKind.Revenue,
                    ICfdVault.ClaimantInflowCashMode.AlreadyRetained
                );
        }

        if (delta.executionFeeUsdc > 0) {
            host.settlementAccumulateFees(delta.executionFeeUsdc);
        }

        if (delta.deletePosition) {
            host.settlementDeletePosition(delta.account);
        } else {
            host.settlementWritePosition(
                delta.account,
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

    /// @notice Applies the live liquidation settlement plan produced by the planner.
    /// @return keeperBountyUsdc Liquidation bounty owed to the keeper after the state transition.
    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime
    ) external onlyEngine returns (uint256 keeperBountyUsdc) {
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        host.settlementApplySideDelta(
            delta.side,
            -int256(delta.sideMaxProfitDecrease),
            -int256(delta.sideOiDecrease),
            -int256(delta.sideEntryNotionalReduction)
        );
        host.settlementSyncTotalSideMargin(delta.side, delta.posMargin, 0);

        keeperBountyUsdc = delta.keeperBountyUsdc;
        uint64[] memory reservationOrderIds =
            IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.account);
        IMarginClearinghouse.LiquidationSettlementPlan memory settlementPlan =
            IMarginClearinghouse.LiquidationSettlementPlan({
                settlementRetainedUsdc: delta.settlementRetainedUsdc,
                settlementSeizedUsdc: delta.residualPlan.settlementSeizedUsdc,
                freshTraderPayoutUsdc: delta.freshTraderPayoutUsdc,
                badDebtUsdc: delta.badDebtUsdc,
                positionMarginUnlockedUsdc: delta.residualPlan.mutation.positionMarginUnlockedUsdc,
                otherLockedMarginUnlockedUsdc: delta.residualPlan.mutation.otherLockedMarginUnlockedUsdc
            });
        uint256 seizedUsdc = IMarginClearinghouse(host.clearinghouse())
            .applyLiquidationSettlementPlan(delta.account, reservationOrderIds, settlementPlan, host.vault());
        uint256 keeperBountyInflowUsdc = seizedUsdc > delta.keeperBountyUsdc ? delta.keeperBountyUsdc : seizedUsdc;
        if (seizedUsdc > 0) {
            if (keeperBountyInflowUsdc > 0) {
                ICfdVault(host.vault()).recordProtocolInflow(keeperBountyInflowUsdc);
            }
            if (seizedUsdc > keeperBountyInflowUsdc) {
                ICfdVault(host.vault())
                    .recordClaimantInflow(
                        seizedUsdc - keeperBountyInflowUsdc,
                        ICfdVault.ClaimantInflowKind.Revenue,
                        ICfdVault.ClaimantInflowCashMode.CashArrived
                    );
            }
        }
        if (delta.syncMarginQueueAmount > 0) {
            IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.account);
        }
        if (delta.existingDeferredConsumedUsdc > 0) {
            host.settlementConsumeDeferredTraderPayout(delta.account, delta.existingDeferredConsumedUsdc);
        }
        if (delta.freshTraderPayoutUsdc > 0) {
            host.settlementRecordDeferredTraderPayout(delta.account, delta.freshTraderPayoutUsdc);
            if (delta.pendingCarryUsdc > 0) {
                ICfdVault(host.vault())
                    .recordClaimantInflow(
                        delta.pendingCarryUsdc,
                        ICfdVault.ClaimantInflowKind.Revenue,
                        ICfdVault.ClaimantInflowCashMode.AlreadyRetained
                    );
            }
        }
        if (delta.badDebtUsdc > 0) {
            host.settlementAccumulateBadDebt(delta.badDebtUsdc);
        }
        host.settlementDeletePosition(delta.account);
    }

}

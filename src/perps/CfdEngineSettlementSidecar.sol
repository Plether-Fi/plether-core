// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "./CfdEnginePlanTypes.sol";
import {CfdTypes} from "./CfdTypes.sol";
import {CfdEngineSettlementTypes} from "./interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineSettlementHost} from "./interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "./interfaces/ICfdEngineSettlementSidecar.sol";
import {IHousePool} from "./interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {CashPriorityLib} from "./libraries/CashPriorityLib.sol";

/// @title CfdEngineSettlementSidecar
/// @notice Externalized settlement executor for `CfdEngine` close and liquidation flows.
/// @dev `CfdEngine` remains the storage owner and grants this sidecar access only through narrow
///      settlement-host hooks. The sidecar does not own independent protocol state.
contract CfdEngineSettlementSidecar is ICfdEngineSettlementSidecar {

    address public immutable ENGINE;

    error CfdEngineSettlementSidecar__Unauthorized();

    constructor(
        address engine_
    ) {
        ENGINE = engine_;
    }

    modifier onlyEngineHost(
        ICfdEngineSettlementHost host
    ) {
        if (msg.sender != ENGINE || address(host) != ENGINE) {
            revert CfdEngineSettlementSidecar__Unauthorized();
        }
        _;
    }

    /// @notice Applies the live open/increase settlement plan produced by the planner.
    /// @dev Realizes carry, fee, and pool-flow side effects through the settlement host while keeping
    ///      the engine as the canonical state owner.
    function executeOpen(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngineHost(host) {
        host.settlementApplyCarryAndMark(delta.price, publishTime);
        CfdTypes.Side marginSide = currentPosition.size > 0 ? currentPosition.side : delta.posSide;
        uint256 marginBefore =
            IMarginClearinghouse(host.clearinghouse()).getLockedMarginBuckets(delta.account).positionMarginUsdc;

        if (delta.poolRebatePayoutUsdc > 0) {
            IHousePool(host.pool()).payOut(host.clearinghouse(), delta.poolRebatePayoutUsdc);
        }

        (int256 netMarginChange, uint256 protocolFeeCreditedUsdc) = IMarginClearinghouse(host.clearinghouse())
            .applyOpenCost(
                delta.account,
                delta.marginDeltaUsdc,
                delta.tradeCostUsdc,
                host.pool(),
                host.protocolTreasury(),
                delta.executionFeeUsdc
            );
        if (delta.tradeCostUsdc > 0) {
            uint256 poolCashInflowUsdc = uint256(delta.tradeCostUsdc) - protocolFeeCreditedUsdc;
            if (poolCashInflowUsdc > 0) {
                IHousePool(host.pool())
                    .recordClaimantInflow(
                        poolCashInflowUsdc,
                        IHousePool.ClaimantInflowKind.Revenue,
                        IHousePool.ClaimantInflowCashMode.CashArrived
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
        _settleProtocolFeeTopUp(host, delta.executionFeeUsdc, protocolFeeCreditedUsdc);
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
    /// @dev Can record trader claims, bad debt, and realized carry depending on the close result.
    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngineHost(host) {
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

        uint256 protocolFeeCreditedUsdc;
        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.GAIN) {
            if (delta.freshTraderPayoutUsdc > 0) {
                host.settlementRecordTraderClaim(delta.account, delta.freshTraderPayoutUsdc);
            }
            if (delta.pendingCarryUsdc > 0) {
                IHousePool(host.pool())
                    .recordClaimantInflow(
                        delta.pendingCarryUsdc,
                        IHousePool.ClaimantInflowKind.Revenue,
                        IHousePool.ClaimantInflowCashMode.AlreadyRetained
                    );
            }
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            protocolFeeCreditedUsdc = _executeCloseLoss(host, delta);
        } else if (delta.pendingCarryUsdc > 0) {
            IHousePool(host.pool())
                .recordClaimantInflow(
                    delta.pendingCarryUsdc,
                    IHousePool.ClaimantInflowKind.Revenue,
                    IHousePool.ClaimantInflowCashMode.AlreadyRetained
                );
        }

        _settleProtocolFeeTopUp(host, protocolFeeCreditedUsdc + delta.protocolFeeTopUpUsdc, protocolFeeCreditedUsdc);

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

    function _executeCloseLoss(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta
    ) private returns (uint256 protocolFeeCreditedUsdc) {
        uint64[] memory reservationOrderIds =
            IOrderRouterAccounting(host.orderRouter()).getMarginReservationIds(delta.account);
        (uint256 seizedUsdc,, uint256 cashCreditedProtocolFeeUsdc) = IMarginClearinghouse(host.clearinghouse())
            .consumeCloseLoss(
                delta.account,
                reservationOrderIds,
                delta.lossUsdc,
                delta.posMarginAfter,
                delta.deletePosition,
                host.pool(),
                host.protocolTreasury(),
                delta.lossResult.collectedExecFeeUsdc
            );
        protocolFeeCreditedUsdc = cashCreditedProtocolFeeUsdc;
        if (seizedUsdc > protocolFeeCreditedUsdc) {
            IHousePool(host.pool())
                .recordClaimantInflow(
                    seizedUsdc - protocolFeeCreditedUsdc,
                    IHousePool.ClaimantInflowKind.Revenue,
                    IHousePool.ClaimantInflowCashMode.CashArrived
                );
        }
        if (delta.syncMarginQueueAmount > 0) {
            IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.account);
        }
        if (delta.existingTraderClaimConsumedUsdc > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.existingTraderClaimConsumedUsdc);
        }
        if (delta.badDebtUsdc > 0) {
            host.settlementAccumulateBadDebt(delta.badDebtUsdc);
        }
    }

    /// @notice Applies the live liquidation settlement plan produced by the planner.
    /// @return keeperBountyUsdc Liquidation bounty owed to the keeper after the state transition.
    function executeLiquidation(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.LiquidationDelta calldata delta,
        uint64 publishTime,
        address keeper
    ) external onlyEngineHost(host) returns (uint256 keeperBountyUsdc) {
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
            .applyLiquidationSettlementPlan(
                delta.account, reservationOrderIds, settlementPlan, host.pool(), keeper, delta.keeperBountyUsdc
            );
        if (seizedUsdc > 0) {
            IHousePool(host.pool())
                .recordClaimantInflow(
                    seizedUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
                );
        }
        if (delta.syncMarginQueueAmount > 0) {
            IOrderRouterAccounting(host.orderRouter()).syncMarginQueue(delta.account);
        }
        if (delta.existingTraderClaimConsumedUsdc > 0) {
            host.settlementConsumeTraderClaim(delta.account, delta.existingTraderClaimConsumedUsdc);
        }
        if (delta.freshTraderPayoutUsdc > 0) {
            host.settlementRecordTraderClaim(delta.account, delta.freshTraderPayoutUsdc);
            if (delta.pendingCarryUsdc > 0) {
                IHousePool(host.pool())
                    .recordClaimantInflow(
                        delta.pendingCarryUsdc,
                        IHousePool.ClaimantInflowKind.Revenue,
                        IHousePool.ClaimantInflowCashMode.AlreadyRetained
                    );
            }
        }
        if (delta.badDebtUsdc > 0) {
            host.settlementAccumulateBadDebt(delta.badDebtUsdc);
        }
        host.settlementDeletePosition(delta.account);
    }

    function _settleProtocolFeeTopUp(
        ICfdEngineSettlementHost host,
        uint256 amountUsdc,
        uint256 clearinghouseCreditedUsdc
    ) private {
        if (clearinghouseCreditedUsdc > amountUsdc) {
            clearinghouseCreditedUsdc = amountUsdc;
        }
        uint256 poolFundedUsdc = amountUsdc - clearinghouseCreditedUsdc;
        if (poolFundedUsdc == 0) {
            return;
        }

        IHousePool pool = IHousePool(host.pool());
        CashPriorityLib.SeniorCashReservation memory reservation =
            CashPriorityLib.reserveFreshPayouts(pool.totalAssets(), host.totalTraderClaimBalanceUsdc());
        uint256 topUpUsdc = poolFundedUsdc < reservation.freeCashUsdc ? poolFundedUsdc : reservation.freeCashUsdc;
        if (topUpUsdc == 0) {
            return;
        }
        pool.payOut(host.clearinghouse(), topUpUsdc);
        IMarginClearinghouse(host.clearinghouse()).settleUsdc(host.protocolTreasury(), int256(topUpUsdc));
    }

}

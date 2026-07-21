// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEngineSettlementTypes} from "@plether/perps/interfaces/CfdEngineSettlementTypes.sol";
import {ICfdEngineSettlementHost} from "@plether/perps/interfaces/ICfdEngineSettlementHost.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {CashPriorityLib} from "@plether/perps/libraries/CashPriorityLib.sol";

/// @title CfdEngineSettlementSidecar
/// @notice Externalized settlement executor for `CfdEngine` open, close, and liquidation flows.
/// @dev `CfdEngine` remains the storage owner and grants this sidecar access only through narrow
///      settlement-host hooks. The sidecar does not own independent protocol state and does not validate planner deltas;
///      the bound engine must supply a valid delta derived from matching live state. Unless stated otherwise, USDC
///      amounts use 6 decimals, prices use 8 decimals, sizes use 18 decimals, and timestamps are Unix seconds.
contract CfdEngineSettlementSidecar is ICfdEngineSettlementSidecar {

    /// @notice Sole engine address authorized to call settlement entrypoints and to be supplied as `host`.
    address public immutable ENGINE;

    /// @notice Thrown when the caller or supplied settlement host is not exactly `ENGINE`.
    error CfdEngineSettlementSidecar__Unauthorized();

    /// @notice Binds the stateless sidecar to one engine settlement host.
    /// @dev Performs no zero-address, code-size, or interface validation. Binding to an invalid address can deploy but
    ///      leaves settlement unusable or causes later host calls to revert.
    /// @param engine_ Engine host authorized to call this sidecar.
    constructor(
        address engine_
    ) {
        ENGINE = engine_;
    }

    /// @notice Restricts an entrypoint to the bound engine passed as both caller and host.
    /// @param host Host argument whose address must equal `ENGINE`.
    modifier onlyEngineHost(
        ICfdEngineSettlementHost host
    ) {
        if (msg.sender != ENGINE || address(host) != ENGINE) {
            revert CfdEngineSettlementSidecar__Unauthorized();
        }
        _;
    }

    /// @notice Applies the live open/increase settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`, which must also be passed as `host`. The host is responsible for supplying a valid
    ///      delta consistent with `currentPosition`; this function does not inspect `delta.valid` or recompute the plan.
    ///      It advances global carry/mark state when the publish time is newer, funds any VPI rebate from the pool,
    ///      applies clearinghouse open costs and margin changes, records collected LP revenue, updates aggregate side
    ///      margin/open interest/entry notional/max-profit state, funds collectible protocol fees from unreserved pool
    ///      cash, and writes the position with `block.timestamp` as its update/carry time. Existing-position carry is
    ///      realized by the engine before invoking the sidecar.
    /// @param host Bound engine settlement host that owns canonical storage.
    /// @param delta Valid planned open/increase delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param currentPosition Position loaded by the engine immediately before settlement.
    /// @param publishTime Oracle publish timestamp proposed for the execution mark.
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
    /// @dev Callable only by `ENGINE`, which must also be passed as `host`. The host must supply a valid delta consistent
    ///      with `currentPosition`; this function does not inspect `delta.valid` or recompute it. It advances carry/mark
    ///      state, updates aggregate side accounting, unlocks proportional margin, pays or records trader gains, consumes
    ///      eligible collateral and claims for losses, records LP revenue and bad debt, funds collectible protocol fees
    ///      from unreserved pool cash, and writes or deletes the position. When a frozen spread was assessed it emits
    ///      `FrozenCloseSpreadSettled` with assessed, recovered, and waived USDC.
    /// @param host Bound engine settlement host that owns canonical storage.
    /// @param delta Valid planned close/decrease delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param currentPosition Position loaded by the engine immediately before settlement.
    /// @param publishTime Oracle publish timestamp proposed for the execution mark.
    function executeClose(
        ICfdEngineSettlementHost host,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        CfdTypes.Position calldata currentPosition,
        uint64 publishTime
    ) external onlyEngineHost(host) {
        (uint256 frozenSpreadPaidUsdc, uint256 nonCashFrozenSpreadPaidUsdc) = _frozenSpreadSettlement(delta);
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
            _recordRetainedCloseRevenue(host, delta.pendingCarryUsdc + frozenSpreadPaidUsdc);
        } else if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            protocolFeeCreditedUsdc = _executeCloseLoss(host, delta);
            _recordRetainedCloseRevenue(host, nonCashFrozenSpreadPaidUsdc);
        } else {
            _recordRetainedCloseRevenue(host, delta.pendingCarryUsdc + frozenSpreadPaidUsdc);
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

        if (delta.closeState.frozenSpreadUsdc > 0) {
            emit FrozenCloseSpreadSettled(
                delta.account,
                delta.closeState.frozenSpreadUsdc,
                frozenSpreadPaidUsdc,
                delta.closeState.frozenSpreadUsdc - frozenSpreadPaidUsdc
            );
        }
    }

    /// @notice Splits assessed frozen spread into total recovered and non-cash LP-revenue portions.
    /// @param delta Planned close delta.
    /// @return paidUsdc Spread recovered from retained value, collateral, or existing-claim netting.
    /// @return nonCashPaidUsdc Recovered spread not already included in cash seizure inflow.
    function _frozenSpreadSettlement(
        CfdEnginePlanTypes.CloseDelta calldata delta
    ) private pure returns (uint256 paidUsdc, uint256 nonCashPaidUsdc) {
        if (delta.settlementType != CfdEnginePlanTypes.SettlementType.LOSS) {
            return (delta.closeState.frozenSpreadUsdc, delta.closeState.frozenSpreadUsdc);
        }

        uint256 uncollectedExecFeeUsdc = delta.closeState.executionFeeUsdc - delta.lossResult.retainedExecFeeUsdc
            - delta.lossResult.collectedExecFeeUsdc;
        uint256 uncollectedSpreadUsdc =
            delta.lossResult.shortfallUsdc - uncollectedExecFeeUsdc - delta.lossResult.badDebtUsdc;
        uint256 claimBadDebtRecoveryUsdc = delta.lossResult.badDebtUsdc - delta.badDebtUsdc;
        uint256 traderClaimRecoveryUsdc =
            delta.existingTraderClaimConsumedUsdc - delta.traderClaimFeeRecoveryUsdc - claimBadDebtRecoveryUsdc;
        paidUsdc = delta.closeState.frozenSpreadUsdc - (uncollectedSpreadUsdc - traderClaimRecoveryUsdc);

        uint256 totalChargesUsdc = delta.closeState.executionFeeUsdc + delta.closeState.frozenSpreadUsdc;
        uint256 retainedChargesUsdc = totalChargesUsdc > delta.lossUsdc ? totalChargesUsdc - delta.lossUsdc : 0;
        uint256 retainedAfterExecFeeUsdc = retainedChargesUsdc - delta.lossResult.retainedExecFeeUsdc;
        uint256 retainedFrozenSpreadUsdc = delta.closeState.frozenSpreadUsdc < retainedAfterExecFeeUsdc
            ? delta.closeState.frozenSpreadUsdc
            : retainedAfterExecFeeUsdc;
        nonCashPaidUsdc = retainedFrozenSpreadUsdc + traderClaimRecoveryUsdc;
    }

    /// @notice Executes clearinghouse, router, claim, pool, and bad-debt mutations for a loss close.
    /// @param host Bound engine settlement host.
    /// @param delta Valid loss-close plan.
    /// @return protocolFeeCreditedUsdc Protocol fee funded directly from seized clearinghouse cash.
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

    /// @notice Records nonzero LP revenue whose cash is already retained in pool accounting.
    /// @param host Bound engine settlement host.
    /// @param amountUsdc Revenue to record, in 6-decimal USDC units.
    function _recordRetainedCloseRevenue(
        ICfdEngineSettlementHost host,
        uint256 amountUsdc
    ) private {
        if (amountUsdc == 0) {
            return;
        }
        IHousePool(host.pool())
            .recordClaimantInflow(
                amountUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.AlreadyRetained
            );
    }

    /// @notice Applies the live liquidation settlement plan produced by the planner.
    /// @dev Callable only by `ENGINE`, which must also be passed as `host`. The host must supply a liquidatable delta
    ///      consistent with live state; this function neither checks `delta.liquidatable` nor recomputes the plan. It
    ///      advances carry/mark state, removes all side exposure and margin, applies the clearinghouse terminal-settlement
    ///      plan, credits the keeper bounty, records seized pool inflow, synchronizes consumed order reservations, nets
    ///      existing claims, pays or records fresh trader value, records applicable carry revenue and bad debt, and
    ///      deletes the position.
    /// @param host Bound engine settlement host that owns canonical storage.
    /// @param delta Valid planned full-liquidation delta; prices are 8 decimals, size 18, and USDC fields 6.
    /// @param publishTime Oracle publish timestamp proposed for the liquidation mark.
    /// @param keeper Clearinghouse account credited with the planned bounty.
    /// @return keeperBountyUsdc Planned bounty forwarded to clearinghouse settlement, in 6-decimal USDC units.
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

    /// @notice Funds an uncredited protocol fee from pool cash not reserved for outstanding trader claims.
    /// @dev The top-up is capped by both the requested shortfall and current free pool cash, then paid to the clearinghouse
    ///      and credited to the host's protocol-treasury account.
    /// @param host Bound engine settlement host.
    /// @param amountUsdc Total protocol-fee amount intended to be credited.
    /// @param clearinghouseCreditedUsdc Portion already credited from clearinghouse cash collection.
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

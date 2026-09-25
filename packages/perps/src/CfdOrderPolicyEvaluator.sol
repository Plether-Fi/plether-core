// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

interface IPositionEpoch {

    function positionEpoch(
        address account
    ) external view returns (uint64);

}

interface ICommittedPolicyRouter {

    function lifecycleBook() external view returns (IOrderLifecycleBook);

}

/// @notice Public policy evaluator; internal snapshot and assessment logic is shared with read-only lenses.
contract CfdOrderPolicyEvaluator is CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEvaluator {

    function assessCommittedOrder(
        address engineAddress,
        uint64 orderId,
        address executor,
        uint256 executionPrice,
        uint64 publishTime
    ) external view returns (OrderV2Types.ExecutionAssessment memory assessment) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        address router = engine.orderRouter();
        OrderV2Types.PendingIntent memory pending = _pending(router, orderId);
        IMarginClearinghouse(engine.clearinghouse())
            .validateBountyReservation(
                pending.account, IMarginClearinghouse.BountyKind.Order, orderId, pending.executionBountyUsdc
            );
        (IOrderRouterAccounting.PendingOrderView memory viewOrder,) =
            IOrderRouterAccounting(router).getPendingOrderView(orderId);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: pending.account,
            sizeDelta: viewOrder.sizeDelta,
            marginDelta: viewOrder.marginDelta,
            targetPrice: viewOrder.targetPrice,
            commitTime: viewOrder.commitTime,
            commitBlock: viewOrder.commitBlock,
            orderId: orderId,
            side: viewOrder.side,
            isClose: viewOrder.isClose
        });
        AssessmentContext memory context = AssessmentContext(
            engineAddress,
            executor,
            executionPrice,
            IHousePool(engine.pool()).totalAssets(),
            publishTime,
            pending.executionBountyUsdc
        );
        if (pending.closeMode == OrderV2Types.CloseMode.CallerPaidFullExit) {
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(pending.account);
            if (
                IPositionEpoch(engineAddress).positionEpoch(pending.account) != pending.positionEpoch
                    || size != pending.positionSize || side != pending.positionSide
            ) {
                revert CfdOrderPolicyEvaluator__TerminalPositionChanged(orderId);
            }
        }
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, context.poolDepthUsdc);
        // Execution releases this order's classification before assessment. A public read projects the same
        // release; a call inside execution observes zero and does not release it twice.
        uint256 release = viewOrder.committedMarginUsdc;
        snapshot.lockedBuckets.committedOrderMarginUsdc -= release;
        snapshot.lockedBuckets.totalLockedMarginUsdc -= release;
        snapshot.accountBuckets.otherLockedMarginUsdc -= release;
        snapshot.accountBuckets.totalLockedMarginUsdc -= release;
        snapshot.accountBuckets.freeSettlementUsdc += release;
        assessment = _assessSnapshot(context, order, pending.bounds, planner, snapshot);
        if (order.isClose) {
            _includeCommitment(assessment, pending.commitment, pending.bounds, pending.executionBountyUsdc);
        }
    }

    function _pending(
        address router,
        uint64 orderId
    ) private view returns (OrderV2Types.PendingIntent memory pending) {
        IOrderLifecycleBook book = ICommittedPolicyRouter(router).lifecycleBook();
        pending = book.pendingIntent(orderId);
        if (pending.account == address(0)) {
            revert CfdOrderPolicyEvaluator__ReservationMismatch(orderId);
        }
        if (
            block.timestamp > pending.bounds.validUntil
                || (pending.bounds.expectedConfigHash != bytes32(0)
                    && book.currentExecutionConfigHash() != pending.bounds.expectedConfigHash)
        ) {
            revert CfdOrderPolicyEvaluator__CommittedPolicyChanged(orderId);
        }
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function assessOrder(
        address engineAddress,
        CfdTypes.Order calldata order,
        address executor,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external view returns (OrderV2Types.ExecutionAssessment memory assessment) {
        AssessmentContext memory context;
        context.engineAddress = engineAddress;
        context.executor = executor;
        context.currentOraclePrice = currentOraclePrice;
        context.poolDepthUsdc = poolDepthUsdc;
        context.publishTime = publishTime;
        context.executionBountyUsdc = executionBountyUsdc;
        return _assessOrder(context, order, bounds);
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.OpenDelta memory deltaCopy = delta;
        OrderV2Types.ExecutionBounds memory boundsCopy = bounds;
        return _evaluateOpen(snapshotCopy, deltaCopy, boundsCopy, executionBountyUsdc, false);
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateClose(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.CloseDelta memory deltaCopy = delta;
        OrderV2Types.ExecutionBounds memory boundsCopy = bounds;
        return _evaluateClose(snapshotCopy, deltaCopy, boundsCopy, executionBountyUsdc, false);
    }

}

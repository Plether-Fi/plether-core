// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";

/// @notice Public policy evaluator; internal snapshot and assessment logic is shared with read-only lenses.
contract CfdOrderPolicyEvaluator is CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEvaluator {

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

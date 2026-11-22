// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OpenOrderFundingLib} from "@plether/perps/libraries/OpenOrderFundingLib.sol";
import {OracleFreshnessPolicyLib} from "@plether/perps/libraries/OracleFreshnessPolicyLib.sol";
import {OrderFailurePolicyLib} from "@plether/perps/libraries/OrderFailurePolicyLib.sol";

interface ICommittedPolicyRouter {

    function engine() external view returns (ICfdOrderPolicyEngineView);
    function engineLensForCommit() external view returns (ICfdEngineLens);
    function pletherOracle() external view returns (IPletherOracle);
    function lifecycleBook() external view returns (IOrderLifecycleBook);

}

/// @notice Public policy evaluator; internal snapshot and assessment logic is shared with read-only lenses.
contract CfdOrderPolicyEvaluator is CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEvaluator {

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function validateOpenCommit(
        address account,
        OrderV3Types.OrderRequest calldata request,
        uint256 commitPrice,
        uint256 executionBountyAssets
    ) external view {
        ICommittedPolicyRouter router = ICommittedPolicyRouter(msg.sender);
        ICfdOrderPolicyEngineView engine = router.engine();
        ICfdEngineLens lens = router.engineLensForCommit();
        ICfdEngineTypes.OpenPreview memory preview =
            lens.previewOpen(account, request.side, request.sizeDelta, request.marginDelta, commitPrice);
        CfdEnginePlanTypes.OpenRevertCode code = CfdEnginePlanTypes.OpenRevertCode(
            lens.previewOpenCommitRevertCode(
                account, request.side, request.sizeDelta, request.marginDelta, commitPrice, executionBountyAssets
            )
        );
        if (code == CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED) {
            revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(uint8(code));
        }
        // An earlier queued close may remove the opposing position before execution.
        if (
            code != CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
                && OrderFailurePolicyLib.isPredictablyInvalidOpen(
                    CfdEnginePlanLib.getOpenFailurePolicyCategory(code)
                )
        ) {
            uint64 markTime = engine.lastMarkTime();
            if (
                markTime != 0
                    && !OracleFreshnessPolicyLib.isStale(
                        markTime, router.pletherOracle().getOrderExecutionPolicy(false).maxStaleness, block.timestamp
                    )
            ) {
                revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(uint8(code));
            }
        }

        // VPI may be unquoted after an early planner failure. The explicit fee is known at the reference mark.
        uint256 notionalAssets = request.sizeDelta / CfdTypes.SIZE_QUANTUM * commitPrice;
        code = OpenOrderFundingLib.validate(
            engine.riskParams(),
            engine.isFadWindow(),
            notionalAssets,
            notionalAssets * engine.executionFeeBps() / 10_000,
            preview.vpiAssets,
            request.marginDelta,
            request.bounds
        );
        if (code != CfdEnginePlanTypes.OpenRevertCode.OK) {
            revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(uint8(code));
        }
    }

    function assessCommittedOrder(
        address engineAddress,
        uint64 orderId,
        address executor,
        uint256 executionPrice
    ) external view returns (OrderV3Types.ExecutionAssessment memory assessment) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        address router = engine.orderRouter();
        OrderV3Types.PendingIntent memory pending = _pending(router, orderId);
        ICommittedPolicyRouter(router).lifecycleBook().validateBountyFunding(orderId);
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
            pending.executionBountyAssets,
            order.isClose && IOrderRouterAccounting(router).pendingOrderCounts(order.account) == 1
        );
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, order.account, context.poolDepthAssets, context.poolDepthAssets);
        // Execution assesses before releasing this order's reservation. Project that release for planner parity.
        uint256 release = viewOrder.committedMarginAssets;
        snapshot.lockedBuckets.committedOrderMarginAssets -= release;
        snapshot.lockedBuckets.totalLockedMarginAssets -= release;
        snapshot.accountBuckets.otherLockedMarginAssets -= release;
        snapshot.accountBuckets.totalLockedMarginAssets -= release;
        snapshot.accountBuckets.freeSettlementAssets += release;
        assessment = _assessSnapshot(context, order, pending.bounds, planner, snapshot, viewOrder.committedMarginAssets);
        _includeCommitment(assessment, pending.commitment, pending.bounds, pending.executionBountyAssets);
    }

    function _pending(
        address router,
        uint64 orderId
    ) private view returns (OrderV3Types.PendingIntent memory pending) {
        IOrderLifecycleBook book = ICommittedPolicyRouter(router).lifecycleBook();
        pending = book.pendingIntent(orderId);
        if (pending.account == address(0)) {
            revert CfdOrderPolicyEvaluator__ReservationMismatch(orderId);
        }
        if (
            block.timestamp > pending.timing.executionDeadline
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
        uint256 poolDepthAssets,
        OrderV3Types.ExecutionBounds calldata bounds,
        uint256 executionBountyAssets
    ) external view returns (OrderV3Types.ExecutionAssessment memory assessment) {
        AssessmentContext memory context;
        context.engineAddress = engineAddress;
        context.executor = executor;
        context.currentOraclePrice = currentOraclePrice;
        context.poolDepthAssets = poolDepthAssets;
        context.executionBountyAssets = executionBountyAssets;
        return _assessOrder(context, order, bounds);
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        OrderV3Types.ExecutionBounds calldata bounds,
        uint256 executionBountyAssets
    ) external pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.OpenDelta memory deltaCopy = delta;
        OrderV3Types.ExecutionBounds memory boundsCopy = bounds;
        return
            _evaluateOpen(
                snapshotCopy, deltaCopy, boundsCopy, executionBountyAssets, false, deltaCopy.marginDeltaAssets
            );
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateClose(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        OrderV3Types.ExecutionBounds calldata bounds,
        uint256 executionBountyAssets
    ) external pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.CloseDelta memory deltaCopy = delta;
        OrderV3Types.ExecutionBounds memory boundsCopy = bounds;
        return _evaluateClose(snapshotCopy, deltaCopy, boundsCopy, executionBountyAssets, false, false);
    }

}

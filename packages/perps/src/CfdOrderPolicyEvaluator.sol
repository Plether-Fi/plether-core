// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
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
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

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
        // Pending opens reserve pool capacity immediately. Enforce pool-risk and numeric failures even on a stale mark.
        if (OrderFailurePolicyLib.isPredictablyInvalidOpen(uint8(code), false)) {
            revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(uint8(code));
        }
        // An earlier queued close may remove the opposing position before execution.
        if (
            code != CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
                && OrderFailurePolicyLib.isPredictablyInvalidOpen(uint8(code), true)
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

        _validateOpenCommitFunding(
            engine,
            account,
            request,
            commitPrice,
            preview.vpiAssets,
            code == CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
        );
    }

    function _validateOpenCommitFunding(
        ICfdOrderPolicyEngineView engine,
        address account,
        OrderV3Types.OrderRequest calldata request,
        uint256 commitPrice,
        int256 previewVpiAssets,
        bool isQueuedFlip
    ) private view {
        // When a live opposing position is scheduled to close first, `previewOpen` stops at MUST_CLOSE_OPPOSING
        // before quoting VPI. Quote the post-close VPI at `commitPrice` so underfunded flips fail at commit.
        CfdTypes.RiskParams memory riskParams = engine.riskParams();
        int256 vpiAssets = isQueuedFlip
            ? _queuedFlipVpiAssets(engine, account, request.side, request.sizeDelta, commitPrice, riskParams.vpiFactor)
            : previewVpiAssets;
        uint256 notionalAssets = request.sizeDelta / CfdTypes.SIZE_QUANTUM * commitPrice;
        CfdEnginePlanTypes.OpenRevertCode fundingCode = OpenOrderFundingLib.validate(
            riskParams,
            engine.isFadWindow(),
            notionalAssets,
            notionalAssets * engine.executionFeeBps() / 10_000,
            vpiAssets,
            request.marginDelta,
            request.bounds
        );
        if (fundingCode != CfdEnginePlanTypes.OpenRevertCode.OK) {
            revert IOrderRouterErrors.OrderRouter__PredictableOpenInvalid(uint8(fundingCode));
        }
    }

    function _queuedFlipVpiAssets(
        ICfdOrderPolicyEngineView engine,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 commitPrice,
        uint256 vpiFactor
    ) private view returns (int256) {
        if (vpiFactor == 0 || commitPrice == 0) {
            return 0;
        }
        uint256 price = commitPrice > engine.CAP_PRICE() ? engine.CAP_PRICE() : commitPrice;
        uint256 netDepthAssets = PositionRiskAccountingLib.computeNetPoolDepthAssets(
            IHousePool(engine.pool()).totalAssets(),
            engine.totalTraderClaimBalanceAssets(),
            engine.totalPositiveVpiAccruedAssets()
        );
        if (netDepthAssets == 0) {
            return 0;
        }
        (bool fits, uint256 preSkewAssets, uint256 postSkewAssets) =
            _queuedFlipSkewAssets(engine, account, side, sizeDelta, price);
        if (!fits) {
            return 0;
        }
        (bool valid, int256 vpiAssets) =
            CfdMath.tryCalculateVPI(preSkewAssets, postSkewAssets, netDepthAssets, vpiFactor);
        return valid ? vpiAssets : int256(0);
    }

    function _queuedFlipSkewAssets(
        ICfdOrderPolicyEngineView engine,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 price
    ) private view returns (bool fits, uint256 preSkewAssets, uint256 postSkewAssets) {
        (uint256 liveSize,,,, CfdTypes.Side liveSide,,) = engine.positions(account);
        (, uint256 longOi,,) = engine.sides(uint256(CfdTypes.Side.LONG));
        (, uint256 shortOi,,) = engine.sides(uint256(CfdTypes.Side.SHORT));
        if (liveSide == CfdTypes.Side.LONG) {
            longOi = longOi > liveSize ? longOi - liveSize : 0;
        } else {
            shortOi = shortOi > liveSize ? shortOi - liveSize : 0;
        }
        uint256 postLongOi = side == CfdTypes.Side.LONG ? longOi + sizeDelta : longOi;
        uint256 postShortOi = side == CfdTypes.Side.SHORT ? shortOi + sizeDelta : shortOi;
        if (postLongOi > type(uint256).max / price || postShortOi > type(uint256).max / price) {
            return (false, 0, 0);
        }
        preSkewAssets = _absOiDiffAssets(longOi, shortOi, price);
        postSkewAssets = _absOiDiffAssets(postLongOi, postShortOi, price);
        fits = true;
    }

    function _absOiDiffAssets(
        uint256 longOi,
        uint256 shortOi,
        uint256 price
    ) private pure returns (uint256) {
        uint256 longAssets = (longOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        uint256 shortAssets = (shortOi * price) / CfdMath.ASSETS_TO_TOKEN_SCALE;
        return longAssets > shortAssets ? longAssets - shortAssets : shortAssets - longAssets;
    }

    function assessCommittedOrder(
        address engineAddress,
        uint64 orderId,
        address executor,
        uint256 executionPrice
    ) external view returns (OrderV3Types.ExecutionAssessment memory assessment) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        address router = engine.orderRouter();
        IOrderLifecycleBook book = ICommittedPolicyRouter(router).lifecycleBook();
        OrderV3Types.PendingIntent memory pending = _pending(book, orderId);
        book.validateBountyFunding(orderId);
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
            order.isClose && IOrderRouterAccounting(router).pendingOrderCounts(order.account) == 1,
            pending.commitment.carryCollectedAssets
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
        if (order.isClose && assessment.postPositionSize != 0 && book.closeRequiresFullExit(orderId)) {
            revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION),
                true
            );
        }
    }

    function _pending(
        IOrderLifecycleBook book,
        uint64 orderId
    ) private view returns (OrderV3Types.PendingIntent memory pending) {
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
        return _evaluateOpen(
            snapshotCopy, deltaCopy, boundsCopy, executionBountyAssets, false, deltaCopy.marginDeltaAssets, 0
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
        return _evaluateClose(snapshotCopy, deltaCopy, boundsCopy, executionBountyAssets, false, false, 0);
    }

}

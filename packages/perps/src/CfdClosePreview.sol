// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CloseCommitmentLib} from "@plether/perps/libraries/CloseCommitmentLib.sol";

interface ICloseAdmission {

    function previewCloseAdmission(
        address account,
        OrderV3Types.OrderRequest calldata request
    ) external view;

}

interface ICfdClosePreviewRouter {

    function liquidationBatchSidecar() external view returns (address);
    function lifecycleBook() external view returns (IOrderLifecycleBook);

    function minOpenNotionalUsdc() external view returns (uint256);

}

/// @title CfdClosePreview
/// @notice Read-only preview of a prospective zero-bounty close after projecting commitment carry.
/// @dev This schema targets a fresh deployment. Historical engines require their archived preview and planner ABI.
contract CfdClosePreview is CfdOrderPolicyEvaluatorBase {

    error CfdClosePreview__NotCloseOrder();

    struct ClosePreview {
        CfdEnginePlanTypes.CloseCommitment commitment;
        uint256 commitmentCarryUsdc;
        OrderV3Types.ExecutionAssessment assessment;
        /// @notice Nonzero for an exact retry: commitment and assessment remain empty because no new close is submitted.
        uint64 replayOrderId;
    }

    /// @notice Previews bounded close submission, resolving permanent client identity before fresh admission.
    /// @dev An exact replay returns only replayOrderId, even after expiry, configuration changes or position closure.
    ///      Use lifecycle reads or assessCommittedOrder for that existing order; this result is not an execution quote.
    function previewClose(
        address engineAddress,
        address account,
        OrderV3Types.OrderRequest calldata request,
        address executor,
        uint256 executionPrice
    ) external view returns (ClosePreview memory preview) {
        if (!request.isClose) {
            revert CfdClosePreview__NotCloseOrder();
        }
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdClosePreviewRouter router = ICfdClosePreviewRouter(engine.orderRouter());
        preview.replayOrderId = _resolveClientId(router.lifecycleBook(), account, request);
        if (preview.replayOrderId != 0) {
            return preview;
        }
        if (request.bounds.minPostSettlementBalanceUsdc != 0) {
            revert IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported();
        }
        CfdEnginePlanTypes.RawSnapshot memory snapshot;
        CfdEnginePlanTypes.CloseDelta memory delta;
        {
            ICloseAdmission(router.liquidationBatchSidecar()).previewCloseAdmission(account, request);
            // Fresh public admission requires a nonzero configuration hash. Registration therefore rejects the
            // protocol-only ID namespace; check after admission to retain the same error ordering as commitment.
            if (OrderV3Types.isProtocolClientOrderId(request.clientOrderId)) {
                revert IOrderLifecycleBook.OrderLifecycleBook__ClientIdDomainMismatch(request.clientOrderId, false);
            }
            ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
            snapshot = _buildRawSnapshot(engine, planner, account, IHousePool(engine.pool()).totalAssets());
            preview.commitment = CloseCommitmentLib.project(snapshot, request.sizeDelta);
            preview.commitmentCarryUsdc = preview.commitment.carryCollectedUsdc;
            delta = planner.planClose(snapshot, _requestOrder(account, request), executionPrice);
        }
        preview.assessment = _evaluateClose(snapshot, delta, request.bounds, 0, executor == account);
        _includeCommitment(preview.assessment, preview.commitment, request.bounds, 0);
    }

    function _resolveClientId(
        IOrderLifecycleBook book,
        address account,
        OrderV3Types.OrderRequest calldata request
    ) private view returns (uint64 replayOrderId) {
        (OrderV3Types.ClientIntentResolution resolution, uint64 existingOrderId, bytes32 suppliedIntentHash) =
            book.resolveClientIntent(account, request);
        if (resolution == OrderV3Types.ClientIntentResolution.ExactReplay) {
            return existingOrderId;
        }
        if (resolution == OrderV3Types.ClientIntentResolution.Conflict) {
            revert IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict(
                account,
                request.clientOrderId,
                book.clientIntent(account, request.clientOrderId).intentHash,
                suppliedIntentHash
            );
        }
    }

    /// @notice Projects commitment now and close execution at the supplied price, using canonical pool depth.
    /// @dev Includes commitment carry in the assessment and reports it separately in commitmentCarryUsdc. No future
    ///      carry, oracle update, router queue admission, deadline or config-hash validation is simulated. Side and dust
    ///      checks use the live position; pending opens/closes can change the router's queued projection. Re-preview
    ///      if state changes.
    function previewClose(
        address engineAddress,
        CfdTypes.Order calldata order,
        address executor,
        uint256 executionPrice,
        OrderV3Types.ExecutionBounds calldata bounds
    ) external view returns (ClosePreview memory preview) {
        if (!order.isClose) {
            revert CfdClosePreview__NotCloseOrder();
        }
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, IHousePool(engine.pool()).totalAssets());
        return _previewSnapshot(planner, snapshot, order, engine.orderRouter(), executor, executionPrice, bounds);
    }

    function _requestOrder(
        address account,
        OrderV3Types.OrderRequest calldata request
    ) private view returns (CfdTypes.Order memory order) {
        order = CfdTypes.Order(
            account,
            request.sizeDelta,
            request.marginDelta,
            request.targetPrice,
            uint64(block.timestamp),
            uint64(block.number),
            0,
            request.side,
            request.isClose
        );
    }

    function _previewSnapshot(
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order,
        address router,
        address executor,
        uint256 executionPrice,
        OrderV3Types.ExecutionBounds calldata bounds
    ) private view returns (ClosePreview memory preview) {
        _validateRouterCommit(snapshot, order, router);
        preview.commitment = CloseCommitmentLib.project(snapshot, order.sizeDelta);
        preview.commitmentCarryUsdc = preview.commitment.carryCollectedUsdc;
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snapshot, order, executionPrice);
        preview.assessment = _evaluateClose(snapshot, delta, bounds, 0, executor == order.account);
        _includeCommitment(preview.assessment, preview.commitment, bounds, 0);
    }

    /// @dev The router checks side and partial-close dust before reserving even a zero bounty. Its queued-position
    ///      projection is deliberately not reproduced here; callers must still simulate the actual commitment.
    function _validateRouterCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order,
        address router
    ) private view {
        if (snapshot.position.size != 0 && order.side != snapshot.position.side) {
            revert IOrderRouterErrors.OrderRouter__SideMismatch();
        }
        // Deterministic lot alignment, not entropy: modulo only selects the size-validation path.
        if (
            // slither-disable-next-line weak-prng
            order.sizeDelta == 0 || order.sizeDelta >= snapshot.position.size
                || order.sizeDelta % CfdTypes.SIZE_QUANTUM != 0
        ) {
            return;
        }
        uint256 commitPrice = snapshot.lastMarkPrice;
        if (commitPrice == 0) {
            revert IOrderRouterErrors.OrderRouter__MarkPriceUnavailable();
        }
        commitPrice = Math.min(commitPrice, snapshot.capPrice);
        if (
            Math.mulDiv(order.sizeDelta, commitPrice, CfdTypes.SIZE_QUANTUM)
                < ICfdClosePreviewRouter(router).minOpenNotionalUsdc()
        ) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(11);
        }
    }

}

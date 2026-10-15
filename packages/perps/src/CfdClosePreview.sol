// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdOrderPolicyEvaluatorBase, ICfdOrderPolicyEngineView} from "@plether/perps/CfdOrderPolicyEvaluatorBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CloseCommitmentLib} from "@plether/perps/libraries/CloseCommitmentLib.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";

interface ICloseAdmission {

    function previewCloseAdmission(
        address account,
        OrderV3Types.OrderRequest calldata request
    ) external view returns (uint256);

}

interface ICfdClosePreviewRouter {

    function liquidationBatchSidecar() external view returns (address);

    function closeOrderExecutionBountyUsdc() external view returns (uint256);

}

/// @title CfdClosePreview
/// @notice Read-only preview of a prospective zero-bounty close after projecting commitment carry.
/// @dev This schema targets a fresh deployment. Historical engines require their archived preview and planner ABI.
contract CfdClosePreview is CfdOrderPolicyEvaluatorBase {

    error CfdClosePreview__NotCloseOrder();
    // Deprecated grant errors remain declared to avoid unrelated ABI churn.
    error CfdClosePreview__SponsoredDeploymentMismatch();
    error CfdClosePreview__SponsoredIntentInvalid();
    error CfdClosePreview__SponsoredAccountBusy();
    error CfdClosePreview__UncoveredCarry(uint256 unpaidCarryUsdc);
    error CfdClosePreview__SubsidyMismatch(uint256 expectedUsdc, uint256 requiredUsdc);
    /// @notice Retained legacy error selector; the current canonical zero-bounty close path does not raise it.
    error CfdEngine__InsufficientCloseOrderBountyBacking(
        uint256 requiredBountyUsdc, uint256 availableBackingUsdc, uint256 unpaidCarryUsdc
    );

    /// @dev Deprecated compatibility getters; this lens no longer previews or validates USDC grants.
    uint256 public constant MAX_CLOSE_SUBSIDY_USDC = 200_000;
    address public immutable SPONSORED_ENGINE;

    constructor(
        address sponsoredEngine
    ) {
        SPONSORED_ENGINE = sponsoredEngine;
    }

    struct ClosePreview {
        CfdEnginePlanTypes.CloseCommitment commitment;
        uint256 commitmentCarryUsdc;
        uint256 executionBountyUsdc;
        OrderV3Types.ExecutionAssessment assessment;
    }

    function previewClose(
        address engineAddress,
        address account,
        OrderV3Types.OrderRequest calldata request,
        address executor,
        uint256 executionPrice,
        uint64 publishTime
    ) external view returns (ClosePreview memory preview) {
        if (!request.isClose) {
            revert CfdClosePreview__NotCloseOrder();
        }
        if (request.bounds.minPostSettlementBalanceUsdc != 0) {
            revert IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported();
        }
        CfdEnginePlanTypes.RawSnapshot memory snapshot;
        CfdEnginePlanTypes.CloseDelta memory delta;
        uint256 bounty;
        {
            ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
            ICfdClosePreviewRouter router = ICfdClosePreviewRouter(engine.orderRouter());
            bounty = ICloseAdmission(router.liquidationBatchSidecar()).previewCloseAdmission(account, request);
            ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
            snapshot = _buildRawSnapshot(engine, planner, account, IHousePool(engine.pool()).totalAssets());
            if (bounty != 0) {
                revert ICfdEngineTypes.CfdEngine__InvalidRiskParams();
            }
            preview.commitment = CloseCommitmentLib.project(snapshot, request.sizeDelta);
            preview.commitmentCarryUsdc = preview.commitment.carryCollectedUsdc;
            preview.executionBountyUsdc = bounty;
            delta = planner.planClose(snapshot, _requestOrder(account, request), executionPrice, publishTime);
        }
        preview.assessment = _evaluateClose(snapshot, delta, request.bounds, bounty, executor == account);
        _includeCommitment(preview.assessment, preview.commitment, request.bounds, bounty);
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
        uint64 publishTime,
        OrderV3Types.ExecutionBounds calldata bounds
    ) external view returns (ClosePreview memory preview) {
        if (!order.isClose) {
            revert CfdClosePreview__NotCloseOrder();
        }
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, IHousePool(engine.pool()).totalAssets());
        return _previewSnapshot(engine, planner, snapshot, order, executor, executionPrice, publishTime, bounds);
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
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order,
        address executor,
        uint256 executionPrice,
        uint64 publishTime,
        OrderV3Types.ExecutionBounds calldata bounds
    ) private view returns (ClosePreview memory preview) {
        preview.executionBountyUsdc = ICfdClosePreviewRouter(engine.orderRouter()).closeOrderExecutionBountyUsdc();
        _validateRouterCommit(snapshot, order);

        if (preview.executionBountyUsdc != 0) {
            revert ICfdEngineTypes.CfdEngine__InvalidRiskParams();
        }
        preview.commitment = CloseCommitmentLib.project(snapshot, order.sizeDelta);
        preview.commitmentCarryUsdc = preview.commitment.carryCollectedUsdc;
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snapshot, order, executionPrice, publishTime);
        preview.assessment =
            _evaluateClose(snapshot, delta, bounds, preview.executionBountyUsdc, executor == order.account);
        _includeCommitment(preview.assessment, preview.commitment, bounds, preview.executionBountyUsdc);
    }

    /// @dev The router checks side and partial-close dust before reserving even a zero bounty. Its queued-position
    ///      projection is deliberately not reproduced here; callers must still simulate the actual commitment.
    function _validateRouterCommit(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdTypes.Order memory order
    ) private pure {
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
        uint256 commitPrice = snapshot.lastMarkPrice == 0 ? 1e8 : snapshot.lastMarkPrice;
        commitPrice = Math.min(commitPrice, snapshot.capPrice);
        uint256 minNotionalUsdc =
            Math.mulDiv(snapshot.riskParams.minBountyUsdc, 10_000, snapshot.riskParams.bountyBps, Math.Rounding.Ceil);
        uint256 minCloseSizeDelta =
            Math.mulDiv(minNotionalUsdc, DecimalConstants.USDC_TO_TOKEN_SCALE, commitPrice, Math.Rounding.Ceil);
        if (order.sizeDelta < minCloseSizeDelta) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(11);
        }
    }

}

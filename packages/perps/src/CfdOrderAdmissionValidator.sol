// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {ICfdOrderAdmissionValidator} from "@plether/perps/interfaces/ICfdOrderAdmissionValidator.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";

interface IAdmissionRouter is IOrderRouterAccounting {

    function lifecycleBook() external view returns (IOrderLifecycleBook);
    function admin() external view returns (address);

}

/// @notice Fixed feasibility and eligible queue projection, isolated from Router/lens deployment-size budgets.
/// @dev Reads only the permanently bound engine and its canonical Router. It never releases actual reservations.
contract CfdOrderAdmissionValidator is ICfdOrderAdmissionValidator, IOrderRouterErrors {

    ICfdEngineCore public immutable engine;

    struct QueuedPosition {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 closeableSize;
    }

    constructor(
        address engine_
    ) {
        engine = ICfdEngineCore(engine_);
    }

    /// @inheritdoc ICfdOrderAdmissionValidator
    function validateRequest(
        OrderV3Types.OrderRequest calldata request
    ) external view {
        _validateRequest(request, _domain(0));
    }

    /// @inheritdoc ICfdOrderAdmissionValidator
    function validateOpen(
        address account,
        OrderV3Types.OrderRequest calldata request,
        uint256 bountyAssets
    ) external view {
        OrderValidationLib.ExecutionDomain memory domain = _domain(bountyAssets);
        _validateRequest(request, domain);
        QueuedPosition memory position = _queuedPosition(account);
        if (position.exists && position.side != request.side) {
            revert OrderRouter__PredictableOpenInvalid(uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING));
        }
        if (position.size > request.bounds.maxPostPositionSize - request.sizeDelta) {
            revert OrderRouter__ImpossibleExecutionRequest();
        }
        (uint256 minimumPrice, uint256 maximumPrice) = OrderValidationLib.executionPriceRange(
            request.side, false, request.sizeDelta, request.targetPrice, request.bounds, domain
        );
        CfdEnginePlanTypes.OpenRevertCode code = CfdEnginePlanLib.getQueuedOpenRevertCode(
            position.size,
            request.sizeDelta,
            request.marginDelta,
            minimumPrice,
            maximumPrice,
            domain.vpiDisabled ? domain.executionFeeBps : 0,
            ICfdEngineRiskParamsView(address(engine)).riskParams()
        );
        if (code != CfdEnginePlanTypes.OpenRevertCode.OK) {
            revert OrderRouter__PredictableOpenInvalid(uint8(code));
        }
    }

    /// @inheritdoc ICfdOrderAdmissionValidator
    function queuedPosition(
        address account
    ) external view returns (bool exists, CfdTypes.Side side, uint256 size, uint256 closeableSize) {
        QueuedPosition memory position = _queuedPosition(account);
        return (position.exists, position.side, position.size, position.closeableSize);
    }

    function _validateRequest(
        OrderV3Types.OrderRequest calldata request,
        OrderValidationLib.ExecutionDomain memory domain
    ) private pure {
        OrderValidationLib.validateBaseCommit(request.sizeDelta, request.marginDelta, request.isClose);
        if (
            !request.isClose
                && (request.sizeDelta / CfdTypes.SIZE_QUANTUM > type(uint112).max
                    || request.marginDelta > uint256(type(int256).max))
        ) {
            revert OrderRouter__PredictableOpenInvalid(uint8(CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED));
        }
        if (!OrderValidationLib.isRequestFeasible(
                request.side, request.isClose, request.sizeDelta, request.targetPrice, request.bounds, domain
            )) {
            revert OrderRouter__ImpossibleExecutionRequest();
        }
    }

    function _queuedPosition(
        address account
    ) private view returns (QueuedPosition memory position) {
        (position.size,,,, position.side,,) = engine.positions(account);
        position.exists = position.size != 0;
        position.closeableSize = position.size;
        CfdTypes.Side liveSide = position.side;
        IAdmissionRouter router = IAdmissionRouter(engine.orderRouter());
        uint64 orderId = router.accountHeadOrderId(account);
        if (orderId == 0) {
            return position;
        }
        uint64 riskOffCutoff = IOrderRouterEmergencyAdmin(router.admin()).riskOffOrderCutoff();
        IOrderLifecycleBook book = router.lifecycleBook();
        bytes32 currentConfigHash = book.currentExecutionConfigHash();
        OrderValidationLib.ExecutionDomain memory domain = _domain(0);
        CfdTypes.RiskParams memory riskParams = ICfdEngineRiskParamsView(address(engine)).riskParams();
        for (; orderId != 0;) {
            (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextOrderId) =
                router.getPendingOrderView(orderId);
            OrderV3Types.PendingIntent memory intent = book.pendingIntent(orderId);
            if (
                (riskOffCutoff == 0 || orderId > riskOffCutoff || pending.isClose)
                    && block.timestamp <= intent.timing.executionDeadline
                    && (intent.bounds.expectedConfigHash == bytes32(0)
                        || intent.bounds.expectedConfigHash == currentConfigHash)
            ) {
                domain.executionBountyAssets = intent.executionBountyAssets;
                position = _projectPendingOrder(position, liveSide, pending, intent, domain, riskParams);
            }
            orderId = nextOrderId;
        }
    }

    function _projectPendingOrder(
        QueuedPosition memory position,
        CfdTypes.Side liveSide,
        IOrderRouterAccounting.PendingOrderView memory pending,
        OrderV3Types.PendingIntent memory intent,
        OrderValidationLib.ExecutionDomain memory domain,
        CfdTypes.RiskParams memory riskParams
    ) private pure returns (QueuedPosition memory) {
        OrderV3Types.ExecutionBounds memory bounds = intent.bounds;
        if (pending.isClose) {
            uint256 carry = intent.commitment.carryCollectedAssets;
            if (carry > bounds.maxActionChargeAssets) {
                return position;
            }
            if (domain.vpiDisabled) {
                // The collected carry is added to the assessed action charge at execution.
                bounds.maxActionChargeAssets -= carry;
            }
        }
        if (!OrderValidationLib.isRequestFeasible(
                pending.side, pending.isClose, pending.sizeDelta, pending.targetPrice, bounds, domain
            )) {
            return position;
        }
        if (pending.isClose) {
            if (
                position.exists && pending.side == position.side && pending.sizeDelta <= position.size
                    && position.size - pending.sizeDelta <= bounds.maxPostPositionSize
                    && (position.size == pending.sizeDelta
                        || bounds.minPostPositionEquityAssets <= uint256(type(int256).max))
            ) {
                position.size -= pending.sizeDelta;
                position.exists = position.size != 0;
                if (pending.side == liveSide) {
                    position.closeableSize =
                        position.closeableSize > pending.sizeDelta ? position.closeableSize - pending.sizeDelta : 0;
                }
            }
            return position;
        }
        if (position.exists && pending.side != position.side) {
            return position;
        }
        if (position.size > bounds.maxPostPositionSize - pending.sizeDelta) {
            return position;
        }
        (uint256 minimumPrice, uint256 maximumPrice) = OrderValidationLib.executionPriceRange(
            pending.side, false, pending.sizeDelta, pending.targetPrice, bounds, domain
        );
        if (
            CfdEnginePlanLib.getQueuedOpenRevertCode(
                    position.size,
                    pending.sizeDelta,
                    pending.marginDelta,
                    minimumPrice,
                    maximumPrice,
                    domain.vpiDisabled ? domain.executionFeeBps : 0,
                    riskParams
                ) != CfdEnginePlanTypes.OpenRevertCode.OK
        ) {
            return position;
        }
        position.exists = true;
        position.side = pending.side;
        position.size += pending.sizeDelta;
        return position;
    }

    function _domain(
        uint256 bountyAssets
    ) private view returns (OrderValidationLib.ExecutionDomain memory domain) {
        ICfdEngineRiskParamsView riskView = ICfdEngineRiskParamsView(address(engine));
        domain.capPrice = engine.CAP_PRICE();
        domain.executionFeeBps = riskView.executionFeeBps();
        domain.vpiDisabled = riskView.riskParams().vpiFactor == 0;
        domain.executionBountyAssets = bountyAssets;
    }

}

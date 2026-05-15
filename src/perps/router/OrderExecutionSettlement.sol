// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineCore} from "../interfaces/ICfdEngineCore.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {OrderOracleExecution} from "./OrderOracleExecution.sol";
import {OrderQueueBook} from "./OrderQueueBook.sol";

/// @notice Terminal order execution settlement and engine-revert classification helpers.
abstract contract OrderExecutionSettlement is OrderOracleExecution, OrderQueueBook {

    enum FailedOrderOutcome {
        ClearerFull
    }

    enum OrderFailReason {
        Expired,
        CloseOnly,
        SlippageExceeded,
        EnginePanic,
        AccountLiquidated,
        EngineRevert
    }

    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);

    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    bytes4 internal constant TYPED_ORDER_FAILURE_SELECTOR = ICfdEngineCore.CfdEngine__TypedOrderFailure.selector;
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineCore.CfdEngine__MarkPriceOutOfOrder.selector;

    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

    function _processTypedOrderExecution(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 housePoolDepth,
        uint64 oraclePublishTime
    ) internal returns (bool success, OrderFailReason failureReason, FailedOrderOutcome failureOutcome) {
        try engine.processOrderTyped(order, executionPrice, housePoolDepth, oraclePublishTime) {
            return (true, OrderFailReason.EngineRevert, FailedOrderOutcome.ClearerFull);
        } catch (bytes memory revertData) {
            bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
            if (selector == MARK_PRICE_OUT_OF_ORDER_SELECTOR) {
                revert IOrderRouterErrors.OrderRouter__OracleValidation(9);
            }
            failureReason = selector == PANIC_SELECTOR ? OrderFailReason.EnginePanic : OrderFailReason.EngineRevert;
            failureOutcome = _failedOutcomeFromEngineRevert(order, revertData);
            return (false, failureReason, failureOutcome);
        }
    }

    function _finalizeOrCleanupOrder(
        uint64 orderId,
        bool success,
        FailedOrderOutcome failedOutcome,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        if (success) {
            _finalizeExecution(orderId, executionPrice, oraclePublishTime);
        } else {
            _cleanupOrder(orderId, failedOutcome, executionPrice, oraclePublishTime);
        }
    }

    function _decodeTypedOrderFailure(
        bytes memory revertData
    )
        internal
        pure
        returns (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose)
    {
        assembly {
            failureCategory := mload(add(revertData, 36))
            failureCode := mload(add(revertData, 68))
            isClose := mload(add(revertData, 100))
        }
    }

    function _failedOutcomeFromEngineRevert(
        CfdTypes.Order memory order,
        bytes memory revertData
    ) internal pure returns (FailedOrderOutcome outcome) {
        if (revertData.length >= 4 && bytes4(revertData) == TYPED_ORDER_FAILURE_SELECTOR) {
            (CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode,) =
                _decodeTypedOrderFailure(revertData);
            if (order.isClose) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCode == uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES)) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCategory == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated) {
                return FailedOrderOutcome.ClearerFull;
            }
            if (failureCategory == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid) {
                return FailedOrderOutcome.ClearerFull;
            }
        }

        return _failedOutcomeForTerminalFailure(order);
    }

    function _failedOutcomeForTerminalFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    function _failedOutcomeForSlippageFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    function _cleanupOrder(
        uint64 orderId,
        FailedOrderOutcome,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderEscrow(orderId, false, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        _consumeOrderEscrow(orderId, true, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Executed);
    }

}

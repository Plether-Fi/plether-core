// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";
import {OrderQueueBook} from "@plether/perps/router/OrderQueueBook.sol";

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
    bytes4 internal constant TYPED_ORDER_FAILURE_SELECTOR = ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector;
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector;

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
                revert OrderRouter__MarkPriceOutOfOrder();
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
        if (revertData.length < 100) {
            return (failureCategory, failureCode, isClose);
        }

        bytes memory args = new bytes(revertData.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = revertData[i + 4];
        }
        (failureCategory, failureCode, isClose) =
            abi.decode(args, (CfdEnginePlanTypes.ExecutionFailurePolicyCategory, uint8, bool));
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
        executionBountyUsdc = _consumeOrderReservation(orderId, false, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
    }

    function _finalizeExecution(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        _consumeOrderReservation(orderId, true, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Executed);
    }

}

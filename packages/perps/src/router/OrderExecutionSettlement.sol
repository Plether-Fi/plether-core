// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";
import {OrderQueueBook} from "@plether/perps/router/OrderQueueBook.sol";

/// @title OrderExecutionSettlement
/// @notice Classifies engine execution failures and performs terminal reservation and queue settlement.
abstract contract OrderExecutionSettlement is OrderOracleExecution, OrderQueueBook {

    /// @notice Clearinghouse disposition selected for a terminal failed order.
    enum FailedOrderOutcome {
        /// @notice Release any committed margin and pay the entire reserved execution bounty to the caller.
        ClearerFull
    }

    /// @notice Public classification emitted when an order reaches a failed terminal state.
    enum OrderFailReason {
        /// @notice The configured maximum order age elapsed.
        Expired,
        /// @notice Execution was blocked by close-only policy.
        /// @dev Reserved for compatibility; close-only currently stops/reverts execution without terminal failure.
        CloseOnly,
        /// @notice The resolved price violated the order's direction-aware limit.
        SlippageExceeded,
        /// @notice The engine reverted with Solidity's `Panic(uint256)` selector.
        EnginePanic,
        /// @notice The order was cleared because its account was liquidated.
        AccountLiquidated,
        /// @notice A non-panic engine revert other than the separately rethrown mark-price-out-of-order selector,
        ///         including empty data.
        EngineRevert
    }

    /// @notice Emitted when an order is processed successfully and reaches `Executed` status.
    /// @param orderId Executed order id.
    /// @param executionPrice Oracle price used by the engine (8 decimals).
    event OrderExecuted(uint64 indexed orderId, uint256 executionPrice);
    /// @notice Emitted when an order is terminally failed and removed from live queues.
    /// @param orderId Failed order id.
    /// @param reason Router-level failure classification.
    event OrderFailed(uint64 indexed orderId, OrderFailReason reason);

    /// @notice Solidity `Panic(uint256)` error selector.
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    /// @notice Engine typed-order failure selector decoded for settlement policy.
    bytes4 internal constant TYPED_ORDER_FAILURE_SELECTOR = ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector;
    /// @notice Engine out-of-order mark selector promoted to a nonterminal router revert.
    bytes4 internal constant MARK_PRICE_OUT_OF_ORDER_SELECTOR = ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector;

    /// @notice Removes an order from all live queues and records its terminal status.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus `Executed` or `Failed` status to retain.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual;

    /// @notice Calls the engine's typed order path and normalizes success or revert classification.
    /// @dev A mark-price-out-of-order engine revert is promoted to a router revert instead of terminally
    ///      failing the order. Other panics and reverts return failure metadata to the caller.
    /// @param order Order payload to process.
    /// @param executionPrice Validated execution price (8 decimals).
    /// @param housePoolDepth Current HousePool assets used as execution depth (6-decimal USDC).
    /// @param oraclePublishTime Publish timestamp of the execution basket.
    /// @return success Whether the engine processed the order.
    /// @return failureReason Meaningful only when `success` is false.
    /// @return failureOutcome Clearinghouse disposition to use on failure.
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

    /// @notice Dispatches an order to successful finalization or failed cleanup.
    /// @param orderId Order id to settle.
    /// @param success Whether engine execution succeeded.
    /// @param failedOutcome Failure disposition; ignored on success.
    /// @param executionPrice Execution price supplied to bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to bounty accounting.
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

    /// @notice Decodes the engine's typed execution-failure payload after its four-byte selector.
    /// @dev Returns zero-valued outputs when the payload is shorter than the 100-byte selector-plus-ABI minimum.
    ///      Malformed longer ABI data may cause `abi.decode` to revert.
    /// @param revertData Complete engine revert bytes.
    /// @return failureCategory Engine failure-policy category.
    /// @return failureCode Engine open/close revert code encoded as `uint8`.
    /// @return isClose Whether the engine classified the failed action as a close.
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

    /// @notice Maps engine revert data to the clearinghouse disposition for the failed order.
    /// @dev Every current branch resolves to `ClearerFull`; the typed decoding preserves an explicit extension
    ///      point and documents that closes, drained-margin opens, and state/user-invalid opens are terminal.
    /// @param order Order rejected by the engine.
    /// @param revertData Complete engine revert bytes.
    /// @return outcome Failure disposition.
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

    /// @notice Returns the disposition for expiry and other terminal failures detected by the router.
    /// @param order Terminally failed order; currently does not alter the disposition.
    /// @return outcome Always `ClearerFull`.
    function _failedOutcomeForTerminalFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    /// @notice Returns the disposition for a direction-aware slippage failure.
    /// @param order Slippage-failed order; currently does not alter the disposition.
    /// @return outcome Always `ClearerFull`.
    function _failedOutcomeForSlippageFailure(
        CfdTypes.Order memory order
    ) internal pure returns (FailedOrderOutcome outcome) {
        order;
        return FailedOrderOutcome.ClearerFull;
    }

    /// @notice Releases failed-order margin, pays its reserved bounty to `msg.sender`, and records `Failed` status.
    /// @dev The unnamed failure-outcome argument is currently reserved for future settlement policies; all
    ///      callers pass `ClearerFull`.
    /// @param orderId Failed order id.
    /// @param executionPrice Price supplied to engine bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to engine bounty accounting.
    /// @return executionBountyUsdc Bounty credited to the caller (6-decimal USDC), or zero.
    function _cleanupOrder(
        uint64 orderId,
        FailedOrderOutcome,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        executionBountyUsdc = _consumeOrderReservation(orderId, false, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
    }

    /// @notice Pays a successfully executed order's bounty and records `Executed` status.
    /// @param orderId Executed order id.
    /// @param executionPrice Price supplied to engine bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to engine bounty accounting.
    function _finalizeExecution(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal {
        _consumeOrderReservation(orderId, true, executionPrice, oraclePublishTime);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Executed);
    }

}

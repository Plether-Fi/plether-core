// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @notice Pure validation helpers for delayed-order router checks.
library OrderValidationLib {

    function validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure {
        if (sizeDelta == 0) {
            revert IOrderRouterErrors.OrderRouter__ZeroSize();
        }
        if (isClose && marginDelta > 0) {
            revert IOrderRouterErrors.OrderRouter__CloseWithPositiveMargin();
        }
    }

    function validateCloseCommit(
        bool positionExists,
        uint256 queuedSize,
        CfdTypes.Side queuedSide,
        CfdTypes.Side requestedSide,
        uint256 sizeDelta
    ) internal pure {
        if (!positionExists || queuedSize == 0) {
            revert IOrderRouterErrors.OrderRouter__NoQueuedPosition();
        }
        if (queuedSide != requestedSide) {
            revert IOrderRouterErrors.OrderRouter__SideMismatch();
        }
        if (sizeDelta > queuedSize) {
            revert IOrderRouterErrors.OrderRouter__SizeExceedsQueued();
        }
    }

    function validateBatchBounds(
        uint64 maxOrderId,
        uint64 nextExecuteId,
        uint64 nextCommitId
    ) internal pure {
        if (nextExecuteId == 0) {
            revert IOrderRouterErrors.OrderRouter__NoOrdersToExecute();
        }
        if (maxOrderId < nextExecuteId) {
            revert IOrderRouterErrors.OrderRouter__BatchBeforeQueueHead();
        }
        if (maxOrderId >= nextCommitId) {
            revert IOrderRouterErrors.OrderRouter__BatchOrderNotCommitted();
        }
    }

    function checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0) {
            return true;
        }
        if (order.isClose) {
            if (order.side == CfdTypes.Side.BULL) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.BULL) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @notice Pure validation helpers for delayed-order router checks.
library OrderValidationLib {

    /// @notice Validates size and margin constraints common to order commits.
    /// @param sizeDelta Requested position-size delta (18 decimals).
    /// @param marginDelta Requested nonnegative margin amount (6 decimals).
    /// @param isClose Whether the order is a close/reduce order.
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

    /// @notice Validates a close order against the router's queued-position projection.
    /// @param positionExists Whether the router's queued-position projection currently exists.
    /// @param queuedSize Projected position size after earlier queued orders (18 decimals).
    /// @param queuedSide Projected position side after earlier queued orders.
    /// @param requestedSide Side supplied by the close request.
    /// @param sizeDelta Requested reduction in position size (18 decimals).
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

    /// @notice Validates an inclusive global-queue endpoint for batch execution.
    /// @param maxOrderId Last order identifier the batch may attempt.
    /// @param nextExecuteId Current global queue-head candidate. It starts at one before the first commit and becomes
    ///        zero only after a previously populated queue drains.
    /// @param nextCommitId Next identifier that will be assigned to a newly committed order.
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

    /// @notice Checks execution price against the order's directional target-price boundary.
    /// @dev A zero target disables the check. Close BULL accepts prices at or below the target; close BEAR accepts
    ///      prices at or above it. Open BULL uses the opposite comparison, as does open BEAR.
    /// @param order Order whose side, close flag, and target price define the boundary.
    /// @param executionPrice Proposed execution price (8 decimals).
    /// @return Whether the proposed price satisfies the order boundary.
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

/// @notice Pure validation helpers for delayed-order router checks.
library OrderValidationLib {

    function validateBaseCommit(
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal pure returns (bool zeroSize, uint8 validationCode) {
        if (sizeDelta == 0) {
            return (true, 0);
        }
        if (isClose && marginDelta > 0) {
            return (false, 2);
        }
        return (false, 0);
    }

    function validateCloseCommit(
        bool positionExists,
        uint256 queuedSize,
        CfdTypes.Side queuedSide,
        CfdTypes.Side requestedSide,
        uint256 sizeDelta
    ) internal pure returns (uint8 validationCode) {
        if (!positionExists || queuedSize == 0) {
            return 3;
        }
        if (queuedSide != requestedSide) {
            return 4;
        }
        if (sizeDelta > queuedSize) {
            return 5;
        }
        return 0;
    }

    function validateBatchBounds(
        uint64 maxOrderId,
        uint64 nextExecuteId,
        uint64 nextCommitId
    ) internal pure returns (uint8 validationCode) {
        if (nextExecuteId == 0) {
            return 0;
        }
        if (maxOrderId < nextExecuteId) {
            return 2;
        }
        if (maxOrderId >= nextCommitId) {
            return 3;
        }
        return 0;
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

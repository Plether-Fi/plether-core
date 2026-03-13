// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

library OrderEscrowAccountingLib {

    struct AccountEscrowTotals {
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        uint256 pendingOrderCount;
    }

    struct AccountOrderSummaryTotals {
        uint256 pendingOrderCount;
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
        bool hasTerminalCloseQueued;
    }

    struct PendingOrderData {
        uint64 orderId;
        bool isClose;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        uint64 commitTime;
        uint64 commitBlock;
        uint256 committedMarginUsdc;
        uint256 executionBountyUsdc;
    }

    function matchesAccount(
        CfdTypes.Order memory order,
        bytes32 accountId
    ) internal pure returns (bool) {
        return order.accountId == accountId && order.sizeDelta > 0;
    }

    function includeOrder(
        AccountEscrowTotals memory totals,
        uint256 committedMarginUsdc,
        uint256 executionBountyUsdc
    ) internal pure returns (AccountEscrowTotals memory) {
        totals.committedMarginUsdc += committedMarginUsdc;
        totals.executionBountyUsdc += executionBountyUsdc;
        totals.pendingOrderCount++;
        return totals;
    }

    function includeOrder(
        AccountOrderSummaryTotals memory totals,
        CfdTypes.Order memory order,
        uint256 committedMarginUsdc,
        uint256 executionBountyUsdc
    ) internal pure returns (AccountOrderSummaryTotals memory) {
        totals.pendingOrderCount++;
        totals.committedMarginUsdc += committedMarginUsdc;
        totals.executionBountyUsdc += executionBountyUsdc;
        if (order.isClose) {
            totals.hasTerminalCloseQueued = true;
        }
        return totals;
    }

    function buildPendingOrderData(
        uint64 orderId,
        CfdTypes.Order memory order,
        uint256 committedMarginUsdc,
        uint256 executionBountyUsdc
    ) internal pure returns (PendingOrderData memory pending) {
        pending = PendingOrderData({
            orderId: orderId,
            isClose: order.isClose,
            side: order.side,
            sizeDelta: order.sizeDelta,
            marginDelta: order.marginDelta,
            targetPrice: order.targetPrice,
            commitTime: order.commitTime,
            commitBlock: order.commitBlock,
            committedMarginUsdc: committedMarginUsdc,
            executionBountyUsdc: executionBountyUsdc
        });
    }

}

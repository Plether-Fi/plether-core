// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngine} from "../interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract OrderEscrowAccounting is IOrderRouterAccounting {
    using SafeERC20 for IERC20;

    struct OrderRecord {
        CfdTypes.Order core;
        IOrderRouterAccounting.OrderStatus status;
        uint256 executionBountyUsdc;
        uint256 marginBackedExecutionBountyUsdc;
        uint64 retryAfterTimestamp;
        uint64 nextPendingOrderId;
        uint64 prevPendingOrderId;
        uint64 nextGlobalOrderId;
        uint64 prevGlobalOrderId;
        uint64 nextMarginOrderId;
        uint64 prevMarginOrderId;
        bool inMarginQueue;
    }

    ICfdEngine public immutable engine;
    IMarginClearinghouse internal immutable clearinghouse;
    IERC20 internal immutable USDC;

    mapping(uint64 => OrderRecord) internal orderRecords;
    mapping(bytes32 => uint256) public pendingOrderCounts;
    mapping(bytes32 => uint256) public pendingCloseSize;
    mapping(bytes32 => uint64) public marginHeadOrderId;
    mapping(bytes32 => uint64) public marginTailOrderId;

    constructor(address _engine) {
        engine = ICfdEngine(_engine);
        clearinghouse = _engine.code.length == 0
            ? IMarginClearinghouse(address(0))
            : IMarginClearinghouse(ICfdEngine(_engine).clearinghouse());
        USDC = _engine.code.length == 0 ? IERC20(address(0)) : ICfdEngine(_engine).USDC();
    }

    function getAccountEscrow(
        bytes32 accountId
    ) public view override returns (IOrderRouterAccounting.AccountEscrowView memory escrow) {
        escrow.committedMarginUsdc = clearinghouse.getAccountReservationSummary(accountId).activeCommittedOrderMarginUsdc;
        uint64 orderId = _pendingHeadOrderId(accountId);
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            escrow.executionBountyUsdc += record.executionBountyUsdc;
            escrow.pendingOrderCount++;
            orderId = record.nextPendingOrderId;
        }
    }

    function getAccountOrderSummary(
        bytes32 accountId
    ) public view returns (IOrderRouterAccounting.AccountOrderSummary memory summary) {
        uint64 orderId = _pendingHeadOrderId(accountId);
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;
            summary.pendingOrderCount++;
            if (order.isClose) {
                summary.pendingCloseSize += order.sizeDelta;
                summary.hasTerminalCloseQueued = true;
            }
            summary.committedMarginUsdc += clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
            summary.executionBountyUsdc += record.executionBountyUsdc;
            orderId = record.nextPendingOrderId;
        }
    }

    function getMarginReservationIds(
        bytes32 accountId
    ) public view override returns (uint64[] memory orderIds) {
        uint64 cursor = marginHeadOrderId[accountId];
        uint256 count;
        while (cursor != 0) {
            count++;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }

        orderIds = new uint64[](count);
        cursor = marginHeadOrderId[accountId];
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = cursor;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }
    }

    function _reserveExecutionBounty(
        bytes32 accountId,
        uint64 orderId,
        uint256 executionBountyUsdc,
        bool isClose
    ) internal {
        if (executionBountyUsdc == 0) {
            return;
        }

        if (isClose) {
            orderRecords[orderId].marginBackedExecutionBountyUsdc =
                _reserveCloseExecutionBounty(accountId, executionBountyUsdc);
        } else {
            if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) < executionBountyUsdc) {
                _revertInsufficientFreeEquity();
            }
            clearinghouse.seizeUsdc(accountId, executionBountyUsdc, address(this));
        }
        orderRecords[orderId].executionBountyUsdc = executionBountyUsdc;
    }

    function _reserveCommittedMargin(
        bytes32 accountId,
        uint64 orderId,
        bool isClose,
        uint256 marginDelta
    ) internal {
        if (isClose || marginDelta == 0) {
            return;
        }
        clearinghouse.reserveCommittedOrderMargin(accountId, orderId, marginDelta);
        _linkMarginOrder(accountId, orderId);
    }

    function _consumeOrderEscrow(
        uint64 orderId,
        bool success,
        uint8 failedPolicy
    ) internal returns (uint256 executionBountyUsdc) {
        if (success) {
            return _collectExecutionBounty(orderId);
        }

        _releaseCommittedMargin(orderId);
        if (failedPolicy == 1) {
            return _collectExecutionBounty(orderId);
        } else if (failedPolicy == 2) {
            _refundExecutionBounty(orderId);
        }
        return 0;
    }

    function _collectExecutionBounty(
        uint64 orderId
    ) internal returns (uint256 executionBountyUsdc) {
        OrderRecord storage record = _orderRecord(orderId);
        executionBountyUsdc = record.executionBountyUsdc;
        if (executionBountyUsdc == 0) {
            return 0;
        }
        record.executionBountyUsdc = 0;
        record.marginBackedExecutionBountyUsdc = 0;
        USDC.safeTransfer(msg.sender, executionBountyUsdc);
    }

    function _refundExecutionBounty(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        uint256 marginBackedBountyUsdc = record.marginBackedExecutionBountyUsdc;
        if (marginBackedBountyUsdc > 0) {
            record.marginBackedExecutionBountyUsdc = 0;
            record.executionBountyUsdc -= marginBackedBountyUsdc;
            USDC.safeTransfer(address(clearinghouse), marginBackedBountyUsdc);
            engine.restoreCloseOrderExecutionBounty(record.core.accountId, marginBackedBountyUsdc);
        }

        uint256 bounty = record.executionBountyUsdc;
        if (bounty == 0) {
            return;
        }

        record.executionBountyUsdc = 0;
        if (record.core.isClose && engine.hasOpenPosition(record.core.accountId)) {
            USDC.safeTransfer(address(clearinghouse), bounty);
            clearinghouse.settleUsdc(record.core.accountId, int256(bounty));
        } else if (record.core.isClose) {
            address trader = address(uint160(uint256(record.core.accountId)));
            USDC.safeTransfer(trader, bounty);
        } else {
            address trader = address(uint160(uint256(record.core.accountId)));
            USDC.safeTransfer(trader, bounty);
        }
    }

    function _releaseCommittedMargin(
        uint64 orderId
    ) internal {
        clearinghouse.releaseOrderReservationIfActive(orderId);
    }

    function _linkMarginOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.inMarginQueue) {
            return;
        }

        uint64 tailOrderId = marginTailOrderId[accountId];
        if (tailOrderId == 0) {
            marginHeadOrderId[accountId] = orderId;
            marginTailOrderId[accountId] = orderId;
        } else {
            orderRecords[tailOrderId].nextMarginOrderId = orderId;
            record.prevMarginOrderId = tailOrderId;
            marginTailOrderId[accountId] = orderId;
        }

        record.inMarginQueue = true;
    }

    function _unlinkMarginOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (!record.inMarginQueue) {
            return;
        }

        uint64 prevOrderId = record.prevMarginOrderId;
        uint64 nextOrderId = record.nextMarginOrderId;
        uint64 headOrderId = marginHeadOrderId[accountId];
        uint64 tailOrderId = marginTailOrderId[accountId];

        if (headOrderId == orderId) {
            marginHeadOrderId[accountId] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextMarginOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            _revertMarginOrderLinkCorrupted();
        }

        if (tailOrderId == orderId) {
            marginTailOrderId[accountId] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevMarginOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            _revertMarginOrderLinkCorrupted();
        }

        record.nextMarginOrderId = 0;
        record.prevMarginOrderId = 0;
        record.inMarginQueue = false;
    }

    function _pruneMarginQueue(
        bytes32 accountId
    ) internal {
        uint64 orderId = marginHeadOrderId[accountId];
        while (orderId != 0) {
            uint256 remainingCommittedMarginUsdc = clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
            uint64 nextOrderId = orderRecords[orderId].nextMarginOrderId;
            if (remainingCommittedMarginUsdc == 0) {
                _unlinkMarginOrder(accountId, orderId);
            }
            orderId = nextOrderId;
        }
    }

    function _orderRecord(
        uint64 orderId
    ) internal view virtual returns (OrderRecord storage record) {
        return orderRecords[orderId];
    }

    function _pendingHeadOrderId(bytes32 accountId) internal view virtual returns (uint64);

    function _reserveCloseExecutionBounty(bytes32 accountId, uint256 executionBountyUsdc)
        internal
        virtual
        returns (uint256 marginBackedBountyUsdc);

    function _revertInsufficientFreeEquity() internal pure virtual;

    function _revertMarginOrderLinkCorrupted() internal pure virtual;
}

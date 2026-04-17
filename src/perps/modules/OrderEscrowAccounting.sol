// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineCore} from "../interfaces/ICfdEngineCore.sol";
import {IMarginClearinghouse} from "../interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "../libraries/MarginClearinghouseAccountingLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract OrderEscrowAccounting is IOrderRouterAccounting {

    using SafeERC20 for IERC20;

    struct OrderRecord {
        CfdTypes.Order core;
        IOrderRouterAccounting.OrderStatus status;
        uint256 executionBountyUsdc;
        uint64 nextGlobalOrderId;
        uint64 prevGlobalOrderId;
        uint64 nextAccountOrderId;
        uint64 prevAccountOrderId;
        uint64 nextMarginOrderId;
        uint64 prevMarginOrderId;
        bool inAccountQueue;
        bool inMarginQueue;
    }

    ICfdEngineCore public immutable engine;
    IMarginClearinghouse internal immutable clearinghouse;
    IERC20 internal immutable USDC;

    mapping(uint64 => OrderRecord) internal orderRecords;
    mapping(bytes32 => uint256) public pendingOrderCounts;
    mapping(bytes32 => uint256) public pendingCloseSize;
    mapping(bytes32 => uint64) public accountHeadOrderId;
    mapping(bytes32 => uint64) internal accountTailOrderId;
    mapping(bytes32 => uint64) public marginHeadOrderId;
    mapping(bytes32 => uint64) public marginTailOrderId;

    constructor(
        address _engine
    ) {
        engine = ICfdEngineCore(_engine);
        clearinghouse = _engine.code.length == 0
            ? IMarginClearinghouse(address(0))
            : IMarginClearinghouse(ICfdEngineCore(_engine).clearinghouse());
        USDC = _engine.code.length == 0 ? IERC20(address(0)) : ICfdEngineCore(_engine).USDC();
    }

    function getAccountEscrow(
        bytes32 accountId
    ) public view override returns (IOrderRouterAccounting.AccountEscrowView memory escrow) {
        // Clearinghouse remains the canonical owner of committed-order margin value; this module only composes the view.
        escrow.committedMarginUsdc =
        clearinghouse.getAccountReservationSummary(accountId).activeCommittedOrderMarginUsdc;
        (escrow.pendingOrderCount, escrow.executionBountyUsdc,,) = _summarizePendingOrders(accountId);
    }

    function _summarizePendingOrders(
        bytes32 accountId
    )
        internal
        view
        returns (
            uint256 pendingOrderCount,
            uint256 executionBountyUsdc,
            uint256 pendingCloseSize_,
            bool hasTerminalCloseQueued
        )
    {
        uint64 orderId = accountHeadOrderId[accountId];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            CfdTypes.Order memory order = record.core;
            pendingOrderCount++;
            executionBountyUsdc += record.executionBountyUsdc;
            if (order.isClose) {
                pendingCloseSize_ += order.sizeDelta;
                hasTerminalCloseQueued = true;
            }
            orderId = record.nextAccountOrderId;
        }
    }

    function _nextCommitId() internal view virtual returns (uint64);

    function getMarginReservationIds(
        bytes32 accountId
    ) public view override returns (uint64[] memory orderIds) {
        // Router queue links expose reservation traversal order only; remaining reservation value lives in MarginClearinghouse.
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
        uint256 sizeDelta,
        uint256 executionBountyUsdc,
        bool isClose
    ) internal {
        if (executionBountyUsdc == 0) {
            return;
        }

        if (isClose) {
            _reserveCloseExecutionBounty(accountId, sizeDelta, executionBountyUsdc);
        } else {
            if (
                MarginClearinghouseAccountingLib.getFreeSettlementUsdc(clearinghouse.getAccountUsdcBuckets(accountId))
                    < executionBountyUsdc
            ) {
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
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        if (success) {
            return _collectExecutionBounty(orderId, executionPrice, oraclePublishTime);
        }

        _releaseCommittedMargin(orderId);
        return _collectExecutionBounty(orderId, executionPrice, oraclePublishTime);
    }

    function _collectExecutionBounty(
        uint64 orderId,
        uint256 executionPrice,
        uint64 oraclePublishTime
    ) internal returns (uint256 executionBountyUsdc) {
        OrderRecord storage record = _orderRecord(orderId);
        executionBountyUsdc = record.executionBountyUsdc;
        if (executionBountyUsdc == 0) {
            return 0;
        }
        record.executionBountyUsdc = 0;
        USDC.safeTransfer(address(clearinghouse), executionBountyUsdc);
        engine.creditKeeperExecutionBounty(msg.sender, executionBountyUsdc, executionPrice, oraclePublishTime);
        return executionBountyUsdc;
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

    function _linkAccountOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.inAccountQueue) {
            return;
        }

        uint64 tailOrderId = accountTailOrderId[accountId];
        if (tailOrderId == 0) {
            accountHeadOrderId[accountId] = orderId;
            accountTailOrderId[accountId] = orderId;
        } else {
            orderRecords[tailOrderId].nextAccountOrderId = orderId;
            record.prevAccountOrderId = tailOrderId;
            accountTailOrderId[accountId] = orderId;
        }

        record.inAccountQueue = true;
    }

    function _unlinkAccountOrder(
        bytes32 accountId,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (!record.inAccountQueue) {
            return;
        }

        uint64 prevOrderId = record.prevAccountOrderId;
        uint64 nextOrderId = record.nextAccountOrderId;
        uint64 headOrderId = accountHeadOrderId[accountId];
        uint64 tailOrderId = accountTailOrderId[accountId];

        if (headOrderId == orderId) {
            accountHeadOrderId[accountId] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextAccountOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            _revertPendingOrderLinkCorrupted();
        }

        if (tailOrderId == orderId) {
            accountTailOrderId[accountId] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevAccountOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            _revertPendingOrderLinkCorrupted();
        }

        record.nextAccountOrderId = 0;
        record.prevAccountOrderId = 0;
        record.inAccountQueue = false;
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

    function _reserveCloseExecutionBounty(
        bytes32 accountId,
        uint256 sizeDelta,
        uint256 executionBountyUsdc
    ) internal virtual;

    function _revertInsufficientFreeEquity() internal pure virtual;

    function _revertMarginOrderLinkCorrupted() internal pure virtual;

    function _revertPendingOrderLinkCorrupted() internal pure virtual;

}

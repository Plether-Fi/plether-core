// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @title OrderReservationAccounting
/// @notice Router-side reservation records and per-account queue links shared by commit, execution, and liquidation.
/// @dev The clearinghouse is canonical for USDC custody and committed-margin values. This contract stores
///      order metadata, bounty amounts, and linked-list indexes; it never holds the reserved USDC itself.
abstract contract OrderReservationAccounting is IOrderRouterAccounting, IOrderRouterErrors {

    /// @notice Persistent metadata and linked-list pointers for one committed order.
    /// @dev Core order data is retained after terminal status, while all live queue pointers are cleared on deletion.
    /// @param core Canonical delayed-order payload.
    /// @param status Current lifecycle status.
    /// @param executionBountyUsdc Unpaid keeper bounty reserved in the clearinghouse (6-decimal USDC).
    /// @param nextGlobalOrderId Next order in the global FIFO queue, or zero at the tail.
    /// @param prevGlobalOrderId Previous order in the global FIFO queue, or zero at the head.
    /// @param nextAccountOrderId Next live order for the same account, or zero at the tail.
    /// @param prevAccountOrderId Previous live order for the same account, or zero at the head.
    /// @param nextMarginOrderId Next committed-margin reservation link for the account, or zero at the tail.
    /// @param prevMarginOrderId Previous committed-margin reservation link for the account, or zero at the head.
    /// @param inAccountQueue Whether the record is currently linked in the account queue.
    /// @param inMarginQueue Whether the record is currently linked in the committed-margin queue.
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

    /// @notice Engine that processes orders, reserves close bounties, and credits keeper bounties.
    ICfdEngineCore public immutable engine;
    /// @notice Clearinghouse that owns settlement and committed-margin reservation balances.
    IMarginClearinghouse internal immutable clearinghouse;

    mapping(uint64 => OrderRecord) internal orderRecords;
    /// @notice Number of live pending orders attributed to each account.
    mapping(address => uint256) public pendingOrderCounts;
    /// @notice Sum of size deltas across each account's live close orders (18 decimals).
    mapping(address => uint256) public pendingCloseSize;
    /// @notice First live pending order id in each account's FIFO queue, or zero when empty.
    mapping(address => uint64) public accountHeadOrderId;
    mapping(address => uint64) internal accountTailOrderId;
    /// @notice First order id in each account's committed-margin reservation queue, or zero when empty.
    mapping(address => uint64) public marginHeadOrderId;
    /// @notice Last order id in each account's committed-margin reservation queue, or zero when empty.
    mapping(address => uint64) public marginTailOrderId;

    /// @notice Binds reservation accounting to an engine and its clearinghouse.
    /// @dev When `_engine` has no code, `clearinghouse` is deliberately set to zero instead of attempting
    ///      an interface call; operational methods will then fail until deployed with a real engine.
    /// @param _engine Engine address used by the router stack.
    constructor(
        address _engine
    ) {
        engine = ICfdEngineCore(_engine);
        clearinghouse = _engine.code.length == 0
            ? IMarginClearinghouse(address(0))
            : IMarginClearinghouse(ICfdEngineCore(_engine).clearinghouse());
    }

    /// @notice Returns aggregate reservations and live-order count attributed to an account.
    /// @dev Committed margin comes from the clearinghouse's canonical account summary. Bounty and count are
    ///      summed by traversing the router's live account queue. Monetary fields use 6-decimal USDC.
    /// @param account Account to inspect.
    /// @return reservation Pending-order count plus committed-margin and unpaid execution-bounty totals.
    function getAccountReservations(
        address account
    ) public view override returns (IOrderRouterAccounting.AccountReservationView memory reservation) {
        // Clearinghouse remains the canonical owner of committed-order margin value; this router component composes the view.
        reservation.committedMarginUsdc =
        clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginUsdc;
        (reservation.pendingOrderCount, reservation.executionBountyUsdc,,) = _summarizePendingOrders(account);
    }

    /// @notice Traverses an account queue and summarizes live orders.
    /// @param account Account whose linked queue is traversed.
    /// @return pendingOrderCount Number of linked live orders.
    /// @return executionBountyUsdc Sum of unpaid reserved bounties (6-decimal USDC).
    /// @return pendingCloseSize_ Sum of close size deltas (18 decimals).
    /// @return hasTerminalCloseQueued Whether at least one close order is linked.
    function _summarizePendingOrders(
        address account
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
        uint64 orderId = accountHeadOrderId[account];
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

    /// @notice Returns the current router-maintained margin-reservation order ids for an account.
    /// @dev This reports structural traversal order, including links whose clearinghouse value has reached
    ///      zero but has not yet been pruned. It does not read or return reservation amounts.
    /// @param account Account to inspect.
    /// @return orderIds Order ids linked into the account's margin reservation queue in FIFO order.
    function getMarginReservationIds(
        address account
    ) public view override returns (uint64[] memory orderIds) {
        // Router queue links expose reservation traversal order only; remaining reservation value lives in MarginClearinghouse.
        uint64 cursor = marginHeadOrderId[account];
        uint256 count;
        while (cursor != 0) {
            count++;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }

        orderIds = new uint64[](count);
        cursor = marginHeadOrderId[account];
        for (uint256 i = 0; i < count; i++) {
            orderIds[i] = cursor;
            cursor = orderRecords[cursor].nextMarginOrderId;
        }
    }

    /// @notice Reserves and records the keeper bounty for a newly assigned order id.
    /// @dev A zero bounty is a no-op. Open-order bounties are locked from free settlement after an explicit
    ///      balance check; close-order bounties use the engine hook implemented by the router base.
    /// @param account Account funding the bounty.
    /// @param orderId Newly assigned order id.
    /// @param sizeDelta Order size used by close-bounty reservation (18 decimals).
    /// @param executionBountyUsdc Bounty to reserve (6-decimal USDC).
    /// @param isClose Whether to use the close-order reservation path.
    function _reserveExecutionBounty(
        address account,
        uint64 orderId,
        uint256 sizeDelta,
        uint256 executionBountyUsdc,
        bool isClose
    ) internal {
        if (executionBountyUsdc == 0) {
            return;
        }

        if (isClose) {
            _reserveCloseExecutionBounty(account, sizeDelta, executionBountyUsdc);
        } else {
            if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < executionBountyUsdc) {
                revert OrderRouter__InsufficientFreeEquity();
            }
            clearinghouse.lockReservedSettlement(account, executionBountyUsdc);
        }
        orderRecords[orderId].executionBountyUsdc = executionBountyUsdc;
    }

    /// @notice Reserves open-order margin in the clearinghouse and links the order into the margin queue.
    /// @dev Close orders and zero margin are no-ops.
    /// @param account Account funding committed margin.
    /// @param orderId Order whose reservation is created.
    /// @param isClose Whether the order is a strict close.
    /// @param marginDelta Margin to reserve (6-decimal USDC).
    function _reserveCommittedMargin(
        address account,
        uint64 orderId,
        bool isClose,
        uint256 marginDelta
    ) internal {
        if (isClose || marginDelta == 0) {
            return;
        }
        clearinghouse.reserveCommittedOrderMargin(account, orderId, marginDelta);
        _linkMarginOrder(account, orderId);
    }

    /// @notice Settles the router-side reservation after an execution attempt.
    /// @dev On failure, releases any still-active committed margin before paying the bounty. On success,
    ///      committed margin has already been released immediately before the engine call, so only the bounty is collected.
    /// @param orderId Order being finalized.
    /// @param success Whether engine execution succeeded.
    /// @param executionPrice Oracle execution price supplied to bounty accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to bounty accounting.
    /// @return executionBountyUsdc Bounty credited to the caller (6-decimal USDC), or zero.
    function _consumeOrderReservation(
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

    /// @notice Clears an order's recorded bounty and asks the engine to credit it to `msg.sender`.
    /// @param orderId Finalized order id.
    /// @param executionPrice Oracle execution price supplied to engine accounting (8 decimals).
    /// @param oraclePublishTime Oracle publish timestamp supplied to engine accounting.
    /// @return executionBountyUsdc Bounty credited to the caller (6-decimal USDC), or zero.
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
        engine.creditBounty(record.core.account, msg.sender, executionBountyUsdc, executionPrice, oraclePublishTime);
        return executionBountyUsdc;
    }

    /// @notice Idempotently releases any active clearinghouse committed-margin reservation for an order.
    /// @param orderId Order whose clearinghouse reservation is released.
    function _releaseCommittedMargin(
        uint64 orderId
    ) internal {
        clearinghouse.releaseOrderReservationIfActive(orderId);
    }

    /// @notice Appends an order to an account's doubly linked margin-reservation queue.
    /// @dev No-ops if the record is already linked.
    /// @param account Account that owns the reservation.
    /// @param orderId Order to append.
    function _linkMarginOrder(
        address account,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.inMarginQueue) {
            return;
        }

        uint64 tailOrderId = marginTailOrderId[account];
        if (tailOrderId == 0) {
            marginHeadOrderId[account] = orderId;
            marginTailOrderId[account] = orderId;
        } else {
            orderRecords[tailOrderId].nextMarginOrderId = orderId;
            record.prevMarginOrderId = tailOrderId;
            marginTailOrderId[account] = orderId;
        }

        record.inMarginQueue = true;
    }

    /// @notice Appends an order to an account's doubly linked live-order queue.
    /// @dev No-ops if the record is already linked.
    /// @param account Account that submitted the order.
    /// @param orderId Order to append.
    function _linkAccountOrder(
        address account,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (record.inAccountQueue) {
            return;
        }

        uint64 tailOrderId = accountTailOrderId[account];
        if (tailOrderId == 0) {
            accountHeadOrderId[account] = orderId;
            accountTailOrderId[account] = orderId;
        } else {
            orderRecords[tailOrderId].nextAccountOrderId = orderId;
            record.prevAccountOrderId = tailOrderId;
            accountTailOrderId[account] = orderId;
        }

        record.inAccountQueue = true;
    }

    /// @notice Removes an order from an account's live-order queue and clears its account pointers.
    /// @dev No-ops if unlinked and reverts when stored head/tail/pointers prove corrupt.
    /// @param account Account queue to mutate.
    /// @param orderId Order to remove.
    function _unlinkAccountOrder(
        address account,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (!record.inAccountQueue) {
            return;
        }

        uint64 prevOrderId = record.prevAccountOrderId;
        uint64 nextOrderId = record.nextAccountOrderId;
        uint64 headOrderId = accountHeadOrderId[account];
        uint64 tailOrderId = accountTailOrderId[account];

        if (headOrderId == orderId) {
            accountHeadOrderId[account] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextAccountOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__AccountQueueCorrupt();
        }

        if (tailOrderId == orderId) {
            accountTailOrderId[account] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevAccountOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__AccountQueueCorrupt();
        }

        record.nextAccountOrderId = 0;
        record.prevAccountOrderId = 0;
        record.inAccountQueue = false;
    }

    /// @notice Removes an order from an account's margin queue and clears its margin pointers.
    /// @dev No-ops if unlinked and reverts when stored head/tail/pointers prove corrupt.
    /// @param account Margin queue to mutate.
    /// @param orderId Order to remove.
    function _unlinkMarginOrder(
        address account,
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (!record.inMarginQueue) {
            return;
        }

        uint64 prevOrderId = record.prevMarginOrderId;
        uint64 nextOrderId = record.nextMarginOrderId;
        uint64 headOrderId = marginHeadOrderId[account];
        uint64 tailOrderId = marginTailOrderId[account];

        if (headOrderId == orderId) {
            marginHeadOrderId[account] = nextOrderId;
        } else if (prevOrderId != 0) {
            orderRecords[prevOrderId].nextMarginOrderId = nextOrderId;
        } else if (tailOrderId != orderId) {
            revert OrderRouter__MarginQueueCorrupt();
        }

        if (tailOrderId == orderId) {
            marginTailOrderId[account] = prevOrderId;
        } else if (nextOrderId != 0) {
            orderRecords[nextOrderId].prevMarginOrderId = prevOrderId;
        } else if (headOrderId != orderId) {
            revert OrderRouter__MarginQueueCorrupt();
        }

        record.nextMarginOrderId = 0;
        record.prevMarginOrderId = 0;
        record.inMarginQueue = false;
    }

    /// @notice Removes every margin-queue link whose clearinghouse reservation has no remaining value.
    /// @param account Account whose full margin queue is traversed.
    function _pruneMarginQueue(
        address account
    ) internal {
        uint64 orderId = marginHeadOrderId[account];
        while (orderId != 0) {
            uint256 remainingCommittedMarginUsdc = clearinghouse.getOrderReservation(orderId).remainingAmountUsdc;
            uint64 nextOrderId = orderRecords[orderId].nextMarginOrderId;
            if (remainingCommittedMarginUsdc == 0) {
                _unlinkMarginOrder(account, orderId);
            }
            orderId = nextOrderId;
        }
    }

    /// @notice Returns the storage record for an order id without checking its status or existence.
    /// @param orderId Order id to look up.
    /// @return record Storage reference; an unassigned id references a zero-initialized record.
    function _orderRecord(
        uint64 orderId
    ) internal view virtual returns (OrderRecord storage record) {
        return orderRecords[orderId];
    }

    /// @notice Reserves a close-order execution bounty through the concrete engine integration.
    /// @param account Account funding the close bounty.
    /// @param sizeDelta Close size used for engine solvency validation (18 decimals).
    /// @param executionBountyUsdc Bounty to reserve (6-decimal USDC).
    function _reserveCloseExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 executionBountyUsdc
    ) internal virtual;

}

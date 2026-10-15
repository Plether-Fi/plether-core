// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @title OrderReservationAccounting
/// @notice Router-side pending records and per-account queue links shared by commit, execution, and liquidation.
/// @dev The clearinghouse is canonical for USDC custody and committed-margin values. This contract stores
///      order metadata and lifecycle queue indexes; it never holds the reserved USDC itself.
abstract contract OrderReservationAccounting is IOrderRouterAccounting, IOrderRouterErrors {

    function _onOrderCommitted(
        CfdTypes.Order memory order,
        CfdEnginePlanTypes.CloseCommitment memory effects,
        uint64 sourcePositionEpoch
    ) internal virtual;

    /// @notice Ephemeral metadata and linked-list pointers for one pending order.
    /// @dev The complete record is deleted on every terminal transition. Permanent identity and outcomes live in the
    ///      immutable lifecycle book.
    /// @param core Canonical delayed-order payload.
    /// @param status Current lifecycle status.
    /// @param nextGlobalOrderId Next order in the global FIFO queue, or zero at the tail.
    /// @param prevGlobalOrderId Previous order in the global FIFO queue, or zero at the head.
    /// @param nextAccountOrderId Next live order for the same account, or zero at the tail.
    /// @param prevAccountOrderId Previous live order for the same account, or zero at the head.
    /// @param inAccountQueue Whether the record is currently linked in the account queue.
    struct OrderRecord {
        CfdTypes.Order core;
        IOrderRouterAccounting.OrderStatus status;
        uint64 nextGlobalOrderId;
        uint64 prevGlobalOrderId;
        uint64 nextAccountOrderId;
        uint64 prevAccountOrderId;
        bool inAccountQueue;
    }

    /// @notice Engine that processes orders, validates zero-bounty closes, and credits keeper bounties.
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

    /// @notice Binds reservation accounting to an engine and its clearinghouse.
    /// @dev When `_engine` has no code, `clearinghouse` is deliberately set to zero instead of attempting an interface
    ///      call. That immutable binding is not refreshed if code is later deployed at the engine address.
    /// @param _engine Engine address used by the router stack.
    constructor(
        address _engine
    ) {
        engine = ICfdEngineCore(_engine);
        clearinghouse = _engine.code.length == 0
            ? IMarginClearinghouse(address(0))
            : IMarginClearinghouse(ICfdEngineCore(_engine).clearinghouse());
    }

    /// @notice Combines Router-owned lifecycle counts with clearinghouse-owned reservation balances.
    /// @dev The bounty total includes live open-order reserves and unpaid protection-trigger reserves. Latched
    ///      protections and their zero-bounty close attempts add no reserved value.
    function getAccountReservations(
        address account
    ) public view override returns (IOrderRouterAccounting.AccountReservationView memory reservation) {
        reservation.committedMarginUsdc =
        clearinghouse.getAccountReservationSummary(account).activeCommittedOrderMarginUsdc;
        reservation.pendingOrderCount = pendingOrderCounts[account];
        reservation.executionBountyUsdc = clearinghouse.totalBountyReservationsUsdc(account);
    }

    /// @notice Compatibility view over the clearinghouse-owned active reservation FIFO.
    function getMarginReservationIds(
        address account
    ) public view override returns (uint64[] memory) {
        return clearinghouse.getMarginReservationIds(account);
    }

    function marginHeadOrderId(
        address account
    ) public view returns (uint64) {
        return clearinghouse.marginReservationHead(account);
    }

    function marginTailOrderId(
        address account
    ) public view returns (uint64) {
        return clearinghouse.marginReservationTail(account);
    }

    /// @notice Reserves the keeper bounty for a newly assigned order id.
    /// @dev Zero-bounty closes still validate admission and checkpoint carry through the engine hook implemented by
    ///      the router base. Open-order bounties are locked from free settlement.
    /// @param account Account committing the order and funding any open-order bounty.
    /// @param sizeDelta Order size used by close admission (18 decimals).
    /// @param bounty Bounty to reserve for an open, or zero for a close (6-decimal USDC).
    /// @param isClose Whether to use the zero-bounty close admission path.
    function _reserveExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 bounty,
        bool isClose
    ) internal returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        if (isClose) {
            if (bounty != 0) {
                revert ICfdEngineTypes.CfdEngine__InvalidRiskParams();
            }
            return _reserveCloseExecutionBounty(account, sizeDelta);
        }
        effects.bountyFromFreeUsdc = bounty;
        if (bounty == 0) {
            return effects;
        }
        if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < bounty) {
            revert OrderRouter__InsufficientFreeEquity();
        }
        clearinghouse.lockReservedSettlement(account, bounty);
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

    /// @notice Returns the storage record for an order id without checking its status or existence.
    /// @param orderId Order id to look up.
    /// @return record Storage reference; an unassigned id references a zero-initialized record.
    function _orderRecord(
        uint64 orderId
    ) internal view virtual returns (OrderRecord storage record) {
        return orderRecords[orderId];
    }

    /// @notice Validates zero-bounty close admission through the concrete engine integration.
    /// @param account Account committing the close.
    /// @param sizeDelta Close size used for engine solvency validation (18 decimals).
    function _reserveCloseExecutionBounty(
        address account,
        uint256 sizeDelta
    ) internal virtual returns (CfdEnginePlanTypes.CloseCommitment memory);

}

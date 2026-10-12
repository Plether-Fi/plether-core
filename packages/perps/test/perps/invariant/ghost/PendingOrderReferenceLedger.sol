// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

/// @notice Input-driven pending-order and reservation ledger for the four-actor mixed accounting campaign.
/// @dev This model never reads production state or calls production arithmetic. Its bounded insertion-order array
/// deliberately differs from the Router's linked queues. Custody movements, carry and economic admission belong to
/// the enclosing reference model; this ledger tracks the reservation classifications supplied by those actions.
contract PendingOrderReferenceLedger {

    uint256 public constant ACTOR_COUNT = 4;
    uint256 public constant MAX_ACCOUNT_ORDERS = 5;
    uint256 public constant MAX_LIVE_ORDERS = 20;

    /// @dev Matches the public reservation status encoding without importing the production ledger implementation.
    enum MarginStatus {
        None,
        Active,
        Consumed,
        Released
    }

    struct Order {
        uint64 id;
        uint256 actorIndex;
        uint256 generation;
        OrderV3Types.OrderRequest request;
        uint64 commitTime;
        uint64 commitBlock;
        uint64 deadline;
        uint256 bountyFree;
        uint256 bountyPledge;
        uint256 bountyUsdc;
        uint256 remainingBounty;
        uint256 sourceGeneration;
        uint256 originalMargin;
        uint256 remainingMargin;
        MarginStatus marginStatus;
        OrderV3Types.LifecycleStatus status;
        OrderV3Types.TerminalReason reason;
        bytes32 requestHash;
        bytes32 receiptHash;
    }

    mapping(uint64 => Order) private _orders;
    mapping(uint256 => mapping(bytes32 => uint64)) private _clientOrders;
    uint64[20] private _live;
    uint256[4] private _counts;
    uint256 private _liveCount;
    uint64 private _nextId = 1;

    error InvalidActor();
    error InvalidRequest();
    error CapacityExceeded();
    error ClientIdConflict();
    error UnknownOrder();
    error OrderNotPending();
    error InvalidTerminalState();
    error MarginStillReserved();
    error BountyStillReserved();
    error InsufficientReservedMargin();
    error InvalidReceipt();

    /// @notice Archives an admitted public request and its independently computed reservation sources.
    /// @dev Exact client-id replay returns the original id even after terminalization or generation changes. Replay
    /// inputs describing a new timestamp or bounty are ignored, just as a replay creates no new reservation.
    function commit(
        uint256 actorIndex,
        uint256 generation,
        OrderV3Types.OrderRequest calldata request,
        uint256 bountyFree,
        uint256 bountyPledge,
        uint256 timestamp,
        uint256 blockNumber
    ) external returns (uint64 id) {
        _requireActor(actorIndex);
        bytes32 requestHash = keccak256(abi.encode(request));
        id = _clientOrders[actorIndex][request.clientOrderId];
        if (id != 0) {
            if (_orders[id].requestHash != requestHash) {
                revert ClientIdConflict();
            }
            return id;
        }
        if (
            request.clientOrderId == bytes32(0) || request.sizeDelta == 0
                || request.sizeDelta % CfdTypes.SIZE_QUANTUM != 0 || timestamp > type(uint64).max
                || blockNumber > type(uint64).max
                || timestamp + request.bounds.executionWindowSeconds > type(uint64).max
        ) {
            revert InvalidRequest();
        }
        if (_counts[actorIndex] == MAX_ACCOUNT_ORDERS || _liveCount == MAX_LIVE_ORDERS) {
            revert CapacityExceeded();
        }
        id = _nextId++;
        Order storage pending = _orders[id];
        pending.id = id;
        pending.actorIndex = actorIndex;
        pending.generation = generation;
        pending.request = request;
        pending.commitTime = uint64(timestamp);
        pending.commitBlock = uint64(blockNumber);
        pending.deadline = uint64(timestamp + request.bounds.executionWindowSeconds);
        pending.bountyFree = bountyFree;
        pending.bountyPledge = bountyPledge;
        pending.bountyUsdc = bountyFree + bountyPledge;
        pending.remainingBounty = pending.bountyUsdc;
        pending.sourceGeneration = bountyPledge == 0 ? 0 : generation;
        pending.originalMargin = request.isClose ? 0 : request.marginDelta;
        pending.remainingMargin = pending.originalMargin;
        pending.marginStatus = pending.originalMargin == 0 ? MarginStatus.None : MarginStatus.Active;
        pending.status = OrderV3Types.LifecycleStatus.Pending;
        pending.requestHash = requestHash;
        _clientOrders[actorIndex][request.clientOrderId] = id;
        _live[_liveCount++] = id;
        ++_counts[actorIndex];
    }

    function order(
        uint64 id
    ) external view returns (Order memory) {
        return _orders[id];
    }

    function clientOrder(
        uint256 actorIndex,
        bytes32 clientOrderId
    ) external view returns (uint64) {
        _requireActor(actorIndex);
        return _clientOrders[actorIndex][clientOrderId];
    }

    function liveIds() external view returns (uint64[] memory ids) {
        ids = new uint64[](_liveCount);
        for (uint256 i; i < _liveCount; ++i) {
            ids[i] = _live[i];
        }
    }

    function accountIds(
        uint256 actorIndex
    ) external view returns (uint64[] memory ids) {
        _requireActor(actorIndex);
        ids = new uint64[](_counts[actorIndex]);
        uint256 cursor;
        for (uint256 i; i < _liveCount; ++i) {
            uint64 id = _live[i];
            if (_orders[id].actorIndex == actorIndex) {
                ids[cursor++] = id;
            }
        }
    }

    function count(
        uint256 actorIndex
    ) external view returns (uint256) {
        _requireActor(actorIndex);
        return _counts[actorIndex];
    }

    function liveCount() external view returns (uint256) {
        return _liveCount;
    }

    /// @notice The Router uses a bootstrap head of one before its first commitment; later empty queues use zero.
    function head() external view returns (uint64) {
        return _liveCount == 0 ? (_nextId == 1 ? 1 : 0) : _live[0];
    }

    function tail() external view returns (uint64) {
        return _liveCount == 0 ? 0 : _live[_liveCount - 1];
    }

    function nextId() external view returns (uint64) {
        return _nextId;
    }

    function margin(
        uint256 actorIndex
    ) public view returns (uint256 total) {
        _requireActor(actorIndex);
        for (uint256 i; i < _liveCount; ++i) {
            Order storage pending = _orders[_live[i]];
            if (pending.actorIndex == actorIndex) {
                total += pending.remainingMargin;
            }
        }
    }

    function bounty(
        uint256 actorIndex
    ) external view returns (uint256 total) {
        _requireActor(actorIndex);
        for (uint256 i; i < _liveCount; ++i) {
            Order storage pending = _orders[_live[i]];
            if (pending.actorIndex == actorIndex) {
                total += pending.remainingBounty;
            }
        }
    }

    function pendingCloseLots(
        uint256 actorIndex
    ) external view returns (uint256 lots) {
        _requireActor(actorIndex);
        for (uint256 i; i < _liveCount; ++i) {
            Order storage pending = _orders[_live[i]];
            if (pending.actorIndex == actorIndex && pending.request.isClose) {
                lots += pending.request.sizeDelta / CfdTypes.SIZE_QUANTUM;
            }
        }
    }

    /// @notice Convenience projection for the campaign's fixed actor sides (even Long, odd Short).
    function queuedLots(
        uint256 actorIndex,
        uint256 liveLots,
        uint64 riskOffCutoff
    ) external view returns (uint256) {
        return _queuedLots(actorIndex, liveLots, CfdTypes.Side(actorIndex % 2), riskOffCutoff);
    }

    /// @notice Projects queued exposure from independently modeled live lots and side. Expired orders still count
    /// until terminalized; cutoff-invalid opens do not. Once a close flattens the family, a later open can change side.
    function queuedLots(
        uint256 actorIndex,
        uint256 liveLots,
        CfdTypes.Side liveSide,
        uint64 riskOffCutoff
    ) external view returns (uint256) {
        return _queuedLots(actorIndex, liveLots, liveSide, riskOffCutoff);
    }

    function _queuedLots(
        uint256 actorIndex,
        uint256 lots,
        CfdTypes.Side side,
        uint64 riskOffCutoff
    ) private view returns (uint256) {
        _requireActor(actorIndex);
        for (uint256 i; i < _liveCount; ++i) {
            Order storage pending = _orders[_live[i]];
            if (pending.actorIndex != actorIndex) {
                continue;
            }
            OrderV3Types.OrderRequest storage request = pending.request;
            if (!request.isClose && pending.id <= riskOffCutoff) {
                continue;
            }
            uint256 orderLots = request.sizeDelta / CfdTypes.SIZE_QUANTUM;
            if (request.isClose) {
                if (lots != 0 && request.side == side) {
                    lots = orderLots < lots ? lots - orderLots : 0;
                }
            } else if (lots == 0) {
                lots = orderLots;
                side = request.side;
            } else if (request.side == side) {
                lots += orderLots;
            }
        }
        return lots;
    }

    /// @notice Releases only the still-active margin classification; it does not model a custody credit.
    function releaseMargin(
        uint64 id
    ) external returns (uint256 released) {
        Order storage pending = _orders[id];
        if (pending.marginStatus != MarginStatus.Active) {
            return 0;
        }
        released = pending.remainingMargin;
        pending.remainingMargin = 0;
        pending.marginStatus = MarginStatus.Released;
    }

    /// @notice Charges terminal action economics to an account's committed margin in insertion order. Consuming a
    /// reservation does not terminalize its order; a later execution may still fail, execute, expire or be invalidated.
    function consumeMargin(
        uint256 actorIndex,
        uint256 amount
    ) external returns (uint256 consumed) {
        if (amount > margin(actorIndex)) {
            revert InsufficientReservedMargin();
        }
        uint256 remaining = amount;
        for (uint256 i; i < _liveCount && remaining != 0; ++i) {
            Order storage pending = _orders[_live[i]];
            if (pending.actorIndex != actorIndex || pending.marginStatus != MarginStatus.Active) {
                continue;
            }
            uint256 debit = pending.remainingMargin < remaining ? pending.remainingMargin : remaining;
            pending.remainingMargin -= debit;
            remaining -= debit;
            if (pending.remainingMargin == 0) {
                pending.marginStatus = MarginStatus.Consumed;
            }
        }
        return amount;
    }

    /// @notice Removes a live bounty classification before its independently modeled payout/refund/forfeiture.
    /// The original free/pledge split and source generation remain archived for history and receipt verification.
    function takeBounty(
        uint64 id
    ) external returns (uint256 amount) {
        Order storage pending = _orders[id];
        if (pending.id == 0) {
            revert UnknownOrder();
        }
        if (pending.status != OrderV3Types.LifecycleStatus.Pending) {
            revert OrderNotPending();
        }
        amount = pending.remainingBounty;
        pending.remainingBounty = 0;
    }

    function marginStatus(
        uint64 id
    ) external view returns (MarginStatus) {
        return _orders[id].marginStatus;
    }

    /// @notice Removes a terminal order from live indexes while preserving its full historical request and funding.
    /// @dev The caller must explicitly release or consume margin and take bounty first, preventing silently lost value.
    function finalize(
        uint64 id,
        OrderV3Types.LifecycleStatus status,
        OrderV3Types.TerminalReason reason
    ) public {
        Order storage pending = _orders[id];
        if (pending.id == 0) {
            revert UnknownOrder();
        }
        if (pending.status != OrderV3Types.LifecycleStatus.Pending) {
            revert OrderNotPending();
        }
        if (
            (status != OrderV3Types.LifecycleStatus.Executed && status != OrderV3Types.LifecycleStatus.Failed)
                || reason == OrderV3Types.TerminalReason.None
                || ((status == OrderV3Types.LifecycleStatus.Executed)
                        != (reason == OrderV3Types.TerminalReason.Executed))
        ) {
            revert InvalidTerminalState();
        }
        if (pending.remainingMargin != 0) {
            revert MarginStillReserved();
        }
        if (pending.remainingBounty != 0) {
            revert BountyStillReserved();
        }
        pending.status = status;
        pending.reason = reason;
        --_counts[pending.actorIndex];
        for (uint256 i; i < _liveCount; ++i) {
            if (_live[i] != id) {
                continue;
            }
            for (uint256 j = i; j + 1 < _liveCount; ++j) {
                _live[j] = _live[j + 1];
            }
            delete _live[--_liveCount];
            return;
        }
        // Every pending order must be in the bounded queue; this is a model consistency failure.
        revert UnknownOrder();
    }

    /// @notice Optional evidence attachment after the handler has independently authenticated a terminal receipt.
    /// @dev Receipt hashes never determine expected economics, disposition, request identity or terminal reason.
    function recordReceipt(
        uint64 id,
        bytes32 validatedReceiptHash
    ) external {
        Order storage terminal = _orders[id];
        if (
            (terminal.status != OrderV3Types.LifecycleStatus.Executed
                    && terminal.status != OrderV3Types.LifecycleStatus.Failed) || validatedReceiptHash == bytes32(0)
                || (terminal.receiptHash != bytes32(0) && terminal.receiptHash != validatedReceiptHash)
        ) {
            revert InvalidReceipt();
        }
        terminal.receiptHash = validatedReceiptHash;
    }

    function _requireActor(
        uint256 actorIndex
    ) private pure {
        if (actorIndex >= ACTOR_COUNT) {
            revert InvalidActor();
        }
    }

}

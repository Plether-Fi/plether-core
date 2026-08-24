// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {OrderCommitHandler} from "@plether/perps/router/OrderCommitHandler.sol";

/// @title PositionProtectionHandler
/// @notice Lifecycle hooks for the external, state-owning position-protection book.
/// @dev Trader/keeper protection actions and views live directly on the discoverable Book. The concrete router reuses
///      its ordinary commit and mark-refresh selectors for the two Book-only authority operations.
abstract contract PositionProtectionHandler is OrderCommitHandler, ReentrancyGuardTransient {

    /// @notice Position-protection lifecycle component permanently bound to this router.
    IPositionProtectionBook public immutable positionProtectionBook;

    constructor() {
        positionProtectionBook =
            IPositionProtectionBook(address(new PositionProtectionBook(address(this), address(engine))));
    }

    /// @notice Refreshes a trigger mark, activates the Book record, and appends its pre-reserved close.
    /// @dev Called only from the concrete router's existing mark-refresh entrypoint after authenticating the Book.
    ///      The Book appends `(keeper, protectionId)` as the final two calldata words.
    function _triggerPositionProtectionFromBook(
        bytes[] calldata pythUpdateData
    ) internal {
        address keeper;
        uint64 protectionId;
        assembly ("memory-safe") {
            keeper := calldataload(sub(calldatasize(), 64))
            protectionId := calldataload(sub(calldatasize(), 32))
        }

        OracleUpdateResult memory update = _prepareMarkRefreshOracleFor(keeper, pythUpdateData);
        uint64 linkedOrderId = nextCommitId++;
        IPositionProtectionBook.TriggerPlan memory plan =
            positionProtectionBook.activate(protectionId, update.markPrice, update.oraclePublishTime, linkedOrderId);
        _recordTriggeredProtectionClose(linkedOrderId, plan);
        engine.creditBounty(plan.account, keeper, plan.triggerBountyUsdc, update.markPrice, update.oraclePublishTime);
    }

    function _recordTriggeredProtectionClose(
        uint64 orderId,
        IPositionProtectionBook.TriggerPlan memory plan
    ) private {
        OrderRecord storage record = orderRecords[orderId];
        record.core.account = plan.account;
        record.core.sizeDelta = plan.size;
        record.core.commitTime = uint64(block.timestamp);
        record.core.commitBlock = uint64(block.number);
        record.core.orderId = orderId;
        record.core.side = plan.side;
        record.core.isClose = true;
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        record.executionBountyUsdc = plan.executionBountyUsdc;
        pendingCloseSize[plan.account] += plan.size;
        _linkGlobalOrder(orderId);
        _linkAccountOrder(plan.account, orderId);
        // Book activation atomically required this count to be zero; router configuration always permits at least one.
        pendingOrderCounts[plan.account] = 1;
        emit OrderCommitted(orderId, plan.account, plan.side);
    }

    function _requireNoActivePositionProtection(
        address account
    ) internal view override {
        if (positionProtectionBook.activePositionProtectionId(account) != 0) {
            revert OrderRouter__ProtectionActive();
        }
    }

    function _additionalExecutionBountyUsdc(
        address account
    ) internal view virtual override returns (uint256) {
        return positionProtectionBook.unpaidBounties(account);
    }

    function _afterOrderDeleted(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual override {
        positionProtectionBook.afterOrderTerminal(orderId, account, terminalStatus);
    }

    function _protectionBountiesToForfeitOnLiquidation(
        address account
    ) internal virtual override returns (uint256 forfeitedUsdc) {
        return positionProtectionBook.forfeitOnLiquidation(account);
    }

}

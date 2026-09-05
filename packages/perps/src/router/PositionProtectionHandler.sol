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
///      its ordinary commit selector for Book-authenticated attached opens; delegated keeper logic calls the Router's
///      isolated self-only item entrypoints for protection triggers and liquidations.
abstract contract PositionProtectionHandler is OrderCommitHandler, ReentrancyGuardTransient {

    /// @notice Position-protection lifecycle component permanently bound to this router.
    IPositionProtectionBook public immutable positionProtectionBook;

    constructor() {
        positionProtectionBook =
            IPositionProtectionBook(address(new PositionProtectionBook(address(this), address(engine))));
    }

    function _requireNoActivePositionProtection(
        address account
    ) internal view override {
        if (positionProtectionBook.activePositionProtectionId(account) != 0) {
            revert OrderRouter__ProtectionActive();
        }
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

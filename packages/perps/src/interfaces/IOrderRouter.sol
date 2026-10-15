// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";

/// @notice Aggregate delayed-order router action, keeper, accounting, and admin-host surface.
/// @dev Router errors are declared in `IOrderRouterErrors`. Inherited function semantics and authorization are
///      documented by their role-specific parent interfaces.
interface IOrderRouter is IPerpsKeeper, IPerpsTraderActions, IOrderRouterAccounting, IOrderRouterAdminHost {

    /// @notice Returns the immutable position-protection book exposing TP/SL actions and retained protection views.
    /// @dev TP/SL calls are made directly to this address; the router does not forward their selectors.
    function positionProtectionBook() external view returns (address book);

    /// @notice Emitted after a delayed order is stored, reserved, and linked into live queues.
    /// @param orderId Monotonically increasing router order id.
    /// @param account Account that submitted and funds the order.
    /// @param side Direction to open/increase or direction of the queued position to close.
    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);

    /// @notice Applies a fresh mark-refresh oracle update and pushes its neutral mark price to the engine.
    /// @dev Permissionless and available while the router admin is paused. The Plether oracle pays the Pyth fee from
    ///      `msg.value` and refunds unused ETH to the caller or records a deferred claim if transfer fails.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the update fee
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable;

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";

/// @notice Aggregate delayed-order router action, keeper, accounting, and admin-host surface.
/// @dev The concrete router also inherits the wider canonical errors in `IOrderRouterErrors`; the declarations below
///      are a legacy compatibility subset. Inherited function semantics and authorization are documented by their
///      role-specific parent interfaces.
interface IOrderRouter is IPerpsKeeper, IPerpsTraderActions, IOrderRouterAccounting, IOrderRouterAdminHost {

    /// @notice An order commit supplied a zero position-size delta.
    error OrderRouter__ZeroSize();
    /// @notice Legacy compact oracle validation failure.
    /// @param code Numeric oracle validation reason.
    error OrderRouter__OracleValidation(uint8 code);
    /// @notice Legacy compact queue-state failure.
    /// @param code Numeric queue-state reason.
    error OrderRouter__QueueState(uint8 code);
    /// @notice A commit failed a compact economic or planner-derived validation rule.
    /// @param code Numeric validation reason; current code `11` denotes a below-minimum economic size.
    error OrderRouter__CommitValidation(uint8 code);
    /// @notice The EIP-150-forwardable gas remaining is below the configured minimum for an engine call.
    error OrderRouter__InsufficientGas();
    /// @notice Commit-time planner preflight identified a predictably invalid open/increase.
    /// @param code Numeric `CfdEnginePlanTypes.OpenRevertCode` returned by the engine lens.
    error OrderRouter__PredictableOpenInvalid(uint8 code);

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

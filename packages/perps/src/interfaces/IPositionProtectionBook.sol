// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";

/// @notice Direct user actions, retained state, and router-only lifecycle hooks for full-position TP/SL protection.
interface IPositionProtectionBook is IPositionProtectionActions, IPositionProtectionViews {

    /// @notice Values the router needs to append a triggered protection close to its ordinary FIFO queue.
    struct TriggerPlan {
        address account;
        CfdTypes.Side side;
        uint256 size;
        uint256 triggerBountyUsdc;
        uint256 executionBountyUsdc;
    }

    /// @notice Activates a met OCO leg and transfers both bounty obligations into a router trigger plan.
    /// @dev Router-only. The router calls this while atomically appending the linked close to its FIFO queue.
    function activate(
        uint64 protectionId,
        uint256 markPrice,
        uint64 publishTime,
        uint64 linkedOrderId
    ) external returns (TriggerPlan memory plan);

    /// @notice Applies a parent-open or linked-close terminal transition.
    function afterOrderTerminal(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) external;

    /// @notice Relatches the current failed close attempt when its protected position still matches exactly.
    /// @dev Router-only. The Router calls this before finalizing a non-liquidation failed child receipt. Returning
    ///      `true` transfers accounting attribution for the unchanged reserved bounty from the child back to this
    ///      Book; returning `false` permits ordinary bounty settlement after a missing or mismatched position resolves
    ///      the protection as `Failed`. Unknown and stale order ids are harmless no-ops that return `false`.
    function handleFailedProtectionAttempt(
        uint64 orderId,
        address account,
        OrderV2Types.TerminalReason reason,
        uint256 executionBountyUsdc
    ) external returns (bool retained);

    /// @notice Fails protection attached to a risk-off-invalidated parent without unlocking its reserve directly.
    /// @dev Router-only. The returned bounty is folded into the Router's no-checkpoint clearinghouse refund.
    function failPendingOpenForRiskOff(
        uint64 parentOrderId,
        address account
    ) external returns (uint256 refundableProtectionBountyUsdc);

    /// @notice Terminalizes active protection during liquidation and returns its unpaid non-order bounty.
    function forfeitOnLiquidation(
        address account
    ) external returns (uint256 forfeitedUsdc);

    /// @notice Returns unpaid reserved bounty value not yet represented by an ordinary queued order.
    function unpaidBounties(
        address account
    ) external view returns (uint256 unpaidBountyUsdc);

}

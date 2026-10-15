// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
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
    }

    /// @notice Activates a met OCO leg and returns the trigger bounty with a zero-bounty close plan.
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
    /// @dev Router-only. The Router validates that the close bounty is zero before this call. Returning `true`
    ///      latches the protection for a fresh retry; returning `false` resolves a missing or mismatched position as
    ///      `Failed`. Unknown and stale order ids return `false` without mutation.
    function handleFailedProtectionAttempt(
        uint64 orderId,
        address account,
        OrderV3Types.TerminalReason reason
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

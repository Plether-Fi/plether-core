// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderExecutionHandler
/// @notice Handles risk-off cleanup and the ETH refund policy used by V2 execution.
abstract contract OrderExecutionHandler is OrderValidation {

    /// @notice Permissionlessly refunds one pending open covered by the persistent risk-off cutoff.
    function _clearRiskOffOrder(
        uint64 orderId
    ) internal {
        OrderRecord storage record = _orderRecord(orderId);
        if (
            record.status != IOrderRouterAccounting.OrderStatus.Pending
                || !_isRiskOffOpen(orderId, record.core.isClose, _riskOffOrderCutoff())
        ) {
            revert OrderRouter__OrderNotRiskOff();
        }
        _settleRiskOffOrderWithReceipt(orderId, msg.sender);
    }

    /// @notice Sends an ETH refund or credits it in the admin contract when the recipient rejects the transfer.
    /// @dev A zero amount is a no-op. The fallback admin credit is funded with the same ETH amount and may revert.
    /// @param to Refund recipient.
    /// @param amount Amount to return in wei.
    function _sendEth(
        address to,
        uint256 amount
    ) internal {
        if (amount == 0) {
            return;
        }
        // Bound recipient code so a gas-burning fallback cannot consume the caller's bookkeeping tail and roll back
        // already-completed batch items. Contracts that need more gas can claim the deferred balance from the admin.
        (bool ok,) = payable(to).call{value: amount, gas: 30_000}("");
        if (!ok) {
            OrderRouterAdmin(admin).creditClaimableEth{value: amount}(to, amount);
        }
    }

}

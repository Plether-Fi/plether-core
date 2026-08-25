// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @notice Trader-facing action surface aligned with the current delayed-order router model.
interface IPerpsTraderActions {

    /// @notice Submits or idempotently resolves an account-scoped, financially bounded delayed-order intent.
    /// @dev An exact replay of a permanently bound `clientOrderId` returns the original order id without consulting
    ///      current protocol state or mutating reservations, counters, queues, or events. Reusing the id with any
    ///      different request field reverts. Fresh requests must pin the active execution-config hash and a finite
    ///      deadline no later than the router's current maximum order age.
    /// @param request Canonical V2 order request and caller-authorized execution bounds.
    /// @return orderId Newly assigned order id or the original id for an exact replay.
    function commitOrder(
        OrderV2Types.OrderRequest calldata request
    ) external returns (uint64 orderId);

}

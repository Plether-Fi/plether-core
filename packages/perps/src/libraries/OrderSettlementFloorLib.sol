// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

interface IOrderSettlementFloorRouter {

    function accountHeadOrderId(
        address account
    ) external view returns (uint64);
    function lifecycleBook() external view returns (IOrderLifecycleBook);

}

/// @notice Reads the funded floor from the isolated pending open; no separate floor ledger is required.
library OrderSettlementFloorLib {

    function load(
        address router,
        address account
    ) internal view returns (uint64 orderId, uint256 minimumUsdc, uint256 maxGrossDebitUsdc) {
        if (router == address(0)) {
            return (0, 0, 0);
        }
        IOrderSettlementFloorRouter host = IOrderSettlementFloorRouter(router);
        orderId = host.accountHeadOrderId(account);
        if (orderId == 0) {
            return (0, 0, 0);
        }
        OrderV3Types.ExecutionBounds memory bounds = host.lifecycleBook().pendingPolicy(orderId);
        return (orderId, bounds.minPostSettlementBalanceUsdc, bounds.maxGrossAccountDebitUsdc);
    }

}

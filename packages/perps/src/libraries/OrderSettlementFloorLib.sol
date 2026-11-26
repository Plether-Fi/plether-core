// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

interface IOrderSettlementFloorRouter {

    function accountHeadOrderId(
        address account
    ) external view returns (uint64);
    function lifecycleBook() external view returns (IOrderLifecycleBook);

}

/// @notice Reads the pending queue head and funded floor from the router; no separate floor ledger is required.
library OrderSettlementFloorLib {

    function pendingHeadOrderId(
        address router,
        address account
    ) internal view returns (uint64) {
        if (router == address(0)) {
            return 0;
        }
        return IOrderSettlementFloorRouter(router).accountHeadOrderId(account);
    }

    function load(
        address router,
        address account
    ) internal view returns (uint64 orderId, uint256 minimumAssets, uint256 maxGrossDebitAssets) {
        orderId = pendingHeadOrderId(router, account);
        if (orderId == 0) {
            return (0, 0, 0);
        }
        OrderV3Types.ExecutionBounds memory bounds =
            IOrderSettlementFloorRouter(router).lifecycleBook().pendingPolicy(orderId);
        return (orderId, bounds.minPostSettlementBalanceAssets, bounds.maxGrossAccountDebitAssets);
    }

}

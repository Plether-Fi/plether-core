// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "./OrderValidation.sol";

/// @notice Liquidation entry handling and post-liquidation queue cleanup.
abstract contract OrderLiquidationHandler is OrderValidation {

    function _executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareLiquidationOracle(account, pythUpdateData);

        _forfeitEscrowedOrderBountiesOnLiquidation(account);
        uint256 housePoolDepth = housePool.totalAssets();
        engine.liquidatePosition(account, update.executionPrice, housePoolDepth, update.oraclePublishTime, msg.sender);

        _clearLiquidatedAccountOrders(account);
    }

    function _clearLiquidatedAccountOrders(
        address account
    ) internal {
        uint64 orderId = accountHeadOrderId[account];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            uint64 nextOrderId = record.nextAccountOrderId;
            _releaseCommittedMargin(orderId);
            emit OrderFailed(orderId, OrderFailReason.AccountLiquidated);
            _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
            orderId = nextOrderId;
        }
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "./OrderValidation.sol";

/// @notice Liquidation entry handling and post-liquidation queue cleanup.
abstract contract OrderLiquidationHandler is OrderValidation {

    function _executeLiquidation(
        bytes32 accountId,
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareLiquidationOracle(pythUpdateData);

        _forfeitEscrowedOrderBountiesOnLiquidation(accountId);
        uint256 housePoolDepth = housePool.totalAssets();
        uint256 keeperBountyUsdc =
            engine.liquidatePosition(accountId, update.executionPrice, housePoolDepth, update.oraclePublishTime);

        _clearLiquidatedAccountOrders(accountId);
        _creditOrDeferLiquidationBounty(keeperBountyUsdc, update.executionPrice, update.oraclePublishTime);

        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _clearLiquidatedAccountOrders(
        bytes32 accountId
    ) internal {
        uint64 orderId = accountHeadOrderId[accountId];
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

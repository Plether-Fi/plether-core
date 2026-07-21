// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderLiquidationHandler
/// @notice Prices and executes account liquidation, forfeits queued bounties, and clears the account's live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

    /// @notice Liquidates an account with an adverse oracle snapshot and current HousePool depth.
    /// @dev Forfeits every queued execution bounty before calling the engine. The engine receives `msg.sender`
    ///      as liquidation keeper. After successful liquidation, all account orders are failed and unlinked;
    ///      any oracle or engine revert rolls the whole operation back.
    /// @param account Canonical account to liquidate.
    /// @param pythUpdateData Pyth update blobs funded by the call's `msg.value`.
    function _executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareLiquidationOracle(account, pythUpdateData);

        _forfeitReservedOrderBountiesOnLiquidation(account);
        uint256 housePoolDepth = housePool.totalAssets();
        engine.liquidatePosition(account, update.executionPrice, housePoolDepth, update.oraclePublishTime, msg.sender);

        _clearLiquidatedAccountOrders(account);
    }

    /// @notice Releases margin and terminally fails every live order belonging to a liquidated account.
    /// @dev Traverses the account queue using the successor cached before deletion and emits
    ///      `OrderFailed(AccountLiquidated)` for each order. Bounties are expected to have been forfeited first.
    /// @param account Liquidated account whose live queue is cleared.
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

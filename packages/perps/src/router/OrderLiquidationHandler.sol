// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderLiquidationHandler
/// @notice Prices and executes account liquidation, forfeits queued bounties, and clears the account's live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

    /// @notice Processes one batch account inside its own rollback frame.
    /// @dev Callable only by this router through delegated batch logic. This function deliberately has no reentrancy
    ///      modifier because the outer public batch call already holds the router's transient guard.
    /// @param account Candidate liquidation account.
    /// @param bullPrice Shared oracle price adverse to BULL positions.
    /// @param bearPrice Shared oracle price adverse to BEAR positions.
    /// @param publishTime Shared oracle publish timestamp.
    /// @param keeper Original external caller credited with any liquidation bounty.
    /// @return keeperBountyUsdc Bounty credited by the engine on success.
    function executeLiquidationBatchItem(
        address account,
        uint256 bullPrice,
        uint256 bearPrice,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 keeperBountyUsdc) {
        if (msg.sender != address(this)) {
            revert OrderRouter__Unauthorized();
        }
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            revert ICfdEngineTypes.CfdEngine__NoPositionToLiquidate();
        }
        uint256 executionPrice = side == CfdTypes.Side.BULL ? bullPrice : bearPrice;
        return _executeLiquidationAtPrice(account, executionPrice, publishTime, keeper);
    }

    /// @notice Applies one fully atomic liquidation after oracle resolution.
    function _executeLiquidationAtPrice(
        address account,
        uint256 executionPrice,
        uint64 publishTime,
        address keeper
    ) internal returns (uint256 keeperBountyUsdc) {
        _forfeitReservedOrderBountiesOnLiquidation(account);
        uint256 housePoolDepth = housePool.totalAssets();
        keeperBountyUsdc = engine.liquidatePosition(account, executionPrice, housePoolDepth, publishTime, keeper);

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

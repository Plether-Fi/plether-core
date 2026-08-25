// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderLiquidationHandler
/// @notice Prices and executes account liquidation, forfeits queued bounties, and clears the account's live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

    /// @notice Liquidates an account with an adverse oracle snapshot and current HousePool depth.
    /// @dev Refunds cutoff-invalid opens first, then forfeits every remaining queued execution bounty before calling
    ///      the engine. The engine receives `msg.sender` as liquidation keeper. If the refund restores solvency, the
    ///      refund remains committed and liquidation stops. After successful liquidation, all remaining account orders
    ///      are failed and unlinked; any oracle or downstream revert rolls the whole operation back.
    /// @param account Canonical account to liquidate.
    /// @param pythUpdateData Pyth update blobs funded by the call's `msg.value`.
    function _executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) internal {
        uint64 riskOffCutoff = _riskOffOrderCutoff();
        OracleUpdateResult memory update = _prepareLiquidationOracle(account, pythUpdateData);
        _executeLiquidationAtPrice(account, update.executionPrice, update.oraclePublishTime, msg.sender, riskOffCutoff);
    }

    /// @notice Processes one batch account inside its own rollback frame.
    /// @dev Callable only by this router through its immutable liquidation-batch sidecar. This function deliberately
    ///      has no reentrancy modifier because the outer public batch call already holds the router's transient guard.
    /// @param account Candidate liquidation account.
    /// @param bullPrice Shared oracle price adverse to BULL positions.
    /// @param bearPrice Shared oracle price adverse to BEAR positions.
    /// @param publishTime Shared oracle publish timestamp.
    /// @param keeper Original external caller credited with any liquidation bounty.
    /// @param riskOffCutoff Inclusive persistent invalidation cutoff cached by the outer batch call.
    /// @return outcome Keeper bounty on liquidation, or `uint256.max` when refunds restored solvency.
    function executeLiquidationBatchItem(
        address account,
        uint256 bullPrice,
        uint256 bearPrice,
        uint64 publishTime,
        address keeper,
        uint64 riskOffCutoff
    ) external returns (uint256 outcome) {
        if (msg.sender != address(this)) {
            revert OrderRouter__Unauthorized();
        }
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            revert ICfdEngineTypes.CfdEngine__NoPositionToLiquidate();
        }
        uint256 executionPrice = side == CfdTypes.Side.BULL ? bullPrice : bearPrice;
        return _executeLiquidationAtPrice(account, executionPrice, publishTime, keeper, riskOffCutoff);
    }

    /// @notice Applies risk-off refunds and, if the account remains eligible, one atomic liquidation after pricing.
    /// @return outcome Keeper bounty on liquidation, or `uint256.max` when refunds restored solvency.
    function _executeLiquidationAtPrice(
        address account,
        uint256 executionPrice,
        uint64 publishTime,
        address keeper,
        uint64 riskOffCutoff
    ) internal returns (uint256 outcome) {
        uint256 refundedOrders = _refundRiskOffAccountOrders(account, riskOffCutoff);
        uint256 housePoolDepth = housePool.totalAssets();
        if (refundedOrders != 0 && !engineLens.isLiquidatableAt(account, executionPrice, housePoolDepth)) {
            return type(uint256).max;
        }
        _forfeitReservedOrderBountiesOnLiquidation(account);
        outcome = engine.liquidatePosition(account, executionPrice, housePoolDepth, publishTime, keeper);
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

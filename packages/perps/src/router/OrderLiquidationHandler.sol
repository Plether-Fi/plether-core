// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterV2ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV2ExecutionHost.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderLiquidationHandler
/// @notice Prices and executes account liquidation, forfeits queued bounties, and clears the account's live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

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
        uint256 neutralMarkPrice,
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
        return _executeLiquidationAtPrice(account, executionPrice, neutralMarkPrice, publishTime, keeper, riskOffCutoff);
    }

    /// @notice Applies risk-off refunds and, if the account remains eligible, one atomic liquidation after pricing.
    /// @return outcome Keeper bounty on liquidation, or `uint256.max` when refunds restored solvency.
    function _executeLiquidationAtPrice(
        address account,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint64 publishTime,
        address keeper,
        uint64 riskOffCutoff
    ) internal returns (uint256 outcome) {
        uint256 refundedOrders = _refundRiskOffAccountOrdersWithReceipts(account, riskOffCutoff, keeper);
        uint256 housePoolDepth = housePool.totalAssets();
        if (refundedOrders != 0 && !engineLens.isLiquidatableAt(account, executionPrice, housePoolDepth)) {
            return type(uint256).max;
        }
        (uint64[] memory orderIds, uint256[] memory orderBountiesUsdc) =
            _forfeitReservedOrderBountiesOnLiquidation(account);
        outcome = engine.liquidatePosition(account, executionPrice, housePoolDepth, publishTime, keeper);
        _clearLiquidatedAccountOrders(
            account, orderIds, orderBountiesUsdc, executionPrice, neutralMarkPrice, housePoolDepth, publishTime, keeper
        );
    }

    /// @notice Refunds every cutoff-invalid open and finalizes one receipt per order before solvency is rechecked.
    function _refundRiskOffAccountOrdersWithReceipts(
        address account,
        uint64 riskOffCutoff,
        address executor
    ) internal returns (uint256 refundedOrders) {
        if (riskOffCutoff == 0) {
            return 0;
        }
        uint64 orderId = accountHeadOrderId[account];
        while (orderId != 0) {
            OrderRecord storage record = orderRecords[orderId];
            uint64 nextOrderId = record.nextAccountOrderId;
            if (_isRiskOffOpen(orderId, record.core.isClose, riskOffCutoff)) {
                _settleRiskOffOrderWithReceipt(orderId, executor);
                ++refundedOrders;
            }
            orderId = nextOrderId;
        }
    }

    /// @notice Releases margin and terminally fails every live order belonging to a liquidated account.
    /// @dev Traverses the account queue using the successor cached before deletion and emits
    ///      `OrderFailed(AccountLiquidated)` for each order. Bounties are expected to have been forfeited first.
    /// @param account Liquidated account whose live queue is cleared.
    function _clearLiquidatedAccountOrders(
        address account,
        uint64[] memory orderIds,
        uint256[] memory orderBountiesUsdc,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 housePoolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) internal {
        bytes32 observedConfigHash = lifecycleBook.currentExecutionConfigHash();
        address protocolTreasury = engine.protocolTreasury();
        uint256 orderCount = orderIds.length;
        for (uint256 i = 0; i < orderCount; ++i) {
            uint64 orderId = orderIds[i];
            (, CfdTypes.Order memory order) = _pendingOrder(orderId);
            if (order.account != account) {
                revert OrderRouter__AccountQueueCorrupt();
            }
            clearinghouse.releaseOrderReservationForTerminalCleanup(orderId);
            emit OrderFailed(orderId, OrderFailReason.AccountLiquidated);
            _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);

            // Solidity zero-initializes fields that are inapplicable to liquidation terminal evidence.
            // slither-disable-next-line uninitialized-local
            IOrderRouterV2ExecutionHost.SettledTerminalInput memory receiptInput;
            receiptInput.orderId = orderId;
            receiptInput.executor = keeper;
            receiptInput.observedConfigHash = observedConfigHash;
            receiptInput.reason = OrderV2Types.TerminalReason.AccountLiquidated;
            receiptInput.executionMode = OrderV2Types.ExecutionMode.None;
            receiptInput.priceSource = OrderV2Types.PriceSource.Liquidation;
            receiptInput.executionPrice = executionPrice;
            receiptInput.neutralMarkPrice = neutralMarkPrice;
            receiptInput.poolDepthUsdc = housePoolDepthUsdc;
            receiptInput.oraclePublishTime = publishTime;
            receiptInput.priceReachedEngine = false;
            receiptInput.bountyUsdc = orderBountiesUsdc[i];
            if (orderBountiesUsdc[i] != 0) {
                receiptInput.bountyRecipient = protocolTreasury;
                receiptInput.bountyDisposition = OrderV2Types.BountyDisposition.Forfeited;
            }
            _recordSettledTerminalReceipt(receiptInput);
        }
    }

}

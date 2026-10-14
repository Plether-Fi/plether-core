// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @dev A separate self-call retains outer risk-off refunds when pledged backing prevents liquidation.
interface IRestoredLiquidationHost {

    function executeRestoredLiquidationItem(
        address account,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 housePoolDepth,
        uint64 publishTime,
        address keeper
    ) external returns (uint256);

}

/// @title OrderLiquidationHandler
/// @notice Executes priced account liquidations, forfeits order/protection bounties, and clears live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

    /// @notice Processes one single-call or batch liquidation account inside its own rollback frame.
    /// @dev Callable only by this Router through its immutable keeper sidecar. This function deliberately has no
    ///      reentrancy modifier because the outer public liquidation call already holds the Router's transient guard.
    /// @param account Candidate liquidation account.
    /// @param longPrice Shared oracle price adverse to LONG positions.
    /// @param shortPrice Shared oracle price adverse to SHORT positions.
    /// @param publishTime Shared oracle publish timestamp.
    /// @param keeper Original external caller credited with any liquidation bounty.
    /// @param riskOffCutoff Inclusive persistent invalidation cutoff cached by the outer batch call.
    /// @return outcome Keeper bounty on liquidation, or `uint256.max` when refunds restored solvency.
    function executeLiquidationBatchItem(
        address account,
        uint256 longPrice,
        uint256 shortPrice,
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
        uint256 executionPrice = side == CfdTypes.Side.LONG ? longPrice : shortPrice;
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
        try IRestoredLiquidationHost(address(this))
            .executeRestoredLiquidationItem(
                account, executionPrice, neutralMarkPrice, housePoolDepth, publishTime, keeper
            ) returns (
            uint256 bounty
        ) {
            return bounty;
        } catch (bytes memory reason) {
            if (reason.length == 4 && bytes4(reason) == OrderRouter__RestoredPledgeMadeSolvent.selector) {
                if (refundedOrders != 0) {
                    return type(uint256).max;
                }
                revert ICfdEngineTypes.CfdEngine__PositionIsSolvent();
            }
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }

    /// @notice Restores source pledge, forfeits free bounty and liquidates in one independently revertible frame.
    /// @dev Only a direct Engine solvent rejection after pledged restoration is translated into the private marker.
    function executeRestoredLiquidationItem(
        address account,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 housePoolDepth,
        uint64 publishTime,
        address keeper
    ) external returns (uint256 outcome) {
        if (msg.sender != address(this)) {
            revert OrderRouter__Unauthorized();
        }
        (uint64[] memory orderIds, uint256[] memory orderBountiesUsdc, uint256[] memory pledgeRefundsUsdc) =
            _forfeitReservedOrderBountiesOnLiquidation(account);
        bool restoredPledge;
        for (uint256 i; i < pledgeRefundsUsdc.length; ++i) {
            if (pledgeRefundsUsdc[i] != 0) {
                restoredPledge = true;
            }
        }
        try engine.liquidatePosition(account, executionPrice, housePoolDepth, publishTime, keeper) returns (
            uint256 bounty
        ) {
            outcome = bounty;
        } catch (bytes memory reason) {
            if (
                restoredPledge && reason.length == 4
                    && bytes4(reason) == ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector
            ) {
                revert OrderRouter__RestoredPledgeMadeSolvent();
            }
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        _clearLiquidatedAccountOrders(
            account,
            orderIds,
            orderBountiesUsdc,
            pledgeRefundsUsdc,
            executionPrice,
            neutralMarkPrice,
            housePoolDepth,
            publishTime,
            keeper
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
    /// @dev Uses the order ids and bounty amounts snapshotted during forfeiture, emits
    ///      `OrderFailed(AccountLiquidated)`, and finalizes a canonical receipt for each order.
    /// @param account Liquidated account whose live queue is cleared.
    function _clearLiquidatedAccountOrders(
        address account,
        uint64[] memory orderIds,
        uint256[] memory orderBountiesUsdc,
        uint256[] memory pledgeRefundsUsdc,
        uint256 executionPrice,
        uint256 neutralMarkPrice,
        uint256 housePoolDepthUsdc,
        uint64 publishTime,
        address keeper
    ) internal {
        bytes32 observedConfigHash = lifecycleBook.currentExecutionConfigHash();
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
            IOrderRouterExecutionHost.SettledTerminalInput memory receiptInput;
            receiptInput.orderId = orderId;
            receiptInput.executor = keeper;
            receiptInput.observedConfigHash = observedConfigHash;
            receiptInput.reason = OrderV3Types.TerminalReason.AccountLiquidated;
            receiptInput.executionMode = OrderV3Types.ExecutionMode.None;
            receiptInput.priceSource = OrderV3Types.PriceSource.Liquidation;
            receiptInput.executionPrice = executionPrice;
            receiptInput.neutralMarkPrice = neutralMarkPrice;
            receiptInput.poolDepthUsdc = housePoolDepthUsdc;
            receiptInput.oraclePublishTime = publishTime;
            receiptInput.priceReachedEngine = false;
            _setLiquidationBountyReceipt(receiptInput, orderBountiesUsdc[i], pledgeRefundsUsdc[i], order.account);
            _recordSettledTerminalReceipt(receiptInput);
        }
    }

    function _setLiquidationBountyReceipt(
        IOrderRouterExecutionHost.SettledTerminalInput memory receiptInput,
        uint256 bountyUsdc,
        uint256 refundedUsdc,
        address account
    ) private view {
        receiptInput.bountyUsdc = bountyUsdc;
        receiptInput.bountyRefundedUsdc = refundedUsdc;
        if (bountyUsdc == 0) {
            return;
        }
        bool fullyRefunded = refundedUsdc == bountyUsdc;
        receiptInput.bountyRecipient = fullyRefunded ? account : engine.protocolTreasury();
        receiptInput.bountyDisposition = fullyRefunded
            ? OrderV3Types.BountyDisposition.RefundedToAccount
            : (refundedUsdc == 0
                    ? OrderV3Types.BountyDisposition.Forfeited
                    : OrderV3Types.BountyDisposition.ForfeitedAndRefunded);
    }

}

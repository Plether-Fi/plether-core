// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "../interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "../interfaces/IPletherOracle.sol";
import {OrderValidation} from "./OrderValidation.sol";

/// @notice Internal action handler for the delayed-order router.
abstract contract OrderHandler is OrderValidation {

    function _commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) internal {
        if (!isClose) {
            _validateOpenCommitAllowed();
        }
        _validateBaseCommit(sizeDelta, marginDelta, isClose);

        address account = msg.sender;
        uint256 executionBountyUsdc = isClose
            ? _validatedCloseExecutionBountyUsdc(account, side, sizeDelta)
            : _validatedOpenExecutionBountyUsdc(account, side, sizeDelta, marginDelta);

        uint64 orderId = nextCommitId++;

        _reserveExecutionBounty(account, orderId, sizeDelta, executionBountyUsdc, isClose);
        _reserveCommittedMargin(account, orderId, isClose, marginDelta);

        OrderRecord storage record = orderRecords[orderId];
        record.core = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: orderId,
            side: side,
            isClose: isClose
        });
        record.status = IOrderRouterAccounting.OrderStatus.Pending;
        if (isClose) {
            pendingCloseSize[account] += sizeDelta;
        }
        _linkGlobalOrder(orderId);
        _linkAccountOrder(account, orderId);
        if (++pendingOrderCounts[account] > maxPendingOrders) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(7);
        }
        emit OrderCommitted(orderId, account, side);
    }

    function _syncMarginQueue(
        address account
    ) internal {
        _onlyEngine();
        _pruneMarginQueue(account);
    }

    function _getPendingOrderView(
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        OrderRecord storage record = orderRecords[orderId];
        CfdTypes.Order memory order = record.core;
        pending = IOrderRouterAccounting.PendingOrderView({
            orderId: orderId,
            isClose: order.isClose,
            side: order.side,
            sizeDelta: order.sizeDelta,
            marginDelta: order.marginDelta,
            targetPrice: order.targetPrice,
            commitTime: order.commitTime,
            commitBlock: order.commitBlock,
            committedMarginUsdc: clearinghouse.getOrderReservation(orderId).remainingAmountUsdc,
            executionBountyUsdc: record.executionBountyUsdc
        });
        nextAccountOrderId = record.nextAccountOrderId;
    }

    function _executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) internal {
        if (nextExecuteId == 0) {
            revert IOrderRouterErrors.OrderRouter__QueueState(0);
        }
        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData);

        _skipStaleOrders(orderId, update.executionPrice, update.oraclePublishTime);
        if (nextExecuteId == 0) {
            revert IOrderRouterErrors.OrderRouter__QueueState(0);
        }
        if (orderId < nextExecuteId) {
            orderId = nextExecuteId;
        }
        if (orderId != nextExecuteId) {
            revert IOrderRouterErrors.OrderRouter__QueueState(1);
        }
        (, CfdTypes.Order memory order) = _pendingOrder(orderId);

        _executePendingOrder(orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, true);
        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) internal {
        _validateBatchBounds(maxOrderId);

        (OracleUpdateResult memory update, RouterExecutionContext memory executionContext) =
            _prepareOrderExecutionOracle(pythUpdateData);
        uint256 expiredPrunes;

        while (nextExecuteId != 0 && nextExecuteId <= maxOrderId) {
            uint64 orderId = nextExecuteId;
            OrderRecord storage record = _orderRecord(orderId);
            CfdTypes.Order memory order = record.core;

            if (record.status != IOrderRouterAccounting.OrderStatus.Pending) {
                nextExecuteId = record.nextGlobalOrderId;
                continue;
            }

            if (maxOrderAge > 0 && block.timestamp - order.commitTime > maxOrderAge) {
                if (expiredPrunes >= maxPruneOrdersPerCall) {
                    break;
                }
                emit OrderFailed(orderId, OrderFailReason.Expired);
                _cleanupOrder(
                    orderId, _failedOutcomeForTerminalFailure(order), update.executionPrice, update.oraclePublishTime
                );
                expiredPrunes++;
                continue;
            }

            OrderExecutionStepResult result = _executePendingOrder(
                orderId, order, update.executionPrice, update.oraclePublishTime, executionContext, false
            );
            if (result == OrderExecutionStepResult.Break) {
                break;
            }
        }

        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) internal {
        _onlyAdmin();
        maxOrderAge = config.maxOrderAge;
        pletherOracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: config.orderExecutionStalenessLimit,
                liquidationStalenessLimit: config.liquidationStalenessLimit,
                pythMaxConfidenceRatioBps: config.pythMaxConfidenceRatioBps
            })
        );
        openOrderExecutionBountyBps = config.openOrderExecutionBountyBps;
        minOpenOrderExecutionBountyUsdc = config.minOpenOrderExecutionBountyUsdc;
        maxOpenOrderExecutionBountyUsdc = config.maxOpenOrderExecutionBountyUsdc;
        closeOrderExecutionBountyUsdc = config.closeOrderExecutionBountyUsdc;
        maxPendingOrders = config.maxPendingOrders;
        minEngineGas = config.minEngineGas;
        maxPruneOrdersPerCall = config.maxPruneOrdersPerCall;
    }

    function _updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareMarkRefreshOracle(pythUpdateData);
        _sendEth(msg.sender, msg.value - update.pythFee);
    }

    function _executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) internal {
        OracleUpdateResult memory update = _prepareLiquidationOracle(pythUpdateData);

        _forfeitEscrowedOrderBountiesOnLiquidation(account);
        uint256 housePoolDepth = housePool.totalAssets();
        uint256 keeperBountyUsdc =
            engine.liquidatePosition(account, update.executionPrice, housePoolDepth, update.oraclePublishTime);

        _clearLiquidatedAccountOrders(account);
        _creditOrDeferLiquidationBounty(keeperBountyUsdc, update.executionPrice, update.oraclePublishTime);

        _sendEth(msg.sender, msg.value - update.pythFee);
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

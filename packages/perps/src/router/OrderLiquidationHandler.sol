// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderValidation} from "@plether/perps/router/OrderValidation.sol";

/// @title OrderLiquidationHandler
/// @notice Prices and executes account liquidation, forfeits queued bounties, and clears the account's live orders.
abstract contract OrderLiquidationHandler is OrderValidation {

    /// @notice Hard candidate-list bound; transaction gas can stop a batch before all 256 accounts are attempted.
    uint256 internal constant MAX_LIQUIDATION_BATCH_ACCOUNTS = 256;
    /// @notice Fixed item budget above `minEngineGas` for router dispatch and account-level bounty accounting.
    /// @dev This is a call cap, not prepaid consumption: unused self-call gas returns to the outer batch frame.
    uint256 internal constant LIQUIDATION_BATCH_ROUTER_GAS = 200_000;
    /// @notice Item budget for each live order's bounty scan plus terminal reservation and queue cleanup.
    uint256 internal constant LIQUIDATION_BATCH_GAS_PER_ORDER = 150_000;
    /// @notice Gas retained by the batch frame for failure classification, events, and a clean return.
    /// @dev At the configured maxima (`minEngineGas <= 5m`, pending orders <= 32), `itemGas` is at most 10m.
    ///      Its EIP-150 forwarding headroom is below 159k, leaving more than 91k of this tail for call setup while
    ///      preserving the outer frame's ability to catch an item failure and return the resume cursor.
    uint256 internal constant LIQUIDATION_BATCH_TAIL_GAS = 250_000;

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
        _executeLiquidationAtPrice(account, update.executionPrice, update.oraclePublishTime, msg.sender);
    }

    /// @notice Updates Pyth and the neutral engine mark once, then independently attempts each supplied account.
    /// @dev Every account is dispatched through an external self-call so a caught revert restores that account's
    ///      bounty-forfeiture, engine, clearinghouse, pool, and queue mutations without reverting earlier successes.
    ///      The function stops before dispatch when it cannot preserve both a useful item budget and the batch gas tail.
    ///      Each item receives `minEngineGas + 200k + (pendingOrderCount * 150k)` as a maximum; unused gas is returned.
    ///      An empty-data item revert is conservatively treated as possible out-of-gas and leaves its index unattempted.
    ///      To resume, the keeper submits the suffix beginning at the returned index with a fresh oracle update.
    /// @param accounts Candidate accounts to liquidate.
    /// @param pythUpdateData Pyth update blobs funded once by the call's `msg.value`.
    /// @param keeper Original external caller credited with successful liquidation bounties.
    /// @return nextIndex First unattempted index, or `accounts.length` when every account was attempted.
    function _executeLiquidationBatch(
        address[] calldata accounts,
        bytes[] calldata pythUpdateData,
        address keeper
    ) internal returns (uint256 nextIndex) {
        uint256 accountCount = accounts.length;
        if (accountCount == 0 || accountCount > MAX_LIQUIDATION_BATCH_ACCOUNTS) {
            revert OrderRouter__InvalidLiquidationBatchSize();
        }

        IPletherOracle.LiquidationBatchSnapshot memory snapshot =
            pletherOracle.updateLiquidationBatchPrice{value: msg.value}(keeper, pythUpdateData);
        engine.updateMarkPrice(snapshot.markPrice, snapshot.publishTime);

        while (nextIndex < accountCount) {
            address account = accounts[nextIndex];
            uint256 itemGas = minEngineGas + LIQUIDATION_BATCH_ROUTER_GAS
                + (pendingOrderCounts[account] * LIQUIDATION_BATCH_GAS_PER_ORDER);

            uint256 remainingGas = gasleft();
            if (remainingGas <= itemGas + LIQUIDATION_BATCH_TAIL_GAS) {
                emit LiquidationBatchStopped(nextIndex);
                return nextIndex;
            }

            try this.executeLiquidationBatchItem{gas: itemGas}(
                account, snapshot.bullPrice, snapshot.bearPrice, snapshot.publishTime, keeper
            ) returns (
                uint256 keeperBountyUsdc
            ) {
                emit LiquidationBatchItem(
                    nextIndex, account, LiquidationBatchResult.Liquidated, keeperBountyUsdc, bytes4(0)
                );
            } catch (bytes memory revertData) {
                if (revertData.length == 0) {
                    emit LiquidationBatchStopped(nextIndex);
                    return nextIndex;
                }
                bytes4 selector = revertData.length >= 4 ? bytes4(revertData) : bytes4(0);
                emit LiquidationBatchItem(nextIndex, account, _liquidationBatchResult(selector), 0, selector);
            }

            unchecked {
                ++nextIndex;
            }
        }
    }

    /// @notice Processes one batch account inside its own rollback frame.
    /// @dev Callable only by this router through `_executeLiquidationBatch`. This function deliberately has no
    ///      reentrancy modifier because the outer public batch call already holds the router's transient guard.
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

    function _liquidationBatchResult(
        bytes4 selector
    ) internal pure returns (LiquidationBatchResult result) {
        if (selector == ICfdEngineTypes.CfdEngine__NoPositionToLiquidate.selector) {
            return LiquidationBatchResult.SkippedNoPosition;
        }
        if (selector == ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector) {
            return LiquidationBatchResult.SkippedSolvent;
        }
        return LiquidationBatchResult.Failed;
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";
import {OrderHandler} from "@plether/perps/router/OrderHandler.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages delayed order commits, MEV protection, and the un-brickable FIFO queue.
/// @dev Does not custody trader collateral or bounty reserves; queued value remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, OrderHandler, ReentrancyGuardTransient {

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _engineLens CfdEngineLens used for commit-time open validation previews
    /// @param _housePool HousePool used for depth queries and liquidation bounty payouts
    /// @param _pletherOracle Deployed perps oracle used for Pyth basket pricing
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle
    ) OrderRouterBase(_engine, _engineLens, _housePool, _pletherOracle) {}

    /// @notice Submits a trade intent to the FIFO queue.
    ///         Margin and the order's execution bounty are reserved immediately.
    /// @param side BULL or BEAR
    /// @param sizeDelta Position size change (18 decimals)
    /// @param marginDelta Margin to add or remove (6 decimals, USDC)
    /// @param targetPrice Slippage limit price (8 decimals, 0 = market order)
    /// @param isClose True to allow execution even when paused or in FAD close-only mode
    function commitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice,
        bool isClose
    ) external nonReentrant {
        _commitOrder(side, sizeDelta, marginDelta, targetPrice, isClose);
    }

    /// @notice Prunes spent margin-reservation links for an account's pending-order queue.
    /// @param account Account whose router-side margin reservation queue should be synchronized
    function syncMarginQueue(
        address account
    ) external {
        _syncMarginQueue(account);
    }

    /// @notice Returns the pending-order view and next account-queue link for an order id.
    /// @param orderId Order id to inspect
    /// @return pending Pending order data, or an empty view when the order is not pending
    /// @return nextAccountOrderId Next order id in the account queue, or zero at the tail
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        return _getPendingOrderView(orderId);
    }

    /// @notice Keeper executes the current global queue head.
    /// @dev Validates oracle freshness, publish-time ordering, and slippage, then delegates to the
    ///      engine. Invalid, expired, or out-of-slippage orders are finalized from clearinghouse-reserved
    ///      execution bounty reservation; the router does not maintain a retry/requeue lane.
    /// @param orderId Must equal the current global queue head (expired orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrder(orderId, pythUpdateData);
    }

    /// @notice Executes queued pending orders against strictly post-commit Pyth historical prices.
    ///         Reuses a parsed historical basket when later FIFO orders are covered by the same tick,
    ///         aggregates reserved USDC execution bounties, and refunds excess ETH in a single transfer.
    /// @param maxOrderId Inclusive upper bound on committed order ids the batch may begin processing from
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrderBatch(maxOrderId, pythUpdateData);
    }

    /// @notice Applies a finalized router risk and queue configuration.
    /// @dev Callable only by the configured router admin.
    /// @param config Timelocked router configuration to apply
    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external nonReentrant {
        _applyRouterConfig(config);
    }

    /// @notice Applies a finalized oracle integration configuration.
    /// @dev Callable only by the configured router admin.
    /// @param config Timelocked oracle configuration to apply
    function applyOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) external nonReentrant {
        _applyOracleConfig(config);
    }

    /// @notice Push a fresh mark price to the engine without processing an order.
    ///         Required before LP deposits/withdrawals when mark is stale.
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _updateMarkPrice(pythUpdateData);
    }

    /// @notice Keeper-triggered liquidation using the canonical live-market staleness policy.
    ///         Forfeits any queued-order execution reservation to the HousePool instead of crediting it back to trader settlement,
    ///         then credits the liquidation keeper directly through the clearinghouse.
    /// @param account The account to liquidate
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeLiquidation(account, pythUpdateData);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {IOrderRouterAccounting} from "./interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "./interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "./interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "./interfaces/IPerpsTraderActions.sol";
import {OrderHandler} from "./modules/OrderHandler.sol";
import {OrderRouterBase} from "./modules/OrderRouterBase.sol";

/// @title OrderRouter (The MEV Shield)
/// @notice Manages Commit-Reveal, MEV protection, and the un-brickable FIFO queue.
/// @dev Holds only non-trader-owned keeper execution reserves. Trader collateral remains in MarginClearinghouse.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, OrderHandler {

    error OrderRouter__ZeroSize();
    error OrderRouter__OracleValidation(uint8 code);
    error OrderRouter__QueueState(uint8 code);
    error OrderRouter__CommitValidation(uint8 code);
    error OrderRouter__InsufficientGas();
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _housePool HousePool used for depth queries and forfeited-escrow accounting
    /// @param _pyth Pyth oracle contract (address(0) enables mock mode on Anvil)
    /// @param _feedIds Pyth price feed IDs for each basket component
    /// @param _quantities Weight of each component (must sum to 1e18)
    /// @param _basePrices Base price per component for normalization (8 decimals)
    /// @param _inversions Whether to invert each feed (e.g. USD/JPY -> JPY/USD)
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderRouterBase(_engine, _engineLens, _housePool, _pyth, _feedIds, _quantities, _basePrices, _inversions) {}

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
    ) external {
        _commitOrder(side, sizeDelta, marginDelta, targetPrice, isClose);
    }

    /// @notice Returns the total queued escrow state for an account across all pending orders.
    function syncMarginQueue(
        address account
    ) external {
        _syncMarginQueue(account);
    }

    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        return _getPendingOrderView(orderId);
    }

    /// @notice Keeper executes the current global queue head.
    /// @dev Validates oracle freshness, publish-time ordering, and slippage, then delegates to the
    ///      engine. Invalid, expired, or out-of-slippage orders are finalized from router-custodied
    ///      execution bounty escrow; the router does not maintain a retry/requeue lane.
    /// @param orderId Must equal the current global queue head (expired orders are auto-skipped)
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        _executeOrder(orderId, pythUpdateData);
    }

    /// @notice Executes queued pending orders against a single Pyth price tick.
    ///         Updates Pyth once, then loops through the FIFO queue. Aggregates reserved USDC
    ///         execution bounties across processed orders and refunds excess ETH in a single transfer.
    /// @param maxOrderId Inclusive upper bound on committed order ids the batch may begin processing from
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable {
        _executeOrderBatch(maxOrderId, pythUpdateData);
    }

    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external {
        _applyRouterConfig(config);
    }

    /// @notice Push a fresh mark price to the engine without processing an order.
    ///         Required before LP deposits/withdrawals when mark is stale.
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable {
        _updateMarkPrice(pythUpdateData);
    }

    /// @notice Keeper-triggered liquidation using the canonical live-market staleness policy.
    ///         Forfeits any queued-order execution escrow to the HousePool instead of crediting it back to trader settlement,
    ///         then asks the engine to service or defer the liquidation keeper bounty.
    /// @param account The account to liquidate
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable {
        _executeLiquidation(account, pythUpdateData);
    }

}

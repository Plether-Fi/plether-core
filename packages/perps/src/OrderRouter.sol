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
/// @notice Queues delayed perps orders and permissionlessly executes them in global FIFO order using Pyth prices.
/// @dev Does not custody trader collateral or USDC bounty reserves; queued value remains in MarginClearinghouse.
///      A dedicated `OrderRouterAdmin` deployed by the base contract timelocks configuration and gates new
///      risk-increasing commits during an emergency pause. Close commits, execution, mark refresh, and
///      liquidation remain available while that admin is paused.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, OrderHandler, ReentrancyGuardTransient {

    /// @notice Deploys the router and its owner-controlled timelocked admin.
    /// @dev The admin owner is the constructor caller. Integration addresses are validated by the inherited
    ///      constructors as described there; the router is not upgradeable.
    /// @param _engine CfdEngine that processes trades and liquidations.
    /// @param _engineLens CfdEngineLens used for commit-time open validation previews.
    /// @param _housePool HousePool used for depth and risk-availability queries.
    /// @param _pletherOracle Deployed Plether oracle used for Pyth basket pricing.
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle
    ) OrderRouterBase(_engine, _engineLens, _housePool, _pletherOracle) {}

    /// @notice Submits an open/increase or strict reduce-only intent to the delayed global FIFO queue.
    /// @dev Reserves committed margin and the keeper bounty in the clearinghouse immediately. Opens are
    ///      blocked while paused, degraded, close-only, or unable to increase pool risk and may be rejected
    ///      by a fresh-mark preflight. Closes remain committable in those modes but must match and not exceed
    ///      the position obtained after applying the account's earlier queued orders. The caller is the account.
    /// @param side Direction to open/increase, or the direction of the queued position being closed.
    /// @param sizeDelta Position-size change in synthetic-token units (18 decimals); must be nonzero.
    /// @param marginDelta Margin to reserve for an open/increase (6-decimal USDC); must be zero for a close.
    /// @param targetPrice Direction-aware slippage limit (8 decimals), or zero for no price limit.
    /// @param isClose True for a strict position reduction and false for an open/increase.
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
    /// @dev Callable only by the engine or its current settlement sidecar. This changes router linkage only;
    ///      the clearinghouse remains the source of truth for reserved value.
    /// @param account Account whose router-side margin reservation queue should be synchronized.
    function syncMarginQueue(
        address account
    ) external {
        _syncMarginQueue(account);
    }

    /// @notice Returns the pending-order view and next account-queue link for an order id.
    /// @dev The returned core fields are populated from the retained order record even after terminal execution;
    ///      callers should traverse only live account-queue ids when they require pending-only data.
    /// @param orderId Order id to inspect.
    /// @return pending Order data plus current clearinghouse margin and router bounty reservation.
    /// @return nextAccountOrderId Next order id in the live account queue, or zero at the tail.
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        return _getPendingOrderView(orderId);
    }

    /// @notice Permissionlessly executes an eligible global queue head and pays its reserved USDC bounty.
    /// @dev Prunes expired heads up to the requested id before oracle work, subject to the configured prune cap.
    ///      It then enforces FIFO, post-commit timing outside frozen-oracle mode, staleness, slippage, and a
    ///      minimum engine-call gas reserve. Expired, slippage-failed, and engine failures other than
    ///      mark-price-out-of-order—including business-rule rejections and panics—are terminal: committed margin is
    ///      released and their bounty is still credited to the caller. Mark-price-out-of-order instead reverts
    ///      nonterminally and leaves the order pending. Excess ETH is refunded, or recorded in the admin contract
    ///      if the transfer fails. Terminal failures have no retry lane.
    /// @param orderId Queue-head id to execute, or a later committed id used as the expired-head pruning bound.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover all Pyth fees used by the call.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrder(orderId, pythUpdateData);
    }

    /// @notice Permissionlessly processes consecutive FIFO orders through a committed inclusive id bound.
    /// @dev Uses strictly post-commit historical Pyth prices outside frozen-oracle mode and may reuse a proven
    ///      basket for later compatible orders. It terminally cleans expired, slippage-failed, and engine failures
    ///      other than mark-price-out-of-order, but stops at an open blocked by close-only policy, an MEV timing
    ///      boundary, insufficient gas, the prune cap, or unavailable historical data after prior progress.
    ///      Mark-price-out-of-order reverts the whole batch and leaves its state unchanged. Reserved USDC bounties
    ///      accrue to the caller; unused ETH is refunded once or deferred to the admin on transfer failure.
    /// @param maxOrderId Last committed order id the batch may process; must be at or after the head and below `nextCommitId`.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the cumulative Pyth fees used.
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrderBatch(maxOrderId, pythUpdateData);
    }

    /// @notice Applies a finalized router risk and queue configuration.
    /// @dev Callable only by this router's deployed admin. Also forwards oracle-policy fields to the
    ///      currently configured Plether oracle.
    /// @param config Timelocked router, bounty, oracle-policy, gas, and queue configuration to apply.
    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external nonReentrant {
        _applyRouterConfig(config);
    }

    /// @notice Applies a finalized oracle integration configuration.
    /// @dev Callable only by this router's deployed admin. The new oracle must be deployed, expose a nonzero
    ///      Pyth contract, and be wired to this router's engine and HousePool.
    /// @param config Timelocked oracle-address configuration to apply.
    function applyOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) external nonReentrant {
        _applyOracleConfig(config);
    }

    /// @notice Applies a mark-refresh oracle update and pushes its mark price to the engine.
    /// @dev Permissionless and available while the router admin is paused. The oracle handles the Pyth fee
    ///      and refunds unused ETH to the caller.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _updateMarkPrice(pythUpdateData);
    }

    /// @notice Permissionlessly liquidates an unsafe account using an account-adverse oracle price.
    /// @dev Available while paused. Before liquidation, all reserved bounties on the account's queued orders
    ///      are forfeited through the engine. On success every queued order is failed, its committed margin is
    ///      released, and its queue links are removed. The oracle handles Pyth fees and ETH refunds.
    /// @param account Canonical account to liquidate.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeLiquidation(account, pythUpdateData);
    }

}

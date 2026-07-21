// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {OrderExecutionOrchestrator} from "@plether/perps/router/OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";

/// @title OrderRouterBase
/// @notice Owns shared router configuration, deploys its admin, and implements engine/admin integration hooks.
abstract contract OrderRouterBase is IOrderRouterAdminHost, OrderExecutionOrchestrator {

    /// @notice Dedicated timelocked `OrderRouterAdmin` deployed with ownership assigned to the router deployer.
    address public immutable admin;

    /// @notice Minimum open/increase notional accepted at commit time (6-decimal USDC).
    uint256 public minOpenNotionalUsdc;
    /// @notice Variable open-order keeper-bounty rate in basis points.
    uint256 public openOrderExecutionBountyBps;
    /// @notice Minimum open-order keeper bounty (6-decimal USDC).
    uint256 public minOpenOrderExecutionBountyUsdc;
    /// @notice Maximum open-order keeper bounty (6-decimal USDC).
    uint256 public maxOpenOrderExecutionBountyUsdc;
    /// @notice Fixed close-order keeper bounty (6-decimal USDC).
    uint256 public closeOrderExecutionBountyUsdc;

    /// @notice Initializes oracle/accounting integrations, deploys the admin, and installs router defaults.
    /// @dev Defaults are: $100 minimum open notional, 1 bp open bounty with $0.01/$0.20 floor/cap,
    ///      $0.20 close bounty, 600,000 minimum engine gas, and 64 expired-order prunes per call.
    /// @param _engine CfdEngine that processes trades and liquidations.
    /// @param _engineLens CfdEngineLens used for open-order commit preflight.
    /// @param _housePool HousePool used for depth and risk-availability queries.
    /// @param _pletherOracle Deployed Plether oracle used for Pyth basket pricing.
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle
    ) OrderOracleExecution(_engine, _engineLens, _housePool, _pletherOracle) {
        admin = address(new OrderRouterAdmin(address(this), msg.sender));
        minOpenNotionalUsdc = 100_000_000;
        openOrderExecutionBountyBps = 1;
        minOpenOrderExecutionBountyUsdc = 10_000;
        maxOpenOrderExecutionBountyUsdc = 200_000;
        closeOrderExecutionBountyUsdc = 200_000;
        minEngineGas = 600_000;
        maxPruneOrdersPerCall = 64;
    }

    /// @notice Restricts an internal entry path to the engine or its current settlement sidecar.
    function _onlyEngine() internal view {
        if (msg.sender != address(engine) && msg.sender != address(engine.settlementSidecar())) {
            revert OrderRouter__Unauthorized();
        }
    }

    /// @notice Restricts an internal configuration path to the deployed router admin.
    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert OrderRouter__Unauthorized();
        }
    }

    /// @notice Releases any active committed-margin reservation immediately before engine execution.
    /// @param orderId Order whose reservation is released.
    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal override {
        _releaseCommittedMargin(orderId);
    }

    /// @notice Delegates close-bounty reservation and solvency checks to the engine.
    /// @dev Any engine revert is normalized to `OrderRouter__InsufficientFreeEquity`.
    /// @param account Account funding the close bounty.
    /// @param sizeDelta Close size used by engine validation (18 decimals).
    /// @param executionBountyUsdc Fixed bounty to reserve (6-decimal USDC).
    function _reserveCloseExecutionBounty(
        address account,
        uint256 sizeDelta,
        uint256 executionBountyUsdc
    ) internal override {
        try engine.reserveCloseOrderExecutionBounty(account, sizeDelta, executionBountyUsdc) {
            return;
        } catch {
            revert OrderRouter__InsufficientFreeEquity();
        }
    }

    /// @notice Unlinks an order from every live queue, records terminal status, and updates account aggregates.
    /// @dev Decrements counts defensively only when positive. Pending close size is decremented only when its
    ///      stored aggregate is at least the order size. Core order data and terminal status remain in the record;
    ///      live queue links and the separately collected or forfeited unpaid bounty are cleared.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus Terminal `Executed` or `Failed` status.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal override {
        OrderRecord storage record = _orderRecord(orderId);
        address account = record.core.account;
        if (account != address(0)) {
            _unlinkAccountOrder(account, orderId);
            _unlinkMarginOrder(account, orderId);
        }
        _unlinkGlobalOrder(orderId);
        record.status = terminalStatus;
        if (account != address(0) && pendingOrderCounts[account] > 0) {
            pendingOrderCounts[account]--;
        }
        if (account != address(0) && record.core.isClose && pendingCloseSize[account] >= record.core.sizeDelta) {
            pendingCloseSize[account] -= record.core.sizeDelta;
        }
    }

}

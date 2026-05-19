// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {OrderRouterAdmin} from "../OrderRouterAdmin.sol";
import {IOrderRouter} from "../interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "../interfaces/IOrderRouterAdminHost.sol";
import {OrderExecutionOrchestrator} from "./OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "./OrderOracleExecution.sol";

/// @notice Shared router storage and integration hooks for the delayed-order router stack.
abstract contract OrderRouterBase is IOrderRouterAdminHost, OrderExecutionOrchestrator {

    address public immutable admin;

    uint256 public minOpenNotionalUsdc;
    uint256 public openOrderExecutionBountyBps;
    uint256 public minOpenOrderExecutionBountyUsdc;
    uint256 public maxOpenOrderExecutionBountyUsdc;
    uint256 public closeOrderExecutionBountyUsdc;

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _housePool HousePool used for depth queries and liquidation bounty payouts
    /// @param _pletherOracle Deployed perps oracle used for Pyth basket pricing
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

    function _onlyEngine() internal view {
        if (msg.sender != address(engine) && msg.sender != address(engine.settlementSidecar())) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert OrderRouter__Unauthorized();
        }
    }

    function _releaseCommittedMarginForExecution(
        uint64 orderId
    ) internal override {
        _releaseCommittedMargin(orderId);
    }

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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {OrderRouterAdmin} from "../OrderRouterAdmin.sol";
import {IOrderRouterAccounting} from "../interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "../interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "../interfaces/IOrderRouterErrors.sol";
import {OrderExecutionOrchestrator} from "./OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "./OrderOracleExecution.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Shared storage and abstract-hook implementations for the delayed-order router stack.
abstract contract OrderRouterBase is IOrderRouterAdminHost, OrderExecutionOrchestrator {

    using SafeERC20 for IERC20;

    uint64 public nextCommitId = 1;
    uint64 public nextExecuteId = 1;
    address public immutable admin;

    uint256 public maxOrderAge;
    uint256 internal constant DEFAULT_MAX_ORDER_AGE = 60;
    uint256 public openOrderExecutionBountyBps;
    uint256 public minOpenOrderExecutionBountyUsdc;
    uint256 public maxOpenOrderExecutionBountyUsdc;
    uint256 public closeOrderExecutionBountyUsdc;
    uint256 public maxPendingOrders;

    uint64 public globalTailOrderId;

    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);

    /// @param _engine CfdEngine that processes trades and liquidations
    /// @param _housePool HousePool used for depth queries and liquidation bounty payouts
    /// @param _pyth Pyth oracle contract
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
    ) OrderOracleExecution(_engine, _engineLens, _housePool, _pyth, _feedIds, _quantities, _basePrices, _inversions) {
        admin = address(new OrderRouterAdmin(address(this), msg.sender));
        maxOrderAge = DEFAULT_MAX_ORDER_AGE;
        openOrderExecutionBountyBps = 1;
        minOpenOrderExecutionBountyUsdc = 10_000;
        maxOpenOrderExecutionBountyUsdc = 200_000;
        closeOrderExecutionBountyUsdc = 200_000;
        maxPendingOrders = 5;
        minEngineGas = 600_000;
        maxPruneOrdersPerCall = 64;
        if (_engine.code.length > 0) {
            USDC.forceApprove(_engine, type(uint256).max);
        }
    }

    function _onlyEngine() internal view {
        if (msg.sender != address(engine) && msg.sender != address(engine.settlementModule())) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(8);
        }
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(8);
        }
    }

    function _queueHeadOrderId() internal view override returns (uint64) {
        return nextExecuteId;
    }

    function _setQueueHeadOrderId(
        uint64 orderId
    ) internal override {
        nextExecuteId = orderId;
    }

    function _queueTailOrderId() internal view override returns (uint64) {
        return globalTailOrderId;
    }

    function _setQueueTailOrderId(
        uint64 orderId
    ) internal override {
        globalTailOrderId = orderId;
    }

    function _maxOrderAge() internal view override returns (uint256) {
        return maxOrderAge;
    }

    function _nextCommitId() internal view override returns (uint64) {
        return nextCommitId;
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
        try engine.reserveCloseOrderExecutionBounty(account, sizeDelta, executionBountyUsdc, address(this)) {}
        catch {
            revert IOrderRouterErrors.OrderRouter__CommitValidation(6);
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

    function _sendEth(
        address to,
        uint256 amount
    ) internal override {
        if (amount > 0) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) {
                OrderRouterAdmin(admin).creditClaimableEth{value: amount}(to, amount);
            }
        }
    }

}

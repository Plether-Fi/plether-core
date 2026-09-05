// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {OrderExecutionOrchestrator} from "@plether/perps/router/OrderExecutionOrchestrator.sol";
import {OrderOracleExecution} from "@plether/perps/router/OrderOracleExecution.sol";

/// @title OrderRouterBase
/// @notice Owns shared router configuration, deploys its admin, and implements engine/admin integration hooks.
abstract contract OrderRouterBase is IOrderRouterAdminHost, OrderExecutionOrchestrator {

    /// @notice Dedicated timelocked `OrderRouterAdmin` deployed with ownership assigned to the router deployer.
    address public immutable admin;

    /// @notice Stateless evaluator that enforces the account's pinned execution policy before settlement is applied.
    address public immutable policyEvaluator;

    /// @notice Predeployed immutable registry for V2 client intents, pending policy, and authenticated receipts.
    OrderLifecycleBook public immutable lifecycleBook;

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
    /// @notice Whether new position-protection creation, replacement, and attached opening orders are enabled.
    bool public positionProtectionCommitsEnabled;
    /// @notice Fixed keeper bounty paid when an armed protection is validly triggered (6-decimal USDC).
    uint256 public positionProtectionTriggerBountyUsdc;

    /// @notice Initializes oracle/accounting integrations, deploys the admin, and installs router defaults.
    /// @dev Defaults are: $100 minimum open notional, 1 bp open bounty with $0.01/$0.20 floor/cap,
    ///      $0.20 close and protection-trigger bounties, protection commits disabled, 600,000 minimum engine gas,
    ///      and 64 expired-order prunes per call.
    /// @param _engine CfdEngine that processes trades and liquidations.
    /// @param _engineLens CfdEngineLens used for open-order commit preflight.
    /// @param _housePool HousePool used for depth and risk-availability queries.
    /// @param _pletherOracle Deployed Plether oracle used for Pyth basket pricing.
    /// @param _policyEvaluator Deployed stateless V2 financial-policy evaluator.
    /// @param _lifecycleBook Predeployed lifecycle Book bound to this predicted Router and protocol stack.
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle,
        address _policyEvaluator,
        address _lifecycleBook
    ) OrderOracleExecution(_engine, _engineLens, _housePool, _pletherOracle) {
        if (_policyEvaluator == address(0) || _policyEvaluator.code.length == 0) {
            revert OrderRouter__InvalidPolicyEvaluator();
        }
        if (_lifecycleBook.code.length == 0) {
            revert OrderRouter__InvalidLifecycleBook();
        }
        OrderLifecycleBook lifecycleBook_ = OrderLifecycleBook(_lifecycleBook);
        if (
            lifecycleBook_.ROUTER() != address(this) || lifecycleBook_.ENGINE() != _engine
                || lifecycleBook_.CLEARINGHOUSE() != address(clearinghouse) || lifecycleBook_.HOUSE_POOL() != _housePool
        ) {
            revert OrderRouter__InvalidLifecycleBook();
        }
        admin = address(new OrderRouterAdmin(address(this), msg.sender));
        policyEvaluator = _policyEvaluator;
        lifecycleBook = lifecycleBook_;
        minOpenNotionalUsdc = 100_000_000;
        openOrderExecutionBountyBps = 1;
        minOpenOrderExecutionBountyUsdc = 10_000;
        maxOpenOrderExecutionBountyUsdc = 200_000;
        closeOrderExecutionBountyUsdc = 200_000;
        positionProtectionCommitsEnabled = false;
        positionProtectionTriggerBountyUsdc = 200_000;
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

    /// @notice Reads the admin's monotonic inclusive open-order invalidation cutoff.
    function _riskOffOrderCutoff() internal view returns (uint64) {
        return OrderRouterAdmin(admin).riskOffOrderCutoff();
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

    /// @notice Unlinks an order from every live queue, deletes its ephemeral record, and updates account aggregates.
    /// @dev Decrements counts defensively only when positive. Pending close size is decremented only when its
    ///      stored aggregate is at least the order size. The lifecycle book is the permanent terminal source of truth.
    /// @param orderId Live order id to delete.
    /// @param terminalStatus Terminal `Executed` or `Failed` status.
    function _deleteOrder(
        uint64 orderId,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual override {
        OrderRecord storage record = _orderRecord(orderId);
        address account = record.core.account;
        if (account != address(0)) {
            _unlinkAccountOrder(account, orderId);
        }
        _unlinkGlobalOrder(orderId);
        record.status = terminalStatus;
        if (account != address(0) && pendingOrderCounts[account] > 0) {
            pendingOrderCounts[account]--;
        }
        if (account != address(0) && record.core.isClose && pendingCloseSize[account] >= record.core.sizeDelta) {
            pendingCloseSize[account] -= record.core.sizeDelta;
        }
        _afterOrderDeleted(orderId, account, terminalStatus);
        delete orderRecords[orderId];
    }

    /// @notice Applies derived-feature lifecycle changes after an ordinary order becomes terminal.
    /// @dev The base implementation is a no-op. It is called after all ordinary queue links and aggregates are updated.
    function _afterOrderDeleted(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal virtual {
        orderId;
        account;
        terminalStatus;
    }

}

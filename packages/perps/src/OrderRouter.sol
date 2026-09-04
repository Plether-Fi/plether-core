// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterV2ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV2ExecutionHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";
import {OrderHandler} from "@plether/perps/router/OrderHandler.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";

/// @notice Binding surface exposed by the Router's predeployed stateless keeper sidecar.
interface IOrderRouterKeeperSidecarBinding {

    function ROUTER() external view returns (address);

}

/// @title OrderRouter (The MEV Shield)
/// @notice Queues delayed perps orders and permissionlessly executes them in global FIFO order using Pyth prices.
/// @dev Does not custody trader collateral or USDC bounty reserves; queued value remains in MarginClearinghouse.
///      A dedicated `OrderRouterAdmin` deployed by the base contract timelocks configuration and gates new
///      risk-increasing commits during an emergency pause. Close commits, execution, mark refresh, and
///      liquidation remain available while that admin is paused.
/// @custom:security-contact contact@plether.com
contract OrderRouter is IPerpsKeeper, IPerpsTraderActions, OrderHandler {

    /// @notice Fixed independently deployed stateless delegate module for V2 order execution and receipts.
    address public immutable executionSidecar;

    /// @notice Fixed stateless delegate module for oracle config, mark refresh, LP settlement, protection triggers,
    ///         and liquidations.
    /// @dev The sidecar is deployed immediately before this Router and constructor-bound to this exact address. Keeping
    ///      its creation payload outside the Router preserves EIP-3860 deployability without trusting storage layout.
    address public immutable liquidationBatchSidecar;

    /// @notice Deploys the router and its owner-controlled timelocked admin.
    /// @dev The admin owner is the constructor caller. Integration addresses are validated by the inherited
    ///      constructors as described there; the router is not upgradeable.
    /// @param _engine CfdEngine that processes trades and liquidations.
    /// @param _engineLens CfdEngineLens used for commit-time open validation previews.
    /// @param _housePool HousePool used for depth and risk-availability queries.
    /// @param _pletherOracle Deployed Plether oracle used for Pyth basket pricing.
    /// @param _keeperSidecar Predeployed stateless keeper logic bound to this Router's address.
    /// @param _policyEvaluator Deployed stateless V2 financial-policy evaluator.
    /// @param _executionSidecar Deployed stateless V2 oracle, execution, and receipt delegate module.
    /// @param _lifecycleBook Predeployed lifecycle Book bound to this predicted Router and protocol stack.
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle,
        address _keeperSidecar,
        address _policyEvaluator,
        address _executionSidecar,
        address _lifecycleBook
    ) OrderRouterBase(_engine, _engineLens, _housePool, _pletherOracle, _policyEvaluator, _lifecycleBook) {
        if (
            _keeperSidecar.code.length == 0
                || IOrderRouterKeeperSidecarBinding(_keeperSidecar).ROUTER() != address(this)
        ) {
            revert OrderRouter__InvalidKeeperSidecar();
        }
        liquidationBatchSidecar = _keeperSidecar;
        if (_executionSidecar == address(0) || _executionSidecar.code.length == 0) {
            revert OrderRouter__InvalidExecutionSidecar();
        }
        executionSidecar = _executionSidecar;
    }

    /// @notice Submits or idempotently resolves a financially bounded V2 delayed-order intent.
    /// @dev `clientOrderId` is permanent within the caller's account namespace. An exact replay returns the
    ///      original order id before consulting current configuration or market state and creates no reservation,
    ///      queue entry, counter increment, or event. A fresh request pins its execution configuration, permitted
    ///      execution modes, absolute deadline, and financial limits in the immutable lifecycle book. The
    ///      `0x504c455448455221` client-id prefix is reserved for protocol-generated protection orders.
    /// @param request Canonical account-scoped V2 order intent and execution bounds.
    /// @return orderId Newly assigned order id or the original id for an exact replay.
    function commitOrder(
        OrderV2Types.OrderRequest calldata request
    ) external nonReentrant returns (uint64 orderId) {
        request;
        return uint64(_delegateToKeeperSidecar());
    }

    /// @notice Typed compatibility host used only by the immutable position-protection Book for an attached open.
    /// @dev The Book forwards the caller-authored bounded request outside Router runtime. This host authenticates the
    ///      Book and explicit account, then uses the canonical public V2 registration and commit policy.
    function commitProtectedOpen(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) external nonReentrant returns (uint64 orderId) {
        account;
        request;
        return uint64(_delegateToKeeperSidecar());
    }

    /// @notice Returns the immutable engine lens to delegated commit validation without exposing storage layout.
    function engineLensForCommit() external view returns (address) {
        return address(engineLens);
    }

    /// @notice Establishes reservations and queues a sidecar-validated, lifecycle-registered order.
    /// @dev The trusted sidecar appends a fixed raw payload to this no-argument selector so Router runtime avoids a
    ///      second large V2 request decoder. The external self-call is the isolated canonical storage mutation frame.
    function executeCommitOrderItem() external {
        _onlySelfCall();
        uint64 orderId;
        address account;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        CfdTypes.Side side;
        uint256 isCloseWord;
        uint256 executionBountyUsdc;
        assembly ("memory-safe") {
            orderId := calldataload(4)
            account := calldataload(36)
            sizeDelta := calldataload(68)
            marginDelta := calldataload(100)
            targetPrice := calldataload(132)
            side := calldataload(164)
            isCloseWord := calldataload(196)
            executionBountyUsdc := calldataload(228)
        }
        if (orderId != nextCommitId) {
            revert OrderRouter__Unauthorized();
        }
        nextCommitId = orderId + 1;
        _createPendingOrder(
            CfdTypes.Order({
                account: account,
                sizeDelta: sizeDelta,
                marginDelta: marginDelta,
                targetPrice: targetPrice,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: orderId,
                side: side,
                isClose: isCloseWord != 0
            }),
            executionBountyUsdc
        );
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
    /// @dev Terminal records are deleted from the Router; permanent identity and outcomes are read from `lifecycleBook`.
    /// @param orderId Order id to inspect.
    /// @return pending Order data plus current clearinghouse margin and router bounty reservation.
    /// @return nextAccountOrderId Next order id in the live account queue, or zero at the tail.
    function getPendingOrderView(
        uint64 orderId
    ) external view returns (IOrderRouterAccounting.PendingOrderView memory pending, uint64 nextAccountOrderId) {
        return _getPendingOrderView(orderId);
    }

    /// @notice Permissionlessly executes or terminally classifies an eligible global queue head.
    /// @dev Risk-off, expiry, and pinned-config mismatch are checked in that order before oracle work. Slippage and
    ///      exact-shape typed planner/policy rejections are terminal and receive canonical receipts. Close-only, MEV,
    ///      insufficient gas, mark ordering, and unknown, panic, empty, or malformed dependency failures leave the
    ///      order pending. Each returned result is machine-readable; terminal state is permanent in `lifecycleBook`.
    /// @param orderId Queue-head id to execute, or a later committed id used as the terminal-head cleanup bound.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover all Pyth fees used by the call.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (OrderV2Types.ExecutionResult memory result) {
        orderId;
        pythUpdateData;
        return abi.decode(_delegateExecutionSidecar(), (OrderV2Types.ExecutionResult));
    }

    /// @notice Permissionlessly processes consecutive FIFO orders through a committed inclusive id bound.
    /// @dev Every prepared item has its own Router rollback frame, so retryable Engine/policy failures or receipt
    ///      failures leave that item pending without undoing earlier terminal items. Oracle/Pyth preparation and the
    ///      Engine mark update remain batch-atomic outside that frame. The result identifies the next live order,
    ///      terminal count, and exact stop class. Unused ETH is refunded once or deferred to the admin.
    /// @param maxOrderId Last committed order id the batch may process; must be at or after the head and below `nextCommitId`.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the cumulative Pyth fees used.
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (OrderV2Types.BatchResult memory result) {
        maxOrderId;
        pythUpdateData;
        return abi.decode(_delegateExecutionSidecar(), (OrderV2Types.BatchResult));
    }

    /// @notice Returns one canonical live record to the immutable execution sidecar.
    /// @dev Restricted to Router self-calls so only a delegate-executing trusted sidecar can consume the host surface.
    function getV2OrderForSidecar(
        uint64 orderId
    ) external view returns (IOrderRouterV2ExecutionHost.OrderView memory orderView) {
        _onlySelfCall();
        OrderRecord storage record = orderRecords[orderId];
        orderView.order = record.core;
        orderView.nextGlobalOrderId = record.nextGlobalOrderId;
        orderView.pending = record.status == IOrderRouterAccounting.OrderStatus.Pending;
    }

    /// @notice Re-enters one V2 item through an independently revertible Router frame.
    /// @dev The outer non-reentrant entrypoint remains active; this callback delegates the exact authenticated calldata.
    function executeV2OrderItemFromSidecar(
        IOrderRouterV2ExecutionHost.ItemRequest calldata request
    ) external returns (OrderV2Types.ExecutionResult memory result) {
        _onlySelfCall();
        request;
        return abi.decode(_delegateExecutionSidecar(), (OrderV2Types.ExecutionResult));
    }

    /// @notice Releases order margin, settles its bounty, and deletes its ephemeral Router record.
    /// @dev The recipient is explicit because the item rollback boundary changes `msg.sender` to the Router. When the
    ///      source account executes its own order, only the bounty classification is released and no Engine carry
    ///      checkpoint occurs; all other recipients use the canonical Engine bounty-credit path.
    function settleV2OrderFromSidecar(
        uint64 orderId,
        bool success,
        address bountyRecipient,
        uint256 executionPrice,
        uint256 accountingPrice,
        uint64 accountingPublishTime
    ) external returns (uint256 bountyUsdc) {
        _onlySelfCall();
        (OrderRecord storage record, CfdTypes.Order memory order) = _pendingOrder(orderId);
        clearinghouse.releaseOrderReservationForTerminalCleanup(orderId);
        bountyUsdc = record.executionBountyUsdc;
        record.executionBountyUsdc = 0;
        if (bountyUsdc != 0) {
            if (bountyRecipient == order.account) {
                clearinghouse.releaseReservedExecutionBountyToSource(order.account, bountyUsdc);
            } else {
                engine.creditBounty(order.account, bountyRecipient, bountyUsdc, accountingPrice, accountingPublishTime);
            }
        }
        if (success) {
            emit OrderExecuted(orderId, executionPrice);
        }
        _deleteOrder(
            orderId, success ? IOrderRouterAccounting.OrderStatus.Executed : IOrderRouterAccounting.OrderStatus.Failed
        );
    }

    /// @notice Refunds a cutoff-invalid open without carry checkpointing and deletes its ephemeral record.
    function refundRiskOffOrderFromSidecar(
        uint64 orderId,
        uint64 riskOffCutoff
    ) external returns (uint256 refundedBountyUsdc) {
        _onlySelfCall();
        (OrderRecord storage record, CfdTypes.Order memory order) = _pendingOrder(orderId);
        if (!_isRiskOffOpen(orderId, order.isClose, riskOffCutoff)) {
            revert OrderRouter__OrderNotRiskOff();
        }

        refundedBountyUsdc = record.executionBountyUsdc;
        record.executionBountyUsdc = 0;
        uint64[] memory orderIds = new uint64[](1);
        orderIds[0] = orderId;
        emit OrderFailed(orderId, OrderFailReason.RiskOff);
        uint256 protectionBountyUsdc = _failPendingOpenProtectionForRiskOff(orderId, order.account);
        _deleteOrder(orderId, IOrderRouterAccounting.OrderStatus.Failed);
        clearinghouse.releaseInvalidatedOrderReserves(
            order.account, orderIds, refundedBountyUsdc + protectionBountyUsdc
        );
    }

    /// @notice Delegates receipt construction for an order already settled by risk-off or liquidation accounting.
    function recordSettledTerminal(
        IOrderRouterV2ExecutionHost.SettledTerminalInput calldata input
    ) external returns (OrderV2Types.ExecutionResult memory result) {
        _onlySelfCall();
        input;
        return abi.decode(_delegateExecutionSidecar(), (OrderV2Types.ExecutionResult));
    }

    /// @notice Executes the Router's canonical ETH refund-or-defer policy for the trusted sidecar.
    function sendEthFromSidecar(
        address recipient,
        uint256 amount
    ) external {
        _onlySelfCall();
        _sendEth(recipient, amount);
    }

    /// @notice Permissionlessly refunds one pending open invalidated by the persistent risk-off cutoff.
    /// @dev Requires no oracle update or ETH. The complete remaining committed-margin reservation and execution
    ///      bounty are returned to the submitting account's free internal settlement; the caller receives nothing.
    ///      The order may be removed from any position in the global queue.
    /// @param orderId Pending pre-cutoff open to refund and terminally fail.
    function clearRiskOffOrder(
        uint64 orderId
    ) external nonReentrant {
        _clearRiskOffOrder(orderId);
    }

    /// @notice Applies a finalized router risk and queue configuration.
    /// @dev Callable only by this router's deployed admin. Also forwards oracle-policy fields to the
    ///      currently configured Plether oracle.
    /// @param config Timelocked router, bounty, oracle-policy, gas, and queue configuration to apply.
    function applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) external nonReentrant {
        _applyRouterConfig(config);
        _delegateToKeeperSidecar();
        _applyRouterConfigAfterOracle(config);
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
    /// @dev Permissionless and available while the router admin is paused. The oracle handles the Pyth fee and
    ///      normally refunds unused ETH to the caller. The router's immutable position-protection book appends the
    ///      keeper and protection id when dispatching a trigger; that path refunds the keeper and queues the protected
    ///      close through the same delayed FIFO machinery.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        pythUpdateData;
        _delegateToKeeperSidecar();
    }

    /// @notice Records the already-validated close order produced by a delegated protection trigger.
    /// @dev Callable only through an external self-call from the exactly bound keeper sidecar. The sidecar performs
    ///      Book activation and bounty crediting; this callback alone mutates Router queue storage and revalidates the
    ///      next id across the intervening external Book call.
    function executePositionProtectionTriggerItem() external {
        if (msg.sender != address(this)) {
            revert OrderRouter__Unauthorized();
        }
        uint64 linkedOrderId;
        address account;
        CfdTypes.Side side;
        uint256 size;
        uint256 executionBountyUsdc;
        assembly ("memory-safe") {
            linkedOrderId := calldataload(4)
            account := calldataload(36)
            side := calldataload(68)
            size := calldataload(100)
            executionBountyUsdc := calldataload(132)
        }
        if (linkedOrderId != nextCommitId) {
            revert OrderRouter__Unauthorized();
        }
        nextCommitId = linkedOrderId + 1;
        _recordCommittedOrder(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: side == CfdTypes.Side.LONG ? engine.CAP_PRICE() : 1,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: linkedOrderId,
                side: side,
                isClose: true
            }),
            executionBountyUsdc
        );
    }

    /// @notice Atomically refreshes the pool-accounting mark and settles matured LP epochs against that exact mark.
    /// @dev Permissionless and available while the router admin is paused. Only the exact quoted Pyth fee is sent to
    ///      the oracle, preventing an oracle refund callback between validation and settlement. The engine mark update,
    ///      HousePool settlement, and final caller refund share one rollback frame.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function settleLpEpoch(
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        pythUpdateData;
        _delegateToKeeperSidecar();
    }

    /// @notice Permissionlessly liquidates an unsafe account using an account-adverse oracle price.
    /// @dev Available while paused. Before liquidation, cutoff-invalid opens are refunded and only bounties on the
    ///      remaining live orders are forfeited through the engine. On success every queued order is failed, its
    ///      committed margin is released, and its queue links are removed. The oracle handles Pyth fees and ETH refunds.
    /// @param account Canonical account to liquidate.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the Pyth update fee.
    function executeLiquidation(
        address account,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        account;
        pythUpdateData;
        _delegateToKeeperSidecar();
    }

    /// @notice Permissionlessly attempts up to 256 account liquidations from one shared Pyth snapshot.
    /// @dev Available while paused. The neutral mark is updated once, then each account's bounty forfeiture,
    ///      liquidation settlement, and order cleanup execute in an independently caught rollback frame. Accounts with
    ///      no position or a solvent position are skipped. Unexpected account-local failures are reported and do not
    ///      revert earlier successes. Processing stops before the router's reserved gas tail is consumed; an empty
    ///      item revert is treated as possible out-of-gas and leaves that item unattempted. The 256-account limit bounds
    ///      candidates, not successful executions per transaction; resume by submitting `accounts[nextIndex:]` with a
    ///      fresh Pyth update.
    /// @param accounts Candidate accounts, in keeper-selected processing order.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` funds one shared update.
    /// @return nextIndex First unattempted account index, or `accounts.length` when every account was attempted.
    function executeLiquidationBatch(
        address[] calldata accounts,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint256 nextIndex) {
        accounts;
        pythUpdateData;
        nextIndex = _delegateToKeeperSidecar();
    }

    /// @dev Forwards the original selector and calldata to the immutable, exactly Router-bound stateless sidecar.
    ///      Normal Solidity return keeps the outer transient reentrancy guard's cleanup reachable.
    function _delegateToKeeperSidecar() private returns (uint256 outputWord) {
        address logic = liquidationBatchSidecar;
        assembly ("memory-safe") {
            let input := mload(0x40)
            calldatacopy(input, 0, calldatasize())
            let success := delegatecall(gas(), logic, input, calldatasize(), 0, 0)
            let outputSize := returndatasize()
            returndatacopy(input, 0, outputSize)
            if iszero(success) { revert(input, outputSize) }
            outputWord := mload(input)
        }
    }

    /// @dev Restricts sidecar host callbacks to an external call made by this Router itself.
    function _onlySelfCall() private view {
        if (msg.sender != address(this)) {
            revert OrderRouter__Unauthorized();
        }
    }

    /// @dev Delegates the exact current calldata to the immutable V2 execution module and bubbles failures verbatim.
    function _delegateExecutionSidecar() private returns (bytes memory returndata) {
        bool success;
        // The target is immutable and constructor code-validated; Router entrypoints constrain the forwarded selector.
        // slither-disable-next-line controlled-delegatecall
        (success, returndata) = executionSidecar.delegatecall(msg.data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

}

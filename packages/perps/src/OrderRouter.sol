// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
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

    /// @notice Fixed stateless delegate module for oracle config, mark refresh, LP settlement, and liquidations.
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
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle,
        address _keeperSidecar
    ) OrderRouterBase(_engine, _engineLens, _housePool, _pletherOracle) {
        if (
            _keeperSidecar.code.length == 0
                || IOrderRouterKeeperSidecarBinding(_keeperSidecar).ROUTER() != address(this)
        ) {
            revert OrderRouter__InvalidKeeperSidecar();
        }
        liquidationBatchSidecar = _keeperSidecar;
    }

    /// @notice Submits an open/increase or strict reduce-only intent to the delayed global FIFO queue.
    /// @dev Reserves committed margin and the keeper bounty in the clearinghouse immediately. Opens are
    ///      blocked while paused, degraded, close-only, or unable to increase pool risk and may be rejected
    ///      by a fresh-mark preflight. Closes remain committable in those modes but must match and not exceed
    ///      the position obtained after applying the account's earlier queued orders. Normally the caller is the
    ///      account. The router's immutable position-protection book may append an authenticated account word when
    ///      atomically attaching protection to a newly committed open; no other caller can use that path.
    /// @param side Direction to open/increase, or the direction of the queued position being closed.
    /// @param sizeDelta Position-size change in synthetic-token units (18 decimals); must be a nonzero 100-token lot multiple.
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
        address account = msg.sender;
        if (account == address(positionProtectionBook)) {
            assembly ("memory-safe") {
                account := calldataload(164)
            }
        }
        _commitOrderFor(account, side, sizeDelta, marginDelta, targetPrice, isClose);
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
    /// @dev Before oracle work, refunds cutoff-invalid open heads up to the requested id, before pruning expired heads.
    ///      Risk-off refunds return all remaining margin and bounty to the trader, pay no caller reward, and are capped
    ///      at 64 per call; reaching the cap or removing a head before the requested target may return without executing
    ///      that target. Expiry pruning remains subject to its separately configured cap. Execution then enforces FIFO,
    ///      post-commit timing outside frozen-oracle mode, staleness, slippage, and a minimum engine-call gas reserve.
    ///      Expired, slippage-failed, and engine failures other than mark-price-out-of-order—including business-rule
    ///      rejections and panics—are terminal: committed margin is released and their bounty is credited to the caller.
    ///      Mark-price-out-of-order instead reverts nonterminally and leaves the order pending. Excess ETH is refunded,
    ///      or recorded in the admin contract if the transfer fails. Terminal failures have no retry lane.
    /// @param orderId Queue-head id to execute, or a later committed id used as the terminal-head cleanup bound.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover all Pyth fees used by the call.
    function executeOrder(
        uint64 orderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrder(orderId, pythUpdateData);
    }

    /// @notice Permissionlessly processes consecutive FIFO orders through a committed inclusive id bound.
    /// @dev Before oracle work for each item, refunds cutoff-invalid opens before applying expiry or other policy.
    ///      Those refunds return the complete remaining margin and bounty to the trader and pay no caller reward. The
    ///      batch processes at most 64 such refunds; after the 64th it may continue with a non-risk-off head, while a
    ///      65th eligible refund stops the call. The batch otherwise uses strictly post-commit historical Pyth prices
    ///      outside frozen-oracle mode and may reuse a proven basket for later compatible orders. It terminally cleans
    ///      expired, slippage-failed, and engine failures other than mark-price-out-of-order, but stops at an open
    ///      blocked by close-only policy, an MEV timing boundary, insufficient gas, either cleanup cap, or unavailable
    ///      historical data after prior progress. Mark-price-out-of-order reverts the whole batch and leaves its state
    ///      unchanged. Ordinary reserved USDC bounties accrue to the caller; unused ETH is refunded once or deferred
    ///      to the admin on transfer failure.
    /// @param maxOrderId Last committed order id the batch may process; must be at or after the head and below `nextCommitId`.
    /// @param pythUpdateData Pyth price update blobs; `msg.value` must cover the cumulative Pyth fees used.
    function executeOrderBatch(
        uint64 maxOrderId,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant {
        _executeOrderBatch(maxOrderId, pythUpdateData);
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
        _recordCommittedOrder(linkedOrderId, account, side, size, 0, 0, true, executionBountyUsdc);
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

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";

interface IRecoveryEngineClaims {

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

}

/// @notice Immutable, storage-free expiry and externally settled receipt logic delegated by the execution sidecar.
contract OrderRecoverySidecar is IOrderRouterErrors {

    uint256 private constant MAX_BULK_CLEANUP_IDS = 64;
    uint256 private constant CLEANUP_RETURN_GAS = 1_000_000;

    /// @notice Settled receipt evidence does not match the risk-off or liquidation terminal reason.
    error OrderRecoverySidecar__InvalidSettledReason();
    /// @notice The settled order identity or bounty disagrees with its lifecycle-book intent.
    error OrderRecoverySidecar__OrderIdentityMismatch(uint64 orderId);

    address private immutable SELF = address(this);
    error RecoveryUnauthorized();
    error RecoveryIdentityMismatch();

    modifier delegated() {
        if (address(this) == SELF) {
            revert RecoveryUnauthorized();
        }
        _;
    }

    modifier routerSelf() {
        if (address(this) == SELF || msg.sender != address(this)) {
            revert RecoveryUnauthorized();
        }
        _;
    }

    function expireOrder(
        uint64 orderId
    ) external delegated returns (OrderV3Types.ExecutionResult memory) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        OrderV3Types.PendingIntent memory pending = IOrderLifecycleBook(host.lifecycleBook()).pendingIntent(orderId);
        if (pending.account == address(0)) {
            revert OrderRouter__OrderNotPending();
        }
        if (block.timestamp <= pending.timing.executionDeadline) {
            revert OrderRouter__OrderNotExpired();
        }
        IOrderRouterExecutionHost.ItemRequest memory request = _cleanupRequest(
            host, orderId, true, IOrderLifecycleBook(host.lifecycleBook()).currentExecutionConfigHash()
        );
        return host.executeOrderItemFromSidecar(request);
    }

    /// @notice Removes independently invalid orders by id while preserving the Router's per-item rollback boundary.
    function clearInvalidOrders(
        uint64[] calldata orderIds
    ) external delegated returns (uint256 nextIndex, uint256 cleared) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        uint256 maximum = host.maxPruneOrdersPerCall();
        if (maximum > MAX_BULK_CLEANUP_IDS) {
            maximum = MAX_BULK_CLEANUP_IDS;
        }
        if (orderIds.length > maximum) {
            revert OrderRouter__TooManyCleanupIds(maximum);
        }

        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        for (; nextIndex < orderIds.length; ++nextIndex) {
            if (gasleft() <= 2 * CLEANUP_RETURN_GAS) {
                break;
            }
            uint64 orderId = orderIds[nextIndex];
            OrderV3Types.PendingIntent memory pending = book.pendingIntent(orderId);
            if (pending.account == address(0)) {
                continue;
            }

            bytes32 observedConfigHash = book.currentExecutionConfigHash();
            bool expired = block.timestamp > pending.timing.executionDeadline;
            bool configInvalid = pending.bounds.expectedConfigHash != bytes32(0)
                && pending.bounds.expectedConfigHash != observedConfigHash;
            if (!expired && !configInvalid) {
                continue;
            }

            IOrderRouterExecutionHost.ItemRequest memory request =
                _cleanupRequest(host, orderId, expired, observedConfigHash);
            uint256 available = gasleft();
            if (available <= 2 * CLEANUP_RETURN_GAS) {
                break;
            }
            try host.executeOrderItemFromSidecar{gas: available - CLEANUP_RETURN_GAS}(request) returns (
                OrderV3Types.ExecutionResult memory result
            ) {
                if (result.status == OrderV3Types.LifecycleStatus.Pending) {
                    break;
                }
                ++cleared;
            } catch {
                break;
            }
        }
    }

    function _cleanupRequest(
        IOrderRouterExecutionHost host,
        uint64 orderId,
        bool expired,
        bytes32 observedConfigHash
    ) private view returns (IOrderRouterExecutionHost.ItemRequest memory request) {
        ICfdEngineCore engine = ICfdEngineCore(host.engine());
        request.orderId = orderId;
        request.action =
            expired ? IOrderRouterExecutionHost.ItemAction.Expire : IOrderRouterExecutionHost.ItemAction.ConfigMismatch;
        request.executor = msg.sender;
        request.observedConfigHash = observedConfigHash;
        uint256 mark = engine.lastMarkPrice();
        request.neutralMarkPrice = mark;
        request.poolDepthUsdc = IHousePool(engine.pool()).totalAssets();
        request.bountyAccountingPrice = mark == 0 ? 1e8 : mark;
        uint256 cap = engine.CAP_PRICE();
        if (request.bountyAccountingPrice > cap) {
            request.bountyAccountingPrice = cap;
        }
        request.bountyAccountingPublishTime = engine.lastMarkTime();
    }

    function recoverExpiredItem(
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) external routerSelf returns (OrderV3Types.ExecutionResult memory) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(request.orderId);
        if (pending.account == address(0) || block.timestamp <= pending.timing.executionDeadline) {
            revert RecoveryIdentityMismatch();
        }
        OrderV3Types.OrderReceipt memory receipt = _receipt(request.orderId, pending, request.executor);
        _copyContext(receipt, request);
        receipt.reason = OrderV3Types.TerminalReason.ExpiredReservationMismatch;
        _state(host, receipt, true);
        IMarginClearinghouse.BountyRecovery memory recovery = host.expireMismatchedOrderFromSidecar(request.orderId);
        receipt.bountyUsdc = recovery.freeUsdc;
        receipt.bounty.bountyRefundedUsdc = receipt.bountyUsdc;
        receipt.bounty.discrepancy = OrderV3Types.ReservationDiscrepancy(recovery.discrepancy);
        if (receipt.bountyUsdc != 0) {
            receipt.bountyRecipient = pending.account;
            receipt.bountyDisposition = OrderV3Types.BountyDisposition.RefundedToAccount;
        }
        _state(host, receipt, false);
        return _finalize(book, receipt);
    }

    function settleNonEngine(
        IOrderRouterExecutionHost.ItemRequest calldata request,
        OrderV3Types.TerminalReason reason,
        OrderV3Types.FailureDetails calldata failure
    ) external routerSelf returns (OrderV3Types.ExecutionResult memory) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(request.orderId);
        if (pending.account == address(0)) {
            revert RecoveryIdentityMismatch();
        }
        OrderV3Types.OrderReceipt memory receipt = _receipt(request.orderId, pending, request.executor);
        receipt.reason = reason;
        _copyContext(receipt, request);
        receipt.failure = failure;
        _state(host, receipt, true);
        IOrderRouterExecutionHost.BountySettlement memory settled = _settle(host, request, reason);
        if (settled.bountyUsdc != pending.executionBountyUsdc) {
            revert RecoveryIdentityMismatch();
        }
        receipt.bountyUsdc = settled.bountyUsdc;
        receipt.bountyDisposition = settled.bountyDisposition;
        receipt.bountyRecipient = settled.bountyRecipient;
        receipt.bounty.bountyRefundedUsdc = settled.bountyRefundedUsdc;
        if (settled.bountyDisposition == OrderV3Types.BountyDisposition.Paid) {
            receipt.bounty.bountyPaidUsdc = settled.bountyUsdc - settled.bountyRefundedUsdc;
        }
        _state(host, receipt, false);
        return _finalize(book, receipt);
    }

    /// @dev Retain authenticated observations even when expiry uses reservation-mismatch recovery.
    ///      Cached mark/depth provide context; absent oracle execution fields remain absent.
    function _copyContext(
        OrderV3Types.OrderReceipt memory receipt,
        IOrderRouterExecutionHost.ItemRequest calldata request
    ) private pure {
        receipt.observedConfigHash = request.observedConfigHash;
        receipt.executionMode = request.executionMode;
        receipt.priceSource = request.priceSource;
        receipt.executionPrice = request.executionPrice;
        receipt.neutralMarkPrice = request.neutralMarkPrice;
        receipt.poolDepthUsdc = request.poolDepthUsdc;
        receipt.oraclePublishTime = request.oraclePublishTime;
    }

    function _settle(
        IOrderRouterExecutionHost host,
        IOrderRouterExecutionHost.ItemRequest calldata request,
        OrderV3Types.TerminalReason reason
    ) private returns (IOrderRouterExecutionHost.BountySettlement memory) {
        return host.settleOrderFromSidecar(
            request.orderId,
            false,
            reason,
            request.executor,
            request.executionPrice,
            request.bountyAccountingPrice,
            request.bountyAccountingPublishTime
        );
    }

    function recordSettledTerminal(
        IOrderRouterExecutionHost.SettledTerminalInput calldata input
    ) external routerSelf returns (OrderV3Types.ExecutionResult memory) {
        if (
            input.reason != OrderV3Types.TerminalReason.RiskOff
                && input.reason != OrderV3Types.TerminalReason.AccountLiquidated
        ) {
            revert OrderRecoverySidecar__InvalidSettledReason();
        }
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(input.orderId);
        if (pending.account == address(0) || input.bountyUsdc != pending.executionBountyUsdc) {
            revert OrderRecoverySidecar__OrderIdentityMismatch(input.orderId);
        }
        _validateSettledTerminalInput(host, pending, input);
        OrderV3Types.OrderReceipt memory receipt = _receipt(input.orderId, pending, input.executor);
        receipt.reason = input.reason;
        receipt.observedConfigHash = input.observedConfigHash;
        receipt.executionMode = input.executionMode;
        receipt.priceSource = input.priceSource;
        receipt.executionPrice = input.executionPrice;
        receipt.neutralMarkPrice = input.neutralMarkPrice;
        receipt.poolDepthUsdc = input.poolDepthUsdc;
        receipt.oraclePublishTime = input.oraclePublishTime;
        receipt.priceReachedEngine = input.priceReachedEngine;
        receipt.bountyUsdc = input.bountyUsdc;
        receipt.bountyRecipient = input.bountyRecipient;
        receipt.bountyDisposition = input.bountyDisposition;
        receipt.failure = input.failure;
        receipt.bounty.bountyRefundedUsdc = input.bountyRefundedUsdc;
        receipt.bounty.bountyForfeitedUsdc = input.bountyUsdc - input.bountyRefundedUsdc;
        _state(host, receipt, true);
        _state(host, receipt, false);
        // The lifecycle book independently checks reason, evidence, recipient, entitlement and disposition.
        return _finalize(book, receipt);
    }

    // Retain the upstream settled-evidence checks at the delegated recovery boundary.
    function _validateSettledTerminalInput(
        IOrderRouterExecutionHost host,
        OrderV3Types.PendingIntent memory pending,
        IOrderRouterExecutionHost.SettledTerminalInput calldata input
    ) private view {
        bool failureIsEmpty = input.failure.selector == bytes4(0) && input.failure.category == 0
            && input.failure.code == 0 && input.failure.constraint == OrderV3Types.ConstraintKind.None
            && input.failure.actual == 0 && input.failure.limit == 0 && input.failure.revertDataHash == bytes32(0);
        if (!failureIsEmpty) {
            revert OrderRecoverySidecar__InvalidSettledReason();
        }
        uint256 refund = input.reason == OrderV3Types.TerminalReason.RiskOff ? input.bountyUsdc : 0;
        OrderV3Types.BountyDisposition disposition;
        address recipient;
        if (input.bountyUsdc != 0) {
            uint256 forfeited = input.bountyUsdc - refund;
            recipient = forfeited == 0 ? pending.account : ICfdEngineCore(host.engine()).protocolTreasury();
            disposition = refund == 0
                ? OrderV3Types.BountyDisposition.Forfeited
                : OrderV3Types.BountyDisposition.RefundedToAccount;
        }
        if (
            input.bountyRefundedUsdc != refund || input.bountyDisposition != disposition
                || input.bountyRecipient != recipient
        ) {
            revert OrderRecoverySidecar__InvalidSettledReason();
        }

        if (input.reason == OrderV3Types.TerminalReason.RiskOff) {
            if (
                input.executionMode != OrderV3Types.ExecutionMode.None
                    || input.priceSource != OrderV3Types.PriceSource.None || input.executionPrice != 0
                    || input.oraclePublishTime != 0 || input.priceReachedEngine
            ) {
                revert OrderRecoverySidecar__InvalidSettledReason();
            }
            return;
        }
        if (input.priceSource != OrderV3Types.PriceSource.Liquidation || input.priceReachedEngine) {
            revert OrderRecoverySidecar__InvalidSettledReason();
        }
    }

    function _receipt(
        uint64 id,
        OrderV3Types.PendingIntent memory pending,
        address executor
    ) private pure returns (OrderV3Types.OrderReceipt memory receipt) {
        receipt.orderId = id;
        receipt.account = pending.account;
        receipt.clientOrderId = pending.clientOrderId;
        receipt.intentHash = pending.intentHash;
        receipt.expectedConfigHash = pending.bounds.expectedConfigHash;
        receipt.commitment = pending.commitment;
        receipt.timing = pending.timing;
        receipt.bounty.bountyEntitlementUsdc = pending.executionBountyUsdc;
        receipt.status = OrderV3Types.LifecycleStatus.Failed;
        receipt.executor = executor;
    }

    function _state(
        IOrderRouterExecutionHost host,
        OrderV3Types.OrderReceipt memory receipt,
        bool beforeState
    ) private view {
        ICfdEngineCore engine = ICfdEngineCore(host.engine());
        uint256 balance = IMarginClearinghouse(engine.clearinghouse()).balanceUsdc(receipt.account);
        uint256 claim = IRecoveryEngineClaims(address(engine)).traderClaimBalanceUsdc(receipt.account);
        if (beforeState) {
            receipt.economics.preSettlementBalanceUsdc = balance;
            receipt.economics.preTraderClaimBalanceUsdc = claim;
        } else {
            receipt.economics.postSettlementBalanceUsdc = balance;
            receipt.economics.postTraderClaimBalanceUsdc = claim;
            (receipt.economics.postPositionSize, receipt.economics.postPositionMarginUsdc,,,,,) =
                engine.positions(receipt.account);
        }
    }

    function _finalize(
        IOrderLifecycleBook book,
        OrderV3Types.OrderReceipt memory receipt
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        result.orderId = receipt.orderId;
        result.status = receipt.status;
        result.terminalReason = receipt.reason;
        result.receiptHash = book.finalize(receipt);
    }

}

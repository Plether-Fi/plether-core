// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IOrderRouterV2ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV2ExecutionHost.sol";

interface IRecoveryEngineClaims {

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

}

/// @notice Immutable, storage-free expiry and externally settled receipt logic delegated by the execution sidecar.
contract OrderRecoverySidecar is IOrderRouterErrors {

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
    ) external delegated returns (OrderV2Types.ExecutionResult memory) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        OrderV2Types.PendingIntent memory pending = IOrderLifecycleBook(host.lifecycleBook()).pendingIntent(orderId);
        if (pending.account == address(0)) {
            revert OrderRouter__OrderNotPending();
        }
        if (block.timestamp <= pending.bounds.validUntil) {
            revert OrderRouter__OrderNotExpired();
        }
        // Solidity zero-initializes this memory struct; oracle/execution fields are intentionally absent for expiry.
        // slither-disable-next-line uninitialized-local
        IOrderRouterV2ExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.action = IOrderRouterV2ExecutionHost.ItemAction.Expire;
        request.executor = msg.sender;
        return host.executeV2OrderItemFromSidecar(request);
    }

    function recoverExpiredItem(
        uint64 orderId,
        address executor
    ) external routerSelf returns (OrderV2Types.ExecutionResult memory) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(orderId);
        if (pending.account == address(0) || block.timestamp <= pending.bounds.validUntil) {
            revert RecoveryIdentityMismatch();
        }
        OrderV2Types.OrderReceipt memory receipt = _receipt(orderId, pending, executor);
        receipt.reason = OrderV2Types.TerminalReason.ExpiredReservationMismatch;
        _state(host, receipt, true);
        IMarginClearinghouse.BountyRecovery memory recovery = host.expireMismatchedOrderFromSidecar(orderId);
        receipt.bountyUsdc = recovery.freeUsdc + recovery.pledgeUsdc;
        receipt.bounty.bountyRefundedUsdc = receipt.bountyUsdc;
        receipt.bounty.discrepancy = OrderV2Types.ReservationDiscrepancy(recovery.discrepancy);
        if (receipt.bountyUsdc != 0) {
            receipt.bountyRecipient = pending.account;
            receipt.bountyDisposition = OrderV2Types.BountyDisposition.RefundedToAccount;
        }
        _state(host, receipt, false);
        return _finalize(book, receipt);
    }

    function settleNonEngine(
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        OrderV2Types.TerminalReason reason,
        OrderV2Types.FailureDetails calldata failure
    ) external routerSelf returns (OrderV2Types.ExecutionResult memory) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(request.orderId);
        if (pending.account == address(0)) {
            revert RecoveryIdentityMismatch();
        }
        OrderV2Types.OrderReceipt memory receipt = _receipt(request.orderId, pending, request.executor);
        receipt.reason = reason;
        receipt.observedConfigHash = request.observedConfigHash;
        receipt.executionMode = request.executionMode;
        receipt.priceSource = request.priceSource;
        receipt.executionPrice = request.executionPrice;
        receipt.neutralMarkPrice = request.neutralMarkPrice;
        receipt.poolDepthUsdc = request.poolDepthUsdc;
        receipt.oraclePublishTime = request.oraclePublishTime;
        receipt.failure = failure;
        _state(host, receipt, true);
        IOrderRouterV2ExecutionHost.BountySettlement memory settled = _settle(host, request, reason);
        if (settled.bountyUsdc != pending.executionBountyUsdc) {
            revert RecoveryIdentityMismatch();
        }
        receipt.bountyUsdc = settled.bountyUsdc;
        receipt.bountyDisposition = settled.bountyDisposition;
        receipt.bountyRecipient = settled.bountyRecipient;
        if (settled.bountyDisposition == OrderV2Types.BountyDisposition.Paid) {
            receipt.bounty.bountyPaidUsdc = settled.bountyUsdc;
        } else if (settled.bountyDisposition == OrderV2Types.BountyDisposition.RetainedForProtectionRetry) {
            receipt.bounty.bountyRetainedUsdc = settled.bountyUsdc;
        }
        _state(host, receipt, false);
        return _finalize(book, receipt);
    }

    function _settle(
        IOrderRouterV2ExecutionHost host,
        IOrderRouterV2ExecutionHost.ItemRequest calldata request,
        OrderV2Types.TerminalReason reason
    ) private returns (IOrderRouterV2ExecutionHost.BountySettlement memory) {
        return host.settleV2OrderFromSidecar(
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
        IOrderRouterV2ExecutionHost.SettledTerminalInput calldata input
    ) external routerSelf returns (OrderV2Types.ExecutionResult memory) {
        IOrderRouterV2ExecutionHost host = IOrderRouterV2ExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV2Types.PendingIntent memory pending = book.pendingIntent(input.orderId);
        if (
            pending.account == address(0) || input.bountyUsdc != pending.executionBountyUsdc
                || (input.reason != OrderV2Types.TerminalReason.RiskOff
                    && input.reason != OrderV2Types.TerminalReason.AccountLiquidated)
        ) {
            revert RecoveryIdentityMismatch();
        }
        OrderV2Types.OrderReceipt memory receipt = _receipt(input.orderId, pending, input.executor);
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
        if (input.reason == OrderV2Types.TerminalReason.RiskOff) {
            receipt.bounty.bountyRefundedUsdc = input.bountyUsdc;
        } else {
            receipt.bounty.bountyForfeitedUsdc = input.bountyUsdc;
        }
        _state(host, receipt, true);
        _state(host, receipt, false);
        // The lifecycle book independently checks reason, evidence, recipient, entitlement and disposition.
        return _finalize(book, receipt);
    }

    function _receipt(
        uint64 id,
        OrderV2Types.PendingIntent memory pending,
        address executor
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        receipt.orderId = id;
        receipt.account = pending.account;
        receipt.clientOrderId = pending.clientOrderId;
        receipt.intentHash = pending.intentHash;
        receipt.expectedConfigHash = pending.bounds.expectedConfigHash;
        receipt.closeMode = pending.closeMode;
        receipt.commitment = pending.commitment;
        receipt.bounty.bountyEntitlementUsdc = pending.executionBountyUsdc;
        receipt.status = OrderV2Types.LifecycleStatus.Failed;
        receipt.executor = executor;
    }

    function _state(
        IOrderRouterV2ExecutionHost host,
        OrderV2Types.OrderReceipt memory receipt,
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
        OrderV2Types.OrderReceipt memory receipt
    ) private returns (OrderV2Types.ExecutionResult memory result) {
        result.orderId = receipt.orderId;
        result.status = receipt.status;
        result.terminalReason = receipt.reason;
        result.receiptHash = book.finalize(receipt);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
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

    error OrderRouterExecutionSidecar__InvalidSettledReason();
    error OrderRouterExecutionSidecar__OrderIdentityMismatch(uint64 orderId);

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
        // Solidity zero-initializes this memory struct; oracle/execution fields are intentionally absent for expiry.
        // slither-disable-next-line uninitialized-local
        IOrderRouterExecutionHost.ItemRequest memory request;
        request.orderId = orderId;
        request.action = IOrderRouterExecutionHost.ItemAction.Expire;
        request.executor = msg.sender;
        return host.executeOrderItemFromSidecar(request);
    }

    function recoverExpiredItem(
        uint64 orderId,
        address executor
    ) external routerSelf returns (OrderV3Types.ExecutionResult memory) {
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(orderId);
        if (pending.account == address(0) || block.timestamp <= pending.timing.executionDeadline) {
            revert RecoveryIdentityMismatch();
        }
        OrderV3Types.OrderReceipt memory receipt = _receipt(orderId, pending, executor);
        receipt.reason = OrderV3Types.TerminalReason.ExpiredReservationMismatch;
        _state(host, receipt, true);
        IMarginClearinghouse.BountyRecovery memory recovery = host.expireMismatchedOrderFromSidecar(orderId);
        receipt.bountyUsdc = recovery.freeUsdc + recovery.pledgeUsdc;
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
        receipt.observedConfigHash = request.observedConfigHash;
        receipt.executionMode = request.executionMode;
        receipt.priceSource = request.priceSource;
        receipt.executionPrice = request.executionPrice;
        receipt.neutralMarkPrice = request.neutralMarkPrice;
        receipt.poolDepthUsdc = request.poolDepthUsdc;
        receipt.oraclePublishTime = request.oraclePublishTime;
        receipt.failure = failure;
        _state(host, receipt, true);
        IOrderRouterExecutionHost.BountySettlement memory settled = _settle(host, request, reason);
        if (settled.bountyUsdc != pending.executionBountyUsdc) {
            revert RecoveryIdentityMismatch();
        }
        receipt.bountyUsdc = settled.bountyUsdc;
        receipt.bountyDisposition = settled.bountyDisposition;
        receipt.bountyRecipient = settled.bountyRecipient;
        if (settled.bountyDisposition == OrderV3Types.BountyDisposition.Paid) {
            receipt.bounty.bountyPaidUsdc = settled.bountyUsdc;
        } else if (settled.bountyDisposition == OrderV3Types.BountyDisposition.RetainedForProtectionRetry) {
            receipt.bounty.bountyRetainedUsdc = settled.bountyUsdc;
        }
        _state(host, receipt, false);
        return _finalize(book, receipt);
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
            revert OrderRouterExecutionSidecar__InvalidSettledReason();
        }
        IOrderRouterExecutionHost host = IOrderRouterExecutionHost(address(this));
        IOrderLifecycleBook book = IOrderLifecycleBook(host.lifecycleBook());
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(input.orderId);
        if (pending.account == address(0) || input.bountyUsdc != pending.executionBountyUsdc) {
            revert OrderRouterExecutionSidecar__OrderIdentityMismatch(input.orderId);
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
        if (input.reason == OrderV3Types.TerminalReason.RiskOff) {
            receipt.bounty.bountyRefundedUsdc = input.bountyUsdc;
        } else {
            receipt.bounty.bountyForfeitedUsdc = input.bountyUsdc;
        }
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
            revert OrderRouterExecutionSidecar__InvalidSettledReason();
        }
        if (input.bountyUsdc == 0) {
            if (input.bountyDisposition != OrderV3Types.BountyDisposition.None || input.bountyRecipient != address(0)) {
                revert OrderRouterExecutionSidecar__InvalidSettledReason();
            }
        } else if (input.reason == OrderV3Types.TerminalReason.RiskOff) {
            if (
                input.bountyDisposition != OrderV3Types.BountyDisposition.RefundedToAccount
                    || input.bountyRecipient != pending.account
            ) {
                revert OrderRouterExecutionSidecar__InvalidSettledReason();
            }
        } else if (
            input.bountyDisposition != OrderV3Types.BountyDisposition.Forfeited
                || input.bountyRecipient != ICfdEngineCore(host.engine()).protocolTreasury()
        ) {
            revert OrderRouterExecutionSidecar__InvalidSettledReason();
        }
        if (input.reason == OrderV3Types.TerminalReason.RiskOff) {
            if (
                input.executionMode != OrderV3Types.ExecutionMode.None
                    || input.priceSource != OrderV3Types.PriceSource.None || input.executionPrice != 0
                    || input.oraclePublishTime != 0 || input.priceReachedEngine
            ) {
                revert OrderRouterExecutionSidecar__InvalidSettledReason();
            }
            return;
        }
        if (input.priceSource != OrderV3Types.PriceSource.Liquidation || input.priceReachedEngine) {
            revert OrderRouterExecutionSidecar__InvalidSettledReason();
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

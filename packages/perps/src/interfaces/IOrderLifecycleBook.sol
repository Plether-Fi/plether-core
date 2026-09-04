// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";

/// @title Immutable V2 order lifecycle book
/// @notice Permanent idempotency records and authenticated terminal receipts for delayed orders.
interface IOrderLifecycleBook {

    /// @notice A mutation was attempted by an address other than the immutable Router.
    error OrderLifecycleBook__Unauthorized();
    /// @notice An immutable protocol dependency was configured as the zero address.
    error OrderLifecycleBook__ZeroDependency();
    /// @notice A pending registration supplied the zero account address.
    error OrderLifecycleBook__ZeroAccount();
    /// @notice A pending registration supplied the reserved zero order identifier.
    error OrderLifecycleBook__ZeroOrderId();
    /// @notice A pending registration supplied the reserved zero client identifier.
    error OrderLifecycleBook__ZeroClientOrderId();
    /// @notice A client id was previously committed to a different intent.
    error OrderLifecycleBook__ClientIdConflict(
        address account, bytes32 clientOrderId, bytes32 existingIntentHash, bytes32 suppliedIntentHash
    );
    /// @notice A fresh request used the public client-id namespace for an internal intent, or vice versa.
    error OrderLifecycleBook__ClientIdDomainMismatch(bytes32 clientOrderId, bool protocolIntent);
    /// @notice An order id already has a pending or terminal lifecycle record.
    error OrderLifecycleBook__OrderIdAlreadyUsed(uint64 orderId);
    /// @notice The actual quoted bounty exceeds the user's committed maximum.
    error OrderLifecycleBook__ExecutionBountyAboveBound(uint256 actualBountyUsdc, uint256 maximumBountyUsdc);
    /// @notice A finalization referenced an order that is not pending.
    error OrderLifecycleBook__OrderNotPending(uint64 orderId);
    /// @notice A protection-attempt marker referenced a missing or externally pinned pending intent.
    error OrderLifecycleBook__InvalidProtectionAttempt(uint64 orderId);
    /// @notice A pending order was already registered as a position-protection execution attempt.
    error OrderLifecycleBook__ProtectionAttemptAlreadyRegistered(uint64 orderId);
    /// @notice Receipt identity or its pinned configuration differs from the pending intent.
    error OrderLifecycleBook__ReceiptIdentityMismatch(uint64 orderId);
    /// @notice A receipt supplied an impossible terminal status/reason combination.
    error OrderLifecycleBook__InvalidTerminalOutcome();
    /// @notice The chain's terminal block number or timestamp cannot fit the canonical receipt encoding.
    error OrderLifecycleBook__TerminalClockOverflow();

    /// @notice Emitted once after a previously unused client id becomes pending.
    event IntentRegistered(
        uint64 indexed orderId,
        address indexed account,
        bytes32 indexed clientOrderId,
        bytes32 intentHash,
        uint256 executionBountyUsdc,
        OrderV2Types.OrderRequest request
    );

    /// @notice Emitted after the Router authenticates a pending internal intent as a position-protection attempt.
    event ProtectionAttemptRegistered(uint64 indexed orderId);

    /// @notice Canonical fixed-shape evidence for one terminal order.
    /// @dev The receipt hash commits to the complete receipt, terminal clock, chain, Book, and Router.
    event OrderFinalized(
        uint64 indexed orderId,
        address indexed account,
        bytes32 indexed clientOrderId,
        bytes32 receiptHash,
        uint64 terminalBlock,
        uint64 terminalTime,
        OrderV2Types.OrderReceipt receipt
    );

    function ROUTER() external view returns (address);

    function ENGINE() external view returns (address);

    function CLEARINGHOUSE() external view returns (address);

    function HOUSE_POOL() external view returns (address);

    function INTENT_TYPEHASH() external view returns (bytes32);

    function RECEIPT_TYPEHASH() external view returns (bytes32);

    function CONFIG_SCHEMA_HASH() external view returns (bytes32);

    /// @notice Hashes every mutable execution-critical integration and finalized admin version.
    function currentExecutionConfigHash() external view returns (bytes32 configHash);

    /// @notice Computes the canonical account-scoped intent hash.
    function hashOrderRequest(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) external view returns (bytes32 intentHash);

    /// @notice Resolves a request before current-state commit validation.
    function resolveClientIntent(
        address account,
        OrderV2Types.OrderRequest calldata request
    ) external view returns (OrderV2Types.ClientIntentResolution resolution, uint64 orderId, bytes32 intentHash);

    /// @notice Permanently binds a new client id and stores its pending policy.
    /// @dev Exact replay is a no-op and returns the original order id; conflicting reuse reverts. Fresh requests with
    ///      a zero expected-config hash must use the reserved protocol namespace, which public requests cannot claim.
    function registerPending(
        address account,
        uint64 proposedOrderId,
        OrderV2Types.OrderRequest calldata request,
        uint256 executionBountyUsdc
    ) external returns (uint64 resolvedOrderId, bytes32 intentHash, bool replayed);

    /// @notice Marks a pending internal intent as a position-protection execution attempt.
    /// @dev Router-only. The intent must already be pending, use the internal unpinned configuration domain, and not
    ///      already carry the marker. Finalization deletes the marker regardless of terminal outcome.
    function registerProtectionAttempt(
        uint64 orderId
    ) external;

    /// @notice Returns whether a pending order is registered as a position-protection execution attempt.
    function isProtectionAttempt(
        uint64 orderId
    ) external view returns (bool registered);

    /// @notice Atomically deletes pending policy, stores a compact outcome, and emits the full receipt.
    function finalize(
        OrderV2Types.OrderReceipt calldata receipt
    ) external returns (bytes32 receiptHash);

    function clientIntent(
        address account,
        bytes32 clientOrderId
    ) external view returns (OrderV2Types.ClientIntent memory intent);

    function pendingIntent(
        uint64 orderId
    ) external view returns (OrderV2Types.PendingIntent memory intent);

    function pendingPolicy(
        uint64 orderId
    ) external view returns (OrderV2Types.ExecutionBounds memory bounds);

    /// @notice Returns Pending while live, otherwise the permanent terminal status or None for an unknown id.
    function lifecycleStatus(
        uint64 orderId
    ) external view returns (OrderV2Types.LifecycleStatus status);

    function outcome(
        uint64 orderId
    ) external view returns (OrderV2Types.CompactOutcome memory terminalOutcome);

}

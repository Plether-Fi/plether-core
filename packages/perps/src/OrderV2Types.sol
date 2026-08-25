// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @title Canonical V2 delayed-order types
/// @notice Fixed-width request, policy, assessment, and receipt types shared by the V2 order pipeline.
/// @custom:security-contact contact@plether.com
library OrderV2Types {

    /// @notice Lifecycle state stored by the immutable order book.
    enum LifecycleStatus {
        None,
        Pending,
        Executed,
        Failed
    }

    /// @notice Result of resolving a client-supplied id in an account namespace.
    enum ClientIntentResolution {
        Unused,
        ExactReplay,
        Conflict
    }

    /// @notice Execution regime selected from authoritative protocol state.
    enum ExecutionMode {
        None,
        Live,
        Fad,
        Frozen
    }

    /// @notice Source of the price reported in a terminal receipt.
    enum PriceSource {
        None,
        OracleExecution,
        CachedMark,
        Liquidation
    }

    /// @notice Final disposition of the order's reserved keeper bounty.
    enum BountyDisposition {
        None,
        Paid,
        Forfeited,
        RefundedToAccount
    }

    /// @notice Canonical reason for a terminal order transition.
    enum TerminalReason {
        None,
        Executed,
        Expired,
        Slippage,
        ConfigMismatch,
        ExecutionModeDisallowed,
        RiskOff,
        PlannerRejected,
        ConstraintViolation,
        AccountLiquidated
    }

    /// @notice Financial constraint tested by the policy evaluator.
    /// @dev Ordering is canonical and is also the required evaluation order.
    enum ConstraintKind {
        None,
        ExecutionBounty,
        ExecutionNotional,
        GrossAccountDebit,
        ActionCharge,
        ExplicitFees,
        PostPositionSize,
        PostSettlementBalance,
        PostPositionEquity,
        PostLeverage
    }

    /// @notice Why an execution call left the current order pending.
    enum PendingReason {
        None,
        CloseOnly,
        SameBlock,
        MevBoundary,
        HistoricalPriceUnavailable,
        InsufficientGas,
        MarkPriceOutOfOrder,
        EngineFailure,
        ReceiptFailure,
        CleanupLimit
    }

    /// @notice Mandatory financial authority supplied with every V2 order.
    /// @dev Maximum values are inclusive and zero is a real zero allowance. Minimum values are inclusive.
    ///      `maxGrossAccountDebitUsdc` covers settlement debit, trader-claim consumption, and the reserved bounty;
    ///      `minPostSettlementBalanceUsdc` refers to total internal settlement custody, including locked value.
    struct ExecutionBounds {
        uint64 validUntil;
        uint8 allowedExecutionModes;
        bytes32 expectedConfigHash;
        uint256 maxExecutionBountyUsdc;
        uint256 maxExecutionNotionalUsdc;
        uint256 maxGrossAccountDebitUsdc;
        uint256 maxActionChargeUsdc;
        uint256 maxExplicitFeesUsdc;
        uint256 maxPostPositionSize;
        uint256 minPostSettlementBalanceUsdc;
        uint256 minPostPositionEquityUsdc;
        uint32 maxPostLeverageBps;
    }

    /// @notice Canonical, idempotent V2 order submission.
    struct OrderRequest {
        bytes32 clientOrderId;
        CfdTypes.Side side;
        uint256 sizeDelta;
        uint256 marginDelta;
        uint256 targetPrice;
        bool isClose;
        ExecutionBounds bounds;
    }

    /// @notice Permanent client-id resolution record.
    struct ClientIntent {
        uint64 orderId;
        bytes32 intentHash;
    }

    /// @notice Identity and policy retained only while an order is pending.
    struct PendingIntent {
        address account;
        bytes32 clientOrderId;
        bytes32 intentHash;
        uint256 executionBountyUsdc;
        ExecutionBounds bounds;
    }

    /// @notice Normalized economic assessment produced before Engine state is applied.
    struct ExecutionAssessment {
        ExecutionMode mode;
        uint256 executionNotionalUsdc;
        uint256 grossAccountDebitUsdc;
        uint256 actionChargeAssessedUsdc;
        uint256 actionChargeCollectedUsdc;
        uint256 explicitFeesUsdc;
        uint256 preSettlementBalanceUsdc;
        uint256 postSettlementBalanceUsdc;
        int256 realizedPnlUsdc;
        int256 vpiUsdc;
        uint256 carryUsdc;
        uint256 executionFeeUsdc;
        uint256 frozenSpreadUsdc;
        uint256 preTraderClaimUsdc;
        uint256 postTraderClaimUsdc;
        uint256 postPositionSize;
        uint256 postPositionMarginUsdc;
        int256 postPositionEquityUsdc;
        uint256 postLeverageBps;
    }

    /// @notice Typed failure evidence included in a terminal receipt.
    struct FailureDetails {
        bytes4 selector;
        uint8 category;
        uint8 code;
        ConstraintKind constraint;
        uint256 actual;
        uint256 limit;
        bytes32 revertDataHash;
    }

    /// @notice Complete normalized economics emitted for a terminal order.
    struct OrderEconomics {
        uint256 executionNotionalUsdc;
        int256 realizedPnlUsdc;
        int256 vpiUsdc;
        int256 carryUsdc;
        uint256 executionFeeUsdc;
        uint256 frozenSpreadUsdc;
        uint256 actionChargeAssessedUsdc;
        uint256 actionChargeCollectedUsdc;
        uint256 grossAccountDebitUsdc;
        uint256 preSettlementBalanceUsdc;
        uint256 postSettlementBalanceUsdc;
        uint256 preTraderClaimBalanceUsdc;
        uint256 postTraderClaimBalanceUsdc;
        uint256 postPositionSize;
        uint256 postPositionMarginUsdc;
        int256 postPositionEquityUsdc;
        uint256 postLeverageBps;
    }

    /// @notice Full fixed-shape input authenticated and emitted by the lifecycle book.
    struct OrderReceipt {
        uint64 orderId;
        address account;
        bytes32 clientOrderId;
        bytes32 intentHash;
        bytes32 expectedConfigHash;
        bytes32 observedConfigHash;
        LifecycleStatus status;
        TerminalReason reason;
        ExecutionMode executionMode;
        address executor;
        PriceSource priceSource;
        uint256 executionPrice;
        uint256 neutralMarkPrice;
        uint256 poolDepthUsdc;
        uint64 oraclePublishTime;
        bool priceReachedEngine;
        uint256 bountyUsdc;
        address bountyRecipient;
        BountyDisposition bountyDisposition;
        FailureDetails failure;
        OrderEconomics economics;
    }

    /// @notice Compact permanent terminal state; full economics remain available from the canonical event.
    struct CompactOutcome {
        address account;
        bytes32 clientOrderId;
        bytes32 intentHash;
        bytes32 expectedConfigHash;
        bytes32 observedConfigHash;
        LifecycleStatus status;
        TerminalReason reason;
        ExecutionMode executionMode;
        PriceSource priceSource;
        BountyDisposition bountyDisposition;
        uint64 terminalBlock;
        uint64 terminalTime;
        uint64 oraclePublishTime;
        address executor;
        address bountyRecipient;
        uint256 executionPrice;
        uint256 bountyUsdc;
        bytes4 failureSelector;
        uint8 failureCategory;
        uint8 failureCode;
        ConstraintKind failedConstraint;
        bytes32 revertDataHash;
        bytes32 receiptHash;
    }

    /// @notice Machine-readable result of one Router execution request.
    struct ExecutionResult {
        uint64 orderId;
        LifecycleStatus status;
        TerminalReason terminalReason;
        PendingReason pendingReason;
        bytes32 receiptHash;
    }

    /// @notice Machine-readable result of one bounded batch request.
    struct BatchResult {
        uint64 nextOrderId;
        uint32 terminalCount;
        PendingReason stopReason;
    }

}

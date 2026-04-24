// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice USDC-only cross-margin account system that holds settlement balances and settles PnL for CFD positions.
/// @dev This is the full operator/integration surface.
///      Product-facing consumers should prefer `IMarginAccount` and avoid depending on
///      reservation buckets, internal custody buckets, or settlement-path helpers.
interface IMarginClearinghouse {

    error MarginClearinghouse__NotOperator();
    error MarginClearinghouse__NotAccountOwner();
    error MarginClearinghouse__ZeroAmount();
    error MarginClearinghouse__InsufficientBalance();
    error MarginClearinghouse__InsufficientFreeEquity();
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    error MarginClearinghouse__InsufficientAssetToSeize();
    error MarginClearinghouse__InvalidSeizeRecipient();
    error MarginClearinghouse__InvalidMarginBucket();
    error MarginClearinghouse__ReservationAlreadyExists();
    error MarginClearinghouse__ReservationNotActive();
    error MarginClearinghouse__IncompleteReservationCoverage();
    error MarginClearinghouse__ReservationLedgerActive();
    error MarginClearinghouse__EngineAlreadySet();
    error MarginClearinghouse__ZeroAddress();
    error MarginClearinghouse__InsufficientBucketMargin();
    error MarginClearinghouse__AmountOverflow();

    enum MarginBucket {
        Position,
        CommittedOrder,
        ReservedSettlement
    }

    struct LockedMarginBuckets {
        // Canonical custody bucket backing currently live positions.
        uint256 positionMarginUsdc;
        uint256 committedOrderMarginUsdc;
        uint256 reservedSettlementUsdc;
        uint256 totalLockedMarginUsdc;
    }

    enum ReservationBucket {
        CommittedOrder
    }

    enum ReservationStatus {
        None,
        Active,
        Consumed,
        Released
    }

    struct OrderReservation {
        address account;
        ReservationBucket bucket;
        ReservationStatus status;
        uint96 originalAmountUsdc;
        uint96 remainingAmountUsdc;
    }

    struct AccountReservationSummary {
        uint256 activeCommittedOrderMarginUsdc;
        uint256 activeReservationCount;
    }

    struct AccountUsdcBuckets {
        uint256 settlementBalanceUsdc;
        uint256 totalLockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
    }

    struct LiquidationSettlementPlan {
        uint256 settlementRetainedUsdc;
        uint256 settlementSeizedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 badDebtUsdc;
        uint256 positionMarginUnlockedUsdc;
        uint256 otherLockedMarginUnlockedUsdc;
    }

    /// @notice Returns the settlement USDC balance for an account.
    function balanceUsdc(
        address account
    ) external view returns (uint256);
    /// @notice Returns the locked USDC margin for an account
    function lockedMarginUsdc(
        address account
    ) external view returns (uint256);
    /// @notice Returns the typed locked-margin buckets for an account.
    function getLockedMarginBuckets(
        address account
    ) external view returns (LockedMarginBuckets memory buckets);
    /// @notice Returns the reservation record for a specific order id.
    function getOrderReservation(
        uint64 orderId
    ) external view returns (OrderReservation memory reservation);
    /// @notice Returns the aggregate active reservation summary for an account.
    function getAccountReservationSummary(
        address account
    ) external view returns (AccountReservationSummary memory summary);
    /// @notice Locks trader-owned settlement into the active position margin bucket.
    function lockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks active position margin back into free settlement.
    function unlockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Locks trader-owned settlement into the committed-order bucket reserved for queued open orders.
    function lockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Reserves committed-order margin for a specific order id inside the clearinghouse reservation ledger.
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks committed-order margin back into free settlement when a queued open order is released.
    function unlockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Releases any remaining reservation balance for an order back into free settlement.
    function releaseOrderReservation(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);
    /// @notice Releases any remaining reservation balance for an order if it is still active.
    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);
    /// @notice Consumes a specific amount from an order reservation, capped by its remaining balance.
    function consumeOrderReservation(
        uint64 orderId,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Consumes active order reservations for an account in FIFO reservation order.
    function consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Consumes the supplied active order reservations in FIFO order until the requested amount is exhausted.
    function consumeOrderReservationsById(
        uint64[] calldata orderIds,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Locks settlement into a reserved bucket excluded from generic order/position margin release paths.
    function lockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks settlement from the reserved bucket back into free settlement.
    function unlockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Adjusts settlement USDC for realized PnL, deferred-claim servicing, or rebates (+credit, -debit).
    function settleUsdc(
        address account,
        int256 amount
    ) external;
    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        address account,
        uint256 amountUsdc
    ) external;
    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external returns (int256 netMarginChangeUsdc);
    /// @notice Consumes a realized settlement loss from free settlement plus the active position margin bucket.
    function consumeSettlementLoss(
        address account,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc);
    /// @notice Consumes close-path losses from settlement buckets while preserving the remaining live position margin and reserved escrow.
    function consumeCloseLoss(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient
    ) external returns (uint256 seizedUsdc, uint256 shortfallUsdc);
    /// @notice Applies a pre-planned liquidation settlement mutation while preserving reserved escrow.
    function applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        LiquidationSettlementPlan calldata plan,
        address recipient
    ) external returns (uint256 seizedUsdc);
    /// @notice Transfers settlement USDC from an account to a recipient (losses, fees, or bad debt)
    function seizeUsdc(
        address account,
        uint256 amount,
        address recipient
    ) external;
    /// @notice Reserves free-settlement USDC for a close-order execution bounty with carry checkpointing.
    /// @dev Restricted to the engine's atomic fresh close-bounty path.
    function reserveCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount,
        address recipient
    ) external;
    /// @notice Reserves free-settlement USDC for a stale close-order execution bounty without checkpointing carry.
    /// @dev Restricted to the engine's atomic stale close-bounty path.
    function reserveStaleCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount,
        address recipient
    ) external;
    /// @notice Transfers settlement USDC from active position margin to a recipient and unlocks the same amount.
    function seizePositionMarginUsdc(
        address account,
        uint256 amount,
        address recipient
    ) external;
    /// @notice Reserves active position margin for a stale close-order execution bounty without checkpointing carry.
    /// @dev Restricted to the engine's bounded stale close-bounty path.
    function reserveStaleCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount,
        address recipient
    ) external;
    function getAccountUsdcBuckets(
        address account
    ) external view returns (AccountUsdcBuckets memory buckets);
    /// @notice Returns total account equity in settlement USDC (6 decimals)
    function getAccountEquityUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns strictly free buying power after subtracting locked margin (6 decimals)
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}

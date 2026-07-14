// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

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
    /// @param account Account to inspect
    function balanceUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns the locked USDC margin for an account
    /// @param account Account to inspect
    function lockedMarginUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns the typed locked-margin buckets for an account.
    /// @param account Account to inspect
    /// @return buckets Position, committed-order, reserved-settlement, and total locked buckets
    function getLockedMarginBuckets(
        address account
    ) external view returns (LockedMarginBuckets memory buckets);

    /// @notice Returns the reservation record for a specific order id.
    /// @param orderId Order reservation id to inspect
    /// @return reservation Reservation record
    function getOrderReservation(
        uint64 orderId
    ) external view returns (OrderReservation memory reservation);

    /// @notice Returns the aggregate active reservation summary for an account.
    /// @param account Account to inspect
    /// @return summary Active committed-order margin and count
    function getAccountReservationSummary(
        address account
    ) external view returns (AccountReservationSummary memory summary);

    /// @notice Locks trader-owned settlement into the active position margin bucket.
    /// @param account Account whose settlement should be locked
    /// @param amountUsdc USDC amount to lock
    function lockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks active position margin back into free settlement.
    /// @param account Account whose position margin should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Locks trader-owned settlement into the committed-order bucket reserved for queued open orders.
    /// @param account Account whose settlement should be locked
    /// @param amountUsdc USDC amount to lock
    function lockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Reserves committed-order margin for a specific order id inside the clearinghouse reservation ledger.
    /// @param account Account whose committed-order margin backs the reservation
    /// @param orderId Router order id receiving the reservation
    /// @param amountUsdc USDC amount to reserve
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks committed-order margin back into free settlement when a queued open order is released.
    /// @param account Account whose committed-order margin should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Releases any remaining reservation balance for an order back into free settlement.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc USDC amount released
    function releaseOrderReservation(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);

    /// @notice Releases any remaining reservation balance for an order if it is still active.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc USDC amount released, or zero if the reservation was not active
    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);

    /// @notice Consumes a specific amount from an order reservation, capped by its remaining balance.
    /// @param orderId Order reservation id to consume
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc USDC amount consumed
    function consumeOrderReservation(
        uint64 orderId,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Consumes active order reservations for an account in FIFO reservation order.
    /// @param account Account whose active reservations should be consumed
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc USDC amount consumed
    function consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Consumes the supplied active order reservations in FIFO order until the requested amount is exhausted.
    /// @param orderIds Reservation order ids to consume in supplied order
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc USDC amount consumed
    function consumeOrderReservationsById(
        uint64[] calldata orderIds,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Locks settlement into a reserved bucket excluded from generic order/position margin release paths.
    /// @param account Account whose settlement should be reserved
    /// @param amountUsdc USDC amount to lock as reserved settlement
    function lockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks settlement from the reserved bucket back into free settlement.
    /// @param account Account whose reserved settlement should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Adjusts settlement USDC for realized PnL, trader claim settlement, or rebates (+credit, -debit).
    /// @param account Account to settle
    /// @param amount Signed USDC delta: positive credits, negative debits
    function settleUsdc(
        address account,
        int256 amount
    ) external;

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    /// @param account Account receiving the settlement credit and position margin lock
    /// @param amountUsdc USDC amount to credit and lock
    function creditSettlementAndLockMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Applies an open/increase trade cost and routes any cash-collected protocol fee to a treasury account.
    /// @param account Account whose settlement/margin pays or receives the open cost
    /// @param marginDeltaUsdc Margin supplied with the order
    /// @param tradeCostUsdc Signed VPI/trade cost; positive debits, negative rebates
    /// @param recipient Pool recipient for cash debits
    /// @param protocolFeeAccount Clearinghouse account receiving any protocol fee credit
    /// @param protocolFeeUsdc Protocol fee amount included in the open cost
    /// @return netMarginChangeUsdc Signed change applied to active position margin
    /// @return protocolFeeCreditedUsdc Protocol fee credited to the treasury account
    function applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) external returns (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc);

    /// @notice Consumes a realized settlement loss from free settlement plus the active position margin bucket.
    /// @param account Account paying the loss
    /// @param lockedPositionMarginUsdc Position margin available to consume
    /// @param lossUsdc USDC loss to collect
    /// @param recipient Recipient of seized USDC
    /// @return marginConsumedUsdc Active position margin consumed
    /// @return freeSettlementConsumedUsdc Free settlement consumed
    /// @return uncoveredUsdc Loss left uncovered after available funds are exhausted
    function consumeSettlementLoss(
        address account,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc);

    /// @notice Consumes close-path losses and routes any cash-collected protocol fee to a treasury account.
    /// @param account Account paying the close loss
    /// @param reservationOrderIds Active reservation ids that may cover close settlement
    /// @param lossUsdc USDC loss to collect
    /// @param protectedLockedMarginUsdc Active position margin protected from loss consumption
    /// @param includeOtherLockedMargin Whether committed/reserved locked buckets may be consumed
    /// @param recipient Recipient of seized USDC
    /// @param protocolFeeAccount Clearinghouse account receiving any protocol fee credit
    /// @param protocolFeeUsdc Protocol fee amount included in the close cost
    /// @return seizedUsdc USDC transferred to the recipient
    /// @return shortfallUsdc Loss left uncovered after available funds are exhausted
    /// @return protocolFeeCreditedUsdc Protocol fee credited to the treasury account
    function consumeCloseLoss(
        address account,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) external returns (uint256 seizedUsdc, uint256 shortfallUsdc, uint256 protocolFeeCreditedUsdc);

    /// @notice Applies a pre-planned liquidation settlement mutation while preserving reserved settlement.
    /// @param account Liquidated account
    /// @param reservationOrderIds Active reservation ids to release or consume during settlement
    /// @param plan Liquidation settlement plan computed by the engine planner
    /// @param recipient Pool recipient of seized USDC
    /// @param keeper Keeper credited with bounty settlement
    /// @param keeperBountyUsdc USDC bounty to credit to the keeper
    /// @return seizedUsdc USDC transferred to the recipient
    function applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        LiquidationSettlementPlan calldata plan,
        address recipient,
        address keeper,
        uint256 keeperBountyUsdc
    ) external returns (uint256 seizedUsdc);

    /// @notice Transfers already-reserved settlement from one account to another without moving tokens.
    /// @param account Account whose reserved settlement is transferred
    /// @param recipient Account receiving settlement credit
    /// @param amount Reserved settlement amount to transfer
    function transferReservedSettlement(
        address account,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Reserves free-settlement USDC for a close-order execution bounty with carry checkpointing.
    /// @dev Restricted to the engine's atomic fresh close-bounty path.
    /// @param account Account whose free settlement should be reserved
    /// @param amount USDC amount to reserve
    function reserveCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external;

    /// @notice Reserves free-settlement USDC for a stale close-order execution bounty without checkpointing carry.
    /// @dev Restricted to the engine's atomic stale close-bounty path.
    /// @param account Account whose free settlement should be reserved
    /// @param amount USDC amount to reserve
    function reserveStaleCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external;

    /// @notice Reclassifies active position margin into reserved settlement for a close-order execution bounty.
    /// @param account Account whose position margin should be reserved
    /// @param amount USDC amount to reserve
    function reserveCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount
    ) external;

    /// @notice Reserves active position margin for a stale close-order execution bounty without checkpointing carry.
    /// @dev Restricted to the engine's bounded stale close-bounty path.
    /// @param account Account whose position margin should be reserved
    /// @param amount USDC amount to reserve
    function reserveStaleCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount
    ) external;

    /// @notice Returns the explicit USDC bucket split after subtracting typed locked-margin buckets.
    /// @param account Account to inspect
    /// @return buckets Settlement, locked, and free USDC buckets
    function getAccountUsdcBuckets(
        address account
    ) external view returns (AccountUsdcBuckets memory buckets);

    /// @notice Returns total account equity in settlement USDC (6 decimals)
    /// @param account Account to inspect
    function getAccountEquityUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns strictly free buying power after subtracting locked margin (6 decimals)
    /// @param account Account to inspect
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice USDC-only cross-margin account system that holds settlement balances and settles PnL for CFD positions.
interface IMarginClearinghouse {

    enum MarginBucket {
        Position,
        CommittedOrder,
        ReservedSettlement
    }

    struct LockedMarginBuckets {
        uint256 positionMarginUsdc;
        uint256 committedOrderMarginUsdc;
        uint256 reservedSettlementUsdc;
        uint256 totalLockedMarginUsdc;
    }

    enum ReservationBucket {
        CommittedOrder,
        ReservedSettlement
    }

    enum ReservationStatus {
        None,
        Active,
        Consumed,
        Released
    }

    struct OrderReservation {
        bytes32 accountId;
        ReservationBucket bucket;
        ReservationStatus status;
        uint96 originalAmountUsdc;
        uint96 remainingAmountUsdc;
    }

    struct AccountReservationSummary {
        uint256 activeCommittedOrderMarginUsdc;
        uint256 activeReservedSettlementUsdc;
        uint256 activeReservationCount;
    }

    struct AccountUsdcBuckets {
        uint256 settlementBalanceUsdc;
        uint256 totalLockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
    }

    /// @notice Returns the settlement USDC balance for an account.
    function balanceUsdc(
        bytes32 accountId
    ) external view returns (uint256);
    /// @notice Returns the locked USDC margin for an account
    function lockedMarginUsdc(
        bytes32 accountId
    ) external view returns (uint256);
    /// @notice Returns the typed locked-margin buckets for an account.
    function getLockedMarginBuckets(
        bytes32 accountId
    ) external view returns (LockedMarginBuckets memory buckets);
    /// @notice Returns the reservation record for a specific order id.
    function getOrderReservation(
        uint64 orderId
    ) external view returns (OrderReservation memory reservation);
    /// @notice Returns the aggregate active reservation summary for an account.
    function getAccountReservationSummary(
        bytes32 accountId
    ) external view returns (AccountReservationSummary memory summary);
    /// @notice Locks trader-owned settlement into the active position margin bucket.
    function lockPositionMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks active position margin back into free settlement.
    function unlockPositionMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Locks trader-owned settlement into the committed-order bucket reserved for queued open orders.
    function lockCommittedOrderMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Reserves committed-order margin for a specific order id inside the clearinghouse reservation ledger.
    function reserveCommittedOrderMargin(
        bytes32 accountId,
        uint64 orderId,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks committed-order margin back into free settlement when a queued open order is released.
    function unlockCommittedOrderMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Releases any remaining reservation balance for an order back into free settlement.
    function releaseOrderReservation(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);
    /// @notice Consumes a specific amount from an order reservation, capped by its remaining balance.
    function consumeOrderReservation(
        uint64 orderId,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Consumes active order reservations for an account in FIFO reservation order.
    function consumeAccountOrderReservations(
        bytes32 accountId,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Consumes the supplied active order reservations in FIFO order until the requested amount is exhausted.
    function consumeOrderReservationsById(
        uint64[] calldata orderIds,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);
    /// @notice Locks settlement into a reserved bucket excluded from generic order/position margin release paths.
    function lockReservedSettlement(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Unlocks settlement from the reserved bucket back into free settlement.
    function unlockReservedSettlement(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Adjusts USDC balance for funding, PnL, or rebates (+credit, -debit)
    function settleUsdc(
        bytes32 accountId,
        int256 amount
    ) external;
    /// @notice Credits settlement USDC and locks the same amount as active margin.
    function creditSettlementAndLockMargin(
        bytes32 accountId,
        uint256 amountUsdc
    ) external;
    /// @notice Applies an open/increase trade cost by debiting or crediting settlement and updating locked margin.
    function applyOpenCost(
        bytes32 accountId,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient
    ) external returns (int256 netMarginChangeUsdc);
    /// @notice Consumes funding loss from free settlement plus the active position margin bucket.
    function consumeFundingLoss(
        bytes32 accountId,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc);
    /// @notice Consumes close-path losses from settlement buckets while preserving the remaining live position margin and reserved escrow.
    function consumeCloseLoss(
        bytes32 accountId,
        uint64[] calldata reservationOrderIds,
        uint256 lossUsdc,
        uint256 protectedLockedMarginUsdc,
        bool includeOtherLockedMargin,
        address recipient
    ) external returns (uint256 seizedUsdc, uint256 shortfallUsdc);
    /// @notice Settles liquidation residual against liquidation-reachable collateral while preserving reserved escrow.
    function consumeLiquidationResidual(
        bytes32 accountId,
        uint64[] calldata reservationOrderIds,
        uint256 lockedPositionMarginUsdc,
        int256 residualUsdc,
        address recipient
    ) external returns (uint256 seizedUsdc, uint256 payoutUsdc, uint256 badDebtUsdc);
    /// @notice Transfers settlement USDC from an account to a recipient (losses, fees, or bad debt)
    function seizeUsdc(
        bytes32 accountId,
        uint256 amount,
        address recipient
    ) external;
    function getAccountUsdcBuckets(
        bytes32 accountId
    ) external view returns (AccountUsdcBuckets memory buckets);
    /// @notice Returns total account equity in settlement USDC (6 decimals)
    function getAccountEquityUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns strictly free buying power after subtracting locked margin (6 decimals)
    function getFreeBuyingPowerUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns free settlement-asset balance after subtracting locked margin (6 decimals)
    function getFreeSettlementBalanceUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns settlement-asset balance reachable during a terminal settlement path.
    function getTerminalReachableUsdc(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns settlement-asset balance reachable for a terminal or partial settlement path.
    /// @dev Protects only the explicitly supplied remaining locked margin bucket and treats all
    ///      other settlement-asset balance as reachable for loss collection.
    function getSettlementReachableUsdc(
        bytes32 accountId,
        uint256 protectedLockedMarginUsdc
    ) external view returns (uint256);

}

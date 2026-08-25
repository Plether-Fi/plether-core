// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice USDC-only cross-margin account system that holds settlement balances and settles PnL for CFD positions.
/// @dev This is the full operator/integration surface.
///      Product-facing consumers should prefer `IMarginAccount` and avoid depending on
///      reservation buckets, internal custody buckets, or settlement-path helpers. Unless stated otherwise,
///      monetary amounts use the settlement token's native units, expected to be 6-decimal USDC.
interface IMarginClearinghouse {

    /// @notice The caller is not the engine or the engine-derived router or settlement sidecar required by the call.
    error MarginClearinghouse__NotOperator();
    /// @notice A user attempted to deposit to or withdraw from an account other than its own address.
    error MarginClearinghouse__NotAccountOwner();
    /// @notice An operation that requires a positive amount received zero.
    error MarginClearinghouse__ZeroAmount();
    /// @notice An account's settlement balance cannot cover a requested user withdrawal.
    error MarginClearinghouse__InsufficientBalance();
    /// @notice Unencumbered settlement cannot cover a new lock or the post-withdrawal locked-margin floor.
    error MarginClearinghouse__InsufficientFreeEquity();
    /// @notice An internal settlement debit exceeds balance, or a post-withdrawal balance cannot cover locked buckets.
    error MarginClearinghouse__InsufficientUsdcForSettlement();
    /// @notice Settlement custody or the required reserved bucket cannot cover an operator-directed debit.
    error MarginClearinghouse__InsufficientAssetToSeize();
    /// @notice An unsupported typed margin or reservation bucket was supplied.
    error MarginClearinghouse__InvalidMarginBucket();
    /// @notice The order id already has a reservation record, including a terminal record.
    error MarginClearinghouse__ReservationAlreadyExists();
    /// @notice The requested reservation does not exist or is no longer active.
    error MarginClearinghouse__ReservationNotActive();
    /// @notice Supplied reservation ids do not cover committed margin that a settlement plan consumes.
    error MarginClearinghouse__IncompleteReservationCoverage();
    /// @notice Aggregate committed-margin mutation was attempted while per-order reservations remain active.
    error MarginClearinghouse__ReservationLedgerActive();
    /// @notice The owner attempted to replace the one-time-configured engine.
    error MarginClearinghouse__EngineAlreadySet();
    /// @notice A required engine, recipient, or keeper address is zero.
    error MarginClearinghouse__ZeroAddress();
    /// @notice A typed locked-margin bucket cannot cover the requested exact decrease.
    error MarginClearinghouse__InsufficientBucketMargin();
    /// @notice A reservation amount cannot be represented by the reservation ledger's `uint96` fields.
    error MarginClearinghouse__AmountOverflow();
    /// @notice Planned action-reserve consumption does not match the currently spendable reserve after queued bounties.
    error MarginClearinghouse__ActionReserveMismatch();
    /// @notice A supplied reservation belongs to an account other than the risk-off refund target.
    error MarginClearinghouse__ReservationAccountMismatch(
        uint64 orderId, address expectedAccount, address actualAccount
    );

    /// @notice Canonical locked-margin bucket whose balance is being classified or mutated.
    enum MarginBucket {
        /// @notice Custody backing the account's live position.
        Position,
        /// @notice Margin committed to queued open/increase orders.
        CommittedOrder,
        /// @notice Settlement explicitly reserved for execution bounties or other protected settlement.
        ReservedSettlement,
        /// @notice Dedicated keeper/protocol liquidation-charge reserve, isolated from price PnL.
        LiquidationReserve
    }

    /// @notice Canonical V2 ownership split for one account's settlement custody.
    /// @dev Every locked bucket is a classification within `settlementBalanceUsdc`, not an additional asset.
    ///      Legacy `positionMarginUsdc`, `committedOrderMarginUsdc`, and `reservedSettlementUsdc` getters map to
    ///      `pnlPledgeUsdc`, `orderMarginUsdc`, and `actionReserveUsdc`, respectively.
    struct PnlIsolationBuckets {
        uint256 settlementBalanceUsdc;
        uint256 pnlPledgeUsdc;
        uint256 liquidationReserveUsdc;
        uint256 orderMarginUsdc;
        uint256 actionReserveUsdc;
        /// @notice Mandatory negative-lifetime-VPI floor contained inside `actionReserveUsdc` (not additive).
        uint256 vpiRebateReserveUsdc;
        uint256 totalLockedUsdc;
        uint256 freeSettlementUsdc;
    }

    /// @notice Legacy three-field locked-margin split for one clearinghouse account.
    /// @dev Prefer `PnlIsolationBuckets` for the canonical four-bucket view. The legacy named fields omit liquidation
    ///      reserve, while `totalLockedMarginUsdc` still includes it so free-equity calculations remain conservative.
    /// @param positionMarginUsdc Margin backing the active position.
    /// @param committedOrderMarginUsdc Aggregate margin backing active order reservations.
    /// @param reservedSettlementUsdc Settlement protected from generic order and position release paths.
    /// @param totalLockedMarginUsdc Sum of PnL pledge, liquidation reserve, order margin, and action reserve.
    struct LockedMarginBuckets {
        uint256 positionMarginUsdc;
        uint256 committedOrderMarginUsdc;
        uint256 reservedSettlementUsdc;
        uint256 totalLockedMarginUsdc;
    }

    /// @notice Reservation-ledger bucket encoded in an order reservation.
    enum ReservationBucket {
        /// @notice Margin committed to a queued open/increase order.
        CommittedOrder
    }

    /// @notice Lifecycle state of an order-specific committed-margin reservation.
    enum ReservationStatus {
        /// @notice No reservation has ever been created for the id.
        None,
        /// @notice The reservation has remaining committed margin.
        Active,
        /// @notice The reservation was fully consumed by settlement.
        Consumed,
        /// @notice The reservation's remainder was released to free settlement.
        Released
    }

    /// @notice Persistent committed-margin reservation for one router order id.
    /// @param account Account whose committed-order bucket backs the record.
    /// @param bucket Reservation bucket; currently always `CommittedOrder`.
    /// @param status Current reservation lifecycle status.
    /// @param originalAmountUsdc Amount locked when the reservation was created.
    /// @param remainingAmountUsdc Amount still available while the reservation is active.
    struct OrderReservation {
        address account;
        ReservationBucket bucket;
        ReservationStatus status;
        uint96 originalAmountUsdc;
        uint96 remainingAmountUsdc;
    }

    /// @notice Aggregate active committed-margin reservation state for one account.
    /// @param activeCommittedOrderMarginUsdc Sum of remaining active reservation amounts.
    /// @param activeReservationCount Number of active reservation records.
    struct AccountReservationSummary {
        uint256 activeCommittedOrderMarginUsdc;
        uint256 activeReservationCount;
    }

    /// @notice Clearinghouse custody split used by engine planning and account diagnostics.
    /// @param settlementBalanceUsdc Total internal settlement balance, including all locked value.
    /// @param totalLockedMarginUsdc Sum of all typed locked-margin buckets.
    /// @param activePositionMarginUsdc Active-position custody bucket.
    /// @param otherLockedMarginUsdc Sum of liquidation reserve, committed-order, and reserved-settlement buckets.
    /// @param freeSettlementUsdc Settlement balance above total locked margin, floored at zero.
    struct AccountUsdcBuckets {
        uint256 settlementBalanceUsdc;
        uint256 totalLockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
    }

    /// @notice Engine-planned bucket mutation for liquidation settlement.
    /// @dev All fields use 6-decimal USDC. The clearinghouse applies the unlock, debit, transfer, and bounty amounts;
    ///      `settlementRetainedUsdc`, `freshTraderPayoutUsdc`, and `badDebtUsdc` describe engine-side diagnostics.
    /// @param settlementRetainedUsdc Existing account settlement left in place toward positive residual equity;
    ///        informational to the clearinghouse mutation.
    /// @param settlementSeizedUsdc Settlement debited from the account and transferred to the pool recipient.
    /// @param freshTraderPayoutUsdc New surplus owed to the trader after liquidation.
    /// @param badDebtUsdc Compatibility diagnostic for uncollectible price loss; the clearinghouse does not store debt.
    /// @param positionMarginUnlockedUsdc Active-position margin to consume or release.
    /// @param otherLockedMarginUnlockedUsdc Committed-order margin to consume through supplied reservation ids.
    struct LiquidationSettlementPlan {
        uint256 settlementRetainedUsdc;
        uint256 settlementSeizedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 badDebtUsdc;
        uint256 positionMarginUnlockedUsdc;
        uint256 otherLockedMarginUnlockedUsdc;
    }

    /// @notice Returns the settlement USDC balance for an account.
    /// @dev This clearinghouse-local balance excludes unrealized PnL and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Account settlement balance in USDC
    function balanceUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns total locked margin across all four canonical isolation buckets.
    /// @param account Account to inspect
    /// @return Total locked margin in USDC
    function lockedMarginUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns the typed locked-margin buckets for an account.
    /// @param account Account to inspect
    /// @return buckets Legacy named fields plus a total that also includes the omitted liquidation reserve
    function getLockedMarginBuckets(
        address account
    ) external view returns (LockedMarginBuckets memory buckets);

    /// @notice Returns the canonical PnL-isolated settlement split.
    function getPnlIsolationBuckets(
        address account
    ) external view returns (PnlIsolationBuckets memory buckets);

    /// @notice Trader-owned collateral explicitly pledged to position price PnL.
    function pnlPledgeUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Settlement reserved exclusively for keeper/protocol liquidation charges.
    function liquidationReserveUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Pending-order margin excluded from live-position price PnL.
    function orderMarginUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Settlement reserved for action charges and execution bounties, never position price PnL.
    function actionReserveUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Nonwithdrawable negative-lifetime-VPI backing contained inside the action-reserve bucket.
    function vpiRebateReserveUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns the reservation record for a specific order id.
    /// @param orderId Order reservation id to inspect
    /// @return reservation Persistent reservation record; unknown ids return a zero-valued record
    function getOrderReservation(
        uint64 orderId
    ) external view returns (OrderReservation memory reservation);

    /// @notice Returns the aggregate active reservation summary for an account.
    /// @param account Account to inspect
    /// @return summary Active committed-order margin in USDC and active record count
    function getAccountReservationSummary(
        address account
    ) external view returns (AccountReservationSummary memory summary);

    /// @notice Locks trader-owned settlement into the active position margin bucket.
    /// @dev Callable only by the engine or its reported settlement sidecar. No tokens move and the settlement balance
    ///      is unchanged. This low-level settlement hook does not checkpoint carry.
    /// @param account Account whose settlement should be locked
    /// @param amountUsdc USDC amount to lock
    function lockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks active position margin back into free settlement.
    /// @dev Callable only by the engine or its reported settlement sidecar. Reverts rather than clamping on bucket
    ///      underflow; no tokens move and the settlement balance is unchanged.
    /// @param account Account whose position margin should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockPositionMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Locks trader-owned settlement into the committed-order bucket reserved for queued open orders.
    /// @dev Legacy aggregate path callable only by the engine or settlement sidecar. It checkpoints carry and reverts
    ///      while the account has active per-order reservations. No tokens move.
    /// @param account Account whose settlement should be locked
    /// @param amountUsdc USDC amount to lock
    function lockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Reserves committed-order margin for a specific order id inside the clearinghouse reservation ledger.
    /// @dev Callable only by the engine or its reported router. Checkpoints carry, requires a unique id and positive
    ///      amount that fits `uint96`, and reclassifies free settlement without moving tokens.
    /// @param account Account whose committed-order margin backs the reservation
    /// @param orderId Router order id receiving the reservation
    /// @param amountUsdc USDC amount to reserve
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks committed-order margin back into free settlement when a queued open order is released.
    /// @dev Legacy aggregate path callable only by the engine or settlement sidecar. It checkpoints carry and reverts
    ///      while active per-order reservations exist or when the bucket cannot cover the exact amount.
    /// @param account Account whose committed-order margin should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockCommittedOrderMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Releases any remaining reservation balance for an order back into free settlement.
    /// @dev Callable only by the engine or settlement sidecar. Checkpoints account carry, marks the reservation
    ///      `Released`, and changes locked classification without moving tokens or changing settlement balance.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc Entire remaining reservation amount released in USDC
    function releaseOrderReservation(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);

    /// @notice Releases any remaining reservation balance for an order if it is still active.
    /// @dev Callable only by the engine or reported router. An unknown or terminal id returns zero without mutation.
    /// @param orderId Order reservation id to release
    /// @return releasedUsdc Remaining reservation amount released in USDC, or zero when not active
    function releaseOrderReservationIfActive(
        uint64 orderId
    ) external returns (uint256 releasedUsdc);

    /// @notice Releases risk-off order margin and its execution bounty back to an account's free settlement.
    /// @dev Callable only by the Engine-reported order router. Unknown and terminal reservations are skipped, but
    ///      every existing supplied reservation must belong to `account`. This path deliberately does not checkpoint
    ///      carry or move settlement tokens. The exact bounty unlock must preserve negative-VPI backing and every
    ///      execution bounty that the router still reports as live.
    /// @param account Account receiving the released margin classifications
    /// @param orderIds Order reservation ids invalidated by the risk-off cutoff
    /// @param executionBountyUsdc Exact invalidated execution bounty to unlock from reserved settlement
    /// @return releasedMarginUsdc Aggregate remaining committed-order margin released
    function releaseInvalidatedOrderReserves(
        address account,
        uint64[] calldata orderIds,
        uint256 executionBountyUsdc
    ) external returns (uint256 releasedMarginUsdc);

    /// @notice Consumes a specific amount from an order reservation, capped by its remaining balance.
    /// @dev Callable only by the engine or settlement sidecar. Decreases committed-order locked classification and
    ///      reservation aggregates without debiting settlement balance or transferring tokens.
    /// @param orderId Order reservation id to consume
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc Amount consumed in USDC, capped by the reservation remainder
    function consumeOrderReservation(
        uint64 orderId,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Atomically promotes exact pending-order margin into live-position PnL pledge.
    function promoteOrderReservationToPnlPledge(
        uint64 orderId,
        uint256 amountUsdc
    ) external;

    /// @notice Consumes active order reservations for an account in FIFO reservation order.
    /// @dev Callable only by the engine or settlement sidecar. The configured router supplies the id order; inactive
    ///      records are skipped, no tokens move, and the returned amount can be below the request.
    /// @param account Account whose active reservations should be consumed
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc Aggregate amount consumed in USDC
    function consumeAccountOrderReservations(
        address account,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Consumes the supplied active order reservations in FIFO order until the requested amount is exhausted.
    /// @dev Callable only by the engine or settlement sidecar. Inactive ids are skipped and ids need not share an
    ///      account. Locked classification changes, but settlement balances and token custody do not.
    /// @param orderIds Reservation order ids to consume in supplied order
    /// @param amountUsdc Requested USDC amount to consume
    /// @return consumedUsdc Aggregate amount consumed in USDC, which can be below `amountUsdc`
    function consumeOrderReservationsById(
        uint64[] calldata orderIds,
        uint256 amountUsdc
    ) external returns (uint256 consumedUsdc);

    /// @notice Locks settlement into a reserved bucket excluded from generic order/position margin release paths.
    /// @dev Callable only by the engine or reported router. Checkpoints carry and reclassifies free settlement without
    ///      moving tokens or changing the total settlement balance.
    /// @param account Account whose settlement should be reserved
    /// @param amountUsdc USDC amount to lock as reserved settlement
    function lockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Unlocks settlement from the reserved bucket back into free settlement.
    /// @dev Callable only by the engine or settlement sidecar. Checkpoints carry and reverts rather than clamping on
    ///      bucket underflow; no tokens move.
    /// @param account Account whose reserved settlement should be unlocked
    /// @param amountUsdc USDC amount to unlock
    function unlockReservedSettlement(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Adjusts settlement USDC for realized PnL, trader claim settlement, or rebates (+credit, -debit).
    /// @dev Callable only by the engine or settlement sidecar. Mutates internal accounting only: it neither transfers
    ///      tokens nor changes locked buckets, and a negative delta cannot exceed the settlement balance.
    /// @param account Account to settle
    /// @param amount Signed USDC delta: positive credits, negative debits
    function settleUsdc(
        address account,
        int256 amount
    ) external;

    /// @notice Credits settlement USDC and locks the same amount as active margin.
    /// @dev Callable only by the engine or settlement sidecar. This accounting-only operation does not transfer tokens
    ///      or checkpoint carry; zero is a no-op.
    /// @param account Account receiving the settlement credit and position margin lock
    /// @param amountUsdc USDC amount to credit and lock
    function creditSettlementAndLockMargin(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Credits newly arrived settlement and atomically classifies it as PnL pledge.
    /// @dev Used when a live-position trader claim is paid into clearinghouse custody. The caller is responsible for
    ///      ensuring the corresponding settlement tokens have already arrived.
    function creditPnlPledge(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Locks free settlement into the liquidation-charge reserve.
    function lockLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Releases liquidation reserve back to free settlement without moving tokens.
    function releaseLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Reclassifies existing PnL pledge as liquidation reserve without changing total locked settlement.
    function reclassifyPnlPledgeToLiquidationReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Reclassifies liquidation reserve as PnL pledge without changing total locked settlement.
    function reclassifyLiquidationReserveToPnlPledge(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Locks free settlement into the action-charge reserve.
    function lockActionReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Releases action reserve back to free settlement without moving tokens.
    function releaseActionReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Transfers action-reserved settlement to a clearinghouse recipient.
    function consumeActionReserve(
        address account,
        address recipient,
        uint256 amountUsdc
    ) external;

    /// @notice Locks free settlement into both action reserve and its mandatory negative-VPI sub-ledger.
    function lockVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Reclassifies newly added PnL pledge into the negative-VPI action-reserve sub-ledger.
    function reclassifyPnlPledgeToVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Releases no-longer-required negative-VPI backing to free settlement.
    function releaseVpiRebateReserve(
        address account,
        uint256 amountUsdc
    ) external;

    /// @notice Debits negative-VPI backing and transfers the recovered cash to the LP pool.
    function consumeVpiRebateReserve(
        address account,
        address recipient,
        uint256 amountUsdc
    ) external;

    /// @notice Collects an action charge from spendable action reserve, free settlement, then committed order margin.
    /// @dev PnL pledge, liquidation reserve, negative-VPI backing, and pending execution bounties are never reachable.
    ///      Both expected-source arguments must exactly match the split implied by current state; this makes a stale or
    ///      incorrect settlement plan revert. Committed margin is consumed through the router-reported FIFO reservation
    ///      ledger. Collection is capped by eligible value, so callers may treat the remainder as waived.
    /// @param account Account paying the charge
    /// @param chargeUsdc Maximum action charge to collect
    /// @param actionReserveConsumedUsdc Exact spendable action reserve the settlement plan expects to consume
    /// @param actionCommittedMarginConsumedUsdc Exact committed order margin the plan expects to consume after free
    /// @param recipient External recipient of the non-protocol portion
    /// @param protocolTreasury Clearinghouse account credited with the protocol portion; zero disables the credit
    /// @param protocolFeeUsdc Requested protocol portion, capped by the amount collected
    /// @return collectedUsdc Action reserve plus free settlement actually collected
    /// @return protocolFeeCreditedUsdc Collected amount credited internally to `protocolTreasury`
    function consumeActionCharge(
        address account,
        uint256 chargeUsdc,
        uint256 actionReserveConsumedUsdc,
        uint256 actionCommittedMarginConsumedUsdc,
        address recipient,
        address protocolTreasury,
        uint256 protocolFeeUsdc
    ) external returns (uint256 collectedUsdc, uint256 protocolFeeCreditedUsdc);

    /// @notice Applies an open/increase trade cost and routes any cash-collected protocol fee to a treasury account.
    /// @dev Callable only by the engine or settlement sidecar. Positive cost debits settlement; negative cost credits
    ///      a rebate. The non-fee debit is transferred to `recipient`, while the fee portion remains in clearinghouse
    ///      custody as an internal credit to `protocolFeeAccount`.
    /// @param account Account whose settlement/margin pays or receives the open cost
    /// @param marginDeltaUsdc Margin supplied with the order, in USDC
    /// @param tradeCostUsdc Signed VPI-plus-fee cost in USDC; positive debits and negative rebates
    /// @param recipient External pool recipient for the non-fee cash debit
    /// @param protocolFeeAccount Clearinghouse account receiving the protocol-fee credit; zero disables the credit
    /// @param protocolFeeUsdc Protocol-fee portion included in `tradeCostUsdc`, in USDC
    /// @return netMarginChangeUsdc Signed change applied to active position margin, in USDC
    /// @return protocolFeeCreditedUsdc Fee portion credited internally to `protocolFeeAccount`, in USDC
    function applyOpenCost(
        address account,
        uint256 marginDeltaUsdc,
        int256 tradeCostUsdc,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc
    ) external returns (int256 netMarginChangeUsdc, uint256 protocolFeeCreditedUsdc);

    /// @notice Consumes a non-price settlement charge from free settlement only.
    /// @dev Callable only by the engine or settlement sidecar. The legacy `lockedPositionMarginUsdc` argument is
    ///      ignored. PnL pledge and every reserve bucket remain protected; any uncovered amount is waived.
    /// @param account Account paying the loss
    /// @param lockedPositionMarginUsdc Deprecated ABI parameter ignored by the implementation
    /// @param lossUsdc Maximum loss to collect in USDC
    /// @param recipient External recipient of collected USDC
    /// @return marginConsumedUsdc Always zero under PnL-isolated accounting
    /// @return freeSettlementConsumedUsdc Free settlement consumed in USDC
    /// @return uncoveredUsdc Requested loss left uncovered in USDC
    function consumeSettlementLoss(
        address account,
        uint256 lockedPositionMarginUsdc,
        uint256 lossUsdc,
        address recipient
    ) external returns (uint256 marginConsumedUsdc, uint256 freeSettlementConsumedUsdc, uint256 uncoveredUsdc);

    /// @notice Collects terminal position price loss from PnL pledge only.
    /// @dev Free settlement and every reserve bucket are excluded so settlement matches the NAV book's collateral cap.
    function consumePnlPledgeLoss(
        address account,
        uint256 priceLossUsdc,
        address recipient
    ) external returns (uint256 consumedUsdc, uint256 shortfallUsdc);

    /// @notice Legacy partial-close entrypoint that collects price loss from PnL pledge only.
    /// @dev `reservationOrderIds`, `includeOtherLockedMargin`, and `protocolFeeAccount` are ignored. A nonzero protocol
    ///      fee reverts because action fees must use `consumeActionCharge`. `protectedLockedMarginUsdc` preserves the
    ///      residual position's pledge, so callers must collect before unlocking unused closed-lot pledge.
    /// @param account Account paying the close loss
    /// @param reservationOrderIds Deprecated and ignored
    /// @param lossUsdc Maximum loss to collect in USDC
    /// @param protectedLockedMarginUsdc Active position margin that must remain protected, in USDC
    /// @param includeOtherLockedMargin Deprecated and ignored
    /// @param recipient External recipient of collected price-loss cash
    /// @param protocolFeeAccount Deprecated and ignored
    /// @param protocolFeeUsdc Must be zero
    /// @return seizedUsdc PnL pledge collected and transferred, in USDC
    /// @return shortfallUsdc Requested loss left uncovered in USDC
    /// @return protocolFeeCreditedUsdc Always zero
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

    /// @notice Applies isolated full-liquidation price-PnL and charge settlement.
    /// @dev Price seizure consumes PnL pledge only. Keeper, protocol, and LP liquidation fees consume liquidation
    ///      reserve only. Order margin, action reserve, and free settlement are never charge or price-loss sources.
    /// @param account Liquidated account
    /// @param reservationOrderIds Active ids allowed to cover committed-order margin consumption
    /// @param plan Engine-planned liquidation amounts, all in USDC
    /// @param recipient External pool recipient of `plan.settlementSeizedUsdc`
    /// @param keeper Clearinghouse account credited with the bounty
    /// @param keeperBountyUsdc Bounty debited from `account` and credited to `keeper`, in USDC
    /// @param protocolFeeAccount Clearinghouse account credited with the liquidation protocol fee
    /// @param protocolFeeUsdc Protocol fee debited from `account` and credited internally, in USDC
    /// @param lpLiquidationFeeUsdc LP fee included in `plan.settlementSeizedUsdc`, in USDC
    /// @return seizedUsdc Amount transferred to `recipient` in USDC
    function applyLiquidationSettlementPlan(
        address account,
        uint64[] calldata reservationOrderIds,
        LiquidationSettlementPlan calldata plan,
        address recipient,
        address keeper,
        uint256 keeperBountyUsdc,
        address protocolFeeAccount,
        uint256 protocolFeeUsdc,
        uint256 lpLiquidationFeeUsdc
    ) external returns (uint256 seizedUsdc);

    /// @notice Transfers already-reserved settlement from one account to another without moving tokens.
    /// @dev Callable only by the engine. Decreases both the source reserved bucket and source settlement balance,
    ///      then credits the recipient's internal settlement balance. The recipient must be nonzero even for zero.
    /// @param account Account whose reserved settlement is transferred
    /// @param recipient Account receiving settlement credit
    /// @param amount Reserved settlement amount to transfer in USDC
    function transferReservedSettlement(
        address account,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Reserves free-settlement USDC for a fresh close-order execution bounty after engine checkpointing.
    /// @dev Callable only by the engine or its bound settlement sidecar on the atomic fresh close-bounty path. This
    ///      hook does not call back into the engine because carry was already checkpointed in the active accounting
    ///      mutation. No tokens move.
    /// @param account Account whose free settlement should be reserved
    /// @param amount USDC amount to reserve
    function reserveCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external;

    /// @notice Reserves free-settlement USDC for a stale close-order execution bounty without checkpointing carry.
    /// @dev Callable only by the engine or its bound settlement sidecar on the bounded stale close-bounty path. No
    ///      tokens move.
    /// @param account Account whose free settlement should be reserved
    /// @param amount USDC amount to reserve
    function reserveStaleCloseExecutionBountyFromSettlement(
        address account,
        uint256 amount
    ) external;

    /// @notice Retired position-margin close-bounty selector retained as an explicit reverting tombstone.
    /// @dev V2 close bounties must be backed exclusively by free settlement; every call reverts.
    /// @param account Ignored legacy account argument
    /// @param amount Ignored legacy amount argument
    function reserveCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount
    ) external;

    /// @notice Retired stale position-margin close-bounty selector retained as an explicit reverting tombstone.
    /// @dev V2 stale close bounties must also be backed exclusively by free settlement; every call reverts.
    /// @param account Ignored legacy account argument
    /// @param amount Ignored legacy amount argument
    function reserveStaleCloseExecutionBountyFromPositionMargin(
        address account,
        uint256 amount
    ) external;

    /// @notice Returns the explicit USDC bucket split after subtracting typed locked-margin buckets.
    /// @dev This clearinghouse-local view excludes unrealized PnL, trader claims, and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return buckets Settlement, typed locked, and free USDC buckets
    function getAccountUsdcBuckets(
        address account
    ) external view returns (AccountUsdcBuckets memory buckets);

    /// @notice Returns the account's internal settlement balance.
    /// @dev Despite the legacy name, this excludes unrealized PnL and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Settlement balance in USDC
    function getAccountEquityUsdc(
        address account
    ) external view returns (uint256);

    /// @notice Returns settlement balance above total typed locked margin, floored at zero.
    /// @dev Excludes unrealized PnL and engine withdrawal constraints.
    /// @param account Account to inspect
    /// @return Unencumbered settlement balance in USDC
    function getFreeBuyingPowerUsdc(
        address account
    ) external view returns (uint256);

}

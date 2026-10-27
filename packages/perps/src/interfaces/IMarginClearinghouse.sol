// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice settlement token-only cross-margin account system that holds settlement balances and settles PnL for CFD positions.
/// @dev This is the full operator/integration surface.
///      Product-facing consumers should prefer `IMarginAccount` and avoid depending on
///      reservation buckets, internal custody buckets, or settlement-path helpers. Unless stated otherwise,
///      monetary amounts use the settlement token's native units, expected to be 6-decimal settlement token.
interface IMarginClearinghouse {

    function unlockCloseMargin(
        address account,
        uint256 safeRelease,
        uint256 fromReleased,
        uint256 netRelease,
        uint256 cashChargeAfterVpi,
        uint256 vpiRelease
    ) external;
    /// @notice The caller is not the engine or the engine-derived router or settlement sidecar required by the call.
    error MarginClearinghouse__NotOperator();
    /// @notice A legacy owner-authenticated deposit or withdrawal named an account other than the caller.
    error MarginClearinghouse__NotAccountOwner();
    /// @notice An operation that requires a positive amount received zero.
    error MarginClearinghouse__ZeroAmount();
    /// @notice The settlement token delivered a different amount than requested by a third-party deposit.
    error MarginClearinghouse__UnexpectedTransferAmount(uint256 expected, uint256 received);
    /// @notice An account's settlement balance cannot cover a requested user withdrawal.
    error MarginClearinghouse__InsufficientBalance();
    /// @notice Unencumbered settlement cannot cover a new lock or the post-withdrawal locked-margin floor.
    error MarginClearinghouse__InsufficientFreeEquity();
    /// @notice An internal settlement debit exceeds balance, or a post-withdrawal balance cannot cover locked buckets.
    error MarginClearinghouse__InsufficientAssetsForSettlement();
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
    /// @notice A supplied reservation belongs to an account other than the expected account.
    error MarginClearinghouse__ReservationAccountMismatch(
        uint64 orderId, address expectedAccount, address actualAccount
    );

    /// @notice Identifies the payer of a credit-only deposit; the matching `Deposit` event records the same credit.
    /// @dev This metadata event is not an additional settlement credit.
    event DepositFor(address indexed payer, address indexed account, uint256 amount);

    /// @notice Pulls the caller's settlement token and credits the beneficiary's free settlement, without recipient authorization.
    /// @dev Rejects zero account/amount and inexact token receipt. Does not checkpoint carry or allocate position
    ///      margin. Existing carry remains due, and only the credited account retains trading/withdrawal authority.
    function depositFor(
        address account,
        uint256 amount
    ) external;

    /// @notice Owner namespace for keeper-bounty reservations; ids are unique within each namespace.
    enum BountyKind {
        Order,
        ProtectionTrigger
    }

    struct BountyRecovery {
        uint256 freeAssets;
        uint8 discrepancy;
    }
    function recoverExpiredBounty(
        address account,
        uint64 orderId,
        uint256 expectedFreeAssets
    ) external returns (BountyRecovery memory);
    enum BountyReservationState {
        None,
        Active,
        Settled,
        Moved,
        Quarantined
    }

    struct BountyReservation {
        address account;
        uint96 amountAssets;
        BountyReservationState state;
        uint96 freeFundedAssets;
    }
    function validateBountyReservation(
        address account,
        BountyKind kind,
        uint64 id,
        uint256 entitlementAssets
    ) external view;

    /// @notice Classifies already-locked action reserve. Orders are Router-owned; protection records are Book-owned.
    function recordBountyReservation(
        address account,
        BountyKind kind,
        uint64 id,
        uint256 amountAssets
    ) external;

    /// @notice Removes one exact bounty classification before its authorized payout/refund. No custody moves.
    function takeBountyReservation(
        address account,
        BountyKind kind,
        uint64 id
    ) external returns (uint256 amountAssets);

    function getBountyReservation(
        BountyKind kind,
        uint64 id
    ) external view returns (BountyReservation memory);
    function totalBountyReservationsAssets(
        address account
    ) external view returns (uint256);
    function getMarginReservationIds(
        address account
    ) external view returns (uint64[] memory);
    function marginReservationHead(
        address account
    ) external view returns (uint64);
    function marginReservationTail(
        address account
    ) external view returns (uint64);

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

    /// @notice Canonical V3 ownership split for one account's settlement custody.
    /// @dev Every locked bucket is a classification within `settlementBalanceAssets`, not an additional asset.
    ///      Legacy `positionMarginAssets`, `committedOrderMarginAssets`, and `reservedSettlementAssets` getters map to
    ///      `pnlPledgeAssets`, `orderMarginAssets`, and `actionReserveAssets`, respectively.
    struct PnlIsolationBuckets {
        uint256 settlementBalanceAssets;
        uint256 pnlPledgeAssets;
        uint256 liquidationReserveAssets;
        uint256 orderMarginAssets;
        uint256 actionReserveAssets;
        /// @notice Mandatory negative-lifetime-VPI floor contained inside `actionReserveAssets` (not additive).
        uint256 vpiRebateReserveAssets;
        uint256 totalLockedAssets;
        uint256 freeSettlementAssets;
    }

    /// @notice Legacy three-field locked-margin split for one clearinghouse account.
    /// @dev Prefer `PnlIsolationBuckets` for the canonical four-bucket view. The legacy named fields omit liquidation
    ///      reserve, while `totalLockedMarginAssets` still includes it so free-equity calculations remain conservative.
    /// @param positionMarginAssets Margin backing the active position.
    /// @param committedOrderMarginAssets Aggregate margin backing active order reservations.
    /// @param reservedSettlementAssets Settlement protected from generic order and position release paths.
    /// @param totalLockedMarginAssets Sum of PnL pledge, liquidation reserve, order margin, and action reserve.
    struct LockedMarginBuckets {
        uint256 positionMarginAssets;
        uint256 committedOrderMarginAssets;
        uint256 reservedSettlementAssets;
        uint256 totalLockedMarginAssets;
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
    /// @param originalAmountAssets Amount locked when the reservation was created.
    /// @param remainingAmountAssets Amount still available while the reservation is active.
    /// @param previousOrderId Previous active committed-margin reservation for the account, or zero at the head.
    /// @param nextOrderId Next active committed-margin reservation for the account, or zero at the tail.
    struct OrderReservation {
        address account;
        uint96 originalAmountAssets;
        uint96 remainingAmountAssets;
        uint64 previousOrderId;
        uint64 nextOrderId;
        ReservationBucket bucket;
        ReservationStatus status;
    }

    /// @notice Aggregate active committed-margin reservation state for one account.
    /// @param activeCommittedOrderMarginAssets Sum of remaining active reservation amounts.
    /// @param activeReservationCount Number of active reservation records.
    struct AccountReservationSummary {
        uint256 activeCommittedOrderMarginAssets;
        uint256 activeReservationCount;
    }

    /// @notice Clearinghouse custody split used by engine planning and account diagnostics.
    /// @param settlementBalanceAssets Total internal settlement balance, including all locked value.
    /// @param totalLockedMarginAssets Sum of all typed locked-margin buckets.
    /// @param activePositionMarginAssets Active-position custody bucket.
    /// @param otherLockedMarginAssets Sum of liquidation reserve, committed-order, and reserved-settlement buckets.
    /// @param freeSettlementAssets Settlement balance above total locked margin, floored at zero.
    struct AccountAssetBuckets {
        uint256 settlementBalanceAssets;
        uint256 totalLockedMarginAssets;
        uint256 activePositionMarginAssets;
        uint256 otherLockedMarginAssets;
        uint256 freeSettlementAssets;
    }

    /// @notice Engine-planned bucket mutation for liquidation settlement.
    /// @dev All fields use 6-decimal settlement token. The clearinghouse applies the unlock, debit, transfer, and bounty amounts.
    /// @param settlementSeizedAssets Settlement debited from the account and transferred to the pool recipient.
    /// @param positionMarginUnlockedAssets Active-position margin to consume or release.
    /// @param otherLockedMarginUnlockedAssets Must be zero; this isolated liquidation plan cannot consume committed orders.
    struct LiquidationSettlementPlan {
        uint256 settlementSeizedAssets;
        uint256 positionMarginUnlockedAssets;
        uint256 otherLockedMarginUnlockedAssets;
    }

    /// @notice Returns the settlement settlement token balance for an account.
    /// @dev This clearinghouse-local balance excludes unrealized PnL and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Account settlement balance in settlement token
    function balanceAssets(
        address account
    ) external view returns (uint256);

    /// @notice Returns total locked margin across all four canonical isolation buckets.
    /// @param account Account to inspect
    /// @return Total locked margin in settlement token
    function lockedMarginAssets(
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
    function pnlPledgeAssets(
        address account
    ) external view returns (uint256);

    /// @notice Settlement reserved exclusively for keeper/protocol liquidation charges.
    function liquidationReserveAssets(
        address account
    ) external view returns (uint256);

    /// @notice Pending-order margin excluded from live-position price PnL.
    function orderMarginAssets(
        address account
    ) external view returns (uint256);

    /// @notice Settlement reserved for action charges and execution bounties, never position price PnL.
    function actionReserveAssets(
        address account
    ) external view returns (uint256);

    /// @notice Nonwithdrawable negative-lifetime-VPI backing contained inside the action-reserve bucket.
    function vpiRebateReserveAssets(
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
    /// @return summary Active committed-order margin in settlement token and active record count
    function getAccountReservationSummary(
        address account
    ) external view returns (AccountReservationSummary memory summary);

    /// @notice Locks trader-owned settlement into the active position margin bucket.
    /// @dev Callable only by the engine or its reported settlement sidecar. No tokens move and the settlement balance
    ///      is unchanged. This low-level settlement hook does not checkpoint carry.
    /// @param account Account whose settlement should be locked
    /// @param amountAssets settlement token amount to lock
    function lockPositionMargin(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Unlocks active position margin back into free settlement.
    /// @dev Callable only by the engine or its reported settlement sidecar. Reverts rather than clamping on bucket
    ///      underflow; no tokens move and the settlement balance is unchanged.
    /// @param account Account whose position margin should be unlocked
    /// @param amountAssets settlement token amount to unlock
    function unlockPositionMargin(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Reserves committed-order margin for a specific order id inside the clearinghouse reservation ledger.
    /// @dev Callable only by the engine or its reported router. Checkpoints carry, requires a unique id and positive
    ///      amount that fits `uint96`, and reclassifies free settlement without moving tokens.
    /// @param account Account whose committed-order margin backs the reservation
    /// @param orderId Router order id receiving the reservation
    /// @param amountAssets settlement token amount to reserve
    function reserveCommittedOrderMargin(
        address account,
        uint64 orderId,
        uint256 amountAssets
    ) external;

    /// @notice Releases an order reservation during terminal Router cleanup if it remains active.
    /// @dev Callable only by the Engine-reported Router. Unknown and terminal ids return zero. This path deliberately
    ///      does not checkpoint carry, change settlement balance, or move tokens.
    /// @param orderId Order reservation id to release
    /// @return releasedAssets Remaining reservation amount released in settlement token, or zero when not active
    function releaseOrderReservationForTerminalCleanup(
        uint64 orderId
    ) external returns (uint256 releasedAssets);

    /// @notice Releases risk-off order margin and refundable bounties back to an account's free settlement.
    /// @dev Callable only by the Engine-reported order router. Unknown and terminal reservations are skipped, but
    ///      every existing supplied reservation must belong to `account`. This path deliberately does not checkpoint
    ///      carry or move settlement tokens. The exact bounty unlock must preserve negative-VPI backing and every
    ///      order or protection bounty still classified in the clearinghouse ledger.
    /// @param account Account receiving the released margin classifications
    /// @param orderIds Order reservation ids invalidated by the risk-off cutoff
    /// @param refundableBountyAssets Exact invalidated order and attached-protection bounties to unlock
    /// @return releasedMarginAssets Aggregate remaining committed-order margin released
    function releaseInvalidatedOrderReserves(
        address account,
        uint64[] calldata orderIds,
        uint256 refundableBountyAssets
    ) external returns (uint256 releasedMarginAssets);

    /// @notice Releases one consumed order or protection-trigger bounty classification back to its source account.
    /// @dev Callable only by the Engine-reported Router. This self-executor path deliberately skips carry
    ///      checkpointing because settlement custody does not change and the bounty returns to its source. Atomic
    ///      protection cancellation uses it before ordinary bounded close commitment collects and records carry.
    /// @param account Account whose reserved bounty becomes free settlement.
    /// @param executionBountyAssets Exact bounty classification to release.
    function releaseReservedExecutionBountyToSource(
        address account,
        uint256 executionBountyAssets
    ) external;

    /// @notice Locks settlement into a reserved bucket excluded from generic order/position margin release paths.
    /// @dev Callable only by the engine, its reported router, or the router's immutable position-protection book.
    ///      Checkpoints carry and reclassifies free settlement without moving tokens or changing the total settlement
    ///      balance.
    /// @param account Account whose settlement should be reserved
    /// @param amountAssets settlement token amount to lock as reserved settlement
    function lockReservedSettlement(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Unlocks settlement from the reserved bucket back into free settlement.
    /// @dev Callable only by the engine, its reported router or settlement sidecar, or the router's immutable
    ///      position-protection book. Checkpoints carry and reverts rather than clamping on bucket underflow; no tokens
    ///      move.
    /// @param account Account whose reserved settlement should be unlocked
    /// @param amountAssets settlement token amount to unlock
    function unlockReservedSettlement(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Adjusts settlement settlement token for realized PnL, trader claim settlement, or rebates (+credit, -debit).
    /// @dev Callable only by the engine or settlement sidecar. Mutates internal accounting only: it neither transfers
    ///      tokens nor changes locked buckets, and a negative delta cannot exceed free settlement above all locked
    ///      buckets. Zero is a no-op; this hook does not checkpoint carry.
    /// @param account Account to settle
    /// @param amount Signed settlement token delta: positive credits, negative debits
    function settleAssets(
        address account,
        int256 amount
    ) external;

    /// @notice Credits newly arrived settlement and atomically classifies it as PnL pledge.
    /// @dev Used when a live-position trader claim is paid into clearinghouse custody. The caller is responsible for
    ///      ensuring the corresponding settlement tokens have already arrived.
    function creditPnlPledge(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Releases liquidation reserve back to free settlement without moving tokens.
    function releaseLiquidationReserve(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Reclassifies existing PnL pledge as liquidation reserve without changing total locked settlement.
    function reclassifyPnlPledgeToLiquidationReserve(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Locks free settlement into both action reserve and its mandatory negative-VPI sub-ledger.
    function lockVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Reclassifies newly added PnL pledge into the negative-VPI action-reserve sub-ledger.
    function reclassifyPnlPledgeToVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Releases no-longer-required negative-VPI backing to free settlement.
    function releaseVpiRebateReserve(
        address account,
        uint256 amountAssets
    ) external;

    /// @notice Debits negative-VPI backing and transfers the recovered cash to the LP pool.
    function consumeVpiRebateReserve(
        address account,
        address recipient,
        uint256 amountAssets
    ) external;

    /// @notice Collects an action charge from spendable action reserve, free settlement, then committed order margin.
    /// @dev Locked PnL pledge, liquidation reserve, negative-VPI backing, and pending execution bounties are never
    ///      reachable here. Full closes release surplus pledge and liquidation reserve into free settlement first.
    ///      Both expected-source arguments must exactly match the split implied by current state; this makes a stale or
    ///      incorrect settlement plan revert. Committed margin is consumed through the clearinghouse-owned FIFO reservation
    ///      ledger. Collection is capped by eligible value, so callers may treat the remainder as waived.
    /// @param account Account paying the charge
    /// @param chargeAssets Maximum action charge to collect
    /// @param actionReserveConsumedAssets Exact spendable action reserve the settlement plan expects to consume
    /// @param actionCommittedMarginConsumedAssets Exact committed order margin the plan expects to consume after free settlement
    /// @param recipient External recipient of the non-protocol portion
    /// @param protocolTreasury Clearinghouse account credited with the protocol portion; zero disables the credit
    /// @param protocolFeeAssets Requested protocol portion, capped by the amount collected
    /// @return collectedAssets Action reserve, free settlement, and committed order margin actually collected
    /// @return protocolFeeCreditedAssets Collected amount credited internally to `protocolTreasury`
    function consumeActionCharge(
        address account,
        uint256 chargeAssets,
        uint256 actionReserveConsumedAssets,
        uint256 actionCommittedMarginConsumedAssets,
        address recipient,
        address protocolTreasury,
        uint256 protocolFeeAssets
    ) external returns (uint256 collectedAssets, uint256 protocolFeeCreditedAssets);

    /// @notice Applies an open/increase trade cost and routes any cash-collected protocol fee to a treasury account.
    /// @dev Callable only by the engine or settlement sidecar. Positive cost debits settlement; negative cost credits
    ///      a rebate. The non-fee debit is transferred to `recipient`, while the fee portion remains in clearinghouse
    ///      custody as an internal credit to `protocolFeeAccount`.
    /// @param account Account whose settlement/margin pays or receives the open cost
    /// @param marginDeltaAssets Margin supplied with the order, in settlement token
    /// @param tradeCostAssets Signed VPI-plus-fee cost in settlement token; positive debits and negative rebates
    /// @param recipient External pool recipient for the non-fee cash debit
    /// @param protocolFeeAccount Clearinghouse account receiving the protocol-fee credit; zero disables the credit
    /// @param protocolFeeAssets Protocol-fee portion included in `tradeCostAssets`, in settlement token
    /// @return netMarginChangeAssets Nonnegative new PnL pledge left after this action's positive cost, in settlement token
    /// @return protocolFeeCreditedAssets Fee portion credited internally to `protocolFeeAccount`, in settlement token
    function applyOpenCost(
        address account,
        uint256 marginDeltaAssets,
        int256 tradeCostAssets,
        address recipient,
        address protocolFeeAccount,
        uint256 protocolFeeAssets
    ) external returns (int256 netMarginChangeAssets, uint256 protocolFeeCreditedAssets);

    /// @notice Consumes carry from canonical active position margin first, then free settlement.
    /// @dev Callable only by the engine or settlement sidecar. Consumption uses canonical stored buckets.
    ///      Other locked buckets and claims are protected; uncovered carry is returned.
    /// @param account Account paying the loss
    /// @param lossAssets Maximum loss to collect in settlement token
    /// @param recipient External recipient of collected settlement token
    /// @return marginConsumedAssets Active position margin consumed in six-decimal settlement token units
    /// @return freeSettlementConsumedAssets Free settlement consumed in settlement token
    /// @return uncoveredAssets Requested loss left uncovered in settlement token
    function consumeSettlementLoss(
        address account,
        uint256 lossAssets,
        address recipient
    ) external returns (uint256 marginConsumedAssets, uint256 freeSettlementConsumedAssets, uint256 uncoveredAssets);

    /// @notice Collects terminal position price loss from PnL pledge only.
    /// @dev Free settlement and every reserve bucket are excluded so settlement matches the NAV book's collateral cap.
    function consumePnlPledgeLoss(
        address account,
        uint256 priceLossAssets,
        address recipient
    ) external returns (uint256 consumedAssets, uint256 shortfallAssets);

    /// @notice Applies isolated full-liquidation price-PnL and charge settlement.
    /// @dev Price seizure consumes PnL pledge only. Keeper, protocol, and LP liquidation fees consume liquidation
    ///      reserve only. Order margin, action reserve, and free settlement are never charge or price-loss sources.
    /// @param account Liquidated account
    /// @param plan Engine-planned liquidation amounts, all in settlement token
    /// @param recipient External pool recipient of `plan.settlementSeizedAssets`
    /// @param keeper Clearinghouse account credited with the bounty
    /// @param keeperBountyAssets Bounty debited from `account` and credited to `keeper`, in settlement token
    /// @param protocolFeeAccount Clearinghouse account credited with the liquidation protocol fee
    /// @param protocolFeeAssets Protocol fee debited from `account` and credited internally, in settlement token
    /// @param lpLiquidationFeeAssets LP fee included in `plan.settlementSeizedAssets`, in settlement token
    /// @return seizedAssets Amount transferred to `recipient` in settlement token
    function applyLiquidationSettlementPlan(
        address account,
        LiquidationSettlementPlan calldata plan,
        address recipient,
        address keeper,
        uint256 keeperBountyAssets,
        address protocolFeeAccount,
        uint256 protocolFeeAssets,
        uint256 lpLiquidationFeeAssets
    ) external returns (uint256 seizedAssets);

    /// @notice Transfers already-reserved settlement from one account to another without moving tokens.
    /// @dev Callable only by the engine. Decreases both the source reserved bucket and source settlement balance,
    ///      then credits the recipient's internal settlement balance. The recipient must be nonzero even for zero.
    /// @param account Account whose reserved settlement is transferred
    /// @param recipient Account receiving settlement credit
    /// @param amount Reserved settlement amount to transfer in settlement token
    function transferReservedSettlement(
        address account,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Returns the explicit settlement token bucket split after subtracting typed locked-margin buckets.
    /// @dev This clearinghouse-local view excludes unrealized PnL, trader claims, and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return buckets Settlement, typed locked, and free settlement token buckets
    function getAccountAssetBuckets(
        address account
    ) external view returns (AccountAssetBuckets memory buckets);

    /// @notice Returns the account's internal settlement balance.
    /// @dev Despite the legacy name, this excludes unrealized PnL and engine withdrawal guards.
    /// @param account Account to inspect
    /// @return Settlement balance in settlement token
    function getAccountEquityAssets(
        address account
    ) external view returns (uint256);

    /// @notice Returns settlement balance above total typed locked margin, floored at zero.
    /// @dev Excludes unrealized PnL and engine withdrawal constraints.
    /// @param account Account to inspect
    /// @return Unencumbered settlement balance in settlement token
    function getFreeBuyingPowerAssets(
        address account
    ) external view returns (uint256);

}

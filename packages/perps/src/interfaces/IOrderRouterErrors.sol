// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Canonical custom errors and commit event shared by the delayed-order router stack.
interface IOrderRouterErrors {

    /// @notice Terminal result of one independently isolated liquidation-batch item.
    enum LiquidationBatchResult {
        Liquidated,
        SkippedNoPosition,
        SkippedSolvent,
        Failed
    }

    /// @notice An order commit supplied a zero position-size delta.
    error OrderRouter__ZeroSize();
    /// @notice An order size is not an exact multiple of the canonical 100-token position lot.
    error OrderRouter__InvalidSizeQuantum();
    /// @notice A commit failed a compact economic or planner-derived validation rule.
    /// @param code Numeric validation code; current code `11` denotes a below-minimum notional or close-size floor.
    error OrderRouter__CommitValidation(uint8 code);

    /// @notice Legacy router-level oracle configuration supplied no basket feeds.
    error OrderRouter__EmptyFeeds();
    /// @notice Legacy router-level oracle arrays or parsed feed counts have inconsistent lengths.
    error OrderRouter__LengthMismatch();
    /// @notice Legacy router-level basket configuration contains a zero normalization base price.
    error OrderRouter__InvalidBasePrice();
    /// @notice Legacy router-level basket weights do not sum to the required 1e18 total.
    error OrderRouter__InvalidWeights();
    /// @notice Legacy test-only oracle behavior was requested when no compatible mock was configured.
    error OrderRouter__MockOracleUnavailable();
    /// @notice A proposed Plether oracle has invalid code, Pyth, engine, or HousePool wiring.
    error OrderRouter__InvalidPletherOracle();
    /// @notice The supplied stateless keeper sidecar has no code or is not bound to this exact Router address.
    error OrderRouter__InvalidKeeperSidecar();
    /// @notice Legacy router oracle path received no Pyth update blobs.
    error OrderRouter__EmptyPythUpdateData();
    /// @notice Legacy router oracle path received less ETH than the required Pyth update fee.
    error OrderRouter__InsufficientPythFee();
    /// @notice The engine-lens dependency is the zero address.
    error OrderRouter__InvalidEngineLens();
    /// @notice The V2 policy-evaluator dependency is zero or has no deployed code.
    error OrderRouter__InvalidPolicyEvaluator();
    /// @notice The immutable V2 execution-sidecar dependency is zero or has no deployed code.
    error OrderRouter__InvalidExecutionSidecar();
    /// @notice The supplied lifecycle Book has no code or does not match this Router's immutable protocol bindings.
    error OrderRouter__InvalidLifecycleBook();
    /// @notice Legacy router oracle resolution produced a zero or otherwise invalid execution price.
    error OrderRouter__InvalidOraclePrice();
    /// @notice Engine execution rejected an oracle publish timestamp older than its cached mark.
    error OrderRouter__MarkPriceOutOfOrder();
    /// @notice Legacy order-execution oracle data exceeds the configured live staleness limit.
    error OrderRouter__OraclePriceTooStale();
    /// @notice Legacy order-execution oracle confidence exceeds the configured price ratio.
    error OrderRouter__OracleConfidenceTooWide();
    /// @notice Legacy liquidation oracle data exceeds the configured liquidation staleness limit.
    error OrderRouter__LiquidationOraclePriceTooStale();
    /// @notice Non-frozen execution was attempted in the commit block or with a non-post-commit publish timestamp.
    error OrderRouter__MevDetected();
    /// @notice Legacy basket components exceed the configured maximum publish-time divergence.
    error OrderRouter__OraclePublishTimesDiverged();

    /// @notice Execution was requested while the global FIFO queue has no live head.
    error OrderRouter__NoOrdersToExecute();
    /// @notice Single-order execution targeted an id other than the current global queue head.
    error OrderRouter__OrderNotQueueHead();
    /// @notice A batch upper bound precedes the current global queue head.
    error OrderRouter__BatchBeforeQueueHead();
    /// @notice A batch upper bound is not lower than the next unassigned commit id.
    error OrderRouter__BatchOrderNotCommitted();
    /// @notice An internal path expected the supplied order id to have `Pending` status.
    error OrderRouter__OrderNotPending();
    /// @notice Permissionless cleanup targeted an order that is not an invalidated pre-cutoff open.
    error OrderRouter__OrderNotRiskOff();
    /// @notice Stored committed-margin linked-list pointers are internally inconsistent.
    error OrderRouter__MarginQueueCorrupt();
    /// @notice Stored per-account live-order linked-list pointers are internally inconsistent.
    error OrderRouter__AccountQueueCorrupt();
    /// @notice Stored global FIFO linked-list pointers are internally inconsistent.
    error OrderRouter__GlobalQueueCorrupt();

    /// @notice An open/increase commit was attempted before both tranche seed positions were initialized.
    error OrderRouter__NotInSeedLifecycle();
    /// @notice The HousePool lifecycle or deposit state currently blocks new trader risk.
    error OrderRouter__VaultRiskBlocked();
    /// @notice A close commit supplied a nonzero margin delta.
    error OrderRouter__CloseWithPositiveMargin();
    /// @notice A close commit has no live or earlier-queued position to reduce.
    error OrderRouter__NoQueuedPosition();
    /// @notice A close commit's side differs from the position obtained after replaying earlier queued orders.
    error OrderRouter__SideMismatch();
    /// @notice A close commit would reduce more than the position remaining after earlier queued orders.
    error OrderRouter__SizeExceedsQueued();
    /// @notice Free settlement cannot back the requested margin or execution bounty.
    error OrderRouter__InsufficientFreeEquity();
    /// @notice Committing another order would exceed the per-account pending-order limit.
    error OrderRouter__TooManyPendingOrders();
    /// @notice A fresh V2 request supplied the reserved zero client-order identifier.
    error OrderRouter__ZeroClientOrderId();
    /// @notice A fresh V2 request omitted its mandatory direction-aware target price.
    error OrderRouter__ZeroTargetPrice();
    /// @notice A fresh V2 request supplied an expired deadline or one beyond the active maximum order age.
    error OrderRouter__InvalidValidUntil();
    /// @notice A fresh V2 request supplied no execution mode or included an undefined mode bit.
    error OrderRouter__InvalidExecutionModeMask();
    /// @notice A fresh V2 request did not pin the currently authoritative execution configuration.
    error OrderRouter__ExecutionConfigMismatch(bytes32 expectedConfigHash, bytes32 currentConfigHash);
    /// @notice A fresh V2 request omitted its mandatory post-position leverage ceiling.
    error OrderRouter__ZeroPostLeverageBound();
    /// @notice The quoted execution bounty alone exceeds the request's gross-account-debit ceiling.
    error OrderRouter__ExecutionBountyAboveGrossDebit(uint256 executionBountyUsdc, uint256 maximumGrossDebitUsdc);
    /// @notice A router integration or configuration hook was called by an unauthorized engine, sidecar, or admin.
    error OrderRouter__Unauthorized();
    /// @notice An open/increase commit was attempted while engine degraded mode is latched.
    error OrderRouter__DegradedMode();
    /// @notice An open/increase commit or execution is blocked by the active oracle close-only policy.
    error OrderRouter__CloseOnlyWindow();

    /// @notice Creating or replacing position protection is disabled by router configuration.
    error OrderRouter__ProtectionDisabled();
    /// @notice Existing-position protection was requested for an account without a live position.
    error OrderRouter__NoOpenPosition();
    /// @notice Protection creation or attached-open submission requires an account with no ordinary pending orders.
    error OrderRouter__PendingOrdersExist();
    /// @notice The account already has a pending-open, armed, or triggered protection.
    error OrderRouter__ProtectionAlreadyActive();
    /// @notice No protection record exists for the supplied identifier.
    error OrderRouter__ProtectionNotFound();
    /// @notice The requested lifecycle transition requires an armed protection.
    error OrderRouter__ProtectionNotArmed();
    /// @notice The requested retry requires a latched protection with no live close attempt.
    error OrderRouter__ProtectionNotLatched();
    /// @notice An ordinary discretionary order was attempted while account protection is active.
    error OrderRouter__ProtectionActive();
    /// @notice Trigger prices are both disabled, out of bounds, or inconsistent with the protected direction.
    error OrderRouter__InvalidProtectionPrices();
    /// @notice A proposed protection threshold is already met at its validation mark.
    error OrderRouter__ProtectionTriggerAlreadyMet();
    /// @notice The cached engine mark is too old to create or replace position protection safely.
    error OrderRouter__ProtectionMarkTooStale();
    /// @notice Neither enabled OCO leg is met at the supplied trigger mark.
    error OrderRouter__TriggerNotMet();
    /// @notice Protection creation, replacement, or triggering was attempted while the oracle is frozen.
    error OrderRouter__ConditionalTriggerFrozen();
    /// @notice The live position no longer exactly matches the side and size bound to the protection.
    error OrderRouter__PositionChanged();
    /// @notice Trigger evaluation was attempted in the block in which protection became armed.
    error OrderRouter__SameBlockTrigger();

    /// @notice The EIP-150-forwardable gas remaining is below the configured minimum for an engine call.
    error OrderRouter__InsufficientGas();
    /// @notice Commit-time planner preflight identified a predictably invalid open/increase.
    /// @param code Numeric `CfdEnginePlanTypes.OpenRevertCode` returned by the engine lens.
    error OrderRouter__PredictableOpenInvalid(uint8 code);
    /// @notice A liquidation batch was empty or exceeded the hard 256-account bound.
    error OrderRouter__InvalidLiquidationBatchSize();

    /// @notice Emitted after a delayed order is stored, reserved, and linked into live queues.
    /// @param orderId Monotonically increasing router order id.
    /// @param account Account that submitted and funds the order.
    /// @param side Direction to open/increase or direction of the queued position to close.
    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);
    /// @notice Reports the terminal result of one attempted liquidation-batch account.
    /// @param index Zero-based account index in the submitted batch.
    /// @param account Account whose liquidation was attempted.
    /// @param result Success, expected skip, or unexpected failure classification.
    /// @param keeperBountyUsdc Bounty credited on success, or zero otherwise.
    /// @param errorSelector Revert selector on a skipped or failed item, or zero on success.
    event LiquidationBatchItem(
        uint256 indexed index,
        address indexed account,
        LiquidationBatchResult result,
        uint256 keeperBountyUsdc,
        bytes4 errorSelector
    );
    /// @notice Reports the first unattempted account after a low-gas check or empty-data item revert stops the batch.
    /// @param nextIndex Zero-based index from which a keeper should resume with a fresh oracle update.
    event LiquidationBatchStopped(uint256 indexed nextIndex);

    /// @notice Emitted when protection is created for a live position or attached to a pending open.
    event PositionProtectionCreated(
        uint64 indexed protectionId,
        address indexed account,
        uint64 indexed parentOrderId,
        uint256 takeProfitTriggerPrice,
        uint256 stopLossTriggerPrice,
        uint256 triggerBountyUsdc,
        uint256 executionBountyUsdc
    );

    /// @notice Emitted when a staged or armed protection's trigger prices are atomically replaced.
    event PositionProtectionReplaced(
        uint64 indexed protectionId,
        address indexed account,
        uint256 takeProfitTriggerPrice,
        uint256 stopLossTriggerPrice
    );

    /// @notice Emitted when a parent open succeeds or existing-position protection becomes armed.
    event PositionProtectionArmed(
        uint64 indexed protectionId,
        address indexed account,
        CfdTypes.Side side,
        uint256 size,
        uint64 armedAt,
        uint64 armedBlock
    );

    /// @notice Emitted when the owner cancels protection before it triggers.
    event PositionProtectionCancelled(uint64 indexed protectionId, address indexed account);

    /// @notice Emitted when an OCO leg activates and creates an ordinary FIFO close.
    event PositionProtectionTriggered(
        uint64 indexed protectionId,
        address indexed account,
        uint64 indexed linkedOrderId,
        PositionProtectionTypes.PositionProtectionTriggerLeg leg,
        uint256 triggerMarkPrice,
        uint64 triggerPublishTime
    );

    /// @notice Emitted whenever the initial or a retried protection close joins the ordinary FIFO queue.
    event PositionProtectionCloseAttemptQueued(
        uint64 indexed protectionId, address indexed account, uint64 indexed linkedOrderId, uint64 previousLinkedOrderId
    );

    /// @notice Emitted when a linked close fails and the protection either relatches or resolves as failed.
    event PositionProtectionCloseAttemptFailed(
        uint64 indexed protectionId,
        address indexed account,
        uint64 indexed linkedOrderId,
        OrderV2Types.TerminalReason reason,
        bool relatched
    );

    /// @notice Emitted when a protection reaches an executed, failed, or liquidated terminal state.
    event PositionProtectionTerminal(
        uint64 indexed protectionId,
        address indexed account,
        uint64 indexed linkedOrderId,
        PositionProtectionTypes.PositionProtectionStatus status
    );

}

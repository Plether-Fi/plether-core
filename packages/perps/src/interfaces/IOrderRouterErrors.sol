// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Canonical custom errors and commit event shared by the delayed-order router stack.
interface IOrderRouterErrors {

    /// @notice An order commit supplied a zero position-size delta.
    error OrderRouter__ZeroSize();
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
    /// @notice Legacy router oracle path received no Pyth update blobs.
    error OrderRouter__EmptyPythUpdateData();
    /// @notice Legacy router oracle path received less ETH than the required Pyth update fee.
    error OrderRouter__InsufficientPythFee();
    /// @notice The engine-lens dependency is the zero address.
    error OrderRouter__InvalidEngineLens();
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
    /// @notice Free settlement or proportional active margin cannot back the requested margin or execution bounty.
    error OrderRouter__InsufficientFreeEquity();
    /// @notice Committing another order would exceed the per-account pending-order limit.
    error OrderRouter__TooManyPendingOrders();
    /// @notice A router integration or configuration hook was called by an unauthorized engine, sidecar, or admin.
    error OrderRouter__Unauthorized();
    /// @notice An open/increase commit was attempted while engine degraded mode is latched.
    error OrderRouter__DegradedMode();
    /// @notice An open/increase commit or execution is blocked by the active oracle close-only policy.
    error OrderRouter__CloseOnlyWindow();

    /// @notice The EIP-150-forwardable gas remaining is below the configured minimum for an engine call.
    error OrderRouter__InsufficientGas();
    /// @notice Commit-time planner preflight identified a predictably invalid open/increase.
    /// @param code Numeric `CfdEnginePlanTypes.OpenRevertCode` returned by the engine lens.
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    /// @notice Emitted after a delayed order is stored, reserved, and linked into live queues.
    /// @param orderId Monotonically increasing router order id.
    /// @param account Account that submitted and funds the order.
    /// @param side Direction to open/increase or direction of the queued position to close.
    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);

}

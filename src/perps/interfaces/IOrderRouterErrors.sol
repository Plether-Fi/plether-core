// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

interface IOrderRouterErrors {

    error OrderRouter__ZeroSize();
    error OrderRouter__CommitValidation(uint8 code);

    error OrderRouter__EmptyFeeds();
    error OrderRouter__LengthMismatch();
    error OrderRouter__InvalidBasePrice();
    error OrderRouter__InvalidWeights();
    error OrderRouter__MockOracleUnavailable();
    error OrderRouter__EmptyPythUpdateData();
    error OrderRouter__InsufficientPythFee();
    error OrderRouter__InvalidEngineLens();
    error OrderRouter__InvalidOraclePrice();
    error OrderRouter__MarkPriceOutOfOrder();
    error OrderRouter__OraclePriceTooStale();
    error OrderRouter__OracleConfidenceTooWide();
    error OrderRouter__LiquidationOraclePriceTooStale();
    error OrderRouter__MevDetected();
    error OrderRouter__OraclePublishTimesDiverged();

    error OrderRouter__NoOrdersToExecute();
    error OrderRouter__OrderNotQueueHead();
    error OrderRouter__BatchBeforeQueueHead();
    error OrderRouter__BatchOrderNotCommitted();
    error OrderRouter__OrderNotPending();
    error OrderRouter__MarginQueueCorrupt();
    error OrderRouter__AccountQueueCorrupt();
    error OrderRouter__GlobalQueueCorrupt();

    error OrderRouter__NotInSeedLifecycle();
    error OrderRouter__VaultRiskBlocked();
    error OrderRouter__CloseWithPositiveMargin();
    error OrderRouter__NoQueuedPosition();
    error OrderRouter__SideMismatch();
    error OrderRouter__SizeExceedsQueued();
    error OrderRouter__InsufficientFreeEquity();
    error OrderRouter__TooManyPendingOrders();
    error OrderRouter__Unauthorized();
    error OrderRouter__DegradedMode();
    error OrderRouter__CloseOnlyWindow();

    error OrderRouter__InsufficientGas();
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

library AccountLensViewTypes {

    struct AccountLedgerView {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 executionEscrowUsdc;
        uint256 committedMarginUsdc;
        uint256 deferredPayoutUsdc;
        uint256 pendingOrderCount;
    }

    struct AccountLedgerSnapshot {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 positionMarginBucketUsdc;
        uint256 committedOrderMarginBucketUsdc;
        uint256 reservedSettlementBucketUsdc;
        uint256 executionEscrowUsdc;
        uint256 committedMarginUsdc;
        uint256 deferredPayoutUsdc;
        uint256 pendingOrderCount;
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        bool hasPosition;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        int256 unrealizedPnlUsdc;
        int256 pendingFundingUsdc;
        int256 netEquityUsdc;
        bool liquidatable;
    }
}

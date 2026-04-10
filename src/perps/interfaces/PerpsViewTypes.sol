// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

/// @notice Canonical public-facing view structs for the simplified perps product surface.
library PerpsViewTypes {

    enum OrderStatus {
        None,
        Pending,
        Executed,
        Failed,
        Cancelled
    }

    struct TraderAccountView {
        uint256 equityUsdc;
        uint256 withdrawableUsdc;
        uint256 pendingOrderMarginUsdc;
        uint256 pendingExecutionBountyUsdc;
        bool hasOpenPosition;
        bool liquidatable;
    }

    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 entryPrice;
        uint256 marginUsdc;
        int256 unrealizedPnlUsdc;
        uint256 maintenanceMarginUsdc;
        bool liquidatable;
    }

    struct PendingOrderView {
        uint64 orderId;
        CfdTypes.Side side;
        uint256 sizeDelta;
        int256 marginDeltaUsdc;
        uint256 acceptablePrice;
        bool isReduceOnly;
        OrderStatus status;
    }

    struct TrancheView {
        uint256 totalAssetsUsdc;
        uint256 totalShares;
        uint256 sharePrice;
        uint256 maxWithdrawUsdc;
        bool depositEnabled;
        bool withdrawEnabled;
    }

    struct LpStatusView {
        bool tradingActive;
        bool withdrawalLive;
        uint64 lastMarkTime;
        bool oracleFresh;
    }

    struct ProtocolStatusView {
        uint8 phase;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool fadWindow;
        bool tradingActive;
        bool withdrawalLive;
    }

}

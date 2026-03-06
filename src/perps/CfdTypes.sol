// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title CfdTypes
/// @notice Core data structures for the Plether CFD Engine
library CfdTypes {

    /// @dev Represents the directional bias of the trade.
    /// BULL = Long Basket (Profits when Basket/BEAR drops)
    /// BEAR = Short Basket (Profits when Basket/BEAR rises)
    enum Side {
        BULL,
        BEAR
    }

    /// @notice A user's active position in a specific market
    struct Position {
        uint256 size; // [18 dec] Notional size in synthetic tokens
        uint256 margin; // [6 dec] Isolated margin backing this position
        uint256 entryPrice; // [8 dec] Oracle price of BEAR at execution
        int256 entryFundingIndex; // [18 dec WAD] Global funding index at the time of entry
        Side side; // [uint8] Trade direction
        uint64 lastUpdateTime; // [uint64] Timestamp of last modification
    }

    /// @notice An intent submitted by a user, waiting for Keeper execution
    struct Order {
        bytes32 accountId; // Maps to MarginClearinghouse unified account
        uint256 sizeDelta; // [18 dec] Amount of size to add/remove
        uint256 marginDelta; // [6 dec] Amount of margin to add/remove
        uint256 targetPrice; // [8 dec] Slippage protection limit
        uint64 commitTime; // Timestamp of intent submission (MEV shield)
        uint64 orderId; // Strict FIFO execution queue ID
        Side side; // [uint8] BULL or BEAR
        bool isClose; // [bool] True if strictly closing/reducing
    }

    /// @notice Global configuration parameters for the VPI and Funding engines
    struct RiskParams {
        uint256 vpiFactor; // [18 dec WAD] Impact severity 'k'
        uint256 maxSkewRatio; // [18 dec WAD] Hard cliff e.g., 40% (0.40e18)
        uint256 kinkSkewRatio; // [18 dec WAD] Inflection point e.g., 25% (0.25e18)
        uint256 baseApy; // [18 dec WAD] Rate at the kink e.g., 15% (0.15e18)
        uint256 maxApy; // [18 dec WAD] Rate at the wall e.g., 300% (3.00e18)
        uint256 maintMarginBps; // e.g., 100 (1%)
        uint256 fadMarginBps; // e.g., 300 (3%)
        uint256 minBountyUsdc; // e.g., 5_000_000 ($5 USDC floor)
        uint256 bountyBps; // e.g., 15 (0.15% of Notional Size)
    }

}

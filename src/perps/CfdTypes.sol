// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title CfdTypes
/// @notice Core data structures for the Plether CFD Engine
/// @custom:security-contact contact@plether.com
library CfdTypes {

    /// @dev BULL profits when USD strengthens (oracle price drops).
    ///      BEAR profits when USD weakens (oracle price rises).
    enum Side {
        BULL,
        BEAR
    }

    /// @notice A user's active position in a specific market.
    /// @dev `margin` is the engine's canonical economic position-margin state used for risk and state transitions.
    ///      It is intentionally distinct from the clearinghouse custody bucket that holds the locked funds backing it.
    struct Position {
        uint256 size; // [18 dec] Notional size in synthetic tokens
        uint256 margin; // [6 dec] Isolated margin backing this position
        uint256 entryPrice; // [8 dec] Oracle price of BEAR at execution
        uint256 maxProfitUsdc; // [6 dec] Cumulative max profit tracked to avoid truncation underflow
        Side side; // [uint8] Trade direction
        uint64 lastUpdateTime; // [uint64] Timestamp of last modification
        uint64 lastCarryTimestamp; // [uint64] Timestamp through which carry has been realized
        int256 vpiAccrued; // [6 dec] Cumulative VPI charges (+) and rebates (-) across the position's lifetime
    }

    /// @notice An intent submitted by a user, waiting for Keeper execution
    struct Order {
        address account; // Maps to MarginClearinghouse unified account
        uint256 sizeDelta; // [18 dec] Amount of size to add/remove
        uint256 marginDelta; // [6 dec] Amount of margin to add/remove
        uint256 targetPrice; // [8 dec] Slippage protection limit
        uint64 commitTime; // Timestamp of intent submission (MEV shield)
        uint64 commitBlock; // Block number of intent submission (same-block execution shield)
        uint64 orderId; // Strict FIFO execution queue ID
        Side side; // [uint8] BULL or BEAR
        bool isClose; // [bool] True if strictly closing/reducing
    }

    enum CloseInvalidReason {
        None,
        NoPosition,
        BadSize,
        PartialCloseUnderwater,
        DustPosition
    }

    /// @notice Global configuration parameters for the VPI and carry engines
    struct RiskParams {
        uint256 vpiFactor; // [18 dec WAD] Impact severity 'k'
        uint256 maxSkewRatio; // [18 dec WAD] Hard cliff e.g., 40% (0.40e18)
        uint256 maintMarginBps; // e.g., 100 (1%)
        uint256 initMarginBps; // e.g., 150 (1.5%)
        uint256 fadMarginBps; // e.g., 300 (3%)
        uint256 baseCarryBps; // e.g., 500 (5% annualized carry on LP-backed notional)
        uint256 minBountyUsdc; // e.g., 1_000_000 ($1 USDC floor)
        uint256 bountyBps; // e.g., 10 (0.10% of Notional Size)
    }

}

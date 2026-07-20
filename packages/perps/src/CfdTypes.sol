// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CfdTypes
/// @notice Defines the canonical position, order, direction, and risk-configuration types used by the perps system.
/// @custom:security-contact contact@plether.com
library CfdTypes {

    /// @notice Direction of a position or order relative to the protocol's USD-strength oracle price.
    /// @dev The oracle price represents the BEAR leg: BULL profits as it falls and BEAR profits as it rises.
    enum Side {
        /// @notice Profits when the oracle price falls (USD strengthens).
        BULL,
        /// @notice Profits when the oracle price rises (USD weakens).
        BEAR
    }

    /// @notice A user's active position in a specific market.
    /// @dev `margin` is the engine's canonical economic position-margin state used for risk and state transitions.
    ///      It is intentionally distinct from the clearinghouse custody bucket that holds the locked funds backing it.
    /// @param size Position notional in synthetic-token units (18 decimals).
    /// @param margin Isolated position margin in USDC units (6 decimals).
    /// @param entryPrice Size-weighted entry oracle price of the BEAR leg (8 decimals).
    /// @param maxProfitUsdc Cumulative maximum-profit envelope used for solvency accounting (6-decimal USDC).
    /// @param side Direction of the position.
    /// @param lastUpdateTime Unix timestamp of the position's most recent state change.
    /// @param lastCarryTimestamp Unix timestamp through which carry has been realized.
    /// @param vpiAccrued Signed cumulative VPI charged (positive) or rebated (negative), in 6-decimal USDC.
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

    /// @notice A delayed trade intent waiting for keeper execution.
    /// @param account Canonical clearinghouse account that submitted the order.
    /// @param sizeDelta Position-size change in synthetic-token units (18 decimals).
    /// @param marginDelta Margin committed by an open/increase order in 6-decimal USDC; close orders require zero.
    /// @param targetPrice Direction-aware execution limit (8 decimals), or zero for no slippage limit.
    /// @param commitTime Unix timestamp at submission, used for expiry and post-commit oracle checks.
    /// @param commitBlock Block number at submission, used to block same-block execution outside frozen-oracle mode.
    /// @param orderId Monotonically increasing router order identifier.
    /// @param side Direction to open/increase or, for a close, the direction of the queued position being reduced.
    /// @param isClose Whether the intent strictly reduces an existing or earlier-queued position.
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

    /// @notice Reason a requested close cannot be applied to the current position.
    enum CloseInvalidReason {
        /// @notice The close is valid.
        None,
        /// @notice No live position exists.
        NoPosition,
        /// @notice The requested close size is zero or exceeds the live position.
        BadSize,
        /// @notice The requested partial close would leave an undercollateralized position.
        PartialCloseUnderwater,
        /// @notice The requested partial close would leave a position below protocol dust floors.
        DustPosition
    }

    /// @notice Global risk parameters used by position, VPI, carry, margin, and liquidation accounting.
    /// @param vpiFactor VPI impact factor `k` (18-decimal WAD).
    /// @param maxSkewRatio Maximum directional skew divided by pool depth (18-decimal WAD).
    /// @param maintMarginBps Normal maintenance-margin ratio in basis points.
    /// @param initMarginBps Initial-margin ratio for opens and increases in basis points.
    /// @param fadMarginBps Maintenance-margin ratio used during the FAD window in basis points.
    /// @param baseCarryBps Annualized base carry rate applied to LP-backed notional in basis points.
    /// @param minBountyUsdc Minimum liquidation bounty and position-margin floor in 6-decimal USDC.
    /// @param bountyBps Variable liquidation bounty rate applied to notional in basis points.
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

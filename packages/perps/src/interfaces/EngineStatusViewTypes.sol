// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title EngineStatusViewTypes
/// @notice Shared return types for engine lifecycle and oracle status.
library EngineStatusViewTypes {

    /// @notice Compact engine runtime status.
    /// @param phase Numeric encoding of `ICfdEngine.ProtocolPhase`.
    /// @param lastMarkPrice Cached engine mark price, with 8 decimals.
    /// @param lastMarkTime Oracle publish timestamp associated with the cached mark.
    /// @param oracleFrozen Whether the market calendar currently permits frozen-oracle operation.
    /// @param fadWindow Whether Friday Afternoon Deleverage controls are currently active.
    /// @param fadMaxStaleness Maximum accepted mark age while the oracle is frozen, in seconds.
    struct ProtocolStatus {
        uint8 phase;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool fadWindow;
        uint256 fadMaxStaleness;
    }

}

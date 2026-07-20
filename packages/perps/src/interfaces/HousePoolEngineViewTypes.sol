// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title HousePoolEngineViewTypes
/// @notice Shared snapshots supplied by the CFD engine to HousePool accounting.
library HousePoolEngineViewTypes {

    /// @notice Engine-derived accounting inputs used for pool reconciliation, deposits, and withdrawals.
    /// @dev Monetary fields use USDC's 6 decimals. Liability inputs are conservative and intentionally separate
    ///      withdrawal-side unrealized MtM from the deposit-pricing model.
    /// @param physicalAssetsUsdc Canonical assets recognized by the HousePool before engine-side reservations.
    /// @param netPhysicalAssetsUsdc Physical assets net of protocol-treasury settlement credited in custody.
    /// @param maxLiabilityUsdc Larger of the bull-side and bear-side maximum-profit envelopes.
    /// @param supplementalReservedUsdc Additional senior reservation supplied by the engine; currently zero.
    /// @param unrealizedMtmLiabilityUsdc Conservative current-mark liability used on the withdrawal side.
    /// @param depositMtmLiabilityUsdc Exact deposit-side MtM adjustment; zero until a non-manipulable model exists.
    /// @param traderClaimBalanceUsdc Aggregate unpaid trader claims senior to fresh discretionary payouts.
    /// @param hasOpenPositions Whether either side has nonzero open interest.
    /// @param markFreshnessRequired Whether live maximum-profit liability requires a fresh mark.
    /// @param maxMarkStaleness Maximum permitted mark age for the active calendar regime, in seconds; zero when
    ///        `markFreshnessRequired` is false.
    struct HousePoolInputSnapshot {
        uint256 physicalAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 supplementalReservedUsdc;
        uint256 unrealizedMtmLiabilityUsdc;
        uint256 depositMtmLiabilityUsdc;
        uint256 traderClaimBalanceUsdc;
        bool hasOpenPositions;
        bool markFreshnessRequired;
        uint256 maxMarkStaleness;
    }

    /// @notice Engine runtime flags consumed by HousePool freshness and withdrawal gates.
    /// @param lastMarkTime Oracle publish timestamp associated with the cached engine mark.
    /// @param oracleFrozen Whether the market calendar currently permits frozen-oracle operation.
    /// @param degradedMode Whether the engine has entered insolvency-protection mode.
    struct HousePoolStatusSnapshot {
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool degradedMode;
    }

}

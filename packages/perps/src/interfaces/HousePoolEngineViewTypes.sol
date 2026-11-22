// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title HousePoolEngineViewTypes
/// @notice Shared snapshots supplied by the CFD engine to HousePool accounting.
library HousePoolEngineViewTypes {

    /// @notice Engine-derived accounting inputs used for pool reconciliation, deposits, and withdrawals.
    /// @dev Monetary fields use settlement token's 6 decimals. The signed terminal LP price delta is the canonical mark-to-close
    ///      adjustment shared by LP entry and exit pricing: positive values are collectible by LPs, while negative
    ///      values are payable by LPs.
    /// @param physicalAssets Canonical assets recognized by the HousePool before engine-side reservations.
    /// @param netPhysicalAssets Canonical pool assets, equal to physicalAssets. Treasury settlement is held
    ///        separately in the clearinghouse and must not be subtracted again; trader claims are also separate.
    /// @param maxLiabilityAssets Larger of the long-side and short-side maximum-profit envelopes.
    /// @param supplementalReservedAssets Protected settlement headroom and pending-open backing for LP withdrawals.
    ///        This supplemental reserve does not affect terminal NAV.
    /// @param terminalLpPriceDeltaAssets Signed terminal mark-to-close delta attributable to LPs.
    /// @param terminalNavBookVersion Monotonic terminal-NAV book version captured with the engine snapshot.
    /// @param traderClaimBalanceAssets Aggregate unpaid trader claims senior to fresh discretionary payouts.
    /// @param totalPositiveVpiAccruedAssets Refundable lifetime VPI held by the pool; excluded from LP NAV and cash.
    /// @param totalNegativeVpiAccruedAssets Negative lifetime VPI backed by clearinghouse reserves; included in LP NAV
    ///        as a collectible receivable, but unavailable to fund withdrawals until collected.
    /// @param hasOpenPositions Whether either side has nonzero open interest.
    /// @param markFreshnessRequired Whether any open position requires a fresh mark, including zero-profit endpoints.
    /// @param maxMarkStaleness Maximum permitted mark age for the active calendar regime, in seconds; zero when
    ///        `markFreshnessRequired` is false.
    struct HousePoolInputSnapshot {
        uint256 physicalAssets;
        uint256 netPhysicalAssets;
        uint256 maxLiabilityAssets;
        uint256 supplementalReservedAssets;
        int256 terminalLpPriceDeltaAssets;
        uint64 terminalNavBookVersion;
        uint256 traderClaimBalanceAssets;
        uint256 totalPositiveVpiAccruedAssets;
        uint256 totalNegativeVpiAccruedAssets;
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

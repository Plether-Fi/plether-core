// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";

/// @title HousePoolAccountingLib
/// @notice Derives withdrawal, reconciliation, and mark-freshness views from engine accounting snapshots.
/// @dev All asset and liability amounts use 6-decimal USDC; staleness values and timestamps use seconds. Liability
///      additions use checked arithmetic, while the documented asset-minus-reservation calculations saturate at zero.
library HousePoolAccountingLib {

    /// @notice Conservative pool cash available for LP withdrawal after senior protocol reservations.
    /// @param physicalAssets Canonical physical pool assets.
    /// @param maxLiability Maximum side-liability envelope.
    /// @param reserved Sum of max liability, outstanding trader claims, and supplemental reservation.
    /// @param freeUsdc Physical assets above `reserved`, floored at zero.
    struct WithdrawalSnapshot {
        uint256 physicalAssets;
        uint256 maxLiability;
        uint256 reserved;
        uint256 freeUsdc;
    }

    /// @notice Pool assets distributable to tranche claims after trader claims and the canonical terminal delta.
    /// @param distributable Terminal LP equity after trader claims and the signed delta, floored at zero.
    /// @param deficit Trader claims and terminal payables above physical assets and terminal receivables.
    struct ReconcileSnapshot {
        uint256 distributable;
        uint256 deficit;
    }

    /// @notice Mark-freshness rule extracted from an engine accounting snapshot.
    /// @param required Whether callers must enforce a mark-age limit.
    /// @param maxStaleness Maximum permitted age in seconds; zero when freshness is not required.
    struct MarkFreshnessPolicy {
        bool required;
        uint256 maxStaleness;
    }

    /// @notice Builds the base withdrawal reserve and free-cash snapshot.
    /// @dev `reserved` uses the engine maximum-profit envelope rather than an MtM liability. Free cash saturates at
    ///      zero when reservations equal or exceed assets. Callers may layer additional reservations on the result.
    /// @param engineSnapshot Engine-supplied physical assets and liability reservations.
    /// @return snapshot Withdrawal accounting values in 6-decimal USDC.
    function buildWithdrawalSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (WithdrawalSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.physicalAssetsUsdc;
        snapshot.maxLiability = engineSnapshot.maxLiabilityUsdc;
        snapshot.reserved = engineSnapshot.maxLiabilityUsdc + engineSnapshot.traderClaimBalanceUsdc
            + engineSnapshot.supplementalReservedUsdc;
        snapshot.freeUsdc =
            snapshot.physicalAssets > snapshot.reserved ? snapshot.physicalAssets - snapshot.reserved : 0;
    }

    /// @notice Builds the single canonical terminal-NAV snapshot shared by LP entry and exit pricing.
    /// @param engineSnapshot Engine accounting inputs.
    /// @return snapshot Terminal LP equity and explicit deficit after claims and the signed terminal delta.
    function buildReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        uint256 terminalAssets = engineSnapshot.physicalAssetsUsdc;
        uint256 terminalLiabilities = engineSnapshot.traderClaimBalanceUsdc;
        int256 terminalDelta = engineSnapshot.terminalLpPriceDeltaUsdc;
        if (terminalDelta >= 0) {
            terminalAssets += uint256(terminalDelta);
        } else {
            // This form also handles `type(int256).min` without negating it directly.
            terminalLiabilities += uint256(-(terminalDelta + 1)) + 1;
        }

        if (terminalAssets >= terminalLiabilities) {
            snapshot.distributable = terminalAssets - terminalLiabilities;
        } else {
            snapshot.deficit = terminalLiabilities - terminalAssets;
        }
    }

    /// @notice Extracts whether mark freshness is required and, if so, its permitted age.
    /// @param accountingSnapshot Engine snapshot carrying the active freshness policy.
    /// @return policy Freshness requirement; `maxStaleness` remains zero when `required` is false.
    function getMarkFreshnessPolicy(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory accountingSnapshot
    ) internal pure returns (MarkFreshnessPolicy memory policy) {
        policy.required = accountingSnapshot.markFreshnessRequired;
        if (policy.required) {
            policy.maxStaleness = accountingSnapshot.maxMarkStaleness;
        }
    }

    /// @notice Tests whether a mark timestamp is no older than an inclusive staleness limit.
    /// @dev If `lastMarkTime` is in the future relative to `currentTimestamp`, its age is treated as zero and the mark
    ///      is fresh. A zero timestamp is not special-cased. The comparison is inclusive (`age <= limit`).
    /// @param lastMarkTime Mark publish timestamp in Unix seconds.
    /// @param limit Maximum permitted mark age in seconds.
    /// @param currentTimestamp Timestamp against which age is measured, in Unix seconds.
    /// @return True when the saturating mark age is at most `limit`.
    function isMarkFresh(
        uint64 lastMarkTime,
        uint256 limit,
        uint256 currentTimestamp
    ) internal pure returns (bool) {
        uint256 age = currentTimestamp > lastMarkTime ? currentTimestamp - lastMarkTime : 0;
        return age <= limit;
    }

}

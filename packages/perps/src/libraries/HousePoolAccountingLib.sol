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

    /// @notice Pool assets distributable to tranche claims after trader claims and the selected MtM liability.
    /// @param physicalAssets Canonical physical pool assets.
    /// @param traderClaimLiabilities Outstanding trader-claim liability senior to LP claims.
    /// @param cashAfterTraderClaimLiabilities Physical assets net of trader claims, floored at zero.
    /// @param mtm Selected mark-to-market liability for this reconciliation context.
    /// @param distributable Cash after trader claims and MtM liability, floored at zero.
    struct ReconcileSnapshot {
        uint256 physicalAssets;
        uint256 traderClaimLiabilities;
        uint256 cashAfterTraderClaimLiabilities;
        uint256 mtm;
        uint256 distributable;
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

    /// @notice Builds a reconciliation snapshot using the conservative withdrawal-side unrealized MtM liability.
    /// @param engineSnapshot Engine accounting inputs.
    /// @return snapshot Physical cash remaining after trader claims and `unrealizedMtmLiabilityUsdc`.
    function buildReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        return _buildReconcileSnapshot(engineSnapshot, engineSnapshot.unrealizedMtmLiabilityUsdc);
    }

    /// @notice Builds a reconciliation snapshot using the deposit-pricing MtM liability.
    /// @param engineSnapshot Engine accounting inputs.
    /// @return snapshot Physical cash remaining after trader claims and `depositMtmLiabilityUsdc`.
    function buildDepositReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot
    ) internal pure returns (ReconcileSnapshot memory snapshot) {
        return _buildReconcileSnapshot(engineSnapshot, engineSnapshot.depositMtmLiabilityUsdc);
    }

    /// @notice Builds reconciliation accounting against an explicitly selected MtM liability.
    /// @dev Each subtraction saturates at zero. The helper does not use `netPhysicalAssetsUsdc`, max liability, or
    ///      supplemental reservations from the engine snapshot.
    /// @param engineSnapshot Engine accounting inputs supplying physical assets and trader claims.
    /// @param mtmLiabilityUsdc Mark-to-market liability to reserve after trader claims.
    /// @return snapshot Reconciliation accounting values in 6-decimal USDC.
    function _buildReconcileSnapshot(
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory engineSnapshot,
        uint256 mtmLiabilityUsdc
    ) private pure returns (ReconcileSnapshot memory snapshot) {
        snapshot.physicalAssets = engineSnapshot.physicalAssetsUsdc;
        snapshot.traderClaimLiabilities = engineSnapshot.traderClaimBalanceUsdc;
        snapshot.cashAfterTraderClaimLiabilities = engineSnapshot.physicalAssetsUsdc > snapshot.traderClaimLiabilities
            ? engineSnapshot.physicalAssetsUsdc - snapshot.traderClaimLiabilities
            : 0;
        snapshot.mtm = mtmLiabilityUsdc;
        snapshot.distributable = snapshot.cashAfterTraderClaimLiabilities > snapshot.mtm
            ? snapshot.cashAfterTraderClaimLiabilities - snapshot.mtm
            : 0;
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

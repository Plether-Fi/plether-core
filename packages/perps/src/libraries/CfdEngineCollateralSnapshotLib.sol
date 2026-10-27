// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";

/// @notice Expands one canonical clearinghouse observation into the planner's collateral fields.
library CfdEngineCollateralSnapshotLib {

    /// @dev The isolation getter applies the same checked locked-bucket sum and zero-floored free settlement as the
    ///      legacy account/locked getters. VPI is contained in action reserve, and bounty remains a separate protected
    ///      classification. Commitment omits execution-only reserve fields while still protecting the full action bucket.
    function load(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        IMarginClearinghouse clearinghouse,
        address account,
        bool closeCommit
    ) internal view {
        IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(account);
        snapshot.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: buckets.settlementBalanceAssets,
            totalLockedMarginAssets: buckets.totalLockedAssets,
            activePositionMarginAssets: buckets.pnlPledgeAssets,
            otherLockedMarginAssets: buckets.liquidationReserveAssets + buckets.orderMarginAssets
                + buckets.actionReserveAssets,
            freeSettlementAssets: buckets.freeSettlementAssets
        });
        snapshot.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginAssets: buckets.pnlPledgeAssets,
            committedOrderMarginAssets: buckets.orderMarginAssets,
            reservedSettlementAssets: buckets.actionReserveAssets,
            totalLockedMarginAssets: buckets.totalLockedAssets
        });
        snapshot.liquidationReserveAssets = buckets.liquidationReserveAssets;
        snapshot.actionReserveAssets = buckets.actionReserveAssets;
        if (!closeCommit) {
            snapshot.vpiRebateReserveAssets = buckets.vpiRebateReserveAssets;
            snapshot.protectedExecutionBountyAssets = clearinghouse.totalBountyReservationsAssets(account);
        }
        // Clearinghouse pledge remains authoritative even when the Engine position tuple is stale.
        snapshot.position.margin = buckets.pnlPledgeAssets;
    }

}

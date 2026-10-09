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
        snapshot.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: buckets.settlementBalanceUsdc,
            totalLockedMarginUsdc: buckets.totalLockedUsdc,
            activePositionMarginUsdc: buckets.pnlPledgeUsdc,
            otherLockedMarginUsdc: buckets.liquidationReserveUsdc + buckets.orderMarginUsdc + buckets.actionReserveUsdc,
            freeSettlementUsdc: buckets.freeSettlementUsdc
        });
        snapshot.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: buckets.pnlPledgeUsdc,
            committedOrderMarginUsdc: buckets.orderMarginUsdc,
            reservedSettlementUsdc: buckets.actionReserveUsdc,
            totalLockedMarginUsdc: buckets.totalLockedUsdc
        });
        snapshot.liquidationReserveUsdc = buckets.liquidationReserveUsdc;
        snapshot.actionReserveUsdc = buckets.actionReserveUsdc;
        if (!closeCommit) {
            snapshot.vpiRebateReserveUsdc = buckets.vpiRebateReserveUsdc;
            snapshot.protectedExecutionBountyUsdc = clearinghouse.totalBountyReservationsUsdc(account);
        }
        // Clearinghouse pledge remains authoritative even when the Engine position tuple is stale.
        snapshot.position.margin = buckets.pnlPledgeUsdc;
    }

}

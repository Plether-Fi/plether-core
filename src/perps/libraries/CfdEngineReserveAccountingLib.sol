// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngineSnapshotsLib} from "./CfdEngineSnapshotsLib.sol";

library CfdEngineReserveAccountingLib {

    function getWithdrawalReservedUsdc(
        uint256 maxLiability,
        uint256 protocolFees,
        int256 fundingLiability,
        uint256 deferredPayoutUsdc,
        uint256 deferredLiquidationBountyUsdc
    ) internal pure returns (uint256 reservedUsdc) {
        reservedUsdc = CfdEngineSnapshotsLib.getWithdrawalReservedUsdc(maxLiability, protocolFees, fundingLiability);
        reservedUsdc += deferredPayoutUsdc + deferredLiquidationBountyUsdc;
    }

    function buildAdjustedSolvencySnapshot(
        uint256 physicalAssets,
        uint256 protocolFees,
        uint256 maxLiability,
        CfdEngineSnapshotsLib.FundingSnapshot memory fundingSnapshot,
        uint256 deferredPayoutUsdc,
        uint256 deferredLiquidationBountyUsdc
    ) internal pure returns (CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot) {
        snapshot = CfdEngineSnapshotsLib.buildSolvencySnapshot(physicalAssets, protocolFees, maxLiability, fundingSnapshot);
        snapshot.effectiveSolvencyAssets = subtractClamped(snapshot.effectiveSolvencyAssets, deferredPayoutUsdc);
        snapshot.effectiveSolvencyAssets =
            subtractClamped(snapshot.effectiveSolvencyAssets, deferredLiquidationBountyUsdc);
    }

    function applyPendingVaultPayout(
        CfdEngineSnapshotsLib.SolvencySnapshot memory snapshot,
        uint256 pendingVaultPayoutUsdc
    ) internal pure returns (CfdEngineSnapshotsLib.SolvencySnapshot memory adjusted) {
        adjusted = snapshot;
        adjusted.effectiveSolvencyAssets = subtractClamped(adjusted.effectiveSolvencyAssets, pendingVaultPayoutUsdc);
    }

    function subtractClamped(
        uint256 value,
        uint256 decrement
    ) internal pure returns (uint256) {
        return value > decrement ? value - decrement : 0;
    }

}

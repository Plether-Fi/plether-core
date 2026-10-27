// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @notice Canonical close admission economics, shared by commitment and prospective assessment.
library CloseCommitmentLib {

    function project(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 size
    ) internal pure returns (CfdEnginePlanTypes.CloseCommitment memory effects) {
        if (snap.position.size == 0) {
            revert ICfdEngineTypes.CfdEngine__NoOpenPosition();
        }
        if (size == 0) {
            revert ICfdEngineTypes.CfdEngine__ZeroAmount();
        }
        if (size > snap.position.size) {
            revert ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition();
        }
        if (size % CfdTypes.SIZE_QUANTUM != 0) {
            revert ICfdEngineTypes.CfdEngine__InvalidCloseSizeQuantum();
        }
        if (snap.lastMarkPrice == 0 || snap.lastMarkTime == 0) {
            revert ICfdEngineTypes.CfdEngine__MarkPriceStale();
        }

        effects.settlementBeforeAssets = snap.accountBuckets.settlementBalanceAssets;
        effects.carryCollectedAssets = CfdEnginePlanLib.projectCloseCommitCarry(snap);
        effects.carryOutstandingAssets = snap.unsettledCarryAssets;
        if (size != snap.position.size) {
            if (snap.unsettledCarryAssets != 0) {
                revert ICfdEngineTypes.CfdEngine__PartialCloseCarryUnfunded(snap.unsettledCarryAssets);
            }
            uint256 bps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
            if (PositionRiskAccountingLib.buildExactPriceRiskState(
                    snap.position,
                    snap.positionEntryCostAssetAtoms,
                    snap.lastMarkPrice,
                    snap.capPrice,
                    snap.position.margin + snap.traderClaimBalanceForAccount,
                    bps
                )
                .liquidatable) {
                revert ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy();
            }
        }
        effects.settlementAfterAssets = snap.accountBuckets.settlementBalanceAssets;
        effects.freeSettlementAfterAssets = snap.accountBuckets.freeSettlementAssets;
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @notice Canonical close admission economics, shared by commitment and prospective assessment.
library CloseCommitmentLib {

    function project(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 size,
        uint256 bounty
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

        effects.settlementBeforeUsdc = snap.accountBuckets.settlementBalanceUsdc;
        effects.carryCollectedUsdc = CfdEnginePlanLib.projectCloseCommitCarry(snap);
        effects.carryOutstandingUsdc = snap.unsettledCarryUsdc;
        uint256 free = snap.accountBuckets.freeSettlementUsdc;
        effects.bountyFromFreeUsdc = bounty < free ? bounty : free;
        effects.bountyFromPledgeUsdc = bounty - effects.bountyFromFreeUsdc;
        if (effects.bountyFromPledgeUsdc > snap.position.margin) {
            revert ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking(
                bounty, free + snap.position.margin, snap.unsettledCarryUsdc
            );
        }
        uint256 oldBorrow = snap.positionBorrowBaseUsdc;
        snap.position.margin -= effects.bountyFromPledgeUsdc;
        snap.positionBorrowBaseUsdc =
            PositionRiskAccountingLib.computeBorrowBaseUsdc(snap.position.maxProfitUsdc, snap.position.margin);
        CfdEnginePlanTypes.SideSnapshot memory side =
            snap.position.side == CfdTypes.Side.LONG ? snap.longSide : snap.shortSide;
        side.totalMargin -= effects.bountyFromPledgeUsdc;
        side.borrowBaseUsdc = side.borrowBaseUsdc - oldBorrow + snap.positionBorrowBaseUsdc;
        if (size != snap.position.size) {
            if (snap.unsettledCarryUsdc != 0) {
                revert ICfdEngineTypes.CfdEngine__PartialCloseCarryUnfunded(snap.unsettledCarryUsdc);
            }
            uint256 bps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
            if (PositionRiskAccountingLib.buildExactPriceRiskState(
                    snap.position,
                    snap.positionEntryCostUsdcAtoms,
                    snap.lastMarkPrice,
                    snap.capPrice,
                    snap.position.margin + snap.traderClaimBalanceForAccount,
                    bps
                )
                .liquidatable) {
                revert ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy();
            }
        }
        snap.lockedBuckets.positionMarginUsdc = snap.position.margin;
        snap.actionReserveUsdc += bounty;
        snap.protectedExecutionBountyUsdc += bounty;
        snap.lockedBuckets.reservedSettlementUsdc += bounty;
        snap.accountBuckets = MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
            snap.accountBuckets.settlementBalanceUsdc,
            snap.position.margin,
            snap.liquidationReserveUsdc,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.actionReserveUsdc
        );
        snap.lockedBuckets.totalLockedMarginUsdc = snap.accountBuckets.totalLockedMarginUsdc;
        effects.settlementAfterUsdc = snap.accountBuckets.settlementBalanceUsdc;
        effects.freeSettlementAfterUsdc = snap.accountBuckets.freeSettlementUsdc;
    }

}

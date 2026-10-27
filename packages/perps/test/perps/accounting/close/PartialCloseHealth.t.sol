// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Synthetic pure-plan fixtures isolate atomic health and fee-source boundaries.
contract PartialCloseHealthTest is Test {

    uint256 private constant CAP_PRICE = 200_000_000;
    uint256 private constant POOL_LIQUIDITY = 1e30;
    address private constant ACCOUNT = address(0xA11CE);

    function test_EquityAtHRejectsAndHPlusOneRetainsAllPledge() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 2_000_000, 0);
        snap.riskParams.maintMarginBps = 200;
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 100_000_000);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY));
        snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 2_000_001, 0);
        snap.riskParams.maintMarginBps = 200;
        delta = _plan(snap, 1, 100_000_000);
        assertTrue(delta.valid);
        assertEq(delta.safeMarginReleaseAssets, 0, "retain extra pledge instead of rejecting a viable reduction");
        assertEq(delta.posMarginAfter, 2_000_001);
    }

    function test_ActionFundingEqualReleasePassesOneMoreAtomFails() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.LONG, 20_000, 0);
        snap.executionFeeBps = 1;
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 100_000_000);
        assertTrue(delta.valid);
        assertEq(delta.actionChargeFromReleasedMarginAssets, 10_000);
        assertEq(delta.safeMarginReleaseAssets, 10_000);
        assertEq(delta.netReleasedMarginAssets, 0);
        snap = _snapshot(2, 200_020_000, CfdTypes.Side.LONG, 20_000, 0);
        snap.executionFeeBps = 1;
        delta = _plan(snap, 1, 100_010_000);
        assertFalse(delta.valid);
        assertEq(delta.actionChargeToCollectAssets, 10_001);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE));
    }

    function test_ClaimsSupportHealthButCannotPayCashFees() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.LONG, 0, 1e9);
        snap.executionFeeBps = 1;
        snap.riskParams.maintMarginBps = 200;
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 100_000_000);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE));
        assertEq(delta.pricePnlClaimConsumedAssets, 0);
    }

    function test_ImmediateAndDeferredGainsHaveSameResidualEquity() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 10e6, 0);
        snap.riskParams.maintMarginBps = 200;
        snap.executionFeeBps = 1;
        CfdEnginePlanTypes.CloseDelta memory immediate = _plan(snap, 1, 101_000_000);
        snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 10e6, 0);
        snap.riskParams.maintMarginBps = 200;
        snap.executionFeeBps = 1;
        snap.poolCashAssets = 0;
        CfdEnginePlanTypes.CloseDelta memory deferred = _plan(snap, 1, 101_000_000);
        assertTrue(immediate.valid && deferred.valid);
        assertTrue(immediate.pricePayoutIsImmediate);
        assertTrue(deferred.pricePayoutCreatesClaim);
        assertEq(immediate.safeMarginReleaseAssets, deferred.safeMarginReleaseAssets);
        assertEq(immediate.posMarginAfter, deferred.posMarginAfter + deferred.pricePayoutAssets);
        assertEq(immediate.actionChargeWithheldAssets, deferred.actionChargeWithheldAssets);
    }

    function _snapshot(
        uint256 lots,
        uint256 entryCostAssetAtoms,
        CfdTypes.Side side,
        uint256 pledgeAssets,
        uint256 claimAssets
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 size = lots * CfdTypes.SIZE_QUANTUM;
        uint256 maxProfitAssets = CfdMath.calculateExactMaxProfit(lots, entryCostAssetAtoms, side, CAP_PRICE);
        snap.position = CfdTypes.Position({
            size: size,
            margin: pledgeAssets,
            entryPrice: entryCostAssetAtoms / lots,
            maxProfitAssets: maxProfitAssets,
            side: side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostAssetAtoms = entryCostAssetAtoms;
        snap.account = ACCOUNT;
        CfdEnginePlanTypes.SideSnapshot memory selected = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: maxProfitAssets,
            openInterest: size,
            entryNotional: entryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE,
            totalMargin: pledgeAssets,
            borrowBaseAssets: 0,
            carryIndex: 0
        });
        if (side == CfdTypes.Side.LONG) {
            snap.longSide = selected;
        } else {
            snap.shortSide = selected;
        }
        snap.poolAssets = POOL_LIQUIDITY;
        snap.poolCashAssets = POOL_LIQUIDITY;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: pledgeAssets,
            totalLockedMarginAssets: pledgeAssets,
            activePositionMarginAssets: pledgeAssets,
            otherLockedMarginAssets: 0,
            freeSettlementAssets: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginAssets: pledgeAssets,
            committedOrderMarginAssets: 0,
            reservedSettlementAssets: 0,
            totalLockedMarginAssets: pledgeAssets
        });
        snap.totalTraderClaimBalanceAssets = claimAssets;
        snap.traderClaimBalanceForAccount = claimAssets;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0,
            maintMarginBps: 0,
            initMarginBps: 0,
            fadMarginBps: 0,
            baseCarryBps: 0,
            minBountyAssets: 0,
            bountyBps: 0,
            keeperShareBps: 0,
            protocolShareBps: 0
        });
    }

    function _plan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 closeLots,
        uint256 price
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: closeLots * CfdTypes.SIZE_QUANTUM,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: snap.position.side,
            isClose: true
        });
        delta = CfdEnginePlanLib.planClose(snap, order, price);
    }

}

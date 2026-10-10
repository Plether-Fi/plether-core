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
        assertEq(delta.safeMarginReleaseUsdc, 0, "retain extra pledge instead of rejecting a viable reduction");
        assertEq(delta.posMarginAfter, 2_000_001);
    }

    function test_ActionFundingEqualReleasePassesOneMoreAtomFails() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.LONG, 20_000, 0);
        snap.executionFeeBps = 1;
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 100_000_000);
        assertTrue(delta.valid);
        assertEq(delta.actionChargeFromReleasedMarginUsdc, 10_000);
        assertEq(delta.safeMarginReleaseUsdc, 10_000);
        assertEq(delta.netReleasedMarginUsdc, 0);
        snap = _snapshot(2, 200_020_000, CfdTypes.Side.LONG, 20_000, 0);
        snap.executionFeeBps = 1;
        delta = _plan(snap, 1, 100_010_000);
        assertFalse(delta.valid);
        assertEq(delta.actionChargeToCollectUsdc, 10_001);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE));
    }

    function test_ClaimsSupportHealthButCannotPayCashFees() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.LONG, 0, 1e9);
        snap.executionFeeBps = 1;
        snap.riskParams.maintMarginBps = 200;
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 100_000_000);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE));
        assertEq(delta.pricePnlClaimConsumedUsdc, 0);
    }

    function test_ImmediateAndDeferredGainsHaveSameResidualEquity() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 10e6, 0);
        snap.riskParams.maintMarginBps = 200;
        snap.executionFeeBps = 1;
        CfdEnginePlanTypes.CloseDelta memory immediate = _plan(snap, 1, 101_000_000);
        snap = _snapshot(2, 200_000_000, CfdTypes.Side.SHORT, 10e6, 0);
        snap.riskParams.maintMarginBps = 200;
        snap.executionFeeBps = 1;
        snap.poolCashUsdc = 0;
        CfdEnginePlanTypes.CloseDelta memory deferred = _plan(snap, 1, 101_000_000);
        assertTrue(immediate.valid && deferred.valid);
        assertTrue(immediate.pricePayoutIsImmediate);
        assertTrue(deferred.pricePayoutCreatesClaim);
        assertEq(immediate.safeMarginReleaseUsdc, deferred.safeMarginReleaseUsdc);
        assertEq(immediate.posMarginAfter, deferred.posMarginAfter + deferred.pricePayoutUsdc);
        assertEq(immediate.actionChargeWithheldUsdc, deferred.actionChargeWithheldUsdc);
    }

    function _snapshot(
        uint256 lots,
        uint256 entryCostUsdcAtoms,
        CfdTypes.Side side,
        uint256 pledgeUsdc,
        uint256 claimUsdc
    ) private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 size = lots * CfdTypes.SIZE_QUANTUM;
        uint256 maxProfitUsdc = CfdMath.calculateExactMaxProfit(lots, entryCostUsdcAtoms, side, CAP_PRICE);
        snap.position = CfdTypes.Position({
            size: size,
            margin: pledgeUsdc,
            entryPrice: entryCostUsdcAtoms / lots,
            maxProfitUsdc: maxProfitUsdc,
            side: side,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = entryCostUsdcAtoms;
        snap.account = ACCOUNT;
        CfdEnginePlanTypes.SideSnapshot memory selected = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: maxProfitUsdc,
            openInterest: size,
            entryNotional: entryCostUsdcAtoms * CfdMath.USDC_TO_TOKEN_SCALE,
            totalMargin: pledgeUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        if (side == CfdTypes.Side.LONG) {
            snap.longSide = selected;
        } else {
            snap.shortSide = selected;
        }
        snap.poolAssetsUsdc = POOL_LIQUIDITY;
        snap.poolCashUsdc = POOL_LIQUIDITY;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: pledgeUsdc,
            totalLockedMarginUsdc: pledgeUsdc,
            activePositionMarginUsdc: pledgeUsdc,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: pledgeUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: pledgeUsdc
        });
        snap.totalTraderClaimBalanceUsdc = claimUsdc;
        snap.traderClaimBalanceForAccount = claimUsdc;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0,
            maintMarginBps: 0,
            initMarginBps: 0,
            fadMarginBps: 0,
            baseCarryBps: 0,
            minBountyUsdc: 0,
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
        delta = CfdEnginePlanLib.planClose(snap, order, price, 0);
    }

}

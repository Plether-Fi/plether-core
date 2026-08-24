// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exact-atom regressions for partition-invariant terminal price accounting on partial closes.
contract TerminalNavCloseConservationTest is Test {

    uint256 private constant CAP_PRICE = 200_000_000;
    uint256 private constant POOL_LIQUIDITY = 1e30;
    address private constant ACCOUNT = address(0xA11CE);

    function test_OneAtomBasisRemainderConsumesMoreThanProRataPledge() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 1, CfdTypes.Side.BULL, 1, 0);
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, 1, 1);

        assertTrue(delta.valid, "exact-atom partial close must be valid");
        assertEq(delta.closeState.closedEntryCostUsdcAtoms, 0, "basis floor assigns no atom to first lot");
        assertEq(delta.closeState.remainingEntryCostUsdcAtoms, 1, "basis remainder must stay on open lot");
        assertEq(delta.closeState.marginToFreeUsdc, 0, "pro-rata pledge allocation rounds to zero");
        assertEq(delta.pricePnlPledgeConsumedUsdc, 1, "conservation requires one atom above pro-rata allocation");
        assertEq(delta.unlockMarginUsdc, 0, "no pledge atom remains available to unlock");
        assertEq(delta.posMarginAfter, 0, "the remaining zero-loss curve needs no collectible cap");
        _assertTerminalConservation(snap, delta, 1);
    }

    function test_MaterialClaimAndPledgeSplitMatchesOneShotTerminalRecovery() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(2, 20, CfdTypes.Side.BULL, 100, 100);
        CfdEnginePlanTypes.CloseDelta memory firstHalf = _plan(snap, 1, 100);
        CfdEnginePlanTypes.CloseDelta memory oneShot = _plan(snap, 2, 100);

        assertTrue(firstHalf.valid, "split close must be valid");
        assertTrue(oneShot.valid, "one-shot close must be valid");
        assertEq(firstHalf.priceLossUsdc, 90, "first half must realize its exact basis loss");
        assertEq(firstHalf.pricePnlClaimConsumedUsdc, 90, "same-account claim must net first");
        assertEq(firstHalf.pricePnlPledgeConsumedUsdc, 0, "claim fully covers first-half loss");
        assertEq(firstHalf.posMarginAfter, 80, "thirty atoms of closed pledge stay to cap the remainder");
        assertEq(firstHalf.unlockMarginUsdc, 20, "only surplus pledge may unlock");

        uint256 splitRecovery =
            firstHalf.pricePnlClaimConsumedUsdc + firstHalf.pricePnlPledgeConsumedUsdc + _postTerminalLoss(firstHalf);
        uint256 oneShotRecovery = oneShot.pricePnlClaimConsumedUsdc + oneShot.pricePnlPledgeConsumedUsdc;
        assertEq(splitRecovery, 180, "split recovery must preserve the pre-close terminal value");
        assertEq(splitRecovery, oneShotRecovery, "split and one-shot recovery must be identical");
        _assertTerminalConservation(snap, firstHalf, 100);
    }

    function testFuzz_PartialPriceLossPreservesTerminalValue(
        uint112 lotsSeed,
        uint112 closeLotsSeed,
        uint32 priceSeed,
        uint144 entrySeed,
        uint144 pledgeSeed,
        uint144 claimSeed,
        bool isBear
    ) public pure {
        uint256 lots = bound(uint256(lotsSeed), 2, 1000);
        uint256 closeLots = bound(uint256(closeLotsSeed), 1, lots - 1);
        CfdTypes.Side side = isBear ? CfdTypes.Side.BEAR : CfdTypes.Side.BULL;
        uint256 price;
        uint256 entryCost;
        if (side == CfdTypes.Side.BULL) {
            price = bound(uint256(priceSeed), 1, CAP_PRICE);
            // BULL loses when the mark rises; keep every lot at least one atom below the mark.
            entryCost = bound(uint256(entrySeed), 0, lots * (price - 1));
        } else {
            price = bound(uint256(priceSeed), 0, CAP_PRICE - 1);
            // BEAR loses when the mark falls; keep every lot at least one atom above the mark.
            entryCost = bound(uint256(entrySeed), lots * (price + 1), lots * CAP_PRICE);
        }
        uint256 pledge = bound(uint256(pledgeSeed), 0, 1e12);
        uint256 claim = bound(uint256(claimSeed), 0, 1e12);

        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(lots, entryCost, side, pledge, claim);
        CfdEnginePlanTypes.CloseDelta memory delta = _plan(snap, closeLots, price);

        assertTrue(delta.valid, "isolated partial price loss must remain valid");
        assertLt(delta.realizedPnlUsdc, 0, "fuzz domain must realize a trader price loss");
        assertEq(
            delta.pricePnlClaimConsumedUsdc + delta.pricePnlPledgeConsumedUsdc + delta.priceLossWrittenOffUsdc,
            delta.priceLossUsdc,
            "every price-loss atom must be recovered or explicitly written off"
        );
        assertEq(
            delta.posMarginAfter + delta.pricePnlPledgeConsumedUsdc + delta.unlockMarginUsdc,
            pledge,
            "pledge consumption, retention, and unlock must conserve collateral"
        );
        _assertTerminalConservation(snap, delta, price);
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
        if (side == CfdTypes.Side.BULL) {
            snap.bullSide = selected;
        } else {
            snap.bearSide = selected;
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

    function _assertTerminalConservation(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint256 price
    ) private pure {
        uint256 lots = CfdMath.sizeToLots(snap.position.size);
        uint256 rawPreLoss = _rawLpLoss(lots, snap.positionEntryCostUsdcAtoms, snap.position.side, price);
        uint256 preCap = snap.position.margin + snap.traderClaimBalanceForAccount;
        uint256 preTerminalLoss = rawPreLoss < preCap ? rawPreLoss : preCap;
        uint256 realizedRecovery = delta.pricePnlClaimConsumedUsdc + delta.pricePnlPledgeConsumedUsdc;
        assertEq(
            realizedRecovery + _postTerminalLoss(delta),
            preTerminalLoss,
            "realized recovery plus the remaining curve must equal pre-close terminal value"
        );
    }

    function _postTerminalLoss(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (uint256 terminalLoss) {
        uint256 remainingLots = CfdMath.sizeToLots(delta.closeState.remainingSize);
        if (remainingLots == 0) {
            return 0;
        }
        uint256 rawLoss =
            _rawLpLoss(remainingLots, delta.closeState.remainingEntryCostUsdcAtoms, delta.side, delta.price);
        uint256 remainingCap = delta.posMarginAfter + delta.existingTraderClaimRemainingUsdc;
        terminalLoss = rawLoss < remainingCap ? rawLoss : remainingCap;
    }

    function _rawLpLoss(
        uint256 lots,
        uint256 entryCostUsdcAtoms,
        CfdTypes.Side side,
        uint256 price
    ) private pure returns (uint256 lossUsdc) {
        uint256 exitValueUsdcAtoms = lots * price;
        if (side == CfdTypes.Side.BULL) {
            lossUsdc = exitValueUsdcAtoms - entryCostUsdcAtoms;
        } else {
            lossUsdc = entryCostUsdcAtoms - exitValueUsdcAtoms;
        }
    }

}

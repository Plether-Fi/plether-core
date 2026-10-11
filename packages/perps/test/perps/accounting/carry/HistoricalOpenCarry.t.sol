// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CarryReferenceLedger} from "../../invariant/ghost/CarryReferenceLedger.sol";
import {MixedLpTestHarness} from "../../invariant/support/MixedLpTestHarness.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

/// @notice Historical first opens must checkpoint old aggregate borrowing before inserting new exposure.
/// @dev All expected clocks, bases and depth come from submitted inputs in the independent mixed ledger.
/// No Engine index, observed position, preview, or event is used to calculate an expected value.
contract HistoricalOpenCarryTest is BasePerpTest {

    MixedLpTestHarness private handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.005e18;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();
        handler = new MixedLpTestHarness(
            usdc,
            baseMockPyth,
            engine,
            clearinghouse,
            pool,
            juniorVault,
            seniorVault,
            OrderRouter(address(router)),
            address(this)
        );
        // Both directional indexes have economically meaningful old borrowing when the new actor enters.
        handler.openOrIncrease(1, 200, 80_000_002);
        handler.openOrIncrease(2, 180, 120_000_002);
    }

    function test_HistoricalLongOpenCheckpointsBothOldBorrowBasesBeforeNewExposure() public {
        _historicalOpenAndNextCheckpoint(0);
        assertEq(engine.positionEpoch(handler.actorAt(0)), 1);
    }

    function test_HistoricalShortOpenCheckpointsBothOldBorrowBasesBeforeNewExposure() public {
        _historicalOpenAndNextCheckpoint(3);
        assertEq(engine.positionEpoch(handler.actorAt(3)), 1);
    }

    function test_HistoricalReopenUsesNewGenerationWithoutRetroactiveBorrowing() public {
        handler.openOrIncrease(0, 17, 80_000_002);
        handler.advanceAndCheckpoint(1 hours);
        assertGt(handler.carry().accountState(handler.actorAt(0)).totalNewCarry, 0);
        handler.close(0, 0, true);
        assertEq(handler.traderState(0).lots, 0);
        assertEq(engine.positionEpoch(handler.actorAt(0)), 1);
        _historicalOpenAndNextCheckpoint(0);
        assertEq(engine.positionEpoch(handler.actorAt(0)), 2, "same address starts a new position generation");
    }

    function _historicalOpenAndNextCheckpoint(
        uint256 actor
    ) private {
        uint256 oldGenerationCarry = handler.carry().accountState(handler.actorAt(actor)).totalNewCarry;
        handler.commitOpen(actor, 17, 80_000_002);
        handler.refreshMark(120_000_002); // The actual first publication after commitment fixes the fill.
        vm.warp(vm.getBlockTimestamp() + 5);
        handler.refreshMark(90_000_002); // A newer accounting mark must survive execution of the older fill.
        uint256 retainedMarkTime = vm.getBlockTimestamp();
        uint256 fillTime = retainedMarkTime + 1; // executeHead advances one block and one wall-clock second.
        CarryReferenceLedger ledger = handler.carry();
        uint256 longAtFill;
        uint256 shortAtFill;
        {
            CarryReferenceLedger.Side memory oldLong = ledger.sideState(0);
            CarryReferenceLedger.Side memory oldShort = ledger.sideState(1);
            uint256 oldDepth = _depth();
            longAtFill = oldLong.index + _increment(oldLong.borrowBase, oldDepth, fillTime - oldLong.timestamp);
            shortAtFill = oldShort.index + _increment(oldShort.borrowBase, oldDepth, fillTime - oldShort.timestamp);
            assertGt(longAtFill, oldLong.index, "old Long exposure accrues before new exposure is added");
            assertGt(shortAtFill, oldShort.index, "old Short exposure accrues before new exposure is added");
        }

        handler.executeHead(false);
        assertEq(handler.traderState(actor).basis, 17 * 120_000_002, "historical fill remains the entry basis");
        assertEq(engine.lastMarkPrice(), 90_000_002, "older fill cannot replace the newer cached price");
        assertEq(engine.lastMarkTime(), retainedMarkTime, "mark age and carry checkpoint time are distinct");
        assertEq(engine.sideCarryTimestamp(0), fillTime);
        assertEq(engine.sideCarryTimestamp(1), fillTime);
        assertEq(engine.sideCarryIndex(0), longAtFill, "old Long basis covers only its own elapsed interval");
        assertEq(engine.sideCarryIndex(1), shortAtFill, "old Short basis covers only its own elapsed interval");
        CarryReferenceLedger.Account memory opened = ledger.accountState(handler.actorAt(actor));
        assertEq(opened.lastIndex, actor % 2 == 0 ? longAtFill : shortAtFill);
        assertEq(opened.lastTime, fillTime);
        assertEq(opened.totalNewCarry, oldGenerationCarry, "new position owes no pre-open carry");
        _nextCheckpoint(ledger, actor, opened, longAtFill, shortAtFill);
    }

    function _nextCheckpoint(
        CarryReferenceLedger ledger,
        uint256 actor,
        CarryReferenceLedger.Account memory opened,
        uint256 longAtFill,
        uint256 shortAtFill
    ) private {
        uint256 depthAfterOpen = _depth();
        uint256 longAfter = longAtFill + _increment(ledger.sideState(0).borrowBase, depthAfterOpen, 1 hours);
        uint256 shortAfter = shortAtFill + _increment(ledger.sideState(1).borrowBase, depthAfterOpen, 1 hours);
        uint256 targetDelta = (actor % 2 == 0 ? longAfter : shortAfter) - opened.lastIndex;
        uint256 carryForNewInterval = opened.borrowBase * targetDelta / 1e18;
        assertGt(carryForNewInterval, 0, "the next assessment has an independently measurable economic effect");
        handler.advanceAndCheckpoint(1 hours);
        assertEq(engine.sideCarryIndex(0), longAfter, "new Long basis applies only after the actual open");
        assertEq(engine.sideCarryIndex(1), shortAfter, "new Short basis applies only after the actual open");
        CarryReferenceLedger.Account memory assessed = ledger.accountState(handler.actorAt(actor));
        assertEq(assessed.totalNewCarry - opened.totalNewCarry, carryForNewInterval);
        assertEq(assessed.pledge, opened.pledge - carryForNewInterval, "only post-open carry debits new pledge");
        handler.assertModel();
    }

    function _depth() private view returns (uint256) {
        uint256 cash = handler.expectedPoolCash();
        uint256 accounted = handler.expectedAccounted();
        return cash < accounted ? cash : accounted;
    }

    function _increment(
        uint256 borrow,
        uint256 depth,
        uint256 elapsed
    ) private pure returns (uint256) {
        uint256 utilization = borrow == 0 ? 0 : depth == 0 || borrow >= depth ? 10_000 : borrow * 10_000 / depth;
        return 500 * utilization * elapsed * 1e18 / (365 days * 10_000 * 10_000);
    }

}

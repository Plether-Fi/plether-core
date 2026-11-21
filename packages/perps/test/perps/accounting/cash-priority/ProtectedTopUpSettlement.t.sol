// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract ProtectedTopUpClearinghouseHarness is MarginClearinghouse {

    constructor(
        address token
    ) MarginClearinghouse(token) {}

    /// @dev Other buckets are funded and locked through the normal custody entrypoints.
    function seedProtectedTopUp(
        address account,
        uint256 pledged,
        uint256 released
    ) external {
        protectedTopUps[account] = ProtectedTopUp(pledged, released);
    }

}

contract ProtectedTopUpSettlementTest is Test {

    address internal constant TRADER = address(0xA11CE);
    address internal constant RECIPIENT = address(0xCEE);
    uint64 internal constant ORDER_ID = 1;

    struct Funding {
        uint256 ordinaryPledge;
        uint256 protectedPledge;
        uint256 released;
        uint256 free;
        uint256 committed;
        uint256 actionReserve;
    }

    MockSettlementToken internal token;
    ProtectedTopUpClearinghouseHarness internal clearinghouse;

    function setUp() public {
        token = new MockSettlementToken();
        clearinghouse = new ProtectedTopUpClearinghouseHarness(address(token));
        clearinghouse.setEngine(address(this));
    }

    function realizeCarryBeforeMarginChange(
        address
    ) external pure {}

    function checkWithdraw(
        address
    ) external pure {}

    function test_ReleasedTopUpStaysLockedForWithdrawalAndOpenCosts() public {
        _fund(Funding(0, 25e6, 50e6, 0, 0, 0));

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        vm.prank(TRADER);
        clearinghouse.withdraw(TRADER, 1);

        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.applyOpenCost(TRADER, 0, 1, RECIPIENT, address(0), 0);
        assertEq(clearinghouse.balanceAssets(TRADER), 75e6);
        _assertProtected(25e6, 50e6);

        clearinghouse.releaseProtectedTopUp(TRADER);
        _assertProtected(0, 0);
        assertEq(clearinghouse.eligiblePositionMarginAssets(TRADER), 25e6);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(TRADER), 50e6);
        vm.prank(TRADER);
        clearinghouse.withdraw(TRADER, 50e6);
        assertEq(token.balanceOf(TRADER), 50e6);
        assertEq(clearinghouse.balanceAssets(TRADER), 25e6);
    }

    function test_CloseActionChargeCollectsReleasedTopUpBeforeCommittedMargin() public {
        _fund(Funding(25e6, 15e6, 55e6, 15e6, 30e6, 10e6));

        (uint256 collected,) = clearinghouse.consumeActionCharge(TRADER, 40e6, 10e6, 0, RECIPIENT, address(0), 0);
        assertEq(collected, 40e6);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(TRADER), 0);
        assertEq(clearinghouse.actionReserveAssets(TRADER), 0);
        assertEq(clearinghouse.getOrderReservation(ORDER_ID).remainingAmountAssets, 30e6);
        _assertProtected(15e6, 40e6);

        (collected,) = clearinghouse.consumeActionCharge(TRADER, 65e6, 0, 25e6, RECIPIENT, address(0), 0);
        assertEq(collected, 65e6);
        assertEq(clearinghouse.getOrderReservation(ORDER_ID).remainingAmountAssets, 5e6);
        _assertProtected(15e6, 0);
        assertEq(clearinghouse.pnlPledgeAssets(TRADER), 40e6);
        assertEq(clearinghouse.balanceAssets(TRADER), 45e6);
        assertEq(token.balanceOf(address(clearinghouse)), 45e6);
        assertEq(token.balanceOf(RECIPIENT), 105e6);
    }

    function test_CloseActionKeepsUnusedNewReleaseProtected() public {
        _fund(Funding(15e6, 25e6, 20e6, 5e6, 20e6, 5e6));

        clearinghouse.unlockCloseMargin(TRADER, 20e6, 15e6, 5e6, 25e6, 0);
        _assertProtected(20e6, 25e6);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(TRADER), 20e6);

        (uint256 collected,) = clearinghouse.consumeActionCharge(TRADER, 25e6, 5e6, 0, RECIPIENT, address(0), 0);
        assertEq(collected, 25e6);
        assertEq(clearinghouse.getOrderReservation(ORDER_ID).remainingAmountAssets, 20e6);
        _assertProtected(20e6, 25e6);
        assertEq(clearinghouse.balanceAssets(TRADER), 65e6);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(TRADER), 0);
    }

    function test_RiskReducingCarryHasAccessToBothProtectedBalances() public {
        _assertCarryCollection(Funding(0, 25e6, 50e6, 10e6, 20e6, 5e6), 55e6, true);
    }

    function test_TerminalCloseAssessmentMatchesProtectedSettlement() public {
        _fund(Funding(10e6, 15e6, 60e6, 0, 0, 0));
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _snapshot(2e6);
        CfdTypes.Order memory order;
        order.account = TRADER;
        order.sizeDelta = snapshot.position.size;
        order.isClose = true;
        CfdEnginePlanTypes.CloseDelta memory delta = (new CfdEnginePlanner()).planClose(snapshot, order, 100_500_000);
        assertTrue(delta.valid);
        assertEq(delta.realizedCarryAssets, 2e6);
        assertEq(delta.pricePnlPledgeConsumedAssets, 23e6);
        assertGt(delta.actionChargeAssessedAssets, 0);
        assertEq(delta.actionChargeCollectedAssets, delta.actionChargeAssessedAssets);
        assertEq(delta.actionChargeWaivedAssets, 0);

        OrderV3Types.ExecutionBounds memory bounds;
        bounds.allowedExecutionModes = 1;
        bounds.maxExecutionNotionalAssets = type(uint256).max;
        bounds.maxGrossAccountDebitAssets = type(uint256).max;
        bounds.maxActionChargeAssets = type(uint256).max;
        bounds.maxExplicitFeesAssets = type(uint256).max;
        OrderV3Types.ExecutionAssessment memory assessment =
            (new CfdOrderPolicyEvaluator()).evaluateClose(snapshot, delta, bounds, 0);
        _applyTerminalCloseCash(delta);
        _assertProtected(0, 60e6 - delta.actionChargeCollectedAssets);
        assertEq(assessment.postSettlementBalanceAssets, clearinghouse.balanceAssets(TRADER));
        assertEq(assessment.close.postFreeSettlementAssets, clearinghouse.getFreeBuyingPowerAssets(TRADER));
        assertEq(assessment.close.postFreeSettlementAssets, 0);
    }

    function test_LiquidationHealthCountsReleasedTopUpForCarry() public {
        _fund(Funding(10e6, 15e6, 60e6, 0, 0, 0));
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _snapshot(40e6);
        snapshot.traderClaimBalanceForAccount = 300e6;
        snapshot.totalTraderClaimBalanceAssets = 300e6;

        CfdEnginePlanTypes.LiquidationDelta memory delta = (new CfdEnginePlanner()).planLiquidation(snapshot, 1e8);
        assertEq(delta.pendingCarryAssets, 40e6);
        assertEq(delta.realizedCarryAssets, 40e6);
        assertEq(delta.riskState.equityAssets, 300e6);
        assertFalse(delta.liquidatable);
    }

    function test_PartialCloseCommitLeavesProtectedCarryForFill() public {
        _fund(Funding(10e6, 15e6, 60e6, 0, 0, 0));
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _snapshot(40e6);
        snapshot.traderClaimBalanceForAccount = 300e6;
        snapshot.totalTraderClaimBalanceAssets = 300e6;
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdTypes.Order memory order;
        order.account = TRADER;
        order.sizeDelta = snapshot.position.size / 2;
        order.isClose = true;

        CfdEnginePlanTypes.CloseCommitment memory commitment = planner.planCloseCommit(snapshot, order.sizeDelta);
        assertEq(commitment.carryCollectedAssets, 10e6);
        assertEq(commitment.carryOutstandingAssets, 30e6);

        (,, uint256 carryOutstanding) = clearinghouse.consumePositionCarry(TRADER, 40e6, RECIPIENT, false);
        assertEq(carryOutstanding, commitment.carryOutstandingAssets);
        assertEq(commitment.settlementAfterAssets, clearinghouse.balanceAssets(TRADER));
        assertEq(commitment.freeSettlementAfterAssets, clearinghouse.getFreeBuyingPowerAssets(TRADER));
        _assertProtected(15e6, 60e6);

        snapshot = _snapshot(carryOutstanding);
        snapshot.traderClaimBalanceForAccount = 300e6;
        snapshot.totalTraderClaimBalanceAssets = 300e6;
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snapshot, order, snapshot.lastMarkPrice);
        assertTrue(delta.valid);
        assertEq(delta.realizedCarryAssets, carryOutstanding);
    }

    function testFuzz_CarryProjectionMatchesProtectedCustody(
        uint32 ordinaryPledge,
        uint32 protectedPledge,
        uint32 released,
        uint32 free,
        uint64 dueSeed,
        bool reducing
    ) public {
        Funding memory funding =
            Funding(ordinaryPledge, uint256(protectedPledge) + 1, uint256(released) + 1, free, 5, 7);
        uint256 due =
            bound(dueSeed, 0, funding.ordinaryPledge + funding.protectedPledge + funding.released + funding.free + 1);
        _assertCarryCollection(funding, due, reducing);
    }

    function _assertCarryCollection(
        Funding memory funding,
        uint256 due,
        bool reducing
    ) internal {
        _fund(funding);
        uint256 expectedPledgeDebit = _min(due, funding.ordinaryPledge + (reducing ? funding.protectedPledge : 0));
        uint256 expectedFreeDebit = _min(due - expectedPledgeDebit, funding.free);
        uint256 expectedReleasedDebit =
            reducing ? _min(due - expectedPledgeDebit - expectedFreeDebit, funding.released) : 0;
        uint256 protectedPledgeAfter =
            _min(funding.protectedPledge, funding.ordinaryPledge + funding.protectedPledge - expectedPledgeDebit);

        (
            MarginClearinghouseAccountingLib.SettlementConsumption memory projection,
            IMarginClearinghouse.AccountAssetBuckets memory afterBuckets
        ) = MarginClearinghouseAccountingLib.projectCarryLoss(
            clearinghouse.getAccountAssetBuckets(TRADER),
            due,
            reducing ? 0 : funding.protectedPledge,
            reducing ? funding.released : 0
        );
        assertEq(projection.otherLockedMarginConsumedAssets, expectedReleasedDebit);
        assertEq(projection.totalConsumedAssets, expectedPledgeDebit + expectedFreeDebit + expectedReleasedDebit);

        (uint256 pledgeDebit, uint256 freeDebit, uint256 uncovered) =
            clearinghouse.consumePositionCarry(TRADER, due, RECIPIENT, reducing);
        assertEq(pledgeDebit, expectedPledgeDebit);
        assertEq(freeDebit, expectedFreeDebit);
        assertEq(uncovered, due - projection.totalConsumedAssets);
        assertEq(
            keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(TRADER))), keccak256(abi.encode(afterBuckets))
        );
        _assertProtected(protectedPledgeAfter, funding.released - expectedReleasedDebit);
        assertEq(clearinghouse.getOrderReservation(ORDER_ID).remainingAmountAssets, funding.committed);
        assertEq(clearinghouse.actionReserveAssets(TRADER), funding.actionReserve);
        assertEq(token.balanceOf(address(clearinghouse)), afterBuckets.settlementBalanceAssets);
        assertEq(token.balanceOf(RECIPIENT), projection.totalConsumedAssets);
    }

    function _fund(
        Funding memory funding
    ) internal {
        uint256 pledged = funding.ordinaryPledge + funding.protectedPledge;
        uint256 total = pledged + funding.released + funding.free + funding.committed + funding.actionReserve;
        token.mint(address(this), total);
        token.approve(address(clearinghouse), total);
        clearinghouse.depositFor(TRADER, total);
        clearinghouse.lockPositionMargin(TRADER, pledged);
        if (funding.committed != 0) {
            clearinghouse.reserveCommittedOrderMargin(TRADER, ORDER_ID, funding.committed);
        }
        if (funding.actionReserve != 0) {
            clearinghouse.lockReservedSettlement(TRADER, funding.actionReserve);
        }
        clearinghouse.seedProtectedTopUp(TRADER, funding.protectedPledge, funding.released);
        assertEq(clearinghouse.getFreeBuyingPowerAssets(TRADER), funding.free);
        assertEq(clearinghouse.eligiblePositionMarginAssets(TRADER), funding.ordinaryPledge);
    }

    function _snapshot(
        uint256 unpaidCarry
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.account = TRADER;
        snapshot.currentTimestamp = 1;
        snapshot.lastMarkTime = 1;
        snapshot.lastMarkPrice = 1e8;
        snapshot.capPrice = 2e8;
        snapshot.position.size = 10_000e18;
        snapshot.position.entryPrice = 1e8;
        snapshot.position.maxProfitAssets = 10_000e6;
        snapshot.position.margin = clearinghouse.pnlPledgeAssets(TRADER);
        snapshot.positionEntryCostAssetAtoms = CfdMath.sizeToLots(snapshot.position.size) * snapshot.position.entryPrice;
        snapshot.positionBorrowBaseAssets =
            snapshot.position.maxProfitAssets - clearinghouse.eligiblePositionMarginAssets(TRADER);
        snapshot.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: snapshot.position.maxProfitAssets,
            openInterest: snapshot.position.size,
            entryNotional: snapshot.positionEntryCostAssetAtoms * CfdMath.ASSETS_TO_TOKEN_SCALE,
            totalMargin: snapshot.position.margin,
            borrowBaseAssets: snapshot.positionBorrowBaseAssets,
            carryIndex: 0
        });
        snapshot.poolAssets = 1_000_000e6;
        snapshot.poolCashAssets = 1_000_000e6;
        snapshot.accountBuckets = clearinghouse.getAccountAssetBuckets(TRADER);
        snapshot.lockedBuckets = clearinghouse.getLockedMarginBuckets(TRADER);
        (snapshot.protectedPositionMarginAssets, snapshot.protectedReleasedMarginAssets) =
            clearinghouse.protectedTopUps(TRADER);
        snapshot.riskParams.maintMarginBps = 100;
        snapshot.riskParams.maxSkewRatio = 1e18;
        snapshot.executionFeeBps = 4;
        snapshot.unsettledCarryAssets = unpaidCarry;
    }

    function _applyTerminalCloseCash(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) internal {
        clearinghouse.consumePositionCarry(TRADER, delta.pendingCarryAssets, RECIPIENT, true);
        clearinghouse.consumePnlPledgeLoss(TRADER, delta.pricePnlPledgeConsumedAssets, RECIPIENT);
        clearinghouse.unlockCloseMargin(
            TRADER,
            delta.safeMarginReleaseAssets,
            delta.actionChargeFromReleasedMarginAssets,
            delta.netReleasedMarginAssets,
            delta.actionChargeToCollectAssets,
            0
        );
        clearinghouse.consumeActionCharge(
            TRADER,
            delta.actionChargeToCollectAssets,
            delta.actionReserveConsumedAssets,
            delta.actionCommittedMarginConsumedAssets,
            RECIPIENT,
            address(0),
            0
        );
    }

    function _assertProtected(
        uint256 pledged,
        uint256 released
    ) internal view {
        (uint256 livePledged, uint256 liveReleased) = clearinghouse.protectedTopUps(TRADER);
        assertEq(livePledged, pledged);
        assertEq(liveReleased, released);
    }

    function _min(
        uint256 left,
        uint256 right
    ) internal pure returns (uint256) {
        return left < right ? left : right;
    }

}

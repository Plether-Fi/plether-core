// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {MixedLpTestHarness} from "../support/MixedLpTestHarness.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

contract PerpMixedAccountingInvariantTest is BasePerpTest {

    MixedLpTestHarness internal handler;

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
        handler.assertModel();
        handler.exerciseRestoredSolventEscrowHistory();
        _seedInterimLpClaims();
        handler.openOrIncrease(0, 300, 120_000_003);
        handler.requestJuniorDeposit(0, 1500e6);
        handler.openOrIncrease(1, 100, 80_000_001);
        handler.openOrIncrease(2, 150, 80_000_001);
        handler.openOrIncrease(0, 25, 110_000_003);
        handler.close(2, 50, false);
        handler.commitPledgeFundedClose(0, true);
        handler.settleJuniorEpoch(true);
        handler.expirePending(0);
        handler.claimJuniorDeposit(0);
        handler.requestJuniorDeposit(1, 1000e6);
        handler.cancelJuniorDeposit(1);
        handler.createDeferredClaimHistory();
        handler.settleClaim(0);
        handler.freezeOrThaw(true);
        handler.close(2, 0, true);
        handler.freezeOrThaw(false);
        handler.openOrIncrease(2, 101, 120_000_001);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.cancelJuniorRedeem(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorRedeem(0);
        for (uint256 i; i < 4; ++i) {
            handler.close(i, 0, true);
        }
        handler.requestJuniorDeposit(1, 2000e6);
        handler.exerciseArrearsAndReuse();
        handler.settleJuniorEpoch(true);
        handler.claimJuniorDeposit(1);
        handler.exerciseLiquidationHistory(0, 2);
        handler.exerciseLiquidationHistory(1, 3);
        handler.exerciseLiquidationHistory(2, 10);
        handler.exerciseLiquidationHistory(3, 11);
        handler.openOrIncrease(0, 251, 120_000_003);
        handler.openOrIncrease(1, 117, 80_000_001);
        handler.exercisePendingHistories();
        handler.exercisePledgeEscrowFailureHistory();

        // Commitments persist across independently generated economic actions. The synchronous helpers above
        // remain deterministic setup conveniences; generated trading uses the public queue lifecycle below.
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = handler.commitOpen.selector;
        selectors[1] = handler.commitClose.selector;
        selectors[2] = handler.advanceAndCheckpoint.selector;
        selectors[3] = handler.addCollateral.selector;
        selectors[4] = handler.freezeOrThaw.selector;
        selectors[5] = handler.requestJuniorDeposit.selector;
        selectors[6] = handler.cancelJuniorDeposit.selector;
        selectors[7] = handler.settleJuniorEpoch.selector;
        selectors[8] = handler.claimJuniorDeposit.selector;
        selectors[9] = handler.settleClaim.selector;
        selectors[10] = handler.requestJuniorRedeem.selector;
        selectors[11] = handler.cancelJuniorRedeem.selector;
        selectors[12] = handler.claimJuniorRedeem.selector;
        selectors[13] = handler.refreshMark.selector;
        selectors[14] = handler.liquidateAndReuse.selector;
        selectors[15] = handler.withdrawFreeCollateral.selector;
        selectors[16] = handler.claimJuniorRedeemShares.selector;
        selectors[17] = handler.claimJuniorWithdraw.selector;
        selectors[18] = handler.claimJuniorRedeemRefund.selector;
        selectors[19] = handler.executeHead.selector;
        selectors[20] = handler.executeBatch.selector;
        selectors[21] = handler.expirePending.selector;
        selectors[22] = handler.replayPending.selector;
        selectors[23] = handler.rejectSixthOrder.selector;
        selectors[24] = handler.pendingSameBlock.selector;
        selectors[25] = handler.pendingMevBoundary.selector;
        selectors[26] = handler.executeSlippageFailure.selector;
        selectors[27] = handler.riskOffPending.selector;
        selectors[28] = handler.commitPledgeFundedClose.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _seedInterimLpClaims() private {
        handler.requestJuniorDeposit(0, 3000e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        uint256 elapsed = handler.lpState(0).redeemEpoch * 1 hours - handler.expectedCouponTime();
        uint256 seniorAtSettlement =
            handler.expectedSenior() + handler.expectedSenior() * 800 * elapsed / (10_000 * 365 days);
        uint256 originalCash = handler.expectedPoolCash();
        handler.changeRawPoolCash(seniorAtSettlement + (seniorAtSettlement + 9998) / 9999 + 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpState(0).claimRedeemAssets, 10_000, "independent partial-funding budget");
        handler.claimJuniorRedeemShares(0, 2);
        handler.claimJuniorWithdraw(0, 2);
        handler.changeRawPoolCash(originalCash - 10_000);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorRedeem(0);
        handler.assertModel();
    }

    function invariant_PersistentPublicMixedAccounting() public view {
        handler.assertModel();
        assertGt(handler.successfulOpens(), 3);
        assertGt(handler.successfulIncreases(), 0);
        assertGt(handler.partialCloses(), 0);
        assertGt(handler.fullCloses(), 0);
        assertGt(handler.positiveVpiActions(), 0);
        assertGt(handler.negativeVpiActions(), 0);
        assertGt(handler.deferredClaims(), 0);
        assertGt(handler.claimBackedPartialCloses(), 0);
        assertGt(handler.settledClaims(), 0);
        assertGt(handler.frozenCloses(), 0);
        assertGt(handler.heldSettlements(), 0);
        assertGt(handler.lpClaims(), 0);
        assertGt(handler.lpCancellations(), 0);
        assertGt(handler.carryCollected(), 0);
        assertGt(handler.arrearsEpisodes(), 0);
        assertGe(handler.liquidations(), 2);
        assertGe(handler.generations(3), 2);
        assertGe(handler.rejectedWithdrawals(), 3);
        assertGt(handler.lpRedemptionRequests(), 0);
        assertGt(handler.lpRedemptionSettlements(), 0);
        assertGt(handler.lpRedemptionClaims(), 0);
        assertGt(handler.lpRedemptionCancellations(), 0);
        assertGt(handler.liquidationsBySide(0), 0);
        assertGt(handler.liquidationsBySide(1), 0);
        assertGt(handler.claimBearingLiquidations(), 0);
        assertGt(handler.unpaidCarryLiquidations(), 0);
        assertGt(handler.positivePnlLiquidations(), 0);
        assertGt(handler.immediateLiquidationPayouts(), 0);
        assertGt(handler.deferredLiquidationPayouts(), 0);
        assertGt(handler.negativeVpiLiquidations(), 0);
        assertGt(handler.lpNonterminalClaims(), 0);
        assertGt(handler.lpClaimsAfterFurtherFunding(), 0);
        assertGt(handler.lpShareClaims(), 0);
        assertGt(handler.lpAssetClaims(), 0);
        assertEq(handler.maximumLiveOrders(), 20);
        assertGe(handler.rejectedSixthOrders(), 4);
        assertGt(handler.overlappingCommits(), 0);
        assertGt(handler.executedDelayedOrders(), 0);
        assertGt(handler.replayedOrders(), 0);
        assertGt(handler.conflictingReplays(), 0);
        assertGt(handler.pendingSameBlockResults(), 0);
        assertGt(handler.pendingMevRejections(), 0);
        assertGt(handler.expiredOrders(), 0);
        assertGt(handler.rejectedEarlyExpiry(), 0);
        assertGt(handler.slippageFailures(), 0);
        assertGt(handler.riskOffOrders(), 0);
        assertGt(handler.completedBatches(), 0);
        assertGt(handler.pendingMarginConsumed(), 0);
        assertGt(handler.mixedFailureRefunds(), 0);
        assertGt(handler.rejectedPledgeOverlap(), 0);
        assertGt(handler.freeOrdersBehindPledgedHead(), 0);
        assertGt(handler.restoredSolventLiquidations(), 0);
        assertGt(handler.pledgeLiquidationRefunds(), 0);
        assertGt(handler.lpEpochsWithCollectibleEscrow(), 0);
    }

    function test_MandatoryPreludeExercisesMixedHistories() public view {
        invariant_PersistentPublicMixedAccounting();
    }

    function test_RegressionOneLotPledgeCloseRejectsZeroSizeWithoutAllocatingOrder() public {
        // Audit seed 0xdeadbeef: two queued partial closes leave exactly one live lot.
        handler.commitClose(21_118, 11_063, false);
        handler.commitClose(
            12_938,
            12_989_514_705_740_598_333_484_151_973_466_354_555_343_510_131_890_239_912_606_811_445_340_916_416_975,
            false
        );
        handler.executeBatch(
            2_837_220_504_266_756_632_723_142_729_865_487_026_003_954_552_410_881_328_926_883_743_677_098
        );
        assertEq(handler.traderState(2).lots, 1, "the generated half-close must round to zero lots");
        uint256 rejectionsBefore = handler.rejectedSmallOrders();
        uint64 cursorBefore = handler.orders().nextId();
        handler.commitPledgeFundedClose(378_607_894_605_621_696_302_822_193_767_330, false);
        assertEq(handler.rejectedSmallOrders(), rejectionsBefore + 1);
        assertEq(handler.orders().nextId(), cursorBefore, "zero-size rejection allocates no order identity");
        assertEq(handler.orders().count(2), 0, "zero-size rejection leaves no reservation or queue entry");
        assertEq(handler.traderState(2).lots, 1, "the rejected close preserves the live position");
        handler.assertModel();

        handler.commitPledgeFundedClose(378_607_894_605_621_696_302_822_193_767_330, true);
        assertEq(handler.orders().count(2), 1, "a full close of the same one-lot position remains valid");
        handler.executeHead(false);
        assertEq(handler.traderState(2).lots, 0, "the valid full close completes");
        assertEq(handler.orders().count(2), 0);
        handler.assertModel();
    }

    function test_RegressionQueuedProjectionDoesNotSatisfyLiveMinimumOpenNotional() public {
        // Audit seed 0xdeadbeef, minimized without changing the submitted action inputs.
        handler.commitClose(327_902_434_968_705_076_393_652_476_002_501_640_834_577_837_043_204_913, 32, true);
        handler.executeHead(true);
        handler.commitOpen(
            100_826_436_524_508_443_061_163_191_620_634_453_116_513_966_566_681_300_926_347_450_229_074_697_899_425,
            661_326_185_454_140_425_211_893_155_309_651_039_604_447,
            770
        );
        uint256 rejectionsBefore = handler.rejectedOpenCommitments();
        uint64 cursorBefore = handler.orders().nextId();
        handler.commitOpen(17_905, 14_527, 73_760);
        assertEq(handler.rejectedOpenCommitments(), rejectionsBefore + 1);
        assertEq(handler.orders().nextId(), cursorBefore, "rejected five-lot open allocates no new identity");
        assertEq(handler.orders().count(1), 1, "the earlier 495-lot reservation remains pending");
        assertEq(handler.traderState(1).lots, 0);
        handler.assertModel();
    }

    function test_RegressionOneLotPledgeCloseDoesNotSubmitZeroSize() public {
        // Audit seed 0x2 shrank to these four public handler actions. Earlier partial closes leave
        // actor 2 with one lot, for which another half-close has no positive size.
        handler.commitPledgeFundedClose(10_786, false);
        handler.commitClose(
            235_399_669_922,
            2_742_752_018_512_376_947_672_463_408_101_996_658_382_367_066_140_257_046_549_603_650_091_881,
            false
        );
        handler.executeBatch(917_127_867_238_270_632_708_738_302_192_089_914);
        assertEq(handler.traderState(2).lots, 1, "shrunk history reaches a one-lot remainder");
        uint64 nextId = handler.orders().nextId();
        uint256 smallRejections = handler.rejectedSmallOrders();
        bytes32 economicsBefore = handler.economicFingerprint(2);
        bytes32 modelBefore = keccak256(abi.encode(handler.traderState(2)));
        uint256 markTimeBefore = handler.currentMarkTime();
        handler.commitPledgeFundedClose(341_821_013_369_658_799_147_725_076_362_896_016_228_270_630_917_724_810, false);
        assertEq(handler.orders().nextId(), nextId, "zero-size partial close is outside generated domain");
        assertEq(handler.rejectedSmallOrders(), smallRejections, "no zero-size request reaches Router validation");
        assertEq(handler.economicFingerprint(2), economicsBefore, "guard runs before any carry or withdrawal");
        assertEq(keccak256(abi.encode(handler.traderState(2))), modelBefore, "ghost balances remain unchanged");
        assertEq(handler.currentMarkTime(), markTimeBefore, "guard does not refresh the mark");
        assertEq(handler.traderState(2).lots, 1);
        handler.assertModel();
    }

    function test_RegressionTinyCarryCashCapsPositiveVpiAfterExternalShock() public {
        handler.openOrIncrease(
            98_649_085_805_498_380_638_313,
            65_334_406_723_469_887_195_895_284_632_339_845_829_231_094_682_571_525,
            271_936_314_260_195_975_302_423_067_331_181_128_781_274_048_493_396_479_409_473_815_292_931_575
        );
        handler.createDeferredClaimHistory();
        assertGt(handler.waivedActionCharges(), 0, "uncollectible terminal action charge must be waived");
        handler.assertModel();
    }

    function test_RegressionClaimBackedDustCloseRejectedBeforeCollection() public {
        handler.createDeferredClaimHistory();
        handler.close(0, 1, false);
        assertEq(handler.rejectedSmallOrders(), 1);
        handler.assertModel();
    }

    function test_RegressionRepeatedDeferredClaimsRetainEconomicHistory() public {
        handler.createDeferredClaimHistory();
        uint256 priorClaims = handler.expectedClaims();
        uint256 priorFunding = handler.explicitFunding();
        handler.createDeferredClaimHistory();
        assertGe(handler.expectedClaims(), priorClaims);
        assertGt(handler.explicitFunding(), priorFunding, "explicit fresh deposit funds reused account");
        handler.assertModel();
    }

    function test_RegressionLpMaturityAcrossWeekendUsesMonotonicLiveCalendar() public {
        uint256 day = vm.getBlockTimestamp() / 1 days;
        uint256 friday = day + (12 - ((day + 4) % 7)) % 7;
        vm.warp(friday * 1 days + 11 hours + 59 minutes);
        handler.advanceAndCheckpoint(1);
        handler.requestJuniorDeposit(0, 1000e6);
        handler.settleJuniorEpoch(false);
        uint256 nowTime = vm.getBlockTimestamp();
        assertEq((nowTime / 1 days + 4) % 7, 1, "weekend maturity waits for Monday");
        handler.claimJuniorDeposit(0);
        handler.freezeOrThaw(true);
        assertGt(vm.getBlockTimestamp(), nowTime, "pre-freeze cache refresh never travels backward");
        handler.assertModel();
    }

    function test_MixedOracleRejectsUnrecordedPoolCash() public {
        usdc.mint(address(pool), 1);
        vm.expectRevert();
        handler.assertModel();
    }

    function test_MixedOracleRejectsCrossAccountCredit() public {
        vm.mockCall(
            address(clearinghouse),
            abi.encodeCall(clearinghouse.balanceUsdc, (handler.actorAt(0))),
            abi.encode(handler.traderState(0).cash + 1)
        );
        vm.expectRevert();
        handler.assertModel();
    }

    function test_MixedOracleRejectsCorruptedLpSupply() public {
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.totalSupply, ()),
            abi.encode(handler.expectedJuniorSupply() + 1)
        );
        vm.expectRevert();
        handler.assertModel();
    }

}

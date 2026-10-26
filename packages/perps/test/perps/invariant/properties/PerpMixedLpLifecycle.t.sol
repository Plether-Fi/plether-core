// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {MixedLpTestHarness} from "../support/MixedLpTestHarness.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

/// @notice Fixed public LP histories anchor the mixed campaign's independently modeled rounding and ownership.
contract PerpMixedLpLifecycleTest is BasePerpTest {

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
            settlementToken,
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
    }

    function test_TwoControllerDepositAndRedemptionDust() public {
        handler.requestJuniorDeposit(0, 1_000_000_001);
        handler.requestJuniorDeposit(1, 1_000_000_003);
        handler.settleJuniorEpoch(true);
        handler.claimJuniorDeposit(0);
        handler.claimJuniorDeposit(1);
        assertGt(handler.burnedDepositDustShares(), 0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.requestJuniorRedeem(1);
        assertEq(handler.lpRedemptionRequests(), 2);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorRedeem(0);
        handler.claimJuniorRedeem(1);
        assertGt(handler.returnedRedemptionDustAssets(), 0);
        assertEq(handler.lpRedemptionClaims(), 2);
        handler.assertModel();
    }

    function test_LpOracleRejectsAlteredClaimSharesWhileSupplyRemainsCorrect() public {
        handler.requestJuniorDeposit(0, 1_000_000_001);
        handler.settleJuniorEpoch(false);
        PerpMixedAccountingHandler.Lp memory lp = handler.lpState(0);
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.claimableDepositShares, (lp.epoch, handler.lpAt(0))),
            abi.encode(lp.claimShares + 1)
        );
        assertEq(juniorVault.totalSupply(), handler.expectedJuniorSupply());
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

    function test_LpOracleRejectsPricingAtNavBeforeInterveningTrade() public {
        uint256 deposit = 1500e6;
        handler.requestJuniorDeposit(0, deposit);
        PerpMixedAccountingHandler.Lp memory lp = handler.lpState(0);
        uint256 elapsed = lp.epoch * 1 hours - handler.expectedCouponTime();
        uint256 coupon = handler.expectedSenior() * 800 * elapsed / (10_000 * 365 days);
        // This deliberately stale quote accounts for the elapsed coupon but omits the subsequent trading history.
        // Every input comes from the explicit reference state before trading, never a production pricing preview.
        uint256 staleShares =
            deposit * (handler.expectedJuniorSupply() + 1000) / (handler.expectedJunior() - coupon + 1);
        handler.openOrIncrease(0, 300, 120_000_003);
        handler.refreshMark(80_000_001);
        handler.settleJuniorEpoch(false);
        lp = handler.lpState(0);
        assertGt(lp.claimShares, staleShares, "trader gains reduce Junior NAV and increase deposit shares");

        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.claimableDepositShares, (lp.epoch, handler.lpAt(0))),
            abi.encode(staleShares)
        );
        assertEq(juniorVault.totalSupply(), handler.expectedJuniorSupply());
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        handler.claimJuniorDeposit(0);
    }

    function test_RedemptionCancellationRetryAndNewDeposit() public {
        handler.requestJuniorDeposit(0, 1500e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.cancelJuniorRedeem(0);
        assertEq(handler.lpRedemptionCancellations(), 1);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorRedeem(0);
        handler.requestJuniorDeposit(0, 2000e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        assertEq(handler.lpRedemptionClaims(), 1);
        handler.assertModel();
    }

    function test_ZeroJuniorNavRefundsRedemptionAndDefersPendingDeposit() public {
        handler.requestJuniorDeposit(0, 1500e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.requestJuniorDeposit(1, 2000e6);
        uint256 day = (vm.getBlockTimestamp() + 13 * 365 days) / 1 days;
        uint256 monday = day + (8 - ((day + 4) % 7)) % 7;
        vm.warp(monday * 1 days + 12 hours);
        handler.settleJuniorEpoch(false);
        assertEq(handler.expectedJunior(), 0);
        assertEq(handler.lpDeferredDeposits(), 1);
        assertGt(handler.lpState(0).refundableRedeemShares, 0);
        assertEq(handler.lpState(1).pending, 2000e6);
        handler.claimJuniorRedeem(0);
        assertEq(handler.lpRedemptionRefunds(), 1);
        handler.cancelJuniorDeposit(1);
        handler.requestJuniorDeposit(1, 2000e6);
        assertEq(handler.lpDepositRejections(), 1);
        handler.assertModel();
    }

    function test_RatioConstrainedFundingRetainsRemainderThenCompletes() public {
        handler.requestJuniorDeposit(0, 3000e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        PerpMixedAccountingHandler.Lp memory lp = handler.lpState(0);
        uint256 elapsed = lp.redeemEpoch * 1 hours - handler.expectedCouponTime();
        uint256 seniorAtSettlement =
            handler.expectedSenior() + handler.expectedSenior() * 800 * elapsed / (10_000 * 365 days);
        uint256 requiredJunior = (seniorAtSettlement + 9998) / 9999;
        uint256 originalCash = handler.expectedPoolCash();
        handler.changeRawPoolCash(seniorAtSettlement + requiredJunior + 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpPartialRedemptions(), 1);
        assertEq(handler.lpState(0).claimRedeemAssets, 10_000, "independent ten-thousand-atom ratio budget");
        assertGt(handler.lpState(0).pendingRedeemShares, 0);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpUnfundedRedemptions(), 1);
        handler.changeRawPoolCash(originalCash - 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpState(0).pendingRedeemShares, 0);
        handler.claimJuniorRedeem(0);
        assertEq(handler.lpRedemptionClaims(), 1);
        handler.assertModel();
    }

    function test_TwoControllerPartialFundingThenWorthlessRefundPreservesDust() public {
        handler.requestJuniorDeposit(0, 2_999_999_999);
        handler.requestJuniorDeposit(1, 1_000_000_003);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.claimJuniorDeposit(1);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.requestJuniorRedeem(1);
        uint256 elapsed = handler.lpState(0).redeemEpoch * 1 hours - handler.expectedCouponTime();
        uint256 seniorAtSettlement =
            handler.expectedSenior() + handler.expectedSenior() * 800 * elapsed / (10_000 * 365 days);
        handler.changeRawPoolCash(seniorAtSettlement + (seniorAtSettlement + 9998) / 9999 + 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpPartialRedemptions(), 1);
        handler.changeRawPoolCash(seniorAtSettlement);
        handler.settleJuniorEpoch(false);
        assertEq(handler.expectedJunior(), 0);
        assertGt(handler.lpState(0).claimRedeemAssets, 0);
        assertGt(handler.lpState(0).refundableRedeemShares, 0);
        handler.claimJuniorRedeem(0);
        handler.claimJuniorRedeem(1);
        assertEq(handler.lpRedemptionClaims(), 2);
        assertEq(handler.lpRedemptionRefunds(), 2);
        assertEq(handler.expectedPendingRedeemEscrowShares(), 0);
        assertGt(handler.expectedJuniorSeedShares(), 500_000e9, "refund share dust belongs to seed owner");
        assertGt(handler.returnedRedemptionDustAssets(), 0, "funded asset dust returns to physical pool cash");
        handler.assertModel();
    }

    function test_PartialFundingClaimsThenTradingAndFurtherFunding() public {
        _preparePartialSingle();
        uint256 initialShares = handler.lpState(0).claimRedeemShares;
        handler.claimJuniorRedeemShares(0, 1); // A single native share legitimately rounds to zero cash.
        assertEq(handler.lpState(0).redeemedShares, 1);
        assertEq(handler.lpState(0).redeemedAssets, 0);
        handler.claimJuniorWithdraw(0, 2);
        assertEq(handler.lpAssetClaims(), 1);
        handler.claimJuniorRedeem(0);
        assertEq(handler.lpState(0).redeemedShares, initialShares);
        assertEq(handler.lpState(0).redeemedAssets, 10_000);
        assertTrue(handler.lpState(0).redeemQueued);
        assertFalse(handler.lpState(0).redeemFundingClaimed);
        handler.claimJuniorRedeemShares(0, 1); // Current entitlement exhausted; the epoch remains live.
        handler.claimJuniorWithdraw(0, 1);
        handler.changeRawPoolCash(1_003_000e6 - 10_000);
        handler.openOrIncrease(0, 23, 100_000_003);
        handler.advanceAndCheckpoint(37);
        handler.settleJuniorEpoch(false);
        assertGt(handler.lpState(0).claimRedeemAssets, 0);
        handler.claimJuniorWithdraw(0, 3);
        assertFalse(handler.lpState(0).redeemQueued);
        assertGe(handler.lpNonterminalClaims(), 3);
        assertEq(handler.lpClaimsAfterFurtherFunding(), 1);
        assertEq(handler.lpClaimRejections(), 2);
        handler.assertModel();
    }

    function test_PerCallClaimsUseRemainingEntitlementAndExactRollback() public {
        _preparePartialSingle();
        PerpMixedAccountingHandler.Lp memory beforeClaim = handler.lpState(0);
        uint256 shares = beforeClaim.claimRedeemShares / 3;
        uint256 assets = shares * beforeClaim.claimRedeemAssets / beforeClaim.claimRedeemShares;
        handler.claimSharesExact(0, shares);
        assertEq(handler.lpState(0).redeemedAssets, assets);
        beforeClaim = handler.lpState(0);
        uint256 cash = beforeClaim.claimRedeemAssets / 3;
        uint256 roundedShares =
            (cash * beforeClaim.claimRedeemShares + beforeClaim.claimRedeemAssets - 1) / beforeClaim.claimRedeemAssets;
        handler.withdrawAssetsExact(0, cash);
        assertEq(handler.lpState(0).redeemedShares, shares + roundedShares);
        handler.claimJuniorRedeemShares(0, 0);
        handler.claimJuniorRedeemShares(0, 4);
        handler.claimJuniorWithdraw(0, 0);
        handler.claimJuniorWithdraw(0, 4);
        handler.claimJuniorRedeemRefund(0);
        assertEq(handler.lpClaimRejections(), 5);
        handler.assertModel();
    }

    function test_TwoEpochsRetainIndependentFundingAndClaims() public {
        handler.requestJuniorDeposit(0, 2_999_999_999);
        handler.requestJuniorDeposit(1, 1_000_000_003);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.claimJuniorDeposit(1);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(1);
        assertLt(handler.lpState(0).redeemEpoch, handler.lpState(1).redeemEpoch);
        uint256 originalCash = handler.expectedPoolCash();
        _constrainNextSettlement(1, 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpState(0).claimRedeemAssets, 10_000);
        assertEq(handler.lpState(1).claimRedeemAssets, 0);
        handler.claimJuniorWithdraw(0, 2);
        handler.claimJuniorRedeemShares(1, 1);
        handler.changeRawPoolCash(originalCash - 10_000);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorWithdraw(1, 3); // Newer epoch can claim before the older controller.
        handler.claimJuniorRedeem(0);
        assertFalse(handler.lpState(0).redeemQueued);
        assertFalse(handler.lpState(1).redeemQueued);
        assertEq(handler.lpClaimsAfterFurtherFunding(), 1);
        assertEq(handler.lpClaimRejections(), 1);
        handler.assertModel();
    }

    function test_RefundAndCashClaimsInBothOrdersAfterInterimClaims() public {
        _preparePartialTwo();
        handler.claimJuniorWithdraw(0, 2);
        handler.claimJuniorRedeemShares(1, 2);
        uint256 seniorCapital = handler.expectedSenior();
        handler.changeRawPoolCash(seniorCapital);
        handler.settleJuniorEpoch(false);
        uint256 accountedBeforeClaims = handler.expectedAccounted();
        uint256 carryClockBeforeClaims = engine.sideCarryTimestamp(0);
        vm.warp(vm.getBlockTimestamp() + 17);
        handler.claimJuniorRedeemRefund(0);
        assertTrue(handler.lpState(0).redeemQueued, "refund does not discard outstanding funded cash");
        handler.claimJuniorRedeem(1); // Cash then refund for the second controller.
        uint256 dustBeforeFinalCash = handler.returnedRedemptionDustAssets();
        handler.claimJuniorWithdraw(0, 3);
        assertFalse(handler.lpState(0).redeemQueued);
        assertEq(handler.lpRefundsBeforeCash(), 1);
        assertEq(handler.lpRefundsAfterCash(), 1);
        assertGt(handler.returnedRedemptionDustAssets(), dustBeforeFinalCash);
        assertEq(
            handler.expectedAccounted(), accountedBeforeClaims, "passive returned dust does not create accounted assets"
        );
        assertEq(
            engine.sideCarryTimestamp(0), carryClockBeforeClaims, "passive returned dust does not checkpoint carry"
        );
        vm.mockCall(address(pool), abi.encodeCall(pool.accountedAssets, ()), abi.encode(accountedBeforeClaims + 1));
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        handler.claimJuniorRedeemRefund(0);
        handler.claimJuniorRedeemRefund(1);
        assertEq(handler.lpClaimRejections(), 2);
        handler.assertModel();
    }

    function test_ZeroShareRefundAcknowledgementClosesTinyControllerAndSweepsDust() public {
        uint256 seedActivation = handler.expectedCouponTime();
        handler.requestJuniorDeposit(0, 3000e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.transferJuniorShares(0, 1);
        handler.requestJuniorRedeem(0);
        handler.requestJuniorRedeem(1);
        _constrainNextSettlement(0, 10_000);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorRedeem(0);
        handler.changeRawPoolCash(handler.expectedSenior());
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpState(1).refundableRedeemShares, 0);
        assertTrue(handler.lpState(1).redeemQueued);
        handler.claimJuniorRedeemRefund(0);
        assertTrue(handler.lpState(1).redeemQueued, "zero refund still needs acknowledgement");
        handler.claimJuniorRedeemRefund(1);
        assertEq(handler.lpZeroShareRefunds(), 1);
        assertFalse(handler.lpState(1).redeemQueued);
        assertEq(
            juniorVault.lastDepositTime(address(this)), seedActivation, "refund share dust preserves seed cooldown"
        );
        assertGt(handler.expectedJuniorSeedShares(), 500_000e9);
        handler.claimJuniorRedeemRefund(1);
        assertEq(handler.lpClaimRejections(), 1);
        handler.assertModel();
    }

    function test_ClaimOracleRejectsForgottenConsumptionAndPrematureQueueRemoval() public {
        _preparePartialSingle();
        uint256 originallyClaimable = handler.lpState(0).claimRedeemShares;
        handler.claimJuniorRedeemShares(0, 2);
        uint256 epoch = handler.lpState(0).redeemEpoch;
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.claimableRedeemRequest, (epoch, handler.lpAt(0))),
            abi.encode(originallyClaimable)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        vm.mockCall(
            address(juniorVault), abi.encodeCall(juniorVault.controllerRedeemHead, (handler.lpAt(0))), abi.encode(0)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

    function test_ClaimOracleRejectsCumulativeClaimCorruptionAndCrossControllerCredit() public {
        _preparePartialTwo();
        handler.claimJuniorWithdraw(0, 2);
        PerpMixedAccountingHandler.Lp memory lp = handler.lpState(0);
        // Returned cumulative state must preserve each claim even though epoch funding is unchanged.
        TrancheVault.RedeemPosition memory corrupted;
        corrupted.shares = lp.redeemBasis;
        corrupted.claimedShares = lp.redeemedShares;
        corrupted.claimedAssets = lp.redeemedAssets - 1;
        corrupted.refundedShares = lp.refundedShares;
        corrupted.queued = lp.redeemQueued;
        corrupted.fundingClaimed = lp.redeemFundingClaimed;
        corrupted.refundClaimed = lp.redeemRefundClaimed;
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.redeemRequests, (handler.lpAt(0), lp.redeemEpoch)),
            abi.encode(corrupted)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        vm.mockCall(
            address(settlementToken),
            abi.encodeCall(settlementToken.balanceOf, (handler.lpAt(1))),
            abi.encode(handler.lpState(1).wallet + lp.redeemedAssets)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
    }

    function test_CumulativeFundingRoundsOnceAfterAnEarlierClaim() public {
        _preparePartialTwo();
        PerpMixedAccountingHandler.Lp memory beforeClaim = handler.lpState(0);
        PerpMixedAccountingHandler.LpRedeemEpoch memory first = handler.redeemEpochState(beforeClaim.redeemEpoch);
        handler.claimJuniorRedeem(0);
        _constrainNextSettlement(0, 10_001);
        handler.settleJuniorEpoch(false);
        PerpMixedAccountingHandler.Lp memory afterFunding = handler.lpState(0);
        PerpMixedAccountingHandler.LpRedeemEpoch memory second = handler.redeemEpochState(beforeClaim.redeemEpoch);
        uint256 independentlyRounded = beforeClaim.redeemBasis * second.fundedAssets / second.shares
            - beforeClaim.redeemBasis * first.fundedAssets / first.shares;
        uint256 incorrectlyRoundedEachRound =
            beforeClaim.redeemBasis * (second.fundedAssets - first.fundedAssets) / second.shares;
        assertEq(afterFunding.claimRedeemAssets, independentlyRounded);
        assertGt(independentlyRounded, incorrectlyRoundedEachRound, "fixed native-atom cumulative rounding witness");
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.claimableRedeemAssets, (beforeClaim.redeemEpoch, handler.lpAt(0))),
            abi.encode(incorrectlyRoundedEachRound)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        handler.claimJuniorWithdraw(0, 3);
        assertEq(handler.lpClaimsAfterFurtherFunding(), 1);
    }

    function test_ActiveBorrowSurvivesDelayedFinalDustBeforeNextCarryCheckpoint() public {
        _preparePartialTwo();
        handler.openOrIncrease(0, 17, 100_000_003);
        assertGt(handler.carry().accountState(handler.actorAt(0)).borrowBase, 0);
        handler.changeRawPoolCash(0);
        handler.settleJuniorEpoch(false);
        uint256 epochId = handler.lpState(0).redeemEpoch;
        uint256 dust = handler.redeemEpochState(epochId).assetDust;
        assertGt(dust, 0, "two-controller independently modeled funded-asset dust");
        assertEq(handler.carry().poolDepth(), 0);
        uint256 checkpoint = handler.carry().sideState(0).timestamp;
        uint256 index = handler.carry().sideState(0).index;
        uint256 accounted = handler.expectedAccounted();
        uint256 collected = handler.carryCollected();

        // No price refresh, Engine checkpoint, or trader collection intervenes in these delayed vault-only calls.
        vm.warp(vm.getBlockTimestamp() + 17);
        handler.claimJuniorRedeemRefund(0);
        handler.claimJuniorRedeem(1);
        assertEq(handler.expectedPoolCash(), 0, "one controller still owes its funding acknowledgement");
        assertEq(handler.carry().sideState(0).timestamp, checkpoint);
        handler.claimJuniorRedeem(0);
        assertEq(handler.expectedPoolCash(), dust);
        assertEq(handler.carry().poolDepth(), dust, "passive dust changes depth for the next assessment");
        assertEq(handler.expectedAccounted(), accounted);
        assertEq(engine.sideCarryTimestamp(0), checkpoint);
        assertEq(engine.sideCarryIndex(0), index);
        handler.assertModel();

        handler.advanceAndCheckpoint(37);
        assertGt(handler.carryCollected(), collected, "real active borrow is assessed after passive dust");
        assertGt(engine.sideCarryIndex(0), index);
        assertEq(engine.sideCarryTimestamp(0), vm.getBlockTimestamp());
        handler.assertModel();
    }

    function test_ClaimOracleRejectsFloorInsteadOfCeilingWithdrawShares() public {
        _preparePartialSingle();
        PerpMixedAccountingHandler.Lp memory beforeClaim = handler.lpState(0);
        // Make the chosen one-atom cash withdrawal indivisible using a valid zero-cash native-share claim if needed.
        if (beforeClaim.claimRedeemShares % beforeClaim.claimRedeemAssets == 0) {
            handler.claimSharesExact(0, 1);
            beforeClaim = handler.lpState(0);
        }
        assertGt(beforeClaim.claimRedeemShares % beforeClaim.claimRedeemAssets, 0);
        uint256 floorShares = beforeClaim.claimRedeemShares / beforeClaim.claimRedeemAssets;
        handler.withdrawAssetsExact(0, 1);
        PerpMixedAccountingHandler.Lp memory lp = handler.lpState(0);
        assertEq(lp.redeemedShares - beforeClaim.redeemedShares, floorShares + 1);
        TrancheVault.RedeemPosition memory corrupted;
        corrupted.shares = lp.redeemBasis;
        corrupted.claimedShares = beforeClaim.redeemedShares + floorShares;
        corrupted.claimedAssets = lp.redeemedAssets;
        corrupted.refundedShares = lp.refundedShares;
        corrupted.queued = lp.redeemQueued;
        corrupted.fundingClaimed = lp.redeemFundingClaimed;
        corrupted.refundClaimed = lp.redeemRefundClaimed;
        vm.mockCall(
            address(juniorVault),
            abi.encodeCall(juniorVault.redeemRequests, (handler.lpAt(0), lp.redeemEpoch)),
            abi.encode(corrupted)
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        handler.claimJuniorRedeem(0);
    }

    function test_ClaimOracleRejectsDustSweepBeforeTerminalFundingAcknowledgements() public {
        _preparePartialTwo();
        uint256 dust = handler.redeemEpochState(handler.lpState(0).redeemEpoch).assetDust;
        uint256 escrow = handler.lpState(0).claimRedeemAssets + handler.lpState(1).claimRedeemAssets + dust;
        uint256 rawPool = handler.expectedPoolCash();
        assertGt(dust, 0);
        assertFalse(handler.lpState(0).redeemFundingClaimed);
        assertFalse(handler.lpState(1).redeemFundingClaimed);
        // This coherent premature transfer preserves total cash, so ownership/timing assertions must detect it.
        vm.mockCall(
            address(settlementToken),
            abi.encodeCall(settlementToken.balanceOf, (address(juniorVault))),
            abi.encode(escrow - dust)
        );
        vm.mockCall(
            address(settlementToken),
            abi.encodeCall(settlementToken.balanceOf, (address(pool))),
            abi.encode(rawPool + dust)
        );
        vm.mockCall(
            address(juniorVault), abi.encodeCall(juniorVault.withdrawalEscrowAssets, ()), abi.encode(escrow - dust)
        );
        assertEq(
            settlementToken.balanceOf(address(juniorVault)) + settlementToken.balanceOf(address(pool)), escrow + rawPool
        );
        vm.expectRevert();
        handler.assertModel();
        vm.clearMockedCalls();
        handler.assertModel();
        handler.claimJuniorRedeem(0);
        assertEq(handler.returnedRedemptionDustAssets(), 0, "a nonterminal cash claim cannot sweep dust");
    }

    function _preparePartialSingle() internal {
        handler.requestJuniorDeposit(0, 3000e6);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        _constrainNextSettlement(0, 10_000);
        handler.settleJuniorEpoch(false);
        assertEq(handler.lpState(0).claimRedeemAssets, 10_000);
        assertGt(handler.lpState(0).pendingRedeemShares, 0);
    }

    function _preparePartialTwo() internal {
        handler.requestJuniorDeposit(0, 2_999_999_999);
        handler.requestJuniorDeposit(1, 1_000_000_003);
        handler.settleJuniorEpoch(false);
        handler.claimJuniorDeposit(0);
        handler.claimJuniorDeposit(1);
        handler.advanceAndCheckpoint(1 hours);
        handler.requestJuniorRedeem(0);
        handler.requestJuniorRedeem(1);
        _constrainNextSettlement(0, 10_000);
        handler.settleJuniorEpoch(false);
        assertGt(handler.lpState(0).claimRedeemAssets, 0);
        assertGt(handler.lpState(1).claimRedeemAssets, 0);
    }

    function _constrainNextSettlement(
        uint256 i,
        uint256 budget
    ) internal {
        uint256 elapsed = handler.lpState(i).redeemEpoch * 1 hours - handler.expectedCouponTime();
        uint256 seniorAtSettlement =
            handler.expectedSenior() + handler.expectedSenior() * 800 * elapsed / (10_000 * 365 days);
        handler.changeRawPoolCash(seniorAtSettlement + (seniorAtSettlement + 9998) / 9999 + budget);
    }

}

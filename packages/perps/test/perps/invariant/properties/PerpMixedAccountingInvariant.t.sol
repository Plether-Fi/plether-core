// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

contract PerpMixedAccountingInvariantTest is BasePerpTest {

    PerpMixedAccountingHandler internal handler;

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
        handler = new PerpMixedAccountingHandler(
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
        handler.openOrIncrease(0, 300, 120_000_003);
        handler.requestJuniorDeposit(0, 1500e6);
        handler.openOrIncrease(1, 100, 80_000_001);
        handler.openOrIncrease(2, 150, 80_000_001);
        handler.openOrIncrease(0, 25, 110_000_003);
        handler.close(2, 50, false);
        handler.settleJuniorEpoch(true);
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
        handler.openOrIncrease(0, 251, 120_000_003);
        handler.openOrIncrease(1, 117, 80_000_001);

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.openOrIncrease.selector;
        selectors[1] = handler.close.selector;
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
        selectors[16] = handler.createDeferredClaimHistory.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
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
    }

    function test_MandatoryPreludeExercisesMixedHistories() public view {
        invariant_PersistentPublicMixedAccounting();
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

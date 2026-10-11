// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {PerpMixedAccountingHandler} from "../handlers/PerpMixedAccountingHandler.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

/// @dev Fixed environmental inputs for constrained-liquidity histories; no observed production state feeds the model.
contract MixedLpTestHarness is PerpMixedAccountingHandler {

    constructor(
        MockUSDC usdc_,
        MockPyth pyth_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        TrancheVault junior_,
        TrancheVault senior_,
        OrderRouter router_,
        address owner_
    ) PerpMixedAccountingHandler(usdc_, pyth_, engine_, clearinghouse_, pool_, junior_, senior_, router_, owner_) {}

    function changeRawPoolCash(
        uint256 nextCash
    ) external {
        engine.checkpointCarryIndexes();
        carry.advance(vm.getBlockTimestamp());
        if (nextCash < expectedPoolCash) {
            uint256 removed = expectedPoolCash - nextCash;
            usdc.burn(address(pool), removed);
            externalShockOut += removed;
        } else {
            uint256 added = nextCash - expectedPoolCash;
            usdc.mint(address(pool), added);
            externalShockIn += added;
        }
        expectedPoolCash = nextCash;
        carry.changeDepth(_depth(), vm.getBlockTimestamp());
        assertModel();
    }

}

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

}

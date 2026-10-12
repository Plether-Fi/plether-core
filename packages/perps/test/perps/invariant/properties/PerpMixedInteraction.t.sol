// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {MixedLpTestHarness} from "../support/MixedLpTestHarness.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

/// @notice Persistent cross-domain histories; every operation is checked by the same independent economic ledger.
contract PerpMixedInteractionTest is BasePerpTest {

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

    function test_InterimLpClaimsAndHeldSettlementPreservePendingTraderOrders() public {
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
        assertEq(handler.lpState(0).claimRedeemAssets, 10_000, "explicit independent funding budget");
        handler.claimJuniorRedeemShares(0, 2);
        assertGt(handler.lpNonterminalClaims(), 0);
        handler.changeRawPoolCash(originalCash - 10_000);

        // Mature a second LP request inside both the fifteen-second first-publication window and the
        // sixty-second order deadline. The old redemption
        // remains partly funded and keeps its first payout while these trader commitments stay live.
        handler.requestJuniorDeposit(1, 2000e6);
        vm.warp(handler.lpState(1).epoch * 1 hours - 10);
        handler.commitOpen(0, 17, 80_000_002);
        handler.commitOpen(1, 17, 120_000_002);
        _assertPending(1, 1);
        handler.claimJuniorWithdraw(0, 2);
        _assertPending(1, 1);
        handler.executeHead(false);
        _assertPending(0, 1);
        handler.settleJuniorEpoch(true);
        _assertPending(0, 1);
        handler.executeHead(false);
        _assertPending(0, 0);
        handler.claimJuniorRedeem(0);
        handler.claimJuniorDeposit(1);

        assertEq(handler.traderState(0).lots, 17);
        assertEq(handler.traderState(1).lots, 17);
        assertGt(handler.lpClaimsAfterFurtherFunding(), 0);
        assertGt(handler.lpAssetClaims(), 0);
        assertGt(handler.heldSettlements(), 0);
        assertEq(handler.lpState(0).pendingRedeemShares, 0);
        handler.assertModel();
    }

    function test_HistoricalFirstTickPricesAnOrderAfterTheMarkChangesAgain() public {
        handler.commitOpen(0, 17, 80_000_002);
        // A different publication is authored one second later: the unique first tick after commitment.
        handler.refreshMark(120_000_002);
        vm.warp(vm.getBlockTimestamp() + 5);
        handler.refreshMark(90_000_002);
        handler.executeHead(false);
        assertEq(handler.traderState(0).lots, 17);
        assertEq(handler.traderState(0).basis, 17 * 120_000_002, "entry uses the actual first historical tick");
        assertEq(handler.currentPrice(), 90_000_002, "newer accounting mark survives the historical fill");
        assertEq(engine.lastMarkPrice(), 90_000_002);
        handler.assertModel();
    }

    function test_NoPublicationInSettlementWindowRetainsTheOrderUntilExpiry() public {
        handler.commitOpen(0, 17, 80_000_002);
        vm.warp(vm.getBlockTimestamp() + 20);
        handler.executeHead(false);
        _assertPending(1, 0);
        assertEq(handler.traderState(0).lots, 0);
        vm.warp(vm.getBlockTimestamp() + 41);
        handler.executeHead(false);
        _assertPending(0, 0);
        assertEq(handler.traderState(0).lots, 0);
        assertEq(handler.expiredOrders(), 1);
    }

    function _assertPending(
        uint256 first,
        uint256 second
    ) private view {
        assertEq(router.pendingOrderCounts(handler.actorAt(0)), first, "first trader queue survives LP action");
        assertEq(router.pendingOrderCounts(handler.actorAt(1)), second, "second trader queue survives LP action");
        handler.assertModel();
    }

}

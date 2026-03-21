// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract ArchitectureRegression_EscrowShielding is BasePerpTest {

    address internal alice = address(0xA11CE);

    function test_LiquidationSolvency_MustIgnoreLockedMarginInReachableEquity() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        router.executeLiquidation(accountId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "locked position margin must not be counted as free liquidation equity");
    }

}

contract ArchitectureRegression_SolvencyViews is BasePerpTest {

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xBEEF);

    function test_WithdrawFees_MustHonorDeferredKeeperLiabilities() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, 950_001e6);

        vm.expectRevert(CfdEngine.CfdEngine__PostOpSolvencyBreach.selector);
        engine.withdrawFees(address(this));
    }

    function test_Reconcile_MustSubtractDeferredLiquidationBounties() public {
        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, 100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 900_000e6, "deferred liquidation bounties must reduce LP distributable equity");
    }

    function test_FreshClosePayout_MustNotLeapfrogExistingDeferredClaims() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 bobId = bytes32(uint256(uint160(bob)));

        _fundTrader(alice, 11_000e6);
        _fundTrader(bob, 11_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);
        _open(bobId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        uint256 aliceDeferred = engine.deferredPayoutUsdc(aliceId);
        assertGt(aliceDeferred, 0, "setup must create a deferred senior claim");

        usdc.mint(address(pool), aliceDeferred);

        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobId);
        _close(bobId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(engine.deferredPayoutUsdc(bobId), 0, "new payout must defer while older deferred claims reserve cash");
        assertEq(
            clearinghouse.balanceUsdc(bobId),
            bobSettlementBefore,
            "fresh profitable close must not bypass older deferred claims via immediate payment"
        );
    }

    function test_DeferredClaimability_MustOnlyExposeQueueHead() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 11_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        uint256 deferredPayout = engine.deferredPayoutUsdc(aliceId);
        assertGt(deferredPayout, 0, "setup must create a deferred payout");

        vm.prank(address(router));
        engine.recordDeferredClearerBounty(keeper, deferredPayout);

        usdc.mint(address(pool), deferredPayout);

        CfdEngine.DeferredPayoutStatus memory status = engine.getDeferredPayoutStatus(aliceId, keeper);
        assertTrue(status.traderPayoutClaimableNow, "oldest queue head should become claimable under partial liquidity");
        assertFalse(status.liquidationBountyClaimableNow, "later claims must remain blocked behind the queue head");

        vm.prank(keeper);
        vm.expectRevert(CfdEngine.CfdEngine__DeferredClaimNotAtHead.selector);
        engine.claimDeferredClearerBounty();
    }

    function test_DeferredClaimQueue_MustServiceOldestClaimFirstUnderPartialLiquidity() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 bobId = bytes32(uint256(uint160(bob)));

        _fundTrader(alice, 11_000e6);
        _fundTrader(bob, 11_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);
        _open(bobId, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        _close(bobId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 aliceDeferred = engine.deferredPayoutUsdc(aliceId);
        uint256 bobDeferred = engine.deferredPayoutUsdc(bobId);
        assertGt(aliceDeferred, 0, "setup must create oldest deferred claim");
        assertGt(bobDeferred, 0, "setup must create second deferred claim");

        usdc.mint(address(pool), aliceDeferred / 2);
        uint256 claimableNow = pool.totalAssets() < aliceDeferred ? pool.totalAssets() : aliceDeferred;

        vm.prank(alice);
        engine.claimDeferredPayout(aliceId);

        assertEq(engine.deferredPayoutUsdc(aliceId), aliceDeferred - claimableNow, "oldest claim should absorb partial liquidity first");
        assertEq(engine.deferredPayoutUsdc(bobId), bobDeferred, "later claim must remain untouched until older claim is serviced");
    }

}

contract ArchitectureRegression_QueueEconomics is BasePerpTest {

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function test_InvalidCloseMustBeRejectedAtCommit() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BEAR, 100_001e18, 0, 0, true);
    }

    function test_FullyMarginedCloseCommit_MustStayLiveByUsingPositionMarginBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 bobId = bytes32(uint256(uint160(bob)));
        _fundTrader(alice, 5_000e6);
        _fundTrader(bob, 50_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 5_000e6, 1e8);
        _open(bobId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        assertEq(clearinghouse.getFreeSettlementBalanceUsdc(aliceId), 0, "setup must leave no idle settlement");
        (, uint256 marginBefore,,,,,,) = engine.positions(aliceId);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,,) = engine.positions(aliceId);
        assertEq(marginAfter, marginBefore - 1e6, "close commit should source bounty from active margin");
        assertEq(router.executionBountyReserves(1), 1e6, "close commit must still escrow the keeper bounty");
    }

}

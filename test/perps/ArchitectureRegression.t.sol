// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {DeferredEngineViewTypes} from "../../src/perps/interfaces/DeferredEngineViewTypes.sol";
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

        (uint256 size,,,,,,) = engine.positions(accountId);
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
        engine.recordDeferredKeeperCredit(keeper, 950_001e6);

        vm.expectRevert(CfdEngine.CfdEngine__PostOpSolvencyBreach.selector);
        engine.withdrawFees(address(this));
    }

    function test_Reconcile_MustSubtractDeferredLiquidationBounties() public {
        uint256 juniorPrincipalBefore = pool.juniorPrincipal();

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, 100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            juniorPrincipalBefore - pool.juniorPrincipal(),
            100_000e6,
            "Deferred liquidation bounties must reduce junior distributable equity by the reserved keeper amount"
        );
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
        uint256 aliceDeferred = engine.deferredTraderCreditUsdc(aliceId);
        assertGt(aliceDeferred, 0, "setup must create a deferred senior claim");

        usdc.mint(address(pool), aliceDeferred);

        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobId);
        _close(bobId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(
            engine.deferredTraderCreditUsdc(bobId), 0, "new payout must defer while older deferred claims reserve cash"
        );
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
        uint256 deferredTraderCredit = engine.deferredTraderCreditUsdc(aliceId);
        assertGt(deferredTraderCredit, 0, "setup must create a deferred payout");

        vm.prank(address(router));
        engine.recordDeferredKeeperCredit(keeper, deferredTraderCredit);

        usdc.mint(address(pool), deferredTraderCredit);

        DeferredEngineViewTypes.DeferredCreditStatus memory status = _deferredCreditStatus(aliceId, keeper);
        assertTrue(status.traderPayoutClaimableNow, "Deferred trader credit should be claimable when liquidity exists");
        assertTrue(
            status.keeperCreditClaimableNow, "Deferred keeper credit should also be claimable without FIFO gating"
        );

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper))));
        vm.prank(keeper);
        engine.claimDeferredKeeperCredit();
        assertGt(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(keeper)))) - keeperSettlementBefore,
            0,
            "Keeper should be able to claim directly without head-of-queue ordering"
        );
    }

    function test_DeferredClaims_NoLongerEnforceOldestFirstUnderPartialLiquidity() public {
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

        uint256 aliceDeferred = engine.deferredTraderCreditUsdc(aliceId);
        uint256 bobDeferred = engine.deferredTraderCreditUsdc(bobId);
        assertGt(aliceDeferred, 0, "setup must create oldest deferred claim");
        assertGt(bobDeferred, 0, "setup must create second deferred claim");

        usdc.mint(address(pool), aliceDeferred / 2);

        uint256 aliceSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        vm.prank(alice);
        engine.claimDeferredTraderCredit(aliceId);

        uint256 aliceClaimed = clearinghouse.balanceUsdc(aliceId) - aliceSettlementBefore;
        assertGt(aliceClaimed, 0, "beneficiary claim should absorb available partial liquidity");
        assertEq(
            engine.deferredTraderCreditUsdc(aliceId),
            aliceDeferred - aliceClaimed,
            "Claimed beneficiary balance should shrink by the paid amount"
        );
        assertEq(engine.deferredTraderCreditUsdc(bobId), bobDeferred, "Unclaimed later balance should remain unchanged");

        usdc.mint(address(pool), bobDeferred / 2);
        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobId);
        vm.prank(bob);
        engine.claimDeferredTraderCredit(bobId);
        assertGt(
            clearinghouse.balanceUsdc(bobId) - bobSettlementBefore,
            0,
            "Later deferred claimant should also be able to claim available liquidity without FIFO ordering"
        );
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
        _fundTrader(alice, 5000e6);
        _fundTrader(bob, 50_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(bobId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(aliceId), 0, "setup must leave no idle settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(aliceId);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(aliceId);
        assertEq(
            marginAfter, marginBefore - 200_000, "close commit should source the configured bounty from active margin"
        );
        assertEq(_executionBountyReserve(1), 200_000, "close commit must still escrow the configured keeper bounty");
    }

}

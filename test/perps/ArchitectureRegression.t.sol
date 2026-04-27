// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {ClaimEngineViewTypes} from "../../src/perps/interfaces/ClaimEngineViewTypes.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract ArchitectureRegression_EscrowShielding is BasePerpTest {

    address internal alice = address(0xA11CE);

    function test_LiquidationSolvency_MustIgnoreLockedMarginInReachableEquity() public {
        address account = alice;
        _fundTrader(alice, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        router.executeLiquidation(account, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "locked position margin must not be counted as free liquidation equity");
    }

}

contract ArchitectureRegression_SolvencyViews is BasePerpTest {

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xBEEF);

    function test_WithdrawFees_MustHonorKeeperClaimLiabilities() public {
        address account = alice;
        _fundTrader(alice, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        _recordKeeperClaimForTest(keeper, 950_001e6);

        vm.expectRevert(CfdEngine.CfdEngine__PostOpSolvencyBreach.selector);
        engine.withdrawFees(address(this));
    }

    function test_Reconcile_MustSubtractKeeperClaimLiabilities() public {
        uint256 juniorPrincipalBefore = pool.juniorPrincipal();
        _recordKeeperClaimForTest(keeper, 100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            juniorPrincipalBefore - pool.juniorPrincipal(),
            100_000e6,
            "claim liquidation bounties must reduce junior distributable equity by the reserved keeper amount"
        );
    }

    function test_FreshClosePayout_MustNotLeapfrogExistingClaims() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 11_000e6);
        _fundTrader(bob, 11_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);
        _open(bobAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        uint256 aliceClaim = clearinghouse.traderClaimBalanceUsdc(aliceAccount);
        assertGt(aliceClaim, 0, "setup must create a senior claim");

        usdc.mint(address(pool), aliceClaim);

        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobAccount);
        _close(bobAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(
            clearinghouse.traderClaimBalanceUsdc(bobAccount),
            0,
            "new payout must create a claim while older claim balances reserve cash"
        );
        assertEq(
            clearinghouse.balanceUsdc(bobAccount),
            bobSettlementBefore,
            "fresh profitable close must not bypass older claim balances via immediate payment"
        );
    }

    function test_ClaimStatus_ViewCanOverstateKeeperClaimabilityDuringShortfall() public {
        address aliceAccount = alice;
        _fundTrader(alice, 11_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        uint256 traderClaimBalance = clearinghouse.traderClaimBalanceUsdc(aliceAccount);
        assertGt(traderClaimBalance, 0, "setup must create a trader claim balance");
        _recordKeeperClaimForTest(keeper, traderClaimBalance);

        usdc.mint(address(pool), traderClaimBalance);

        ClaimEngineViewTypes.ClaimStatus memory status = _claimStatus(aliceAccount, keeper);
        assertTrue(
            status.traderClaimServiceableNow,
            "Trader claim should remain claimable when cash fully covers the trader credit"
        );
        assertTrue(
            status.keeperClaimServiceableNow, "Keeper view currently reports claimability whenever any cash remains"
        );

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(keeper);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Keeper, keeper);
        assertEq(clearinghouse.balanceUsdc(keeper), keeperSettlementBefore);
    }

    function test_Claims_FreezeForAllClaimantsDuringAggregateShortfall() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 11_000e6);
        _fundTrader(bob, 11_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);
        _open(bobAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        _close(bobAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        uint256 aliceClaim = clearinghouse.traderClaimBalanceUsdc(aliceAccount);
        uint256 bobClaim = clearinghouse.traderClaimBalanceUsdc(bobAccount);
        assertGt(aliceClaim, 0, "setup must create oldest claim balance");
        assertGt(bobClaim, 0, "setup must create second claim balance");

        usdc.mint(address(pool), aliceClaim / 2);

        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(alice);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Trader, aliceAccount);

        assertEq(
            clearinghouse.traderClaimBalanceUsdc(aliceAccount), aliceClaim, "Oldest claim balance should remain frozen"
        );
        assertEq(
            clearinghouse.traderClaimBalanceUsdc(bobAccount),
            bobClaim,
            "Unclaimed later balance should remain unchanged"
        );

        usdc.mint(address(pool), bobClaim / 2);
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientVaultLiquidity.selector);
        vm.prank(bob);
        engine.claimBalance(IMarginClearinghouse.ClaimKind.Trader, bobAccount);

        assertEq(
            clearinghouse.traderClaimBalanceUsdc(bobAccount),
            bobClaim,
            "Later claim balanceant should remain frozen too"
        );
    }

}

contract ArchitectureRegression_QueueEconomics is BasePerpTest {

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function test_InvalidCloseMustBeRejectedAtCommit() public {
        address account = alice;
        _fundTrader(alice, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BEAR, 100_001e18, 0, 0, true);
    }

    function test_FullyMarginedCloseCommit_MustStayLiveByUsingPositionMarginBounty() public {
        address aliceAccount = alice;
        address bobAccount = bob;
        _fundTrader(alice, 5000e6);
        _fundTrader(bob, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(bobAccount, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(aliceAccount), 0, "setup must leave no idle settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(aliceAccount);
        assertEq(
            marginAfter, marginBefore - 200_000, "close commit should source the configured bounty from active margin"
        );
        assertEq(_executionBountyReserve(1), 200_000, "close commit must still escrow the configured keeper bounty");
    }

}

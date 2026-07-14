// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract ArchitectureRegression_ReservationShielding is BasePerpTest {

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

    function test_ProtocolFees_AreCustodiedInTreasuryMargin() public {
        address account = alice;
        _fundTrader(alice, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertGt(fees, 0, "Setup should accrue protocol fees");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            fees,
            "Protocol fees should live in the treasury clearinghouse account"
        );
    }

    function test_FreshClosePayout_MustNotLeapfrogExistingTraderClaims() public {
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
        uint256 aliceClaim = engine.traderClaimBalanceUsdc(aliceAccount);
        assertGt(aliceClaim, 0, "setup must create a trader claim");

        usdc.mint(address(pool), aliceClaim);

        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobAccount);
        _close(bobAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

        assertGt(
            engine.traderClaimBalanceUsdc(bobAccount),
            0,
            "new payout must become a claim while older trader claims reserve cash"
        );
        assertEq(
            clearinghouse.balanceUsdc(bobAccount),
            bobSettlementBefore,
            "fresh profitable close must not bypass older trader claims via immediate payment"
        );
    }

    function test_TraderClaimStatus_ViewReportsTraderPath() public {
        address aliceAccount = alice;
        _fundTrader(alice, 11_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 80_000_000);
        uint256 traderClaim = engine.traderClaimBalanceUsdc(aliceAccount);
        assertGt(traderClaim, 0, "setup must create a trader claim");

        usdc.mint(address(pool), traderClaim);

        assertTrue(
            _traderClaimStatus(aliceAccount, address(0)).traderClaimServiceableNow,
            "Trader claim should remain serviceable when cash fully covers the claim balance"
        );
    }

    function test_TraderClaims_FreezeForAllClaimantsDuringAggregateShortfall() public {
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

        uint256 aliceClaim = engine.traderClaimBalanceUsdc(aliceAccount);
        uint256 bobClaim = engine.traderClaimBalanceUsdc(bobAccount);
        assertGt(aliceClaim, 0, "setup must create oldest trader claim");
        assertGt(bobClaim, 0, "setup must create second trader claim");

        usdc.mint(address(pool), aliceClaim / 2);

        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(alice);
        engine.settleTraderClaim(aliceAccount);

        assertEq(engine.traderClaimBalanceUsdc(aliceAccount), aliceClaim, "Oldest trader claim should remain frozen");
        assertEq(engine.traderClaimBalanceUsdc(bobAccount), bobClaim, "Unclaimed later balance should remain unchanged");

        usdc.mint(address(pool), bobClaim / 2);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InsufficientPoolLiquidity.selector);
        vm.prank(bob);
        engine.settleTraderClaim(bobAccount);

        assertEq(engine.traderClaimBalanceUsdc(bobAccount), bobClaim, "Later trader claimant should remain frozen too");
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
        assertEq(
            _executionBountyReserve(1), 200_000, "close commit must still reservation the configured keeper bounty"
        );
    }

}

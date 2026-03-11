// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditValidFindingsFailing is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    function test_C1_CommitMustLockMargin() public {
        _fundTrader(trader, 10_000 * 1e6);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 5_000 * 1e6, 1e8, false);

        vm.prank(trader);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(accountId, address(usdc), 10_000 * 1e6);
    }

    function test_C2_MtmMustAccountForUncollectibleLosses() public {
        _fundTrader(traderA, 200_000 * 1e6);
        _fundTrader(traderB, 1_000 * 1e6);

        bytes32 aId = bytes32(uint256(uint160(traderA)));
        bytes32 bId = bytes32(uint256(uint160(traderB)));

        _open(aId, CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1.5e8);
        _open(bId, CfdTypes.Side.BULL, 100_000 * 1e18, 1_000 * 1e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        int256 mtm = engine.getVaultMtmAdjustment();
        assertGt(mtm, 0, "MtM should reserve liability from undercollateralized losers");
    }

    function test_H1_KeeperFeeMustBePaidOnFailedSingleExecute() public {
        vm.deal(trader, 2 ether);
        vm.deal(keeper, 1 ether);

        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        router.commitOrder{value: 1 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 1e8, false);

        uint256 keeperBefore = keeper.balance;
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(1, empty);

        assertEq(keeper.balance - keeperBefore, 1 ether, "Keeper should receive fee even when order fails");
    }

    function test_H2_LiquidationBountyShouldNotIncreaseAfterCrossingZeroEquity() public {
        address traderPositive = address(0xA201);
        address traderNegative = address(0xA202);
        bytes32 positiveId = bytes32(uint256(uint160(traderPositive)));
        bytes32 negativeId = bytes32(uint256(uint160(traderNegative)));

        _fundTrader(traderPositive, 10_000 * 1e6);
        _fundTrader(traderNegative, 10_000 * 1e6);

        _open(positiveId, CfdTypes.Side.BULL, 100_000 * 1e18, 1_600 * 1e6, 1e8);
        _open(negativeId, CfdTypes.Side.BULL, 100_000 * 1e18, 1_600 * 1e6, 1e8);

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtPositiveEquity =
            engine.liquidatePosition(positiveId, 101_530_000, depth, uint64(block.timestamp));

        depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtNegativeEquity =
            engine.liquidatePosition(negativeId, 101_541_000, depth, uint64(block.timestamp));

        assertGe(
            bountyAtPositiveEquity,
            bountyAtNegativeEquity,
            "Bounty should not jump up after position slips into bad debt"
        );
    }

    function test_H4_SeniorShouldRemainDepositableAfterFullWipeout() public {
        address seniorLp = address(0x333);
        address juniorLp = address(0x444);
        address newSeniorLp = address(0x555);

        _fundSenior(seniorLp, 100_000 * 1e6);
        _fundJunior(juniorLp, 100_000 * 1e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        _fundSenior(newSeniorLp, 10_000 * 1e6);
        assertEq(pool.seniorPrincipal(), 10_000 * 1e6, "Senior tranche should accept new deposits after wipeout");
    }

    function test_M1_WithdrawMustRevertWhenMarkIsStale() public {
        _fundTrader(trader, 100_000 * 1e6);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 1_000 * 1e6, 1e8);

        vm.warp(block.timestamp + 1 days);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(accountId, address(usdc), 1e6);
    }

    function test_M2_StaleReconcileMustNotAdvanceClock() public {
        _fundSenior(address(0x666), 200_000 * 1e6);
        _fundJunior(address(0x777), 200_000 * 1e6);
        _fundTrader(trader, 50_000 * 1e6);

        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _open(accountId, CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        uint256 beforeTime = pool.lastReconcileTime();
        vm.warp(block.timestamp + 121);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.lastReconcileTime(), beforeTime, "Stale reconcile should not erase elapsed time");
    }

}

contract AuditValidFindingsFailingVpi is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function test_M3_MarketMakerShouldKeepNetVpiRebate() public {
        address skewTrader = address(0x901);
        address marketMaker = address(0x902);
        address flipper = address(0x903);

        _fundJunior(address(this), 2_000_000 * 1e6);

        _fundTrader(skewTrader, 500_000 * 1e6);
        _fundTrader(marketMaker, 500_000 * 1e6);
        _fundTrader(flipper, 500_000 * 1e6);

        bytes32 skewId = bytes32(uint256(uint160(skewTrader)));
        bytes32 mmId = bytes32(uint256(uint160(marketMaker)));
        bytes32 flipId = bytes32(uint256(uint160(flipper)));

        _open(skewId, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(flipId, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8);

        _close(mmId, CfdTypes.Side.BULL, 500_000 * 1e18, 1e8);

        uint256 mmAfter = clearinghouse.balances(mmId, address(usdc));
        uint256 depositAmount = 500_000 * 1e6;
        uint256 execFeesRoundTrip = ((500_000 * 1e6 * 6) / 10_000) * 2;

        assertGt(mmAfter, depositAmount - execFeesRoundTrip, "MM should retain net VPI rebate after round trip");
    }

}

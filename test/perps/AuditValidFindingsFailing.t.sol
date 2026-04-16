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
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 1e8, false);

        vm.prank(trader);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(accountId, 9999 * 1e6);
    }

    function test_C2_MtmMustAccountForUncollectibleLosses() public {
        _fundTrader(traderA, 200_000 * 1e6);
        _fundTrader(traderB, 1000 * 1e6);

        bytes32 aId = bytes32(uint256(uint160(traderA)));
        bytes32 bId = bytes32(uint256(uint160(traderB)));

        // A enters BULL at 1.5e8 → profits when price drops to 1e8 (+$50K)
        // B enters BULL at 0.5e8 → loses when price rises to 1e8 (-$50K, but only $1K margin)
        _open(aId, CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1.5e8);
        _open(bId, CfdTypes.Side.BULL, 100_000 * 1e18, 1000 * 1e6, 0.5e8);

        // Move mark to 1e8 — both positions still open (no liquidation).
        // A is winning $50K, B is losing $50K but has only $1K margin.
        // The vault's true liability is ~$49K (A's profit minus B's collectible $1K),
        // but O(1) netting reports bullTotal = 0 since +$50K and -$50K cancel out.
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 mtm = _vaultMtmAdjustment();
        assertEq(mtm, 0, "O(1) netting currently hides uncollectible losses before liquidation");
    }

    function test_H1_FailedSingleExecuteDoesNotPayKeeperOrEthRefund() public {
        vm.deal(trader, 2 ether);
        vm.deal(keeper, 1 ether);

        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 1, false);

        uint256 keeperBefore = keeper.balance;
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(1, empty);

        assertEq(keeper.balance - keeperBefore, 0, "Keeper should not receive fee when order fails");
        assertEq(trader.balance, 2 ether, "Failed open-order execution should not route any ETH refund to the user");
    }

    function test_H2_LiquidationBountyShouldNotIncreaseAfterCrossingZeroEquity() public {
        address traderPositive = address(0xA201);
        address traderNegative = address(0xA202);
        bytes32 positiveId = bytes32(uint256(uint160(traderPositive)));
        bytes32 negativeId = bytes32(uint256(uint160(traderNegative)));

        _fundTrader(traderPositive, 10_000 * 1e6);
        _fundTrader(traderNegative, 10_000 * 1e6);

        // BULL at 1e8, $1,600 margin. Equity hits 0 at price 101,600,000.
        _open(positiveId, CfdTypes.Side.BULL, 100_000 * 1e18, 1600 * 1e6, 1e8);
        _open(negativeId, CfdTypes.Side.BULL, 100_000 * 1e18, 1600 * 1e6, 1e8);

        vm.prank(traderPositive);
        clearinghouse.withdraw(positiveId, 8400 * 1e6);
        vm.prank(traderNegative);
        clearinghouse.withdraw(negativeId, 8400 * 1e6);

        // Liquidate at equity ≈ +$5 (just above zero)
        // Bounty capped at min(~$152, $5) = $5
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtPositiveEquity =
            engine.liquidatePosition(positiveId, 101_595_000, depth, uint64(block.timestamp));

        // Liquidate at equity ≈ -$5 (just below zero)
        // Bounty capped at min(~$152, $1600 margin) = $152
        depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtNegativeEquity =
            engine.liquidatePosition(negativeId, 101_605_000, depth, uint64(block.timestamp));

        uint256 jump = bountyAtNegativeEquity > bountyAtPositiveEquity
            ? bountyAtNegativeEquity - bountyAtPositiveEquity
            : bountyAtPositiveEquity - bountyAtNegativeEquity;
        assertLt(jump, 1e6, "Bounty should not exhibit a large discontinuity around zero equity");
    }

    function test_H4_SeniorShouldRemainDepositableAfterFullWipeout() public {
        address seniorLp = address(0x333);
        address juniorLp = address(0x444);

        _fundSenior(seniorLp, 100_000 * 1e6);
        _fundJunior(juniorLp, 100_000 * 1e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 depositAmount = 10_000 * 1e6;
        usdc.mint(address(seniorVault), depositAmount);
        vm.startPrank(address(seniorVault));
        usdc.approve(address(pool), depositAmount);
        pool.depositSenior(depositAmount);
        vm.stopPrank();

        assertEq(pool.seniorPrincipal(), depositAmount, "Senior tranche should accept recapitalization from zero");
        assertEq(pool.seniorHighWaterMark(), depositAmount, "Recapitalization should seed a fresh HWM");
    }

    function test_M1_WithdrawMustRevertWhenMarkIsStale() public {
        _fundTrader(trader, 100_000 * 1e6);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _open(accountId, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.warp(block.timestamp + 1 days);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(accountId, 1e6);
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

        assertEq(pool.lastReconcileTime(), beforeTime, "Stale reconcile should preserve the accrual clock");
    }

}

contract AuditValidFindingsFailingVpi is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.001e18,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
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

        uint256 mmAfter = clearinghouse.balanceUsdc(mmId);
        uint256 depositAmount = 500_000 * 1e6;
        uint256 execFeesRoundTrip = ((500_000 * 1e6 * 4) / 10_000) * 2;

        assertEq(mmAfter, depositAmount - execFeesRoundTrip, "VPI clamp should prevent net rebate extraction");
    }

}

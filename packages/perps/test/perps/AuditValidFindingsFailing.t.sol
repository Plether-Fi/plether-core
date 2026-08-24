// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract AuditValidFindingsFailing is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    function test_C1_CommitMustLockMargin() public {
        _fundTrader(trader, 10_000 * 1e6);
        address account = trader;

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 1e8, false);

        vm.prank(trader);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(account, 9999 * 1e6);
    }

    function test_C2_ExactMtmCapsLossesAtAccountPriceCollateral() public {
        _fundTrader(traderA, 200_000 * 1e6);
        _fundTrader(traderB, 1000 * 1e6);

        address aAccount = traderA;
        address bAccount = traderB;

        // A enters BULL at 1.5e8 → profits when price drops to 1e8 (+$50K)
        // B enters BULL at 0.5e8 → loses when price rises to 1e8 (-$50K, but only $1K margin)
        _open(aAccount, CfdTypes.Side.BULL, 100_000 * 1e18, 100_000 * 1e6, 1.5e8);
        _open(bAccount, CfdTypes.Side.BULL, 100_000 * 1e18, 1000 * 1e6, 0.5e8);

        // Move mark to 1e8 — both positions still open (no liquidation).
        // A is winning $50K, B is losing $50K but has only $1K margin.
        // The pool has a live winner on the same side as an undercollateralized loser.
        // Exact terminal NAV nets only the loser's account-local collectible price collateral
        // against the winner liability. The uncollectible tail is a diagnostic writeoff.
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 loserCollectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(bAccount).terminalPriceCollectibleCapUsdc;
        assertEq(loserCollectibleCapUsdc, 930e6, "Fixture should leave 930 USDC of exact price collateral");

        uint256 mtm = _poolMtmAdjustment();
        assertEq(
            mtm,
            50_000e6 - loserCollectibleCapUsdc,
            "Exact MtM should net only the loser's collectible cap against the winner liability"
        );
    }

    function test_H1_FailedSingleExecutePaysReservedUsdcBountyWithoutNativeEthTransfer() public {
        vm.deal(trader, 2 ether);
        vm.deal(keeper, 1 ether);

        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 200e6, 1.5e8, false);

        uint256 executionBountyUsdc = _executionBountyReserve(1);
        uint256 keeperEthBefore = keeper.balance;
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(trader);
        bytes[] memory empty = _mockPythUpdateData();
        vm.prank(keeper);
        router.executeOrder(1, empty);

        assertEq(keeper.balance, keeperEthBefore, "Failed execution must not transfer native ETH to the keeper");
        assertEq(trader.balance, 2 ether, "Failed execution must not route a native ETH refund to the trader");
        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            executionBountyUsdc,
            "Terminal slippage failure must pay the separately reserved USDC bounty"
        );
        assertEq(
            traderSettlementBefore - clearinghouse.balanceUsdc(trader),
            executionBountyUsdc,
            "Failed order must forfeit only its reserved execution bounty"
        );
        assertEq(router.pendingOrderCounts(trader), 0, "Terminal failure must clear the queued order");
        assertEq(_executionBountyReserve(1), 0, "Terminal failure must clear the bounty attribution");
    }

    function test_H2_LiquidationBountyShouldNotIncreaseAfterCrossingZeroEquity() public {
        address traderPositive = address(0xA201);
        address traderNegative = address(0xA202);
        address positiveAccount = traderPositive;
        address negativeAccount = traderNegative;

        _fundTrader(traderPositive, 10_000 * 1e6);
        _fundTrader(traderNegative, 10_000 * 1e6);

        // Each open funds a $100 dedicated liquidation reserve in addition to execution
        // fees and the exact PnL pledge used for price health.
        _open(positiveAccount, CfdTypes.Side.BULL, 100_000 * 1e18, 1700 * 1e6, 1e8);
        _open(negativeAccount, CfdTypes.Side.BULL, 100_000 * 1e18, 1700 * 1e6, 1e8);

        uint256 positiveFreeSettlementUsdc = _freeSettlementUsdc(positiveAccount);
        uint256 negativeFreeSettlementUsdc = _freeSettlementUsdc(negativeAccount);
        vm.prank(traderPositive);
        clearinghouse.withdraw(positiveAccount, positiveFreeSettlementUsdc);
        vm.prank(traderNegative);
        clearinghouse.withdraw(negativeAccount, negativeFreeSettlementUsdc);

        uint256 pledgeUsdc = clearinghouse.pnlPledgeUsdc(positiveAccount);
        assertEq(pledgeUsdc, 1560e6, "Fixture must retain the exact post-fee, post-reserve PnL pledge");
        assertEq(
            clearinghouse.liquidationReserveUsdc(positiveAccount),
            100e6,
            "Fixture must independently fund the liquidation charge"
        );

        // With 1,000 whole lots, these prices place exact P+C equity $5 above and
        // below zero. Both bounties are funded by the same protected reserve.
        uint256 positiveEquityPrice = 101_555_000;
        uint256 negativeEquityPrice = 101_565_000;
        ICfdEngineTypes.LiquidationPreview memory positivePreview =
            engineLens.previewLiquidation(positiveAccount, positiveEquityPrice);
        ICfdEngineTypes.LiquidationPreview memory negativePreview =
            engineLens.previewLiquidation(negativeAccount, negativeEquityPrice);
        assertEq(positivePreview.equityUsdc, int256(5e6), "Positive fixture must sit five USDC above zero");
        assertEq(negativePreview.equityUsdc, -int256(5e6), "Negative fixture must sit five USDC below zero");
        assertEq(
            positivePreview.keeperBountyUsdc,
            negativePreview.keeperBountyUsdc,
            "Dedicated reserve must remove any bounty discontinuity around zero price equity"
        );

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtPositiveEquity = engine.liquidatePosition(
            positiveAccount, positiveEquityPrice, depth, uint64(block.timestamp), address(this)
        );

        depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtNegativeEquity = engine.liquidatePosition(
            negativeAccount, negativeEquityPrice, depth, uint64(block.timestamp), address(this)
        );

        assertEq(bountyAtPositiveEquity, positivePreview.keeperBountyUsdc, "Positive execution must match preview");
        assertEq(bountyAtNegativeEquity, negativePreview.keeperBountyUsdc, "Negative execution must match preview");
        assertEq(bountyAtPositiveEquity, bountyAtNegativeEquity, "Bounty must remain continuous across zero equity");
    }

    function test_H4_SeniorRequiresExplicitRecapAfterFullWipeout() public {
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
        (bool legacyDepositAccepted,) =
            address(pool).call(abi.encodeWithSignature("depositSenior(uint256)", depositAmount));
        assertFalse(legacyDepositAccepted, "removed synchronous Senior entrypoint must stay unavailable");
        vm.stopPrank();

        usdc.mint(address(pool), depositAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            depositAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), depositAmount, "Senior tranche should accept recapitalization from zero");
        assertEq(pool.seniorHighWaterMark(), depositAmount, "Recapitalization should seed a fresh HWM");
    }

    function test_M1_WithdrawMustRevertWhenMarkIsStale() public {
        _fundTrader(trader, 100_000 * 1e6);
        address account = trader;

        _open(account, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        vm.warp(block.timestamp + 1 days);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(account, 1e6);
    }

    function test_M2_StaleReconcileMustNotAdvanceClock() public {
        _fundSenior(address(0x666), 200_000 * 1e6);
        _fundJunior(address(0x777), 200_000 * 1e6);
        _fundTrader(trader, 50_000 * 1e6);

        address account = trader;
        _open(account, CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8);

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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
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

        address skewAccount = skewTrader;
        address mmAccount = marketMaker;
        address flipAccount = flipper;

        _open(skewAccount, CfdTypes.Side.BEAR, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(mmAccount, CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8);
        _open(flipAccount, CfdTypes.Side.BULL, 1_000_000 * 1e18, 100_000 * 1e6, 1e8);

        _close(mmAccount, CfdTypes.Side.BULL, 500_000 * 1e18, 1e8);

        uint256 mmAfter = clearinghouse.balanceUsdc(mmAccount);
        uint256 depositAmount = 500_000 * 1e6;
        uint256 execFeesRoundTrip = ((500_000 * 1e6 * 4) / 10_000) * 2;

        assertEq(mmAfter, depositAmount - execFeesRoundTrip, "VPI clamp should prevent net rebate extraction");
    }

}

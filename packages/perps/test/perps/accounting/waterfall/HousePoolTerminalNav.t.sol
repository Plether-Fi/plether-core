// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolAccountBehaviorTest is HousePoolAsyncTestBase {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
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

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _mintAndAccountPoolExcess(
        uint256 amount
    ) internal {
        usdc.mint(address(pool), amount);
        pool.accountExcess();
    }

    function test_SeniorDepositDoesNotCapturePriorYield() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        _mintAndAccountPoolExcess(20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);

        uint256 carolDeposit = 100_000 * 1e6;
        _fundSenior(carol, carolDeposit);

        uint256 carolShares = seniorVault.balanceOf(carol);
        uint256 carolShareValue = seniorVault.convertToAssets(carolShares);

        assertLe(carolShareValue, carolDeposit, "Carol should not profit from pre-existing yield");
    }

    // MtM: trader profit reduces junior principal
    function test_MtM_TraderProfitReducesJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        _open(alice, CfdTypes.Side.SHORT, 200_000e18, 10_000e6, 1e8);

        uint256 juniorBefore = pool.juniorPrincipal();

        _open(carol, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1.2e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLt(juniorAfter, juniorBefore, "MtM: junior principal must decrease when traders are winning");
        assertGt(_unrealizedTraderPnl(), 0, "Traders should have positive unrealized PnL");
    }

    // Exact terminal NAV recognizes only the account-local loss collateral that LPs can actually collect.
    function test_TerminalNav_CollectibleTraderLossIncreasesJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        _open(alice, CfdTypes.Side.SHORT, 200_000e18, 10_000e6, 1e8);

        uint256 juniorBefore = pool.juniorPrincipal();

        _open(carol, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 0.8e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertGt(juniorAfter, juniorBefore, "collectible terminal value must accrue to Junior");
        assertGt(_terminalLpPriceDelta(), 0, "LP terminal delta should be positive for collectible trader loss");
        assertLt(_unrealizedTraderPnl(), 0, "Traders should have negative unrealized PnL");
    }

    function test_TerminalNav_OpenPnlUsesSameJuniorEntryAndExitPricing() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _open(alice, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));
        assertLt(_terminalLpPriceDelta(), 0, "setup requires a live trader-profit liability");

        (, uint256 withdrawalJuniorNav,,) = pool.getPendingTrancheState();
        (, uint256 depositJuniorNav) = pool.getPendingDepositTrancheState();
        assertEq(depositJuniorNav, withdrawalJuniorNav, "entry and exit must project one exact Junior NAV");

        uint256 depositAssets = 25_000e6;
        uint256 requestId = _requestAsyncDeposit(juniorVault, carol, depositAssets);
        vm.warp(pool.lpEpochStart(requestId));
        _refreshMarkForAsyncSettlement();

        (, withdrawalJuniorNav,,) = pool.getPendingTrancheState();
        (, depositJuniorNav) = pool.getPendingDepositTrancheState();
        assertEq(depositJuniorNav, withdrawalJuniorNav, "settlement-time entry and exit NAV must match");
        uint256 expectedShares =
            juniorVault.quoteDepositFromState(depositAssets, withdrawalJuniorNav, juniorVault.totalSupply(), 0);

        _settleLpEpochForTest();
        (uint256 epochAssets, uint256 epochShares,,, bool finalized) = juniorVault.depositEpochs(requestId);
        assertTrue(finalized, "mature exact-NAV deposit should finalize");
        assertEq(epochAssets, depositAssets, "settled epoch asset basis mismatch");
        assertEq(epochShares, expectedShares, "actual mint must use the same NAV exposed to redemptions");
    }

    // MtM zeroes after all positions closed
    function test_MtM_ZeroAfterAllPositionsClosed() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        address account = alice;

        _open(alice, CfdTypes.Side.SHORT, 100_000e18, 5000e6, 1e8);
        _close(alice, CfdTypes.Side.SHORT, 100_000e18, 1e8);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0);

        assertEq(_sideEntryNotional(CfdTypes.Side.LONG), 0, "Long entry notional should be zero");
        assertEq(_sideEntryNotional(CfdTypes.Side.SHORT), 0, "Short entry notional should be zero");
        assertEq(_unrealizedTraderPnl(), 0, "Unrealized PnL should be zero with no positions");
    }

    // Redemption requests remain live while pricing is stale; settlement applies the canonical exit policy.
    function test_StaleMarkDoesNotBlockRedeemRequest() public {
        _fundJunior(bob, 500_000e6);
        _fundJunior(carol, 500_000e6);
        _fundTrader(alice, 50_000e6);
        vm.warp(block.timestamp + 2 hours);

        _open(alice, CfdTypes.Side.SHORT, 400_000e18, 20_000e6, 1e8);

        vm.warp(block.timestamp + 121);

        uint256 requestedShares = juniorVault.estimateWithdrawShares(1e6);
        uint256 requestId = _requestAsyncRedeem(juniorVault, bob, requestedShares);
        assertEq(
            juniorVault.pendingRedeemRequest(requestId, bob),
            requestedShares,
            "stale pricing must not prevent escrowed exit requests"
        );
    }

    function test_Reconcile_AllowsStaleMarkWithoutLiveLiability() public {
        _fundJunior(bob, 500_000e6);

        _mintAndAccountPoolExcess(10_000e6);
        vm.warp(block.timestamp + 121);

        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(
            pool.juniorPrincipal(), juniorBefore, "Without live liability, reconcile should not require a fresh mark"
        );
    }

    function test_OracleFrozen_DoesNotBlockWithdrawals() public {
        uint256 saturdayFrozen = 1_710_021_600;
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        _open(alice, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        vm.warp(saturdayFrozen);
        assertTrue(engine.isOracleFrozen(), "Test setup should advance into a frozen oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 3 hours));

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 requestShares = juniorVault.estimateWithdrawShares(1e6);
        uint256 requestId = _requestAsyncRedeem(juniorVault, bob, requestShares);
        _settleAsyncRequest(requestId, false);
        (uint256 fundedShares, uint256 assetsPaid) = _claimAsyncRedeem(juniorVault, requestId, bob);

        assertEq(fundedShares, requestShares, "the frozen-window request should be fully funded");
        assertGt(assetsPaid, 0, "the frozen-window exit should pay assets after the configured fee");
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + assetsPaid, "oracleFrozen alone should not block LP exits");
    }

    function test_MaxWithdraw_RemainsExecutableWithPendingCarryAccrual() public {
        uint256 saturdayFrozen = 1_710_021_600;
        _fundJunior(bob, 1_000_000e6);

        address longTrader = address(0x444);
        _fundTrader(longTrader, 100_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 400_000e18, 40_000e6, 1e8);

        address shortTrader = address(0x555);
        _fundTrader(shortTrader, 100_000e6);
        _open(shortTrader, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);

        uint256 requestId = _requestAsyncRedeem(juniorVault, bob, juniorVault.maxRequestRedeem(bob));
        _settleAsyncRequest(requestId, false);
        uint256 quotedAssets = juniorVault.maxWithdraw(bob);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        juniorVault.withdraw(quotedAssets, bob, bob);

        assertEq(
            usdc.balanceOf(bob),
            bobBalanceBefore + quotedAssets,
            "maxWithdraw quote should remain executable after sync"
        );
    }

    function test_MaxRedeem_RemainsExecutableWithPendingCarryAccrual() public {
        uint256 saturdayFrozen = 1_710_021_600;
        _fundJunior(bob, 1_000_000e6);

        address longTrader = address(0x444);
        _fundTrader(longTrader, 100_000e6);
        _open(longTrader, CfdTypes.Side.LONG, 400_000e18, 40_000e6, 1e8);

        address shortTrader = address(0x555);
        _fundTrader(shortTrader, 100_000e6);
        _open(shortTrader, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);

        uint256 requestId = _requestAsyncRedeem(juniorVault, bob, juniorVault.maxRequestRedeem(bob));
        _settleAsyncRequest(requestId, false);
        uint256 quotedShares = juniorVault.maxRedeem(bob);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 quotedAssets = juniorVault.maxWithdraw(bob);

        vm.prank(bob);
        uint256 redeemedAssets = juniorVault.redeem(quotedShares, bob, bob);

        assertEq(redeemedAssets, quotedAssets, "maxRedeem should pay the settled claimable asset amount");
        assertEq(
            usdc.balanceOf(bob),
            bobBalanceBefore + redeemedAssets,
            "maxRedeem quote should remain executable after sync"
        );
    }

    // Closing both sides removes all current terminal price exposure.
    function test_ClosingAllPositionsClearsTerminalPriceExposure() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        _open(alice, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);
        _open(carol, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 90 days);

        _close(carol, CfdTypes.Side.LONG, 100_000e18, 1e8);
        _close(alice, CfdTypes.Side.SHORT, 300_000e18, 1e8);

        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 0, "All long positions closed");
        assertEq(_sideOpenInterest(CfdTypes.Side.SHORT), 0, "All short positions closed");

        assertEq(_terminalLpPriceDelta(), 0, "closed positions leave no terminal price exposure");
    }

    // Once positions close, every unit of pool cash remains accounted for.
    function test_DistributableRevenueDoesNotDependOnLegacySpread() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        _open(alice, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);
        _open(carol, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 90 days);

        _close(carol, CfdTypes.Side.LONG, 100_000e18, 1e8);
        _close(alice, CfdTypes.Side.SHORT, 300_000e18, 1e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 totalClaimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 pendingFees = clearinghouse.balanceUsdc(engine.protocolTreasury());

        assertGe(totalClaimed + pendingFees, poolBalance, "All pool cash must be accounted for with zero open interest");
    }

    // legacy negative spread must not inflate junior beyond separately realized carry
    function test_LegacyNegativeSpreadDoesNotInflateJuniorBeyondRealizedCarry() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        _open(alice, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);
        _open(carol, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        uint256 accountedAssetsBeforeClose = pool.accountedAssets();
        _close(carol, CfdTypes.Side.LONG, 100_000e18, 1e8);
        uint256 realizedCarryUsdc = pool.accountedAssets() - accountedAssetsBeforeClose;

        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engine.terminalNavSnapshot();
        assertEq(terminalSnapshot.terminalLpPriceDeltaUsdc, 0, "remaining position has no terminal price PnL");
        assertGt(realizedCarryUsdc, 0, "close should separately realize elapsed carry into the pool");

        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 juniorAfter = pool.juniorPrincipal();

        uint256 fundedSeniorCouponUsdc = seniorAfter - seniorBefore;
        uint256 juniorCarryRevenueUsdc = juniorAfter - juniorBefore;
        assertEq(
            fundedSeniorCouponUsdc + juniorCarryRevenueUsdc,
            realizedCarryUsdc,
            "realized carry must account for the full claimant increase"
        );
        assertEq(
            juniorAfter,
            juniorBefore + realizedCarryUsdc - fundedSeniorCouponUsdc,
            "legacy spread state must not add junior value beyond realized carry after senior coupon"
        );
    }

    // fees withdrawable at high utilization
    function test_FeesWithdrawableAtHighUtilization() public {
        _fundJunior(bob, 500_200e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        _open(alice, CfdTypes.Side.LONG, 250_000e18, 25_000e6, 1e8);
        _open(carol, CfdTypes.Side.LONG, 250_100e18, 25_000e6, 1e8);

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertGt(fees, 0, "Fees should have accumulated");

        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.LONG);
        assertEq(maxLiability, 500_100e6, "Both positions should be open");

        address feeRecipient = engine.protocolTreasury();
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);
        _withdrawProtocolTreasury(fees);

        assertEq(usdc.balanceOf(feeRecipient) - recipientBalanceBefore, fees, "Fee recipient should receive fees");
    }

    // senior HWM preserved for restoration after wipeout
    function test_SeniorHWMResetPreventsRestoration() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        _fundTrader(carol, 50_000e6);
        _open(carol, CfdTypes.Side.SHORT, 200_000e18, 20_000e6, 1e8);

        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: carol,
                sizeDelta: 200_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: true
            }),
            1.8e8,
            closeDepth,
            uint64(block.timestamp)
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfterLoss = pool.seniorPrincipal();
        assertGt(pool.seniorHighWaterMark(), seniorAfterLoss, "Senior below HWM");
        assertGt(seniorAfterLoss, 0, "Senior not fully wiped");

        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorPrincipal(), seniorAfterLoss, "Senior should be restored after recovery");
    }

    // senior deposit reverts when tranche is impaired (seniorPrincipal < HWM)
    function test_FlashDepositBlockedWhenSeniorImpaired() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        _fundTrader(carol, 50_000e6);
        _open(carol, CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 1e8);

        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: carol,
                sizeDelta: 100_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.SHORT,
                isClose: true
            }),
            2e8,
            closeDepth,
            uint64(block.timestamp)
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorHighWaterMark() - pool.seniorPrincipal(), 0, "Senior deficit exists");

        address dave = address(0x444);
        usdc.mint(dave, 10_000_000e6);
        vm.startPrank(dave);
        usdc.approve(address(seniorVault), 10_000_000e6);
        assertEq(seniorVault.maxRequestDeposit(dave), 0, "request capacity should be zero while impaired");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(10_000_000e6, dave, dave);
        vm.stopPrank();
    }

}

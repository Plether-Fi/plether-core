// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract HousePoolTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _mintAndAccountPoolExcess(
        uint256 amount
    ) internal {
        usdc.mint(address(pool), amount);
        pool.accountExcess();
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    // ==========================================
    // DEPOSIT & PRINCIPAL TRACKING
    // ==========================================

    function test_SeniorJuniorDeposit() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        assertEq(pool.seniorPrincipal(), 500_000 * 1e6);
        assertEq(pool.juniorPrincipal(), 300_000 * 1e6);
        assertEq(pool.totalAssets(), 800_000 * 1e6);
        assertEq(seniorVault.totalAssets(), 500_000 * 1e6);
        assertEq(juniorVault.totalAssets(), 300_000 * 1e6);
    }

    // ==========================================
    // REVENUE WATERFALL
    // ==========================================

    function test_RevenueDistribution() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Simulate realized revenue entering the pool, then account it explicitly.
        _mintAndAccountPoolExcess(100_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield = 500k * 8% * 1 year = 40k (capped at revenue=100k, so 40k)
        // Junior surplus = 100k - 40k = 60k
        assertEq(pool.seniorPrincipal(), 540_000 * 1e6, "Senior gets 8% APY yield");
        assertEq(pool.juniorPrincipal(), 560_000 * 1e6, "Junior gets surplus");
    }

    function test_RevenueDistribution_SeniorCapped() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Small revenue: only 10k
        _mintAndAccountPoolExcess(10_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield would be 40k but capped at 10k revenue
        assertEq(pool.seniorPrincipal(), 510_000 * 1e6, "Senior capped at available revenue");
        assertEq(pool.juniorPrincipal(), 500_000 * 1e6, "Junior gets nothing when revenue < senior yield");
    }

    function test_SeniorPreviewDeposit_MatchesReconcileFirstDeposit() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        _mintAndAccountPoolExcess(100_000 * 1e6);

        vm.warp(block.timestamp + 365 days);

        address dave = address(0x4444);
        uint256 assets = 100_000 * 1e6;
        usdc.mint(dave, assets);

        vm.startPrank(dave);
        usdc.approve(address(seniorVault), assets);
        uint256 previewedShares = seniorVault.previewDeposit(assets);
        uint256 mintedShares = seniorVault.deposit(assets, dave);
        vm.stopPrank();

        assertEq(mintedShares, previewedShares, "previewDeposit should match reconcile-first deposit shares");
    }

    // ==========================================
    // LOSS WATERFALL
    // ==========================================

    function test_LossWaterfall_JuniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.50 → BULL profits $100k
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.5e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLe(pool.juniorPrincipal(), 300_000 * 1e6, "Junior absorbed loss");
        assertEq(pool.seniorPrincipal(), 500_000 * 1e6, "Senior untouched when junior covers");
    }

    function test_JuniorWipeout_SeniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 50_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.50 → BULL profits $100k, exceeding junior's $50k
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.5e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped out");
        assertLt(pool.seniorPrincipal(), 500_000 * 1e6, "Senior absorbs remaining loss");
    }

    // ==========================================
    // WITHDRAWAL PRIORITY
    // ==========================================

    function test_WithdrawalPriority() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 800_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Max liability = 800k (BULL at $1, cap $2 → max profit = entry*size = $800k)
        // Free USDC = totalAssets - maxLiability
        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 seniorMax = pool.getMaxSeniorWithdraw();
        uint256 juniorMax = pool.getMaxJuniorWithdraw();

        // Senior has first claim on freeUSDC
        assertEq(seniorMax, freeUsdc < 500_000 * 1e6 ? freeUsdc : 500_000 * 1e6);
        // Junior only gets what's left after senior's claim
        uint256 expectedJuniorMax = freeUsdc > 500_000 * 1e6 ? freeUsdc - 500_000 * 1e6 : 0;
        if (expectedJuniorMax > 500_000 * 1e6) {
            expectedJuniorMax = 500_000 * 1e6;
        }
        assertEq(juniorMax, expectedJuniorMax);
    }

    function test_SeniorCanWithdrawWhenJuniorCannot() public {
        _fundSenior(alice, 200_000 * 1e6);
        _fundJunior(bob, 200_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 250_000 * 1e18, 25_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // freeUSDC ≈ 400k - 250k + exec_fees. Senior principal = 200k.
        // Senior max = min(200k, freeUSDC) < 200k
        // Junior max = max(0, freeUSDC - 200k) = 0 since freeUSDC < 200k
        uint256 seniorMax = pool.getMaxSeniorWithdraw();
        assertGt(seniorMax, 0, "Senior can withdraw");
        assertLe(seniorMax, 200_000 * 1e6, "Senior cannot exceed principal when junior is fully subordinated");
        assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior fully subordinated");
    }

    function test_JuniorMaxWithdraw_MatchesReconcileFirstWithdraw() public {
        bytes32 carolId = bytes32(uint256(uint160(carol)));

        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        _open(carolId, CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8);
        _close(carolId, CfdTypes.Side.BULL, 200_000 * 1e18, 0.5e8);

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 quotedAssets = juniorVault.maxWithdraw(bob);
        uint256 sharesBefore = juniorVault.balanceOf(bob);

        assertLt(quotedAssets, 300_000 * 1e6, "reconciled losses should reduce junior withdraw capacity");

        vm.prank(bob);
        juniorVault.withdraw(quotedAssets, bob, bob);

        assertEq(usdc.balanceOf(bob), quotedAssets, "maxWithdraw quote should remain executable after reconcile");
        assertLt(juniorVault.balanceOf(bob), sharesBefore, "withdraw should burn shares using the quoted max");
    }

    // ==========================================
    // RECONCILE EXCLUDES PROTOCOL FEES
    // ==========================================

    function test_ReconcileExcludesProtocolFees() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 fees = engine.accumulatedFeesUsdc();
        assertTrue(fees > 0, "Fees should exist after trade");

        // Pool balance includes the seized margin (exec fee goes to pool as part of seize)
        // But reconcile should NOT treat fees as LP revenue
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 totalBalance = pool.totalAssets();
        assertEq(pool.juniorPrincipal(), totalBalance - fees, "Reconcile should exclude protocol fees exactly");
    }

    // ==========================================
    // FULL INTEGRATION
    // ==========================================

    function test_FullIntegration() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        // Trader opens BULL $100k at $1.00
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.80 → BULL profits $20k (paid from pool)
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.8e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool paid out ~$20k profit to trader. Junior absorbs first.
        assertLt(pool.juniorPrincipal(), 500_000 * 1e6, "Junior absorbed trader profit payout");
        assertEq(pool.seniorPrincipal(), 500_000 * 1e6, "Senior untouched");
    }

    // ==========================================
    // SENIOR RATE CHANGE
    // ==========================================

    function test_SeniorRateChange() public {
        _fundSenior(alice, 1_000_000 * 1e6);
        _fundJunior(bob, 1_000_000 * 1e6);

        // Generate some revenue
        _mintAndAccountPoolExcess(200_000 * 1e6);

        vm.warp(block.timestamp + 365 days - 48 hours - 1);

        pool.proposeSeniorRate(1200);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeSeniorRate();

        // Senior should have received 8% for the first year
        assertEq(pool.seniorPrincipal(), 1_080_000 * 1e6, "Senior got 8% before rate change");
        assertEq(pool.juniorPrincipal(), 1_120_000 * 1e6, "Junior got surplus");
    }

    function test_FinalizeSeniorRate_StaleMarkDoesNotAccrueYield() public {
        address trader = address(0x3333);
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 unpaidBefore = pool.unpaidSeniorYield();

        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        assertEq(
            pool.unpaidSeniorYield(),
            unpaidBefore,
            "Stale-mark finalization should not accrue yield"
        );
        assertEq(pool.seniorRateBps(), 1600, "Senior rate should still update after stale-mark checkpointing");
    }

    function test_FinalizeSeniorRate_SyncsFundingBeforeReconcile() public {
        address trader = address(0x4444);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 800_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        uint64 fundingBefore = engine.lastFundingTime();
        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 1);

        pool.finalizeSeniorRate();

        assertGt(engine.lastFundingTime(), fundingBefore, "Finalizing senior rate must sync funding before accounting");
    }

    function test_ProposeSeniorRate_RevertsAbove100PercentApr() public {
        vm.expectRevert(HousePool.HousePool__InvalidSeniorRate.selector);
        pool.proposeSeniorRate(10_001);
    }

    // ==========================================
    // ERC4626 SHARE ACCOUNTING
    // ==========================================

    function test_ShareAccounting_AfterRevenue() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        uint256 seniorPriceBefore = seniorVault.convertToAssets(1e9);
        uint256 juniorPriceBefore = juniorVault.convertToAssets(1e9);

        _mintAndAccountPoolExcess(20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorPriceAfter = seniorVault.convertToAssets(1e9);
        uint256 juniorPriceAfter = juniorVault.convertToAssets(1e9);

        assertTrue(seniorPriceAfter > seniorPriceBefore, "Senior share price should increase");
        assertTrue(juniorPriceAfter > juniorPriceBefore, "Junior share price should increase");
    }

    function test_SharePrice_NoFreeDilution() public {
        _fundJunior(alice, 100_000 * 1e6);
        uint256 aliceShares = juniorVault.balanceOf(alice);

        _mintAndAccountPoolExcess(20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        _fundJunior(bob, 100_000 * 1e6);
        uint256 bobShares = juniorVault.balanceOf(bob);

        assertGt(aliceShares, bobShares, "Late depositor should receive fewer shares");

        uint256 aliceAssets = juniorVault.convertToAssets(aliceShares);
        uint256 bobAssets = juniorVault.convertToAssets(bobShares);
        assertGt(aliceAssets, bobAssets, "Early depositor's shares should be worth more");
    }

    function test_UnaccountedDonation_IgnoredUntilExplicitlyAccounted() public {
        _fundJunior(bob, 500_000e6);

        uint256 accountedBefore = pool.totalAssets();
        usdc.mint(address(pool), 100_000e6);

        HousePool.VaultLiquidityView memory beforeAccount = pool.getVaultLiquidityView();
        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw balance should include unsolicited donation");
        assertEq(pool.excessAssets(), 100_000e6, "Donation should remain quarantined as excess");
        assertEq(pool.totalAssets(), accountedBefore, "Canonical assets must ignore raw donation until accounted");
        assertEq(beforeAccount.totalAssetsUsdc, accountedBefore, "Liquidity view must use canonical assets");

        pool.accountExcess();

        HousePool.VaultLiquidityView memory afterAccount = pool.getVaultLiquidityView();
        assertEq(pool.excessAssets(), 0, "Accounting excess should clear the quarantine bucket");
        assertEq(
            pool.totalAssets(),
            accountedBefore + 100_000e6,
            "Canonical assets should increase only after explicit accounting"
        );
        assertEq(
            afterAccount.totalAssetsUsdc,
            accountedBefore + 100_000e6,
            "Liquidity view should reflect explicit accounting"
        );
    }

    function test_SweepExcess_RemovesDonationWithoutChangingAccountedAssets() public {
        _fundJunior(bob, 500_000e6);

        address treasury = address(0xBEEF);
        usdc.mint(address(pool), 25_000e6);

        uint256 accountedBefore = pool.totalAssets();
        pool.sweepExcess(treasury, 25_000e6);

        assertEq(pool.totalAssets(), accountedBefore, "Sweeping raw excess must not change canonical assets");
        assertEq(pool.excessAssets(), 0, "Swept donation should no longer remain as excess");
        assertEq(usdc.balanceOf(treasury), 25_000e6, "Sweep recipient should receive only the quarantined donation");
    }

    function test_RecordProtocolInflow_OnlyEngineCanAccountRawExcess() public {
        _fundJunior(bob, 500_000e6);
        usdc.mint(address(pool), 25_000e6);

        vm.prank(alice);
        vm.expectRevert(HousePool.HousePool__Unauthorized.selector);
        pool.recordProtocolInflow(25_000e6);

        vm.prank(address(engine));
        pool.recordProtocolInflow(25_000e6);

        assertEq(pool.totalAssets(), 525_000e6, "Engine-accounted inflow should become canonical immediately");
        assertEq(pool.excessAssets(), 0, "Engine-accounted inflow should not remain quarantined as excess");
    }

    function test_RecordProtocolInflow_OrderRouterCanAccountRawExcess() public {
        _fundJunior(bob, 500_000e6);
        usdc.mint(address(pool), 25_000e6);

        vm.prank(address(router));
        pool.recordProtocolInflow(25_000e6);

        assertEq(pool.totalAssets(), 525_000e6, "Router-accounted inflow should become canonical immediately");
        assertEq(pool.excessAssets(), 0, "Router-accounted inflow should not remain quarantined as excess");
    }

    function test_RecordProtocolInflow_RestoresCanonicalAssetsAfterRawShortfall() public {
        _fundJunior(bob, 500_000e6);
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 100_000e6);
        usdc.mint(address(pool), 10_000e6);

        vm.prank(address(engine));
        pool.recordProtocolInflow(10_000e6);

        assertEq(
            pool.totalAssets(),
            410_000e6,
            "Engine-accounted inflow should restore canonical assets even after a raw shortfall"
        );
        assertEq(pool.excessAssets(), 0, "Shortfall recovery inflow should not remain quarantined as excess");
    }

    function test_SetOrderRouter_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__RouterAlreadySet.selector);
        pool.setOrderRouter(address(0x999));
    }

    function test_SetSeniorVault_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__SeniorVaultAlreadySet.selector);
        pool.setSeniorVault(address(0x999));
    }

    function test_SetJuniorVault_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__JuniorVaultAlreadySet.selector);
        pool.setJuniorVault(address(0x999));
    }

    function test_PayOut_Unauthorized_Reverts() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(HousePool.HousePool__Unauthorized.selector);
        pool.payOut(alice, 1000 * 1e6);
    }

    function test_H6_ReconcileSpam_DoesNotEraseSeniorYield() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _mintAndAccountPoolExcess(100_000 * 1e6);

        // Use absolute timestamps to avoid block.timestamp caching in test call frame
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 365; i++) {
            vm.warp(t0 + i * 1 days);
            vm.prank(address(juniorVault));
            pool.reconcile();
        }

        // Senior's total claim = seniorPrincipal + unpaidSeniorYield
        // Should be ~$540k (8% * $500k = $40k yield) regardless of reconcile frequency.
        uint256 totalSeniorClaim = pool.seniorPrincipal() + pool.unpaidSeniorYield();
        // Integer division across 365 daily reconciles loses ≤ $1 cumulative
        assertGe(totalSeniorClaim, 540_000 * 1e6 - 1e6, "Senior total claim must reflect 8% APY");

        // Inject fresh revenue to pay unpaid yield
        _mintAndAccountPoolExcess(50_000 * 1e6);
        vm.warp(t0 + 366 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Now unpaidSeniorYield should be mostly paid from fresh revenue
        assertGe(pool.seniorPrincipal(), 540_000 * 1e6 - 1e6, "Senior principal catches up when revenue arrives");
    }

    function test_M12_GetFreeUSDC_ReservesFees() public {
        _fundJunior(bob, 500_000 * 1e6);

        address trader = address(0x444);
        _fundTrader(trader, 50_000 * 1e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // 100k BULL at $1.00: protocol accrues the full $40 execution fee.
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 40_000_000, "Protocol fees should remain separate from reserved execution bounty escrow");

        uint256 freeUSDC = pool.getFreeUSDC();
        uint256 vaultBal = pool.totalAssets();
        uint256 expectedReserved = 100_000 * 1e6 + fees;

        assertEq(
            freeUSDC,
            vaultBal - expectedReserved,
            "Free USDC should reserve both directional liability and fees exactly"
        );
    }

    function test_GetVaultLiquidityView_ReturnsCurrentPoolState() public {
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 300_000e6);

        HousePool.VaultLiquidityView memory viewData = pool.getVaultLiquidityView();
        assertEq(viewData.totalAssetsUsdc, pool.totalAssets());
        assertEq(viewData.freeUsdc, pool.getFreeUSDC());
        assertEq(viewData.withdrawalReservedUsdc, engine.getWithdrawalReservedUsdc());
        assertEq(viewData.seniorPrincipalUsdc, pool.seniorPrincipal());
        assertEq(viewData.juniorPrincipalUsdc, pool.juniorPrincipal());
        assertEq(viewData.unpaidSeniorYieldUsdc, pool.unpaidSeniorYield());
        assertEq(viewData.seniorHighWaterMarkUsdc, pool.seniorHighWaterMark());
        assertEq(viewData.oracleFrozen, engine.isOracleFrozen());
        assertEq(viewData.degradedMode, engine.degradedMode());
    }

    function test_M10_JitLP_BlockedByCooldown() public {
        _fundJunior(bob, 500_000 * 1e6);

        _fundJunior(carol, 500_000 * 1e6);

        _mintAndAccountPoolExcess(50_000 * 1e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")), carol, 500_000 * 1e6, 0
            )
        );
        vm.prank(carol);
        juniorVault.withdraw(500_000 * 1e6, carol, carol);
    }

    function test_DustDepositToExistingHolderDoesNotResetCooldown() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 50 minutes);

        // Attacker deposits 1 wei on behalf of alice to grief her cooldown
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1);
        juniorVault.deposit(1, alice);
        vm.stopPrank();

        // Third-party deposits must not grief Alice's cooldown.
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 100_000 * 1e6, "Victim withdraw should succeed after original cooldown");
    }

    function test_SeniorPrincipal_RestoredBeforeJuniorSurplus() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        assertEq(pool.seniorHighWaterMark(), 500_000 * 1e6);

        // Catastrophic loss: pool loses $600k → junior wiped ($500k), senior loses $100k
        // Simulate by burning pool USDC
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 600_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped");
        assertEq(pool.seniorPrincipal(), 400_000 * 1e6, "Senior lost $100k");
        assertEq(pool.seniorHighWaterMark(), 500_000 * 1e6, "HWM remembers original principal");

        // Revenue arrives: $150k. Should restore senior $100k first, then junior gets $50k.
        usdc.mint(address(pool), 150_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield for ~0 elapsed time is negligible, so nearly all goes to restoration + junior
        assertEq(pool.seniorPrincipal(), 500_000 * 1e6, "Senior restored to HWM");
        assertEq(pool.juniorPrincipal(), 50_000 * 1e6, "Junior gets remainder after restoration");
    }

    function test_SeniorHWM_ProportionalOnWithdraw() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Warp past cooldown
        vm.warp(block.timestamp + 1 hours);

        // Alice withdraws half her senior position
        vm.prank(alice);
        seniorVault.withdraw(250_000 * 1e6, alice, alice);

        assertEq(pool.seniorPrincipal(), 250_000 * 1e6);
        assertEq(pool.seniorHighWaterMark(), 250_000 * 1e6, "HWM scales proportionally on withdraw");
    }

    function test_SeniorHWM_PreservedOnFullWipeout() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        // Total wipeout
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 200_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), 100_000 * 1e6, "HWM preserves senior recovery rights after wipeout");
    }

    function test_C3_DepositCooldown_BlocksFlashWithdraw() public {
        _fundJunior(alice, 100_000 * 1e6);

        // Alice deposits and tries to withdraw in the same block
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")), alice, 100_000 * 1e6, 0
            )
        );
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);

        // After cooldown passes, withdrawal succeeds
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100_000 * 1e6, "Withdrawal after cooldown succeeds");
    }

    // ==========================================
    // C-01: LIQUIDATION CLEARS UNREALIZED FUNDING FOR CLOSED POSITION
    // ==========================================

    function test_C01_LiquidationClearsUnrealizedFunding() public {
        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 1e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 1e18,
                maxApy: 5e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 100_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(engine.getUnrealizedFundingPnl(), 0, "Starts at zero");

        vm.warp(block.timestamp + 60 days);

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.95e8);

        router.executeLiquidation(carolId, pythData);

        assertEq(engine.getUnrealizedFundingPnl(), 0, "Liquidation clears unrealized funding for closed position");
    }

    // ==========================================
    // C-03: getFreeUSDC RESERVES POSITIVE UNREALIZED FUNDING
    // ==========================================

    function test_C03_GetFreeUSDC_ReservesPositiveUnrealizedFunding() public {
        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 1e18,
                maxApy: 5e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        _fundJunior(bob, 1_000_000 * 1e6);

        address trader1 = address(0x444);
        _fundTrader(trader1, 100_000 * 1e6);
        vm.prank(trader1);
        router.commitOrder(CfdTypes.Side.BULL, 400_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        address trader2 = address(0x555);
        _fundTrader(trader2, 100_000 * 1e6);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 20 days);

        // Bull payer closes → bear receiver still open with positive unrealized funding
        bytes[] memory closePythData = new bytes[](1);
        closePythData[0] = abi.encode(1e8);
        vm.prank(trader1);
        router.commitOrder(CfdTypes.Side.BULL, 400_000 * 1e18, 0, 0, true);
        router.executeOrder(3, closePythData);

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertTrue(unrealizedFunding > 0, "Remaining receiver has positive unrealized funding");

        uint256 freeUSDC = pool.getFreeUSDC();
        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiab = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 naiveFree = bal - maxLiab - fees;

        assertLt(freeUSDC, naiveFree, "getFreeUSDC must reserve positive unrealized funding");
    }

    // ==========================================
    // C-03b: _reconcile RESERVES POSITIVE UNREALIZED FUNDING FROM DISTRIBUTABLE
    // ==========================================

    function test_C03b_Reconcile_ReservesPositiveUnrealizedFunding() public {
        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 1e18,
                maxApy: 5e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        _fundJunior(bob, 1_000_000 * 1e6);
        uint256 juniorBefore = pool.juniorPrincipal();

        address trader1 = address(0x444);
        _fundTrader(trader1, 100_000 * 1e6);
        vm.prank(trader1);
        router.commitOrder(CfdTypes.Side.BULL, 400_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        address trader2 = address(0x555);
        _fundTrader(trader2, 100_000 * 1e6);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 20 days);

        bytes[] memory closePythData = new bytes[](1);
        closePythData[0] = abi.encode(1e8);
        vm.prank(trader1);
        router.commitOrder(CfdTypes.Side.BULL, 400_000 * 1e18, 0, 0, true);
        router.executeOrder(3, closePythData);

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertTrue(unrealizedFunding > 0, "Remaining receiver has positive unrealized funding");

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool cash must cover LP claims + fees + unrealized funding obligations
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 juniorAfter = pool.juniorPrincipal();
        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 reserved = fees + uint256(unrealizedFunding);
        assertGe(poolBalance, juniorAfter + reserved, "Pool cash must cover LP claims + reserved obligations");
    }

}

contract HousePoolAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
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

    // Regression: Finding-2 — stale totalAssets on deposit
    function test_StaleSharePriceOnDeposit() public {
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

    // Regression: H-01 — MtM: trader profit reduces junior principal
    function test_MtM_TraderProfitReducesJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.2e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1.2e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLt(juniorAfter, juniorBefore, "MtM: junior principal must decrease when traders are winning");
        assertGt(engine.getUnrealizedTraderPnl(), 0, "Traders should have positive unrealized PnL");
    }

    // Regression: H-01 + C-03 — unrealized trader losses must not inflate junior principal
    function test_MtM_TraderLossDoesNotInflateJuniorPrincipal() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 juniorBefore = pool.juniorPrincipal();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(0.8e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 0.8e8, false);
        router.executeOrder(2, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(juniorAfter, juniorBefore, "C-03 fix: unrealized trader losses must not inflate junior principal");
        assertLt(engine.getUnrealizedTraderPnl(), 0, "Traders should have negative unrealized PnL");
    }

    // Regression: H-01 — MtM zeroes after all positions closed
    function test_MtM_ZeroAfterAllPositionsClosed() public {
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 5000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 1e8, true);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0);

        assertEq(_sideEntryNotional(CfdTypes.Side.BULL), 0, "Bull entry notional should be zero");
        assertEq(_sideEntryNotional(CfdTypes.Side.BEAR), 0, "Bear entry notional should be zero");
        assertEq(engine.getUnrealizedTraderPnl(), 0, "Unrealized PnL should be zero with no positions");
    }

    // Regression: M-01 — stale mark does not block withdrawal
    function test_StaleMarkBlocksWithdrawal() public {
        _fundJunior(bob, 500_000e6);
        _fundJunior(carol, 500_000e6);
        _fundTrader(alice, 50_000e6);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 400_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.warp(block.timestamp + 121);

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)")), bob, 1e6, 0
            )
        );
        vm.prank(bob);
        juniorVault.withdraw(1e6, bob, bob);
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

    function test_FrozenOracle_UsesRelaxedMarkFreshnessForWithdrawals() public {
        uint256 saturdayFrozen = 1_710_021_600;
        _fundJunior(bob, 500_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.warp(saturdayFrozen);
        assertTrue(engine.isOracleFrozen(), "Test setup should advance into a frozen oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 3 hours));

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        juniorVault.withdraw(1e6, bob, bob);

        assertEq(
            usdc.balanceOf(bob), bobUsdcBefore + 1e6, "Frozen-oracle withdrawals should use the relaxed freshness limit"
        );
    }

    // Regression: C-02 — funding spread not permanently locked after positions close
    function test_FundingSpreadLockedAfterAllPositionsClose() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 90 days);

        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, closePrice);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 0, 0, true);
        router.executeOrder(4, closePrice);

        assertEq(_sideOpenInterest(CfdTypes.Side.BULL), 0, "All bull positions closed");
        assertEq(_sideOpenInterest(CfdTypes.Side.BEAR), 0, "All bear positions closed");

        assertEq(
            engine.getUnrealizedFundingPnl(), 0, "No positions => zero unrealized funding; spread is distributable"
        );
    }

    // Regression: C-02 — funding spread reduces distributable revenue
    function test_FundingSpreadReducesDistributableRevenue() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 90 days);

        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, closePrice);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 0, 0, true);
        router.executeOrder(4, closePrice);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 totalClaimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 pendingFees = engine.accumulatedFeesUsdc();

        assertGe(totalClaimed + pendingFees, poolBalance, "All pool cash must be accounted for with zero open interest");
    }

    // Regression: C-02 — negative funding must not inflate junior principal
    function test_NegativeFundingDoesNotInflateJuniorPrincipal() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 100_000e6);
        _fundTrader(carol, 100_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(block.timestamp + 90 days);

        bytes[] memory price = new bytes[](1);
        price[0] = abi.encode(uint256(1e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, price);

        int256 unrealizedFunding = engine.getUnrealizedFundingPnl();
        assertLt(unrealizedFunding, 0, "house is owed funding by remaining bears");

        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(juniorAfter, juniorBefore, "conservative: junior must not increase from unrealized funding debt");
    }

    // Regression: H-04 — fees withdrawable at high utilization
    function test_FeesWithdrawableAtHighUtilization() public {
        _fundJunior(bob, 500_200e6);
        _fundTrader(alice, 50_000e6);
        _fundTrader(carol, 50_000e6);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        uint64 id1 = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 250_000e18, 25_000e6, 1e8, false);
        router.executeOrder(id1, priceData);

        uint64 id2 = router.nextCommitId();
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 250_100e18, 25_000e6, 1e8, false);
        router.executeOrder(id2, priceData);

        uint256 fees = engine.accumulatedFeesUsdc();
        assertGt(fees, 0, "Fees should have accumulated");

        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        assertEq(maxLiability, 500_100e6, "Both positions should be open");

        address feeRecipient = address(0xFEE);
        engine.withdrawFees(feeRecipient);

        assertEq(usdc.balanceOf(feeRecipient), fees, "Fee recipient should receive fees");
    }

    // Regression: C-03 — senior HWM preserved for restoration after wipeout
    function test_SeniorHWMResetPreventsRestoration() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: bytes32(uint256(uint160(carol))),
                sizeDelta: 200_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BEAR,
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

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorPrincipal(), seniorAfterLoss, "Senior should be restored after recovery");
    }

    // Regression: C-05 — senior deposit reverts when tranche is impaired (seniorPrincipal < HWM)
    function test_FlashDepositBlockedWhenSeniorImpaired() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 closeDepth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrder(
            CfdTypes.Order({
                accountId: bytes32(uint256(uint160(carol))),
                sizeDelta: 100_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BEAR,
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
        vm.expectRevert(HousePool.HousePool__SeniorImpaired.selector);
        seniorVault.deposit(10_000_000e6, dave);
        vm.stopPrank();
    }

}

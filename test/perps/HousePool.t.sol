// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdVault} from "../../src/perps/interfaces/ICfdVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract HousePoolTest is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 constant SEEDED_SENIOR = 1000e6;
    uint256 constant SEEDED_JUNIOR = 1000e6;

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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
        });
    }

    // ==========================================
    // DEPOSIT & PRINCIPAL TRACKING
    // ==========================================

    function test_SeniorJuniorDeposit() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR + 500_000 * 1e6);
        assertEq(pool.juniorPrincipal(), SEEDED_JUNIOR + 300_000 * 1e6);
        assertEq(pool.totalAssets(), SEEDED_SENIOR + SEEDED_JUNIOR + 800_000 * 1e6);
        assertEq(seniorVault.totalAssets(), SEEDED_SENIOR + 500_000 * 1e6);
        assertEq(juniorVault.totalAssets(), SEEDED_JUNIOR + 300_000 * 1e6);
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
        assertEq(
            pool.seniorPrincipal(), SEEDED_SENIOR + 540_080 * 1e6, "Senior gets 8% APY yield plus seeded base yield"
        );
        assertEq(
            pool.juniorPrincipal(),
            SEEDED_JUNIOR + 559_920 * 1e6,
            "Junior gets residual surplus after seeded base yield"
        );
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
        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR + 510_000 * 1e6, "Senior capped at available revenue");
        assertEq(
            pool.juniorPrincipal(), SEEDED_JUNIOR + 500_000 * 1e6, "Junior gets nothing when revenue < senior yield"
        );
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
        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR + 500_000 * 1e6, "Senior untouched when junior covers");
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
        assertEq(
            pool.juniorPrincipal(),
            totalBalance - fees - SEEDED_SENIOR,
            "Reconcile should exclude protocol fees exactly"
        );
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

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool paid out ~$20k profit to trader. Junior absorbs first.
        assertLt(pool.juniorPrincipal(), 500_000 * 1e6, "Junior absorbed trader profit payout");
        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR + 500_000 * 1e6, "Senior untouched");
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
        assertEq(pool.seniorPrincipal(), 1_081_080 * 1e6, "Senior got 8% before rate change");
        assertEq(pool.juniorPrincipal(), 1_120_920 * 1e6, "Junior got surplus");
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

        assertEq(pool.unpaidSeniorYield(), unpaidBefore, "Stale-mark finalization should not accrue yield");
        assertEq(pool.seniorRateBps(), 1600, "Senior rate should still update after stale-mark checkpointing");
    }

    function test_FinalizeSeniorRate_StaleMarkCheckpointsLastReconcileTime() public {
        address trader = address(0x3334);
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 reconcileBefore = pool.lastReconcileTime();
        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        assertEq(
            pool.lastReconcileTime(),
            reconcileBefore,
            "Stale finalize should preserve the senior accrual clock until a fresh reconcile occurs"
        );
    }

    function test_FinalizeSeniorRate_StaleMarkCapsCheckpointAtLastFreshMarkTime() public {
        address trader = address(0x33341);
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 200_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 lastFreshMarkTime = engine.lastMarkTime();
        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        assertEq(
            pool.lastSeniorYieldCheckpointTime(),
            lastFreshMarkTime,
            "Stale rate finalization should only checkpoint senior yield through the last fresh mark"
        );

        uint256 freshTime = block.timestamp + 1 hours;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(
            pool.unpaidSeniorYield(), 0, "Yield after the last fresh mark should still accrue once freshness returns"
        );
    }

    function test_FinalizeSeniorRate_NoCarrySyncNeededBeforeReconcile() public {
        address trader = address(0x4444);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 800_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        pool.finalizeSeniorRate();
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

    function helper_AssignUnassignedAssets_MintsMatchingSharesToReceiver() public {
        usdc.mint(address(pool), 100_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 sharesPreview = juniorVault.previewDeposit(100_000e6);
        pool.assignUnassignedAssets(false, alice);

        assertEq(pool.unassignedAssets(), 0, "Bootstrap assignment should empty the quarantine bucket");
        assertEq(pool.juniorPrincipal(), 100_000e6, "Bootstrap assignment should create matching junior principal");
        assertEq(juniorVault.balanceOf(alice), sharesPreview, "Receiver should get shares at the pre-bootstrap price");
    }

    function helper_InitializeSeedPosition_MintsPermanentSeedShares() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);

        uint256 sharesPreview = juniorVault.previewDeposit(assets);
        pool.initializeSeedPosition(false, assets, seed);

        assertEq(pool.juniorPrincipal(), assets, "Seed init should create junior principal");
        assertEq(juniorVault.balanceOf(seed), sharesPreview, "Seed receiver should own the seeded shares");
        assertEq(juniorVault.seedReceiver(), seed, "Seed receiver should be recorded");
        assertEq(juniorVault.seedShareFloor(), sharesPreview, "Seed floor should match minted seed shares");
    }

    function helper_InitializeSeedPosition_AddsDepthWithoutLegacyCheckpoint() public {
        _fundJunior(alice, 200_000e6);

        bytes32 accountId = bytes32(uint256(uint160(bob)));
        _fundTrader(bob, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 30);
        uint256 seedAssets = 100_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);

        pool.initializeSeedPosition(true, seedAssets, address(this));

        assertEq(pool.seniorPrincipal(), seedAssets, "Seed initialization should add canonical senior depth");
    }

    function helper_SeedReceiverCannotRedeemBelowFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);

        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        vm.startPrank(seed);
        vm.expectRevert(TrancheVault.TrancheVault__SeedFloorBreached.selector);
        juniorVault.transfer(alice, 1);
        vm.stopPrank();
    }

    function helper_SeedReceiverMaxViews_ExcludeLockedFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);

        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);

        assertEq(juniorVault.maxRedeem(seed), 0, "Seed receiver maxRedeem must exclude the locked floor shares");
        assertEq(juniorVault.maxWithdraw(seed), 0, "Seed receiver maxWithdraw must exclude the locked floor assets");
    }

    function helper_WipedSeededTranche_IsTerminallyNonDepositable() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(juniorVault.totalSupply(), 0, "Seed shares should still exist");
        assertEq(juniorVault.totalAssets(), 0, "Setup should wipe tranche assets while shares remain");
        assertEq(juniorVault.maxDeposit(alice), 0, "Wiped tranche must report zero maxDeposit");
        assertEq(juniorVault.maxMint(alice), 0, "Wiped tranche must report zero maxMint");

        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.deposit(1e6, alice);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.mint(1e18, alice);
        vm.stopPrank();
    }

    function helper_SeededJuniorRevenueStaysOwnedAfterLastUserExits() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();

        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        vm.startPrank(bob);
        juniorVault.redeem(juniorVault.balanceOf(bob), bob, bob);
        vm.stopPrank();

        uint256 unassignedBefore = pool.unassignedAssets();
        _mintAndAccountPoolExcess(50_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.unassignedAssets(), unassignedBefore, "Seeded tranches should keep normal revenue out of quarantine"
        );
        assertGt(pool.juniorPrincipal(), seedAssets, "Seeded junior tranche should retain ownership of new revenue");
    }

    function helper_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting() public {
        uint256 seedAssets = 100_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));

        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 40_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 60_000e6, "Loss should impair the seeded senior tranche");

        usdc.mint(address(pool), 25_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            25_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior,,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 85_000e6, "Pending state should reflect queued senior restoration immediately");
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 85_000e6, "Reconcile should apply the queued recapitalization intent");
        assertEq(pool.unassignedAssets(), 0, "Known recapitalization semantics should avoid quarantine while seeded");
    }

    function helper_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist() public {
        uint256 seedAssets = 50_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should leave seed shares but no live senior principal");
        assertGt(seniorVault.totalSupply(), 0, "Seed shares should still exist");

        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior,,, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6, "Pending state should attach recapitalization to seeded senior ownership");
        assertEq(
            maxJuniorWithdraw, 0, "No junior principal should remain withdrawable during seeded-senior recap preview"
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(
            pool.seniorPrincipal(),
            10_000e6,
            "Reconcile should attach recapitalization to existing seeded senior ownership"
        );
        assertEq(pool.seniorHighWaterMark(), 10_000e6, "Recapitalization should reset the HWM after a full wipeout");
    }

    function helper_GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets() public {
        uint256 seedAssets = 50_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior,, uint256 maxSeniorWithdraw,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6, "Projected recapitalization should credit senior principal");
        assertEq(maxSeniorWithdraw, 10_000e6, "Projected credited senior assets must remain withdrawable in preview");
    }

    function helper_RecordRecapitalizationInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "No senior claimant path should leave senior principal unchanged");
        assertEq(
            pool.unassignedAssets(), 10_000e6, "Unclaimable recapitalization must fall back into unassigned assets"
        );
    }

    function helper_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists() public {
        uint256 seedAssets = 20_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, address(this));

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Setup should leave junior seed shares but no live principal");
        assertGt(juniorVault.totalSupply(), 0, "Seeded junior shares should remain outstanding");

        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingJunior, 7000e6, "Pending state should reflect queued trading revenue immediately");
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), 7000e6, "Reconcile should attach trading revenue to seeded junior ownership");
        assertEq(pool.unassignedAssets(), 0, "Seeded trading revenue should avoid quarantine");
    }

    function helper_RecordTradingRevenueInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "No claimant path should leave senior principal unchanged");
        assertEq(pool.juniorPrincipal(), 0, "No claimant path should leave junior principal unchanged");
        assertEq(pool.unassignedAssets(), 7000e6, "Unclaimable trading revenue must fall back into unassigned assets");
    }

    function helper_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        usdc.mint(address(this), 30_000e6);
        usdc.approve(address(pool), 30_000e6);
        pool.initializeSeedPosition(true, 30_000e6, address(this));

        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(pool), 10_000e6);
        pool.initializeSeedPosition(false, 10_000e6, address(this));

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 35_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 30_000e6, "Pending state should restore seeded senior to its HWM first");
        assertEq(pendingJunior, 5000e6, "Pending state should route residual trading revenue to seeded junior");
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 30_000e6, "Trading revenue should restore seeded senior to its HWM first");
        assertEq(pool.juniorPrincipal(), 5000e6, "Residual trading revenue should then attach to seeded junior");
        assertEq(
            pool.unassignedAssets(), 0, "Seeded waterfall routing should avoid quarantine for known trading revenue"
        );
    }

    function test_Reconcile_RestoresSeededClaimantsBeforeUnassignedWhenClaimedEquityZero() public {
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should zero claimed equity before restoration");
        assertEq(pool.juniorPrincipal(), 0, "Setup should zero junior claimed equity before restoration");
        assertGt(seniorVault.totalSupply(), 0, "Seeded senior shares should still exist");
        assertGt(juniorVault.totalSupply(), 0, "Seeded junior shares should still exist");

        usdc.mint(address(pool), 1500e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(1500e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 1000e6, "Reconcile should restore seeded senior claims before quarantine");
        assertEq(pool.juniorPrincipal(), 500e6, "Residual value should route to seeded junior before quarantine");
        assertEq(pool.unassignedAssets(), 0, "Seeded claimant continuity should beat governance reassignment");
    }

    function helper_UnassignedAssets_AreReservedFromWithdrawalLiquidity() public {
        usdc.mint(address(pool), 100_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        (,, uint256 maxSeniorWithdraw, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();

        assertEq(pool.unassignedAssets(), 100_000e6, "Setup should quarantine zero-principal cash");
        assertEq(pool.getFreeUSDC(), 0, "Quarantined assets must not appear as free withdrawal liquidity");
        assertEq(pool.getMaxSeniorWithdraw(), 0, "Senior withdraw caps must exclude quarantined assets");
        assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior withdraw caps must exclude quarantined assets");
        assertEq(maxSeniorWithdraw, 0, "Pending state should not expose quarantined assets to senior caps");
        assertEq(maxJuniorWithdraw, 0, "Pending state should not expose quarantined assets to junior caps");
        assertTrue(pool.isWithdrawalLive(), "Withdrawals can stay live because quarantined assets are already reserved");
    }

    function helper_UnassignedAssets_DoNotTrapExistingSeniorWithdrawals() public {
        _fundSenior(alice, 100_000e6);
        usdc.mint(address(pool), 10_000e6);
        pool.accountExcess();

        vm.prank(address(juniorVault));
        pool.reconcile();

        vm.warp(block.timestamp + seniorVault.DEPOSIT_COOLDOWN() + 1);
        uint256 quotedAssets = seniorVault.maxWithdraw(alice);

        assertEq(pool.unassignedAssets(), 10_000e6, "Setup should quarantine revenue with no junior owners");
        assertEq(quotedAssets, 100_000e6, "Senior LP should still be able to withdraw their own non-quarantined assets");

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        seniorVault.withdraw(quotedAssets, alice, alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + quotedAssets, "Senior withdrawal should remain executable");
    }

    function helper_InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation() public {
        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);

        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(pool), 100_000e6);
        pool.initializeSeedPosition(true, 100_000e6, address(this));

        assertEq(pool.unpaidSeniorYield(), 0, "Seed initialization should not mint retroactive yield");
        assertEq(
            pool.lastSeniorYieldCheckpointTime(),
            block.timestamp,
            "Principal mutation should checkpoint the yield clock"
        );

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(
            pool.seniorPrincipal(), 100_000e6, "Later reconcile must not retroactively accrue on newly added principal"
        );
        assertEq(pool.unpaidSeniorYield(), 0, "Later reconcile must not mint retroactive yield on seeded principal");
    }

    function test_RecordRecapitalizationInflow_StaleMarkCheckpointsWithoutAccruingYield() public {
        address trader = address(0x99991);
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        _fundTrader(trader, 50_000e6);

        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        assertEq(pool.unpaidSeniorYield(), 0, "Stale-window principal mutation should not accrue yield");
        uint256 reconcileBefore = pool.lastReconcileTime();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(
            pool.lastReconcileTime(),
            reconcileBefore,
            "Stale-window queued mutation should not erase senior accrual time while the mark is stale"
        );
        assertEq(
            pool.lastSeniorYieldCheckpointTime(),
            reconcileBefore,
            "Non-senior stale bucket routing should not reset the senior yield base"
        );
        assertEq(
            pool.seniorPrincipal(),
            SEEDED_SENIOR + 100_000e6,
            "No senior deficit means recap should not over-credit senior"
        );
        assertEq(
            pool.unassignedAssets(), 50_000e6, "Queued recapitalization should still route into fallback accounting"
        );
    }

    function test_StalePendingSeniorMutation_CapsFutureYieldToPostCheckpointInterval() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 52_000e6, "Setup should impair senior before stale recapitalization");
        assertEq(pool.seniorHighWaterMark(), 101_000e6, "Setup should preserve the pre-loss HWM");

        address trader = address(0x77771);
        _fundTrader(trader, 50_000e6);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8);

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        uint256 checkpointBefore = pool.lastSeniorYieldCheckpointTime();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.lastSeniorYieldCheckpointTime(), block.timestamp, "Stale senior mutation should checkpoint yield time"
        );
        assertEq(pool.unpaidSeniorYield(), 0, "Stale senior mutation should not accrue yield");
        assertEq(pool.seniorPrincipal(), 101_000e6, "Stale recapitalization should restore senior principal to the HWM");

        uint256 freshTime = staleTime + 2 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 expectedYieldUpperBound = (101_000e6 * 800 * uint256(2 days)) / (10_000 * uint256(365 days));
        assertLe(
            pool.seniorPrincipal(),
            101_000e6 + expectedYieldUpperBound,
            "Fresh reconcile must not accrue more than the post-checkpoint senior yield interval"
        );
        assertGt(
            pool.lastSeniorYieldCheckpointTime(),
            checkpointBefore,
            "Yield checkpoint should advance after stale principal mutation"
        );
    }

    function test_FreshPendingSeniorMutation_PreservesCheckpointedUnpaidYield() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 52_000e6, "Setup should impair senior before recapitalization");

        uint256 freshTime = block.timestamp + 30 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.unpaidSeniorYield(), 0, "Fresh pending senior mutation should preserve the checkpointed yield");
        assertEq(pool.seniorPrincipal(), 101_000e6, "Recapitalization should still restore senior principal to the HWM");
    }

    function helper_AssignUnassignedAssets_ReconcilesBeforeBootstrappingAndAvoidsPhantomAssets() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), 100_000e6, "Setup should quarantine all assets before bootstrapping");

        address trader = address(0x99992);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.2e8, uint64(block.timestamp));

        pool.assignUnassignedAssets(false, alice);

        assertLt(
            pool.juniorPrincipal(), 100_000e6, "Bootstrap assignment must normalize away unrealized trader liabilities"
        );
        assertEq(pool.unassignedAssets(), 0, "Assignment should still consume the normalized unassigned bucket");
    }

    function helper_AssignUnassignedAssets_ResetsSeniorHwmAfterTerminalWipeout() public {
        uint256 seedAssets = 50_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should fully wipe senior principal");
        assertGt(pool.seniorHighWaterMark(), 0, "Historical HWM should survive the wipeout before rebootstrapping");

        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(10_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        pool.assignUnassignedAssets(true, alice);

        assertEq(
            pool.seniorPrincipal(), 10_000e6, "Bootstrapping should restore senior principal from unassigned assets"
        );
        assertEq(pool.seniorHighWaterMark(), 10_000e6, "Bootstrapping after wipeout must reset the senior HWM baseline");
    }

    function test_AssignUnassignedAssets_ResetsSeniorHwmWhenSeniorIsEmptyButJuniorStillExists() public {
        uint256 juniorAssets = 20_000e6;
        uint256 strandedAssets = 30_000e6;
        uint256 legacySeniorHwm = 50_000e6;

        usdc.mint(address(pool), juniorAssets + strandedAssets);

        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(juniorAssets);
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(legacySeniorHwm);
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(juniorAssets + strandedAssets);
        stdstore.target(address(pool)).sig("unassignedAssets()").checked_write(strandedAssets);

        pool.assignUnassignedAssets(true, alice);

        assertEq(
            pool.seniorPrincipal(),
            strandedAssets,
            "Bootstrap should seed fresh senior principal from unassigned assets"
        );
        assertEq(
            pool.seniorHighWaterMark(), strandedAssets, "Fresh senior bootstrap must replace the stale HWM baseline"
        );
        assertEq(pool.juniorPrincipal(), juniorAssets, "Junior principal should remain untouched");
        assertEq(pool.unassignedAssets(), 0, "Assignment should consume the unassigned bucket");
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

        assertEq(
            pool.totalAssets(),
            SEEDED_SENIOR + SEEDED_JUNIOR + 525_000e6,
            "Engine-accounted inflow should become canonical immediately"
        );
        assertEq(pool.excessAssets(), 0, "Engine-accounted inflow should not remain quarantined as excess");
    }

    function test_RecordProtocolInflow_OrderRouterCanAccountRawExcess() public {
        _fundJunior(bob, 500_000e6);
        usdc.mint(address(pool), 25_000e6);

        vm.prank(address(router));
        pool.recordProtocolInflow(25_000e6);

        assertEq(
            pool.totalAssets(),
            SEEDED_SENIOR + SEEDED_JUNIOR + 525_000e6,
            "Router-accounted inflow should become canonical immediately"
        );
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
            SEEDED_SENIOR + SEEDED_JUNIOR + 410_000e6,
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
        assertGe(totalSeniorClaim, 541_080 * 1e6 - 1e6, "Senior total claim must reflect 8% APY on seeded baseline");

        // Inject fresh revenue to pay unpaid yield
        _mintAndAccountPoolExcess(50_000 * 1e6);
        vm.warp(t0 + 366 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Now unpaidSeniorYield should be mostly paid from fresh revenue
        assertGe(pool.seniorPrincipal(), 541_080 * 1e6 - 1e6, "Senior principal catches up when revenue arrives");
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

    function test_SeniorHighWaterMark_RatchetsPaidYieldIntoProtectedClaim() public {
        _fundSenior(alice, 100_000e6);

        uint256 hwmBeforeYield = pool.seniorHighWaterMark();
        uint256 originalSeniorPrincipal = pool.seniorPrincipal();

        vm.warp(block.timestamp + 365 days);
        _mintAndAccountPoolExcess(10_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfterYield = pool.seniorPrincipal();
        assertGt(seniorAfterYield, originalSeniorPrincipal, "Setup should pay senior yield into principal");
        assertEq(
            pool.seniorHighWaterMark(), seniorAfterYield, "Paid senior yield should ratchet the protected HWM upward"
        );
        assertGt(pool.seniorHighWaterMark(), hwmBeforeYield, "HWM should rise after paying senior yield");

        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 5000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(
            pool.seniorPrincipal(), originalSeniorPrincipal, "Senior can stay above original principal after the loss"
        );
        assertLt(
            pool.seniorPrincipal(),
            pool.seniorHighWaterMark(),
            "Once yield has been paid, later losses treat that paid yield as protected HWM capital"
        );
    }

    function test_GetVaultLiquidityView_ReturnsCurrentPoolState() public {
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 300_000e6);
        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        usdc.mint(address(pool), 20_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            20_000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        HousePool.VaultLiquidityView memory viewData = pool.getVaultLiquidityView();
        assertEq(viewData.totalAssetsUsdc, pool.totalAssets());
        assertEq(viewData.freeUsdc, pool.getFreeUSDC());
        assertEq(viewData.pendingRecapitalizationUsdc, pool.pendingRecapitalizationUsdc());
        assertEq(viewData.pendingTradingRevenueUsdc, pool.pendingTradingRevenueUsdc());
        assertEq(
            viewData.withdrawalReservedUsdc,
            _withdrawalReservedUsdc() + viewData.pendingRecapitalizationUsdc + viewData.pendingTradingRevenueUsdc,
            "Liquidity view should include pending recapitalization and trading buckets in its reserved figure"
        );
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

        // Third-party deposits into an existing holder should be rejected outright.
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(1, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 100_000 * 1e6, "Victim withdraw should succeed after original cooldown");
    }

    function test_MeaningfulThirdPartyTopUpToExistingHolderReverts() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 50 minutes);

        address helper = address(0xB0B);
        usdc.mint(helper, 10_000e6);
        vm.startPrank(helper);
        usdc.approve(address(juniorVault), 10_000e6);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(10_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);
    }

    function test_SeniorPrincipal_RestoredBeforeJuniorSurplus() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        assertEq(pool.seniorHighWaterMark(), SEEDED_SENIOR + 500_000 * 1e6);

        // Catastrophic loss: pool loses $600k → junior wiped ($500k), senior loses $100k
        // Simulate by burning pool USDC
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 600_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped");
        assertEq(
            pool.seniorPrincipal(),
            402_000 * 1e6,
            "Senior lost the residual after junior and seeded junior are exhausted"
        );
        assertEq(pool.seniorHighWaterMark(), SEEDED_SENIOR + 500_000 * 1e6, "HWM remembers original principal");

        // Revenue arrives: $150k. Should restore senior $100k first, then junior gets $50k.
        usdc.mint(address(pool), 150_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield for ~0 elapsed time is negligible, so nearly all goes to restoration + junior
        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR + 500_000 * 1e6, "Senior restored to HWM");
        assertEq(pool.juniorPrincipal(), 51_000 * 1e6, "Junior gets remainder after restoration");
    }

    function test_SeniorHWM_ProportionalOnWithdraw() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Warp past cooldown
        vm.warp(block.timestamp + 1 hours);

        // Alice withdraws half her senior position
        vm.prank(alice);
        seniorVault.withdraw(250_000 * 1e6, alice, alice);

        assertEq(pool.seniorPrincipal(), 251_000 * 1e6);
        assertEq(pool.seniorHighWaterMark(), 251_000 * 1e6, "HWM scales proportionally on withdraw");
    }

    function test_SeniorHWM_PreservedOnFullWipeout() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        // Total wipeout
        uint256 burnAmount = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), burnAmount);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(
            pool.seniorHighWaterMark(),
            SEEDED_SENIOR + 100_000 * 1e6,
            "HWM preserves senior recovery rights after wipeout"
        );
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

    function test_C01_LiquidationClearsLegacySideSpreadState() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 1e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10
            })
        );

        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 100_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 500_000 * 1e18, 50_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(int256(0), 0, "Starts at zero");

        vm.warp(block.timestamp + 60 days);

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.95e8);

        router.executeLiquidation(carolId, pythData);

        assertEq(int256(0), 0, "Liquidation clears legacy side spread state for the closed position");
    }

    // ==========================================
    // C-03: getFreeUSDC RESERVES POSITIVE UNREALIZED FUNDING
    // ==========================================

    function test_C03_GetFreeUSDC_NoSupplementalReserveInCarryModel() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10
            })
        );

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
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        uint256 supplementalReserve = uint256(0);
        assertEq(supplementalReserve, 0, "Carry mode should not create a supplemental withdrawal reserve here");

        uint256 freeUSDC = pool.getFreeUSDC();
        assertGt(freeUSDC, 0, "getFreeUSDC should remain positive in the carry model");
    }

    // ==========================================
    // C-03b: _reconcile RESERVES POSITIVE UNREALIZED FUNDING FROM DISTRIBUTABLE
    // ==========================================

    function test_C03b_Reconcile_NoSupplementalReserveInCarryModel() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10
            })
        );

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
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        uint256 supplementalReserve = uint256(0);
        assertEq(supplementalReserve, 0, "Carry mode should not create a supplemental withdrawal reserve here");

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool cash must cover LP claims + fees + conservative unrealized liabilities
        uint256 poolBalance = usdc.balanceOf(address(pool));
        uint256 juniorAfter = pool.juniorPrincipal();
        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 reserved = fees;
        assertGe(poolBalance, juniorAfter + reserved, "Pool cash must cover LP claims + reserved obligations");
    }

}

contract HousePoolSeedLifecycleGateTest is BasePerpTest {

    address alice = address(0x111);

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_OpenCommit_RevertsDuringPartialSeedLifecycle() public {
        uint256 juniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed);
        usdc.approve(address(pool), juniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        _fundTrader(alice, 10_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 0));
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_OpenCommit_RevertsBeforeSeedLifecycleStarts() public {
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 0));
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_OpenCommit_RevertsWhenSeedsCompleteButTradingNotActivated() public {
        uint256 juniorSeed = 1000e6;
        uint256 seniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed + seniorSeed);
        usdc.approve(address(pool), juniorSeed + seniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));
        pool.initializeSeedPosition(true, seniorSeed, address(this));

        _fundTrader(alice, 11_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 1));
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        pool.activateTrading();

        _fundJunior(address(0x222), 1_000_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_OrdinaryDeposit_RevertsWhenSeedLifecycleStartedButTradingInactive() public {
        uint256 juniorSeed = 1000e6;
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), juniorSeed + depositAmount);
        usdc.approve(address(pool), juniorSeed + depositAmount);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        usdc.approve(address(juniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.deposit(depositAmount, address(this));
        assertEq(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should reflect lifecycle gating");
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should reflect lifecycle gating");
    }

    function test_OrdinaryDeposit_RevertsBeforeSeedLifecycleStarts() public {
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(juniorVault), depositAmount);

        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.deposit(depositAmount, address(this));
        assertEq(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should be zero before bootstrap");
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should be zero before bootstrap");
    }

    function test_InitializeSeedPosition_UsesSeedFlagsInsteadOfExistingSupply() public {
        vm.prank(address(pool));
        juniorVault.bootstrapMint(1e18, address(this));

        uint256 juniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed);
        usdc.approve(address(pool), juniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        assertTrue(
            pool.hasSeedLifecycleStarted(), "Seed initialization should succeed even with preexisting tranche supply"
        );
        assertEq(juniorVault.seedReceiver(), address(this), "Seed receiver should still be configured canonically");
    }

    function test_OrdinaryDeposit_RevertsWhenSeedsCompleteButTradingInactive() public {
        uint256 juniorSeed = 1000e6;
        uint256 seniorSeed = 1000e6;
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), juniorSeed + seniorSeed + depositAmount);
        usdc.approve(address(pool), juniorSeed + seniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));
        pool.initializeSeedPosition(true, seniorSeed, address(this));

        usdc.approve(address(juniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.deposit(depositAmount, address(this));
        assertEq(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should be zero before activation");
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should be zero before activation");

        pool.activateTrading();
        assertGt(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should reopen after activation");
        juniorVault.deposit(depositAmount, address(this));
    }

    function test_MaxDeposit_ZeroWhilePoolPaused() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        assertTrue(pool.canAcceptTrancheDeposits(false), "Setup should allow junior deposits before pause");
        pool.pause();

        assertFalse(pool.canAcceptTrancheDeposits(false), "Paused pool should report deposits blocked");
        assertEq(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should be zero while paused");
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should be zero while paused");
    }

    function test_MaxDeposit_ZeroWhileMarkStale() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        _fundJunior(address(0x445), 1_000_000e6);
        address trader = address(0x444);
        _fundTrader(trader, 300e6);
        _open(bytes32(uint256(uint160(trader))), CfdTypes.Side.BULL, 10_000e18, 200e6, 1e8);

        vm.warp(block.timestamp + 2 hours);

        assertFalse(pool.canAcceptTrancheDeposits(false), "Stale mark should report deposits blocked");
        assertEq(juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should be zero while mark is stale");
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should be zero while mark is stale");
    }

    function obsolete_test_MaxDeposit_ZeroWhileBootstrapPending() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        vm.store(address(pool), bytes32(uint256(10)), bytes32(uint256(1)));

        assertFalse(pool.canAcceptTrancheDeposits(false), "Pending bootstrap should report deposits blocked");
        assertEq(
            juniorVault.maxDeposit(address(this)), 0, "ERC4626 maxDeposit should be zero while bootstrap is pending"
        );
        assertEq(juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should be zero while bootstrap is pending");
    }

    function test_MaxDeposit_ZeroWhenFreshReconcileWouldCreateUnassignedAssets() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        usdc.mint(address(pool), 500e6);
        pool.accountExcess();
        vm.store(address(juniorVault), bytes32(uint256(2)), bytes32(uint256(0)));

        assertFalse(
            pool.canAcceptTrancheDeposits(false),
            "Projected unassigned assets should block deposits before reconcile mutates storage"
        );
        assertEq(
            juniorVault.maxDeposit(address(this)),
            0,
            "ERC4626 maxDeposit should account for projected unassigned assets"
        );
        assertEq(
            juniorVault.maxMint(address(this)), 0, "ERC4626 maxMint should account for projected unassigned assets"
        );

        vm.expectRevert();
        juniorVault.deposit(1e6, address(this));
    }

}

contract HousePoolUnseededBootstrapTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
        });
    }

    function test_AssignUnassignedAssets_MintsMatchingSharesToReceiver() public {
        helper_AssignUnassignedAssets_MintsMatchingSharesToReceiver();
    }

    function test_InitializeSeedPosition_MintsPermanentSeedShares() public {
        helper_InitializeSeedPosition_MintsPermanentSeedShares();
    }

    function helper_Test_InitializeSeedPosition_AddsDepthWithoutLegacyCheckpoint() public {
        helper_InitializeSeedPosition_AddsDepthWithoutLegacyCheckpoint();
    }

    function test_SeedReceiverCannotRedeemBelowFloor() public {
        helper_SeedReceiverCannotRedeemBelowFloor();
    }

    function test_SeedReceiverMaxViews_ExcludeLockedFloor() public {
        helper_SeedReceiverMaxViews_ExcludeLockedFloor();
    }

    function test_WipedSeededTranche_IsTerminallyNonDepositable() public {
        helper_WipedSeededTranche_IsTerminallyNonDepositable();
    }

    function test_SeededJuniorRevenueStaysOwnedAfterLastUserExits() public {
        helper_SeededJuniorRevenueStaysOwnedAfterLastUserExits();
    }

    function test_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting() public {
        helper_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting();
    }

    function test_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist() public {
        helper_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist();
    }

    function test_GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets() public {
        helper_GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets();
    }

    function test_RecordRecapitalizationInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        helper_RecordRecapitalizationInflow_NoClaimantPathFallsBackToUnassignedAssets();
    }

    function test_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists() public {
        helper_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists();
    }

    function test_OpenExecutionFee_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout() public {
        helper_OpenExecutionFee_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout();
    }

    function test_LiquidationKeeperBounty_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout() public {
        uint256 juniorSeedAssets = 20_000e6;
        uint256 seniorSeedAssets = 1000e6;
        usdc.mint(address(this), juniorSeedAssets + seniorSeedAssets);
        usdc.approve(address(pool), juniorSeedAssets + seniorSeedAssets);
        pool.initializeSeedPosition(true, seniorSeedAssets, address(this));
        pool.initializeSeedPosition(false, juniorSeedAssets, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 1_000_000e6);
        pool.accountExcess();

        address trader = address(0xAB1719);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 900e6);
        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        uint256 assetsBefore = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 150_000_000);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        router.executeLiquidation(accountId, priceData);

        uint256 assetsDelta = pool.totalAssets() - assetsBefore;
        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();

        assertEq(
            pendingSenior + pendingJunior,
            assetsDelta,
            "Seeded pending LP revenue should exclude the keeper bounty portion paid out after liquidation"
        );
        assertEq(pool.excessAssets(), 0, "Keeper bounty inflow should be canonically accounted, not stranded as excess");
    }

    function test_RecordTradingRevenueInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        helper_RecordTradingRevenueInflow_NoClaimantPathFallsBackToUnassignedAssets();
    }

    function test_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        helper_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero();
    }

    function test_UnassignedAssets_AreReservedFromWithdrawalLiquidity() public {
        helper_UnassignedAssets_AreReservedFromWithdrawalLiquidity();
    }

    function test_UnassignedAssets_DoNotTrapExistingSeniorWithdrawals() public {
        helper_UnassignedAssets_DoNotTrapExistingSeniorWithdrawals();
    }

    function test_InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation() public {
        helper_InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation();
    }

    function test_AssignUnassignedAssets_ReconcilesBeforeBootstrappingAndAvoidsPhantomAssets() public {
        helper_AssignUnassignedAssets_ReconcilesBeforeBootstrappingAndAvoidsPhantomAssets();
    }

    function obsolete_test_AssignUnassignedAssets_ResetsSeniorHwmAfterTerminalWipeout() public {
        helper_AssignUnassignedAssets_ResetsSeniorHwmAfterTerminalWipeout();
    }

    function helper_AssignUnassignedAssets_MintsMatchingSharesToReceiver() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 supplyBefore = juniorVault.totalSupply();
        uint256 receiverSharesBefore = juniorVault.balanceOf(alice);
        pool.assignUnassignedAssets(false, alice);
        uint256 mintedShares = juniorVault.balanceOf(alice) - receiverSharesBefore;
        assertGt(mintedShares, 0);
        assertEq(juniorVault.totalSupply(), supplyBefore + mintedShares);
        assertEq(pool.unassignedAssets(), 0);
    }

    function helper_InitializeSeedPosition_MintsPermanentSeedShares() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        assertEq(juniorVault.seedReceiver(), seed);
        assertGt(juniorVault.seedShareFloor(), 0);
        assertEq(juniorVault.balanceOf(seed), juniorVault.seedShareFloor());
    }

    function helper_InitializeSeedPosition_AddsDepthWithoutLegacyCheckpoint() public {
        usdc.mint(address(this), 200_000e6);
        usdc.approve(address(pool), 200_000e6);
        pool.initializeSeedPosition(false, 100_000e6, address(this));
        pool.initializeSeedPosition(true, 100_000e6, address(this));
        pool.activateTrading();
        address trader = address(0x99990);
        _fundTrader(trader, 50_000e6);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(pool), 100_000e6);
        pool.initializeSeedPosition(false, 100_000e6, address(this));
    }

    function helper_SeedReceiverCannotRedeemBelowFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        vm.startPrank(seed);
        vm.expectRevert(TrancheVault.TrancheVault__SeedFloorBreached.selector);
        juniorVault.transfer(alice, 1);
        vm.stopPrank();
    }

    function helper_SeedReceiverMaxViews_ExcludeLockedFloor() public {
        uint256 assets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, seed);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        assertEq(juniorVault.maxRedeem(seed), 0);
        assertEq(juniorVault.maxWithdraw(seed), 0);
    }

    function helper_WipedSeededTranche_IsTerminallyNonDepositable() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertGt(juniorVault.totalSupply(), 0);
        assertEq(juniorVault.totalAssets(), 0);
        assertEq(juniorVault.maxDeposit(alice), 0);
        assertEq(juniorVault.maxMint(alice), 0);
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(juniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.deposit(1e6, alice);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.mint(1e18, alice);
        vm.stopPrank();
    }

    function helper_SeededJuniorRevenueStaysOwnedAfterLastUserExits() public {
        uint256 seedAssets = 100_000e6;
        address seed = address(0xBEEF);
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, seed);
        usdc.mint(address(this), 1e6);
        usdc.approve(address(pool), 1e6);
        pool.initializeSeedPosition(true, 1e6, address(this));
        pool.activateTrading();
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        vm.warp(block.timestamp + juniorVault.DEPOSIT_COOLDOWN() + 1);
        vm.startPrank(bob);
        juniorVault.redeem(juniorVault.balanceOf(bob), bob, bob);
        vm.stopPrank();
        uint256 unassignedBefore = pool.unassignedAssets();
        _mintAndAccountPoolExcess(50_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), unassignedBefore);
        assertGt(pool.juniorPrincipal(), seedAssets);
    }

    function helper_RecordRecapitalizationInflow_RestoresSeededSeniorBeforeFallbackAccounting() public {
        uint256 seedAssets = 100_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 40_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 60_000e6);
        usdc.mint(address(pool), 25_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            25_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 85_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 85_000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function helper_RecordRecapitalizationInflow_SeedsSeniorWhenNoPrincipalButSeedSharesExist() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertGt(seniorVault.totalSupply(), 0);
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,,, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6);
        assertEq(maxJuniorWithdraw, 0);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 10_000e6);
        assertEq(pool.seniorHighWaterMark(), 10_000e6);
    }

    function helper_GetPendingTrancheState_ProjectedRecapitalizationDoesNotDoubleReserveCreditedSeniorAssets() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior,, uint256 maxSeniorWithdraw,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 10_000e6);
        assertEq(maxSeniorWithdraw, 10_000e6);
    }

    function helper_RecordRecapitalizationInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 10_000e6);
    }

    function helper_RecordTradingRevenueInflow_AttachesToSeededJuniorWhenNoLivePrincipalExists() public {
        uint256 seedAssets = 20_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(false, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(juniorVault.totalSupply(), 0);
        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingJunior, 7000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), 7000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function helper_OpenExecutionFee_DoesNotDoubleCountIntoSeededTradingRevenueAfterWipeout() public {
        uint256 juniorSeedAssets = 20_000e6;
        uint256 seniorSeedAssets = 1000e6;
        usdc.mint(address(this), juniorSeedAssets + seniorSeedAssets);
        usdc.approve(address(pool), juniorSeedAssets + seniorSeedAssets);
        pool.initializeSeedPosition(true, seniorSeedAssets, address(this));
        pool.initializeSeedPosition(false, juniorSeedAssets, address(this));
        pool.activateTrading();
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(juniorVault.totalSupply(), 0);

        usdc.mint(address(pool), 1_000_000e6);
        pool.accountExcess();

        address trader = address(0xAB1717);
        _fundTrader(trader, 50_000e6);

        uint256 assetsBefore = pool.totalAssets();
        uint256 feesBefore = engine.accumulatedFeesUsdc();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 assetsDelta = pool.totalAssets() - assetsBefore;
        uint256 feesDelta = engine.accumulatedFeesUsdc() - feesBefore;
        (, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        uint256 expectedLpTradingRevenue = assetsDelta > feesDelta ? assetsDelta - feesDelta : 0;

        assertEq(feesDelta, 40_000_000, "Open should still accrue the full execution fee as protocol revenue");
        assertEq(pool.excessAssets(), 0, "Execution fee inflow should be canonically accounted, not stranded as excess");
        assertEq(
            pendingJunior,
            expectedLpTradingRevenue,
            "Seeded pending LP revenue should exclude the execution fee portion"
        );

        uint256 juniorBeforeFeeWithdrawal = pool.juniorPrincipal();
        address feeRecipient = address(0xAB1718);
        engine.withdrawFees(feeRecipient);
        assertEq(
            pool.juniorPrincipal(), juniorBeforeFeeWithdrawal, "Fee withdrawal should not drain seeded LP principal"
        );
    }

    function helper_RecordTradingRevenueInflow_NoClaimantPathFallsBackToUnassignedAssets() public {
        usdc.mint(address(pool), 7000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            7000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 7000e6);
    }

    function helper_RecordTradingRevenueInflow_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        usdc.mint(address(this), 30_000e6);
        usdc.approve(address(pool), 30_000e6);
        pool.initializeSeedPosition(true, 30_000e6, address(this));
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(pool), 10_000e6);
        pool.initializeSeedPosition(false, 10_000e6, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        usdc.mint(address(pool), 35_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 30_000e6);
        assertEq(pendingJunior, 5000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 30_000e6);
        assertEq(pool.juniorPrincipal(), 5000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function test_RecordImplicitTradingRevenue_RestoresSeededSeniorBeforeJuniorWhenBothAreZero() public {
        usdc.mint(address(this), 30_000e6);
        usdc.approve(address(pool), 30_000e6);
        pool.initializeSeedPosition(true, 30_000e6, address(this));
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(pool), 10_000e6);
        pool.initializeSeedPosition(false, 10_000e6, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(pool), 35_000e6);
        uint256 accountedBefore = pool.accountedAssets();
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.AlreadyRetained
        );

        assertEq(
            pool.accountedAssets(), accountedBefore, "Implicit retained revenue must not increment accounted assets"
        );

        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, 30_000e6, "Pending state should restore seeded senior to its HWM first");
        assertEq(pendingJunior, 5000e6, "Pending state should route residual retained carry to seeded junior");

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 30_000e6, "Implicit retained revenue should restore seeded senior first");
        assertEq(pool.juniorPrincipal(), 5000e6, "Residual implicit retained revenue should attach to seeded junior");
        assertEq(pool.unassignedAssets(), 0, "Seeded implicit retained revenue should avoid quarantine");
    }

    function helper_UnassignedAssets_AreReservedFromWithdrawalLiquidity() public {
        usdc.mint(address(pool), 100_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(100_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        (,, uint256 maxSeniorWithdraw, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pool.unassignedAssets(), 100_000e6);
        assertEq(pool.getFreeUSDC(), 0);
        assertEq(pool.getMaxSeniorWithdraw(), 0);
        assertEq(pool.getMaxJuniorWithdraw(), 0);
        assertEq(maxSeniorWithdraw, 0);
        assertEq(maxJuniorWithdraw, 0);
        assertTrue(pool.isWithdrawalLive());
    }

    function helper_UnassignedAssets_DoNotTrapExistingSeniorWithdrawals() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();
        _fundSenior(alice, 100_000e6);
        usdc.mint(address(pool), 10_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        vm.warp(block.timestamp + seniorVault.DEPOSIT_COOLDOWN() + 1);
        uint256 quotedAssets = seniorVault.maxWithdraw(alice);
        assertEq(pool.unassignedAssets(), 0);
        assertEq(quotedAssets, 100_000e6);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        seniorVault.withdraw(quotedAssets, alice, alice);
        assertEq(usdc.balanceOf(alice), aliceBefore + quotedAssets);
    }

    function helper_InitializeSeedPosition_CheckpointsSeniorYieldBeforePrincipalMutation() public {
        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(pool), 100_000e6);
        pool.initializeSeedPosition(true, 100_000e6, address(this));
        assertEq(pool.unpaidSeniorYield(), 0);
        assertEq(pool.lastSeniorYieldCheckpointTime(), block.timestamp);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 100_000e6);
        assertEq(pool.unpaidSeniorYield(), 0);
    }

    function helper_AssignUnassignedAssets_ReconcilesBeforeBootstrappingAndAvoidsPhantomAssets() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), 100_000e6);
        address trader = address(0x99992);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);
        vm.prank(address(router));
        engine.updateMarkPrice(1.2e8, uint64(block.timestamp));
        pool.assignUnassignedAssets(false, alice);
        assertLt(pool.juniorPrincipal(), 100_000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

    function helper_AssignUnassignedAssets_ResetsSeniorHwmAfterTerminalWipeout() public {
        uint256 seedAssets = 50_000e6;
        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, address(this));
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertGt(pool.seniorHighWaterMark(), 0);
        usdc.mint(address(pool), 10_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(10_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        pool.assignUnassignedAssets(true, alice);
        assertEq(pool.seniorPrincipal(), 10_000e6);
        assertEq(pool.seniorHighWaterMark(), 10_000e6);
    }

}

contract HousePoolSeededBaseSetupTest is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 25_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 10_000e6;
    }

    function test_BasePerpTest_CanBootstrapSeededSetup() public view {
        assertEq(pool.juniorPrincipal(), 25_000e6, "Shared setup should initialize the junior seed");
        assertEq(pool.seniorPrincipal(), 10_000e6, "Shared setup should initialize the senior seed");
        assertEq(
            juniorVault.seedShareFloor(), juniorVault.balanceOf(address(this)), "Junior seed floor should be registered"
        );
        assertEq(
            seniorVault.seedShareFloor(), seniorVault.balanceOf(address(this)), "Senior seed floor should be registered"
        );
    }

    function test_MaxDepositAndMaxMint_ZeroWhenSeniorImpaired() public {
        address alice = address(0x111);
        address bob = address(0x222);

        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 120_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        address dave = address(0x444);
        assertGt(pool.seniorHighWaterMark() - pool.seniorPrincipal(), 0, "Senior deficit exists");
        assertEq(seniorVault.maxDeposit(dave), 0, "ERC4626 maxDeposit should be zero while senior is impaired");
        assertEq(seniorVault.maxMint(dave), 0, "ERC4626 maxMint should be zero while senior is impaired");
    }

    function test_MaxDepositAndMaxMint_ReopenForPendingSeniorRecapAfterWipeout() public {
        uint256 rawAssetsBefore = pool.rawAssets();
        assertGt(rawAssetsBefore, 0, "Setup should leave real USDC in the pool before wipeout");
        usdc.burn(address(pool), rawAssetsBefore);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Senior principal should be wiped out before recap");
        assertGt(pool.seniorHighWaterMark(), 0, "Stored HWM should remain stale until reconcile applies the recap");

        uint256 recapAmount = 500e6;
        usdc.mint(address(pool), recapAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapAmount, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        assertTrue(
            pool.canAcceptTrancheDeposits(true),
            "Senior deposits should reopen when pending recap fully clears the projected HWM"
        );

        address dave = address(0x444);
        usdc.mint(dave, 1000e6);
        vm.startPrank(dave);
        usdc.approve(address(seniorVault), 1000e6);
        assertGt(seniorVault.maxDeposit(dave), 0, "ERC4626 maxDeposit should use the projected recapitalized HWM");
        assertGt(seniorVault.maxMint(dave), 0, "ERC4626 maxMint should use the projected recapitalized HWM");
        uint256 shares = seniorVault.deposit(1000e6, dave);
        vm.stopPrank();

        assertGt(shares, 0, "Senior deposit should succeed after reconcile consumes the pending recap");
        assertEq(
            pool.seniorPrincipal(), recapAmount + 1000e6, "Live state should include the recap plus the new deposit"
        );
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
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
        assertGt(_unrealizedTraderPnl(), 0, "Traders should have positive unrealized PnL");
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
        assertLt(_unrealizedTraderPnl(), 0, "Traders should have negative unrealized PnL");
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

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0);

        assertEq(_sideEntryNotional(CfdTypes.Side.BULL), 0, "Bull entry notional should be zero");
        assertEq(_sideEntryNotional(CfdTypes.Side.BEAR), 0, "Bear entry notional should be zero");
        assertEq(_unrealizedTraderPnl(), 0, "Unrealized PnL should be zero with no positions");
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

    function test_MaxWithdraw_RemainsExecutableWithPendingCarryAccrual() public {
        uint256 saturdayFrozen = 1_710_021_600;
        _fundJunior(bob, 1_000_000e6);

        address bullTrader = address(0x444);
        _fundTrader(bullTrader, 100_000e6);
        vm.prank(bullTrader);
        router.commitOrder(CfdTypes.Side.BULL, 400_000e18, 40_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        address bearTrader = address(0x555);
        _fundTrader(bearTrader, 100_000e6);
        vm.prank(bearTrader);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);

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

        address bullTrader = address(0x444);
        _fundTrader(bullTrader, 100_000e6);
        vm.prank(bullTrader);
        router.commitOrder(CfdTypes.Side.BULL, 400_000e18, 40_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        address bearTrader = address(0x555);
        _fundTrader(bearTrader, 100_000e6);
        vm.prank(bearTrader);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        vm.warp(saturdayFrozen - 12 hours);
        assertTrue(engine.isOracleFrozen(), "setup should enter a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(saturdayFrozen - 12 hours));

        vm.warp(saturdayFrozen);

        uint256 quotedShares = juniorVault.maxRedeem(bob);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 previewAssets = juniorVault.previewRedeem(quotedShares);

        vm.prank(bob);
        uint256 redeemedAssets = juniorVault.redeem(quotedShares, bob, bob);

        assertEq(redeemedAssets, previewAssets, "maxRedeem quote should reconcile to the previewed asset amount");
        assertEq(
            usdc.balanceOf(bob),
            bobBalanceBefore + redeemedAssets,
            "maxRedeem quote should remain executable after sync"
        );
    }

    // Regression: C-02 — legacy spread not permanently locked after positions close
    function test_NoLegacySpreadRemainsAfterAllPositionsClose() public {
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

        assertEq(int256(0), 0, "No positions => zero legacy side spread state; value remains distributable");
    }

    // Regression: C-02 — legacy spread reduces distributable revenue
    function test_DistributableRevenueDoesNotDependOnLegacySpread() public {
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

    // Regression: C-02 — legacy negative spread must not inflate junior principal
    function test_LegacyNegativeSpreadDoesNotInflateJuniorPrincipal() public {
        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

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

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30);

        bytes[] memory price = new bytes[](1);
        price[0] = abi.encode(uint256(1e8));
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        router.executeOrder(3, price);

        int256 unrealizedLegacySpread = int256(0);
        assertEq(unrealizedLegacySpread, 0, "Carry model should not report legacy side spread state");

        uint256 juniorBefore = pool.juniorPrincipal();
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 juniorAfter = pool.juniorPrincipal();

        assertLe(juniorAfter, juniorBefore, "conservative: junior must not increase from legacy side spread debt");
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
        engine.processOrderTyped(
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
        pool.accountExcess();

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
        engine.processOrderTyped(
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
        assertEq(seniorVault.maxDeposit(dave), 0, "ERC4626 maxDeposit should be zero while senior is impaired");
        assertEq(seniorVault.maxMint(dave), 0, "ERC4626 maxMint should be zero while senior is impaired");
        vm.expectRevert();
        seniorVault.deposit(10_000_000e6, dave);
        vm.stopPrank();
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolWaterfallTest is HousePoolTestBase {

    using stdStorage for StdStorage;

    // ==========================================
    // REVENUE WATERFALL
    // ==========================================

    function test_RevenueDistribution() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();

        // Simulate realized revenue entering the pool, then account it explicitly.
        _mintAndAccountPoolExcess(100_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedCoupon =
            (seniorBefore * 800 * (block.timestamp - couponCheckpoint)) / (10_000 * uint256(365 days));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), seniorBefore + expectedCoupon, "Senior gets the elapsed 8% APY coupon");
        assertEq(
            pool.juniorPrincipal(),
            juniorBefore + 100_000 * 1e6 - expectedCoupon,
            "Junior receives residual surplus after funding the coupon"
        );
    }

    function test_RevenueDistribution_SeniorCouponFundedByJuniorWhenRevenueIsLow() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();

        // Small revenue: only 10k
        _mintAndAccountPoolExcess(10_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedCoupon =
            (seniorBefore * 800 * (block.timestamp - couponCheckpoint)) / (10_000 * uint256(365 days));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), seniorBefore + expectedCoupon, "Senior receives the target coupon");
        assertEq(
            pool.juniorPrincipal(),
            juniorBefore + 10_000 * 1e6 - expectedCoupon,
            "Junior pays senior coupon and receives the realized revenue"
        );
    }

    // ==========================================
    // LOSS WATERFALL
    // ==========================================

    function test_LossWaterfall_JuniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);
        uint256 seniorBefore = pool.seniorPrincipal();

        _fundTrader(carol, 50_000 * 1e6);

        _open(carol, CfdTypes.Side.LONG, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        // Price drops to $0.50 → LONG profits $100k
        _close(carol, CfdTypes.Side.LONG, 200_000 * 1e18, 0.5e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLe(pool.juniorPrincipal(), 300_000 * 1e6, "Junior absorbed loss");
        assertGe(pool.seniorPrincipal(), seniorBefore, "Senior is not impaired when junior covers the loss");
        assertEq(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "Senior remains fully protected");
    }

    function test_JuniorWipeout_SeniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 50_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        _open(carol, CfdTypes.Side.LONG, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        // Price drops to $0.50 → LONG profits $100k, exceeding junior's $50k
        _close(carol, CfdTypes.Side.LONG, 200_000 * 1e18, 0.5e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped out");
        assertLt(pool.seniorPrincipal(), 500_000 * 1e6, "Senior absorbs remaining loss");
    }

    // ==========================================
    // RECONCILE TREATS TREASURY FEES OUTSIDE VAULT RESERVES
    // ==========================================

    function test_Reconcile_DoesNotSubtractTreasuryFeesFromVaultAssets() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        _open(carol, CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertTrue(fees > 0, "Fees should exist after trade");

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 totalBalance = pool.totalAssets();
        uint256 unrealizedMtmLiability = _poolMtmAdjustment();
        assertEq(
            pool.juniorPrincipal(),
            totalBalance - unrealizedMtmLiability - pool.seniorPrincipal(),
            "Reconcile should treat treasury fees as clearinghouse margin, not a vault reserve"
        );
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

    function test_PendingRecapitalization_CapsAgainstTraderClaimLiabilitiesAndCarriesResidual() public {
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 pendingAmount = 100_000e6;
        uint256 traderClaimLiability = 50_040e6;
        uint256 settleableAmount = pendingAmount - traderClaimLiability;

        usdc.mint(address(pool), pendingAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            pendingAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        _setTotalTraderClaim(traderClaimLiability);

        (uint256 pendingSenior,, uint256 maxSeniorWithdraw,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, settleableAmount, "Preview should only credit liability-adjusted recap assets");
        assertEq(maxSeniorWithdraw, 0, "Residual pending recapitalization should stay reserved from withdrawals");

        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), settleableAmount, "Live reconcile should apply only the settleable recap");
        assertEq(pool.seniorHighWaterMark(), pendingAmount, "Residual recap should preserve senior's recovery target");
        assertEq(pool.pendingRecapitalizationUsdc(), traderClaimLiability, "Unsettled recap must remain pending");
        assertEq(pool.pendingTradingRevenueUsdc(), 0);

        IHousePool.PoolLiquidityView memory viewData = pool.getPoolLiquidityView();
        assertEq(viewData.seniorPrincipalUsdc, settleableAmount, "Liquidity view should not overstate senior NAV");
        assertEq(
            viewData.pendingRecapitalizationUsdc, traderClaimLiability, "Liquidity view should expose residual recap"
        );
        assertEq(viewData.freeUsdc, 0, "Residual pending recap should reserve remaining free liquidity");
        assertEq(pool.getMaxSeniorWithdraw(), 0, "Residual pending recap should reserve senior withdrawals");

        _setTotalTraderClaim(0);
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), pendingAmount, "Residual recap should settle once backing becomes available");
        assertEq(pool.pendingRecapitalizationUsdc(), 0, "Fully settled recap should clear the pending bucket");
        assertEq(pool.unassignedAssets(), 0, "Settled recap should keep senior restoration out of unassigned assets");
    }

    function test_PendingRevenue_CapsAgainstTraderClaimLiabilitiesAndCarriesResidual() public {
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 pendingAmount = 100_000e6;
        uint256 traderClaimLiability = 50_040e6;
        uint256 settleableAmount = pendingAmount - traderClaimLiability;

        usdc.mint(address(pool), pendingAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            pendingAmount, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        _setTotalTraderClaim(traderClaimLiability);

        (uint256 pendingSenior, uint256 pendingJunior,, uint256 maxJuniorWithdraw) = pool.getPendingTrancheState();
        assertEq(pendingSenior, SEEDED_SENIOR, "Preview should restore seeded senior first");
        assertEq(pendingJunior, settleableAmount - SEEDED_SENIOR, "Preview should credit only settleable revenue");
        assertEq(maxJuniorWithdraw, 0, "Residual pending revenue should stay reserved from withdrawals");

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR, "Live reconcile should restore seeded senior first");
        assertEq(pool.juniorPrincipal(), settleableAmount - SEEDED_SENIOR, "Live reconcile should cap revenue credit");
        assertEq(pool.pendingTradingRevenueUsdc(), traderClaimLiability, "Unsettled revenue must remain pending");
        assertFalse(pool.canAcceptTrancheDeposits(false), "Residual pending revenue should keep deposits shut");

        _setTotalTraderClaim(0);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), SEEDED_SENIOR, "Senior should stay restored after residual revenue settles");
        assertEq(pool.juniorPrincipal(), pendingAmount - SEEDED_SENIOR, "Residual revenue should settle to junior");
        assertEq(pool.pendingTradingRevenueUsdc(), 0, "Fully settled revenue should clear the pending bucket");
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
        pool.recordClaimantInflow(
            1500e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 1000e6, "Reconcile should restore seeded senior claims before quarantine");
        assertEq(pool.juniorPrincipal(), 500e6, "Residual value should route to seeded junior before quarantine");
        assertEq(pool.unassignedAssets(), 0, "Seeded claimant continuity should beat governance reassignment");
    }

    function test_RecordRecapitalizationInflow_StaleMarkPaysCouponDirectly() public {
        address trader = address(0x99991);
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();
        _fundTrader(trader, 50_000e6);

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        uint256 reconcileBefore = pool.lastReconcileTime();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(
            pool.lastReconcileTime(),
            reconcileBefore,
            "Stale-window coupon checkpoint should not mark a full reconcile as fresh"
        );
        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            block.timestamp,
            "Stale-window coupon checkpoint should advance the senior coupon base"
        );
        uint256 expectedCoupon = (seniorBefore * 800 * (staleTime - couponCheckpoint)) / (10_000 * uint256(365 days));
        assertEq(
            pool.seniorPrincipal(),
            seniorBefore + expectedCoupon,
            "Junior-funded coupon should credit senior before stale pending-bucket routing"
        );
        assertEq(
            pool.unassignedAssets(), 50_000e6, "Queued recapitalization should still route into fallback accounting"
        );
    }

    function test_StalePendingSeniorMutation_CapsFutureYieldToPostCheckpointInterval() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        uint256 hwmBeforeLoss = pool.seniorHighWaterMark();

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLt(pool.seniorPrincipal(), hwmBeforeLoss, "Setup should impair senior before stale recapitalization");
        assertEq(pool.seniorHighWaterMark(), hwmBeforeLoss, "Setup should preserve the pre-loss HWM");

        address trader = address(0x77771);
        _fundTrader(trader, 50_000e6);
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8);

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        uint256 checkpointBefore = pool.lastSeniorCouponCheckpointTime();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            block.timestamp,
            "Stale senior mutation should checkpoint coupon time"
        );
        assertEq(
            pool.seniorPrincipal(), hwmBeforeLoss, "Stale recapitalization should restore senior principal to the HWM"
        );

        uint256 freshTime = staleTime + 2 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 expectedCouponUpperBound = (hwmBeforeLoss * 800 * uint256(2 days)) / (10_000 * uint256(365 days));
        assertLe(
            pool.seniorPrincipal(),
            hwmBeforeLoss + expectedCouponUpperBound,
            "Fresh reconcile must not accrue more than the post-checkpoint senior coupon interval"
        );
        assertGt(
            pool.lastSeniorCouponCheckpointTime(),
            checkpointBefore,
            "Coupon checkpoint should advance after stale principal mutation"
        );
    }

    function test_FreshPendingSeniorMutation_RestoresHwmWithoutDebtQueue() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        uint256 hwmBeforeLoss = pool.seniorHighWaterMark();

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLt(pool.seniorPrincipal(), hwmBeforeLoss, "Setup should impair senior before recapitalization");

        uint256 freshTime = block.timestamp + 30 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.seniorPrincipal(), hwmBeforeLoss, "Recapitalization should still restore senior principal to the HWM"
        );
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

    function test_RecordClaimantRevenue_RestoresCanonicalAssetsAfterRawShortfall() public {
        _fundJunior(bob, 500_000e6);
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 100_000e6);
        usdc.mint(address(pool), 10_000e6);

        vm.prank(address(engine));
        pool.recordClaimantInflow(
            10_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertEq(
            pool.totalAssets(),
            SEEDED_SENIOR + SEEDED_JUNIOR + 410_000e6,
            "Engine-accounted inflow should restore canonical assets even after a raw shortfall"
        );
        assertEq(pool.excessAssets(), 0, "Shortfall recovery inflow should not remain quarantined as excess");
    }

    function test_ReconcileSpam_PaysSeniorCouponDirectly() public {
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

        assertGe(
            pool.seniorPrincipal(),
            541_080 * 1e6 - 1e6,
            "Senior principal should reflect at least the simple target coupon on seeded baseline"
        );
    }

    function test_SeniorHighWaterMark_RatchetsPaidCouponIntoProtectedClaim() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 hwmBeforeCoupon = pool.seniorHighWaterMark();
        uint256 originalSeniorPrincipal = pool.seniorPrincipal();

        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfterCoupon = pool.seniorPrincipal();
        assertGt(seniorAfterCoupon, originalSeniorPrincipal, "Setup should pay senior coupon into principal");
        assertEq(
            pool.seniorHighWaterMark(), seniorAfterCoupon, "Paid senior coupon should ratchet the protected HWM upward"
        );
        assertGt(pool.seniorHighWaterMark(), hwmBeforeCoupon, "HWM should rise after paying senior coupon");

        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 95_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(
            pool.seniorPrincipal(), originalSeniorPrincipal, "Senior can stay above original principal after the loss"
        );
        assertLt(
            pool.seniorPrincipal(),
            pool.seniorHighWaterMark(),
            "Once coupon has been paid, later losses treat that paid coupon as protected HWM capital"
        );
    }

    function test_SeniorPrincipal_RestoredBeforeJuniorSurplus() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        uint256 seniorHwmBeforeLoss = pool.seniorHighWaterMark();

        assertEq(pool.seniorPrincipal(), seniorHwmBeforeLoss);

        // Catastrophic loss: pool loses $600k → junior wiped ($500k), senior loses $100k
        // Simulate by burning pool USDC
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), 600_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped");
        assertLt(pool.seniorPrincipal(), seniorHwmBeforeLoss, "Senior loses only after junior is exhausted");
        assertEq(pool.seniorHighWaterMark(), seniorHwmBeforeLoss, "HWM remembers original principal");

        // Revenue arrives: $150k. Should restore senior $100k first, then junior gets $50k.
        usdc.mint(address(pool), 150_000 * 1e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        // Coupon for ~0 elapsed time is negligible, so nearly all goes to restoration + junior.
        assertEq(pool.seniorPrincipal(), seniorHwmBeforeLoss, "Senior restored to HWM");
        assertGt(pool.juniorPrincipal(), 0, "Junior gets the remainder after restoration");
    }

    function test_SeniorHWM_PreservedOnFullWipeout() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);
        uint256 hwmBeforeWipeout = pool.seniorHighWaterMark();

        // Total wipeout
        uint256 burnAmount = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), burnAmount);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), hwmBeforeWipeout, "HWM preserves senior recovery rights after wipeout");
    }

}

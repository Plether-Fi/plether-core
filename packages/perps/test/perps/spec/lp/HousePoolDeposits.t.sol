// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolDepositsTest is HousePoolTestBase {

    using stdStorage for StdStorage;

    function test_MaxDeposit_ZeroWhileOracleFrozen() public {
        assertTrue(pool.canAcceptTrancheDeposits(false), "setup should permit live junior entry");

        _enterFrozenWindow();

        assertFalse(pool.canAcceptTrancheDeposits(false), "frozen-oracle entry must fail closed");
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "frozen-oracle request capacity must be zero");
    }

    function test_CurrentTerminalDeficitBlocksEntryBeforeStoredCheckpointUpdates() public {
        uint256 deficit = 123e6;
        _setTotalTraderClaim(pool.totalAssets() + deficit);

        assertEq(pool.terminalDeficitUsdc(), 0, "stored deficit should remain the prior reconciled checkpoint");
        assertEq(
            pool.getPoolLiquidityView().currentTerminalDeficitUsdc,
            deficit,
            "current view must derive the live terminal deficit"
        );
        assertFalse(pool.canAcceptTrancheDeposits(false), "live terminal deficit must block junior entry");
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "deficit must zero request capacity");

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.terminalDeficitUsdc(), deficit, "fresh reconcile must persist the explicit deficit");
    }

    function test_DegradedModeBlocksNewEntryAndQueuedActivation() public {
        assertTrue(pool.canAcceptTrancheDeposits(false), "setup should permit live junior entry");

        uint256 depositAssets = 10_000e6;
        uint256 requestId = _requestAsyncDeposit(juniorVault, carol, depositAssets);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);

        assertFalse(pool.canAcceptTrancheDeposits(false), "degraded mode must close the request gate");
        assertEq(juniorVault.maxRequestDeposit(carol), 0, "degraded mode must expose zero request capacity");

        vm.warp(pool.lpEpochStart(requestId));
        vm.expectRevert(IHousePool.HousePool__DegradedMode.selector);
        pool.settleLpEpoch(0, 0);

        (uint256 epochAssets, uint256 epochShares,,, bool finalized) = juniorVault.depositEpochs(requestId);
        assertEq(epochAssets, depositAssets, "blocked activation must preserve the deposit escrow");
        assertEq(epochShares, 0, "blocked activation must not mint shares");
        assertFalse(finalized, "blocked activation must leave the epoch pending");
    }

    function test_PreWipeQueuedJuniorDeposit_DefersAtZeroNavAndRemainsCancellable() public {
        _fundJunior(bob, 100_000e6);
        _finishAsyncCooldown(juniorVault, bob);

        uint256 depositAssets = 10_000e6;
        uint256 depositRequestId = _requestAsyncDeposit(juniorVault, carol, depositAssets);
        uint256 redeemRequestId = _requestAsyncRedeem(juniorVault, bob, juniorVault.balanceOf(bob) / 10);
        assertEq(redeemRequestId, depositRequestId, "simultaneous entry and exit must share one request epoch");

        usdc.burn(address(pool), pool.juniorPrincipal());
        vm.warp(pool.lpEpochStart(depositRequestId));

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        assertEq(pool.juniorPrincipal(), 0, "settlement reconcile should recognize the Junior wipe");
        assertTrue(result.entriesDeferred, "zero-NAV Junior entry must remain deferred");
        assertEq(result.juniorDepositAssets, 0, "deferred entry must not move escrowed assets into the pool");
        assertEq(result.juniorDepositShares, 0, "deferred entry must not mint restart shares");
        assertFalse(pool.canAcceptTrancheDeposits(false), "wiped Junior must remain closed to fresh entry");

        (uint256 epochAssets, uint256 epochShares,,, bool finalized) = juniorVault.depositEpochs(depositRequestId);
        assertEq(epochAssets, depositAssets, "queued deposit assets must remain intact");
        assertEq(epochShares, 0, "deferred epoch must not receive shares");
        assertFalse(finalized, "zero-NAV epoch must not finalize");

        vm.prank(carol);
        uint256 refundedAssets = juniorVault.cancelPendingDeposit(depositRequestId, carol, carol);
        assertEq(refundedAssets, depositAssets, "wiped-tranche depositor must recover full escrow");
        assertEq(usdc.balanceOf(carol), depositAssets, "cancelled assets must return to the depositor");
    }

    // ==========================================
    // DEPOSIT & PRINCIPAL TRACKING
    // ==========================================

    function test_SeniorJuniorDeposit() public {
        uint256 totalBefore = pool.totalAssets();
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        assertEq(pool.totalAssets(), totalBefore + 800_000 * 1e6);
        assertEq(seniorVault.totalAssets(), pool.seniorPrincipal());
        assertEq(juniorVault.totalAssets(), pool.juniorPrincipal());
        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), pool.totalAssets());
    }

    function test_SeniorEstimateDeposit_MatchesSettlementPrice() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        _mintAndAccountPoolExcess(100_000 * 1e6);

        vm.warp(block.timestamp + 365 days);

        address dave = address(0x4444);
        uint256 assets = 100_000 * 1e6;
        uint256 requestId = _requestAsyncDeposit(seniorVault, dave, assets);
        uint256 maturity = pool.lpEpochStart(requestId);
        vm.warp(maturity);
        _refreshMarkForAsyncSettlement();

        uint256 estimatedShares = seniorVault.estimateDepositShares(assets);
        _settleLpEpochForTest();
        uint256 mintedShares = _claimAsyncDeposit(seniorVault, requestId, dave);

        assertEq(mintedShares, estimatedShares, "execution-time estimate should match settled deposit shares");
    }

    // ==========================================
    // FULL INTEGRATION
    // ==========================================

    function test_FullIntegration() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();

        _fundTrader(carol, 50_000 * 1e6);

        // Trader opens LONG $100k at $1.00
        _open(carol, CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        // Price drops to $0.80 → LONG profits $20k (paid from pool)
        _close(carol, CfdTypes.Side.LONG, 100_000 * 1e18, 0.8e8);

        uint256 staleTime = block.timestamp + 30 days;
        vm.warp(staleTime);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool paid out ~$20k profit to trader. Junior absorbs first.
        assertLt(pool.juniorPrincipal(), 500_000 * 1e6, "Junior absorbed trader profit payout");
        uint256 expectedCoupon = (seniorBefore * 800 * (staleTime - couponCheckpoint)) / (10_000 * uint256(365 days));
        assertEq(
            pool.seniorPrincipal(),
            seniorBefore + expectedCoupon,
            "Senior receives junior-funded coupon before junior absorbs residual loss"
        );
    }

    function test_UnaccountedDonation_IgnoredUntilExplicitlyAccounted() public {
        _fundJunior(bob, 500_000e6);

        uint256 accountedBefore = pool.totalAssets();
        usdc.mint(address(pool), 100_000e6);

        IHousePool.PoolLiquidityView memory beforeAccount = pool.getPoolLiquidityView();
        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw balance should include unsolicited donation");
        assertEq(pool.excessAssets(), 100_000e6, "Donation should remain quarantined as excess");
        assertEq(pool.totalAssets(), accountedBefore, "Canonical assets must ignore raw donation until accounted");
        assertEq(beforeAccount.totalAssetsUsdc, accountedBefore, "Liquidity view must use canonical assets");

        pool.accountExcess();

        IHousePool.PoolLiquidityView memory afterAccount = pool.getPoolLiquidityView();
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

    function test_AssignUnassignedAssets_RevertsWhenOracleFrozen() public {
        usdc.mint(address(pool), 100_000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();

        _enterFrozenWindow();

        vm.expectRevert(IHousePool.HousePool__OracleFrozen.selector);
        pool.assignUnassignedAssets(false, alice);
    }

    function test_InitializeSeedPosition_RevertsWhenSeedAlreadyInitializedEvenIfOracleFrozen() public {
        uint256 seedAssets = 50_000e6;

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);

        _enterFrozenWindow();

        vm.expectRevert(IHousePool.HousePool__SeedAlreadyInitialized.selector);
        pool.initializeSeedPosition(true, seedAssets, address(this));
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

    function test_GetPoolLiquidityView_ReturnsCurrentPoolState() public {
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 300_000e6);
        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        usdc.mint(address(pool), 20_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            20_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        IHousePool.PoolLiquidityView memory viewData = pool.getPoolLiquidityView();
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
        assertEq(viewData.seniorHighWaterMarkUsdc, pool.seniorHighWaterMark());
        assertEq(viewData.oracleFrozen, engine.isOracleFrozen());
        assertEq(viewData.degradedMode, engine.degradedMode());
    }

    function test_JitLP_BlockedByCooldown() public {
        _fundJunior(bob, 500_000 * 1e6);

        _fundJunior(carol, 500_000 * 1e6);

        _mintAndAccountPoolExcess(50_000 * 1e6);

        uint256 carolShares = juniorVault.balanceOf(carol);
        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(carol);
        juniorVault.requestRedeem(carolShares, carol, carol);
    }

    function test_DustDepositToExistingHolderDoesNotResetCooldown() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 50 minutes);

        // A third party may request with its own funds, but cannot claim shares into an existing holder.
        address attacker = address(0xBAD);
        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        uint256 requestId = _requestAsyncDeposit(juniorVault, attacker, minimumDeposit);
        _settleAsyncRequest(requestId, true);
        vm.prank(attacker);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, minimumDeposit, alice, attacker);

        vm.warp(block.timestamp + 11 minutes);
        uint256 redeemId = _requestAsyncRedeem(juniorVault, alice, juniorVault.maxRequestRedeem(alice));
        _settleAsyncRequest(redeemId, true);
        uint256 withdrawable = juniorVault.maxWithdraw(alice);
        vm.prank(alice);
        juniorVault.withdraw(withdrawable, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawable, "Victim withdraw should succeed after original cooldown");
    }

    function test_MinDeposit_BlocksDustBeforeCouponCheckpoint() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);
        uint256 checkpointBefore = pool.lastSeniorCouponCheckpointTime();

        vm.warp(block.timestamp + 1 days);

        address dave = address(0x444);
        usdc.mint(dave, pool.minTrancheDepositUsdc());
        vm.startPrank(dave);
        usdc.approve(address(seniorVault), pool.minTrancheDepositUsdc());
        vm.expectRevert(TrancheVault.TrancheVault__DepositTooSmall.selector);
        seniorVault.requestDeposit(1, dave, dave);
        vm.stopPrank();

        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            checkpointBefore,
            "Dust deposits must fail before forcing coupon checkpointing"
        );
    }

    function test_MeaningfulThirdPartyTopUpToExistingHolderReverts() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 50 minutes);

        address helper = address(0xB0B);
        usdc.mint(helper, 10_000e6);
        uint256 requestId = _requestAsyncDeposit(juniorVault, helper, 10_000e6);
        _settleAsyncRequest(requestId, true);
        vm.prank(helper);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.claimDeposit(requestId, 10_000e6, alice, helper);

        vm.warp(block.timestamp + 11 minutes);
        uint256 redeemId = _requestAsyncRedeem(juniorVault, alice, juniorVault.maxRequestRedeem(alice));
        _settleAsyncRequest(redeemId, true);
        uint256 withdrawable = juniorVault.maxWithdraw(alice);
        vm.prank(alice);
        juniorVault.withdraw(withdrawable, alice, alice);
    }

    function test_DepositCooldown_BlocksFlashWithdraw() public {
        _fundJunior(alice, 100_000 * 1e6);

        // Alice deposits and tries to withdraw in the same block
        uint256 aliceShares = juniorVault.balanceOf(alice);
        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(alice);
        juniorVault.requestRedeem(aliceShares, alice, alice);

        // After cooldown passes, withdrawal succeeds
        _finishAsyncCooldown(juniorVault, alice);
        (,, uint256 withdrawable) = _redeemAsync(juniorVault, alice, juniorVault.maxRequestRedeem(alice), true);
        assertEq(usdc.balanceOf(alice), withdrawable, "Withdrawal after cooldown succeeds");
    }

}


// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract RecapitalizationIdempotenceTest is HousePoolTestBase {

    function _bookedAssets() private view returns (uint256) {
        return pool.seniorPrincipal() + pool.juniorPrincipal() + pool.unassignedAssets();
    }

    function _recordInflow(
        IHousePool.ClaimantInflowKind kind,
        uint256 amount
    ) private {
        settlementToken.mint(address(pool), amount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(amount, kind, IHousePool.ClaimantInflowCashMode.CashArrived);
    }

    function _reconcile() private {
        vm.prank(address(juniorVault));
        pool.reconcile();
    }

    function _wipePool() private {
        settlementToken.burn(address(pool), pool.rawAssets());
        _reconcile();
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_PartialRecapAndRevenueAreIdempotentAcrossRepeatedReconciles() public {
        _wipePool();
        uint256 survivingHwm = pool.seniorHighWaterMark();

        uint256 recap = 6000e6;
        uint256 revenue = 4800e6;
        uint256 traderClaims = 6000e6;
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, recap);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, revenue);
        _setTotalTraderClaim(traderClaims);

        _reconcile();
        assertEq(pool.seniorPrincipal(), survivingHwm, "recap restores only the surviving Senior HWM");
        assertEq(pool.seniorHighWaterMark(), survivingHwm, "recap must not reset the HWM");
        assertEq(pool.pendingRecapitalizationAssets(), 1200e6, "unsettled recap remains pending");
        assertEq(pool.pendingTradingRevenueAssets(), revenue, "revenue remains in its separate bucket");
        assertEq(_bookedAssets(), 4800e6, "first pass books the distributable value once");

        uint256 firstSenior = pool.seniorPrincipal();
        uint256 firstJunior = pool.juniorPrincipal();
        uint256 firstUnassigned = pool.unassignedAssets();
        for (uint256 i; i < 10; ++i) {
            _reconcile();
            assertEq(pool.seniorPrincipal(), firstSenior, "unchanged mark must not repay Senior");
            assertEq(pool.juniorPrincipal(), firstJunior, "unchanged mark must not credit Junior");
            assertEq(pool.seniorHighWaterMark(), survivingHwm, "unchanged mark must not rewrite HWM");
            assertEq(pool.unassignedAssets(), firstUnassigned, "unchanged mark must not consume owner value");
            assertEq(pool.pendingRecapitalizationAssets(), 1200e6, "residual recap must not be consumed twice");
            assertEq(pool.pendingTradingRevenueAssets(), revenue, "residual revenue must not be consumed twice");
        }

        // A later owner receipt creates new unbooked backing; that receipt may be allocated once.
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 2000e6);
        _reconcile();
        assertEq(_bookedAssets(), 6800e6, "new receipt is recognized exactly once");
        uint256 secondPendingRecap = pool.pendingRecapitalizationAssets();
        uint256 secondUnassigned = pool.unassignedAssets();
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), secondPendingRecap, "new residual cannot replay");
        assertEq(pool.unassignedAssets(), secondUnassigned, "new owner receipt cannot be applied twice");
        assertEq(pool.seniorHighWaterMark(), survivingHwm, "later receipt cannot reset HWM");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_ClaimPayoutClearsResidualAlreadyBookedCash() public {
        _wipePool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 6000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 4800e6);
        _setTotalTraderClaim(6000e6);
        _reconcile();

        assertEq(_bookedAssets(), 4800e6, "first reconcile assigns all equity");
        assertEq(pool.pendingRecapitalizationAssets(), 1200e6, "recap residual exists before claim payout");

        vm.prank(address(engine));
        pool.payOutTraderClaim(address(0xCA11), 6000e6);
        _setTotalTraderClaim(0);

        assertEq(pool.totalAssets(), _bookedAssets(), "remaining cash already backs booked owners");
        assertEq(pool.pendingRecapitalizationAssets(), 1200e6, "payout debit waits for a stable canonical snapshot");
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 0, "claim payout removes unbacked recap residual");
        assertEq(pool.pendingTradingRevenueAssets(), 0, "claim payout removes unbacked revenue residual");
        assertEq(_bookedAssets(), pool.totalAssets(), "claim payout cannot be booked a second time");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_TinyPayoutRetiresOnlyItsUnsupportedShare() public {
        _wipePool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 6000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 4800e6);
        _setTotalTraderClaim(6000e6);
        _reconcile();

        vm.prank(address(engine));
        pool.payOutTraderClaim(address(0xCA11), 10e6);
        _setTotalTraderClaim(5990e6);
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 1200e6, "recap keeps priority");
        assertEq(pool.pendingTradingRevenueAssets(), 4790e6, "only the ten-unit payout is retired");
        assertEq(_bookedAssets(), 4800e6, "the payout does not manufacture an LP loss");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_CollectibleReceivableKeepsFreshRecapAfterCashPayout() public {
        settlementToken.burn(address(pool), 500e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 500e6);
        vm.prank(address(engine));
        pool.payOut(address(0xCA11), 1700e6);
        assertEq(pool.totalAssets(), 300e6);
        assertEq(pool.pendingRecapitalizationAssets(), 500e6, "physical cash alone cannot retire the recap");

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            pool.ENGINE_PROTOCOL_LENS().getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.terminalLpPriceDeltaAssets = int256(2000e6);
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolInputSnapshot(uint256)", pool.markStalenessLimit()),
            abi.encode(snapshot)
        );
        (uint256 previewSenior, uint256 previewJunior,,) = pool.getPendingTrancheState();
        assertEq(previewSenior, 1000e6);
        assertEq(previewJunior, 800e6, "receivable backs full fresh owner recap in preview");
        _reconcile();
        assertEq(pool.seniorPrincipal(), previewSenior);
        assertEq(pool.juniorPrincipal(), previewJunior);
        assertEq(pool.unassignedAssets(), 500e6, "full recap remains owner owned");
        assertEq(pool.pendingRecapitalizationAssets(), 0);
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_PayoutDebitWaitsForFreshMarkBeforeRetiringIntent() public {
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 500e6);
        vm.prank(address(engine));
        pool.payOutTraderClaim(address(0xCA11), 2000e6);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            pool.ENGINE_PROTOCOL_LENS().getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.traderClaimBalanceAssets = 500e6;
        snapshot.hasOpenPositions = true;
        snapshot.markFreshnessRequired = true;
        snapshot.maxMarkStaleness = 60;
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolInputSnapshot(uint256)", pool.markStalenessLimit()),
            abi.encode(snapshot)
        );
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status =
            pool.ENGINE_PROTOCOL_LENS().getHousePoolStatusSnapshot();
        status.lastMarkTime = uint64(block.timestamp - 61);
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolStatusSnapshot()"),
            abi.encode(status)
        );

        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 500e6, "stale mark cannot retire payout backing");

        status.lastMarkTime = uint64(block.timestamp + 1);
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolStatusSnapshot()"),
            abi.encode(status)
        );
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 500e6, "future mark cannot retire payout backing");

        status.lastMarkTime = uint64(block.timestamp);
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolStatusSnapshot()"),
            abi.encode(status)
        );
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 0, "fresh canonical snapshot retires unsupported intent");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_FreshRecapSettlesAfterPositiveEquityLoss() public {
        uint256 survivingHwm = pool.seniorHighWaterMark();
        settlementToken.burn(address(pool), 400e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 300e6);

        assertLt(pool.totalAssets(), _bookedAssets(), "the old book still exceeds physical equity");
        _reconcile();
        assertEq(pool.seniorPrincipal(), survivingHwm);
        assertEq(pool.juniorPrincipal(), 600e6, "Junior bears the independent cash loss");
        assertEq(pool.unassignedAssets(), 300e6, "fresh recap is owner owned once");
        assertEq(pool.pendingRecapitalizationAssets(), 0);
        _reconcile();
        assertEq(pool.juniorPrincipal(), 600e6);
        assertEq(pool.unassignedAssets(), 300e6);
        assertEq(pool.seniorHighWaterMark(), survivingHwm);
    }

    /// @dev A fresh owner recap is reserved while the independent cash loss first impairs Senior.
    ///      The recap then restores Senior's 500-unit gap and keeps its unused 500 units owner owned.
    function test_FreshRecapRestoresSeniorAfterUnreconciledLoss() public {
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.juniorPrincipal(), 1000e6);
        assertEq(pool.seniorHighWaterMark(), 1000e6);

        settlementToken.burn(address(pool), 1500e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 1000e6);
        assertEq(pool.totalAssets(), 1500e6);

        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6, "recap restores the impaired Senior principal");
        assertEq(pool.juniorPrincipal(), 0, "Junior absorbs the independent loss first");
        assertEq(pool.seniorHighWaterMark(), 1000e6);
        assertEq(pool.unassignedAssets(), 500e6, "unused owner recap remains owner owned");
        assertEq(pool.pendingRecapitalizationAssets(), 0);

        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 500e6);
    }

    function test_PaidClaimCannotReapplySpentRecapToLaterRevenue() public {
        _wipePool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 4000e6);
        _setTotalTraderClaim(3000e6);
        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.pendingRecapitalizationAssets(), 3000e6);

        vm.prank(address(engine));
        pool.payOutTraderClaim(address(0xCA11), 3000e6);
        _setTotalTraderClaim(0);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 5000e6);
        _reconcile();

        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.juniorPrincipal(), 5000e6, "later revenue belongs to Junior");
        assertEq(pool.unassignedAssets(), 0);
        assertEq(pool.pendingRecapitalizationAssets(), 0);
    }

    function test_OrdinaryPayoutDoesNotRetireClaimBackedRecap() public {
        _wipePool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 10_800e6);
        _setTotalTraderClaim(6000e6);
        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.unassignedAssets(), 3800e6);
        assertEq(pool.pendingRecapitalizationAssets(), 6000e6);

        vm.prank(address(engine));
        pool.payOut(address(0xCA11), 4000e6);
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 6000e6, "ordinary payout cannot retire the claim reserve");

        _setTotalTraderClaim(0);
        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.juniorPrincipal(), 0, "owner recap cannot become Junior revenue");
        assertEq(pool.unassignedAssets(), 5800e6);
        assertEq(pool.pendingRecapitalizationAssets(), 3000e6);
    }

    function test_TemporaryMarkedLossCannotEraseFreshRecapAfterOrdinaryPayout() public {
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 500e6);
        vm.prank(address(engine));
        pool.payOut(address(0xCA11), 1000e6);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            pool.ENGINE_PROTOCOL_LENS().getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.terminalLpPriceDeltaAssets = -int256(1500e6);
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSignature("getHousePoolInputSnapshot(uint256)", pool.markStalenessLimit()),
            abi.encode(snapshot)
        );
        _reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), 500e6, "marked dip cannot retire fresh owner funding");

        vm.clearMockedCalls();
        _reconcile();
        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.juniorPrincipal(), 500e6);
        assertEq(pool.pendingRecapitalizationAssets(), 0);
    }

}

contract RealClaimPayoutRecoveryTest is HousePoolTestBase {

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 10_000e6;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 10_000e6;
    }

    function test_FreshTraderProfitDoesNotRetireOwnerRecap() public {
        address trader = address(0x7114);
        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8);

        settlementToken.mint(address(this), 500e6);
        settlementToken.approve(address(engine), 500e6);
        engine.recapitalizePool(500e6);

        vm.warp(block.timestamp + 1);
        _close(trader, CfdTypes.Side.LONG, 5000e18, 80_000_000);
        assertEq(engine.traderClaimBalanceAssets(trader), 0, "fresh profit was paid without recording a claim");
        _reconcile();
        assertEq(pool.unassignedAssets(), 500e6, "fresh payout cannot spend owner recap intent");
    }

    function test_RealTraderClaimCarryCannotResurrectSpentRecap() public {
        address trader = address(0x7114);
        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8);
        settlementToken.burn(address(pool), pool.rawAssets());
        vm.warp(vm.getBlockTimestamp() + 1);
        _close(trader, CfdTypes.Side.LONG, 5000e18, 80_000_000);
        uint256 claim = engine.traderClaimBalanceAssets(trader);
        assertGt(claim, 0);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(vm.getBlockTimestamp()));
        _reconcile();
        uint256 recap = claim + pool.seniorHighWaterMark();
        settlementToken.mint(address(this), recap);
        settlementToken.approve(address(engine), recap);
        engine.recapitalizePool(recap);
        _reconcile();
        uint256 unassignedBefore = pool.unassignedAssets();
        assertGt(pool.pendingRecapitalizationAssets(), 0);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(vm.getBlockTimestamp()));
        uint256 assetsBefore = pool.totalAssets();
        vm.prank(trader);
        engine.settleTraderClaim(trader);
        uint256 realizedCarry = pool.totalAssets() + claim - assetsBefore;
        assertGt(realizedCarry, 0);

        _reconcile();
        assertEq(pool.unassignedAssets(), unassignedBefore, "spent recap cannot capture realized carry");
        assertEq(pool.juniorPrincipal(), realizedCarry, "carry belongs to Junior after Senior recovery");
    }

    function _reconcile() private {
        vm.prank(address(juniorVault));
        pool.reconcile();
    }

}

contract RecapitalizationWithoutSeniorOwnersTest is HousePoolTestBase {

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_FreshRecapPreservesOwnerPriorityOverJuniorLoss() public {
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 recap = 50e6;
        settlementToken.mint(address(pool), recap);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recap, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(engine));
        pool.payOut(address(0xCA11), 10e6);
        assertEq(pool.pendingRecapitalizationAssets(), recap, "fresh earmarked recap remains backed");

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.juniorPrincipal(), juniorBefore - 10e6, "Junior bears the realized payout");
        assertEq(pool.unassignedAssets(), recap, "owner recap remains unassigned without Senior owners");

        uint256 pendingBefore = pool.pendingRecapitalizationAssets();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.pendingRecapitalizationAssets(), pendingBefore, "repeat reconcile cannot reapply owner funds");
        assertEq(pool.juniorPrincipal(), juniorBefore - 10e6, "repeat reconcile cannot credit Junior");
        assertEq(pool.unassignedAssets(), recap, "repeat reconcile cannot consume owner funds");
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#ownership-routing-for-pool-inflows.
    function test_NoSeniorResidualDoesNotDrainOwnerAllocation() public {
        uint256 recap = 500e6;
        settlementToken.mint(address(pool), recap);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recap, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        _setTotalTraderClaim(1200e6);

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), 300e6, "only distributable recap is owner assigned");
        assertEq(pool.juniorPrincipal(), 0, "claim reserve absorbs prior Junior principal");
        assertEq(pool.pendingRecapitalizationAssets(), 200e6, "unsupported intent remains pending");
        for (uint256 i; i < 10; ++i) {
            vm.prank(address(juniorVault));
            pool.reconcile();
            assertEq(pool.unassignedAssets(), 300e6, "repeat reconcile cannot drain owner allocation");
            assertEq(pool.juniorPrincipal(), 0);
            assertEq(pool.pendingRecapitalizationAssets(), 200e6);
        }
    }

}

contract PartialRecapitalizationRevenueOrderTest is HousePoolTestBase {

    uint256 private constant RECAP_ASSETS = 40_000e6;
    uint256 private constant TRADER_CLAIMS = 30_000e6;
    uint256 private constant PENDING_RECAP = 30_000e6;

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return RECAP_ASSETS;
    }

    function _recordInflow(
        IHousePool.ClaimantInflowKind kind,
        uint256 amount
    ) private {
        settlementToken.mint(address(pool), amount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(amount, kind, IHousePool.ClaimantInflowCashMode.CashArrived);
    }

    function _reconcile() private {
        vm.prank(address(juniorVault));
        pool.reconcile();
    }

    function _wipeSeededPool() private {
        assertEq(pool.seniorHighWaterMark(), RECAP_ASSETS, "Senior has a real 40k pre-wipe recovery target");
        settlementToken.burn(address(pool), pool.rawAssets());
        _reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), RECAP_ASSETS, "Senior recovery target survives the wipe");
        assertGt(seniorVault.totalSupply(), 0);
        assertGt(juniorVault.totalSupply(), 0);
    }

    function _partlySettleRecap() private {
        _wipeSeededPool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, RECAP_ASSETS);
        _setTotalTraderClaim(TRADER_CLAIMS);
        _reconcile();

        assertEq(pool.seniorPrincipal(), 10_000e6, "only 10k of recap is distributable initially");
        assertEq(pool.seniorHighWaterMark(), RECAP_ASSETS, "Senior still has a 30k recovery gap");
        assertEq(pool.pendingRecapitalizationAssets(), PENDING_RECAP, "same 30k remains queued");
        assertEq(pool.unassignedAssets(), 0);
    }

    function _assertFullyOwnedFinalEquity() private view {
        assertEq(pool.totalAssets() - TRADER_CLAIMS, 80_000e6, "both schedules end with 80k LP equity");
        assertEq(pool.seniorPrincipal(), RECAP_ASSETS, "recap restores Senior to its original target");
        assertEq(pool.juniorPrincipal(), 40_000e6, "later revenue above the Senior target belongs to Junior");
        assertEq(pool.unassignedAssets(), 0, "ordinary revenue cannot become ownerless");
        assertEq(pool.pendingRecapitalizationAssets(), 0, "recap remainder is consumed once");
        assertEq(pool.pendingTradingRevenueAssets(), 0);
    }

    /// @dev A partial recap and later revenue must give the same ownership as settling the remainder before
    ///      the rest of the revenue arrives. The first pass has a legitimate pre-existing 40k Senior HWM.
    function test_RevenueBeforePendingRecapSettlementDoesNotBecomeUnassigned() public {
        _partlySettleRecap();

        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 70_000e6);
        assertEq(pool.pendingTradingRevenueAssets(), 0, "positive-principal revenue uses the ordinary waterfall");
        _reconcile();

        _assertFullyOwnedFinalEquity();
    }

    /// @dev Same recap, claims, revenue and final equity; only the reconcile point differs.
    function test_StagedRevenueAfterPendingRecapSettlementHasSameOwnership() public {
        _partlySettleRecap();

        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, PENDING_RECAP);
        _reconcile();
        assertEq(pool.seniorPrincipal(), RECAP_ASSETS);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 0);
        assertEq(pool.pendingRecapitalizationAssets(), 0);

        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 40_000e6);
        _reconcile();

        _assertFullyOwnedFinalEquity();
    }

    /// @dev Both claimant buckets are partly unsettled on the first pass. Clearing trader claims and
    ///      earning ordinary revenue before the next reconcile must not divert that revenue to unassigned.
    function test_MixedPendingBucketsAndLaterRevenueRemainOwnedByJunior() public {
        _wipeSeededPool();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, RECAP_ASSETS);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        _setTotalTraderClaim(TRADER_CLAIMS);
        _reconcile();

        assertEq(pool.seniorPrincipal(), 25_000e6);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), RECAP_ASSETS);
        assertEq(pool.pendingRecapitalizationAssets(), 15_000e6);
        assertEq(pool.pendingTradingRevenueAssets(), 15_000e6);
        assertEq(pool.unassignedAssets(), 0);

        _setTotalTraderClaim(0);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        assertEq(pool.pendingTradingRevenueAssets(), 15_000e6, "later revenue is ordinary waterfall revenue");
        _reconcile();

        assertEq(pool.totalAssets(), 70_000e6);
        assertEq(pool.seniorPrincipal(), RECAP_ASSETS);
        assertEq(pool.juniorPrincipal(), 30_000e6, "both queued and later revenue belong to Junior");
        assertEq(pool.unassignedAssets(), 0);
        assertEq(pool.pendingRecapitalizationAssets(), 0);
        assertEq(pool.pendingTradingRevenueAssets(), 0);

        _reconcile();
        assertEq(pool.seniorPrincipal(), RECAP_ASSETS);
        assertEq(pool.juniorPrincipal(), 30_000e6);
        assertEq(pool.unassignedAssets(), 0);
    }

}

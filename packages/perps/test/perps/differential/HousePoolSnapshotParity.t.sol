// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {HousePoolPendingPreviewLib} from "@plether/perps/libraries/HousePoolPendingPreviewLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

abstract contract HousePoolAccountingParityBase is BasePerpTest {

    struct ExpectedAccounting {
        uint256 senior;
        uint256 junior;
        uint256 highWaterMark;
        uint256 unassigned;
        uint256 pendingRecapitalization;
        uint256 pendingRevenue;
    }

    function _recordInflow(
        IHousePool.ClaimantInflowKind kind,
        uint256 amount
    ) internal {
        settlementToken.mint(address(pool), amount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(amount, kind, IHousePool.ClaimantInflowCashMode.CashArrived);
    }

    function _accountingHash() internal view returns (bytes32) {
        bytes32 ownership = keccak256(
            abi.encode(
                pool.seniorPrincipal(),
                pool.juniorPrincipal(),
                pool.seniorHighWaterMark(),
                pool.unassignedAssets(),
                pool.pendingRecapitalizationAssets(),
                pool.pendingTradingRevenueAssets()
            )
        );
        return keccak256(
            abi.encode(
                ownership,
                pool.lastSeniorCouponCheckpointTime(),
                pool.lastReconcileTime(),
                pool.terminalDeficitAssets(),
                pool.accountedAssets(),
                settlementToken.balanceOf(address(pool)),
                seniorVault.totalSupply(),
                juniorVault.totalSupply()
            )
        );
    }

    function _assertPendingAccounting(
        ExpectedAccounting memory expected
    ) internal returns (uint256[4] memory preview) {
        bytes32 beforePreview = _accountingHash();
        if (pool.seniorPrincipal() + pool.juniorPrincipal() == 0) {
            assertEq(pool.getSettlementFreeAssets(), 0, "Settlement cash waits for stored LP principal");
        } else {
            assertEq(
                pool.getSettlementFreeAssets(), pool.getFreeAssets(), "Settlement cash matches withdrawal reserves"
            );
        }
        uint256 previewGasBefore = gasleft();
        (preview[0], preview[1], preview[2], preview[3]) = pool.getPendingTrancheState();
        emit log_named_uint("pending_tranche_preview_gas", previewGasBefore - gasleft());
        assertEq(_accountingHash(), beforePreview, "preview must not mutate accounting or custody");

        uint256[4] memory repeated;
        (repeated[0], repeated[1], repeated[2], repeated[3]) = pool.getPendingTrancheState();
        assertEq(keccak256(abi.encode(repeated)), keccak256(abi.encode(preview)), "repeated preview must be stable");
        (uint256 depositSenior, uint256 depositJunior) = pool.getPendingDepositTrancheState();
        assertEq(depositSenior, expected.senior, "deposit preview senior principal");
        assertEq(depositJunior, expected.junior, "deposit preview junior principal");
        assertEq(_accountingHash(), beforePreview, "repeated previews must leave stored state unchanged");
        assertEq(preview[0], expected.senior, "withdrawal preview senior principal");
        assertEq(preview[1], expected.junior, "withdrawal preview junior principal");

        vm.prank(address(juniorVault));
        uint256 reconcileGasBefore = gasleft();
        pool.reconcile();
        emit log_named_uint("pending_tranche_reconcile_gas", reconcileGasBefore - gasleft());
        assertEq(pool.seniorPrincipal(), expected.senior, "reconciled senior principal");
        assertEq(pool.juniorPrincipal(), expected.junior, "reconciled junior principal");
        assertEq(pool.seniorHighWaterMark(), expected.highWaterMark, "reconciled senior recovery target");
        assertEq(pool.unassignedAssets(), expected.unassigned, "reconciled ownerless assets");
        assertEq(pool.pendingRecapitalizationAssets(), expected.pendingRecapitalization, "remaining recapitalization");
        assertEq(pool.pendingTradingRevenueAssets(), expected.pendingRevenue, "remaining trading revenue");
        assertEq(pool.getSettlementFreeAssets(), pool.getFreeAssets(), "Settlement cash matches reconciled reserves");
        assertEq(pool.getMaxSeniorWithdraw(), preview[2], "senior withdrawal-cap parity");
        assertEq(pool.getMaxJuniorWithdraw(), preview[3], "junior withdrawal-cap parity");
    }

}

contract HousePoolUnownedSnapshotParityTest is HousePoolAccountingParityBase {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_PendingInflowsWithoutJuniorOrSeniorOwnersStayUnassigned() public {
        assertEq(juniorVault.totalSupply(), 0, "fixture has no junior owners");
        assertEq(seniorVault.totalSupply(), 0, "fixture has no senior owners");
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        uint256[4] memory preview = _assertPendingAccounting(ExpectedAccounting(0, 0, 0, 55_000e6, 0, 0));
        assertEq(preview[2], 0, "unassigned assets are not senior withdrawal capital");
        assertEq(preview[3], 0, "unassigned assets are not junior withdrawal capital");
    }

}

contract HousePoolSnapshotParityTest is HousePoolAccountingParityBase {

    using stdStorage for StdStorage;

    function _wipePrincipal() internal {
        settlementToken.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(seniorVault.totalSupply(), 0, "senior ownership survives the wipe");
        assertGt(juniorVault.totalSupply(), 0, "junior ownership survives the wipe");
    }

    function test_MixedPendingInflowsPreserveRecapitalizationPriorityAfterWipe() public {
        _wipePrincipal();
        uint256 survivingHwm = pool.seniorHighWaterMark();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);

        // Recapitalization restores only the existing Senior entitlement; excess remains unassigned.
        ExpectedAccounting memory expected =
            ExpectedAccounting(survivingHwm, 15_000e6, survivingHwm, 40_000e6 - survivingHwm, 0, 0);
        assertFalse(
            pool.canSettleDepositEntries(), "ownerless recapitalization surplus blocks projected deposit settlement"
        );
        uint256[4] memory preview = _assertPendingAccounting(expected);
        assertEq(preview[2], survivingHwm, "restored Senior assets are withdrawable");
        assertGt(preview[3], 0, "surviving junior owners can withdraw recovered revenue");
        assertLe(preview[3], expected.junior, "junior withdrawals remain bounded by recovered principal");
        assertFalse(pool.canSettleDepositEntries(), "ownerless recapitalization surplus still blocks deposits");

        // A second pass has zero pending buckets and must not apply the inflows again.
        bytes32 settled = _accountingHash();
        _assertPendingAccounting(expected);
        assertEq(_accountingHash(), settled, "same-block reconciliation must not double count settled inflows");
    }

    function test_PartialMixedInflowsPreserveFullIntentAndSettleResidualLater() public {
        _wipePrincipal();
        uint256 survivingHwm = pool.seniorHighWaterMark();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(30_000e6));

        uint256[4] memory preview = _assertPendingAccounting(
            ExpectedAccounting(survivingHwm, 0, survivingHwm, 25_000e6 - survivingHwm, 15_000e6, 15_000e6)
        );
        assertEq(preview[2], 0, "residual claimant buckets reserve all remaining senior liquidity");
        assertEq(preview[3], 0, "no junior principal exists before residual settlement");

        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(0));
        // Principal already exists on this pass, so residual revenue continues to junior after senior recovery.
        _assertPendingAccounting(
            ExpectedAccounting(survivingHwm, 15_000e6, survivingHwm, 40_000e6 - survivingHwm, 0, 0)
        );
    }

    function test_PartialMixedInflowsContinueRevenueInFirstPassAfterWipe() public {
        _wipePrincipal();
        uint256 survivingHwm = pool.seniorHighWaterMark();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(5000e6));

        // The first pass can settle all recapitalization and only part of the revenue.
        _assertPendingAccounting(
            ExpectedAccounting(survivingHwm, 10_000e6, survivingHwm, 40_000e6 - survivingHwm, 0, 5000e6)
        );

        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(0));
        _assertPendingAccounting(
            ExpectedAccounting(survivingHwm, 15_000e6, survivingHwm, 40_000e6 - survivingHwm, 0, 0)
        );
    }

    function test_MixedPendingInflowsWithoutJuniorOwnersKeepSurplusUnassigned() public pure {
        // Unit boundary: the production Pool's capacity rule prevents seeding Senior without Junior backing.
        HousePoolPendingPreviewLib.PendingAccountingState memory state;
        state.seniorSupply = 1;
        state.waterfall.seniorHighWaterMark = 40_000e6;
        HousePoolPendingPreviewLib.applyClaimantRecapitalizationIntent(state, 40_000e6);
        HousePoolPendingPreviewLib.applyRevenueIntent(state, 15_000e6);

        assertEq(state.waterfall.seniorPrincipal, 40_000e6);
        assertEq(state.waterfall.seniorHighWaterMark, 40_000e6);
        assertEq(state.waterfall.juniorPrincipal, 0, "revenue cannot create ownerless Junior principal");
        assertEq(state.unassignedAssets, 15_000e6, "surplus without Junior owners stays unassigned");
    }

    function test_StaleMarkPreviewKeepsCouponAccrualWithoutRepricingPrincipal() public {
        address trader = address(0xA103);
        _fundSenior(address(this), 1e6);
        _fundTrader(trader, 20_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 highWaterBefore = pool.seniorHighWaterMark();
        uint256 checkpointBefore = pool.lastSeniorCouponCheckpointTime();
        uint256 reconcileTimeBefore = pool.lastReconcileTime();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 500e6);
        vm.warp(block.timestamp + pool.markStalenessLimit() + 1);
        assertFalse(pool.isWithdrawalLive(), "open position requires a fresh mark");

        uint256 coupon =
            seniorBefore * pool.seniorRateBps() * (block.timestamp - checkpointBefore) / (10_000 * 365 days);
        assertGt(coupon, 0, "fixture must exercise coupon accrual");
        uint256[4] memory preview = _assertPendingAccounting(
            ExpectedAccounting(seniorBefore + coupon, juniorBefore - coupon, highWaterBefore + coupon, 0, 0, 0)
        );
        assertEq(preview[2], 0, "stale senior withdrawals remain disabled");
        assertEq(preview[3], 0, "stale junior withdrawals remain disabled");
        assertEq(pool.lastReconcileTime(), reconcileTimeBefore, "stale mark must not advance the reconcile timestamp");
        assertEq(pool.lastSeniorCouponCheckpointTime(), block.timestamp, "coupon checkpoint still advances");
    }

    function test_HousePoolInputSnapshotMirrorsProtocolSnapshot() public {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory inputSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engine.terminalNavSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            inputSnapshot.physicalAssets,
            protocolSnapshot.poolAssets,
            "HousePool input physical assets should match protocol pool assets"
        );
        assertEq(
            inputSnapshot.netPhysicalAssets,
            protocolSnapshot.netPhysicalAssets,
            "HousePool input net physical assets should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.maxLiabilityAssets,
            protocolSnapshot.maxLiabilityAssets,
            "HousePool input max liability should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.traderClaimBalanceAssets,
            protocolSnapshot.totalTraderClaimBalanceAssets,
            "HousePool input trader claim balance should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.terminalLpPriceDeltaAssets,
            terminalSnapshot.terminalLpPriceDeltaAssets,
            "HousePool input must preserve the Engine terminal delta"
        );
        assertEq(
            inputSnapshot.terminalNavBookVersion,
            terminalSnapshot.bookVersion,
            "HousePool input must preserve the terminal-book version"
        );
        assertEq(
            inputSnapshot.hasOpenPositions,
            terminalSnapshot.hasOpenPositions,
            "HousePool position flag must come from the authenticated terminal snapshot"
        );
    }

    function test_PendingTrancheStateMatchesReconcileOutcome() public {
        address juniorLp = address(0xA102);
        address trader = address(0xA101);
        address account = trader;
        _fundJunior(juniorLp, 1_000_000e6);
        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        _ensureLaterOracleTime();
        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(vm.getBlockTimestamp()));
        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        (uint256 pendingSenior, uint256 pendingJunior, uint256 pendingSeniorWithdraw, uint256 pendingJuniorWithdraw) =
            pool.getPendingTrancheState();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.seniorPrincipal(), pendingSenior, "Pending senior principal should match post-reconcile principal"
        );
        assertEq(
            pool.juniorPrincipal(), pendingJunior, "Pending junior principal should match post-reconcile principal"
        );
        assertEq(
            pool.getMaxSeniorWithdraw(),
            pendingSeniorWithdraw,
            "Pending senior withdraw cap should match post-reconcile cap"
        );
        assertEq(
            pool.getMaxJuniorWithdraw(),
            pendingJuniorWithdraw,
            "Pending junior withdraw cap should match post-reconcile cap"
        );
    }

    function test_PendingTrancheStateMatchesSeededZeroClaimReconcileOutcome() public {
        uint256 seniorRestorationTarget = pool.seniorHighWaterMark();
        uint256 restorationRevenue = 35_000e6;

        settlementToken.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should wipe live senior principal");
        assertEq(pool.juniorPrincipal(), 0, "Setup should wipe live junior principal");
        assertGt(seniorVault.totalSupply(), 0, "Setup should preserve seeded senior ownership");
        assertGt(juniorVault.totalSupply(), 0, "Setup should preserve seeded junior ownership");

        settlementToken.mint(address(pool), restorationRevenue);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            restorationRevenue, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior, uint256 pendingJunior, uint256 pendingSeniorWithdraw, uint256 pendingJuniorWithdraw) =
            pool.getPendingTrancheState();
        uint256 pendingSeniorAssets = seniorVault.totalAssets();
        uint256 pendingJuniorAssets = juniorVault.totalAssets();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pendingSenior,
            seniorRestorationTarget,
            "Pending state should restore the seeded senior HWM before junior in zero-claim states"
        );
        assertEq(
            pendingJunior,
            restorationRevenue - seniorRestorationTarget,
            "Pending state should route only residual revenue to seeded junior"
        );
        assertEq(
            pool.seniorPrincipal(), pendingSenior, "Pending senior principal should match post-reconcile principal"
        );
        assertEq(
            pool.juniorPrincipal(), pendingJunior, "Pending junior principal should match post-reconcile principal"
        );
        assertEq(
            pool.getMaxSeniorWithdraw(),
            pendingSeniorWithdraw,
            "Pending senior withdraw cap should match post-reconcile cap"
        );
        assertEq(
            pool.getMaxJuniorWithdraw(),
            pendingJuniorWithdraw,
            "Pending junior withdraw cap should match post-reconcile cap"
        );
        assertEq(
            seniorVault.totalAssets(),
            pendingSeniorAssets,
            "Senior vault preview assets should match post-reconcile assets"
        );
        assertEq(
            juniorVault.totalAssets(),
            pendingJuniorAssets,
            "Junior vault preview assets should match post-reconcile assets"
        );
        assertEq(pool.unassignedAssets(), 0, "Seeded continuity should keep zero-claim revenue out of quarantine");
    }

}

contract HousePoolPendingRevenueReserveParityTest is HousePoolAccountingParityBase {

    using stdStorage for StdStorage;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _wipePrincipalWithReserve() internal {
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 1000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), 1000e6);

        settlementToken.burn(address(pool), pool.totalAssets() - 1000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 1000e6);
    }

    function _payTrader(
        uint256 amount
    ) internal {
        vm.prank(address(engine));
        pool.payOut(address(0xA105), amount);
    }

    function test_OffsettingReceiptsAndPayoutsPreserveUnassignedReserve() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 100e6);
        _payTrader(100e6);

        _assertPendingAccounting(ExpectedAccounting(0, 0, 1000e6, 1000e6, 0, 0));
        assertFalse(pool.canAcceptTrancheDeposits(false), "unassigned reserve still blocks new deposits");
    }

    function testFuzz_OnlyNetRevenueRestoresClaimants(
        uint256 receipts,
        uint256 payouts,
        bool payoutFirst
    ) public {
        receipts = bound(receipts, 0, 2000e6);
        payouts = bound(payouts, 0, 1000e6);
        _wipePrincipalWithReserve();
        if (payoutFirst) {
            _payTrader(payouts);
        }
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, receipts);
        if (!payoutFirst) {
            _payTrader(payouts);
        }

        uint256 gain = receipts > payouts ? receipts - payouts : 0;
        uint256 reserve = receipts >= payouts ? 1000e6 : 1000e6 - (payouts - receipts);
        uint256 senior = gain > 1000e6 ? 1000e6 : gain;
        _assertPendingAccounting(ExpectedAccounting(senior, gain - senior, 1000e6, reserve, 0, 0));
    }

    function test_SpentRevenueClearsEvenWhenGrossBucketExceedsPoolCash() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 2000e6);
        _payTrader(2500e6);

        _assertPendingAccounting(ExpectedAccounting(0, 0, 1000e6, 500e6, 0, 0));
    }

    function test_ClaimLiabilitiesRetainBackedRevenueAfterPayoutWriteoff() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 2000e6);
        _payTrader(500e6);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(400e6));

        _assertPendingAccounting(ExpectedAccounting(1000e6, 100e6, 1000e6, 1000e6, 0, 400e6));

        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(uint256(0));
        _assertPendingAccounting(ExpectedAccounting(1000e6, 500e6, 1000e6, 1000e6, 0, 0));
    }

    function test_StaleTerminalLossDoesNotWriteOffPhysicallyBackedRevenue() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 2000e6);
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.terminalLpPriceDeltaAssets = -3000e6;
        snapshot.markFreshnessRequired = true;
        snapshot.maxMarkStaleness = 1;
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSelector(engineProtocolLens.getHousePoolInputSnapshot.selector, pool.markStalenessLimit()),
            abi.encode(snapshot)
        );
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSelector(engineProtocolLens.getHousePoolStatusSnapshot.selector),
            abi.encode(HousePoolEngineViewTypes.HousePoolStatusSnapshot(0, false, false))
        );

        _assertPendingAccounting(ExpectedAccounting(0, 0, 1000e6, 1000e6, 0, 2000e6));

        vm.clearMockedCalls();
        _assertPendingAccounting(ExpectedAccounting(1000e6, 1000e6, 1000e6, 1000e6, 0, 0));
    }

    function test_PositiveTerminalReceivableStillRestoresClaimantsAfterPayout() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 100e6);
        _payTrader(100e6);
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.terminalLpPriceDeltaAssets = 1500e6;
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSelector(engineProtocolLens.getHousePoolInputSnapshot.selector, pool.markStalenessLimit()),
            abi.encode(snapshot)
        );

        _assertPendingAccounting(ExpectedAccounting(1000e6, 500e6, 1000e6, 1000e6, 0, 0));
    }

    function test_PositiveTerminalReceivablePreservesFullRecapitalizationIntent() public {
        _wipePrincipalWithReserve();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 2000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 100e6);
        _payTrader(2000e6);
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        snapshot.terminalLpPriceDeltaAssets = 2000e6;
        vm.mockCall(
            address(pool.ENGINE_PROTOCOL_LENS()),
            abi.encodeWithSelector(engineProtocolLens.getHousePoolInputSnapshot.selector, pool.markStalenessLimit()),
            abi.encode(snapshot)
        );

        _assertPendingAccounting(ExpectedAccounting(2000e6, 100e6, 2000e6, 1000e6, 0, 0));
    }

}

contract HousePoolSeededClaimReleaseSnapshotParityTest is HousePoolAccountingParityBase {

    using stdStorage for StdStorage;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev A released trader-claim reserve is ordinary distributable equity, not part of the pending revenue bucket.
    ///      Its seeded-owner restoration must allow the subsequent pending revenue to follow the same claimant path.
    function test_ClaimReleaseRestoresSeededSeniorBeforePendingRevenueSettles() public {
        uint256 seededAssets = pool.totalAssets();
        assertEq(seededAssets, 2000e6, "fixture should begin with only the two seed positions");
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(seededAssets);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), 0, "claims should wipe stored LP principal");

        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 10e6);
        assertEq(pool.pendingTradingRevenueAssets(), 10e6, "revenue should remain queued until reconcile");
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(seededAssets - 20e6);
        assertEq(pool.getFreeAssets(), 20e6, "released senior claim remains physical free cash");

        _assertPendingAccounting(ExpectedAccounting(30e6, 0, 1000e6, 0, 0, 0));
        assertEq(seniorVault.totalAssets(), 30e6, "released claim and revenue should both belong to seeded senior");
    }

    function test_ClaimReleaseRestoresSeededJuniorBeforePendingRevenueSettles() public {
        uint256 seededAssets = pool.totalAssets();
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(seededAssets);
        vm.prank(address(juniorVault));
        pool.reconcile();

        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 10e6);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()").checked_write(seededAssets - 1020e6);
        assertEq(pool.getFreeAssets(), 1020e6, "released junior claim remains physical free cash");

        _assertPendingAccounting(ExpectedAccounting(1000e6, 30e6, 1000e6, 0, 0, 0));
        assertEq(juniorVault.totalAssets(), 30e6, "released claim and revenue should both belong to seeded junior");
    }

}

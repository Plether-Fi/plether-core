// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
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
        usdc.mint(address(pool), amount);
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
                pool.pendingRecapitalizationUsdc(),
                pool.pendingTradingRevenueUsdc()
            )
        );
        return keccak256(
            abi.encode(
                ownership,
                pool.lastSeniorCouponCheckpointTime(),
                pool.lastReconcileTime(),
                pool.terminalDeficitUsdc(),
                pool.accountedAssets(),
                usdc.balanceOf(address(pool)),
                seniorVault.totalSupply(),
                juniorVault.totalSupply()
            )
        );
    }

    function _assertPendingAccounting(
        ExpectedAccounting memory expected
    ) internal returns (uint256[4] memory preview) {
        bytes32 beforePreview = _accountingHash();
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
        assertEq(pool.pendingRecapitalizationUsdc(), expected.pendingRecapitalization, "remaining recapitalization");
        assertEq(pool.pendingTradingRevenueUsdc(), expected.pendingRevenue, "remaining trading revenue");
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
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.juniorPrincipal(), 0);
        assertGt(seniorVault.totalSupply(), 0, "senior ownership survives the wipe");
        assertGt(juniorVault.totalSupply(), 0, "junior ownership survives the wipe");
    }

    function test_MixedPendingInflowsPreserveRecapitalizationPriorityAfterWipe() public {
        _wipePrincipal();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);

        // Continuation is selected before recapitalization revives principal, so this batch's revenue is ownerless.
        ExpectedAccounting memory expected = ExpectedAccounting(40_000e6, 0, 40_000e6, 15_000e6, 0, 0);
        uint256[4] memory preview = _assertPendingAccounting(expected);
        assertEq(preview[2], 40_000e6, "only recapitalized senior assets are withdrawable");
        assertEq(preview[3], 0, "mixed bootstrap does not assign revenue to junior");

        // A second pass has zero pending buckets and must not apply the inflows again.
        bytes32 settled = _accountingHash();
        _assertPendingAccounting(expected);
        assertEq(_accountingHash(), settled, "same-block reconciliation must not double count settled inflows");
    }

    function test_PartialMixedInflowsPreserveFullIntentAndSettleResidualLater() public {
        _wipePrincipal();
        _recordInflow(IHousePool.ClaimantInflowKind.Recapitalization, 40_000e6);
        _recordInflow(IHousePool.ClaimantInflowKind.Revenue, 15_000e6);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(30_000e6));

        uint256[4] memory preview =
            _assertPendingAccounting(ExpectedAccounting(25_000e6, 0, 40_000e6, 0, 15_000e6, 15_000e6));
        assertEq(preview[2], 0, "residual claimant buckets reserve all remaining senior liquidity");
        assertEq(preview[3], 0, "no junior principal exists before residual settlement");

        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(uint256(0));
        // Principal already exists on this pass, so residual revenue continues to junior after senior recovery.
        _assertPendingAccounting(ExpectedAccounting(40_000e6, 15_000e6, 40_000e6, 0, 0, 0));
    }

    function test_StaleMarkPreviewKeepsCouponAccrualWithoutRepricingPrincipal() public {
        address trader = address(0xA103);
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
            inputSnapshot.physicalAssetsUsdc,
            protocolSnapshot.poolAssetsUsdc,
            "HousePool input physical assets should match protocol pool assets"
        );
        assertEq(
            inputSnapshot.netPhysicalAssetsUsdc,
            protocolSnapshot.netPhysicalAssetsUsdc,
            "HousePool input net physical assets should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.maxLiabilityUsdc,
            protocolSnapshot.maxLiabilityUsdc,
            "HousePool input max liability should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.traderClaimBalanceUsdc,
            protocolSnapshot.totalTraderClaimBalanceUsdc,
            "HousePool input trader claim balance should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.terminalLpPriceDeltaUsdc,
            terminalSnapshot.terminalLpPriceDeltaUsdc,
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

        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));
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

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should wipe live senior principal");
        assertEq(pool.juniorPrincipal(), 0, "Setup should wipe live junior principal");
        assertGt(seniorVault.totalSupply(), 0, "Setup should preserve seeded senior ownership");
        assertGt(juniorVault.totalSupply(), 0, "Setup should preserve seeded junior ownership");

        usdc.mint(address(pool), restorationRevenue);
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

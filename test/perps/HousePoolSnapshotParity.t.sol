// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdVault} from "../../src/perps/interfaces/ICfdVault.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract HousePoolSnapshotParityTest is BasePerpTest {

    function test_HousePoolInputSnapshotMirrorsProtocolSnapshot() public {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory inputSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(
            inputSnapshot.physicalAssetsUsdc,
            protocolSnapshot.vaultAssetsUsdc,
            "HousePool input physical assets should match protocol vault assets"
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
            inputSnapshot.protocolFeesUsdc,
            protocolSnapshot.accumulatedFeesUsdc,
            "HousePool input fees should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.deferredTraderCreditUsdc,
            protocolSnapshot.totalDeferredTraderCreditUsdc,
            "HousePool input deferred trader credit should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.deferredKeeperCreditUsdc,
            protocolSnapshot.totalDeferredKeeperCreditUsdc,
            "HousePool input deferred keeper credit should match protocol snapshot"
        );
    }

    function test_PendingTrancheStateMatchesReconcileOutcome() public {
        address juniorLp = address(0xA102);
        address trader = address(0xA101);
        address account = trader;
        _fundJunior(juniorLp, 1_000_000e6);
        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));
        _close(account, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

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
        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Setup should wipe live senior principal");
        assertEq(pool.juniorPrincipal(), 0, "Setup should wipe live junior principal");
        assertGt(seniorVault.totalSupply(), 0, "Setup should preserve seeded senior ownership");
        assertGt(juniorVault.totalSupply(), 0, "Setup should preserve seeded junior ownership");

        usdc.mint(address(pool), 35_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            35_000e6, ICfdVault.ClaimantInflowKind.Revenue, ICfdVault.ClaimantInflowCashMode.CashArrived
        );

        (uint256 pendingSenior, uint256 pendingJunior, uint256 pendingSeniorWithdraw, uint256 pendingJuniorWithdraw) =
            pool.getPendingTrancheState();
        uint256 pendingSeniorAssets = seniorVault.totalAssets();
        uint256 pendingJuniorAssets = juniorVault.totalAssets();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pendingSenior, 1000e6, "Pending state should restore seeded senior before junior in zero-claim states");
        assertEq(pendingJunior, 34_000e6, "Pending state should route only residual revenue to seeded junior");
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

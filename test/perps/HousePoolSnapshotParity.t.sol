// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePoolEngineViewTypes} from "../../src/perps/interfaces/HousePoolEngineViewTypes.sol";
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
            inputSnapshot.deferredTraderPayoutUsdc,
            protocolSnapshot.totalDeferredPayoutUsdc,
            "HousePool input deferred trader payout should match protocol snapshot"
        );
        assertEq(
            inputSnapshot.deferredKeeperCreditUsdc,
            protocolSnapshot.totalDeferredKeeperCreditUsdc,
            "HousePool input deferred clearer bounty should match protocol snapshot"
        );
    }

    function test_PendingTrancheStateMatchesReconcileOutcome() public {
        address juniorLp = address(0xA102);
        address trader = address(0xA101);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundJunior(juniorLp, 1_000_000e6);
        _fundTrader(trader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(80_000_000, uint64(block.timestamp));
        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 80_000_000);

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

}

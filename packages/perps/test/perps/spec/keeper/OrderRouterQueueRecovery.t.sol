// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterQueueRecoveryTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_StateMachine_StaleRevertPreservesQueueUntilHonestBatchExecutes() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.SHORT, 8000 * 1e18, 400 * 1e6, 1e8, false);
        vm.stopPrank();

        address account = alice;
        IOrderRouterAccounting.AccountReservationView memory beforeReservation = router.getAccountReservations(account);
        assertEq(beforeReservation.pendingOrderCount, 2, "Both orders should be queued");

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);
        vm.warp(1000);
        bytes[] memory empty = _pythUpdateData();

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountReservationView memory afterRevertReservation =
            router.getAccountReservations(account);
        assertEq(router.nextExecuteId(), 1, "Non-terminal stale failure must leave the queue untouched");
        assertEq(afterRevertReservation.pendingOrderCount, 2, "All queued reservation should remain after stale revert");

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1006, 900);
        vm.warp(1050);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        IOrderRouterAccounting.AccountReservationView memory finalReservation = router.getAccountReservations(account);
        assertEq(router.nextExecuteId(), 0, "Honest keeper should later consume both queued orders and clear the queue");
        assertEq(finalReservation.pendingOrderCount, 0, "Reservation should be fully released after terminal execution");
    }

    function testFuzz_StaleOracleRevertPreservesReservationAndQueue(
        uint64 age
    ) public {
        _startRecordingLogs();
        age = uint64(bound(age, 61, 600));
        vm.warp(2000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address account = alice;
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2000 - age);

        bytes[] memory empty = _pythUpdateData();
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(router.nextExecuteId(), 1, "Stale revert should keep queue head pending");
        assertEq(reservation.pendingOrderCount, 1, "Stale revert should preserve reserved order state");
        assertEq(usdc.balanceOf(address(router)), 0, "Router should not custody the keeper reserve");
        assertEq(
            reservation.executionBountyUsdc,
            200_000,
            "Reservation view should continue tracking the pending keeper reserve"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            200_000,
            "Clearinghouse should continue reserving the pending keeper reserve"
        );
    }

}


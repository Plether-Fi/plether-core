// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../shared/OrderRouterTestBase.sol";

contract OrderRouterQueueGasBoundsTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_BoundedQueue_BatchClearsFailedOrdersAndExecutesTail() public {
        _startRecordingLogs();
        address spammer = address(0x444);
        address carol = address(0x555);
        address carolAccount = carol;

        usdc.mint(spammer, 100_000 * 1e6);
        vm.startPrank(spammer);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(spammer, 100_000 * 1e6);
        vm.stopPrank();

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolAccount, 20_000 * 1e6);
        vm.stopPrank();

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.LONG, 1000 * 1e18, 100 * 1e6, 2e8, false);
        }

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        uint256 gasBefore = gasleft();
        router.executeOrderBatch(uint64(spamCount + 1), empty);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(
            router.nextExecuteId(), 0, "batch should clear adversarial failed heads and still execute the tail order"
        );
        (uint256 size,,,,,,) = engine.positions(carolAccount);
        assertEq(size, 10_000 * 1e18, "tail order should still execute after many failed head orders");
        assertLt(gasUsed, 40_000_000, "adversarial batch path gas budget regressed");
    }

    function test_HistoricalFailedReservations_DoNotBrickLaterHeadCleanup() public {
        _startRecordingLogs();
        address carol = address(0x559);
        address aliceAccount = alice;
        address carolAccount = carol;

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolAccount, 20_000 * 1e6);
        vm.stopPrank();

        bytes[] memory empty = _mockPythUpdateData();
        uint256 failedCycles = 24;

        for (uint256 i = 0; i < failedCycles; ++i) {
            vm.prank(alice);
            router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

            vm.warp(block.timestamp + router.maxExecutionWindowSeconds() + 1);
            uint256 historicalPublishTime = block.timestamp - router.maxExecutionWindowSeconds();
            baseMockPyth.setAllUniquePrices(
                _basePythFeedIds(), int64(100_000_000), 0, int32(-8), historicalPublishTime, historicalPublishTime - 1
            );
            vm.roll(block.number + 1);
            router.executeOrder(uint64(i + 1), empty);

            assertEq(router.nextExecuteId(), 0, "failed slippage head should clear immediately each cycle");
            assertEq(
                clearinghouse.getAccountReservationSummary(aliceAccount).activeReservationCount,
                0,
                "historical failed reservations must not leave active residue"
            );
        }

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 1);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(100_000_000), 0, int32(-8), block.timestamp, block.timestamp - 1
        );
        vm.roll(block.number + 10);
        uint256 gasBefore = gasleft();
        router.executeOrderBatch(26, empty);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(router.nextExecuteId(), 0, "later valid head cleanup should still drain the queue");
        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        (uint256 carolSize,,,,,,) = engine.positions(carolAccount);
        assertEq(aliceSize, 10_000 * 1e18, "historical failed reservations must not block later head execution");
        assertEq(carolSize, 5000 * 1e18, "tail order should execute after the cleaned head");
        assertLt(gasUsed, 40_000_000, "historical failed reservations should not cause unbounded cleanup gas");
    }

    function test_BoundedForeignQueue_FullCloseExecutesAndLeavesTailLive() public {
        _startRecordingLogs();
        address spammer = address(0x557);
        address aliceAccount = alice;

        usdc.mint(spammer, 100_000 * 1e6);
        vm.startPrank(spammer);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(spammer, 100_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 2e8, false);
        }

        bytes[] memory closeData = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 10);
        uint256 gasBefore = gasleft();
        router.executeOrder(2, closeData);
        uint256 gasUsed = gasBefore - gasleft();

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "terminal close should still succeed with a bounded foreign queue behind it");
        assertEq(router.nextExecuteId(), 3, "queue head should advance after the full close");
        assertLt(gasUsed, 40_000_000, "terminal close gas budget regressed");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 10);
        router.executeOrder(3, closeData);
        assertEq(router.nextExecuteId(), 4, "tail queue should remain live after terminal close cleanup");
    }

}


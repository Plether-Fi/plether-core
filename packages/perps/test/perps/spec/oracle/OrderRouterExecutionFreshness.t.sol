// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterExecutionFreshnessTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_PublishTimeBeforeCommit_Reverts() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        assertEq(
            router.nextExecuteId(), 1, "Live execution should keep the order pending when publish time predates commit"
        );
    }

    function test_FuturePublishTime_Reverts() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1010);
        vm.warp(1005);
        vm.roll(block.number + 1);

        bytes[] memory empty = _pythUpdateData();
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Future oracle publication must not consume the FIFO head");
        assertEq(engine.lastMarkTime(), 0, "Future oracle publication must not update the cached mark");
    }

    function test_SameBlockExecution_ReturnsPending() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, empty);

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));
        assertEq(router.nextExecuteId(), 1, "Order stays in queue when executed in same block");
    }

    function test_OrderExecution_UsesRouterExecutionStalenessLimit_NotPoolMarkLimit() public {
        _startRecordingLogs();
        IHousePool.PoolConfig memory poolConfig = _currentPoolConfig();
        poolConfig.markStalenessLimit = 300;
        pool.proposePoolConfig(poolConfig);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        vm.warp(1150);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1100);
        vm.warp(1200);
        vm.roll(block.number + 1);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, _pythUpdateData());

        IOrderRouterAdminHost.RouterConfig memory routerConfig = _routerConfig();
        routerConfig.orderExecutionStalenessLimit = 300;
        routerAdmin.proposeRouterConfig(routerConfig);
        vm.warp(1200 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp - 10));

        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 0, "Router execution staleness limit should control live order execution");
    }

    function test_OrderRefund_DoesNotRevertWhenRouterLimitExceedsEngineHelperLimit() public {
        _startRecordingLogs();
        ICfdEngineAdminHost.EngineFreshnessConfig memory freshnessConfig = _engineFreshnessConfig();
        freshnessConfig.engineMarkStalenessLimit = 60;
        engineAdmin.proposeFreshnessConfig(freshnessConfig);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        engineAdmin.finalizeFreshnessConfig();
        routerAdmin.finalizeRouterConfig();

        vm.warp(1050);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1051, 1050);
        bytes[] memory empty = _pythUpdateData();
        address aliceAccount = alice;
        uint256 settlementBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.warp(1200);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            router.nextExecuteId(),
            0,
            "Router-validated refund path should not revert during settlement credit finalization"
        );
        assertEq(
            settlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Trader refund path should consume the reserved bounty from the post-commit settlement baseline"
        );
    }

    function test_PostCommitDegradedModePaysClearerAndDoesNotBrickHead() public {
        _startRecordingLogs();
        _fundTrader(bob, 10_000e6);
        address aliceAccount = alice;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);

        _setDegradedModeForTest();
        vm.warp(block.timestamp + 6);

        uint256 aliceSettlementBefore = clearinghouse.balanceUsdc(aliceAccount);
        uint256 keeperBefore = _settlementBalance(address(this));

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 2, "Failed refund transfer must not brick the FIFO head");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Current policy should still pay the clearer while preserving FIFO progress"
        );
        assertEq(
            aliceSettlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Trader settlement should pay the reserved bounty while preserving FIFO progress"
        );
    }

    function test_BatchExecution_UsesOrderExecutionPublishTimeDivergenceLimit() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderSettlementWindow = 60;
        config.maxComponentPublishTimeDivergence = 60;
        _setRouterConfig(config);
        vm.warp(1000);

        uint256 basePublishTime = block.timestamp + 6;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(feedIds[0], int64(100_000_000), int32(-8), basePublishTime);
        for (uint256 i = 1; i < feedIds.length; i++) {
            mockPyth.setPrice(feedIds[i], int64(100_000_000), int32(-8), basePublishTime + 30);
        }

        vm.warp(basePublishTime + 30);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, _pythUpdateData());

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(
            size, 10_000e18, "Batch execution should accept feed publish dispersion allowed for normal order execution"
        );
        assertEq(router.nextExecuteId(), 0, "Successful batch execution should clear the queue head");
    }

    function test_FrozenCloseExecution_AllowsFeedPublishDivergenceWithinFadStaleness() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 2 hours;
        _setRouterConfig(config);

        uint256 saturdayNoon = 605_016_000;
        uint256 minPublishTime = saturdayNoon - 2 hours;
        address aliceAccount = alice;

        vm.warp(minPublishTime - 1);
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8);

        mockPyth.setPrice(feedIds[0], int64(100_000_000), int32(-8), minPublishTime);
        mockPyth.setPrice(feedIds[1], int64(100_000_000), int32(-8), minPublishTime + 2 hours);

        vm.warp(saturdayNoon);
        uint64 orderId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        vm.roll(block.number + 1);
        router.executeOrder(orderId, _pythUpdateData());

        (uint256 sizeAfter,,,,,,) = engine.positions(aliceAccount);
        assertEq(sizeAfter, 0, "Frozen close execution should accept feed divergence within FAD staleness");
    }

    function test_SingleExecute_EmptyQueueRevertsNoOrders() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp + 6));
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0, "Queue head should clear to zero sentinel when empty");

        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrder(1, empty);
    }

    function test_InsufficientPythFee_Reverts() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setFee(1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory data = new bytes[](1);
        data[0] = hex"00";

        vm.warp(1050);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__InsufficientFee.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, data);
    }

    function test_BatchExecution_MEVCheckPerOrder() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1008);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1010);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        assertEq(router.nextExecuteId(), 2, "Batch should stop once the next order fails publish-time ordering");

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000 * 1e18, "Only the pre-publish commitment should execute before batch processing stops");
    }

    function test_PublishTimeBeforeCommit_RevertsForExternalKeeper() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Live execution should reject publish times that are not post-commit");
    }

    function test_FreshPublishAfterCommit_Executes() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1006);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0, "Fresh post-commit publish should execute normally");
    }

    function test_PublishTimeEqualToCommit_Reverts() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1000, 999);

        vm.warp(1050);
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 1, "Live execution must require a strictly post-commit tick");
    }

    function test_OrderExecution_UsesPostCommitHistoricalPrice_NotLiveRevealPrice() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 0, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1006, 999);
        mockPyth.setAllPrices(feedIds, int64(120_000_000), int32(-8), 1050);

        vm.warp(1050);
        vm.roll(block.number + 1);
        router.executeOrder(1, _pythUpdateData());

        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(alice);
        assertEq(size, 10_000 * 1e18, "Historical settlement should execute the open");
        assertEq(entryPrice, 100_000_000, "Entry price must bind to the first post-commit tick");
    }

    function test_OrderExecution_RejectsSkippedHistoricalTick() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 0, false);

        mockPyth.setAllUniquePrices(feedIds, int64(120_000_000), 0, int32(-8), 1012, 1006);

        vm.warp(1050);
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 1, "A skipped historical tick must leave the order pending");
    }

    function test_BatchExecution_ReusesHistoricalTickForClusteredOrders() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setFee(1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1006, 999);

        vm.deal(address(this), 2 ether);
        vm.warp(1050);
        vm.roll(block.number + 1);
        uint256 callsBefore = mockPyth.parseUniqueCallCount();
        router.executeOrderBatch{value: 2 ether}(2, _pythUpdateData());

        assertEq(
            mockPyth.parseUniqueCallCount() - callsBefore,
            1,
            "Batch should parse once when later commit times are covered by the same unique tick"
        );
        assertEq(router.nextExecuteId(), 0, "Clustered batch should drain the queue");

        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 15_000 * 1e18, "Both clustered orders should execute");
    }

    function test_BatchExecution_DoesNotReuseTickAtCommitTimestamp() public {
        _startRecordingLogs();
        vm.warp(1000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1006);
        vm.roll(block.number + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1006, 999);

        vm.warp(1050);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, _pythUpdateData());

        assertEq(router.nextExecuteId(), 2, "Order committed at the cached tick must remain pending");

        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 10_000 * 1e18, "Only the strictly post-commit order should execute");
    }

    function test_BatchExecution_StalePrice_ReturnsUnavailableAndLeavesPending() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1000);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(1, empty);

        assertEq(result.nextOrderId, 1);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));
        assertEq(router.nextExecuteId(), 1, "Stale batch price must leave the FIFO head pending");
    }

}

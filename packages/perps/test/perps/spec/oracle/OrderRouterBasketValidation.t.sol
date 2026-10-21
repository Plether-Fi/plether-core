// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterBasketValidationTest is OrderRouterPythTestBase {

    function test_BasketConfidenceTooWide_RevertsExecution() public {
        _startRecordingLogs();
        vm.warp(SETUP_TIMESTAMP);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 100;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(SETUP_TIMESTAMP + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        mockPyth.setAllUniquePrices(
            feedIds,
            int64(100_000_000),
            uint64(2_000_000),
            int32(-8),
            uint256(pending.commitTime) + 1,
            pending.commitTime
        );

        vm.warp(uint256(pending.commitTime) + 1);
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        router.executeOrder(1, _pythUpdateData());
    }

    function test_BasketConfidenceWithinThreshold_AllowsExecution() public {
        _startRecordingLogs();
        vm.warp(SETUP_TIMESTAMP);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 100;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(routerAdmin.routerConfigActivationTime());
        routerAdmin.finalizeRouterConfig();

        uint64 commitTime = uint64(block.timestamp);
        vm.prank(alice);
        uint64 orderId = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 110_000_000, false);
        mockPyth.setAllUniquePrices(feedIds, 120_000_000, 500_000, -8, commitTime + 1, commitTime);
        vm.warp(uint256(commitTime) + 1);
        vm.roll(block.number + 1);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, _pythUpdateData());

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(alice);
        assertEq(size, 10_000e18);
        assertEq(entryPrice, 119_900_000, "confidence shifts the fill by 20% of 500000");
        assertEq(engine.lastMarkPrice(), 120_000_000, "neutral basket mark remains unchanged");
        assertEq(router.nextExecuteId(), 0);
    }

    function test_BasketMath_WeightedAverage() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setPrice(FEED_A, 130_000_000, -8, 1006);
        mockPyth.setPrice(FEED_B, 110_000_000, -8, 1006);
        vm.prank(alice);
        uint64 orderId = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 119_000_000, false);
        vm.warp(1050);
        vm.roll(block.number + 1);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, _pythUpdateData());

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(alice);
        assertEq(size, 10_000e18);
        assertEq(entryPrice, 120_000_000, "equal weights preserve the $1.20 basket in the actual fill");
        assertEq(engine.lastMarkPrice(), 120_000_000);
    }

    function test_BasketMath_UnequalWeights() public {
        _startRecordingLogs();
        vm.warp(1001);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_A;
        ids[1] = FEED_B;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.7e18;
        w[1] = 0.3e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 1e8;
        b[1] = 1e8;

        PletherOracle oracle =
            new PletherOracle(address(engine), address(pool), address(mockPyth), ids, w, b, new bool[](2));

        mockPyth.setPrice(FEED_A, int64(120_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(80_000_000), int32(-8), 1001);

        vm.warp(1001);
        vm.prank(address(router));
        oracle.updatePrice(address(this), _pythUpdateData(), IPletherOracle.PriceMode.MarkRefresh);
        IPletherOracle.PriceSnapshot memory snapshot = oracle.getLatestPrice(IPletherOracle.PriceMode.MarkRefresh);
        assertEq(snapshot.price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(snapshot.markPrice, 108_000_000);
        assertEq(snapshot.publishTime, 1001, "minPublishTime should be weakest link");
    }

    function test_WeakestLink_Timestamp_TriggersMev() public {
        _startRecordingLogs();
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Weakest-link publish time should still enforce post-commit settlement");
    }

    function test_WeakestLink_StalenessReturnsUnavailableAndLeavesPending() public {
        _startRecordingLogs();
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1001);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(1, empty);

        assertEq(result.nextOrderId, 1);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));
        assertEq(router.nextExecuteId(), 1, "Weakest-link staleness must leave the FIFO head pending");
    }

    function test_BasketPrice_RevertsWhenFeedPublishTimesDivergeTooFar() public {
        // Historical settlement admits ticks throughout a 15-second window, but the components must
        // remain within five seconds. Exercise that production policy independently of live freshness.
        vm.warp(1008);
        mockPyth.setUniquePrice(FEED_A, 120_000_000, 0, -8, 1001, 1000);
        mockPyth.setUniquePrice(FEED_B, 120_000_000, 0, -8, 1007, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__PublishTimeDivergence.selector,
                IPletherOracle.PriceMode.OrderExecution,
                1001,
                1007,
                5
            )
        );
        pletherOracle.updateOrderExecutionPrice(
            address(this),
            _pythUpdateData(),
            IPletherOracle.OrderExecutionRequest(1000, 0, CfdTypes.Side.LONG, false, true)
        );
    }

}

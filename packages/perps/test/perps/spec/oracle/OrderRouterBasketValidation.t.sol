// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {BasketPriceHarness, OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterBasketValidationTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

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
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.basketMaxConfidenceRatioBps = 100;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(1000 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        assertEq(router.pletherOracle().basketMaxConfidenceRatioBps(), 100, "timelocked basket confidence limit");

        mockPyth.setAllPrices(feedIds, int64(100_000_000), uint64(500_000), int32(-8), 1006);

        vm.roll(block.number + 1);
        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 0, "Execution should succeed when basket confidence is within threshold");
    }

    function test_BasketMath_WeightedAverage() public {
        _startRecordingLogs();
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(110_000_000), int32(-8), 1006);
        mockPyth.setPrice(FEED_B, int64(90_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Basket at $1.00 should pass slippage for target $1.00");
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

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, new bool[](2));

        mockPyth.setPrice(FEED_A, int64(120_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(80_000_000), int32(-8), 1001);

        vm.warp(1001);
        (uint256 price, uint256 minPt) = harness.computeBasketPrice(60, 60);
        assertEq(price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(minPt, 1001, "minPublishTime should be weakest link");
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
        _startRecordingLogs();
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 930);

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), feedIds, weights, bases, new bool[](2));
        vm.expectPartialRevert(IPletherOracle.PletherOracle__PublishTimeDivergence.selector);
        harness.computeBasketPrice(3 days, 60);
    }

}


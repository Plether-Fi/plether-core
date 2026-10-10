// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterSlippageTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_Slippage_CancelsGracefully() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;
        assertEq(
            clearinghouse.balanceUsdc(account),
            10_000 * 1e6 - 200_000,
            "Open-order slippage failure should forfeit the reserved execution bounty from trader settlement"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            200_000,
            "Terminal slippage failures currently credit the clearer through the carry-aware settlement path"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            0,
            "Failed binding open-order bounty should not be routed to protocol revenue in this execution path"
        );
        assertEq(router.nextExecuteId(), 0, "Terminal slippage miss should clear the pending order");
        assertEq(_executionBountyReserve(1), 0, "Terminal slippage miss should clear bounty reservation");
    }

    function test_StateMachine_BatchClearsSlippageFailedHeadAndContinues() public {
        _startRecordingLogs();
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.roll(block.number + 1);
        vm.warp(1050);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address account = alice;
        bytes[] memory empty = _pythUpdateData();

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1006);
        router.executeOrderBatch(2, empty);

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(router.nextExecuteId(), 2, "Failed head should clear while a later blocked order remains pending");
        assertEq(
            reservation.pendingOrderCount,
            1,
            "The later blocked order should remain pending after the failed head clears"
        );
        assertEq(_executionBountyReserve(1), 0, "Failed head should clear its execution bounty reservation");
        assertEq(
            _executionBountyReserve(2),
            200_000,
            "Later blocked order should retain its reservation after the failed head clears"
        );
    }

    function testFuzz_SlippageFailureClearsReservationAndOrder(
        uint256 adverseTarget
    ) public {
        _startRecordingLogs();
        adverseTarget = bound(adverseTarget, 1, 99_999_999);
        vm.warp(3000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, adverseTarget, false);

        address account = alice;
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3006);
        vm.warp(3006);

        bytes[] memory empty = _pythUpdateData();
        vm.warp(3006);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(router.nextExecuteId(), 0, "Terminal slippage miss should clear the queue head");
        assertEq(reservation.pendingOrderCount, 0, "Terminal slippage miss should clear pending reservation state");
        assertEq(usdc.balanceOf(address(router)), 0, "Keeper reserve should not remain reserved after terminal failure");
    }

    function test_Slippage_CloseOrders_Protected() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;
        (uint256 size,,,,,,) = engine.positions(account);
        assertTrue(size > 0, "Position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Close should be rejected by slippage check");
    }

    function test_Slippage_ClampedBeforeCheck_LongClose() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;
        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "LONG position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(250_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 240_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "LONG close should succeed against clamped price");
    }

}


// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterQueueLifecycleTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_UnbrickableQueue_OnEngineRevert() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 1 hours);
        uint256 bobMaxWithdraw = _maxRequestableJuniorAssets(bob);
        _settleJuniorWithdrawal(bob, bobMaxWithdraw);

        bytes[] memory emptyPayload = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, emptyPayload);

        assertEq(router.nextExecuteId(), 0, "Terminal engine reverts should clear the queue to the zero sentinel");

        address account = alice;
        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should not exist");

        assertEq(
            clearinghouse.balanceUsdc(account),
            10_000 * 1e6 - 200_000,
            "Protocol-state invalidation should preserve the post-commit settlement baseline under the current refund path"
        );
    }

    function test_ExecuteNonPendingOrder_Reverts() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        vm.roll(10);
        router.executeOrder(1, empty);
    }

    function test_ExecuteOrder_SkipsFailedHeadBeforeExpiration() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();

        address other = address(0x333);
        address otherAccount = other;

        _fundTrader(other, 1000e6);
        _open(otherAccount, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 1, head
        vm.prank(other);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, type(uint256).max, false); // order 2, non-head
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 3, next live order

        vm.prank(other);
        clearinghouse.withdraw(otherAccount, 70e6);

        bytes[] memory pythPrice = new bytes[](1);
        pythPrice[0] = abi.encode(uint256(150_000_000));
        vm.deal(other, 10 ether);
        vm.prank(other);
        router.executeLiquidation{value: 0}(otherAccount, pythPrice);

        assertEq(router.nextExecuteId(), 1, "Liquidating a non-head account should not advance the global head");

        assertEq(
            router.nextExecuteId(),
            1,
            "Liquidation of a non-head order should leave the head pointer unchanged initially"
        );

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 3, "Liquidation should already have cleared the invalidated non-head order");

        vm.roll(block.number + 10);
        router.executeOrder(3, empty);

        assertEq(
            router.nextExecuteId(),
            0,
            "Single-order execution should clear the queue to the zero sentinel when exhausted"
        );
    }

    function test_StrictFIFO_OutOfOrder_Reverts() public {
        _startRecordingLogs();
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty = _mockPythUpdateData();
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        vm.roll(10);
        router.executeOrder(2, empty);
    }

    function test_CommitOrder_RevertsWhenPendingOrderCountHitsCap() public {
        _startRecordingLogs();
        uint256 limit = 5;

        vm.startPrank(alice);
        for (uint256 i = 0; i < limit; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, 1e8, false);
        }
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TooManyPendingOrders.selector);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, 1e8, false);
        vm.stopPrank();
    }

    function test_OrderRecord_UnifiesPendingState() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        OrderRouterDebugLens.OrderRecord memory record = _orderRecord(1);
        assertEq(uint256(record.status), uint256(IOrderRouterAccounting.OrderStatus.Pending));
        assertEq(record.core.orderId, 1);
        assertEq(record.core.account, alice);
        assertEq(_remainingCommittedMargin(1), 1000 * 1e6);
        assertEq(record.executionBountyUsdc, 200_000);
        assertEq(record.nextMarginOrderId, 0);
        assertEq(record.prevMarginOrderId, 0);
        assertTrue(record.inMarginQueue, "Positive-margin pending order should advertise margin-queue membership");
    }

    function test_OrderRecord_DeletesExecutedStateAndBookPreservesLifecycle() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        OrderRouterDebugLens.OrderRecord memory record = OrderRouterDebugLens.loadRawOrderRecord(vm, router, 1);
        assertEq(uint256(record.status), uint256(IOrderRouterAccounting.OrderStatus.None));
        assertEq(record.core.orderId, 0, "Terminal Router record should be fully deleted");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 1);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Executed));
        assertEq(_remainingCommittedMargin(1), 0, "Executed order should clear committed margin reservation");
        assertEq(record.executionBountyUsdc, 0, "Executed order should clear execution bounty reservation");
        assertFalse(record.inMarginQueue, "Executed order should not remain linked in the margin queue");
    }

    function test_GetPendingOrdersForAccount_ReturnsQueuedOrderDetails() public {
        _startRecordingLogs();
        address account = alice;

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(account);
        assertEq(pending.length, 2);
        assertEq(pending[0].orderId, 1);
        assertFalse(pending[0].isClose);
        assertEq(pending[0].committedMarginUsdc, 1000 * 1e6);
        assertEq(pending[0].executionBountyUsdc, 200_000);
        assertEq(pending[1].orderId, 2);
        assertFalse(pending[1].isClose);
        assertEq(pending[1].executionBountyUsdc, 200_000);
    }

    function test_PendingOrderPointers_LinkPerAccountInFIFOOrder() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _fundTrader(bob, 10_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.SHORT, 20_000 * 1e18, 2000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 500 * 1e6, 1e8, false);

        IOrderRouterAccounting.PendingOrderView[] memory alicePending = _pendingOrders(aliceAccount);
        assertEq(alicePending.length, 2, "Alice should see only her own queued orders");
        assertEq(alicePending[0].orderId, 1, "Alice queue should preserve per-account FIFO order");
        assertEq(alicePending[1].orderId, 3, "Alice tail should remain reachable after foreign inserts");
    }

    function test_ExecuteOrder_UnlinksAccountHeadWithoutAffectingForeignQueuePointers() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _fundTrader(bob, 10_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.SHORT, 20_000 * 1e18, 2000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.PendingOrderView[] memory alicePending = _pendingOrders(aliceAccount);
        assertEq(alicePending.length, 1, "Only Alice's trailing queued order should remain");
        assertEq(alicePending[0].orderId, 3, "Alice residual queue should still be reachable after execution");
    }

    function test_PoisonedHead_CloseSlippageFailsAndLetsTailExecute() public {
        _startRecordingLogs();
        address carol = address(0x556);
        address aliceAccount = alice;
        address carolAccount = carol;

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolAccount, 20_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        _fundTrader(alice, 2 * 1e6);
        _fundTrader(bob, 1000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory batchData = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 10);
        router.executeOrderBatch(3, batchData);

        assertEq(router.nextExecuteId(), 0, "terminal slippage miss should not block later queued orders");
        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        (uint256 carolSize,,,,,,) = engine.positions(carolAccount);
        assertEq(aliceSize, 10_000 * 1e18, "slippage-failed close must leave the live position intact");
        assertEq(carolSize, 5000 * 1e18, "tail order should execute once the failed head is cleared");
    }

}

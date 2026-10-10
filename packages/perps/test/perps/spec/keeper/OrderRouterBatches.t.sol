// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterBatchesTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_BatchExecution_AllSucceed() public {
        _startRecordingLogs();
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.deal(carol, 10 ether);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carol, 10_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        uint256 keeperBefore = _settlementBalance(address(this));
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 10);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 0, "Empty global queue should clear to zero sentinel after processing");

        address aliceAccount = alice;
        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(aliceSize, 15_000 * 1e18, "Alice should have 15k LONG");

        address carolAccount = carol;
        (uint256 carolSize,,,,,,) = engine.positions(carolAccount);
        assertEq(carolSize, 10_000 * 1e18, "Carol should have 10k SHORT");

        uint256 keeperAfter = _settlementBalance(address(this));
        assertEq(
            keeperAfter - keeperBefore,
            600_000,
            "Keeper should receive the 0.20 USDC capped reward per successful order"
        );

        assertEq(uint256(_orderRecord(1).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(_orderRecord(2).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(_orderRecord(3).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
    }

    function test_BatchExecution_SuccessfulOrdersEndExecuted() public {
        _startRecordingLogs();
        address carol = address(0x334);
        usdc.mint(carol, 10_000 * 1e6);
        vm.deal(carol, 10 ether);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carol, 10_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        OrderRouterDebugLens.OrderRecord memory firstRecord = _orderRecord(1);
        OrderRouterDebugLens.OrderRecord memory secondRecord = _orderRecord(2);
        assertEq(uint256(firstRecord.status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(secondRecord.status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(_remainingCommittedMargin(1), 0, "Executed batch order should clear committed margin reservation");
        assertEq(_remainingCommittedMargin(2), 0, "Executed batch order should clear committed margin reservation");
        assertEq(firstRecord.executionBountyUsdc, 0, "Executed batch order should clear execution bounty reservation");
        assertEq(secondRecord.executionBountyUsdc, 0, "Executed batch order should clear execution bounty reservation");
    }

    function test_BatchExecution_MixedResults() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1.5e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 10);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 0, "Batch should clear the terminal slippage middle order and drain the queue");

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 15_000 * 1e18, "Orders 1 and 3 succeed, order 2 cancelled");
    }

    function test_BatchExecution_NoOrders_Reverts() public {
        _startRecordingLogs();
        bytes[] memory empty;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__BatchBeforeQueueHead.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(0, empty);
    }

    function test_BatchExecution_EmptyQueueAfterDrain_RevertsBeforeOracleWork() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        assertEq(router.nextExecuteId(), 0, "Queue should be empty after draining the only batch order");
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrderBatch(1, empty);
    }

    function test_BatchExecution_UncommittedMaxId_Reverts() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__BatchOrderNotCommitted.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(5, empty);
    }

    function test_BatchExecution_RefundsExcessEthAndCreditsReservedUsdcBounties() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        uint256 keeperEthBefore = address(this).balance;
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        router.executeOrderBatch{value: 0.1 ether}(2, empty);
        uint256 keeperEthAfter = address(this).balance;
        uint256 keeperUsdcAfter = _settlementBalance(address(this));

        assertEq(
            keeperEthAfter - keeperEthBefore, 0, "Batch execution should refund unused ETH when no Pyth fee is due"
        );
        assertEq(
            keeperUsdcAfter - keeperUsdcBefore, 400_000, "Keeper should receive capped USDC rewards for both orders"
        );
    }

}

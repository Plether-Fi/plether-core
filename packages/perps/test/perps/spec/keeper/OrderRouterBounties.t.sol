// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterBountiesTest is OrderRouterTestBase {

    using stdStorage for StdStorage;

    function test_CloseCommit_AcceptsPositionMarginBackedBountyWhenFullyUtilized() public {
        _startRecordingLogs();
        address trader = address(0x334);
        address account = trader;
        address counterparty = address(0x335);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 50_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(account);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore - router.closeOrderExecutionBountyUsdc(), "bounty reclassification is exact");
        assertEq(router.pendingOrderCounts(account), 1, "accepted close enters FIFO");
        assertEq(router.nextCommitId(), 2, "accepted close consumes one ID");
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "bounty is protected in action reserve"
        );
    }

    function test_CloseCommit_StaleMarkStillAllowsPositionMarginBackedBounty() public {
        _startRecordingLogs();
        address trader = address(0x3341);
        address account = trader;
        address counterparty = address(0x3351);
        address counterpartyAccount = counterparty;

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 1000e6, 1e8);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 50_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(account), 0, "setup must fully consume free settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(account);
        assertEq(engine.lastMarkPrice(), 1e8, "setup should leave a stored mark price");

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertLe(
            marginAfter,
            marginBefore - router.closeOrderExecutionBountyUsdc(),
            "commit collects carry and reserves its bounty"
        );
        assertEq(router.pendingOrderCounts(account), 1, "accepted stale-mark close queues");
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "accepted close protects its bounty"
        );
    }

    function test_AlignedPartialClose_FreeBackedBountyPaysKeeper() public {
        _startRecordingLogs();
        address trader = address(0x340);
        address account = trader;
        address counterparty = address(0x341);
        address counterpartyAccount = counterparty;

        uint256 depth = 5_000_000 * 1e6;
        _fundTrader(trader, 55_000e6);
        _fundTrader(counterparty, 500_000e6);
        _open(counterpartyAccount, CfdTypes.Side.SHORT, 500_000e18, 50_000e6, 1e8, depth);

        uint256 positionSize = 1100e18;
        uint256 partialCloseSize = 1000e18;
        _open(account, CfdTypes.Side.LONG, positionSize, 50_000e6, 1e8, depth);

        uint256 freeSettlementBeforeCommit = _freeSettlementUsdc(account);
        assertGt(freeSettlementBeforeCommit, 200_000, "setup must leave free settlement to back the bounty");
        assertEq(usdc.balanceOf(trader), 0, "trader wallet should start empty after depositing into the clearinghouse");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, partialCloseSize, 0, 0, true);

        assertEq(
            _freeSettlementUsdc(account),
            freeSettlementBeforeCommit - 200_000,
            "commit should temporarily seize the close bounty from free settlement"
        );

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        uint256 keeperBefore = _settlementBalance(address(this));
        router.executeOrder(1, empty);

        assertGt(
            _freeSettlementUsdc(account),
            freeSettlementBeforeCommit - 200_000,
            "successful partial close should release proportional PnL pledge into free settlement"
        );
        assertEq(usdc.balanceOf(trader), 0, "free-backed bounty refund should not escape to the trader wallet");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "keeper should receive the free-backed bounty as clearinghouse credit"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(account);
        assertEq(remainingSize, CfdTypes.SIZE_QUANTUM, "partial close should preserve one exact residual lot");
    }

    function test_QueueEconomics_MixedHeadOrdersPayExecutorAcrossCloseFailuresAndSuccesses() public {
        _startRecordingLogs();
        address carol = address(0x558);
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
        _fundTrader(bob, 5000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 2e8, false);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory batchData = _mockPythUpdateData();
        uint256 executorBefore = _settlementBalance(address(this));
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 10);
        router.executeOrderBatch(4, batchData);

        uint256 executorReward = _settlementBalance(address(this)) - executorBefore;
        assertEq(
            executorReward,
            600_000,
            "Current queue economics pay the executor for all three terminal head outcomes in this mixed sequence"
        );
        assertEq(
            router.nextExecuteId(),
            0,
            "mixed failed and successful heads should clear the failed head and drain the queue"
        );

        (uint256 carolSize,,,,,,) = engine.positions(carolAccount);
        assertEq(carolSize, 10_000 * 1e18, "valid tail order should still execute after mixed heads");
    }

}

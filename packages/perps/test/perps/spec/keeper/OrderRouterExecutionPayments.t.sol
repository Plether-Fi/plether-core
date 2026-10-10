// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterExecutionPaymentsTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_PostCommitDegradedModePaysClearerBounty() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);

        _setDegradedModeForTest();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = _settlementBalance(address(this));
        address aliceAccount = alice;
        uint256 aliceSettlementBefore = clearinghouse.balanceUsdc(aliceAccount);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Order should fail once degraded mode latches");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Keeper should receive bounty on protocol-state failure under current policy"
        );
        assertEq(
            aliceSettlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Trader should pay the reserved bounty under current policy"
        );
    }

    function test_CommitOrder_RevertsOnPredictableSkewInvalidation() public {
        _startRecordingLogs();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictableSolvencyInvalidation() public {
        _startRecordingLogs();
        address shortTrader = address(0xC333);
        address shortAccount = shortTrader;

        _fundTrader(shortTrader, 50_000e6);
        _open(shortAccount, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);
        _fundTrader(alice, 40_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 350_000e18, 35_000e6, 1e8, false);
    }

    function test_PostCommitSkewInvalidationPaysClearerBounty() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        address aliceAccount = alice;
        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceAccount);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Order should fail once post-commit skew exceeds the cap");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Keeper should receive bounty on skew invalidation under current policy"
        );
        assertEq(
            traderSettlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Trader should pay the reserved bounty on skew invalidation"
        );
    }

    function test_PostCommitSolvencyInvalidationPaysClearerBounty() public {
        _startRecordingLogs();
        address shortTrader = address(0xC333);
        address shortAccount = shortTrader;
        address aliceAccount = alice;

        _fundTrader(shortTrader, 50_000e6);
        _open(shortAccount, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);
        _fundTrader(alice, 40_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 350_000e18, 35_000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceAccount);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Order should fail once post-commit solvency is exceeded");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Keeper should receive bounty on solvency invalidation under current policy"
        );
        assertEq(
            traderSettlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Trader should pay the reserved bounty on solvency invalidation"
        );
    }

    function test_PostCommitMarginDrainInvalidationPaysClearerBounty() public {
        _startRecordingLogs();
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, 1e8, false);

        _forcePnlPledgeForMarginDrain(aliceAccount, 1e6);

        uint256 keeperBefore = _settlementBalance(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.warp(7);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000e18, "Order should fail once post-commit margin is drained");
        assertEq(margin, 1e6, "Post-commit state mutation should leave the custody-backed margin state untouched");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Keeper should receive bounty on post-commit margin-drain invalidation as clearinghouse credit"
        );
        assertEq(usdc.balanceOf(alice), 0, "Trader should not receive bounty refund on margin-drain invalidation");
    }

    function test_StaleCachedMark_DoesNotBlockMarginDrainInvalidationExecution() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(SETUP_TIMESTAMP);
        routerAdmin.finalizeRouterConfig();

        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        _forcePnlPledgeForMarginDrain(aliceAccount, 1e6);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        uint64 historicalPublishTime =
            uint64(uint256(pending.commitTime) + router.pletherOracle().orderSettlementWindow());
        uint64 staleMarkTimeBefore = engine.lastMarkTime();
        mockPyth.setAllUniquePrices(
            feedIds, int64(100_000_000), 0, int32(-8), historicalPublishTime, pending.commitTime
        );
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        router.executeOrder(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000e18, "Fresh execution should fail softly instead of stale-reverting the live position");
        assertEq(margin, 1e6, "Invalidation should preserve the drained custody-backed margin state");
        assertEq(engine.lastMarkTime(), historicalPublishTime, "Execution should push the resolved mark before release");
        assertLt(staleMarkTimeBefore, engine.lastMarkTime(), "Execution should advance the stale cached mark");
        assertEq(router.nextExecuteId(), 0, "Execution should clear the pending head instead of stalling on stale mark");
    }

    function test_BatchPostCommitMarginDrainInvalidationPaysClearerBounty() public {
        _startRecordingLogs();
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, 1e8, false);

        _forcePnlPledgeForMarginDrain(aliceAccount, 1e6);

        uint256 keeperBefore = _settlementBalance(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.warp(7);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000e18, "Batch execution should leave the original position untouched");
        assertEq(margin, 1e6, "Batch execution should preserve the drained custody-backed margin state");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Batch clearer should receive bounty on post-commit margin-drain invalidation as clearinghouse credit"
        );
        assertEq(
            usdc.balanceOf(alice), 0, "Batch execution should not refund trader bounty on margin-drain invalidation"
        );
    }

    function test_BatchStaleCachedMark_DoesNotBlockMarginDrainInvalidationExecution() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(SETUP_TIMESTAMP);
        routerAdmin.finalizeRouterConfig();

        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        _forcePnlPledgeForMarginDrain(aliceAccount, 1e6);

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        uint64 historicalPublishTime =
            uint64(uint256(pending.commitTime) + router.pletherOracle().orderSettlementWindow());
        uint64 staleMarkTimeBefore = engine.lastMarkTime();
        mockPyth.setAllUniquePrices(
            feedIds, int64(100_000_000), 0, int32(-8), historicalPublishTime, pending.commitTime
        );
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        router.executeOrderBatch(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000e18, "Batch execution should fail softly instead of stale-reverting the live position");
        assertEq(margin, 1e6, "Batch execution should preserve the drained custody-backed margin state");
        assertEq(
            engine.lastMarkTime(), historicalPublishTime, "Batch execution should push the resolved mark before release"
        );
        assertLt(staleMarkTimeBefore, engine.lastMarkTime(), "Batch execution should advance the stale cached mark");
        assertEq(
            router.nextExecuteId(), 0, "Batch execution should clear the pending head instead of stalling on stale mark"
        );
    }

    function test_BatchPostCommitSkewInvalidationPaysClearerBounty() public {
        _startRecordingLogs();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        address aliceAccount = alice;
        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceAccount);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp));
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Batch execution should leave invalidated order unopened");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Batch execution should pay the clearer on skew invalidation under current policy"
        );
        assertEq(
            traderSettlementBefore - clearinghouse.balanceUsdc(aliceAccount),
            200_000,
            "Batch invalidation should debit the reserved trader bounty"
        );
    }

    function test_ExitedAccount_ExpiredCloseOrderPaysClearerBounty() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _open(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(closeOrderId);
        uint64 historicalPublishTime =
            uint64(uint256(pending.commitTime) + router.pletherOracle().orderSettlementWindow());

        _close(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1e8);

        bytes[] memory empty = _pythUpdateData();
        vm.warp(block.timestamp + 120);
        mockPyth.setAllUniquePrices(feedIds, int64(1e8), 0, int32(-8), historicalPublishTime, pending.commitTime);
        vm.roll(block.number + 1);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.roll(block.number + 1);
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Keeper should recover the full expired close-order bounty"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            0,
            "Expired close-order bounty should not be routed to protocol revenue"
        );
    }

    function test_ExitedAccount_InvalidCloseOrderPaysReservedBounty() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _open(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        _close(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1e8);

        vm.warp(block.timestamp + 6);
        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Invalid close-order failure should pay the reserved clearer bounty"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            0,
            "Invalid close-order failure should not book protocol revenue"
        );
    }

    function test_AlignedPartialClose_OpenPositionFreeBackedBountyPaysKeeper() public {
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

        bytes[] memory empty = _pythUpdateData();
        vm.warp(block.timestamp + 6);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), block.timestamp);
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

    function test_SlippageFailedCloseOrderForfeitsReservedBountyToProtocol() public {
        _startRecordingLogs();
        address aliceAccount = alice;

        _open(aliceAccount, CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 90_000_000, true);

        vm.warp(block.timestamp + 6);
        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            200_000,
            "Terminal close slippage miss should still credit the clearer through the carry-aware keeper settlement path"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            0,
            "Slippage-failed close order should not additionally book protocol revenue in this path"
        );
        assertEq(router.nextExecuteId(), 0, "Terminal close slippage miss should clear the order");
        assertEq(_executionBountyReserve(closeOrderId), 0, "Close bounty should be consumed on terminal failure");
    }

    function test_OlderHistoricalExecutionAfterMarkRefresh_ClearsOrderAndPaysBounty() public {
        _startRecordingLogs();
        vm.warp(1000);
        vm.roll(100);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 0, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        uint64 historicalPublishTime = pending.commitTime + 10;
        uint64 refreshedPublishTime = pending.commitTime + 16;
        mockPyth.setAllPrices(feedIds, int64(120_000_000), int32(-8), refreshedPublishTime);

        vm.warp(refreshedPublishTime);
        router.updateMarkPrice(_pythUpdateData());
        assertEq(engine.lastMarkTime(), refreshedPublishTime, "Setup should advance the cached mark past execution");

        mockPyth.setAllUniquePrices(
            feedIds, int64(100_000_000), 0, int32(-8), historicalPublishTime, pending.commitTime
        );

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, _pythUpdateData());

        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(alice);
        assertEq(size, 10_000 * 1e18, "Historical order should execute even after a fresher mark refresh");
        assertEq(entryPrice, 100_000_000, "Execution should still bind to the historical settlement tick");
        assertEq(engine.lastMarkTime(), refreshedPublishTime, "Bounty credit must not roll back the cached mark");
        assertEq(router.nextExecuteId(), 0, "Executed order should clear the FIFO head");
        assertEq(
            clearinghouse.balanceUsdc(address(this)) - keeperSettlementBefore,
            pending.executionBountyUsdc,
            "Keeper should receive the reserved execution bounty"
        );
    }

}


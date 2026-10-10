// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

contract StaleOrderExpiryTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address spammer = address(0x666);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        assertEq(router.openOrderExecutionBountyBps(), 1);
        assertEq(router.maxOpenOrderExecutionBountyUsdc(), 200_000);
    }

    function test_TargetedExpiryPrunesFiveEarlierOrdersAndPaysEveryBounty() public {
        _runExpiredPrefixCleanup(5, false);
    }

    function test_FreshOrdersNotSkipped() public {
        _startRecordingLogs();
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0);
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 100_000e18, "fresh order must create the requested position");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 1);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Executed));
        _assertNoPendingReservations(alice);
    }

    function test_BatchExpiryPrunesAllOrdersAndPaysEveryBounty() public {
        _runExpiredPrefixCleanup(3, true);
    }

    function test_BatchExecution_PrunesExpiredOrdersInBoundedSlices() public {
        _startRecordingLogs();
        _fundJunior(bob, 1_000_000 * 1e6);

        uint256 traderCount = 13;
        uint256 ordersPerTrader = 5;

        for (uint256 traderIndex = 0; traderIndex < traderCount; traderIndex++) {
            address trader = address(uint160(0xC100 + traderIndex));
            _fundTrader(trader, 10_000 * 1e6);
            for (uint256 orderIndex = 0; orderIndex < ordersPerTrader; orderIndex++) {
                vm.prank(trader);
                router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
            }
        }

        _fundTrader(alice, 50_000 * 1e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(66, empty);

        assertEq(router.nextExecuteId(), 65, "Batch should prune only a bounded number of expired orders per call");

        vm.roll(block.number + 1);
        router.executeOrderBatch(66, empty);
        assertEq(router.nextExecuteId(), 0, "Second batch call should finish pruning the remaining expired orders");
    }

    function test_SetMaxExecutionWindowSeconds_OnlyOwner() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 600;
        vm.prank(spammer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, spammer));
        routerAdmin.proposeRouterConfig(config);

        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        assertEq(router.maxExecutionWindowSeconds(), 600);
    }

    function test_TargetedExpiryPrunesEarlierHeadAndPaysEachBountyOnce() public {
        _runExpiredPrefixCleanup(1, false);
    }

    function test_ExpiredOpenPaysStoredBountyToClearerExactlyOnce() public {
        _startRecordingLogs();
        address localKeeper = address(0x999);
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(spammer, 10_000e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        uint256 cashBefore = usdc.balanceOf(address(clearinghouse));
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        vm.warp(block.timestamp + 301);
        vm.roll(block.number + 1);
        vm.prank(localKeeper);
        router.executeOrder(1, new bytes[](0));
        assertEq(_settlementBalance(spammer), 10_000e6 - 200_000, "only the stored bounty leaves trader settlement");
        assertEq(_settlementBalance(localKeeper), 200_000, "full stored bounty credits the clearer");
        assertEq(_settlementBalance(engine.protocolTreasury()), treasuryBefore, "expiry does not pay the treasury");
        assertEq(usdc.balanceOf(address(clearinghouse)), cashBefore, "expiry transfers internal ownership only");
        assertEq(usdc.balanceOf(address(pool)), poolBefore, "expiry does not route cash to the pool");
        _assertExpiredReceipt(1, spammer, localKeeper);
        _assertNoPendingReservations(spammer);
        _assertExpiryReplayRejected(1, localKeeper, false);
    }

    function _runExpiredPrefixCleanup(
        uint64 earlierCount,
        bool batch
    ) internal {
        _startRecordingLogs();
        address localKeeper = address(0x999);
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(spammer, 10_000e6);
        _fundTrader(alice, 50_000e6);
        for (uint64 i; i < earlierCount; ++i) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        }
        vm.prank(alice);
        uint64 target = router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        uint256 cashBefore = usdc.balanceOf(address(clearinghouse));
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        assertEq(router.getAccountReservations(spammer).committedMarginUsdc, uint256(earlierCount) * 1000e6);
        vm.warp(block.timestamp + 301);
        vm.roll(block.number + 1);
        vm.prank(localKeeper);
        if (batch) {
            router.executeOrderBatch(target, new bytes[](0));
        } else {
            router.executeOrder(target, new bytes[](0));
        }

        assertEq(_settlementBalance(spammer), 10_000e6 - uint256(earlierCount) * 200_000);
        assertEq(_settlementBalance(alice), 50_000e6 - 200_000);
        assertEq(_settlementBalance(localKeeper), uint256(earlierCount + 1) * 200_000, "one credit per expired order");
        assertEq(_settlementBalance(engine.protocolTreasury()), treasuryBefore, "no expiry bounty accrues to protocol");
        assertEq(usdc.balanceOf(address(clearinghouse)), cashBefore, "clearinghouse cash remains physically backed");
        assertEq(usdc.balanceOf(address(pool)), poolBefore, "unexecuted positions cannot route pool cash");
        for (uint64 id = 1; id <= target; ++id) {
            _assertExpiredReceipt(id, id == target ? alice : spammer, localKeeper);
        }
        _assertNoPendingReservations(spammer);
        _assertNoPendingReservations(alice);
        (uint256 spammerSize,,,,,,) = engine.positions(spammer);
        (uint256 aliceSize,,,,,,) = engine.positions(alice);
        assertEq(spammerSize, 0, "expired prefix cannot open a position");
        assertEq(aliceSize, 0, "expired target cannot open a position");
        _assertExpiryReplayRejected(target, localKeeper, batch);
    }

    function _assertExpiredReceipt(
        uint64 id,
        address account,
        address localKeeper
    ) internal {
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), id);
        assertEq(outcome.account, account);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Expired));
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.Paid));
        assertEq(outcome.executor, localKeeper);
        assertEq(outcome.bountyRecipient, localKeeper);
        assertEq(outcome.bountyUsdc, 200_000, "configured one-bps bounty is capped at 0.2 USDC");
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(id);
        assertEq(pending.committedMarginUsdc, 0);
        assertEq(pending.executionBountyUsdc, 0);
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(0));
    }

    function _assertNoPendingReservations(
        address account
    ) internal view {
        IOrderRouterAccounting.AccountReservationView memory reserves = router.getAccountReservations(account);
        assertEq(reserves.committedMarginUsdc, 0);
        assertEq(reserves.executionBountyUsdc, 0);
        assertEq(reserves.pendingOrderCount, 0);
        assertEq(router.accountHeadOrderId(account), 0);
    }

    function _assertExpiryReplayRejected(
        uint64 id,
        address localKeeper,
        bool batch
    ) internal {
        assertEq(router.nextExecuteId(), 0, "all selected orders are terminal");
        uint256 keeperBefore = _settlementBalance(localKeeper);
        bytes32 hashBefore = router.lifecycleBook().terminalOutcome(id).receiptHash;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        vm.prank(localKeeper);
        if (batch) {
            router.executeOrderBatch(id, new bytes[](0));
        } else {
            router.executeOrder(id, new bytes[](0));
        }
        assertEq(_settlementBalance(localKeeper), keeperBefore, "terminal order cannot pay twice");
        assertEq(
            router.lifecycleBook().terminalOutcome(id).receiptHash, hashBefore, "terminal receipt remains immutable"
        );
    }

}

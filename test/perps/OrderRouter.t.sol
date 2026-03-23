// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract OrderRouterTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    function test_UnbrickableQueue_OnEngineRevert() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        juniorVault.withdraw(1_000_000 * 1e6, bob, bob);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory emptyPayload;
        vm.roll(block.number + 1);
        router.executeOrder(1, emptyPayload);

        assertEq(router.nextExecuteId(), 0, "Terminal engine reverts should clear the queue to the zero sentinel");

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should not exist");

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            9999 * 1e6,
            "Only the reserved execution bounty should leave Alice's balance"
        );
    }

    function test_WithdrawalFirewall() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperUsdcBefore = usdc.balanceOf(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(_sideMaxProfit(CfdTypes.Side.BULL), 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 20_000_000, "Protocol should still retain the full 4 bps execution fee");
        assertEq(
            usdc.balanceOf(address(this)) - keeperUsdcBefore, 1e6, "Keeper should receive the 1 USDC capped reward"
        );
        assertGt(freeUsdc, 949_000 * 1e6, "Free USDC should be ~$950k (pool - maxLiab - fees)");
        assertLt(freeUsdc, 951_000 * 1e6, "Free USDC bounded above");

        uint256 bobMaxWithdraw = juniorVault.maxWithdraw(bob);
        assertEq(bobMaxWithdraw, freeUsdc, "LP should only be able to withdraw unencumbered capital");
    }

    function test_IncreaseOrder_UsesUnlockedPositionMarginToPayTradeCost() public {
        address trader = address(0xC444);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 sizeDelta = 3334e18;
        uint256 marginDelta = 110e6;
        uint256 executionBountyUsdc = router.quoteOpenOrderExecutionBountyUsdc(sizeDelta);

        _fundTrader(trader, marginDelta + executionBountyUsdc);
        _open(accountId, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8);

        assertEq(
            clearinghouse.getFreeSettlementBalanceUsdc(accountId),
            executionBountyUsdc,
            "setup must leave only the future execution bounty as free settlement"
        );

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, sizeDelta, 0, 1e8, false);

        assertEq(
            clearinghouse.getFreeSettlementBalanceUsdc(accountId),
            0,
            "commit should move the only free settlement into bounty escrow"
        );

        uint256 keeperBefore = usdc.balanceOf(address(this));
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(
            size, sizeDelta * 2, "valid increase should execute even when free settlement is zero at execution time"
        );
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            executionBountyUsdc,
            "keeper should receive the reserved execution bounty after successful execution"
        );
    }

    function test_ZeroSizeCommit_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__ZeroSize.selector);
        router.commitOrder(CfdTypes.Side.BULL, 0, 500 * 1e6, 1e8, false);
    }

    function test_ExecuteNonPendingOrder_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        vm.roll(10);
        router.executeOrder(1, empty);
    }

    function test_ExecuteOrder_SkipsFailedHeadEvenWhenExpirationDisabled() public {
        address other = address(0x333);
        bytes32 otherId = bytes32(uint256(uint160(other)));

        _fundTrader(other, 350e6);
        _open(otherId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 1, head
        vm.prank(other);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, type(uint256).max, false); // order 2, non-head
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 3, next live order

        vm.prank(other);
        clearinghouse.withdraw(otherId, 70e6);

        vm.prank(address(this));
        router.proposeMaxOrderAge(0);
        vm.warp(block.timestamp + router.TIMELOCK_DELAY());
        vm.prank(address(this));
        router.finalizeMaxOrderAge();

        bytes[] memory pythPrice = new bytes[](1);
        pythPrice[0] = abi.encode(uint256(102_500_000));
        vm.deal(other, 10 ether);
        vm.prank(other);
        router.executeLiquidation{value: 0}(otherId, pythPrice);

        assertEq(router.nextExecuteId(), 1, "Liquidating a non-head account should not advance the global head");

        assertEq(
            router.nextExecuteId(),
            1,
            "Liquidation of a non-head order should leave the head pointer unchanged initially"
        );

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 3, "Liquidation should already have cleared the invalidated non-head order");

        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        assertEq(router.nextExecuteId(), 0, "Single-order execution should clear the queue to the zero sentinel when exhausted");
    }

    function test_StrictFIFO_OutOfOrder_Reverts() public {
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__FIFOViolation.selector);
        vm.roll(10);
        router.executeOrder(2, empty);
    }

    function test_MultiPendingOrders_DoNotCorruptLockedMarginOnFail() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 500 * 1e6, 2e8, false);
        vm.stopPrank();

        assertEq(clearinghouse.lockedMarginUsdc(accountId), 1500 * 1e6, "Both committed margins should be locked");

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (, uint256 posMargin,,,,,,) = engine.positions(accountId);
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
            posMargin + 500 * 1e6,
            "Lock should preserve pending committed margin for order 2"
        );
        assertEq(router.committedMargins(1), 0, "Order 1 committed margin must be cleared on success");

        vm.roll(10);
        router.executeOrder(2, empty);

        (, uint256 posMarginAfter,,,,,,) = engine.positions(accountId);
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
            posMarginAfter,
            "Failed order 2 should only unlock its own committed margin"
        );
        assertEq(router.committedMargins(2), 0, "Order 2 committed margin must be cleared on failure");
    }

    function test_CommitOrder_RevertsWhenPendingOrderCountHitsCap() public {
        uint256 limit = router.MAX_PENDING_ORDERS();

        vm.startPrank(alice);
        for (uint256 i = 0; i < limit; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 100e6, 1e8, false);
        }
        vm.expectRevert(OrderRouter.OrderRouter__TooManyPendingOrders.selector);
        router.commitOrder(CfdTypes.Side.BULL, 1000e18, 100e6, 1e8, false);
        vm.stopPrank();
    }

    function test_AccountEscrowView_TracksPendingOrders() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(escrow.committedMarginUsdc, 1000 * 1e6, "Escrow view should sum committed margin");
        assertEq(escrow.executionBountyUsdc, 2_000_000, "Open and close orders should both escrow execution bounties");
        assertEq(escrow.pendingOrderCount, 2, "Escrow view should count queued orders");
    }

    function test_OrderRecord_UnifiesPendingState() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        OrderRouter.OrderRecord memory record = router.getOrderRecord(1);
        assertEq(uint256(record.status), uint256(OrderRouter.OrderStatus.Pending));
        assertEq(record.core.orderId, 1);
        assertEq(record.core.accountId, bytes32(uint256(uint160(alice))));
        assertEq(router.committedMargins(1), 1000 * 1e6);
        assertEq(record.executionBountyUsdc, 1_000_000);
        assertEq(record.nextPendingOrderId, 0);
        assertEq(record.prevPendingOrderId, 0);
        assertEq(record.nextMarginOrderId, 0);
        assertEq(record.prevMarginOrderId, 0);
        assertTrue(record.inMarginQueue, "Positive-margin pending order should advertise margin-queue membership");
    }

    function test_OrderRecord_PreservesExecutedLifecycle() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        OrderRouter.OrderRecord memory record = router.getOrderRecord(1);
        assertEq(uint256(record.status), uint256(OrderRouter.OrderStatus.Executed));
        assertEq(record.core.orderId, 1, "Terminal record should keep immutable order metadata");
        assertEq(router.committedMargins(1), 0, "Executed order should clear committed margin escrow");
        assertEq(record.executionBountyUsdc, 0, "Executed order should clear execution bounty escrow");
        assertFalse(record.inMarginQueue, "Executed order should not remain linked in the margin queue");
    }

    function test_GetAccountOrderSummary_ReturnsAggregateOrderState() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        vm.stopPrank();

        OrderRouter.AccountOrderSummary memory summary = router.getAccountOrderSummary(accountId);
        assertEq(summary.pendingOrderCount, 2);
        assertEq(summary.committedMarginUsdc, 1000 * 1e6);
        assertEq(summary.executionBountyUsdc, 2_000_000);
        assertTrue(summary.hasTerminalCloseQueued);
    }

    function test_CloseCommit_ReservesPrefundedKeeperBounty() public {
        address trader = address(0x333);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 1001e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 1000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        assertEq(router.executionBountyReserves(1), 1_000_000, "Close orders should pre-seize the flat router bounty");
    }

    function test_CloseCommit_CanReserveKeeperBountyFromPositionMarginWhenFullyUtilized() public {
        address trader = address(0x334);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x335);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 1000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 50_000e18, 50_000e6, 1e8);

        assertEq(clearinghouse.getFreeSettlementBalanceUsdc(accountId), 0, "setup must fully consume free settlement");
        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,,) = engine.positions(accountId);
        assertEq(router.executionBountyReserves(1), 1_000_000, "Close orders should still escrow full bounty");
        assertEq(marginAfter, marginBefore - 1_000_000, "Close bounty should fall back to active margin");
        assertEq(usdc.balanceOf(address(router)), 1_000_000, "Router should custody the close bounty after fallback");
    }

    function test_ReserveCloseOrderExecutionBounty_RevertsWhenMarginBackedBountyWouldBreakMaintenance() public {
        address trader = address(0x336);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x337);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 1000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 50_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_000_000, uint64(block.timestamp));

        assertEq(clearinghouse.getFreeSettlementBalanceUsdc(accountId), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));
    }

    function test_InvalidClose_DoesNotPayKeeperFromMarginBackedBounty() public {
        address trader = address(0x338);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x339);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        uint256 depth = 5_000_000 * 1e6;
        _fundTrader(trader, 50_000e6);
        _fundTrader(counterparty, 500_000e6);
        _open(counterpartyId, CfdTypes.Side.BEAR, 500_000e18, 50_000e6, 1e8, depth);

        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(accountId, CfdTypes.Side.BULL, minSize, 50_000e6, 1e8, depth);

        (, uint256 marginBeforeCommit,,,,,,) = engine.positions(accountId);
        assertEq(clearinghouse.getFreeSettlementBalanceUsdc(accountId), 0, "setup must fully consume free settlement");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, minSize - 1, 0, 0, true);

        (, uint256 marginAfterCommit,,,,,,) = engine.positions(accountId);
        assertEq(marginAfterCommit, marginBeforeCommit - 1e6, "commit should temporarily reserve the bounty from position margin");

        uint256 keeperBefore = usdc.balanceOf(address(this));
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (, uint256 marginAfterExecute,,,,,,) = engine.positions(accountId);
        assertEq(marginAfterExecute, marginBeforeCommit, "failed invalid close should refund margin-backed bounty to position margin");
        assertEq(usdc.balanceOf(address(this)) - keeperBefore, 0, "keeper should not receive a refunded margin-backed bounty");
        assertEq(router.executionBountyReserves(1), 0, "failed close should clear router bounty escrow");
        assertEq(uint256(router.getOrderRecord(1).status), uint256(OrderRouter.OrderStatus.Failed), "invalid close should finalize as failed");
    }

    function test_GetPendingOrdersForAccount_ReturnsQueuedOrderDetails() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        vm.stopPrank();

        OrderRouter.PendingOrderView[] memory pending = router.getPendingOrdersForAccount(accountId);
        assertEq(pending.length, 2);
        assertEq(pending[0].orderId, 1);
        assertFalse(pending[0].isClose);
        assertEq(pending[0].committedMarginUsdc, 1000 * 1e6);
        assertEq(pending[0].executionBountyUsdc, 1_000_000);
        assertEq(pending[1].orderId, 2);
        assertTrue(pending[1].isClose);
        assertEq(pending[1].executionBountyUsdc, 1_000_000);
    }

    function test_PendingOrderPointers_LinkPerAccountInFIFOOrder() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 bobId = bytes32(uint256(uint160(bob)));

        _fundTrader(bob, 10_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BEAR, 20_000 * 1e18, 2000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 500 * 1e6, 1e8, false);

        assertEq(router.pendingHeadOrderId(aliceId), 1, "Alice head should point to her first queued order");
        assertEq(router.pendingTailOrderId(aliceId), 3, "Alice tail should point to her last queued order");
        assertEq(router.pendingHeadOrderId(bobId), 2, "Bob head should be isolated from Alice queue state");
        assertEq(router.pendingTailOrderId(bobId), 2, "Bob tail should equal his only queued order");

        OrderRouter.PendingOrderView[] memory alicePending = router.getPendingOrdersForAccount(aliceId);
        assertEq(alicePending.length, 2, "Alice should see only her own queued orders");
        assertEq(alicePending[0].orderId, 1, "Alice queue should preserve per-account FIFO order");
        assertEq(alicePending[1].orderId, 3, "Alice tail should remain reachable after foreign inserts");
    }

    function test_MarginQueue_LinksOnlyOrdersWithPositiveCommittedMargin() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        assertEq(
            router.marginHeadOrderId(accountId), 1, "Margin queue head should start at the first positive-margin order"
        );
        assertEq(
            router.marginTailOrderId(accountId), 3, "Margin queue tail should end at the last positive-margin order"
        );
        assertTrue(router.isInMarginQueue(1), "Positive-margin open should be linked into the margin queue");
        assertFalse(router.isInMarginQueue(2), "Close order should not enter the margin queue");
        assertTrue(router.isInMarginQueue(3), "Later positive-margin open should be linked into the margin queue");
    }

    function test_NoteCommittedMarginConsumed_PartialConsumePreservesMarginQueueMembership() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(address(engine));
        clearinghouse.consumeAccountOrderReservations(accountId, 400 * 1e6);

        vm.prank(address(engine));
        router.syncMarginQueue(accountId);

        assertEq(router.committedMargins(1), 600 * 1e6, "Partial consumption should leave residual committed margin");
        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            600 * 1e6,
            "Reservation residual should match router-side committed margin residual"
        );
        assertEq(router.marginHeadOrderId(accountId), 1, "Partially consumed order should remain at margin-queue head");
        assertEq(router.marginTailOrderId(accountId), 1, "Single residual order should remain at margin-queue tail");
        assertTrue(router.isInMarginQueue(1), "Partially consumed order should remain linked in the margin queue");
    }

    function test_NoteCommittedMarginConsumed_DrainsHeadExposureWithoutWalkingQueue() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        vm.prank(address(engine));
        clearinghouse.consumeAccountOrderReservations(accountId, 1000 * 1e6);

        vm.prank(address(engine));
        router.syncMarginQueue(accountId);

        assertEq(router.committedMargins(1), 0, "First margin-paying order should be fully drained");
        assertEq(
            router.committedMargins(3), 250 * 1e6, "Later positive-margin order should retain its committed margin"
        );
        assertEq(
            router.marginHeadOrderId(accountId),
            3,
            "Account margin head should advance once zero-remaining reservations are pruned"
        );
        assertEq(
            router.marginTailOrderId(accountId),
            3,
            "Margin queue tail should still point at the trailing positive-margin order"
        );
        assertFalse(
            router.isInMarginQueue(1),
            "Drained order should be pruned from the margin queue once reservations are consumed"
        );
        assertFalse(router.isInMarginQueue(2), "Close orders should remain outside the margin queue");
        assertTrue(router.isInMarginQueue(3), "Residual positive-margin order should remain in the margin queue");
        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            0,
            "First reservation should be fully consumed alongside router head exposure"
        );
        assertEq(
            clearinghouse.getOrderReservation(3).remainingAmountUsdc,
            250 * 1e6,
            "Later reservation should retain its committed margin"
        );
    }

    function test_NoteCommittedMarginConsumed_ReconcilesPerOrderReleaseAfterPartialBucketConsumption() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 25 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 25 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeSettlement);

        IMarginClearinghouse.LockedMarginBuckets memory beforeBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        assertEq(beforeBuckets.committedOrderMarginUsdc, 50 * 1e6, "Setup must lock both committed-order buckets");

        vm.prank(address(engine));
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 1;
        reservationIds[1] = 2;
        clearinghouse.consumeCloseLoss(accountId, reservationIds, 30 * 1e6, 0, true, address(engine));

        vm.prank(address(engine));
        router.syncMarginQueue(accountId);

        assertEq(router.committedMargins(1), 0, "First order should be fully consumed before release");
        assertEq(
            router.committedMargins(2), 20 * 1e6, "Second order should retain only the unconsumed committed margin"
        );

        bytes[] memory empty;
        router.executeOrder(1, empty);
        router.executeOrder(2, empty);

        IMarginClearinghouse.LockedMarginBuckets memory afterBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        IMarginClearinghouse.OrderReservation memory firstReservation = clearinghouse.getOrderReservation(1);
        IMarginClearinghouse.OrderReservation memory secondReservation = clearinghouse.getOrderReservation(2);
        assertEq(
            afterBuckets.committedOrderMarginUsdc,
            0,
            "Per-order release must reconcile with partially consumed committed-order buckets"
        );
        assertEq(router.committedMargins(1), 0, "First order committed margin should stay zero after release");
        assertEq(
            router.committedMargins(2),
            0,
            "Second order committed margin should release only the residual tracked amount"
        );
        assertEq(uint256(firstReservation.status), uint256(IMarginClearinghouse.ReservationStatus.Consumed));
        assertEq(uint256(secondReservation.status), uint256(IMarginClearinghouse.ReservationStatus.Released));
    }

    function test_CommitOrder_DualWritesReservationAndRouterCommittedMarginState() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 250 * 1e6, 1e8, false);

        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(1);
        IMarginClearinghouse.AccountReservationSummary memory summary =
            clearinghouse.getAccountReservationSummary(accountId);

        assertEq(
            router.committedMargins(1), 250 * 1e6, "Router should still track the per-order committed margin locally"
        );
        assertEq(
            reservation.remainingAmountUsdc,
            250 * 1e6,
            "Clearinghouse reservation should mirror the router committed margin"
        );
        assertEq(
            summary.activeCommittedOrderMarginUsdc,
            250 * 1e6,
            "Reservation summary should match the live committed-order bucket"
        );
        assertEq(
            summary.activeReservationCount,
            1,
            "Exactly one active reservation should exist after a single open-order commit"
        );
    }

    function test_ReleaseCommittedMargin_NoopsWhenReservationAlreadyConsumed() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 25 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 25 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeSettlement);

        vm.prank(address(engine));
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 1;
        reservationIds[1] = 2;
        clearinghouse.consumeCloseLoss(accountId, reservationIds, 30 * 1e6, 0, true, address(engine));

        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            0,
            "Consumed reservation should remain zero after execution cleanup"
        );
    }

    function test_ExecuteOrder_UnlinksMarginQueueHeadAndPreservesResidualTail() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 250 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            router.marginHeadOrderId(accountId),
            2,
            "Executing the margin-queue head should advance to the surviving residual order"
        );
        assertEq(
            router.marginTailOrderId(accountId),
            2,
            "Executing the margin-queue head should leave the residual order as tail"
        );
        assertFalse(router.isInMarginQueue(1), "Executed order should be removed from the margin queue");
        assertTrue(router.isInMarginQueue(2), "Residual positive-margin order should remain linked");
    }

    function test_ExecuteOrder_UnlinksAccountHeadWithoutAffectingForeignQueuePointers() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 bobId = bytes32(uint256(uint160(bob)));

        _fundTrader(bob, 10_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BEAR, 20_000 * 1e18, 2000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.pendingHeadOrderId(aliceId), 3, "Executing Alice head should advance her account-local head");
        assertEq(router.pendingTailOrderId(aliceId), 3, "Alice tail should collapse to her surviving queued order");
        assertEq(router.pendingHeadOrderId(bobId), 2, "Foreign account head should stay unchanged");
        assertEq(router.pendingTailOrderId(bobId), 2, "Foreign account tail should stay unchanged");

        OrderRouter.PendingOrderView[] memory alicePending = router.getPendingOrdersForAccount(aliceId);
        assertEq(alicePending.length, 1, "Only Alice's trailing queued order should remain");
        assertEq(alicePending[0].orderId, 3, "Alice residual queue should still be reachable after execution");
    }

    function test_BatchExecution_AllSucceed() public {
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.deal(carol, 10 ether);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), 10_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperBefore = usdc.balanceOf(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 0, "Empty global queue should clear to zero sentinel after processing");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 15_000 * 1e18, "Alice should have 15k BULL");

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 carolSize,,,,,,,) = engine.positions(carolId);
        assertEq(carolSize, 10_000 * 1e18, "Carol should have 10k BEAR");

        uint256 keeperAfter = usdc.balanceOf(address(this));
        assertEq(keeperAfter - keeperBefore, 2_500_000, "Keeper should receive min(1 bp, 1 USDC) per successful order");
    }

    function test_BatchExecution_MixedResults() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.5e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 2, "Batch should stop with the retryable middle order still pending at the head");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 15_000 * 1e18, "Orders 1 and 3 succeed, order 2 cancelled");
    }

    function test_BatchExecution_NoOrders_Reverts() public {
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(0, empty);
    }

    function test_BatchExecution_EmptyQueueAfterDrain_RevertsBeforeOracleWork() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        assertEq(router.nextExecuteId(), 0, "Queue should be empty after draining the only batch order");
        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrderBatch(1, empty);
    }

    function test_BatchExecution_UncommittedMaxId_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__MaxOrderIdNotCommitted.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(5, empty);
    }

    function test_BatchExecution_SingleETHTransfer() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperEthBefore = address(this).balance;
        uint256 keeperUsdcBefore = usdc.balanceOf(address(this));
        router.executeOrderBatch{value: 0.1 ether}(2, empty);
        uint256 keeperEthAfter = address(this).balance;
        uint256 keeperUsdcAfter = usdc.balanceOf(address(this));

        assertEq(
            keeperEthAfter - keeperEthBefore, 0, "Batch execution should refund unused ETH when no Pyth fee is due"
        );
        assertEq(
            keeperUsdcAfter - keeperUsdcBefore, 1_500_000, "Keeper should receive capped USDC rewards for both orders"
        );
    }

    function test_BoundedQueue_BatchClearsFailedOrdersAndExecutesTail() public {
        address spammer = address(0x444);
        address carol = address(0x555);
        bytes32 carolId = bytes32(uint256(uint160(carol)));

        usdc.mint(spammer, 100_000 * 1e6);
        vm.startPrank(spammer);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(spammer))), 100_000 * 1e6);
        vm.stopPrank();

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolId, 20_000 * 1e6);
        vm.stopPrank();

        uint256 spamCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 100 * 1e6, 2e8, false);
        }

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        uint256 gasBefore = gasleft();
        router.executeOrderBatch(uint64(spamCount + 1), empty);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(router.nextExecuteId(), 1, "batch should execute the tail order without requiring the adversarial retryable head to clear");
        (uint256 size,,,,,,,) = engine.positions(carolId);
        assertEq(size, 10_000 * 1e18, "tail order should still execute after many failed head orders");
        assertLt(gasUsed, 40_000_000, "adversarial batch path gas budget regressed");
    }

    function test_PoisonedHead_CloseSlippageSkipsToTailAndLetsTailExecute() public {
        address carol = address(0x556);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 carolId = bytes32(uint256(uint160(carol)));

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolId, 20_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        _fundTrader(alice, 2 * 1e6);
        _fundTrader(bob, 200 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 500 * 1e6, 1e8, false);

        vm.roll(block.number + 1);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 2, "retryable slippage miss must leave the head order pending");
        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
        (uint256 carolSize,,,,,,,) = engine.positions(carolId);
        assertEq(aliceSize, 10_000 * 1e18, "slippage-failed close must leave the live position intact");
        assertEq(carolSize, 5000 * 1e18, "tail order should execute once the retryable head is skipped to the tail");

        bytes[] memory betterPrice = new bytes[](1);
        betterPrice[0] = abi.encode(uint256(90_000_000));
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, betterPrice);

        assertEq(router.nextExecuteId(), 0, "once marketable again, batch should consume the retried head and clear the queue");
    }

    function test_BoundedForeignQueue_FullCloseExecutesAndLeavesTailLive() public {
        address spammer = address(0x557);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        usdc.mint(spammer, 100_000 * 1e6);
        vm.startPrank(spammer);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(spammer))), 100_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        uint256 spamCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BEAR, 1000 * 1e18, 100 * 1e6, 2e8, false);
        }

        vm.roll(block.number + 1);
        uint256 gasBefore = gasleft();
        router.executeOrder(2, empty);
        uint256 gasUsed = gasBefore - gasleft();

        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "terminal close should still succeed with a bounded foreign queue behind it");
        assertEq(router.nextExecuteId(), 3, "queue head should advance after the full close");
        assertLt(gasUsed, 40_000_000, "terminal close gas budget regressed");

        vm.roll(block.number + 1);
        router.executeOrder(3, empty);
        assertEq(router.nextExecuteId(), 4, "tail queue should remain live after terminal close cleanup");
    }

    function test_QueueEconomics_MixedHeadOrdersPayExecutorAcrossCloseFailuresAndSuccesses() public {
        address carol = address(0x558);
        bytes32 carolId = bytes32(uint256(uint160(carol)));

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolId, 20_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        _fundTrader(alice, 2 * 1e6);
        _fundTrader(bob, 200 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 100 * 1e6, 2e8, false);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        uint256 executorBefore = usdc.balanceOf(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(4, empty);

        uint256 executorReward = usdc.balanceOf(address(this)) - executorBefore;
        assertEq(executorReward, 1_000_000, "Retryable invalid heads should not pay the executor while the valid tail still executes");
        assertEq(router.nextExecuteId(), 2, "mixed failed and successful heads should leave the retryable head pending for a later keeper");

        (uint256 carolSize,,,,,,,) = engine.positions(carolId);
        assertEq(carolSize, 10_000 * 1e18, "valid tail order should still execute after mixed heads");
    }

}

contract OrderRouterPythTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        vm.warp(1);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function test_MevCheck_RevertsInsteadOfCancelling() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order stays in queue for honest keeper");
    }

    function test_SameBlockExecution_Reverts() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order stays in queue when executed in same block");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        uint256 keeperUsdcBefore = usdc.balanceOf(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        assertEq(
            clearinghouse.balanceUsdc(accountId), 9999 * 1e6, "Reserved execution bounty should be charged on failure"
        );
        assertEq(
            usdc.balanceOf(address(this)) - keeperUsdcBefore,
            0,
            "Retryable slippage misses should preserve escrow instead of paying the executor"
        );
        assertEq(
            engine.accumulatedFeesUsdc(), 0, "Failed binding open-order bounty should not be routed to protocol revenue"
        );
        assertEq(router.nextExecuteId(), 1, "Retryable slippage miss should leave the order pending at the head");
        assertEq(router.executionBountyReserves(1), 1e6, "Retryable slippage miss should keep the bounty escrowed");
    }

    function _setDegradedModeForTest() internal {
        bytes32 slotValue = vm.load(address(engine), bytes32(uint256(19)));
        vm.store(address(engine), bytes32(uint256(19)), slotValue | bytes32(uint256(1)));
    }

    function test_PostCommitDegradedModeRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _setDegradedModeForTest();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once degraded mode latches");
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            0,
            "Keeper should not receive bounty on protocol-state failure"
        );
        assertEq(usdc.balanceOf(alice), 1e6, "Trader should receive bounty refund on degraded-mode failure");
    }

    function test_PostCommitSkewInvalidationRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once post-commit skew exceeds the cap");
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore, 0, "Keeper should not receive bounty on skew invalidation"
        );
        assertEq(usdc.balanceOf(alice), 1e6, "Trader should receive bounty refund on skew invalidation");
    }

    function test_PostCommitSolvencyInvalidationRefundsUserBounty() public {
        address bearTrader = address(0xC333);
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bearTrader, 50_000e6);
        _open(bearId, CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8);
        _fundTrader(alice, 40_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 350_000e18, 35_000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once post-commit solvency is exceeded");
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore, 0, "Keeper should not receive bounty on solvency invalidation"
        );
        assertEq(usdc.balanceOf(alice), 1e6, "Trader should receive bounty refund on solvency invalidation");
    }

    function test_BatchPostCommitSkewInvalidationRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp));
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Batch execution should leave invalidated order unopened");
        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            0,
            "Batch clearer should not receive bounty on skew invalidation"
        );
        assertEq(usdc.balanceOf(alice), 1e6, "Batch execution should refund trader bounty on skew invalidation");
    }

    function test_ExitedAccount_ExpiredCloseOrderPaysClearerBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        _close(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1e8);

        bytes[] memory empty = _pythUpdateData();
        vm.warp(block.timestamp + 120);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        vm.roll(block.number + 1);
        router.executeOrder(closeOrderId, empty);

        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            1e6,
            "Keeper should recover the full expired close-order bounty"
        );
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            0,
            "Expired close-order bounty should not be routed to protocol revenue"
        );
    }

    function test_ExitedAccount_InvalidCloseOrderPaysEscrowedBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        _close(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1e8);

        vm.warp(block.timestamp + 6);
        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        router.executeOrder(closeOrderId, empty);

        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            1e6,
            "Invalid close-order failure should pay the escrowed clearer bounty"
        );
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Invalid close-order failure should not book protocol revenue"
        );
    }

    function test_CloseCommit_RevertsWhenPendingCloseSizeWouldExceedPosition() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 6000 * 1e18, 0, 0, true);
        vm.expectRevert(OrderRouter.OrderRouter__CloseSizeExceedsPosition.selector);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);
        vm.stopPrank();

        assertEq(
            router.pendingCloseSize(aliceId),
            6000 * 1e18,
            "Only the first queued close should count toward pending close size"
        );
    }

    function test_CloseCommit_AllowsPendingOpenPositionExposure() public {
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);
        vm.stopPrank();

        assertEq(router.nextCommitId(), 3, "Close intents should be queueable against pending open exposure");
    }

    function test_StateMachine_StaleRevertPreservesQueueUntilHonestBatchExecutes() public {
        vm.warp(1000);

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BEAR, 8000 * 1e18, 400 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        IOrderRouterAccounting.AccountEscrowView memory beforeEscrow = router.getAccountEscrow(accountId);
        assertEq(beforeEscrow.pendingOrderCount, 2, "Both orders should be queued");

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);
        vm.warp(1000);
        bytes[] memory empty = _pythUpdateData();

        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountEscrowView memory afterRevertEscrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 1, "Non-terminal stale failure must leave the queue untouched");
        assertEq(afterRevertEscrow.pendingOrderCount, 2, "All queued escrow should remain after stale revert");

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1050);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        IOrderRouterAccounting.AccountEscrowView memory finalEscrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 0, "Honest keeper should later consume both queued orders and clear the queue");
        assertEq(finalEscrow.pendingOrderCount, 0, "Escrow should be fully released after terminal execution");
    }

    function test_StateMachine_BatchSkipsRetryableSlippageHeadToTail() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.roll(block.number + 1);
        vm.warp(1050);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory empty = _pythUpdateData();

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1006);
        router.executeOrderBatch(2, empty);

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 2, "Skipped head should move behind the next queued order");
        assertEq(
            escrow.pendingOrderCount,
            2,
            "Later order should remain pending if another non-terminal gate stops the batch"
        );
        assertEq(router.executionBountyReserves(1), 1e6, "Skipped head should retain its execution bounty escrow");
        assertEq(
            router.executionBountyReserves(2),
            1e6,
            "Later order should retain escrow if it remains pending after the skip"
        );
    }

    function test_DeferredPayout_CloseDoesNotBlockLaterQueuedOrders() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 8000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory priceData = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp + 6);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 8000e6);

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), block.timestamp + 6);
        uint256 keeperUsdcBefore = usdc.balanceOf(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, priceData);

        assertEq(router.nextExecuteId(), 0, "Deferred-payout close should not stall the FIFO queue and should drain it when no orders remain");
        assertGt(
            engine.deferredPayoutUsdc(accountId), 0, "Deferred payout should remain recorded after batch execution"
        );
        assertEq(
            engine.deferredClearerBountyUsdc(address(this)),
            0,
            "Close execution should not rely on deferred liquidation bounties"
        );
        assertEq(
            usdc.balanceOf(address(this)) - keeperUsdcBefore,
            1e6,
            "Batch executor should be paid only for the successful close when the failed open tail refunds the user"
        );

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(
            escrow.pendingOrderCount, 0, "Queued orders should be fully consumed even when one close defers payout"
        );
    }

    function testFuzz_StaleOracleRevertPreservesEscrowAndQueue(
        uint64 age
    ) public {
        age = uint64(bound(age, 61, 600));
        vm.warp(2000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2000 - age);

        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 1, "Stale revert should keep queue head pending");
        assertEq(escrow.pendingOrderCount, 1, "Stale revert should preserve escrowed order state");
        assertEq(usdc.balanceOf(address(router)), 1e6, "Router custody should continue escrowing the keeper reserve");
    }

    function testFuzz_SlippageFailurePreservesEscrowAndRequeuesOrder(
        uint256 adverseTarget
    ) public {
        adverseTarget = bound(adverseTarget, 1, 99_999_999);
        vm.warp(3000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, adverseTarget, false);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3006);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 1, "Retryable slippage miss should keep the queue head pending");
        assertEq(escrow.pendingOrderCount, 1, "Retryable slippage miss should preserve pending escrow state");
        assertEq(usdc.balanceOf(address(router)), 1e6, "Keeper reserve should remain escrowed in router custody");
        assertGt(
            router.getOrderRecord(1).retryAfterTimestamp, block.timestamp, "Retryable slippage miss should set cooldown"
        );
    }

    function test_SingleExecute_RevertsDuringRetryCooldown() public {
        vm.warp(3000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 90_000_000, false);

        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3006);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.expectRevert(OrderRouter.OrderRouter__RetryCooldownActive.selector);
        router.executeOrder(1, empty);
    }

    function test_SingleExecute_EmptyQueueRevertsNoOrders() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp + 6));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0, "Queue head should clear to zero sentinel when empty");

        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrder(1, empty);
    }

    function test_SlippageFailedCloseOrderPreservesEscrowedBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.warp(block.timestamp + 6);
        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = usdc.balanceOf(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        router.executeOrder(closeOrderId, empty);

        assertEq(
            usdc.balanceOf(address(this)) - keeperBefore,
            0,
            "Retryable close slippage miss should not pay keeper bounty"
        );
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Slippage-failed close order should not book protocol revenue"
        );
        assertEq(router.nextExecuteId(), closeOrderId, "Retryable close slippage miss should keep the order pending");
        assertEq(
            router.executionBountyReserves(closeOrderId),
            1e6,
            "Close bounty should remain escrowed while order stays pending"
        );
    }

    function test_InsufficientPythFee_Reverts() public {
        vm.warp(1000);
        mockPyth.setFee(1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory data = new bytes[](1);
        data[0] = hex"00";

        vm.warp(1050);
        vm.expectRevert(OrderRouter.OrderRouter__InsufficientPythFee.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, data);
    }

    function test_LiquidationStaleness_15SecBoundary() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2000);

        vm.warp(2016);
        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(accountId, empty);

        vm.warp(2015);
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
    }

    function test_Slippage_OpenDirections() public {
        address trader2 = address(0x444);
        usdc.mint(trader2, 10_000 * 1e6);
        vm.startPrank(trader2);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(trader2))), 10_000 * 1e6);
        vm.stopPrank();

        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "BULL open at favorable price should succeed");

        vm.warp(2000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2006);
        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        bytes32 trader2Id = bytes32(uint256(uint160(trader2)));
        (size,,,,,,,) = engine.positions(trader2Id);
        assertGt(size, 0, "BEAR open at favorable price should succeed");

        vm.warp(3000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3006);
        vm.warp(3050);
        vm.roll(20);
        router.executeOrder(3, empty);

        (size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "BULL open at adverse price should be rejected");

        vm.warp(4000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 4006);
        vm.warp(4050);
        vm.roll(30);
        router.executeOrder(4, empty);

        (size,,,,,,,) = engine.positions(trader2Id);
        assertEq(size, 10_000 * 1e18, "BEAR open at adverse price should be rejected");
    }

    function test_Slippage_CloseOrders_Protected() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertTrue(size > 0, "Position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Close should be rejected by slippage check");
    }

    function test_BatchExecution_MEVCheckPerOrder() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1008);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1010);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        assertEq(router.nextExecuteId(), 2, "Batch breaks at MEV-stale order, leaving it in queue");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "Only order 1 should execute");
    }

    function test_C1_MevDetected_RevertsEntireTx() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order preserved for honest keeper");
        (, uint256 sizeDelta,,,,,,,) = router.orders(1);
        assertEq(sizeDelta, 10_000 * 1e18, "Order should remain pending after MEV revert");
    }

    function test_BatchExecution_StalePrice_Reverts() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1000);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);
    }

    function test_BasketMath_WeightedAverage() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(110_000_000), int32(-8), 1006);
        mockPyth.setPrice(FEED_B, int64(90_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Basket at $1.00 should pass slippage for target $1.00");
    }

    function test_BasketMath_UnequalWeights() public {
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

        (uint256 price, uint256 minPt) = harness.computeBasketPrice();
        assertEq(price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(minPt, 1001, "minPublishTime should be weakest link");
    }

    function test_WeakestLink_Timestamp_MEV() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Weakest-link stale feed reverts, order preserved");
    }

    function test_WeakestLink_Staleness() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1001);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);
    }

    function test_Slippage_ClampedBeforeCheck_BullClose() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "BULL position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(250_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 240_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "BULL close should succeed against clamped price");
    }

}

contract BasketPriceHarness is OrderRouter {

    constructor(
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderRouter(address(1), address(1), _pyth, _feedIds, _quantities, _basePrices, _inversions) {}

    function computeBasketPrice() external view returns (uint256, uint256) {
        return _computeBasketPrice();
    }

}

contract NormalizePythHarness is OrderRouter {

    constructor()
        OrderRouter(
            address(1), address(1), address(0), new bytes32[](0), new uint256[](0), new uint256[](0), new bool[](0)
        )
    {}

    function normalizePythPrice(
        int64 price,
        int32 expo
    ) external pure returns (uint256) {
        return _normalizePythPrice(price, expo);
    }

}

contract NormalizePythFuzzTest is Test {

    NormalizePythHarness harness;

    function setUp() public {
        harness = new NormalizePythHarness();
    }

    function testFuzz_NormalizePythPrice(
        int64 rawPrice,
        int32 expo
    ) public view {
        vm.assume(rawPrice > 0);
        expo = int32(bound(int256(expo), -18, 18));

        uint256 result = harness.normalizePythPrice(rawPrice, expo);

        if (expo == -8) {
            assertEq(result, uint256(uint64(rawPrice)), "Identity at expo=-8");
        }

        if (expo > -8) {
            assertGe(result, uint256(uint64(rawPrice)), "Upscaling must not shrink value");
        }
    }

}

contract OrderRouterLiquidationEscrowTest is BasePerpTest {

    address trader = address(0xC10A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function test_ExecuteLiquidation_ForfeitsEscrowedOpenBountiesWithoutCreditingTraderSettlement() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(address(router)),
            queuedOrderCount * 1e6,
            "Router should custody the shielded open-order bounty escrow"
        );
        assertEq(
            router.pendingOrderCounts(accountId),
            queuedOrderCount,
            "Queued open orders should remain pending before liquidation"
        );

        ICfdEngine.AccountLedgerSnapshot memory snapshotBefore = engine.getAccountLedgerSnapshot(accountId);
        uint256 vaultAssetsBefore = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, 102_500_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(102_500_000));

        router.executeLiquidation(accountId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Liquidation should still clear the underwater position");
        assertEq(
            engine.accumulatedBadDebtUsdc(),
            preview.badDebtUsdc,
            "Liquidation should not improve previewed bad debt by restoring execution escrow"
        );
        assertEq(
            snapshotBefore.executionEscrowUsdc,
            queuedOrderCount * 1e6,
            "Setup must report queued execution escrow outside trader settlement"
        );
        assertEq(
            preview.reachableCollateralUsdc,
            snapshotBefore.terminalReachableUsdc,
            "Preview must exclude queued execution escrow from liquidation reachability"
        );
        assertEq(router.nextExecuteId(), 0, "Liquidation should clear the global queue head when only liquidated-account orders remain");
        assertEq(router.executionBountyReserves(1), 0, "Liquidation should forfeit the first open-order bounty escrow");
        assertEq(
            router.executionBountyReserves(uint64(queuedOrderCount)),
            0,
            "All queued open-order bounty escrow should be cleared"
        );
        assertEq(
            usdc.balanceOf(address(router)), 0, "Router should not retain shielded bounty escrow after liquidation"
        );
        assertEq(pool.excessAssets(), 0, "Forfeited open-order bounty escrow should not remain quarantined as excess");
        assertGe(
            pool.totalAssets(),
            vaultAssetsBefore + queuedOrderCount * 1e6,
            "Forfeited open-order bounty escrow should contribute to canonical vault assets"
        );
    }

    function test_ExecuteLiquidation_ForfeitedEscrowDoesNotRetroactivelySoftenFunding() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 60 days);
        uint64 fundingBefore = engine.lastFundingTime();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));

        vm.recordLogs();
        router.executeLiquidation(accountId, priceData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 fundingUpdatedSig = keccak256("FundingUpdated(int256,int256,uint256)");
        bytes32 protocolInflowSig = keccak256("ProtocolInflowAccounted(address,uint256,uint256)");
        uint256 fundingLogIndex = type(uint256).max;
        uint256 inflowLogIndex = type(uint256).max;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == fundingUpdatedSig && fundingLogIndex == type(uint256).max) {
                fundingLogIndex = i;
            }
            if (
                logs[i].topics[0] == protocolInflowSig && logs[i].emitter == address(pool)
                    && inflowLogIndex == type(uint256).max
            ) {
                inflowLogIndex = i;
            }
        }

        assertEq(
            engine.lastFundingTime(),
            uint64(block.timestamp),
            "liquidation path should sync funding for the elapsed interval"
        );
        assertGt(
            engine.lastFundingTime(), fundingBefore, "liquidation must materialize pending funding before fee booking"
        );
        assertLt(
            fundingLogIndex,
            inflowLogIndex,
            "funding must sync before forfeited escrow is recognized as canonical vault inflow"
        );
    }

    function test_ExecuteLiquidation_ForfeitsEscrowedCloseBountiesBeforeClearingOrders() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 5000e18, 0, 0, true);
        router.commitOrder(CfdTypes.Side.BULL, 5000e18, 0, 0, true);
        clearinghouse.withdraw(accountId, 68e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(router)), 2e6, "Router should custody prefunded close-order bounty escrow");

        ICfdEngine.AccountLedgerSnapshot memory snapshotBefore = engine.getAccountLedgerSnapshot(accountId);
        uint256 vaultAssetsBefore = pool.totalAssets();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(102_500_000));

        router.executeLiquidation(accountId, priceData);

        assertEq(
            snapshotBefore.executionEscrowUsdc,
            2e6,
            "Setup must report queued close-order execution escrow outside trader settlement"
        );
        assertEq(router.pendingOrderCounts(accountId), 0, "Liquidation should clear queued close orders");
        assertEq(router.executionBountyReserves(1), 0, "Liquidation should forfeit the first close-order bounty escrow");
        assertEq(
            router.executionBountyReserves(2), 0, "Liquidation should forfeit the second close-order bounty escrow"
        );
        assertEq(
            usdc.balanceOf(address(router)), 0, "Router should not retain close-order bounty escrow after liquidation"
        );
        assertEq(pool.excessAssets(), 0, "Forfeited close-order bounty escrow should not remain quarantined as excess");
        assertGe(
            pool.totalAssets(),
            vaultAssetsBefore + 2e6,
            "Forfeited close-order bounty escrow should contribute to canonical vault assets"
        );
    }

    function test_ExecuteLiquidation_PreventsPostLiquidationEscrowRecovery() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 350e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = router.MAX_PENDING_ORDERS();
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(102_500_000));
        router.executeLiquidation(accountId, priceData);

        assertEq(
            router.nextExecuteId(),
            0,
            "Liquidation should consume the liquidated account's queued orders and clear the queue to the zero sentinel"
        );

        vm.prank(trader);
        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrderBatch(uint64(queuedOrderCount), priceData);

        assertEq(
            usdc.balanceOf(trader), traderUsdcBefore, "Liquidated trader should not recover escrow after liquidation"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "Router should hold no escrow for post-liquidation recovery");
    }

}

contract FadStalenessTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    uint256 constant FRIDAY_18UTC = 604_951_200;
    uint256 constant SATURDAY_NOON = 605_016_000;
    uint256 constant SUNDAY_21UTC = 605_134_800;
    uint256 constant MONDAY_NOON = 605_188_800;
    uint256 constant WEDNESDAY_NOON = 605_361_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        uint256 WEDNESDAY_BEFORE = FRIDAY_18UTC - 2 days;
        vm.warp(WEDNESDAY_BEFORE);
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), uint64(WEDNESDAY_BEFORE + 6));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(WEDNESDAY_BEFORE + 50);
        bytes[] memory setupPyth = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, setupPyth);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        require(size == 10_000 * 1e18, "setUp: position not opened");

        vm.warp(FRIDAY_18UTC);
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_18UTC + 6);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _currentTimestamp() internal view returns (uint256 ts) {
        assembly {
            ts := timestamp()
        }
    }

    function _addFadDays(
        uint256[] memory timestamps
    ) internal {
        engine.proposeAddFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeAddFadDays();
    }

    function _removeFadDays(
        uint256[] memory timestamps
    ) internal {
        engine.proposeRemoveFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeRemoveFadDays();
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        engine.proposeFadMaxStaleness(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeFadMaxStaleness();
    }

    function _setFadRunway(
        uint256 val
    ) internal {
        engine.proposeFadRunway(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeFadRunway();
    }

    function test_FadWindow_CloseOrder_AllowedDuringFrozenWithPreFreezeCommit() public {
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(fridayClose - 6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(fridayClose + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close order should execute during frozen oracle");
    }

    function test_FadWindow_OpenOrder_BlockedDuringFrozen() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__CloseOnlyMode.selector);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FadWindow_MevCheckDisabledDuringFrozen() public {
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Frozen-window close should execute without MEV rejection");
    }

    function test_FadWindow_ExcessStaleness_CloseGracefullyCancelled() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_Liquidation_AcceptsStalePrice() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        vm.prank(address(router));
        engine.updateMarkPrice(86_000_000, uint64(block.timestamp));
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, 9300e6);

        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), uint64(block.timestamp));

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();

        router.executeLiquidation(aliceId, empty);

        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Liquidation should succeed during FAD with stale price");
    }

    function test_FadWindow_Liquidation_ExcessStaleness_Reverts() public {
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(aliceId, empty);
    }

    function test_FadBatch_CloseAllowedDuringFrozenWithPreFreezeCommit() public {
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(fridayClose - 6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(fridayClose + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 5000 * 1e18, "Partial close should reduce position");
    }

    function test_FadBatch_ExcessStaleness_FrozenReverts() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);
    }

    function test_Weekday_StalenessUnchanged() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 6);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(WEDNESDAY_NOON + 67);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "61s stale on weekday should cancel");
    }

    function test_Weekday_OpenOrder_Allowed() public {
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), 10_000 * 1e6);
        vm.stopPrank();

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 10);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(WEDNESDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,,,) = engine.positions(carolId);
        assertGt(size, 0, "Weekday open orders should work normally");
    }

    function test_Admin_AddFadDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow(), "Wednesday should be FAD after admin override");
    }

    function test_Admin_RemoveFadDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow());

        _removeFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertFalse(engine.isFadWindow(), "FAD override should be removed");
    }

    function test_Admin_SetFadMaxStaleness() public {
        assertEq(engine.fadMaxStaleness(), 3 days);
        _setFadMaxStaleness(5 days);
        assertEq(engine.fadMaxStaleness(), 5 days);
    }

    function test_Admin_SetFadMaxStaleness_ZeroReverts() public {
        vm.expectRevert(CfdEngine.CfdEngine__ZeroStaleness.selector);
        engine.proposeFadMaxStaleness(0);
    }

    function test_Admin_AddFadDays_NonOwner_Reverts() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;

        vm.prank(alice);
        vm.expectRevert();
        engine.proposeAddFadDays(timestamps);
    }

    function test_Admin_EmptyDays_Reverts() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(CfdEngine.CfdEngine__EmptyDays.selector);
        engine.proposeAddFadDays(empty);
    }

    function test_AdminFadDay_BlockedDuringFrozen() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = MONDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(MONDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__CloseOnlyMode.selector);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FridayGap_MevCheckStillActive() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        uint256 publishTime = FRIDAY_20UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(2, empty);
    }

    function test_FridayGap_FreshPriceStillWorks() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 6);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close with fresh price should succeed during Friday gap");
    }

    function test_FridayGap_OpenStillBlocked() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__CloseOnlyMode.selector);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FridayGap_StalenessStill60s() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 63);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "60s staleness must apply during Friday gap");
    }

    function test_FridayGap_LiquidationStaleness15s() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), FRIDAY_20UTC);

        vm.warp(FRIDAY_20UTC + 16);
        bytes[] memory empty = _pythUpdateData();
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(aliceId, empty);
    }

    function test_SundayDst_OracleUnfrozenAt21() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 6);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close should succeed at Sunday 21:00 with fresh price");
    }

    function test_SundayDst_MevEnforcedAt21() public {
        uint256 publishTime = SUNDAY_21UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(2, empty);
    }

    function test_SundayDst_StillFadAt21() public {
        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__CloseOnlyMode.selector);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_SundayDst_WinterStalenessRejects() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 12 hours);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(2, empty);
    }

    function test_Runway_FadActivatesBeforeHoliday() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 tuesdayJustOutside = wednesdayMidnight - 3 hours - 1;

        vm.warp(tuesdayJustOutside);
        assertFalse(engine.isFadWindow(), "Before runway: FAD should be inactive");

        uint256 tuesdayRunwayStart = wednesdayMidnight - 3 hours;
        vm.warp(tuesdayRunwayStart);
        assertTrue(engine.isFadWindow(), "At runway start: FAD should be active");

        uint256 tuesday22 = wednesdayMidnight - 2 hours;
        vm.warp(tuesday22);
        assertTrue(engine.isFadWindow(), "During runway: FAD should be active");
    }

    function test_Runway_OracleFrozenOnlyOnHolidayDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;

        vm.warp(wednesdayMidnight - 3 hours);
        assertTrue(engine.isFadWindow());

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__CloseOnlyMode.selector);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), wednesdayMidnight - 3 hours + 6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(wednesdayMidnight - 3 hours + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close with fresh price works during runway");
    }

    function test_Runway_MevStillEnforcedDuringRunway() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 runwayTime = wednesdayMidnight - 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), runwayTime - 60);

        vm.warp(runwayTime);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(runwayTime + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrder(2, empty);
    }

    function test_Runway_SetFadRunway() public {
        assertEq(engine.fadRunwaySeconds(), 3 hours);
        _setFadRunway(6 hours);
        assertEq(engine.fadRunwaySeconds(), 6 hours);
    }

    function test_Runway_TooLong_Reverts() public {
        vm.expectRevert(CfdEngine.CfdEngine__RunwayTooLong.selector);
        engine.proposeFadRunway(25 hours);
    }

    function test_Runway_ZeroDisablesLookahead() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);
        _setFadRunway(0);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;

        vm.warp(wednesdayMidnight - 3 hours);
        assertFalse(engine.isFadWindow(), "Zero runway disables lookahead");

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow(), "Holiday day itself still FAD");
    }

}

contract InversionTest is Test {

    MockPyth mockPyth;
    bytes32 constant FEED_JPY = bytes32(uint256(0xAA));
    bytes32 constant FEED_EUR = bytes32(uint256(0xBB));

    function setUp() public {
        mockPyth = new MockPyth();
    }

    function test_H03_InvertedFeedUsesCorrectPrice() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 638_163;
        bool[] memory inv = new bool[](1);
        inv[0] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);
        (uint256 price,) = harness.computeBasketPrice();

        uint256 expectedNorm = uint256(1e11) / 156_700;
        uint256 expectedBasket = (expectedNorm * 1e18) / (uint256(638_163) * 1e10);
        assertEq(price, expectedBasket, "Inverted JPY should produce correct basket price");
    }

    function test_H03_InversionsLengthMismatchReverts() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_JPY;
        ids[1] = FEED_EUR;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 1e8;
        b[1] = 1e8;
        bool[] memory inv = new bool[](1);

        vm.expectRevert(OrderRouter.OrderRouter__LengthMismatch.selector);
        new BasketPriceHarness(address(mockPyth), ids, w, b, inv);
    }

    function test_H03_MixedInversionsComputeCorrectBasket() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_EUR;
        ids[1] = FEED_JPY;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 108_000_000;
        b[1] = 638_163;
        bool[] memory inv = new bool[](2);
        inv[0] = false;
        inv[1] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_EUR, int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);

        (uint256 price,) = harness.computeBasketPrice();

        assertApproxEqAbs(price, 100_000_000, 100, "Mixed basket at base prices should be ~$1.00");
    }

    function test_H03_OracleEquivalence_SamePricesSameBasket() public {
        uint256[] memory w = new uint256[](4);
        w[0] = 0.4e18;
        w[1] = 0.2e18;
        w[2] = 0.25e18;
        w[3] = 0.15e18;

        int256 eurUsd8 = 108_000_000;
        int256 jpyUsd8 = 638_163;
        int256 gbpUsd8 = 126_000_000;
        int256 chfUsd8 = 113_636_363;

        uint256[] memory basePrices = new uint256[](4);
        basePrices[0] = uint256(eurUsd8);
        basePrices[1] = uint256(jpyUsd8);
        basePrices[2] = uint256(gbpUsd8);
        basePrices[3] = uint256(chfUsd8);

        address[] memory feeds = new address[](4);
        feeds[0] = address(new MockOracle(eurUsd8, "EUR/USD"));
        feeds[1] = address(new MockOracle(jpyUsd8, "JPY/USD"));
        feeds[2] = address(new MockOracle(gbpUsd8, "GBP/USD"));
        feeds[3] = address(new MockOracle(chfUsd8, "CHF/USD"));

        BasketOracle basket = new BasketOracle(feeds, w, basePrices, 500, 2e8, address(this));
        (, int256 chainlinkPrice,,,) = basket.latestRoundData();

        bytes32[] memory pythIds = new bytes32[](4);
        pythIds[0] = bytes32(uint256(0x01));
        pythIds[1] = bytes32(uint256(0x02));
        pythIds[2] = bytes32(uint256(0x03));
        pythIds[3] = bytes32(uint256(0x04));

        bool[] memory inv = new bool[](4);
        inv[0] = false;
        inv[1] = true;
        inv[2] = false;
        inv[3] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), pythIds, w, basePrices, inv);

        mockPyth.setPrice(pythIds[0], int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[1], int64(15_670), int32(-2), 1001);
        mockPyth.setPrice(pythIds[2], int64(126_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[3], int64(8800), int32(-4), 1001);

        (uint256 pythPrice,) = harness.computeBasketPrice();

        assertApproxEqAbs(
            uint256(chainlinkPrice), pythPrice, 100, "BasketOracle and OrderRouter must agree within rounding"
        );
    }

}

contract OrderRouterAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-5 — close orders bypass slippage
    function test_CloseBypassesSlippage() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0.9e8, true);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(uint256(1.5e8));
        vm.roll(10);
        router.executeOrder(2, pythData);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,,,) = engine.positions(carolAccount);
        assertGt(size, 0, "Close at bad price should have been rejected by slippage check");
    }

    // Regression: Finding-6 — missing chainId guard
    function test_MissingChainIdGuard() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.chainId(1);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;

        vm.expectRevert(OrderRouter.OrderRouter__MockModeDisabled.selector);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);
    }

    // Regression: H-02 — stale order executes via executeOrder
    function test_StaleOrderExecutesViaExecuteOrder() public {
        router.proposeMaxOrderAge(300);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        uint64 commitId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 600);

        vm.roll(block.number + 1);
        router.executeOrder(commitId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Expired order must not execute via executeOrder");
    }

    // Regression: order commits should not require ETH
    function test_ZeroEthCommitAllowed() public {
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 1000e18, 1000e6, 1e8, false);

        assertEq(router.nextCommitId(), 2, "Commit should succeed without an ETH execution fee");
    }

    // Regression: H-03 — close order allowed while paused
    function test_CloseOrderAllowedWhilePaused() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        router.unpause();
        vm.roll(10);
        router.executeOrder(2, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Position should be fully closed");
    }

}

// Regression: H-03
contract StaleOrderExpiryTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address spammer = address(0x666);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        router.proposeMaxOrderAge(300);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();
    }

    // Regression: H-03
    function test_StaleSpamOrdersAutoSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);
        _fundTrader(spammer, 10_000 * 1e6);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        assertEq(router.nextExecuteId(), 1);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(6, empty);

        assertEq(router.nextExecuteId(), 0, "Queue advanced past spam + real order and drained to the zero sentinel");
    }

    // Regression: H-03
    function test_FreshOrdersNotSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0);
    }

    // Regression: H-03
    function test_SpammerFeeConfiscatedOnExpiry() public {
        vm.deal(spammer, 1 ether);
        _fundTrader(spammer, 10_000 * 1e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        assertEq(router.claimableEth(spammer), 0, "Expired order should not create claimable ETH for the user");
        assertEq(router.claimableEth(keeper), 0, "Expired order should not pay an ETH execution fee");
    }

    // Regression: H-03
    function test_BatchSkipsStaleOrders() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);
        _fundTrader(spammer, 10_000 * 1e6);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(4, empty);

        assertEq(router.nextExecuteId(), 0, "Batch advanced past stale + real order and drained to the zero sentinel");
    }

    // Regression: H-03
    function test_SetMaxOrderAge_OnlyOwner() public {
        vm.prank(spammer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, spammer));
        router.proposeMaxOrderAge(600);

        router.proposeMaxOrderAge(600);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();
        assertEq(router.maxOrderAge(), 600);
    }

    // Regression: H-01
    function test_ExpiredOrderFeeRefundedToUser_ViaSkip() public {
        vm.deal(spammer, 1 ether);
        _fundTrader(spammer, 10_000e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        assertEq(router.claimableEth(spammer), 0, "Expired order should not create claimable ETH for the user");
        assertEq(router.claimableEth(keeper), 0, "Expired order should not pay an ETH execution fee");
    }

}

contract MarkPriceStalenessTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        pool.setJuniorVault(address(juniorVault));
        pool.setSeniorVault(address(seniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);
    }

    function test_UpdateMarkPrice_RevertsOnStaleOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 120);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.updateMarkPrice(updateData);
    }

    function test_UpdateMarkPrice_AcceptsFreshOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 30);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);
        assertEq(engine.lastMarkPrice(), 1e8);
    }

}

// Regression: H-02
contract StalenessGriefTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);
    address attacker = address(0x666);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        pool.setJuniorVault(address(juniorVault));
        pool.setSeniorVault(address(seniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    // Regression: H-02
    function test_StaleOracleCancelsOrderInsteadOfReverting() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 120);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(attacker);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "stale oracle gracefully cancels order instead of reverting");
    }

}

// Regression: C-05
contract VpiImrBypassTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 1e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    // M-01 fix: IMR check excludes VPI rebates from effective margin.
    // With zero deposited margin, the position should be rejected even if the VPI
    // rebate would otherwise exceed IMR.
    function test_VpiRebateDoesNotSatisfyIMR_AfterFix() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        usdc.mint(alice, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(aliceAccount, 1e6);
        vm.stopPrank();

        assertEq(clearinghouse.balanceUsdc(aliceAccount), 1e6, "Alice only funds the reserved execution bounty");

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Position rejected: VPI rebate alone cannot satisfy IMR");
    }

}

// Regression: H-01
contract KeeperFeeRefundTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        router.proposeMaxOrderAge(300);
        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
        router.finalizeMaxOrderAge();
    }

    // Regression: H-01 — fee refunded to user on failure
    function test_ExpiredOrderFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 50_000e6);
        vm.prank(alice);
        usdc.approve(address(clearinghouse), 50_000e6);
        vm.prank(alice);
        clearinghouse.deposit(accountId, 50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        uint256 keeperBefore = keeper.balance;
        bytes[] memory empty;
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.claimableEth(alice), 0, "Refund should be sent directly to the user");
        assertEq(keeper.balance - keeperBefore, 0, "Keeper should not receive failed-order fee");
        assertEq(alice.balance, 1 ether, "User receives failed-order fee refund");
    }

    // Regression: H-01 — fee refunded to user on slippage failure
    function test_SlippageFailFeeRefundedToUser() public {
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), 50_000e6);
        clearinghouse.deposit(accountId, 50_000e6);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1.5e8, false);

        uint256 keeperBefore = keeper.balance;
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(router.claimableEth(alice), 0, "Refund should be sent directly to the user");
        assertEq(keeper.balance - keeperBefore, 0, "Keeper should not receive fee on slippage failure");
        assertEq(alice.balance, 1 ether, "User receives slippage-failure refund");
    }

    // Regression: H-01
    function test_BatchExpiredFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 50_000e6);
        vm.prank(alice);
        usdc.approve(address(clearinghouse), 50_000e6);
        vm.prank(alice);
        clearinghouse.deposit(accountId, 50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        uint256 keeperBefore = address(this).balance;
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        assertEq(alice.balance, 1 ether, "User fee refunded on batch expiry");
        assertEq(address(this).balance - keeperBefore, 0, "Keeper should not receive fee for expired batch order");
    }

}

// Regression: H-02
contract WeekendArbitrageTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    function setUp() public {
        vm.warp(1_709_100_000);
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
    }

    function test_CloseOrderCommittedDuringFrozenCanUseStaleFridayPrice() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 0, false);
        vm.warp(block.timestamp + 6);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        vm.roll(block.number + 1);
        router.executeOrder(1, updateData);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should be open");

        uint256 ts = block.timestamp;
        uint256 dayOfWeek = ((ts / 86_400) + 4) % 7;
        uint256 daysToSaturday = (6 + 7 - dayOfWeek) % 7;
        if (daysToSaturday == 0) {
            daysToSaturday = 7;
        }
        uint256 saturdayNoon = ts + (daysToSaturday * 86_400) - (ts % 86_400) + 12 hours;
        vm.warp(saturdayNoon);

        uint256 fridayPublishTime = saturdayNoon - 18 hours;
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), fridayPublishTime);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 0, true);

        vm.roll(10);
        router.executeOrder(2, updateData);

        (size,,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Frozen-window close should execute when only stale Friday price exists");
    }

}

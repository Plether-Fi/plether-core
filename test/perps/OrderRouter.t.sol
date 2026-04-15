// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";
import {DecimalConstants} from "../../src/libraries/DecimalConstants.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAdminHost} from "../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract OrderRouterTest is BasePerpTest {

    using stdStorage for StdStorage;

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
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
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        juniorVault.withdraw(1_000_000 * 1e6, bob, bob);

        bytes[] memory emptyPayload;
        vm.roll(block.number + 1);
        router.executeOrder(1, emptyPayload);

        assertEq(router.nextExecuteId(), 0, "Terminal engine reverts should clear the queue to the zero sentinel");

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should not exist");

        assertEq(
            clearinghouse.balanceUsdc(accountId),
            10_000 * 1e6,
            "Protocol-state invalidation should refund the reserved bounty back into Alice's clearinghouse balance"
        );
    }

    function test_WithdrawalFirewall() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(_sideMaxProfit(CfdTypes.Side.BULL), 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 20_000_000, "Protocol should still retain the full 4 bps execution fee");
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            1e6,
            "Keeper should receive the 1 USDC capped reward as clearinghouse credit"
        );
        assertGt(freeUsdc, 951_000 * 1e6, "Free USDC should include the seeded junior floor plus unencumbered capital");
        assertLt(freeUsdc, 953_000 * 1e6, "Free USDC bounded above");

        (,, uint256 maxSeniorWithdrawUsdc, uint256 maxJuniorWithdrawUsdc) = pool.getPendingTrancheState();
        uint256 bobMaxWithdraw = juniorVault.maxWithdraw(bob);
        assertEq(maxSeniorWithdrawUsdc + maxJuniorWithdrawUsdc, freeUsdc, "free USDC should split across tranches");
        assertEq(
            bobMaxWithdraw,
            maxJuniorWithdrawUsdc,
            "junior LP should only withdraw the junior tranche share of free USDC"
        );
    }

    function test_IncreaseOrder_UsesUnlockedPositionMarginToPayTradeCost() public {
        address trader = address(0xC444);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 sizeDelta = 3334e18;
        uint256 marginDelta = 110e6;
        uint256 executionBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(sizeDelta);

        _fundTrader(trader, marginDelta + executionBountyUsdc);
        _open(accountId, CfdTypes.Side.BULL, sizeDelta, marginDelta, 1e8);

        assertEq(
            _freeSettlementUsdc(accountId),
            executionBountyUsdc,
            "setup must leave only the future execution bounty as free settlement"
        );

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, sizeDelta, 0, 1e8, false);

        assertEq(_freeSettlementUsdc(accountId), 0, "commit should move the only free settlement into bounty escrow");

        uint256 keeperBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this)))));
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(
            size, sizeDelta * 2, "valid increase should execute even when free settlement is zero at execution time"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            executionBountyUsdc,
            "keeper should receive the reserved execution bounty as clearinghouse credit after successful execution"
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

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 0));
        vm.roll(10);
        router.executeOrder(1, empty);
    }

    function test_ExecuteOrder_SkipsFailedHeadEvenWhenExpirationDisabled() public {
        address other = address(0x333);
        bytes32 otherId = bytes32(uint256(uint160(other)));

        _fundTrader(other, 1000e6);
        _open(otherId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 1, head
        vm.prank(other);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, type(uint256).max, false); // order 2, non-head
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false); // order 3, next live order

        vm.prank(other);
        clearinghouse.withdraw(otherId, 70e6);

        vm.prank(address(this));
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 0;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(this));
        routerAdmin.finalizeRouterConfig();

        bytes[] memory pythPrice = new bytes[](1);
        pythPrice[0] = abi.encode(uint256(150_000_000));
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
        router.executeOrder(3, empty);

        assertEq(
            router.nextExecuteId(),
            0,
            "Single-order execution should clear the queue to the zero sentinel when exhausted"
        );
    }

    function test_StrictFIFO_OutOfOrder_Reverts() public {
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 1));
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

        (, uint256 posMargin,,,,,) = engine.positions(accountId);
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
            posMargin + 500 * 1e6,
            "Lock should preserve pending committed margin for order 2"
        );
        assertEq(_remainingCommittedMargin(1), 0, "Order 1 committed margin must be cleared on success");

        vm.roll(10);
        router.executeOrder(2, empty);

        (, uint256 posMarginAfter,,,,,) = engine.positions(accountId);
        assertEq(
            clearinghouse.lockedMarginUsdc(accountId),
            posMarginAfter,
            "Failed order 2 should only unlock its own committed margin"
        );
        assertEq(_remainingCommittedMargin(2), 0, "Order 2 committed margin must be cleared on failure");
    }

    function test_CommitOrder_RevertsWhenPendingOrderCountHitsCap() public {
        uint256 limit = 5;

        vm.startPrank(alice);
        for (uint256 i = 0; i < limit; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 100e6, 1e8, false);
        }
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 7));
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

        OrderRouter.OrderRecord memory record = _orderRecord(1);
        assertEq(uint256(record.status), uint256(IOrderRouterAccounting.OrderStatus.Pending));
        assertEq(record.core.orderId, 1);
        assertEq(record.core.accountId, bytes32(uint256(uint160(alice))));
        assertEq(_remainingCommittedMargin(1), 1000 * 1e6);
        assertEq(record.executionBountyUsdc, 1_000_000);
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

        OrderRouter.OrderRecord memory record = _orderRecord(1);
        assertEq(uint256(record.status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(record.core.orderId, 1, "Terminal record should keep immutable order metadata");
        assertEq(_remainingCommittedMargin(1), 0, "Executed order should clear committed margin escrow");
        assertEq(record.executionBountyUsdc, 0, "Executed order should clear execution bounty escrow");
        assertFalse(record.inMarginQueue, "Executed order should not remain linked in the margin queue");
    }

    function test_GetPendingOrdersAndEscrow_ReturnAggregateOrderState() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        vm.stopPrank();

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(accountId);
        assertEq(escrow.pendingOrderCount, 2);
        assertEq(escrow.committedMarginUsdc, 1000 * 1e6);
        assertEq(escrow.executionBountyUsdc, 2_000_000);
        assertEq(pending.length, 2);
        assertTrue(pending[1].isClose);
    }

    function test_CloseCommit_ReservesPrefundedKeeperBounty() public {
        address trader = address(0x333);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 1001e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 1000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        assertEq(_executionBountyReserve(1), 1_000_000, "Close orders should pre-seize the flat router bounty");
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

        assertEq(_freeSettlementUsdc(accountId), 0, "setup must fully consume free settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(accountId);
        assertEq(_executionBountyReserve(1), 1_000_000, "Close orders should still escrow full bounty");
        assertEq(marginAfter, marginBefore - 1_000_000, "Close bounty should fall back to active margin");
        assertEq(usdc.balanceOf(address(router)), 1_000_000, "Router should custody the close bounty after fallback");
    }

    function test_CloseCommit_CanReserveKeeperBountyFromPositionMarginWithStaleStoredMark() public {
        address trader = address(0x3341);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x3351);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 1000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 50_000e18, 1000e6, 1e8);
        _open(counterpartyId, CfdTypes.Side.BEAR, 50_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(accountId), 0, "setup must fully consume free settlement");
        (, uint256 marginBefore,,,,,) = engine.positions(accountId);
        assertEq(engine.lastMarkPrice(), 1e8, "setup should leave a stored mark price");

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(accountId);
        assertEq(
            _executionBountyReserve(1), 1_000_000, "Stale-mark close commits should still escrow the flat router bounty"
        );
        assertEq(
            marginAfter, marginBefore - 1_000_000, "Stale-mark close bounty should still fall back to active margin"
        );
        assertEq(
            usdc.balanceOf(address(router)),
            1_000_000,
            "Router should custody the stale-mark close bounty after fallback"
        );
    }

    function test_CloseCommit_StaleFallbackDoesNotRevertWhenFreeSettlementExists() public {
        address trader = address(0x3342);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, 251_500_000);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 251_500_000);
        clearinghouse.deposit(accountId, 251_500_000);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = new bytes[](1);
        openPrice[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        uint256 freeSettlementBefore = clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc;
        assertEq(
            freeSettlementBefore, 500_000, "Setup should leave partial free settlement before the stale close commit"
        );

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0, true);

        assertEq(_executionBountyReserve(2), 1_000_000, "Stale close commit should still escrow the full bounty");
        assertEq(
            clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc,
            0,
            "Stale close fallback should still be allowed to consume the remaining free-settlement slice"
        );
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

        assertEq(_freeSettlementUsdc(accountId), 0, "setup must fully consume free settlement");

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__InsufficientCloseOrderBountyBacking.selector);
        engine.reserveCloseOrderExecutionBounty(accountId, 1e6, address(router));
    }

    function test_InvalidClose_MarginBackedBountyPaysKeeper() public {
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

        (, uint256 marginBeforeCommit,,,,,) = engine.positions(accountId);
        assertEq(_freeSettlementUsdc(accountId), 0, "setup must fully consume free settlement");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, minSize - 1, 0, 0, true);

        (, uint256 marginAfterCommit,,,,,) = engine.positions(accountId);
        assertEq(
            marginAfterCommit,
            marginBeforeCommit - 1e6,
            "commit should temporarily reserve the bounty from position margin"
        );

        uint256 keeperBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this)))));
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (, uint256 marginAfterExecute,,,,,) = engine.positions(accountId);
        assertEq(
            marginAfterExecute,
            marginBeforeCommit - 1e6,
            "failed invalid close should keep the consumed margin-backed bounty paid out"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "keeper should receive the escrowed margin-backed bounty as clearinghouse credit"
        );
        assertEq(_executionBountyReserve(1), 0, "failed close should clear router bounty escrow");
        assertEq(
            uint256(_orderRecord(1).status),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "invalid close should finalize as failed"
        );
    }

    function test_InvalidClose_FreeBackedBountyPaysKeeper() public {
        address trader = address(0x340);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x341);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        uint256 depth = 5_000_000 * 1e6;
        _fundTrader(trader, 55_000e6);
        _fundTrader(counterparty, 500_000e6);
        _open(counterpartyId, CfdTypes.Side.BEAR, 500_000e18, 50_000e6, 1e8, depth);

        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(accountId, CfdTypes.Side.BULL, minSize, 50_000e6, 1e8, depth);

        uint256 freeSettlementBeforeCommit = _freeSettlementUsdc(accountId);
        assertEq(freeSettlementBeforeCommit, 5000e6, "setup must leave free settlement to back the bounty");
        assertEq(usdc.balanceOf(trader), 0, "trader wallet should start empty after depositing into the clearinghouse");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, minSize - 1, 0, 0, true);

        assertEq(
            _freeSettlementUsdc(accountId),
            freeSettlementBeforeCommit - 1e6,
            "commit should temporarily seize the close bounty from free settlement"
        );

        bytes[] memory empty;
        vm.roll(block.number + 1);
        uint256 keeperBefore = _settlementBalance(address(this));
        router.executeOrder(1, empty);

        assertEq(
            _freeSettlementUsdc(accountId),
            freeSettlementBeforeCommit - 1e6,
            "failed invalid close should keep the free-backed bounty consumed"
        );
        assertEq(usdc.balanceOf(trader), 0, "free-backed bounty refund should not escape to the trader wallet");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "keeper should receive the free-backed bounty as clearinghouse credit"
        );
    }

    function test_GetPendingOrdersForAccount_ReturnsQueuedOrderDetails() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 1e8, true);
        vm.stopPrank();

        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(accountId);
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

        IOrderRouterAccounting.PendingOrderView[] memory alicePending = _pendingOrders(aliceId);
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
        assertTrue(_isInMarginQueue(1), "Positive-margin open should be linked into the margin queue");
        assertFalse(_isInMarginQueue(2), "Close order should not enter the margin queue");
        assertTrue(_isInMarginQueue(3), "Later positive-margin open should be linked into the margin queue");
    }

    function test_NoteCommittedMarginConsumed_PartialConsumePreservesMarginQueueMembership() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(address(engine));
        clearinghouse.consumeAccountOrderReservations(accountId, 400 * 1e6);

        vm.prank(address(engine));
        router.syncMarginQueue(accountId);

        assertEq(_remainingCommittedMargin(1), 600 * 1e6, "Partial consumption should leave residual committed margin");
        assertEq(
            clearinghouse.getOrderReservation(1).remainingAmountUsdc,
            600 * 1e6,
            "Reservation residual should match router-side committed margin residual"
        );
        assertEq(router.marginHeadOrderId(accountId), 1, "Partially consumed order should remain at margin-queue head");
        assertEq(router.marginTailOrderId(accountId), 1, "Single residual order should remain at margin-queue tail");
        assertTrue(_isInMarginQueue(1), "Partially consumed order should remain linked in the margin queue");
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

        assertEq(_remainingCommittedMargin(1), 0, "First margin-paying order should be fully drained");
        assertEq(
            _remainingCommittedMargin(3), 250 * 1e6, "Later positive-margin order should retain its committed margin"
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
            _isInMarginQueue(1), "Drained order should be pruned from the margin queue once reservations are consumed"
        );
        assertFalse(_isInMarginQueue(2), "Close orders should remain outside the margin queue");
        assertTrue(_isInMarginQueue(3), "Residual positive-margin order should remain in the margin queue");
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
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeSettlement);

        IMarginClearinghouse.LockedMarginBuckets memory beforeBuckets = clearinghouse.getLockedMarginBuckets(accountId);
        assertEq(beforeBuckets.committedOrderMarginUsdc, 500 * 1e6, "Setup must lock both committed-order buckets");

        vm.prank(address(engine));
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 1;
        reservationIds[1] = 2;
        clearinghouse.consumeCloseLoss(accountId, reservationIds, 300 * 1e6, 0, true, address(engine));

        vm.prank(address(engine));
        router.syncMarginQueue(accountId);

        assertEq(_remainingCommittedMargin(1), 0, "First order should be fully consumed before release");
        assertEq(
            _remainingCommittedMargin(2), 200 * 1e6, "Second order should retain only the unconsumed committed margin"
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
        assertEq(_remainingCommittedMargin(1), 0, "First order committed margin should stay zero after release");
        assertEq(
            _remainingCommittedMargin(2),
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
            _remainingCommittedMargin(1), 250 * 1e6, "Router should still track the per-order committed margin locally"
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
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 250 * 1e6, 2e8, false);
        vm.stopPrank();

        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        vm.prank(alice);
        clearinghouse.withdraw(accountId, freeSettlement);

        vm.prank(address(engine));
        uint64[] memory reservationIds = new uint64[](2);
        reservationIds[0] = 1;
        reservationIds[1] = 2;
        clearinghouse.consumeCloseLoss(accountId, reservationIds, 300 * 1e6, 0, true, address(engine));

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
        assertFalse(_isInMarginQueue(1), "Executed order should be removed from the margin queue");
        assertTrue(_isInMarginQueue(2), "Residual positive-margin order should remain linked");
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

        IOrderRouterAccounting.PendingOrderView[] memory alicePending = _pendingOrders(aliceId);
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
        uint256 keeperBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 0, "Empty global queue should clear to zero sentinel after processing");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 15_000 * 1e18, "Alice should have 15k BULL");

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 carolSize,,,,,,) = engine.positions(carolId);
        assertEq(carolSize, 10_000 * 1e18, "Carol should have 10k BEAR");

        uint256 keeperAfter = _settlementBalance(address(this));
        assertEq(keeperAfter - keeperBefore, 2_500_000, "Keeper should receive min(1 bp, 1 USDC) per successful order");

        assertEq(uint256(_orderRecord(1).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(_orderRecord(2).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(_orderRecord(3).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
    }

    function test_BatchExecution_SuccessfulOrdersEndExecuted() public {
        address carol = address(0x334);
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

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        OrderRouter.OrderRecord memory firstRecord = _orderRecord(1);
        OrderRouter.OrderRecord memory secondRecord = _orderRecord(2);
        assertEq(uint256(firstRecord.status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(secondRecord.status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(_remainingCommittedMargin(1), 0, "Executed batch order should clear committed margin escrow");
        assertEq(_remainingCommittedMargin(2), 0, "Executed batch order should clear committed margin escrow");
        assertEq(firstRecord.executionBountyUsdc, 0, "Executed batch order should clear execution bounty escrow");
        assertEq(secondRecord.executionBountyUsdc, 0, "Executed batch order should clear execution bounty escrow");
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

        assertEq(router.nextExecuteId(), 0, "Batch should clear the terminal slippage middle order and drain the queue");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 15_000 * 1e18, "Orders 1 and 3 succeed, order 2 cancelled");
    }

    function test_BatchExecution_NoOrders_Reverts() public {
        bytes[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 0));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 0));
        router.executeOrderBatch(1, empty);
    }

    function test_BatchExecution_UncommittedMaxId_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 3));
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
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        router.executeOrderBatch{value: 0.1 ether}(2, empty);
        uint256 keeperEthAfter = address(this).balance;
        uint256 keeperUsdcAfter = _settlementBalance(address(this));

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

        uint256 spamCount = 5;
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

        assertEq(
            router.nextExecuteId(), 0, "batch should clear adversarial failed heads and still execute the tail order"
        );
        (uint256 size,,,,,,) = engine.positions(carolId);
        assertEq(size, 10_000 * 1e18, "tail order should still execute after many failed head orders");
        assertLt(gasUsed, 40_000_000, "adversarial batch path gas budget regressed");
    }

    function test_PoisonedHead_CloseSlippageFailsAndLetsTailExecute() public {
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
        _fundTrader(bob, 1000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 500 * 1e6, 1e8, false);

        vm.roll(block.number + 1);
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 0, "terminal slippage miss should not block later queued orders");
        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        (uint256 carolSize,,,,,,) = engine.positions(carolId);
        assertEq(aliceSize, 10_000 * 1e18, "slippage-failed close must leave the live position intact");
        assertEq(carolSize, 5000 * 1e18, "tail order should execute once the failed head is cleared");
    }

    function test_HistoricalFailedReservations_DoNotBrickLaterHeadCleanup() public {
        address carol = address(0x559);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        bytes32 carolId = bytes32(uint256(uint160(carol)));

        usdc.mint(carol, 20_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carolId, 20_000 * 1e6);
        vm.stopPrank();

        bytes[] memory empty;
        uint256 failedCycles = 24;

        for (uint256 i = 0; i < failedCycles; ++i) {
            vm.prank(alice);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

            vm.warp(block.timestamp + router.maxOrderAge() + 1);
            vm.roll(block.number + 1);
            router.executeOrder(uint64(i + 1), empty);

            assertEq(router.nextExecuteId(), 0, "failed slippage head should clear immediately each cycle");
            assertEq(
                clearinghouse.getAccountReservationSummary(aliceId).activeReservationCount,
                0,
                "historical failed reservations must not leave active residue"
            );
        }

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 500 * 1e6, 1e8, false);

        vm.roll(block.number + 1);
        uint256 gasBefore = gasleft();
        router.executeOrderBatch(26, empty);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(router.nextExecuteId(), 0, "later valid head cleanup should still drain the queue");
        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        (uint256 carolSize,,,,,,) = engine.positions(carolId);
        assertEq(aliceSize, 10_000 * 1e18, "historical failed reservations must not block later head execution");
        assertEq(carolSize, 5000 * 1e18, "tail order should execute after the cleaned head");
        assertLt(gasUsed, 40_000_000, "historical failed reservations should not cause unbounded cleanup gas");
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

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 2e8, false);
        }

        vm.roll(block.number + 1);
        uint256 gasBefore = gasleft();
        router.executeOrder(2, empty);
        uint256 gasUsed = gasBefore - gasleft();

        (uint256 size,,,,,,) = engine.positions(aliceId);
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
        _fundTrader(bob, 5000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 2e8, false);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        uint256 executorBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(4, empty);

        uint256 executorReward = _settlementBalance(address(this)) - executorBefore;
        assertEq(
            executorReward,
            2_000_000,
            "Terminal close slippage and the valid tail should both pay the executor under current policy"
        );
        assertEq(
            router.nextExecuteId(),
            0,
            "mixed failed and successful heads should clear the failed head and drain the queue"
        );

        (uint256 carolSize,,,,,,) = engine.positions(carolId);
        assertEq(carolSize, 10_000 * 1e18, "valid tail order should still execute after mixed heads");
    }

}

contract OrderRouterPythTest is BasePerpTest {

    using stdStorage for StdStorage;

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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        _syncEngineAdmin();
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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        _syncRouterAdmin();
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

    function test_PublishTimeBeforeCommit_Reverts() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 13));
        router.executeOrder(1, empty);

        assertEq(
            router.nextExecuteId(), 1, "Live execution should keep the order pending when publish time predates commit"
        );
    }

    function test_SameBlockExecution_Reverts() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 13));
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order stays in queue when executed in same block");
    }

    function test_OrderExecution_UsesRouterExecutionStalenessLimit_NotPoolMarkLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();

        vm.warp(1150);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1100);
        vm.warp(1200);
        vm.roll(block.number + 1);

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(1, _pythUpdateData());

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(1200 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp - 10));

        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 0, "Router execution staleness limit should control live order execution");
    }

    function test_OrderRefund_DoesNotRevertWhenRouterLimitExceedsEngineHelperLimit() public {
        engineAdmin.proposeEngineMarkStalenessLimit(60);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 300;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        engineAdmin.finalizeEngineMarkStalenessLimit();
        routerAdmin.finalizeRouterConfig();

        vm.warp(1050);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1120);
        bytes[] memory empty = _pythUpdateData();
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 settlementBefore = clearinghouse.balanceUsdc(aliceId);

        vm.warp(1200);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            router.nextExecuteId(),
            0,
            "Router-validated refund path should not revert during settlement credit finalization"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - settlementBefore,
            1e6,
            "Trader refund should succeed even when engine helper freshness would otherwise be stricter"
        );
    }

    function test_PythConfidenceTooWide_RevertsExecution() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.pythMaxConfidenceRatioBps = 100;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(1000 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        mockPyth.setAllPrices(feedIds, int64(100_000_000), uint64(2_000_000), int32(-8), uint64(block.timestamp - 10));

        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 11));
        router.executeOrder(1, _pythUpdateData());
    }

    function test_PythConfidenceWithinThreshold_AllowsExecution() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.pythMaxConfidenceRatioBps = 100;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(1000 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        mockPyth.setAllPrices(feedIds, int64(100_000_000), uint64(500_000), int32(-8), 1006);

        vm.roll(block.number + 1);
        router.executeOrder(1, _pythUpdateData());

        assertEq(router.nextExecuteId(), 0, "Execution should succeed when all Pyth confidences are within threshold");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1006);
        vm.warp(1050);

        bytes[] memory empty = _pythUpdateData();
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            10_000 * 1e6,
            "Open-order slippage failure should refund the reserved execution bounty into clearinghouse settlement"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            0,
            "Terminal slippage failures should not pay the executor"
        );
        assertEq(
            engine.accumulatedFeesUsdc(), 0, "Failed binding open-order bounty should not be routed to protocol revenue"
        );
        assertEq(router.nextExecuteId(), 0, "Terminal slippage miss should clear the pending order");
        assertEq(_executionBountyReserve(1), 0, "Terminal slippage miss should clear bounty escrow");
    }

    function _setDegradedModeForTest() internal {
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
    }

    function test_PostCommitDegradedModeRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _setDegradedModeForTest();
        assertTrue(engine.degradedMode(), "Setup must latch degraded mode");
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = _settlementBalance(address(this));
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 aliceSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once degraded mode latches");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            0,
            "Keeper should not receive bounty on protocol-state failure"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - aliceSettlementBefore,
            1e6,
            "Trader should receive bounty refund into clearinghouse custody on degraded-mode failure"
        );
    }

    function test_PostCommitDegradedModeRefundCreditsClearinghouseAndDoesNotBrickHead() public {
        _fundTrader(bob, 10_000e6);
        bytes32 aliceAccountId = bytes32(uint256(uint160(alice)));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _setDegradedModeForTest();
        vm.warp(block.timestamp + 6);

        uint256 aliceSettlementBefore = clearinghouse.balanceUsdc(aliceAccountId);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 2, "Failed refund transfer must not brick the FIFO head");
        assertEq(
            clearinghouse.balanceUsdc(aliceAccountId),
            aliceSettlementBefore + 1e6,
            "Refund should credit the trader clearinghouse balance directly"
        );
    }

    function test_CommitOrder_RevertsOnPredictableInsufficientInitialMargin() public {
        address eve = address(0xE111);
        bytes32 eveId = bytes32(uint256(uint160(eve)));
        _fundTrader(eve, 1000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(eve);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 100e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictableMustCloseOpposing() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderRouter.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING)
            )
        );
        router.commitOrder(CfdTypes.Side.BEAR, 5000e18, 500e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictablePositionTooSmall() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 5000e6, 1e8, false);
    }

    function test_CommitOrder_DoesNotUseStaleCachedMarkForPredictableOpenPrefilter() public {
        address eve = address(0xE112);
        bytes32 eveId = bytes32(uint256(uint160(eve)));
        _fundTrader(eve, 1000e6);

        vm.warp(block.timestamp + router.orderExecutionStalenessLimit() + 1);

        vm.prank(eve);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 100e6, 1e8, false);

        IOrderRouterAccounting.PendingOrderView[] memory pending = _pendingOrders(eveId);
        assertEq(pending.length, 1, "Stale cached marks should skip commit-time predictable-open rejection");
        assertEq(pending[0].sizeDelta, 100_000e18, "Queued order should preserve the requested open intent");
    }

    function test_CommitOrder_RevertsOnPredictableSkewInvalidation() public {
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);
    }

    function test_CommitOrder_RevertsOnPredictableSolvencyInvalidation() public {
        address bearTrader = address(0xC333);
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _fundTrader(bearTrader, 50_000e6);
        _open(bearId, CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8);
        _fundTrader(alice, 40_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 350_000e18, 35_000e6, 1e8, false);
    }

    function test_PostCommitSkewInvalidationRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once post-commit skew exceeds the cap");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore, 0, "Keeper should not receive bounty on skew invalidation"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            1e6,
            "Trader should receive bounty refund into clearinghouse settlement on skew invalidation"
        );
    }

    function test_PostCommitSolvencyInvalidationRefundsUserBounty() public {
        address bearTrader = address(0xC333);
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _fundTrader(bearTrader, 50_000e6);
        _open(bearId, CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8);
        _fundTrader(alice, 40_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 350_000e18, 35_000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);
        vm.warp(block.timestamp + 6);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Order should fail once post-commit solvency is exceeded");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            0,
            "Keeper should not receive bounty on solvency invalidation"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            1e6,
            "Trader should receive bounty refund into clearinghouse settlement on solvency invalidation"
        );
    }

    function test_PostCommitMarginDrainInvalidationPaysClearerBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, false);

        vm.store(address(clearinghouse), keccak256(abi.encode(aliceId, uint256(3))), bytes32(uint256(1e6)));

        uint256 keeperBefore = _settlementBalance(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.warp(7);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000e18, "Order should fail once post-commit margin is drained");
        assertEq(margin, 1e6, "Post-commit state mutation should leave the custody-backed margin state untouched");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "Keeper should receive bounty on post-commit margin-drain invalidation as clearinghouse credit"
        );
        assertEq(usdc.balanceOf(alice), 0, "Trader should not receive bounty refund on margin-drain invalidation");
    }

    function test_StaleCachedMark_DoesNotBlockMarginDrainInvalidationExecution() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, false);

        vm.store(address(clearinghouse), keccak256(abi.encode(aliceId, uint256(3))), bytes32(uint256(1e6)));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        uint64 freshPublishTime = uint64(block.timestamp);
        uint64 staleMarkTimeBefore = engine.lastMarkTime();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), freshPublishTime);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        router.executeOrder(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000e18, "Fresh execution should fail softly instead of stale-reverting the live position");
        assertEq(margin, 1e6, "Invalidation should preserve the drained custody-backed margin state");
        assertEq(
            engine.lastMarkTime(), freshPublishTime, "Execution should push the fresh resolved mark before release"
        );
        assertLt(staleMarkTimeBefore, engine.lastMarkTime(), "Execution should advance the stale cached mark");
        assertEq(router.nextExecuteId(), 0, "Execution should clear the pending head instead of stalling on stale mark");
    }

    function test_BatchPostCommitMarginDrainInvalidationPaysClearerBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, false);

        vm.store(address(clearinghouse), keccak256(abi.encode(aliceId, uint256(3))), bytes32(uint256(1e6)));

        uint256 keeperBefore = _settlementBalance(address(this));
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 7);
        bytes[] memory empty = _pythUpdateData();
        vm.warp(7);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000e18, "Batch execution should leave the original position untouched");
        assertEq(margin, 1e6, "Batch execution should preserve the drained custody-backed margin state");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "Batch clearer should receive bounty on post-commit margin-drain invalidation as clearinghouse credit"
        );
        assertEq(
            usdc.balanceOf(alice), 0, "Batch execution should not refund trader bounty on margin-drain invalidation"
        );
    }

    function test_BatchStaleCachedMark_DoesNotBlockMarginDrainInvalidationExecution() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 1e8, false);

        vm.store(address(clearinghouse), keccak256(abi.encode(aliceId, uint256(3))), bytes32(uint256(1e6)));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);
        uint64 freshPublishTime = uint64(block.timestamp);
        uint64 staleMarkTimeBefore = engine.lastMarkTime();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), freshPublishTime);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        router.executeOrderBatch(1, empty);

        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000e18, "Batch execution should fail softly instead of stale-reverting the live position");
        assertEq(margin, 1e6, "Batch execution should preserve the drained custody-backed margin state");
        assertEq(
            engine.lastMarkTime(),
            freshPublishTime,
            "Batch execution should push the fresh resolved mark before release"
        );
        assertLt(staleMarkTimeBefore, engine.lastMarkTime(), "Batch execution should advance the stale cached mark");
        assertEq(
            router.nextExecuteId(), 0, "Batch execution should clear the pending head instead of stalling on stale mark"
        );
    }

    function test_BatchExecution_UsesOrderExecutionPublishTimeDivergenceLimit() public {
        uint256 basePublishTime = block.timestamp + 6;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(feedIds[0], int64(100_000_000), int32(-8), basePublishTime);
        for (uint256 i = 1; i < feedIds.length; i++) {
            mockPyth.setPrice(feedIds[i], int64(100_000_000), int32(-8), basePublishTime + 30);
        }

        vm.warp(basePublishTime + 30);
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, _pythUpdateData());

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(
            size, 10_000e18, "Batch execution should accept feed publish dispersion allowed for normal order execution"
        );
        assertEq(router.nextExecuteId(), 0, "Successful batch execution should clear the queue head");
    }

    function test_BatchPostCommitSkewInvalidationRefundsUserBounty() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, false);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 800_000e6);
        vm.warp(block.timestamp + 6);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp));
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Batch execution should leave invalidated order unopened");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            0,
            "Batch clearer should not receive bounty on skew invalidation"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            1e6,
            "Batch execution should refund trader bounty into clearinghouse settlement on skew invalidation"
        );
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

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        vm.roll(block.number + 1);
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
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

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "Invalid close-order failure should pay the escrowed clearer bounty"
        );
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Invalid close-order failure should not book protocol revenue"
        );
    }

    function test_InvalidClose_OpenPositionFreeBackedBountyPaysKeeper() public {
        address trader = address(0x340);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        address counterparty = address(0x341);
        bytes32 counterpartyId = bytes32(uint256(uint160(counterparty)));

        uint256 depth = 5_000_000 * 1e6;
        _fundTrader(trader, 55_000e6);
        _fundTrader(counterparty, 500_000e6);
        _open(counterpartyId, CfdTypes.Side.BEAR, 500_000e18, 50_000e6, 1e8, depth);

        uint256 minNotional = (uint256(5) * 1e6 * 10_000) / 15 + 1e6;
        uint256 minSize = (minNotional * 1e20) / 1e8;
        _open(accountId, CfdTypes.Side.BULL, minSize, 50_000e6, 1e8, depth);

        uint256 freeSettlementBeforeCommit = _freeSettlementUsdc(accountId);
        assertEq(freeSettlementBeforeCommit, 5000e6, "setup must leave free settlement to back the bounty");
        assertEq(usdc.balanceOf(trader), 0, "trader wallet should start empty after depositing into the clearinghouse");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, minSize - 1, 0, 0, true);

        assertEq(
            _freeSettlementUsdc(accountId),
            freeSettlementBeforeCommit - 1e6,
            "commit should temporarily seize the close bounty from free settlement"
        );

        bytes[] memory empty = _pythUpdateData();
        vm.warp(block.timestamp + 6);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), block.timestamp);
        vm.roll(block.number + 1);
        uint256 keeperBefore = _settlementBalance(address(this));
        router.executeOrder(1, empty);

        assertEq(
            _freeSettlementUsdc(accountId),
            freeSettlementBeforeCommit - 1e6,
            "failed invalid close should keep the free-backed bounty consumed"
        );
        assertEq(usdc.balanceOf(trader), 0, "free-backed bounty refund should not escape to the trader wallet");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "keeper should receive the free-backed bounty as clearinghouse credit"
        );
    }

    function test_CloseCommit_RevertsWhenPendingCloseSizeWouldExceedPosition() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);

        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 6000 * 1e18, 0, 0, true);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 5));
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

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountEscrowView memory afterRevertEscrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 1, "Non-terminal stale failure must leave the queue untouched");
        assertEq(afterRevertEscrow.pendingOrderCount, 2, "All queued escrow should remain after stale revert");

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1050);
        vm.warp(1050);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        IOrderRouterAccounting.AccountEscrowView memory finalEscrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 0, "Honest keeper should later consume both queued orders and clear the queue");
        assertEq(finalEscrow.pendingOrderCount, 0, "Escrow should be fully released after terminal execution");
    }

    function test_StateMachine_BatchClearsSlippageFailedHeadAndContinues() public {
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
        assertEq(router.nextExecuteId(), 2, "Failed head should clear while a later blocked order remains pending");
        assertEq(
            escrow.pendingOrderCount, 1, "The later blocked order should remain pending after the failed head clears"
        );
        assertEq(_executionBountyReserve(1), 0, "Failed head should clear its execution bounty escrow");
        assertEq(
            _executionBountyReserve(2), 1e6, "Later blocked order should retain its escrow after the failed head clears"
        );
    }

    function test_DeferredTraderCredit_CloseDoesNotBlockLaterQueuedOrders() public {
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
        uint256 keeperUsdcBefore = _settlementBalance(address(this));
        vm.roll(block.number + 1);
        router.executeOrderBatch(3, priceData);

        assertEq(
            router.nextExecuteId(),
            0,
            "Deferred-payout close should not stall the FIFO queue and should drain it when no orders remain"
        );
        assertGt(
            engine.deferredTraderCreditUsdc(accountId),
            0,
            "Deferred payout should remain recorded after batch execution"
        );
        assertEq(
            engine.deferredKeeperCreditUsdc(address(this)),
            0,
            "Close execution should not rely on deferred liquidation bounties"
        );
        assertEq(
            _settlementBalance(address(this)) - keeperUsdcBefore,
            1e6,
            "Batch executor should be paid only for the successful close as clearinghouse credit when the failed open tail refunds the user"
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(1, empty);

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(router.nextExecuteId(), 1, "Stale revert should keep queue head pending");
        assertEq(escrow.pendingOrderCount, 1, "Stale revert should preserve escrowed order state");
        assertEq(usdc.balanceOf(address(router)), 1e6, "Router custody should continue escrowing the keeper reserve");
    }

    function testFuzz_SlippageFailureClearsEscrowAndOrder(
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
        assertEq(router.nextExecuteId(), 0, "Terminal slippage miss should clear the queue head");
        assertEq(escrow.pendingOrderCount, 0, "Terminal slippage miss should clear pending escrow state");
        assertEq(usdc.balanceOf(address(router)), 0, "Keeper reserve should not remain escrowed after terminal failure");
    }

    function test_SingleExecute_EmptyQueueRevertsNoOrders() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), uint64(block.timestamp + 6));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0, "Queue head should clear to zero sentinel when empty");

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 0));
        router.executeOrder(1, empty);
    }

    function test_SlippageFailedCloseOrderRefundsEscrowedBounty() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        _open(aliceId, CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8);
        uint64 closeOrderId = router.nextCommitId();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 90_000_000, true);

        vm.warp(block.timestamp + 6);
        bytes[] memory empty = _pythUpdateData();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        vm.roll(block.number + 1);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 feesBefore = engine.accumulatedFeesUsdc();
        router.executeOrder(closeOrderId, empty);

        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            1e6,
            "Terminal close slippage miss should pay keeper bounty as clearinghouse credit under current policy"
        );
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore, 0, "Slippage-failed close order should not book protocol revenue"
        );
        assertEq(router.nextExecuteId(), 0, "Terminal close slippage miss should clear the order");
        assertEq(_executionBountyReserve(closeOrderId), 0, "Close bounty should be refunded on terminal failure");
    }

    function test_InsufficientPythFee_Reverts() public {
        vm.warp(1000);
        mockPyth.setFee(1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory data = new bytes[](1);
        data[0] = hex"00";

        vm.warp(1050);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 6));
        vm.roll(block.number + 1);
        router.executeOrder(1, data);
    }

    function test_LiquidationStaleness_IsStricterThanOrderExecution() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 60;
        config.liquidationStalenessLimit = 15;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2040);
        vm.warp(2050);
        router.updateMarkPrice(empty);

        vm.warp(2056);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeLiquidation(accountId, empty);
    }

    function test_LiquidationStaleness_UsesRouterLiquidationLimit_NotPoolMarkLimit() public {
        pool.proposeMarkStalenessLimit(300);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeMarkStalenessLimit();

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

        vm.warp(2061);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeLiquidation(accountId, empty);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.liquidationStalenessLimit = 61;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(2061 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.warp(2061);
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "BULL open at favorable price should succeed");

        vm.warp(2000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2006);
        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        bytes32 trader2Id = bytes32(uint256(uint160(trader2)));
        (size,,,,,,) = engine.positions(trader2Id);
        assertGt(size, 0, "BEAR open at favorable price should succeed");

        vm.warp(3000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3006);
        vm.warp(3050);
        vm.roll(20);
        router.executeOrder(3, empty);

        (size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "BULL open at adverse price should be rejected");

        vm.warp(4000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 4006);
        vm.warp(4050);
        vm.roll(30);
        router.executeOrder(4, empty);

        (size,,,,,,) = engine.positions(trader2Id);
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
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertTrue(size > 0, "Position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,) = engine.positions(accountId);
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

        assertEq(router.nextExecuteId(), 2, "Batch should stop once the next order fails publish-time ordering");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "Only the pre-publish commitment should execute before batch processing stops");
    }

    function test_C1_PublishTimeBeforeCommit_Reverts() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 13));
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Live execution should reject publish times that predate commit");
    }

    function test_FreshPublishAfterCommit_Executes() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);
        vm.warp(1006);

        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 0, "Fresh post-commit publish should execute normally");
    }

    function test_BatchExecution_StalePrice_Reverts() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1000);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
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

        (uint256 price, uint256 minPt) = harness.computeBasketPrice(60, 60);
        assertEq(price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(minPt, 1001, "minPublishTime should be weakest link");
    }

    function test_WeakestLink_Timestamp_TriggersMev() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 13));
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Weakest-link publish time should still trigger MEV protection");
    }

    function test_WeakestLink_Staleness() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1001);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        vm.roll(block.number + 1);
        router.executeOrderBatch(1, empty);
    }

    function test_BasketPrice_RevertsWhenFeedPublishTimesDivergeTooFar() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 930);

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), feedIds, weights, bases, new bool[](2));
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        harness.computeBasketPrice(3 days, 60);
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
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "BULL position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(250_000_000), int32(-8), 2006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 240_000_000, true);

        vm.warp(2050);
        vm.roll(10);
        router.executeOrder(2, empty);

        (size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "BULL close should succeed against clamped price");
    }

}

contract OrderRouterBlockedExecutionTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    uint256 internal constant TEST_FRIDAY_18UTC = 604_951_200;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        _syncEngineAdmin();
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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
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

    function test_FadWindow_OpenOrderStaysPendingAtExecution() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 7 days;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();

        uint256 fadPublishTime = TEST_FRIDAY_18UTC + 2 hours + 1;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fadPublishTime);

        vm.warp(TEST_FRIDAY_18UTC);
        uint64 orderId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 reservedBounty = _executionBountyReserve(orderId);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        (uint256 sizeBefore,,,,,,) = engine.positions(aliceId);

        vm.warp(TEST_FRIDAY_18UTC + 2 hours + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
        router.executeOrder(orderId, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, sizeBefore, "Open order should remain unexecuted during close-only mode");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            0,
            "Blocked close-only execution should not pay the keeper"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            0,
            "Blocked close-only execution should not refund the trader"
        );
        assertEq(
            _executionBountyReserve(orderId),
            reservedBounty,
            "Blocked close-only execution should preserve bounty escrow"
        );
        assertEq(router.nextExecuteId(), orderId, "Blocked close-only execution should leave the FIFO head pending");
        assertEq(
            router.pendingOrderCounts(aliceId), 1, "Blocked close-only execution should preserve pending order count"
        );
        assertEq(
            uint256(_orderRecord(orderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "Blocked close-only execution should keep the order pending"
        );
    }

    function test_FadWindow_BatchOpenOrderStaysPendingAtBlockedHead() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 7 days;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();

        uint256 fadPublishTime = TEST_FRIDAY_18UTC + 2 hours + 1;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fadPublishTime);

        vm.warp(TEST_FRIDAY_18UTC);
        uint64 orderId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 reservedBounty = _executionBountyReserve(orderId);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        (uint256 sizeBefore,,,,,,) = engine.positions(aliceId);

        vm.warp(TEST_FRIDAY_18UTC + 2 hours + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(orderId, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, sizeBefore, "Open order should remain unexecuted while the batch head is close-only blocked");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore, 0, "Blocked batch execution should not pay the keeper"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            0,
            "Blocked batch execution should not refund the trader"
        );
        assertEq(
            _executionBountyReserve(orderId), reservedBounty, "Blocked batch execution should preserve bounty escrow"
        );
        assertEq(router.nextExecuteId(), orderId, "Blocked batch execution should stop at the pending FIFO head");
        assertEq(router.pendingOrderCounts(aliceId), 1, "Blocked batch execution should preserve pending order count");
        assertEq(
            uint256(_orderRecord(orderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "Blocked batch execution should keep the order pending"
        );
    }

}

contract BasketPriceHarness is OrderRouter {

    constructor(
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderRouter(address(1), address(1), address(1), _pyth, _feedIds, _quantities, _basePrices, _inversions) {}

    function computeBasketPrice(
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) external view returns (uint256, uint256) {
        uint256 minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 basketPrice;

        for (uint256 i = 0; i < pythFeedIds.length; i++) {
            PythStructs.Price memory p = IPyth(address(pyth)).getPriceUnsafe(pythFeedIds[i]);
            if (block.timestamp > uint64(p.publishTime) + maxStaleness) {
                _revertOraclePriceTooStale();
            }

            uint256 norm =
                inversions[i] ? _localInvertPythPrice(p.price, p.expo) : _localNormalizePythPrice(p.price, p.expo);
            basketPrice += (norm * quantities[i]) / (basePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);

            if (p.publishTime < minPublishTime) {
                minPublishTime = p.publishTime;
            }
            if (p.publishTime > maxPublishTime) {
                maxPublishTime = p.publishTime;
            }
        }

        if (maxPublishTime > minPublishTime + maxPublishTimeDivergence) {
            _revertOraclePriceTooStale();
        }
        if (basketPrice == 0) {
            _revertOraclePriceNegative();
        }

        return (basketPrice, minPublishTime);
    }

    function _localInvertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256 normalizedPrice) {
        if (price <= 0) {
            revert OrderRouter.OrderRouter__OracleValidation(8);
        }
        uint256 positivePrice = uint256(uint64(price));
        uint256 scaledPrecision = 10 ** uint256(uint32(26 - expo));
        uint256 scaledInverse = (scaledPrecision + (positivePrice / 2)) / positivePrice;
        return scaledInverse / 1e18;
    }

    function _localNormalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256 normalizedPrice) {
        if (price <= 0) {
            revert OrderRouter.OrderRouter__OracleValidation(8);
        }

        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
    }

}

contract NormalizePythHarness is OrderRouter {

    constructor()
        OrderRouter(
            address(1),
            address(1),
            address(1),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        )
    {}

    function normalizePythPrice(
        int64 price,
        int32 expo
    ) external pure returns (uint256) {
        if (price <= 0) {
            revert OrderRouter.OrderRouter__OracleValidation(8);
        }

        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 900e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this)))));

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, address(this));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this))))) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Immediate liquidation bounty should credit the keeper clearinghouse balance"
        );
    }

    function test_ExecuteLiquidation_DefersKeeperCreditPerPreviewWhenVaultPayoutFails() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 900e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(accountId, address(this));

        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(pool.payOut.selector, address(clearinghouse), preview.keeperBountyUsdc),
            abi.encodeWithSignature("Error(string)", "vault illiquid")
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        router.executeLiquidation(accountId, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(accountId, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(observed.keeperSettlementUsdc, 0, "Failed immediate keeper credit should not reach settlement");
        assertEq(
            observed.deferredKeeperCreditUsdc,
            preview.keeperBountyUsdc,
            "Failed immediate keeper credit should defer the previewed keeper bounty into deferred keeper credit liability"
        );
    }

    function test_ExecuteLiquidation_ForfeitsEscrowedOpenBountiesWithoutCreditingTraderSettlement() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 900e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(address(router)),
            _executionBountyReserve(1) * queuedOrderCount,
            "Router should custody the shielded open-order bounty escrow"
        );
        assertEq(
            router.pendingOrderCounts(accountId),
            queuedOrderCount,
            "Queued open orders should remain pending before liquidation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, 150_000_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        router.executeLiquidation(accountId, priceData);

        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Liquidation should still clear the underwater position");
        assertEq(
            engine.accumulatedBadDebtUsdc(),
            preview.badDebtUsdc,
            "Liquidation should not improve previewed bad debt by restoring execution escrow"
        );
        assertEq(router.getAccountEscrow(accountId).executionBountyUsdc, _executionBountyReserve(1) * queuedOrderCount);
        assertEq(
            preview.reachableCollateralUsdc,
            snapshotBefore.terminalReachableUsdc,
            "Preview must exclude queued execution escrow from liquidation reachability"
        );
        assertEq(
            router.nextExecuteId(),
            0,
            "Liquidation should clear the global queue head when only liquidated-account orders remain"
        );
        assertEq(
            clearinghouse.balanceUsdc(accountId),
            0,
            "Forfeited open-order bounty escrow must not be credited back into trader settlement"
        );
    }

    function test_ExecuteLiquidation_ForfeitedEscrowFeedsPostForfeitureVaultDepth() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 900e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        engineAdmin.proposeEngineMarkStalenessLimit(90 days);
        vm.warp(engineAdmin.engineMarkStalenessActivationTime() + 1);
        engineAdmin.finalizeEngineMarkStalenessLimit();

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 25e6);

        vm.warp(block.timestamp + 60 days);
        uint256 canonicalDepthBefore = pool.totalAssets();

        CfdEngine.LiquidationPreview memory expectedPreview =
            engineLens.simulateLiquidation(accountId, 195_000_000, canonicalDepthBefore);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));

        uint256 keeperBefore = clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this)))));
        router.executeLiquidation(accountId, priceData);

        assertEq(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this))))) - keeperBefore,
            expectedPreview.keeperBountyUsdc,
            "Liquidation bounty should use the post-forfeiture vault depth for funding"
        );
        assertEq(
            engine.accumulatedBadDebtUsdc(),
            expectedPreview.badDebtUsdc,
            "Liquidation bad debt should use the post-forfeiture vault depth for funding"
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

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(accountId);
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
        assertEq(_executionBountyReserve(1), 0, "Liquidation should forfeit the first close-order bounty escrow");
        assertEq(_executionBountyReserve(2), 0, "Liquidation should forfeit the second close-order bounty escrow");
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
        _fundTrader(trader, 900e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(accountId, 70e6);
        vm.stopPrank();

        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        router.executeLiquidation(accountId, priceData);

        assertEq(
            router.nextExecuteId(),
            0,
            "Liquidation should consume the liquidated account's queued orders and clear the queue to the zero sentinel"
        );

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__QueueState.selector, 0));
        router.executeOrderBatch(uint64(queuedOrderCount), priceData);

        assertEq(
            usdc.balanceOf(trader), traderUsdcBefore, "Liquidated trader should not recover escrow after liquidation"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "Router should hold no escrow for post-liquidation recovery");
    }

    function test_ExecuteLiquidation_ClearsOnlyLiquidatedAccountsPendingOrders() public {
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        address otherTrader = address(0xC10B);
        bytes32 otherId = bytes32(uint256(uint160(otherTrader)));

        _fundTrader(trader, 900e6);
        _fundTrader(otherTrader, 2000e6);

        _open(traderId, CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 100e6, type(uint256).max, false);
        clearinghouse.withdraw(traderId, 70e6);
        vm.stopPrank();

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, type(uint256).max, false);
        vm.stopPrank();

        assertEq(router.pendingOrderCounts(traderId), 2, "Liquidated account should start with two queued orders");
        assertEq(router.pendingOrderCounts(otherId), 2, "Unrelated account should start with its own queued orders");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        router.executeLiquidation(traderId, priceData);

        assertEq(router.pendingOrderCounts(traderId), 0, "Liquidation should clear only the liquidated account queue");
        assertEq(router.pendingOrderCounts(otherId), 2, "Unrelated account queue should remain intact");

        IOrderRouterAccounting.PendingOrderView[] memory otherPending = _pendingOrders(otherId);
        assertEq(otherPending.length, 2, "Per-account traversal should still expose unrelated pending orders");
        assertEq(otherPending[0].orderId, 3, "Unrelated account should retain FIFO order ids after cleanup");
        assertEq(otherPending[1].orderId, 4, "Unrelated account queue should preserve its tail order");
    }

    function test_CommitClose_UsesOnlyAccountLocalQueuedPositionProjection() public {
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        address otherTrader = address(0xC10C);

        _fundTrader(trader, 2000e6);
        _fundTrader(otherTrader, 2000e6);
        _open(traderId, CfdTypes.Side.BULL, 20_000e18, 500e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 5000e18, 0, type(uint256).max, true);

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, type(uint256).max, false);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000e18, 500e6, type(uint256).max, false);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 15_000e18, 0, type(uint256).max, true);

        IOrderRouterAccounting.PendingOrderView[] memory traderPending = _pendingOrders(traderId);
        assertEq(traderPending.length, 2, "Trader should be able to queue closes using only its own pending orders");
        assertEq(traderPending[0].sizeDelta, 5000e18, "First close should remain queued");
        assertEq(traderPending[1].sizeDelta, 15_000e18, "Second close should consume only the trader's residual size");
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        _syncEngineAdmin();
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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

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
        (uint256 size,,,,,,) = engine.positions(aliceId);
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
        engineAdmin.proposeAddFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engineAdmin.finalizeAddFadDays();
    }

    function _removeFadDays(
        uint256[] memory timestamps
    ) internal {
        engineAdmin.proposeRemoveFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engineAdmin.finalizeRemoveFadDays();
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        engineAdmin.proposeFadMaxStaleness(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engineAdmin.finalizeFadMaxStaleness();
    }

    function _setFadRunway(
        uint256 val
    ) internal {
        engineAdmin.proposeFadRunway(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engineAdmin.finalizeFadRunway();
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close order should execute during frozen oracle");
    }

    function test_FadWindow_OpenOrder_BlockedDuringFrozen() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function helper_FadWindow_OpenOrderStaysPendingAtExecution() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 7 days;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();

        uint256 fadPublishTime = FRIDAY_18UTC + 2 hours + 1;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fadPublishTime);

        vm.warp(FRIDAY_18UTC);
        uint64 orderId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 reservedBounty = _executionBountyReserve(orderId);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        (uint256 sizeBefore,,,,,,) = engine.positions(aliceId);
        vm.warp(FRIDAY_18UTC + 2 hours + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
        router.executeOrder(orderId, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, sizeBefore, "Open order should remain unexecuted during close-only mode");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore,
            0,
            "Blocked close-only execution should not pay the keeper"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            0,
            "Blocked close-only execution should not refund the trader"
        );
        assertEq(
            _executionBountyReserve(orderId),
            reservedBounty,
            "Blocked close-only execution should preserve bounty escrow"
        );
        assertEq(router.nextExecuteId(), orderId, "Blocked close-only execution should leave the FIFO head pending");
        assertEq(
            router.pendingOrderCounts(aliceId), 1, "Blocked close-only execution should preserve pending order count"
        );
        assertEq(
            uint256(_orderRecord(orderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "Blocked close-only execution should keep the order pending"
        );
    }

    function helper_FadWindow_BatchOpenOrderStaysPendingAtBlockedHead() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 7 days;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours);
        routerAdmin.finalizeRouterConfig();

        uint256 fadPublishTime = FRIDAY_18UTC + 2 hours + 1;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fadPublishTime);

        vm.warp(FRIDAY_18UTC);
        uint64 orderId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        uint256 keeperBefore = _settlementBalance(address(this));
        uint256 reservedBounty = _executionBountyReserve(orderId);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(aliceId);
        (uint256 sizeBefore,,,,,,) = engine.positions(aliceId);
        vm.warp(FRIDAY_18UTC + 2 hours + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(orderId, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, sizeBefore, "Open order should remain unexecuted while the batch head is close-only blocked");
        assertEq(
            _settlementBalance(address(this)) - keeperBefore, 0, "Blocked batch execution should not pay the keeper"
        );
        assertEq(
            clearinghouse.balanceUsdc(aliceId) - traderSettlementBefore,
            0,
            "Blocked batch execution should not refund the trader"
        );
        assertEq(
            _executionBountyReserve(orderId), reservedBounty, "Blocked batch execution should preserve bounty escrow"
        );
        assertEq(router.nextExecuteId(), orderId, "Blocked batch execution should stop at the pending FIFO head");
        assertEq(router.pendingOrderCounts(aliceId), 1, "Blocked batch execution should preserve pending order count");
        assertEq(
            uint256(_orderRecord(orderId).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "Blocked batch execution should keep the order pending"
        );
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(2, empty);
    }

    function test_FadWindow_Liquidation_AcceptsStalePrice() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint64 fridayPublishTime = uint64(FRIDAY_18UTC + 6);
        vm.prank(address(router));
        engine.updateMarkPrice(180_000_000, uint64(block.timestamp));

        mockPyth.setAllPrices(feedIds, int64(180_000_000), int32(-8), fridayPublishTime);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();

        router.executeLiquidation(aliceId, empty);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Liquidation should succeed during FAD with stale price");
        assertEq(
            engine.lastMarkTime(), fridayPublishTime, "Liquidation should accept the frozen-window Friday publish time"
        );
    }

    function test_FadWindow_MarkRefresh_AcceptsStaleFridayPrice() public {
        bytes[] memory empty = _pythUpdateData();
        uint64 fridayPublishTime = uint64(FRIDAY_18UTC + 6);

        vm.warp(SATURDAY_NOON);
        router.updateMarkPrice(empty);

        assertEq(
            engine.lastMarkTime(), fridayPublishTime, "Mark refresh should accept the frozen-window Friday publish time"
        );
        assertEq(engine.lastMarkPrice(), 80_000_000, "Mark refresh should store the Friday oracle price");
    }

    function test_FadWindow_Liquidation_ExcessStaleness_Reverts() public {
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 12));
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 5000 * 1e18, "Partial close should reduce position");
    }

    function test_FadBatch_ExcessStaleness_FrozenReverts() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "61s stale on weekday should leave the close order unexecuted");
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
        (uint256 size,,,,,,) = engine.positions(carolId);
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
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__ZeroStaleness.selector);
        engineAdmin.proposeFadMaxStaleness(0);
    }

    function test_Admin_AddFadDays_NonOwner_Reverts() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;

        vm.prank(alice);
        vm.expectRevert();
        engineAdmin.proposeAddFadDays(timestamps);
    }

    function test_Admin_EmptyDays_Reverts() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(CfdEngine.CfdEngine__EmptyDays.selector);
        engineAdmin.proposeAddFadDays(empty);
    }

    function test_AdminFadDay_BlockedDuringFrozen() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = MONDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(MONDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close with fresh price should succeed during Friday gap");
    }

    function test_FridayGap_OpenStillBlocked() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "60s staleness must apply during Friday gap");
    }

    function test_FridayGap_LiquidationUsesRouterLiquidationStalenessLimit() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), FRIDAY_20UTC);

        vm.warp(FRIDAY_20UTC + 61);
        bytes[] memory empty = _pythUpdateData();
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 12));
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(2, empty);
    }

    function test_SundayDst_StillFadAt21() public {
        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__CommitValidation.selector, 10));
        router.commitOrder(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), wednesdayMidnight - 3 hours + 6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(wednesdayMidnight - 3 hours + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(2, empty);
    }

    function test_Runway_SetFadRunway() public {
        assertEq(engine.fadRunwaySeconds(), 3 hours);
        _setFadRunway(6 hours);
        assertEq(engine.fadRunwaySeconds(), 6 hours);
    }

    function test_Runway_TooLong_Reverts() public {
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__RunwayTooLong.selector);
        engineAdmin.proposeFadRunway(25 hours);
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
        (uint256 price,) = harness.computeBasketPrice(60, 60);

        uint256 expectedNorm = (uint256(1e29) + (156_700 / 2)) / 156_700 / 1e18;
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

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 1));
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

        (uint256 price,) = harness.computeBasketPrice(60, 60);

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

        (uint256 pythPrice,) = harness.computeBasketPrice(60, 60);

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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
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
        (uint256 size,,,,,,) = engine.positions(carolAccount);
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

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 4));
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);
    }

    // Regression: H-02 — stale order executes via executeOrder
    function test_StaleOrderExecutesViaExecuteOrder() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 300;
        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();

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

        (uint256 size,,,,,,) = engine.positions(accountId);
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
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        routerAdmin.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        routerAdmin.unpause();
        vm.roll(10);
        router.executeOrder(2, empty);

        (uint256 sizeAfter,,,,,,) = engine.positions(accountId);
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 300;
        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();
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
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(spammer, 10_000 * 1e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);
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

    // Regression: queue liveness hardening
    function test_BatchExecution_PrunesExpiredOrdersInBoundedSlices() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        uint256 traderCount = 13;
        uint256 ordersPerTrader = 5;

        for (uint256 traderIndex = 0; traderIndex < traderCount; traderIndex++) {
            address trader = address(uint160(0xC100 + traderIndex));
            _fundTrader(trader, 10_000 * 1e6);
            for (uint256 orderIndex = 0; orderIndex < ordersPerTrader; orderIndex++) {
                vm.prank(trader);
                router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
            }
        }

        _fundTrader(alice, 50_000 * 1e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrderBatch(66, empty);

        assertEq(router.nextExecuteId(), 65, "Batch should prune only a bounded number of expired orders per call");

        vm.roll(block.number + 1);
        router.executeOrderBatch(66, empty);
        assertEq(router.nextExecuteId(), 0, "Second batch call should finish pruning the remaining expired orders");
    }

    // Regression: H-03
    function test_SetMaxOrderAge_OnlyOwner() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxOrderAge = 600;
        vm.prank(spammer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, spammer));
        routerAdmin.proposeRouterConfig(config);

        routerAdmin.proposeRouterConfig(config);
        _warpForward(48 hours + 1);
        routerAdmin.finalizeRouterConfig();
        assertEq(router.maxOrderAge(), 600);
    }

    // Regression: H-01
    function test_ExpiredOrderFeeRefundedToUser_ViaSkip() public {
        vm.deal(spammer, 1 ether);
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(spammer, 10_000e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);
    }

    function test_ExpiredOpenOrderRefundsUsdcBountyToTrader_NotKeeper() public {
        address localKeeper = address(0x999);
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(spammer, 10_000e6);

        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        uint256 traderSettlementBefore = _settlementBalance(spammer);
        uint256 keeperSettlementBefore = _settlementBalance(localKeeper);

        vm.warp(block.timestamp + 301);
        bytes[] memory empty;
        vm.prank(localKeeper);
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        assertEq(
            _settlementBalance(localKeeper) - keeperSettlementBefore, 0, "Expired open order should not pay the keeper"
        );
        assertEq(
            _settlementBalance(spammer) - traderSettlementBefore,
            1e6,
            "Expired open order should refund the trader bounty into clearinghouse settlement"
        );
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
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
        _syncEngineAdmin();
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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);
        _bootstrapSeededLifecycle();
    }

    function test_UpdateMarkPrice_RevertsOnStaleOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 120);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.updateMarkPrice(updateData);
    }

    function test_UpdateMarkPrice_AcceptsFreshOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 30);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);
        assertEq(engine.lastMarkPrice(), 1e8);
    }

    function test_Constructor_ZeroEngineLensReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 7));
        new OrderRouter(
            address(engine), address(0), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
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
        _syncEngineAdmin();
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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.setEngine(address(engine));
        vm.warp(SETUP_TIMESTAMP);
        _bootstrapSeededLifecycle();
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    // Regression: H-02
    function test_StaleOracleRevertsInsteadOfCancelling() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 120);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(attacker);
        vm.roll(block.number + 1);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "stale oracle should leave the order unexecuted when execution reverts");
    }

}

// Regression: C-05
contract VpiImrBypassTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    OrderRouterAdmin routerAdmin;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _settlementBalance(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.balanceUsdc(bytes32(uint256(uint160(account))));
    }

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 1e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
        _bootstrapSeededLifecycle();
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

    function _orderStatus(
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.OrderStatus) {
        return OrderRouterDebugLens.loadOrderStatus(vm, router, orderId);
    }

    // Rebate-aware open validation should allow commits when a skew-reducing rebate
    // supplies the missing reachable collateral for IMR.
    function test_VpiRebateCanSatisfyReachableCollateralProjection() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address eve = address(0xE222);
        bytes32 eveAccount = bytes32(uint256(uint160(eve)));

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        vm.stopPrank();

        assertEq(clearinghouse.balanceUsdc(eveAccount), 1e6, "Trader only funds the reserved execution bounty");

        vm.prank(eve);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);

        assertEq(router.nextCommitId(), 3, "Rebate-backed open should remain committable under the planner");
    }

    function test_TypedUserInvalidOpenPaysClearer() public {
        address eve = address(0xE223);
        bytes32 eveAccount = bytes32(uint256(uint160(eve)));

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        vm.stopPrank();

        uint256 keeperBefore = _settlementBalance(address(this));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(bytes32(uint256(uint160(address(this))))) - keeperBefore,
            1e6,
            "Typed user-invalid open should pay the clearer as clearinghouse credit"
        );
        assertEq(
            uint256(_orderStatus(1)),
            uint256(IOrderRouterAccounting.OrderStatus.Failed),
            "Order should fail"
        );
        assertEq(usdc.balanceOf(address(router)), 0, "Router should not retain consumed user-invalid bounty escrow");
    }

}

// Regression: H-01
contract KeeperFeeRefundTest is Test {

    // Policy matrix coverage in this contract/file:
    // - expired open -> trader refunded: test_ExpiredOrderFeeRefundedToUser, test_ExpiredOpenOrderRefundsUsdcBountyToTrader_NotKeeper
    // - expired close -> clearer paid: test_ExitedAccount_ExpiredCloseOrderPaysClearerBounty
    // - slippage open -> trader refunded: test_SlippageFailFeeRefundedToUser
    // - slippage close -> clearer paid: test_CloseSlippageFailPaysClearerWhenBountyIsMarginBacked
    // - protocol invalidation -> trader refunded: test_PostCommitDegradedModeRefundsUserBounty
    // - user invalid -> clearer paid: test_TypedUserInvalidOpenPaysClearer

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    OrderRouterAdmin routerAdmin;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    function _accountIdOf(
        address account
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _settlementBalance(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.balanceUsdc(_accountIdOf(account));
    }

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: 300,
            orderExecutionStalenessLimit: router.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.liquidationStalenessLimit(),
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps()
        });
        routerAdmin.proposeRouterConfig(config);
        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
        routerAdmin.finalizeRouterConfig();
        _bootstrapSeededLifecycle();

        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();
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
        uint256 deferredKeeperCreditBefore = engine.totalDeferredKeeperCreditUsdc();
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        assertEq(keeper.balance - keeperBefore, 0, "Keeper should not receive fee on slippage failure");
        assertEq(alice.balance, 1 ether, "User receives slippage-failure refund");
        assertEq(
            engine.totalDeferredKeeperCreditUsdc(),
            deferredKeeperCreditBefore,
            "Slippage failure should not leak failed-order bounty into deferred keeper credit liabilities"
        );
    }

    function test_CloseSlippageFailPaysClearerWhenBountyIsMarginBacked() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 251_500_000);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), 251_500_000);
        clearinghouse.deposit(accountId, 251_500_000);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = new bytes[](1);
        openPrice[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, openPrice);

        uint256 freeSettlementBefore = clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc;
        assertEq(
            freeSettlementBefore, 500_000, "Setup should leave only partial free settlement before the close commit"
        );

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0.8e8, true);

        uint256 keeperUsdcBefore = _settlementBalance(keeper);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        vm.prank(keeper);
        vm.roll(block.number + 1);
        router.executeOrder(2, closePrice);

        (uint256 sizeAfter,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 10_000e18, "Terminal slippage failure should leave the position open");
        assertEq(
            _settlementBalance(keeper) - keeperUsdcBefore,
            1e6,
            "Terminal close slippage should pay the clearer as clearinghouse credit"
        );
        assertEq(usdc.balanceOf(alice), 0, "Trader wallet should not receive margin-backed close bounty refunds");
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
    TrancheVault seniorVault;
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

    function _bootstrapSeededLifecycle() internal {
        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();
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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
        _bootstrapSeededLifecycle();
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
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
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

        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Frozen-window close should execute when only stale Friday price exists");
    }

}

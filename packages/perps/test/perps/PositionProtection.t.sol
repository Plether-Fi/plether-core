// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

contract PositionProtectionTest is BasePerpTest {

    using stdStorage for StdStorage;

    struct RiskBoundaryFixture {
        uint256 requirementUsdc;
        uint256 exactOpeningMarginDeltaUsdc;
        uint256 plusOneOpeningMarginDeltaUsdc;
        uint256 protectionBountiesUsdc;
    }

    struct RiskOffRefundFixture {
        uint256 freeBefore;
        uint256 settlementBefore;
        uint256 cleanerSettlementBefore;
        uint256 parentMarginUsdc;
        uint256 parentBountyUsdc;
        uint256 protectionBountiesUsdc;
        uint64 parentOrderId;
        uint64 protectionId;
    }

    IPositionProtectionBook internal protectionBook;
    IPositionProtectionActions internal protectionActions;
    IPositionProtectionViews internal protectionViews;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant TRIGGER_KEEPER = address(0x7106);
    address internal constant EXECUTION_KEEPER = address(0xE0EC);
    address internal constant CAROL = address(0xCA201);
    address internal constant RISK_EXACT = address(0xB0A0D1);
    address internal constant RISK_PLUS_ONE = address(0xB0A0D2);

    uint256 internal constant MARK_PRICE = 1e8;
    uint256 internal constant POSITION_SIZE = 10_000e18;
    uint256 internal constant POSITION_MARGIN_USDC = 2000e6;
    uint256 internal constant LONG_TAKE_PROFIT = 90_000_000;
    uint256 internal constant LONG_STOP_LOSS = 110_000_000;
    uint256 internal constant SHORT_TAKE_PROFIT = 110_000_000;
    uint256 internal constant SHORT_STOP_LOSS = 90_000_000;
    uint256 internal constant FRIDAY_FAD_START = 1_709_933_400;
    bytes32 internal constant RISK_OFF_RESERVES_REFUNDED_TOPIC =
        keccak256("RiskOffOrderReservesRefunded(address,uint256,uint256)");

    function setUp() public override {
        super.setUp();

        protectionBook = router.positionProtectionBook();
        protectionActions = IPositionProtectionActions(address(protectionBook));
        protectionViews = IPositionProtectionViews(address(protectionBook));

        _fundTrader(ALICE, 20_000e6);
        _fundTrader(BOB, 20_000e6);
        _fundTrader(CAROL, 20_000e6);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = true;
        _setRouterConfig(config);
        _refreshMark(MARK_PRICE);
    }

    function test_Constructor_RejectsZeroRouterOrEngine() public {
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__ZeroAddress.selector);
        new PositionProtectionBook(address(0), address(engine));

        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__ZeroAddress.selector);
        new PositionProtectionBook(address(router), address(0));
    }

    function test_CreatePositionProtection_RejectsNoPositionAndDegradedMode() public {
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOpenPosition.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__DegradedMode.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            0,
            "failed protection creation must roll back both bounty locks"
        );
    }

    function test_CreatePositionProtection_RejectsEmptyOrAboveCapThresholds() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(0, 0));

        uint256 capPrice = engine.CAP_PRICE();
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(capPrice + 1, 0));

        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            0,
            "invalid protection prices must roll back both bounty locks"
        );
    }

    function test_CreatePositionProtection_ValidatesLongGeometryAndArmsOffQueue() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(LONG_STOP_LOSS, LONG_TAKE_PROFIT));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(MARK_PRICE, 0));

        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(protectionId, 1, "first protection id");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "active protection id");
        assertEq(protection.account, ALICE, "protection owner");
        assertEq(uint8(protection.side), uint8(CfdTypes.Side.LONG), "protected side");
        assertEq(protection.size, POSITION_SIZE, "full position size");
        assertEq(protection.takeProfitTriggerPrice, LONG_TAKE_PROFIT, "take-profit threshold");
        assertEq(protection.stopLossTriggerPrice, LONG_STOP_LOSS, "stop-loss threshold");
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "protection should arm immediately"
        );
        assertEq(router.pendingOrderCounts(ALICE), 0, "armed protection must not be an ordinary order");
        assertEq(router.pendingCloseSize(ALICE), 0, "armed protection must not reserve queued close size");
        assertEq(router.nextCommitId(), 1, "armed protection must not consume an order id");
        assertEq(
            _freeSettlementUsdc(ALICE),
            freeBefore - _totalProtectionBountyUsdc(),
            "both protection bounties should be reserved"
        );
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            _totalProtectionBountyUsdc(),
            "reservation view should include dormant protection bounties"
        );
    }

    function test_CreatePositionProtection_ValidatesShortGeometry() public {
        _open(ALICE, CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(SHORT_STOP_LOSS, SHORT_TAKE_PROFIT));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(MARK_PRICE, 0));

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(SHORT_TAKE_PROFIT, SHORT_STOP_LOSS));

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(uint8(protection.side), uint8(CfdTypes.Side.SHORT), "protected side");
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "short protection should arm"
        );
    }

    function test_LongTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        _expectTriggerNotMet(protectionId, LONG_TAKE_PROFIT + 2);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            LONG_TAKE_PROFIT
        );
    }

    function test_LongStopLoss_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);

        _expectTriggerNotMet(protectionId, LONG_STOP_LOSS - 1);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, LONG_STOP_LOSS
        );
    }

    function test_ShortTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.SHORT, SHORT_TAKE_PROFIT, 0);

        _expectTriggerNotMet(protectionId, SHORT_TAKE_PROFIT - 1);
        uint64 linkedOrderId = _triggerAt(protectionId, SHORT_TAKE_PROFIT);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            SHORT_TAKE_PROFIT
        );
        assertEq(
            _orderRecord(linkedOrderId).core.targetPrice,
            1,
            "linked close should use the canonical unbounded SHORT-close sentinel"
        );
    }

    function test_ShortStopLoss_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.SHORT, 0, SHORT_STOP_LOSS);

        _expectTriggerNotMet(protectionId, SHORT_STOP_LOSS + 2);
        uint64 linkedOrderId = _triggerAt(protectionId, SHORT_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, SHORT_STOP_LOSS
        );
    }

    function test_TriggeredProtection_RejectsReplacementAndCancellation() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        vm.startPrank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotArmed.selector);
        protectionActions.replacePositionProtection(protectionId, _params(LONG_TAKE_PROFIT - 1, 0));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotArmed.selector);
        protectionActions.cancelPositionProtection(protectionId);
        vm.stopPrank();

        PositionProtectionTypes.PositionProtectionView memory triggered =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(triggered.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "rejected mutations must preserve triggered lifecycle"
        );
        assertEq(triggered.linkedOrderId, linkedOrderId, "rejected mutations must preserve the linked close");
        assertEq(
            protectionViews.activePositionProtectionId(ALICE),
            protectionId,
            "rejected mutations must preserve the active trade lock"
        );
    }

    function test_TriggerPositionProtection_RejectsSameBlockAndOldPublishTime() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);

        bytes[] memory sameBlockData = _priceData(LONG_TAKE_PROFIT);
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SameBlockTrigger.selector);
        protectionActions.triggerPositionProtection(protectionId, sameBlockData);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(LONG_TAKE_PROFIT)), 0, int32(-8), armed.armedAt);
        bytes[] memory oldPublishData = new bytes[](1);
        oldPublishData[0] = hex"01";

        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SameBlockTrigger.selector);
        protectionActions.triggerPositionProtection(protectionId, oldPublishData);

        PositionProtectionTypes.PositionProtectionView memory afterReverts =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(afterReverts.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "timing reverts must preserve armed protection"
        );
        assertEq(afterReverts.linkedOrderId, 0, "timing reverts must not create a close");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            _totalProtectionBountyUsdc(),
            "timing reverts must preserve both bounties"
        );
    }

    function test_TriggeredClose_AppendsToGlobalFifoAndExecutesThroughOrdinaryPath() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        vm.prank(BOB);
        router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_USDC, 0, false);
        assertEq(router.nextExecuteId(), 1, "foreign order should be queue head");

        uint256 triggerKeeperBefore = clearinghouse.balanceUsdc(TRIGGER_KEEPER);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        assertEq(linkedOrderId, 2, "triggered close should consume the next ordinary order id");
        assertEq(router.nextExecuteId(), 1, "triggered close must not jump the foreign head");
        assertEq(router.globalTailOrderId(), linkedOrderId, "triggered close should join the FIFO tail");
        assertEq(_orderRecord(1).nextGlobalOrderId, linkedOrderId, "foreign head should link to close");
        assertEq(_orderRecord(linkedOrderId).prevGlobalOrderId, 1, "close should link back to foreign head");
        assertEq(
            clearinghouse.balanceUsdc(TRIGGER_KEEPER) - triggerKeeperBefore,
            router.positionProtectionTriggerBountyUsdc(),
            "trigger keeper should be paid exactly once"
        );

        CfdTypes.Order memory closeOrder = _orderRecord(linkedOrderId).core;
        assertEq(closeOrder.account, ALICE, "linked close owner");
        assertEq(closeOrder.sizeDelta, POSITION_SIZE, "linked close should cover the full position");
        assertEq(closeOrder.marginDelta, 0, "linked close margin delta");
        assertEq(
            closeOrder.targetPrice,
            engine.CAP_PRICE(),
            "linked close should use the canonical unbounded LONG-close sentinel"
        );
        assertEq(uint8(closeOrder.side), uint8(CfdTypes.Side.LONG), "linked close side");
        assertTrue(closeOrder.isClose, "linked order should be reduce-only");
        assertEq(router.pendingCloseSize(ALICE), POSITION_SIZE, "linked close aggregate");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "trigger must transfer, not duplicate, the close bounty"
        );

        bytes[] memory nonHeadExecutionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        router.executeOrder(linkedOrderId, nonHeadExecutionData);

        bytes[] memory bobExecutionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(1, bobExecutionData);

        uint256 executionKeeperBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);
        bytes[] memory closeExecutionData = _mockPythUpdateData(LONG_TAKE_PROFIT);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(linkedOrderId, closeExecutionData);

        PositionProtectionTypes.PositionProtectionView memory terminal =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(terminal.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "successful linked close should terminalize protection"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "terminal protection should release trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "terminal close should leave no account order");
        assertEq(router.pendingCloseSize(ALICE), 0, "terminal close should clear pending size");
        assertEq(
            clearinghouse.balanceUsdc(EXECUTION_KEEPER) - executionKeeperBefore,
            router.closeOrderExecutionBountyUsdc(),
            "close executor should receive the remaining bounty once"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "linked close should fully exit the protected position");
    }

    function test_TriggeredClose_ExecutesInDegradedModeBelowSettlementBufferWhileRawSolvent() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 settlementBufferUsdc = _settlementBufferTargetUsdc(maxLiabilityUsdc);
        _drainPoolTo(maxLiabilityUsdc);

        assertEq(pool.totalAssets(), maxLiabilityUsdc, "setup should retain raw solvency equality");
        assertGt(settlementBufferUsdc, 0, "live protection should require a nonzero settlement buffer");
        assertLt(
            pool.totalAssets(),
            maxLiabilityUsdc + settlementBufferUsdc,
            "setup should leave the live position below the open-admission buffer target"
        );

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertTrue(engine.degradedMode(), "setup should latch risk-off mode");

        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        bytes[] memory executionData = _mockPythUpdateData(LONG_TAKE_PROFIT);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(linkedOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory terminal =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(terminal.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "buffer headroom and degraded mode must not block a protective close"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "successful TP should release the trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "successful TP should leave no queued close");
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "profitable TP should fully close the protected position");
        assertTrue(engine.degradedMode(), "a safety close must not silently clear the risk-off latch");
    }

    function test_ExpiredProtectionAttempt_RelatchesRetainsBountyAndPaysNoCleaner() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        uint256 actionReserveBefore = clearinghouse.actionReserveUsdc(ALICE);
        uint256 cleanerBalanceBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);

        OrderV2Types.ExecutionResult memory result = _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed), "expiry lifecycle status");
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.Expired), "expiry reason");
        assertEq(
            clearinghouse.balanceUsdc(EXECUTION_KEEPER),
            cleanerBalanceBefore,
            "failed protection-attempt cleaner must not consume the reusable bounty"
        );

        PositionProtectionTypes.PositionProtectionView memory latched =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(latched.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "expired close attempt should relatch"
        );
        assertEq(latched.linkedOrderId, linkedOrderId, "latched protection retains latest attempt history");
        assertEq(latched.executionBountyUsdc, executionBountyUsdc, "Book should recover the original close bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "latch keeps the trade lock active");
        assertEq(router.pendingOrderCounts(ALICE), 0, "expired attempt should leave no live account order");
        assertEq(router.pendingCloseSize(ALICE), 0, "expired attempt should clear pending close size");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            executionBountyUsdc,
            "reservation view should include the Book-held bounty"
        );
        assertEq(
            clearinghouse.actionReserveUsdc(ALICE),
            actionReserveBefore,
            "expiry should not change the underlying action reserve"
        );

        OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(linkedOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.Expired), "receipt expiry reason");
        assertEq(
            uint8(outcome.bountyDisposition),
            uint8(OrderV2Types.BountyDisposition.RetainedForProtectionRetry),
            "receipt should authenticate retained retry funding"
        );
        assertEq(outcome.bountyUsdc, executionBountyUsdc, "receipt should preserve the bounty amount");
        assertEq(outcome.bountyRecipient, address(0), "retained bounty has no recipient");
        assertFalse(router.lifecycleBook().isProtectionAttempt(linkedOrderId), "terminal receipt should clear marker");
    }

    function test_RetryPositionProtectionClose_IsPermissionlessFreshAndAppendsFifoTail() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        CfdTypes.Order memory firstOrder = _orderRecord(firstOrderId).core;
        uint64 firstValidUntil = router.lifecycleBook().pendingPolicy(firstOrderId).validUntil;
        PositionProtectionTypes.PositionProtectionView memory triggered =
            protectionViews.getPositionProtection(protectionId);

        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        vm.prank(BOB);
        uint64 foreignOrderId = router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_USDC, 0, false);
        assertEq(router.nextExecuteId(), foreignOrderId, "foreign order should become the FIFO head");

        vm.deal(CAROL, 1);
        vm.prank(CAROL);
        (bool payableRetrySucceeded,) = address(protectionActions).call{value: 1}(
            abi.encodeCall(IPositionProtectionActions.retryPositionProtectionClose, (protectionId))
        );
        assertFalse(payableRetrySucceeded, "retry must remain nonpayable");
        assertEq(address(protectionBook).balance, 0, "rejected ETH must never enter the Book");

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);

        assertGt(retryOrderId, firstOrderId, "retry should receive a fresh order id");
        assertEq(router.nextExecuteId(), foreignOrderId, "retry must not jump the existing FIFO head");
        assertEq(router.globalTailOrderId(), retryOrderId, "retry should append at the global tail");
        assertEq(_orderRecord(foreignOrderId).nextGlobalOrderId, retryOrderId, "foreign head should point to retry");
        assertEq(_orderRecord(retryOrderId).prevGlobalOrderId, foreignOrderId, "retry should point to prior tail");

        CfdTypes.Order memory retryOrder = _orderRecord(retryOrderId).core;
        OrderV2Types.ExecutionBounds memory retryBounds = router.lifecycleBook().pendingPolicy(retryOrderId);
        assertGt(retryOrder.commitTime, firstOrder.commitTime, "retry should use a fresh commit clock");
        assertEq(retryOrder.commitTime, block.timestamp, "retry commit time");
        assertEq(retryOrder.commitBlock, block.number, "retry commit block");
        assertGt(retryBounds.validUntil, firstValidUntil, "retry should receive a fresh validity window");
        assertEq(
            retryBounds.validUntil,
            retryOrder.commitTime + uint64(router.maxOrderAge()),
            "retry deadline should derive from its own commit time"
        );
        assertTrue(
            router.lifecycleBook().isProtectionAttempt(retryOrderId), "retry should carry protected-attempt marker"
        );

        PositionProtectionTypes.PositionProtectionView memory retried =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(retried.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "retry should install one live child"
        );
        assertEq(retried.linkedOrderId, retryOrderId, "retry should become the latest linked order");
        assertEq(retried.executionBountyUsdc, 0, "Book should transfer bounty attribution to retry child");
        assertEq(
            _orderRecord(retryOrderId).executionBountyUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "retry should reuse the original bounty"
        );
        assertEq(uint8(retried.triggeredLeg), uint8(triggered.triggeredLeg), "retry must preserve trigger leg");
        assertEq(retried.triggerMarkPrice, triggered.triggerMarkPrice, "retry must preserve trigger mark");
        assertEq(retried.triggerPublishTime, triggered.triggerPublishTime, "retry must preserve trigger publish time");

        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotLatched.selector);
        protectionActions.retryPositionProtectionClose(protectionId);
        assertEq(router.pendingOrderCounts(ALICE), 1, "double retry must not create another child");
    }

    function test_RetryPositionProtectionClose_StaleOldAttemptCallbacksCannotMutateReplacement() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 oldOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        _expireProtectionAttempt(oldOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);

        vm.startPrank(address(router));
        protectionBook.afterOrderTerminal(oldOrderId, ALICE, IOrderRouterAccounting.OrderStatus.Executed);
        bool retained = protectionBook.handleFailedProtectionAttempt(
            oldOrderId, ALICE, OrderV2Types.TerminalReason.Expired, executionBountyUsdc
        );
        vm.stopPrank();

        assertFalse(retained, "obsolete failed-attempt callback must be ignored");
        PositionProtectionTypes.PositionProtectionView memory replacement =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(replacement.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "obsolete terminal callback must not resolve the replacement attempt"
        );
        assertEq(replacement.linkedOrderId, retryOrderId, "obsolete callbacks must not restore the old attempt");
        assertEq(replacement.executionBountyUsdc, 0, "replacement child must retain bounty attribution");
        assertEq(
            protectionViews.activePositionProtectionId(ALICE), protectionId, "replacement must keep the trade lock"
        );
        assertFalse(router.lifecycleBook().isProtectionAttempt(oldOrderId), "old attempt marker must stay cleared");
        assertTrue(
            router.lifecycleBook().isProtectionAttempt(retryOrderId), "replacement attempt marker must stay live"
        );
        assertEq(router.pendingOrderCounts(ALICE), 1, "obsolete callbacks must not unlink the replacement");
        assertEq(_orderRecord(retryOrderId).executionBountyUsdc, executionBountyUsdc, "replacement bounty must survive");
    }

    function test_RetryPositionProtectionClose_OracleWindowStartsStrictlyAfterFreshCommit() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 oldOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        CfdTypes.Order memory oldOrder = _orderRecord(oldOrderId).core;
        _expireProtectionAttempt(oldOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        CfdTypes.Order memory retryOrder = _orderRecord(retryOrderId).core;
        assertGt(retryOrder.commitTime, oldOrder.commitTime + 1, "retry must start after the old oracle window tick");

        vm.warp(uint256(retryOrder.commitTime) + 1);
        vm.roll(block.number + 1);

        bytes[] memory oldWindowData =
            _mockUniquePythUpdateDataAt(MARK_PRICE, oldOrder.commitTime + 1, oldOrder.commitTime);
        vm.prank(EXECUTION_KEEPER);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(retryOrderId, oldWindowData);

        bytes[] memory commitBoundaryData =
            _mockUniquePythUpdateDataAt(MARK_PRICE, retryOrder.commitTime, retryOrder.commitTime - 1);
        vm.prank(EXECUTION_KEEPER);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(retryOrderId, commitBoundaryData);

        assertEq(router.nextExecuteId(), retryOrderId, "ticks at or before the retry commit must leave it pending");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "rejected old-window ticks must preserve the live retry"
        );

        bytes[] memory firstValidTickData =
            _mockUniquePythUpdateDataAt(MARK_PRICE, retryOrder.commitTime + 1, retryOrder.commitTime);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(retryOrderId, firstValidTickData);

        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "first strictly post-retry tick must execute"
        );
    }

    function test_RetryPositionProtectionClose_OracleWindowIncludesFreshDeadlineButNotLaterTicks() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 oldOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expireProtectionAttempt(oldOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        CfdTypes.Order memory retryOrder = _orderRecord(retryOrderId).core;
        uint64 settlementDeadline =
            uint64(uint256(retryOrder.commitTime) + router.pletherOracle().orderSettlementWindow());

        vm.warp(uint256(settlementDeadline) + 1);
        vm.roll(block.number + 1);

        bytes[] memory afterDeadlineData =
            _mockUniquePythUpdateDataAt(MARK_PRICE, settlementDeadline + 1, retryOrder.commitTime);
        vm.prank(EXECUTION_KEEPER);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(retryOrderId, afterDeadlineData);

        assertEq(router.nextExecuteId(), retryOrderId, "post-deadline tick must leave the retry pending");
        assertTrue(
            router.lifecycleBook().isProtectionAttempt(retryOrderId), "rejected tick must keep retry attribution"
        );

        bytes[] memory deadlineData = _mockUniquePythUpdateDataAt(MARK_PRICE, settlementDeadline, retryOrder.commitTime);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(retryOrderId, deadlineData);

        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "tick exactly at the retry settlement deadline must execute"
        );
    }

    function test_RetryPositionProtectionClose_PriceRecoveryDoesNotCancelLatchedIntent() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        _refreshMark(MARK_PRICE);
        assertGt(MARK_PRICE, LONG_TAKE_PROFIT, "fixture should move back across the original TP threshold");

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        assertEq(
            protectionViews.getPositionProtection(protectionId).triggerMarkPrice,
            LONG_TAKE_PROFIT,
            "price recovery must not rewrite the latched trigger"
        );

        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        uint256 executorBalanceBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);
        bytes[] memory executionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(retryOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory executed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(executed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "fresh attempt should eventually execute despite price recovery"
        );
        assertEq(executed.triggerMarkPrice, LONG_TAKE_PROFIT, "terminal protection keeps original trigger evidence");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "successful retry should release trade lock");
        assertEq(
            clearinghouse.balanceUsdc(EXECUTION_KEEPER) - executorBalanceBefore,
            executionBountyUsdc,
            "successful retry should pay the original bounty exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "success should clear bounty reserve");
        assertEq(clearinghouse.actionReserveUsdc(ALICE), 0, "success should consume the action reserve");
        OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(retryOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.Executed), "successful retry receipt");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid), "paid disposition");
        assertEq(outcome.bountyRecipient, EXECUTION_KEEPER, "receipt bounty recipient");
        assertEq(outcome.bountyUsdc, executionBountyUsdc, "receipt bounty amount");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "success should clear attempt marker");
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "successful retry should fully close the position");
    }

    function test_FailedProtectionAttempt_PositionMismatchFailsAndPaysCleanerExactlyOnce() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();

        CfdTypes.Order memory outOfBandPartialClose = CfdTypes.Order({
            account: ALICE,
            sizeDelta: 100e18,
            marginDelta: 0,
            targetPrice: engine.CAP_PRICE(),
            commitTime: uint64(block.timestamp - 1),
            commitBlock: uint64(block.number - 1),
            orderId: type(uint64).max,
            side: CfdTypes.Side.LONG,
            isClose: true
        });
        uint256 poolDepthUsdc = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(outOfBandPartialClose, MARK_PRICE, poolDepthUsdc, uint64(block.timestamp));
        (uint256 mismatchedSize,,,,,,) = engine.positions(ALICE);
        assertEq(mismatchedSize, POSITION_SIZE - 100e18, "fixture should change the protected position size");

        uint256 cleanerBalanceBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);
        _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);

        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "mismatched position should terminally fail protection"
        );
        assertEq(failed.executionBountyUsdc, 0, "failed protection must not retain the child bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "terminal mismatch should clear active id");
        assertEq(
            clearinghouse.balanceUsdc(EXECUTION_KEEPER) - cleanerBalanceBefore,
            executionBountyUsdc,
            "mismatch cleaner should receive the child bounty exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "mismatch should clear reserve view");
        assertEq(clearinghouse.actionReserveUsdc(ALICE), 0, "mismatch payout should consume the action reserve");

        OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(linkedOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV2Types.TerminalReason.Expired), "mismatch receipt reason");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid), "paid receipt");
        assertEq(outcome.bountyRecipient, EXECUTION_KEEPER, "cleaner receipt recipient");
        assertEq(outcome.bountyUsdc, executionBountyUsdc, "cleaner receipt bounty");
        assertFalse(router.lifecycleBook().isProtectionAttempt(linkedOrderId), "mismatch should clear attempt marker");
    }

    function test_RetryPositionProtectionClose_ReusesSnapshotAfterBountyConfigChangeWithoutFreshFunds() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        _withdrawAllFreeSettlement(ALICE);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 originalBountyUsdc = router.closeOrderExecutionBountyUsdc();
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        uint256 actionReserveBefore = clearinghouse.actionReserveUsdc(ALICE);
        assertEq(actionReserveBefore, originalBountyUsdc, "fixture should retain only the original bounty");
        assertEq(_freeSettlementUsdc(ALICE), 0, "fixture should leave no fresh retry funding");

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.closeOrderExecutionBountyUsdc = originalBountyUsdc + 100_000;
        _setRouterConfig(config);
        assertNotEq(router.closeOrderExecutionBountyUsdc(), originalBountyUsdc, "fixture should change live config");

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);

        assertEq(
            _orderRecord(retryOrderId).executionBountyUsdc,
            originalBountyUsdc,
            "retry child should reuse the immutable protection snapshot"
        );
        assertEq(
            router.lifecycleBook().pendingIntent(retryOrderId).executionBountyUsdc,
            originalBountyUsdc,
            "lifecycle intent should authenticate the original snapshot"
        );
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            originalBountyUsdc,
            "config change must not create a second reserve"
        );
        assertEq(clearinghouse.actionReserveUsdc(ALICE), actionReserveBefore, "retry should not alter reserve amount");
        assertEq(_freeSettlementUsdc(ALICE), 0, "retry should not debit unavailable free settlement");
    }

    function test_Batch_ExpiredProtectionHeadRelatchesAndLaterOrderExecutes() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint64 linkedValidUntil = router.lifecycleBook().pendingPolicy(linkedOrderId).validUntil;

        vm.warp(block.timestamp + 30);
        vm.prank(BOB);
        uint64 bobOrderId = router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_USDC, 0, false);
        CfdTypes.Order memory bobOrder = _orderRecord(bobOrderId).core;
        assertEq(router.nextExecuteId(), linkedOrderId, "protection attempt should be the global head");

        vm.warp(uint256(linkedValidUntil) + 1);
        vm.roll(block.number + 1);
        uint256 bobPublishTime = uint256(bobOrder.commitTime) + 1;
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(MARK_PRICE)), 0, int32(-8), bobPublishTime, bobPublishTime - 1
        );
        bytes[] memory executionData = new bytes[](1);
        executionData[0] = abi.encode(MARK_PRICE);

        vm.prank(EXECUTION_KEEPER);
        router.executeOrderBatch(bobOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory latched =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(latched.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "batch cleanup should relatch expired protection head"
        );
        assertEq(
            latched.executionBountyUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "batch cleanup should retain protection bounty"
        );
        OrderV2Types.CompactOutcome memory protectionOutcome = router.lifecycleBook().outcome(linkedOrderId);
        assertEq(
            uint8(protectionOutcome.bountyDisposition),
            uint8(OrderV2Types.BountyDisposition.RetainedForProtectionRetry),
            "batch head receipt should retain bounty"
        );
        assertEq(
            uint8(router.lifecycleBook().outcome(bobOrderId).status),
            uint8(OrderV2Types.LifecycleStatus.Executed),
            "later target should execute in the same batch"
        );
        assertEq(router.nextExecuteId(), 0, "batch should advance beyond both orders");
        (uint256 bobSize,,,,,,) = engine.positions(BOB);
        assertEq(bobSize, POSITION_SIZE, "later account order should reach the Engine");
    }

    function test_RepeatedProtectionAttemptExpiryRetry_ConservesSingleBounty() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 attemptOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        uint256 freeSettlementBefore = _freeSettlementUsdc(ALICE);
        uint256 actionReserveBefore = clearinghouse.actionReserveUsdc(ALICE);

        for (uint256 i; i < 2; ++i) {
            uint256 cleanerBalanceBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);
            _expireProtectionAttempt(attemptOrderId, EXECUTION_KEEPER);

            PositionProtectionTypes.PositionProtectionView memory latched =
                protectionViews.getPositionProtection(protectionId);
            assertEq(
                uint8(latched.status),
                uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
                "each expiry should return to the durable latch"
            );
            assertEq(latched.executionBountyUsdc, executionBountyUsdc, "each expiry returns the same bounty to Book");
            assertEq(
                clearinghouse.balanceUsdc(EXECUTION_KEEPER),
                cleanerBalanceBefore,
                "expiry cleaner should remain unpaid on every cycle"
            );
            assertEq(_freeSettlementUsdc(ALICE), freeSettlementBefore, "cycles must not change free settlement");
            assertEq(
                clearinghouse.actionReserveUsdc(ALICE),
                actionReserveBefore,
                "cycles must not duplicate or consume reserved settlement"
            );
            assertEq(
                router.getAccountReservations(ALICE).executionBountyUsdc,
                executionBountyUsdc,
                "exactly one execution bounty should remain reserved"
            );

            uint64 previousOrderId = attemptOrderId;
            vm.prank(CAROL);
            attemptOrderId = protectionActions.retryPositionProtectionClose(protectionId);
            assertGt(attemptOrderId, previousOrderId, "each attempt should receive a new id");
            assertEq(
                _orderRecord(attemptOrderId).executionBountyUsdc,
                executionBountyUsdc,
                "new child should own the same single bounty"
            );
            assertEq(
                protectionViews.getPositionProtection(protectionId).executionBountyUsdc,
                0,
                "Book and live child must not both own the bounty"
            );
        }
    }

    function test_RetryPositionProtectionClose_RemainsAvailableAcrossSafetyModes() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = false;
        _setRouterConfig(config);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        routerAdmin.pause();
        vm.warp(FRIDAY_FAD_START + 3 hours);

        assertFalse(router.positionProtectionCommitsEnabled(), "fixture should disable new protections");
        assertTrue(routerAdmin.paused(), "fixture should pause new risk");
        assertTrue(engine.degradedMode(), "fixture should enable degraded mode");
        assertTrue(engine.isOracleFrozen(), "fixture should enter frozen-oracle policy");

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        assertEq(router.accountHeadOrderId(ALICE), retryOrderId, "safety modes must not suppress durable retry");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "retry should restore one live close attempt"
        );

        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        uint256 executorBalanceBefore = clearinghouse.balanceUsdc(EXECUTION_KEEPER);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(MARK_PRICE)), 0, int32(-8), uint64(block.timestamp));
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(retryOrderId, _priceData(MARK_PRICE));

        OrderV2Types.CompactOutcome memory outcome = router.lifecycleBook().outcome(retryOrderId);
        assertEq(uint8(outcome.executionMode), uint8(OrderV2Types.ExecutionMode.Frozen), "frozen execution mode");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid), "frozen payout");
        assertEq(outcome.bountyRecipient, EXECUTION_KEEPER, "frozen executor should receive bounty");
        assertEq(
            clearinghouse.balanceUsdc(EXECUTION_KEEPER) - executorBalanceBefore,
            executionBountyUsdc,
            "frozen retry should pay exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "frozen success clears reserve");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "frozen success clears marker");
    }

    function test_CancelPositionProtection_RefundsExactReserveAndClearsTradeLock() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        uint256 freeBefore = _freeSettlementUsdc(ALICE);

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementUsdc(ALICE), freeBefore - _totalProtectionBountyUsdc(), "reserve after create");

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(protectionId);

        PositionProtectionTypes.PositionProtectionView memory cancelled =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(cancelled.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Cancelled),
            "cancelled lifecycle"
        );
        assertEq(cancelled.triggerBountyUsdc, 0, "cancel should clear trigger bounty ownership");
        assertEq(cancelled.executionBountyUsdc, 0, "cancel should clear execution bounty ownership");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "cancel should clear active id");
        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "cancel should refund exact reserve");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "reservation view after cancel");
    }

    function test_PostLockRisk_RejectsInitialMarginEqualityAndAcceptsOneMicroUsdcAboveBoundary() public {
        CfdTypes.RiskParams memory riskParams = _riskParams();
        RiskBoundaryFixture memory fixture = _riskBoundaryFixture(riskParams, riskParams.initMarginBps);

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc);
        _fundTrader(RISK_PLUS_ONE, fixture.plusOneOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.LONG, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaUsdc, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "exact pledge boundary");
        assertEq(clearinghouse.pnlPledgeUsdc(RISK_PLUS_ONE), fixture.requirementUsdc + 1, "one-atom pledge surplus");

        uint256 exactFreeBefore = _freeSettlementUsdc(RISK_EXACT);
        assertEq(
            exactFreeBefore,
            fixture.protectionBountiesUsdc,
            "exact account should fund both bounties from free settlement"
        );
        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementUsdc(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");
        assertEq(protectionViews.activePositionProtectionId(RISK_EXACT), 0, "risk failure must not create protection");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one micro-USDC above the inclusive initial-margin boundary should arm"
        );
    }

    function test_PostLockRisk_FreeSettlementCannotCureExactPriceRisk() public {
        CfdTypes.RiskParams memory riskParams = _riskParams();
        RiskBoundaryFixture memory fixture = _riskBoundaryFixture(riskParams, riskParams.initMarginBps);
        uint256 surplusFreeSettlementUsdc = 5000e6;

        _fundTrader(
            RISK_EXACT, fixture.exactOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc + surplusFreeSettlementUsdc
        );
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "price pledge at equality");
        assertEq(
            _freeSettlementUsdc(RISK_EXACT),
            fixture.protectionBountiesUsdc + surplusFreeSettlementUsdc,
            "fixture must have abundant generic free settlement"
        );

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            _freeSettlementUsdc(RISK_EXACT),
            fixture.protectionBountiesUsdc + surplusFreeSettlementUsdc,
            "failed protection must roll back the temporary bounty lock"
        );
        assertEq(protectionViews.activePositionProtectionId(RISK_EXACT), 0, "free cash must not create price backing");
    }

    function test_PostLockRisk_SameAccountClaimProvidesOneAtomOfExactPriceCollateral() public {
        CfdTypes.RiskParams memory riskParams = _riskParams();
        RiskBoundaryFixture memory fixture = _riskBoundaryFixture(riskParams, riskParams.initMarginBps);

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "pledge starts at equality");

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        _seedAuthenticatedTraderClaim(RISK_EXACT, 1);
        vm.prank(RISK_EXACT);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(engine.traderClaimBalanceUsdc(RISK_EXACT), 1, "fixture must add one same-account claim atom");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one claim atom above equality should arm"
        );
    }

    function test_PostLockRisk_UsesStricterFadBoundary() public {
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);

        RiskBoundaryFixture memory fixture = _riskBoundaryFixture(riskParams, riskParams.fadMarginBps);
        assertGt(
            fixture.requirementUsdc,
            ((POSITION_SIZE * MARK_PRICE) / 1e20) * riskParams.initMarginBps / 10_000,
            "fixture requires FAD to be stricter than initial"
        );

        vm.warp(FRIDAY_FAD_START - 2);
        router.updateMarkPrice(_mockPythUpdateData(MARK_PRICE));
        assertFalse(engine.isFadWindow(), "positions should open immediately before the FAD boundary");

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc);
        _fundTrader(RISK_PLUS_ONE, fixture.plusOneOpeningMarginDeltaUsdc + fixture.protectionBountiesUsdc);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.LONG, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaUsdc, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "exact FAD pledge boundary");
        assertEq(clearinghouse.pnlPledgeUsdc(RISK_PLUS_ONE), fixture.requirementUsdc + 1, "one-atom FAD pledge surplus");

        vm.warp(FRIDAY_FAD_START);
        router.updateMarkPrice(_mockPythUpdateData(MARK_PRICE));
        assertTrue(engine.isFadWindow(), "post-lock risk should use the stricter FAD requirement");

        uint256 exactFreeBefore = _freeSettlementUsdc(RISK_EXACT);
        assertGe(exactFreeBefore, fixture.protectionBountiesUsdc, "exact-boundary account can fund the bounty itself");
        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementUsdc(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one micro-USDC above the inclusive risk boundary should arm"
        );
    }

    function test_PostLockRisk_RejectsUnderfundedNegativeVpiReserveIndependently() public {
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.vpiFactor = 0.05e18;
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);

        uint256 size = 100_000e18;
        uint256 depth = pool.totalAssets();
        _open(ALICE, CfdTypes.Side.SHORT, size, 5000e6, MARK_PRICE, depth);
        _open(BOB, CfdTypes.Side.LONG, size, 5000e6, MARK_PRICE, depth);
        (,,,,,, int256 vpiAccrued) = engine.positions(BOB);
        assertLt(vpiAccrued, 0, "rebate-side fixture must have negative lifetime VPI");

        uint256 reserveTargetUsdc = uint256(-(vpiAccrued + 1)) + 1;
        assertEq(clearinghouse.vpiRebateReserveUsdc(BOB), reserveTargetUsdc, "reserve starts exactly funded");
        vm.prank(address(engine));
        clearinghouse.releaseVpiRebateReserve(BOB, 1);

        uint256 freeBefore = _freeSettlementUsdc(BOB);
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            clearinghouse.vpiRebateReserveUsdc(BOB), reserveTargetUsdc - 1, "failed action must not repair VPI backing"
        );
        assertEq(_freeSettlementUsdc(BOB), freeBefore, "failed action must roll back its bounty lock");
        assertEq(protectionViews.activePositionProtectionId(BOB), 0, "VPI delinquency must fail closed");
    }

    function test_PostLockRisk_RejectsCarryLeftUncoveredByLockCheckpoint() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        _withdrawAllFreeSettlement(ALICE);

        stdstore.target(address(router)).sig("closeOrderExecutionBountyUsdc()").checked_write(uint256(0));
        stdstore.target(address(router)).sig("positionProtectionTriggerBountyUsdc()").checked_write(uint256(0));

        vm.warp(block.timestamp + 365 days);
        _refreshMark(MARK_PRICE);
        assertGt(_expectedIndexedCarryUsdc(ALICE), 0, "fixture must accrue carry with no eligible free settlement");

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            engine.unsettledCarryUsdc(ALICE),
            0,
            "risk failure must roll back the lock-time carry checkpoint with the rest of the action"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "uncovered carry must fail closed");
    }

    function test_Pause_BlocksNewAndReplacementButAllowsCancelAndTrigger() public {
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, LONG_TAKE_PROFIT, LONG_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, LONG_TAKE_PROFIT, 0);

        routerAdmin.pause();

        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(LONG_TAKE_PROFIT - 1, 0));

        OrderV2Types.OrderRequest memory pausedRequest =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        vm.prank(CAROL);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.commitOpenOrderWithProtection(pausedRequest, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(cancelledProtectionId);
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "pause must not block cancellation");

        uint64 linkedOrderId = _triggerAt(triggeredProtectionId, LONG_TAKE_PROFIT);
        assertEq(
            uint8(protectionViews.getPositionProtection(triggeredProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "pause must not block a safety trigger"
        );
        assertEq(router.accountHeadOrderId(BOB), linkedOrderId, "paused trigger should append the close normally");
    }

    function test_FeatureOff_BlocksNewAndReplacementButAllowsCancelAndTrigger() public {
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, LONG_TAKE_PROFIT, LONG_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, LONG_TAKE_PROFIT, 0);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = false;
        _setRouterConfig(config);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionDisabled.selector);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(LONG_TAKE_PROFIT - 1, 0));

        OrderV2Types.OrderRequest memory disabledRequest =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        vm.prank(CAROL);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionDisabled.selector);
        protectionActions.commitOpenOrderWithProtection(disabledRequest, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(cancelledProtectionId);
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "feature-off must not block cancellation");

        uint64 linkedOrderId = _triggerAt(triggeredProtectionId, LONG_TAKE_PROFIT);
        assertEq(
            uint8(protectionViews.getPositionProtection(triggeredProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "feature-off must not disable existing safety instructions"
        );
        assertEq(router.accountHeadOrderId(BOB), linkedOrderId, "feature-off trigger should append the close normally");
    }

    function test_ReplacePositionProtection_RemainsAvailableInDegradedMode() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertTrue(engine.degradedMode(), "setup should enter degraded mode");

        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, _params(LONG_TAKE_PROFIT - 1, 0));

        PositionProtectionTypes.PositionProtectionView memory replaced =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(replaced.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "geometry-only replacement should remain available in degraded mode"
        );
        assertEq(replaced.takeProfitTriggerPrice, LONG_TAKE_PROFIT - 1, "replacement threshold");
        assertEq(replaced.armedAt, block.timestamp, "replacement should restart time separation");
        assertEq(replaced.armedBlock, block.number, "replacement should restart block separation");
        assertEq(
            replaced.triggerBountyUsdc + replaced.executionBountyUsdc,
            _totalProtectionBountyUsdc(),
            "replacement should retain the snapshotted reserve"
        );
    }

    function test_ProtectionBook_NonTriggerActionsRejectEthAndNeverCustodyIt() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IPositionProtectionActions.createPositionProtection, (params));
        calls[1] = abi.encodeCall(IPositionProtectionActions.replacePositionProtection, (uint64(1), params));
        calls[2] = abi.encodeCall(IPositionProtectionActions.cancelPositionProtection, (uint64(1)));
        calls[3] = abi.encodeCall(IPositionProtectionActions.commitOpenOrderWithProtection, (request, params));

        vm.deal(ALICE, calls.length);
        for (uint256 i; i < calls.length; ++i) {
            uint256 callerEthBefore = ALICE.balance;
            vm.prank(ALICE);
            (bool success,) = address(protectionBook).call{value: 1}(calls[i]);
            assertFalse(success, "every non-trigger action must remain nonpayable");
            assertEq(ALICE.balance, callerEthBefore, "reverted ETH must remain with the caller");
            assertEq(address(protectionBook).balance, 0, "the Book must never retain native value");
        }
    }

    function test_ProtectionBook_LifecycleHooksRejectNonRouterCallers() public {
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.activate(1, MARK_PRICE, uint64(block.timestamp), 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.afterOrderTerminal(1, ALICE, IOrderRouterAccounting.OrderStatus.Failed);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.handleFailedProtectionAttempt(1, ALICE, OrderV2Types.TerminalReason.Expired, executionBountyUsdc);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.failPendingOpenForRiskOff(1, ALICE);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.forfeitOnLiquidation(ALICE);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.commitProtectionCloseAttempt(1, ALICE, CfdTypes.Side.LONG, POSITION_SIZE, executionBountyUsdc);
    }

    function test_ProtectionBook_FailedAttemptHookValidatesAttemptAccountReasonAndBounty() public {
        uint256 executionBountyUsdc = router.closeOrderExecutionBountyUsdc();

        vm.prank(address(router));
        assertFalse(
            protectionBook.handleFailedProtectionAttempt(
                404, ALICE, OrderV2Types.TerminalReason.Expired, executionBountyUsdc
            ),
            "unknown attempts should be ignored"
        );

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        vm.prank(address(router));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__PositionChanged.selector);
        protectionBook.handleFailedProtectionAttempt(
            linkedOrderId, BOB, OrderV2Types.TerminalReason.Expired, executionBountyUsdc
        );

        vm.prank(address(router));
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__InvalidTerminalReason.selector);
        protectionBook.handleFailedProtectionAttempt(
            linkedOrderId, ALICE, OrderV2Types.TerminalReason.Executed, executionBountyUsdc
        );

        vm.prank(address(router));
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__BountyMismatch.selector);
        protectionBook.handleFailedProtectionAttempt(
            linkedOrderId, ALICE, OrderV2Types.TerminalReason.Expired, executionBountyUsdc + 1
        );

        assertTrue(
            router.lifecycleBook().isProtectionAttempt(linkedOrderId), "rejected callbacks keep live attempt state"
        );
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "rejected callbacks must not alter the durable protection"
        );
    }

    function test_Router_RejectsUntrustedProtectionHostMetadata() public {
        OrderV2Types.OrderRequest memory protectedOpenRequest;
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.commitProtectedOpen(ALICE, protectedOpenRequest);

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        bytes memory refreshCall =
            abi.encodeWithSelector(router.updateMarkPrice.selector, _mockPythUpdateData(LONG_TAKE_PROFIT));
        vm.prank(CAROL);
        (bool refreshSuccess,) =
            address(router).call(abi.encodePacked(refreshCall, abi.encode(CAROL, uint256(protectionId))));
        assertTrue(refreshSuccess, "ordinary mark refresh should accept harmless trailing bytes");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "only the Book may use trailing trigger metadata"
        );
        assertEq(router.pendingOrderCounts(ALICE), 0, "spoofed metadata must not append a protection close");
    }

    function test_TriggerPositionProtection_RefundsUnusedEthAndLeavesBookBalanceZero() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        bytes[] memory updateData = _mockPythUpdateData(LONG_TAKE_PROFIT);
        vm.deal(TRIGGER_KEEPER, 1 ether);
        uint256 keeperEthBefore = TRIGGER_KEEPER.balance;

        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection{value: 1 ether}(protectionId, updateData);

        assertEq(TRIGGER_KEEPER.balance, keeperEthBefore, "unused oracle ETH should return to the original keeper");
        assertEq(address(protectionBook).balance, 0, "the Book must only forward native value transiently");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "ETH forwarding should preserve trigger lifecycle"
        );
        assertEq(router.accountHeadOrderId(ALICE), linkedOrderId, "trigger should still append the linked close");
    }

    function test_ActiveProtection_BlocksDiscretionaryOrdersButAllowsAddMargin() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        router.commitOrder(CfdTypes.Side.LONG, POSITION_SIZE, 0, 0, true);

        (, uint256 marginBefore,,,,,) = engine.positions(ALICE);
        vm.prank(ALICE);
        engine.addMargin(ALICE, 100e6);
        (, uint256 marginAfter,,,,,) = engine.positions(ALICE);
        assertEq(marginAfter, marginBefore + 100e6, "protection should not block add-margin safety action");

        _triggerAt(protectionId, LONG_TAKE_PROFIT);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        router.commitOrder(CfdTypes.Side.LONG, POSITION_SIZE, 0, 0, true);
    }

    function test_ActiveProtection_BlocksAttachedOpenWithCanonicalSelector() public {
        _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
    }

    function test_Liquidation_ArmedProtectionForfeitsBothBountiesAndTerminalizes() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.prank(EXECUTION_KEEPER);
        router.executeLiquidation(ALICE, _mockPythUpdateData(150_000_000));

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "armed protection should terminalize as liquidated"
        );
        assertEq(liquidated.triggerBountyUsdc, 0, "liquidation should consume the unpaid trigger bounty");
        assertEq(liquidated.executionBountyUsdc, 0, "liquidation should consume the dormant close bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear active protection");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "no bounty reservation should remain");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            _totalProtectionBountyUsdc(),
            "both unpaid bounties should be forfeited exactly once"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_TriggeredProtectionForfeitsLinkedCloseBountyExactlyOnce() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.prank(EXECUTION_KEEPER);
        router.executeLiquidation(ALICE, _mockPythUpdateData(150_000_000));

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "triggered protection should remain liquidated after linked-order cleanup"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear active protection");
        assertEq(
            uint8(_orderRecord(linkedOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "liquidation should terminally fail the queued linked close"
        );
        assertEq(_orderRecord(linkedOrderId).executionBountyUsdc, 0, "linked order bounty should be consumed");
        assertEq(router.pendingOrderCounts(ALICE), 0, "liquidation should unlink the generated close");
        assertEq(router.pendingCloseSize(ALICE), 0, "liquidation should clear generated close size");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "no bounty reservation should remain");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            router.closeOrderExecutionBountyUsdc(),
            "only the unpaid linked-close bounty should be forfeited at liquidation"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_LatchedProtectionForfeitsRetainedBountyExactlyOnce() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);
        _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);

        PositionProtectionTypes.PositionProtectionView memory latched =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(latched.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "fixture should hold a durable latched protection"
        );
        assertEq(
            latched.executionBountyUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "latched Book should hold exactly one close bounty"
        );
        assertEq(router.pendingOrderCounts(ALICE), 0, "latched protection should have no live child");

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.prank(EXECUTION_KEEPER);
        router.executeLiquidation(ALICE, _mockPythUpdateData(150_000_000));

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "liquidation should terminalize the latch"
        );
        assertEq(liquidated.executionBountyUsdc, 0, "liquidation should consume the Book-held bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear the trade lock");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "no bounty reserve should remain");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            router.closeOrderExecutionBountyUsdc(),
            "retained bounty should be forfeited exactly once"
        );
        OrderV2Types.CompactOutcome memory expiredOutcome = router.lifecycleBook().outcome(linkedOrderId);
        assertEq(
            uint8(expiredOutcome.bountyDisposition),
            uint8(OrderV2Types.BountyDisposition.RetainedForProtectionRetry),
            "liquidation must not rewrite the prior attempt receipt"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_LiveRetriedChildCleansLatestLinkageAndBountyExactlyOnce() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        assertEq(
            protectionViews.getPositionProtection(protectionId).linkedOrderId,
            retryOrderId,
            "retry should be the latest live linkage"
        );
        assertEq(
            _orderRecord(retryOrderId).executionBountyUsdc,
            router.closeOrderExecutionBountyUsdc(),
            "retry child should own the single retained bounty"
        );

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        vm.prank(EXECUTION_KEEPER);
        router.executeLiquidation(ALICE, _mockPythUpdateData(150_000_000));

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "liquidation should terminalize retried protection"
        );
        assertEq(liquidated.linkedOrderId, retryOrderId, "terminal history should retain the latest retry id");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear active linkage");
        assertEq(uint8(_orderRecord(retryOrderId).status), uint8(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(_orderRecord(retryOrderId).executionBountyUsdc, 0, "latest child bounty should be consumed");
        assertEq(router.pendingOrderCounts(ALICE), 0, "latest child should be removed from account queue");
        assertEq(router.pendingCloseSize(ALICE), 0, "latest child should be removed from close aggregate");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "all bounty reserve should clear");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            router.closeOrderExecutionBountyUsdc(),
            "live retry bounty should be forfeited exactly once"
        );

        OrderV2Types.CompactOutcome memory retryOutcome = router.lifecycleBook().outcome(retryOrderId);
        assertEq(
            uint8(retryOutcome.reason),
            uint8(OrderV2Types.TerminalReason.AccountLiquidated),
            "latest child should receive liquidation terminal evidence"
        );
        assertEq(
            uint8(retryOutcome.bountyDisposition),
            uint8(OrderV2Types.BountyDisposition.Forfeited),
            "latest child receipt should authenticate forfeiture"
        );
        assertEq(retryOutcome.bountyRecipient, engine.protocolTreasury(), "forfeiture recipient");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "liquidation should clear attempt marker");
    }

    function test_AttachedOpen_InheritsSettlementBufferAdmissionAtCommit() public {
        uint256 size = 100_000e18;
        uint256 marginUsdc = 5000e6;
        _open(BOB, CfdTypes.Side.SHORT, size, marginUsdc, MARK_PRICE);

        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 settlementBufferUsdc = _settlementBufferTargetUsdc(maxLiabilityUsdc);
        uint256 underBufferedAssetsUsdc = maxLiabilityUsdc + settlementBufferUsdc - 1;
        _drainPoolTo(underBufferedAssetsUsdc);

        assertGe(pool.totalAssets(), maxLiabilityUsdc, "setup must remain raw solvent");
        assertLt(
            pool.totalAssets(),
            maxLiabilityUsdc + settlementBufferUsdc,
            "setup must miss only the settlement-buffer admission target"
        );
        assertEq(
            engineLens.previewOpenRevertCode(
                ALICE, CfdTypes.Side.LONG, size, marginUsdc, MARK_PRICE, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "the attached parent must inherit the ordinary open buffer gate"
        );

        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        OrderV2Types.OrderRequest memory request = _boundedOpenRequest(CfdTypes.Side.LONG, size, marginUsdc, 0);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)
            )
        );
        protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "commit rejection must roll back every tentative lock");
        assertEq(
            PositionProtectionBook(address(protectionBook)).nextPositionProtectionId(),
            1,
            "commit rejection must not allocate a protection id"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "commit rejection must not create a trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "commit rejection must not enqueue a parent order");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "commit rejection must reserve no bounty");
    }

    function test_AttachedOpen_PostCommitBufferInvalidationRefundsAndUnlocksProtection() public {
        uint256 size = 100_000e18;
        uint256 marginUsdc = 5000e6;
        _open(BOB, CfdTypes.Side.SHORT, size, marginUsdc, MARK_PRICE);

        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, size, marginUsdc, 0), _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)
        );
        vm.stopPrank();
        uint256 parentBountyUsdc = _executionBountyReserve(parentOrderId);

        uint256 maxLiabilityUsdc = _maxLiability();
        uint256 settlementBufferUsdc = _settlementBufferTargetUsdc(maxLiabilityUsdc);
        _drainPoolTo(maxLiabilityUsdc + settlementBufferUsdc - 1);
        assertGe(pool.totalAssets(), maxLiabilityUsdc, "post-commit drift must remain raw solvent");
        assertLt(
            pool.totalAssets(),
            maxLiabilityUsdc + settlementBufferUsdc,
            "post-commit drift must leave the parent one atom below its buffer target"
        );

        uint256 branch = vm.snapshotState();
        vm.prank(address(router));
        clearinghouse.releaseOrderReservationIfActive(parentOrderId);
        assertEq(
            engineLens.previewOpenRevertCode(
                ALICE, CfdTypes.Side.LONG, size, marginUsdc, MARK_PRICE, uint64(block.timestamp)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "execution-time revalidation must classify the headroom loss as solvency exceeded"
        );
        vm.revertToState(branch);

        uint256 keeperBefore = _settlementBalance(EXECUTION_KEEPER);
        bytes[] memory executionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(parentOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(_orderRecord(parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "under-buffer parent must terminally fail"
        );
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "terminal parent invalidation must fail its attached protection"
        );
        assertEq(failed.triggerBountyUsdc, 0, "invalidation must refund the trigger bounty");
        assertEq(failed.executionBountyUsdc, 0, "invalidation must refund the staged close bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "invalidation must release the trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "invalidation must remove the parent from the queue");
        assertEq(router.getAccountReservations(ALICE).committedMarginUsdc, 0, "parent margin must be unlocked");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "all bounty reservations must clear");
        assertEq(
            _freeSettlementUsdc(ALICE),
            freeBefore - parentBountyUsdc,
            "margin and protection bounties must return while the existing parent-bounty policy pays the keeper"
        );
        assertEq(
            _settlementBalance(EXECUTION_KEEPER) - keeperBefore,
            parentBountyUsdc,
            "the ordinary parent execution bounty must follow the existing terminal-failure policy"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "invalidated attached open must create no position");
    }

    function test_AttachedOpen_SuccessArmsProtectionAtomically() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0), params
        );
        vm.stopPrank();

        PositionProtectionTypes.PositionProtectionView memory staged =
            protectionViews.getPositionProtection(protectionId);
        assertEq(staged.parentOrderId, parentOrderId, "parent link");
        assertEq(
            uint8(staged.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "protection should stage before parent execution"
        );
        assertEq(router.pendingOrderCounts(ALICE), 1, "only parent should count as pending");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            _totalProtectionBountyUsdc() + _executionBountyReserve(parentOrderId),
            "view should include parent and staged-protection bounties"
        );

        PositionProtectionTypes.PositionProtectionParams memory replacement = _params(85_000_000, 115_000_000);
        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, replacement);
        PositionProtectionTypes.PositionProtectionView memory replacedPending =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(replacedPending.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "staged replacement should remain dormant until parent execution"
        );
        assertEq(replacedPending.takeProfitTriggerPrice, replacement.takeProfitTriggerPrice, "staged replacement TP");
        assertEq(replacedPending.stopLossTriggerPrice, replacement.stopLossTriggerPrice, "staged replacement SL");
        assertEq(replacedPending.armedAt, 0, "staged replacement must not start trigger timing");
        assertEq(replacedPending.armedBlock, 0, "staged replacement must not start block separation");

        bytes[] memory executionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(parentOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(armed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "successful parent should atomically arm protection"
        );
        assertEq(armed.size, POSITION_SIZE, "armed size should match actual position");
        assertEq(uint8(armed.side), uint8(CfdTypes.Side.LONG), "armed side should match actual position");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "active id after parent success");
        assertEq(router.pendingOrderCounts(ALICE), 0, "parent should be terminal");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            _totalProtectionBountyUsdc(),
            "only protection bounties should remain after opening bounty payment"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, POSITION_SIZE, "parent should open the position");
    }

    function test_AttachedOpen_RetainsCallerBoundedRequestAndPublicIdentity() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        request.clientOrderId = keccak256("bounded-protected-parent");
        request.bounds.validUntil = uint64(block.timestamp + 1);
        request.bounds.allowedExecutionModes = 1;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        OrderV2Types.ClientIntent memory intent = router.lifecycleBook().clientIntent(ALICE, request.clientOrderId);
        OrderV2Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(parentOrderId);
        (IOrderRouterAccounting.PendingOrderView memory parent,) = router.getPendingOrderView(parentOrderId);
        assertFalse(OrderV2Types.isProtocolClientOrderId(request.clientOrderId), "parent must use public id namespace");
        assertEq(intent.orderId, parentOrderId, "client id must resolve to parent");
        assertEq(intent.intentHash, router.lifecycleBook().hashOrderRequest(ALICE, request), "caller request hash");
        assertEq(pending.account, ALICE, "pending account");
        assertEq(pending.clientOrderId, request.clientOrderId, "pending client id");
        assertEq(pending.intentHash, intent.intentHash, "pending intent hash");
        assertEq(keccak256(abi.encode(pending.bounds)), keccak256(abi.encode(request.bounds)), "exact bounds");
        assertEq(uint8(parent.side), uint8(request.side), "parent side");
        assertEq(parent.sizeDelta, request.sizeDelta, "parent size");
        assertEq(parent.marginDelta, request.marginDelta, "parent margin");
        assertEq(parent.targetPrice, request.targetPrice, "parent target");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "bounded parent must stage protection"
        );
    }

    function test_AttachedOpen_RejectsMalformedOrUnboundedParentAndRollsBack() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        bytes32 currentConfigHash = request.bounds.expectedConfigHash;

        request.bounds.expectedConfigHash = bytes32(0);
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__ExecutionConfigMismatch.selector, bytes32(0), currentConfigHash
            )
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        request.targetPrice = 0;
        _expectAttachedOpenCommitRevert(
            request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroTargetPrice.selector)
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        request.isClose = true;
        _expectAttachedOpenCommitRevert(
            request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__Unauthorized.selector)
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        request.clientOrderId = OrderV2Types.protocolClientOrderId(keccak256("protected-parent"));
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdDomainMismatch.selector, request.clientOrderId, false
            )
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        uint256 executionBountyUsdc = _quoteOpenOrderExecutionBountyUsdc(POSITION_SIZE);
        request.bounds.maxExecutionBountyUsdc = executionBountyUsdc - 1;
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound.selector,
                executionBountyUsdc,
                executionBountyUsdc - 1
            )
        );
    }

    function test_AttachedOpen_RejectsStaleConfigAtCommitAndRollsBack() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        bytes32 staleConfigHash = request.bounds.expectedConfigHash;
        _setRouterConfig(_routerConfig());
        _refreshMark(MARK_PRICE);
        request.bounds.validUntil = uint64(block.timestamp + router.maxOrderAge());
        bytes32 currentConfigHash = router.lifecycleBook().currentExecutionConfigHash();
        assertTrue(staleConfigHash != currentConfigHash, "finalized config must change the digest");

        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__ExecutionConfigMismatch.selector, staleConfigHash, currentConfigHash
            )
        );
    }

    function test_AttachedOpen_ConfigDriftTerminallyFailsParentAndProtection() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        routerAdmin.proposeRouterConfig(config);
        uint256 activationTime = routerAdmin.routerConfigActivationTime();
        vm.warp(activationTime - 1);
        _refreshMark(MARK_PRICE);

        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.warp(activationTime);
        routerAdmin.finalizeRouterConfig();
        assertTrue(
            request.bounds.expectedConfigHash != router.lifecycleBook().currentExecutionConfigHash(),
            "finalized config must invalidate the parent"
        );

        vm.prank(EXECUTION_KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(parentOrderId, new bytes[](0));

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.ConfigMismatch), "parent failure reason"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_DisallowedExecutionModeFailsParentAndProtection() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        request.bounds.allowedExecutionModes = 2;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertFalse(engine.isFadWindow(), "execution must occur in live mode");
        vm.prank(EXECUTION_KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(parentOrderId, _mockPythUpdateData(MARK_PRICE));

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV2Types.TerminalReason.ExecutionModeDisallowed),
            "parent failure reason"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_FinancialBoundFailureFailsParentAndProtection() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        uint256 executionNotionalUsdc = (POSITION_SIZE * MARK_PRICE) / 1e20;
        request.bounds.maxExecutionNotionalUsdc = executionNotionalUsdc - 1;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.prank(EXECUTION_KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(parentOrderId, _mockPythUpdateData(MARK_PRICE));

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV2Types.TerminalReason.ConstraintViolation),
            "parent failure reason"
        );
        assertEq(
            uint8(router.lifecycleBook().outcome(parentOrderId).failedConstraint),
            uint8(OrderV2Types.ConstraintKind.ExecutionNotional),
            "failed bound"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_ExactReplayAndClientIdConflictAreRejectedWithoutMutation() public {
        OrderV2Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(request, params);

        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        uint64 nextParentBefore = router.nextCommitId();
        uint64 nextProtectionBefore = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();
        bytes32 protectionHash = keccak256(abi.encode(protectionViews.getPositionProtection(protectionId)));

        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__InvalidHostResponse.selector);
        vm.prank(ALICE);
        protectionActions.commitOpenOrderWithProtection(request, params);

        OrderV2Types.OrderRequest memory conflict =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0);
        conflict.clientOrderId = request.clientOrderId;
        conflict.bounds.maxExplicitFeesUsdc -= 1;
        bytes32 existingIntentHash = router.lifecycleBook().hashOrderRequest(ALICE, request);
        bytes32 suppliedIntentHash = router.lifecycleBook().hashOrderRequest(ALICE, conflict);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
                ALICE,
                request.clientOrderId,
                existingIntentHash,
                suppliedIntentHash
            )
        );
        vm.prank(ALICE);
        protectionActions.commitOpenOrderWithProtection(conflict, params);

        assertEq(router.nextCommitId(), nextParentBefore, "retry must not allocate parent");
        assertEq(
            PositionProtectionBook(address(protectionBook)).nextPositionProtectionId(),
            nextProtectionBefore,
            "retry must not allocate protection"
        );
        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "retry must roll back tentative bounty locks");
        assertEq(
            keccak256(abi.encode(protectionViews.getPositionProtection(protectionId))),
            protectionHash,
            "retry must not mutate protection"
        );
        assertEq(router.lifecycleBook().clientIntent(ALICE, request.clientOrderId).orderId, parentOrderId);
    }

    function test_AttachedOpen_LegacyScalarSelectorIsUnavailable() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        bytes4 legacySelector =
            bytes4(keccak256("commitOpenOrderWithProtection(uint8,uint256,uint256,uint256,(uint256,uint256))"));
        assertTrue(legacySelector != IPositionProtectionActions.commitOpenOrderWithProtection.selector);

        vm.prank(ALICE);
        (bool success,) = address(protectionBook)
            .call(
                abi.encodeWithSelector(
                    legacySelector, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, uint256(0), params
                )
            );

        assertFalse(success, "legacy scalar selector must be unavailable");
        assertEq(router.pendingOrderCounts(ALICE), 0, "legacy call must not commit an order");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "legacy call must not create protection");
    }

    function test_Trigger_PublicRawIdPreclaimCannotPoisonProtocolClose() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        uint64 protectionId = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();
        uint64 poisonOrderId = router.nextCommitId();
        uint64 predictedLinkedOrderId = poisonOrderId + 1;
        bytes32 rawTriggerDigest = keccak256(
            abi.encode(
                "PLETHER_POSITION_PROTECTION_TRIGGER_V2",
                block.chainid,
                address(router),
                ALICE,
                protectionId,
                predictedLinkedOrderId
            )
        );
        bytes32 protocolClientOrderId = OrderV2Types.protocolClientOrderId(rawTriggerDigest);

        OrderV2Types.OrderRequest memory poisonRequest = _publicBoundedRequest(rawTriggerDigest, true);
        poisonRequest.bounds.validUntil = uint64(block.timestamp + 1);
        vm.prank(ALICE);
        assertEq(router.commitOrder(poisonRequest), poisonOrderId, "public preclaim order id");

        vm.warp(uint256(poisonRequest.bounds.validUntil) + 1);
        vm.prank(EXECUTION_KEEPER);
        OrderV2Types.ExecutionResult memory poisonResult = router.executeOrder(poisonOrderId, new bytes[](0));
        assertEq(uint8(poisonResult.terminalReason), uint8(OrderV2Types.TerminalReason.Expired));
        _refreshMark(MARK_PRICE);

        vm.prank(ALICE);
        assertEq(
            protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)),
            protectionId,
            "fixture protection id"
        );
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        assertEq(linkedOrderId, predictedLinkedOrderId, "fixture must target the formerly colliding close");
        assertTrue(OrderV2Types.isProtocolClientOrderId(protocolClientOrderId));
        assertEq(router.lifecycleBook().clientIntent(ALICE, rawTriggerDigest).orderId, poisonOrderId);
        assertEq(router.lifecycleBook().clientIntent(ALICE, protocolClientOrderId).orderId, linkedOrderId);
        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            LONG_TAKE_PROFIT
        );
    }

    function test_AttachedOpen_ThresholdCrossedBeforeFillArmsThenTriggersOnLaterTick() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, 0);

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0), params
        );
        vm.stopPrank();

        uint256 crossedTakeProfit = LONG_TAKE_PROFIT - 2;
        bytes[] memory executionData = _mockPythUpdateData(crossedTakeProfit);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(parentOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(armed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "a crossed staged threshold must not leave the filled position naked"
        );
        assertEq(armed.size, POSITION_SIZE, "activation should bind the actual full position");

        uint64 linkedOrderId = _triggerAt(protectionId, crossedTakeProfit);
        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            crossedTakeProfit
        );
    }

    function test_AttachedOpen_SlippageFailureRefundsProtectionBounties() public {
        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, LONG_STOP_LOSS), params
        );
        vm.stopPrank();
        uint256 parentBountyUsdc = _executionBountyReserve(parentOrderId);

        bytes[] memory executionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(parentOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "terminal parent failure should fail attached protection"
        );
        assertEq(failed.triggerBountyUsdc, 0, "failed attached protection should release trigger bounty");
        assertEq(failed.executionBountyUsdc, 0, "failed attached protection should release close bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "failure should clear active protection");
        assertEq(router.pendingOrderCounts(ALICE), 0, "failed parent should leave no order");
        assertEq(router.getAccountReservations(ALICE).executionBountyUsdc, 0, "failure should clear all reserves");
        assertEq(
            _freeSettlementUsdc(ALICE),
            freeBefore - parentBountyUsdc,
            "only the ordinary parent clearer bounty should remain spent"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "slippage-failed parent must not create a position");
    }

    function test_AttachedOpen_RiskOffRefundFailsProtectionAndReleasesAllReservesExactlyOnce() public {
        RiskOffRefundFixture memory fixture;
        fixture.freeBefore = _freeSettlementUsdc(ALICE);
        fixture.settlementBefore = _settlementBalance(ALICE);
        fixture.cleanerSettlementBefore = _settlementBalance(CAROL);

        vm.startPrank(ALICE);
        (fixture.parentOrderId, fixture.protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0),
            _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)
        );
        vm.stopPrank();

        fixture.parentMarginUsdc = _remainingCommittedMargin(fixture.parentOrderId);
        fixture.parentBountyUsdc = _executionBountyReserve(fixture.parentOrderId);
        fixture.protectionBountiesUsdc = _totalProtectionBountyUsdc();

        {
            uint256 totalReservedUsdc =
                fixture.parentMarginUsdc + fixture.parentBountyUsdc + fixture.protectionBountiesUsdc;
            IOrderRouterAccounting.AccountReservationView memory stagedReservations =
                router.getAccountReservations(ALICE);

            assertEq(
                fixture.freeBefore - _freeSettlementUsdc(ALICE),
                totalReservedUsdc,
                "setup must lock every reserve exactly"
            );
            assertEq(_settlementBalance(ALICE), fixture.settlementBefore, "reservation must not debit gross settlement");
            assertEq(stagedReservations.committedMarginUsdc, fixture.parentMarginUsdc, "parent margin reserve");
            assertEq(
                stagedReservations.executionBountyUsdc,
                fixture.parentBountyUsdc + fixture.protectionBountiesUsdc,
                "parent and protection bounty reserves"
            );
            assertEq(stagedReservations.pendingOrderCount, 1, "only the parent open should be queued");
        }
        assertEq(
            uint8(protectionViews.getPositionProtection(fixture.protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "protection must be pending on its parent"
        );

        routerAdmin.pause();
        assertTrue(routerAdmin.paused(), "risk-off must pause new risk");
        assertEq(routerAdmin.riskOffOrderCutoff(), fixture.parentOrderId, "cutoff must include the attached parent");

        vm.mockCallRevert(
            address(engine),
            abi.encodeCall(ICfdEngineCore.realizeCarryBeforeMarginChange, (ALICE)),
            bytes("risk-off must not checkpoint carry")
        );
        vm.recordLogs();
        vm.prank(CAROL);
        router.clearRiskOffOrder(fixture.parentOrderId);
        {
            Vm.Log[] memory riskOffLogs = vm.getRecordedLogs();
            vm.clearMockedCalls();
            _assertSingleRiskOffRefund(
                riskOffLogs, ALICE, fixture.parentMarginUsdc, fixture.parentBountyUsdc + fixture.protectionBountiesUsdc
            );
        }

        assertEq(
            uint8(_orderRecord(fixture.parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "risk-off parent must fail"
        );
        assertEq(_orderRecord(fixture.parentOrderId).executionBountyUsdc, 0, "parent must retain no unpaid bounty");
        assertFalse(_orderRecord(fixture.parentOrderId).inAccountQueue, "parent must leave the account queue");
        assertFalse(_orderRecord(fixture.parentOrderId).inMarginQueue, "parent must leave the margin queue");
        assertEq(_orderRecord(fixture.parentOrderId).nextGlobalOrderId, 0, "parent global next link");
        assertEq(_orderRecord(fixture.parentOrderId).prevGlobalOrderId, 0, "parent global previous link");
        assertEq(_orderRecord(fixture.parentOrderId).nextAccountOrderId, 0, "parent account next link");
        assertEq(_orderRecord(fixture.parentOrderId).prevAccountOrderId, 0, "parent account previous link");
        assertEq(_orderRecord(fixture.parentOrderId).nextMarginOrderId, 0, "parent margin next link");
        assertEq(_orderRecord(fixture.parentOrderId).prevMarginOrderId, 0, "parent margin previous link");
        assertEq(router.nextExecuteId(), 0, "global queue must be empty");
        assertEq(router.globalTailOrderId(), 0, "global tail must be empty");
        assertEq(router.accountHeadOrderId(ALICE), 0, "account queue must be empty");
        assertEq(router.marginHeadOrderId(ALICE), 0, "margin queue head must be empty");
        assertEq(router.marginTailOrderId(ALICE), 0, "margin queue tail must be empty");
        assertEq(router.pendingOrderCounts(ALICE), 0, "parent must no longer count as pending");

        {
            PositionProtectionTypes.PositionProtectionView memory failed =
                protectionViews.getPositionProtection(fixture.protectionId);
            assertEq(
                uint8(failed.status),
                uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
                "risk-off parent must fail its staged protection"
            );
            assertEq(failed.parentOrderId, fixture.parentOrderId, "terminal protection should retain its parent id");
            assertEq(failed.linkedOrderId, 0, "failed staged protection must never create a close");
            assertEq(failed.triggerBountyUsdc, 0, "risk-off must refund the trigger bounty");
            assertEq(failed.executionBountyUsdc, 0, "risk-off must refund the staged close bounty");
        }
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "risk-off must clear the active protection");

        {
            IMarginClearinghouse.OrderReservation memory releasedParent =
                clearinghouse.getOrderReservation(fixture.parentOrderId);
            assertEq(
                uint8(releasedParent.status),
                uint8(IMarginClearinghouse.ReservationStatus.Released),
                "parent margin reservation must be released"
            );
            assertEq(
                releasedParent.originalAmountUsdc, fixture.parentMarginUsdc, "parent original margin must be retained"
            );
            assertEq(releasedParent.remainingAmountUsdc, 0, "parent margin must have no remainder");
        }
        {
            IOrderRouterAccounting.AccountReservationView memory clearedReservations =
                router.getAccountReservations(ALICE);
            assertEq(clearedReservations.committedMarginUsdc, 0, "no parent margin may remain reserved");
            assertEq(clearedReservations.executionBountyUsdc, 0, "no parent or protection bounty may remain reserved");
            assertEq(clearedReservations.pendingOrderCount, 0, "no parent order may remain live");
        }
        assertEq(_freeSettlementUsdc(ALICE), fixture.freeBefore, "every reserve must return to free settlement");
        assertEq(_settlementBalance(ALICE), fixture.settlementBefore, "risk-off refund must preserve gross settlement");
        assertEq(
            _settlementBalance(CAROL), fixture.cleanerSettlementBefore, "permissionless cleaner must receive no bounty"
        );

        vm.prank(CAROL);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(fixture.parentOrderId);

        assertEq(_freeSettlementUsdc(ALICE), fixture.freeBefore, "retry must not double-release reserves");
        assertEq(_settlementBalance(CAROL), fixture.cleanerSettlementBefore, "retry must not credit the cleaner");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc, 0, "retry must leave all bounty reserves cleared"
        );
        assertEq(
            clearinghouse.getOrderReservation(fixture.parentOrderId).remainingAmountUsdc,
            0,
            "retry must release no margin"
        );
    }

    function test_AttachedOpen_RiskOffClearinghouseFailureRollsBackProtectionAndRouter() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0), params
        );
        vm.stopPrank();
        routerAdmin.pause();

        bytes32 orderHashBefore = keccak256(abi.encode(_orderRecord(parentOrderId)));
        bytes32 reservationHashBefore = keccak256(abi.encode(clearinghouse.getOrderReservation(parentOrderId)));
        bytes32 accountReservationsHashBefore = keccak256(abi.encode(router.getAccountReservations(ALICE)));
        bytes32 protectionHashBefore = keccak256(abi.encode(protectionViews.getPositionProtection(protectionId)));
        uint64 activeProtectionIdBefore = protectionViews.activePositionProtectionId(ALICE);
        uint64 nextExecuteBefore = router.nextExecuteId();
        uint64 globalTailBefore = router.globalTailOrderId();
        uint64 accountHeadBefore = router.accountHeadOrderId(ALICE);
        uint256 freeSettlementBefore = _freeSettlementUsdc(ALICE);

        vm.mockCallRevert(
            address(clearinghouse),
            abi.encodeWithSelector(IMarginClearinghouse.releaseInvalidatedOrderReserves.selector),
            bytes("forced clearinghouse failure")
        );
        vm.expectRevert(bytes("forced clearinghouse failure"));
        vm.prank(CAROL);
        router.clearRiskOffOrder(parentOrderId);
        vm.clearMockedCalls();

        assertEq(keccak256(abi.encode(_orderRecord(parentOrderId))), orderHashBefore, "order must roll back");
        assertEq(
            keccak256(abi.encode(clearinghouse.getOrderReservation(parentOrderId))),
            reservationHashBefore,
            "margin reservation must roll back"
        );
        assertEq(
            keccak256(abi.encode(router.getAccountReservations(ALICE))),
            accountReservationsHashBefore,
            "router reservation aggregates must roll back"
        );
        assertEq(
            keccak256(abi.encode(protectionViews.getPositionProtection(protectionId))),
            protectionHashBefore,
            "protection lifecycle and bounties must roll back"
        );
        assertEq(
            protectionViews.activePositionProtectionId(ALICE),
            activeProtectionIdBefore,
            "active protection must roll back"
        );
        assertEq(router.nextExecuteId(), nextExecuteBefore, "global head must roll back");
        assertEq(router.globalTailOrderId(), globalTailBefore, "global tail must roll back");
        assertEq(router.accountHeadOrderId(ALICE), accountHeadBefore, "account head must roll back");
        assertEq(_freeSettlementUsdc(ALICE), freeSettlementBefore, "free settlement must roll back");
    }

    function test_AttachedOpen_ParentExpiryBatchFailsProtectionsAndRefundsTheirBounties() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);

        vm.startPrank(ALICE);
        (uint64 aliceParentId, uint64 aliceProtectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0), params
        );
        vm.stopPrank();
        vm.startPrank(BOB);
        (uint64 bobParentId, uint64 bobProtectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_USDC, 0), params
        );
        vm.stopPrank();
        assertEq(aliceParentId, 1, "Alice parent queue id");
        assertEq(bobParentId, 2, "Bob parent queue id");

        vm.warp(block.timestamp + router.maxOrderAge() + 1);
        bytes[] memory empty = new bytes[](0);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrderBatch(bobParentId, empty);

        _assertExpiredAttachedProtection(ALICE, aliceParentId, aliceProtectionId);
        _assertExpiredAttachedProtection(BOB, bobParentId, bobProtectionId);
        assertEq(router.nextExecuteId(), 0, "batch expiry should fully drain the parent queue");
    }

    function _createSingleLegProtection(
        CfdTypes.Side side,
        uint256 takeProfit,
        uint256 stopLoss
    ) internal returns (uint64 protectionId) {
        return _createProtectionFor(ALICE, side, POSITION_SIZE, POSITION_MARGIN_USDC, takeProfit, stopLoss);
    }

    function _createProtectionFor(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 marginUsdc,
        uint256 takeProfit,
        uint256 stopLoss
    ) internal returns (uint64 protectionId) {
        _open(account, side, size, marginUsdc, MARK_PRICE);
        vm.prank(account);
        protectionId = protectionActions.createPositionProtection(_params(takeProfit, stopLoss));
    }

    function _triggerAt(
        uint64 protectionId,
        uint256 price
    ) internal returns (uint64 linkedOrderId) {
        bytes[] memory updateData = _mockPythUpdateData(price);
        vm.prank(TRIGGER_KEEPER);
        linkedOrderId = protectionActions.triggerPositionProtection(protectionId, updateData);
    }

    function _mockUniquePythUpdateDataAt(
        uint256 price,
        uint64 publishTime,
        uint64 previousPublishTime
    ) internal returns (bytes[] memory updateData) {
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(uint64(price)), 0, int32(-8), publishTime, previousPublishTime
        );
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _expireProtectionAttempt(
        uint64 orderId,
        address cleaner
    ) internal returns (OrderV2Types.ExecutionResult memory result) {
        uint64 validUntil = router.lifecycleBook().pendingPolicy(orderId).validUntil;
        assertGt(validUntil, block.timestamp, "fixture requires a live attempt before expiry");
        vm.warp(uint256(validUntil) + 1);
        vm.prank(cleaner);
        result = router.executeOrder(orderId, new bytes[](0));
    }

    function _expectTriggerNotMet(
        uint64 protectionId,
        uint256 price
    ) internal {
        bytes[] memory updateData = _mockPythUpdateData(price);
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TriggerNotMet.selector);
        protectionActions.triggerPositionProtection(protectionId, updateData);
    }

    function _assertTriggered(
        uint64 protectionId,
        uint64 linkedOrderId,
        PositionProtectionTypes.PositionProtectionTriggerLeg expectedLeg,
        uint256 expectedMark
    ) internal view {
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "triggered lifecycle"
        );
        assertEq(uint8(protection.triggeredLeg), uint8(expectedLeg), "triggered leg");
        assertEq(protection.triggerMarkPrice, expectedMark, "neutral trigger mark");
        assertEq(protection.linkedOrderId, linkedOrderId, "linked order id");
        assertEq(router.pendingOrderCounts(ALICE), 1, "linked close should enter account queue");
    }

    function _refreshMark(
        uint256 price
    ) internal {
        router.updateMarkPrice(_priceData(price));
    }

    function _priceData(
        uint256 price
    ) internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _params(
        uint256 takeProfit,
        uint256 stopLoss
    ) internal pure returns (PositionProtectionTypes.PositionProtectionParams memory params) {
        params.takeProfitTriggerPrice = takeProfit;
        params.stopLossTriggerPrice = stopLoss;
    }

    function _publicBoundedRequest(
        bytes32 clientOrderId,
        bool isClose
    ) internal view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = clientOrderId;
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = POSITION_SIZE;
        request.marginDelta = isClose ? 0 : POSITION_MARGIN_USDC;
        request.targetPrice = isClose ? engine.CAP_PRICE() : 1;
        request.isClose = isClose;
        request.bounds = OrderV2Types.ExecutionBounds({
            validUntil: uint64(block.timestamp + router.maxOrderAge()),
            allowedExecutionModes: 1 | 2 | 4,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _boundedOpenRequest(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) internal view returns (OrderV2Types.OrderRequest memory request) {
        request = _publicBoundedRequest(bytes32(uint256(router.nextCommitId())), false);
        request.side = side;
        request.sizeDelta = sizeDelta;
        request.marginDelta = marginDelta;
        request.targetPrice = targetPrice == 0 ? (side == CfdTypes.Side.LONG ? 1 : engine.CAP_PRICE()) : targetPrice;
    }

    function _expectAttachedOpenCommitRevert(
        OrderV2Types.OrderRequest memory request,
        bytes memory revertData
    ) internal {
        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        uint64 nextParentBefore = router.nextCommitId();
        uint64 nextProtectionBefore = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();

        vm.expectRevert(revertData);
        vm.prank(ALICE);
        protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(router.nextCommitId(), nextParentBefore, "rejection must not allocate parent");
        assertEq(
            PositionProtectionBook(address(protectionBook)).nextPositionProtectionId(),
            nextProtectionBefore,
            "rejection must not allocate protection"
        );
        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "rejection must roll back protection bounty locks");
        assertEq(router.pendingOrderCounts(ALICE), 0, "rejection must not queue parent");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "rejection must not stage protection");
    }

    function _assertAttachedOpenTerminalFailure(
        uint64 parentOrderId,
        uint64 protectionId
    ) internal view {
        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(_orderRecord(parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "parent must fail"
        );
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "protection must fail with parent"
        );
        assertEq(failed.triggerBountyUsdc, 0, "trigger bounty must clear");
        assertEq(failed.executionBountyUsdc, 0, "close bounty must clear");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "trade lock must clear");
        assertEq(router.pendingOrderCounts(ALICE), 0, "parent must leave queue");
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "failed parent must not create position");
    }

    function _totalProtectionBountyUsdc() internal view returns (uint256) {
        return router.positionProtectionTriggerBountyUsdc() + router.closeOrderExecutionBountyUsdc();
    }

    function _settlementBufferTargetUsdc(
        uint256 maxLiabilityUsdc
    ) internal view returns (uint256) {
        return SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiabilityUsdc, engine.settlementBufferBps());
    }

    function _drainPoolTo(
        uint256 targetAssetsUsdc
    ) internal {
        uint256 assetsUsdc = pool.totalAssets();
        assertGt(assetsUsdc, targetAssetsUsdc, "fixture must have drainable pool assets");
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), assetsUsdc - targetAssetsUsdc);
        assertEq(pool.totalAssets(), targetAssetsUsdc, "fixture must reach the requested pool assets");
    }

    function _riskBoundaryFixture(
        CfdTypes.RiskParams memory riskParams,
        uint256 requiredMarginBps
    ) internal view returns (RiskBoundaryFixture memory fixture) {
        uint256 notionalUsdc = (POSITION_SIZE * MARK_PRICE) / 1e20;
        fixture.requirementUsdc = (notionalUsdc * requiredMarginBps) / 10_000;
        fixture.exactOpeningMarginDeltaUsdc = fixture.requirementUsdc
            + _engineExecutionFeeUsdc(POSITION_SIZE, MARK_PRICE)
            + _liquidationReserveTargetUsdc(notionalUsdc, riskParams);
        fixture.plusOneOpeningMarginDeltaUsdc = fixture.exactOpeningMarginDeltaUsdc + 1;
        fixture.protectionBountiesUsdc = _totalProtectionBountyUsdc();
    }

    function _liquidationReserveTargetUsdc(
        uint256 notionalUsdc,
        CfdTypes.RiskParams memory riskParams
    ) internal pure returns (uint256 reserveTargetUsdc) {
        reserveTargetUsdc = (notionalUsdc * riskParams.bountyBps) / 10_000;
        if (reserveTargetUsdc < riskParams.minBountyUsdc) {
            reserveTargetUsdc = riskParams.minBountyUsdc;
        }
    }

    function _seedAuthenticatedTraderClaim(
        address account,
        uint256 claimUsdc
    ) internal {
        bytes32 oldCurveHash = terminalNavBook.curveHashOf(account);
        uint256 oldAccountClaimUsdc = engine.traderClaimBalanceUsdc(account);
        uint256 oldTotalClaimUsdc = engine.totalTraderClaimBalanceUsdc();
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(account)
            .checked_write(claimUsdc);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()")
            .checked_write(oldTotalClaimUsdc - oldAccountClaimUsdc + claimUsdc);
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(account, oldCurveHash);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
    }

    function _withdrawAllFreeSettlement(
        address account
    ) internal {
        uint256 freeSettlementUsdc = _freeSettlementUsdc(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlementUsdc);
    }

    function _assertExpiredAttachedProtection(
        address account,
        uint64 parentOrderId,
        uint64 protectionId
    ) internal view {
        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "expired parent should fail its staged protection"
        );
        assertEq(failed.triggerBountyUsdc, 0, "expiry should refund the staged trigger bounty");
        assertEq(failed.executionBountyUsdc, 0, "expiry should refund the staged close bounty");
        assertEq(protectionViews.activePositionProtectionId(account), 0, "expiry should clear the trade lock");
        assertEq(
            uint8(_orderRecord(parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "expired parent should be terminally failed"
        );
        assertEq(router.pendingOrderCounts(account), 0, "expiry should clear the account queue");
        assertEq(router.getAccountReservations(account).executionBountyUsdc, 0, "expiry should clear every reserve");
    }

    function _assertSingleRiskOffRefund(
        Vm.Log[] memory logs,
        address expectedAccount,
        uint256 expectedMarginUsdc,
        uint256 expectedBountyUsdc
    ) internal view {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(clearinghouse) || entry.topics.length < 2
                    || entry.topics[0] != RISK_OFF_RESERVES_REFUNDED_TOPIC
            ) {
                continue;
            }
            ++matches;
            assertEq(address(uint160(uint256(entry.topics[1]))), expectedAccount, "risk-off refund account");
            (uint256 releasedMarginUsdc, uint256 refundableBountyUsdc) = abi.decode(entry.data, (uint256, uint256));
            assertEq(releasedMarginUsdc, expectedMarginUsdc, "risk-off released margin");
            assertEq(refundableBountyUsdc, expectedBountyUsdc, "risk-off aggregate bounty refund");
        }
        assertEq(matches, 1, "exactly one aggregate risk-off refund event");
    }

}

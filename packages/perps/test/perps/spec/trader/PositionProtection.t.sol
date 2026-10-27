// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
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
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

contract PositionProtectionTest is BasePerpTest {

    using stdStorage for StdStorage;

    struct RiskBoundaryFixture {
        uint256 requirementAssets;
        uint256 exactOpeningMarginDeltaAssets;
        uint256 plusOneOpeningMarginDeltaAssets;
        uint256 protectionBountiesAssets;
    }

    struct RiskOffRefundFixture {
        uint256 freeBefore;
        uint256 settlementBefore;
        uint256 cleanerSettlementBefore;
        uint256 parentMarginAssets;
        uint256 parentBountyAssets;
        uint256 protectionBountiesAssets;
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
    uint256 internal constant POST_MARK_PRICE = MARK_PRICE + 2;
    uint256 internal constant POSITION_SIZE = 10_000e18;
    uint256 internal constant POSITION_MARGIN_ASSETS = 2000e6;
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

        _refreshMark(MARK_PRICE);
    }

    function test_ZeroBountyProtectionExpiryAndRetryUsesExplicitReservation() public {
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        _setRouterConfig(config);
        _refreshMark(MARK_PRICE);
        test_RetryPositionProtectionClose_StaysZeroBountyAfterTriggerConfigChangeWithoutFreshFunds();
    }

    function test_Constructor_RejectsZeroRouterOrEngine() public {
        _startRecordingLogs();
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__ZeroAddress.selector);
        new PositionProtectionBook(address(0), address(engine));

        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__ZeroAddress.selector);
        new PositionProtectionBook(address(router), address(0));
    }

    function test_CreatePositionProtection_RejectsNoPositionIncludingDegradedMode() public {
        for (uint256 i; i < 2; ++i) {
            stdstore.target(address(engine)).sig("degradedMode()").checked_write(i != 0);
            vm.prank(ALICE);
            vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOpenPosition.selector);
            protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
            assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "failed creation releases reserve");
        }
    }

    function test_CreatePositionProtection_DegradedLongCanArmAndTrigger() public {
        _assertDegradedPositionCanArmAndTrigger(CfdTypes.Side.LONG);
    }

    function test_CreatePositionProtection_DegradedShortCanArmAndTrigger() public {
        _assertDegradedPositionCanArmAndTrigger(CfdTypes.Side.SHORT);
    }

    function _assertDegradedPositionCanArmAndTrigger(
        CfdTypes.Side side
    ) internal {
        _refreshMark(95_000_000);
        _open(ALICE, side, POSITION_SIZE, POSITION_MARGIN_ASSETS, 95_000_000);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        uint256 freeBefore = _freeSettlementAssets(ALICE);
        (uint256 sizeBefore, uint256 marginBefore,,,,,) = engine.positions(ALICE);
        uint256 triggerPrice = side == CfdTypes.Side.LONG ? LONG_TAKE_PROFIT : SHORT_TAKE_PROFIT;

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(triggerPrice, 0));
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(uint8(protection.status), uint8(PositionProtectionTypes.PositionProtectionStatus.Armed));
        assertEq(protection.size, sizeBefore, "protects the entire existing position");
        assertEq(uint8(protection.side), uint8(side));
        assertEq(router.pendingOrderCounts(ALICE), 0, "arming creates no ordinary order");
        assertEq(_freeSettlementAssets(ALICE), freeBefore - _totalProtectionBountyAssets(), "bounty remains funded");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, _totalProtectionBountyAssets());
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(ALICE);
        assertEq(sizeAfter, sizeBefore, "arming does not expand exposure");
        assertEq(marginAfter, marginBefore, "arming preserves pledged margin");
        assertTrue(engine.degradedMode(), "arming must not clear containment");

        uint64 attemptId = _triggerAt(protectionId, triggerPrice);
        assertEq(protectionViews.getPositionProtection(protectionId).linkedOrderId, attemptId);
        assertEq(router.pendingCloseSize(ALICE), sizeBefore, "new protection can queue a full close");
        assertTrue(engine.degradedMode(), "trigger must not clear containment");
    }

    function test_CreatePositionProtection_DegradedRetainsPauseFreshnessAndFrozenGuards() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        uint256 freeBefore = _freeSettlementAssets(ALICE);
        routerAdmin.pause();
        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        routerAdmin.unpause();

        vm.warp(uint256(engine.lastMarkTime()) + pletherOracle.orderExecutionStalenessLimit() + 1);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionMarkTooStale.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));

        vm.warp(FRIDAY_FAD_START + 3 hours);
        assertTrue(engine.isOracleFrozen());
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ConditionalTriggerFrozen.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "rejections release temporary reserve");
        assertEq(_freeSettlementAssets(ALICE), freeBefore, "rejections roll back carry and lock");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0);
    }

    function test_AttachedOpen_DegradedStillRejectsNewExposure() public {
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        _expectAttachedOpenCommitRevert(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0),
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__DegradedMode.selector)
        );
    }

    function test_CreatePositionProtection_RejectsEmptyOrAboveCapThresholds() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(0, 0));

        uint256 capPrice = engine.CAP_PRICE();
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(capPrice + 1, 0));

        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            0,
            "invalid protection prices must roll back both bounty locks"
        );
    }

    function test_CreatePositionProtection_ValidatesLongGeometryAndArmsOffQueue() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(LONG_STOP_LOSS, LONG_TAKE_PROFIT));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(MARK_PRICE, 0));

        uint256 freeBefore = _freeSettlementAssets(ALICE);
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
            _freeSettlementAssets(ALICE),
            freeBefore - _totalProtectionBountyAssets(),
            "both protection bounties should be reserved"
        );
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            _totalProtectionBountyAssets(),
            "reservation view should include dormant protection bounties"
        );
    }

    function test_CreatePositionProtection_ValidatesShortGeometry() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);

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

    function test_CreatePositionProtection_RejectsThresholdCrossedByCurrentOracleButNotCachedMark() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        uint256 cachedMark = engine.lastMarkPrice();
        uint64 nextProtectionId = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        IPletherOracle.PriceSnapshot memory current =
            pletherOracle.updatePrice(BOB, _priceData(LONG_TAKE_PROFIT), IPletherOracle.PriceMode.MarkRefresh);
        assertEq(current.markPrice, LONG_TAKE_PROFIT, "oracle must see the crossed price");
        assertEq(engine.lastMarkPrice(), cachedMark, "direct oracle update must leave the engine mark cached");

        vm.prank(ALICE);
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__OracleMarkAhead.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        router.updateMarkPrice(new bytes[](0));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "crossed create must leave no protection");
        assertEq(
            PositionProtectionBook(address(protectionBook)).nextPositionProtectionId(),
            nextProtectionId,
            "crossed create must not consume an id"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "crossed create must release bounty");

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        router.updateMarkPrice(_livePriceData(MARK_PRICE));
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        assertEq(protectionId, nextProtectionId, "uncrossed current price should allow creation");
    }

    function test_LongTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        _startRecordingLogs();
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
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);

        _expectTriggerNotMet(protectionId, LONG_STOP_LOSS - 1);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, LONG_STOP_LOSS
        );
    }

    function test_ShortTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        _startRecordingLogs();
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

    function test_ShortProtection_ZeroAdjustedPricePreservesAttemptAndAllowsExpiryRetry() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.SHORT, SHORT_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, SHORT_TAKE_PROFIT);
        CfdTypes.Order memory order = _orderRecord(linkedOrderId).core;
        uint256 balanceBefore = _settlementBalance(ALICE);
        uint256 keeperBefore = _settlementBalance(EXECUTION_KEEPER);
        uint256 markBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        vm.warp(uint256(order.commitTime) + 1);
        vm.roll(block.number + 1);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), 1_000_000_000_000, 1_000_000_000, -8, order.commitTime + 1, order.commitTime
        );
        bytes[] memory data = new bytes[](1);
        data[0] = hex"01";

        vm.prank(EXECUTION_KEEPER);
        vm.expectRevert(IPletherOracle.PletherOracle__ZeroExecutionPrice.selector);
        router.executeOrder(linkedOrderId, data);

        assertEq(router.nextExecuteId(), linkedOrderId, "invalid observation leaves the close queued");
        assertEq(router.pendingOrderCounts(ALICE), 1, "attempt remains pending");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "protection remains active");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "invalid observation does not terminalize or relatch the attempt"
        );
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, POSITION_SIZE, "position unchanged");
        assertEq(_settlementBalance(ALICE), balanceBefore, "trader balance unchanged");
        assertEq(_settlementBalance(EXECUTION_KEEPER), keeperBefore, "no keeper payout");
        assertEq(engine.lastMarkPrice(), markBefore, "engine mark unchanged");
        assertEq(engine.lastMarkTime(), markTimeBefore, "engine publication unchanged");

        _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        bytes[] memory retryData = _mockPythUpdateData(SHORT_TAKE_PROFIT);
        vm.roll(uint256(_orderRecord(retryOrderId).core.commitBlock) + 1);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(retryOrderId, retryData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "positive-price retry executes");
        (size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0, "retry closes the protected short");
    }

    function test_ShortStopLoss_TriggersAtEqualityAndRejectsWrongDirection() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.SHORT, 0, SHORT_STOP_LOSS);

        _expectTriggerNotMet(protectionId, SHORT_STOP_LOSS + 2);
        uint64 linkedOrderId = _triggerAt(protectionId, SHORT_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, SHORT_STOP_LOSS
        );
    }

    function test_TriggeredProtection_RejectsReplacementAndCancellation() public {
        _startRecordingLogs();
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
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);

        vm.warp(block.timestamp + 1);
        bytes[] memory sameBlockData = _livePriceData(LONG_TAKE_PROFIT);
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SameBlockTrigger.selector);
        protectionActions.triggerPositionProtection(protectionId, sameBlockData);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(LONG_TAKE_PROFIT)), 0, int32(-8), armed.armedAt - 60);
        bytes[] memory oldPublishData = new bytes[](1);
        oldPublishData[0] = hex"01";

        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(bytes("outside range"));
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
            router.getAccountReservations(ALICE).executionBountyAssets,
            _totalProtectionBountyAssets(),
            "timing reverts must preserve both bounties"
        );
    }

    function test_TriggerPositionProtection_AcceptsNewOracleTickBehindArmingWallClock() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        uint64 observedPublishTime = engine.lastMarkTime();
        vm.warp(block.timestamp + 5);

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        uint64 armedAt = protectionViews.getPositionProtection(protectionId).armedAt;
        assertLt(observedPublishTime + 1, armedAt, "fixture requires oracle publication to lag arming time");

        vm.roll(block.number + 1);
        baseMockPyth.setAllPrices(
            _basePythFeedIds(), int64(uint64(LONG_TAKE_PROFIT)), 0, int32(-8), observedPublishTime + 1
        );
        bytes[] memory alreadyStoredData = new bytes[](1);
        alreadyStoredData[0] = hex"01";
        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection(protectionId, alreadyStoredData);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            LONG_TAKE_PROFIT
        );
        assertEq(
            protectionViews.getPositionProtection(protectionId).triggerPublishTime,
            observedPublishTime + 1,
            "trigger must use the newer oracle observation"
        );
    }

    function test_ArbitrumTrigger_UsesL2BlockWhileL1BlockStaysConstant() public {
        vm.chainId(421_614);
        _mockArbitrumBlockNumber(10_000);
        uint256 l1Block = block.number;

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(armed.armedBlock, 10_000, "protection must store the L2 block");

        vm.warp(block.timestamp + 1);
        bytes[] memory freshData = _mockUniquePythUpdateDataAt(LONG_TAKE_PROFIT, armed.armedAt + 1, armed.armedAt);
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SameBlockTrigger.selector);
        protectionActions.triggerPositionProtection(protectionId, freshData);
        assertEq(block.number, l1Block, "L1 block must remain fixed after same-L2 rejection");

        _mockArbitrumBlockNumber(10_001);
        baseMockPyth.setAllUniquePrices(_basePythFeedIds(), int64(uint64(MARK_PRICE)), 0, int32(-8), armed.armedAt, 0);
        bytes[] memory oldPublishData = new bytes[](1);
        oldPublishData[0] = hex"01";
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TriggerPublishTimeNotAdvanced.selector);
        protectionActions.triggerPositionProtection(protectionId, oldPublishData);

        freshData = _mockUniquePythUpdateDataAt(LONG_TAKE_PROFIT, armed.armedAt + 1, armed.armedAt);
        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection(protectionId, freshData);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            LONG_TAKE_PROFIT
        );
        assertEq(_orderRecord(linkedOrderId).core.commitBlock, 10_001, "linked close must store the L2 block");
        assertEq(block.number, l1Block, "trigger must not require an L1 block change");
    }

    function test_ArbitrumTriggeredClose_ExecutesInLaterL2BlockWithoutL1BlockChange() public {
        vm.chainId(421_614);
        _mockArbitrumBlockNumber(20_000);
        uint256 l1Block = block.number;

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 armedAt = protectionViews.getPositionProtection(protectionId).armedAt;
        vm.warp(block.timestamp + 1);
        _mockArbitrumBlockNumber(20_001);
        bytes[] memory triggerData = _mockUniquePythUpdateDataAt(LONG_TAKE_PROFIT, armedAt + 1, armedAt);
        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection(protectionId, triggerData);
        assertEq(_orderRecord(linkedOrderId).core.commitBlock, 20_001, "close must commit at the trigger L2 block");
        uint64 closeCommittedAt = _orderRecord(linkedOrderId).core.commitTime;

        vm.warp(uint256(closeCommittedAt) + 1);
        bytes[] memory executionData =
            _mockUniquePythUpdateDataAt(LONG_TAKE_PROFIT, closeCommittedAt + 1, closeCommittedAt);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory sameBlock = router.executeOrder(linkedOrderId, executionData);
        assertEq(
            uint8(sameBlock.status), uint8(OrderV3Types.LifecycleStatus.Pending), "same-L2 close must remain pending"
        );
        assertEq(uint8(sameBlock.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));
        assertEq(router.nextExecuteId(), linkedOrderId, "same-L2 attempt must keep the close queued");

        _mockArbitrumBlockNumber(20_002);
        vm.warp(uint256(closeCommittedAt) + 2);
        executionData = _mockUniquePythUpdateDataAt(LONG_TAKE_PROFIT, closeCommittedAt + 2, closeCommittedAt);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory laterBlock = router.executeOrder(linkedOrderId, executionData);
        assertEq(uint8(laterBlock.status), uint8(OrderV3Types.LifecycleStatus.Executed), "later-L2 close must execute");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed),
            "successful close must terminalize protection"
        );
        assertEq(block.number, l1Block, "close execution must not require an L1 block change");
    }

    function test_ArbitrumOrdinaryOrder_UsesL2BlockForSameBlockExecutionShield() public {
        vm.chainId(421_614);
        _mockArbitrumBlockNumber(30_000);
        uint256 l1Block = block.number;

        vm.prank(BOB);
        uint64 orderId = router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0, false);
        assertEq(_orderRecord(orderId).core.commitBlock, 30_000, "ordinary order must store the L2 block");
        uint64 committedAt = _orderRecord(orderId).core.commitTime;

        vm.warp(uint256(committedAt) + 1);
        bytes[] memory executionData = _mockUniquePythUpdateDataAt(MARK_PRICE, committedAt + 1, committedAt);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory sameBlock = router.executeOrder(orderId, executionData);
        assertEq(
            uint8(sameBlock.status), uint8(OrderV3Types.LifecycleStatus.Pending), "same-L2 order must remain pending"
        );
        assertEq(uint8(sameBlock.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));

        _mockArbitrumBlockNumber(30_001);
        vm.warp(uint256(committedAt) + 2);
        executionData = _mockUniquePythUpdateDataAt(MARK_PRICE, committedAt + 2, committedAt);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory laterBlock = router.executeOrder(orderId, executionData);
        assertEq(uint8(laterBlock.status), uint8(OrderV3Types.LifecycleStatus.Executed), "later-L2 order must execute");
        assertEq(block.number, l1Block, "ordinary order must execute without an L1 block change");
    }

    function test_TriggerUsesArmedOracleTimeWhenSignedTickPredatesWallClockArm() public {
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        uint64 armedOracleTime = engine.lastMarkTime();
        vm.warp(uint256(armedOracleTime) + 5);
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        uint64 armedAt = protectionViews.getPositionProtection(protectionId).armedAt;
        assertLt(armedOracleTime + 1, armedAt);

        vm.roll(block.number + 1);
        vm.warp(uint256(armedAt) + 1);
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            ticks[i] = MockPyth.FeedUpdate(
                ids[i], MockPyth.MockPrice(int64(uint64(LONG_TAKE_PROFIT)), 0, -8, armedOracleTime + 1, armedOracleTime)
            );
        }
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(ticks);
        vm.prank(TRIGGER_KEEPER);
        uint64 linkedOrderId = protectionActions.triggerPositionProtection(protectionId, data);
        assertGt(linkedOrderId, 0);
        assertEq(protectionViews.getPositionProtection(protectionId).triggerPublishTime, armedOracleTime + 1);
    }

    function test_TriggeredClose_AppendsToGlobalFifoAndExecutesThroughOrdinaryPath() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        vm.prank(BOB);
        router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0, false);
        assertEq(router.nextExecuteId(), 1, "foreign order should be queue head");

        uint256 triggerKeeperBefore = clearinghouse.balanceAssets(TRIGGER_KEEPER);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        assertEq(linkedOrderId, 2, "triggered close should consume the next ordinary order id");
        assertEq(router.nextExecuteId(), 1, "triggered close must not jump the foreign head");
        assertEq(router.globalTailOrderId(), linkedOrderId, "triggered close should join the FIFO tail");
        assertEq(_orderRecord(1).nextGlobalOrderId, linkedOrderId, "foreign head should link to close");
        assertEq(_orderRecord(linkedOrderId).prevGlobalOrderId, 1, "close should link back to foreign head");
        assertEq(
            clearinghouse.balanceAssets(TRIGGER_KEEPER) - triggerKeeperBefore,
            router.positionProtectionTriggerBountyAssets(),
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
            router.getAccountReservations(ALICE).executionBountyAssets,
            0,
            "trigger must transfer, not duplicate, the close bounty"
        );

        bytes[] memory nonHeadExecutionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        router.executeOrder(linkedOrderId, nonHeadExecutionData);

        bytes[] memory bobExecutionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(1, bobExecutionData);

        uint256 executionKeeperBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
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
            clearinghouse.balanceAssets(EXECUTION_KEEPER) - executionKeeperBefore,
            0,
            "close executor should receive the remaining bounty once"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "linked close should fully exit the protected position");
    }

    function test_TriggeredClose_ExecutesInDegradedModeBelowSettlementBufferWhileRawSolvent() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        uint256 maxLiabilityAssets = _maxLiability();
        uint256 settlementBufferAssets = _settlementBufferTargetAssets(maxLiabilityAssets);
        _drainPoolTo(maxLiabilityAssets);

        assertEq(pool.totalAssets(), maxLiabilityAssets, "setup should retain raw solvency equality");
        assertGt(settlementBufferAssets, 0, "live protection should require a nonzero settlement buffer");
        assertLt(
            pool.totalAssets(),
            maxLiabilityAssets + settlementBufferAssets,
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

    function test_ExpiredProtectionAttempt_RelatchesWithZeroBountyAndPaysNoCleaner() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyAssets = 0;
        uint256 actionReserveBefore = clearinghouse.actionReserveAssets(ALICE);
        uint256 cleanerBalanceBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);

        OrderV3Types.ExecutionResult memory result = _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "expiry lifecycle status");
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired), "expiry reason");
        assertEq(
            clearinghouse.balanceAssets(EXECUTION_KEEPER),
            cleanerBalanceBefore,
            "zero-bounty protection attempt must not credit the cleaner"
        );

        PositionProtectionTypes.PositionProtectionView memory latched =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(latched.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "expired close attempt should relatch"
        );
        assertEq(latched.linkedOrderId, linkedOrderId, "latched protection retains latest attempt history");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "latch keeps the trade lock active");
        assertEq(router.pendingOrderCounts(ALICE), 0, "expired attempt should leave no live account order");
        assertEq(router.pendingCloseSize(ALICE), 0, "expired attempt should clear pending close size");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            executionBountyAssets,
            "relatched protection must have no execution bounty reserve"
        );
        assertEq(
            clearinghouse.actionReserveAssets(ALICE),
            actionReserveBefore,
            "expiry should not change the underlying action reserve"
        );

        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), linkedOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Expired), "receipt expiry reason");
        assertEq(
            uint8(outcome.bountyDisposition),
            uint8(OrderV3Types.BountyDisposition.None),
            "receipt should authenticate zero-bounty expiry"
        );
        assertEq(outcome.bountyAssets, executionBountyAssets, "receipt should preserve the bounty amount");
        assertEq(outcome.bountyRecipient, address(0), "zero bounty has no recipient");
        assertFalse(router.lifecycleBook().isProtectionAttempt(linkedOrderId), "terminal receipt should clear marker");
    }

    function test_RetryPositionProtectionClose_IsPermissionlessFreshAndAppendsFifoTail() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        CfdTypes.Order memory firstOrder = _orderRecord(firstOrderId).core;
        uint64 firstValidUntil = router.lifecycleBook().orderTiming(firstOrderId).executionDeadline;
        PositionProtectionTypes.PositionProtectionView memory triggered =
            protectionViews.getPositionProtection(protectionId);

        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        vm.prank(BOB);
        uint64 foreignOrderId = router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0, false);
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
        OrderV3Types.ExecutionBounds memory retryBounds = router.lifecycleBook().pendingPolicy(retryOrderId);
        assertGt(retryOrder.commitTime, firstOrder.commitTime, "retry should use a fresh commit clock");
        assertEq(retryOrder.commitTime, block.timestamp, "retry commit time");
        assertEq(retryOrder.commitBlock, block.number, "retry commit block");
        assertGt(
            router.lifecycleBook().orderTiming(retryOrderId).executionDeadline,
            firstValidUntil,
            "retry should receive a fresh validity window"
        );
        assertEq(
            router.lifecycleBook().orderTiming(retryOrderId).executionDeadline,
            retryOrder.commitTime + uint64(router.maxExecutionWindowSeconds()),
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
        assertEq(_orderRecord(retryOrderId).executionBountyAssets, 0, "retry close remains zero bounty");
        assertEq(uint8(retried.triggeredLeg), uint8(triggered.triggeredLeg), "retry must preserve trigger leg");
        assertEq(retried.triggerMarkPrice, triggered.triggerMarkPrice, "retry must preserve trigger mark");
        assertEq(retried.triggerPublishTime, triggered.triggerPublishTime, "retry must preserve trigger publish time");

        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotLatched.selector);
        protectionActions.retryPositionProtectionClose(protectionId);
        assertEq(router.pendingOrderCounts(ALICE), 1, "double retry must not create another child");
    }

    function test_ProtectionCloseLimits_PropagateToTriggeredCloseAndPermissionlessRetry() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, 0);
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: 12_345e6,
            maxGrossAccountDebitAssets: 9876e6,
            maxActionChargeAssets: 4321e6,
            maxExplicitFeesAssets: 1234e6
        });

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(params);
        _assertStoredCloseLimits(protectionId, params.closeLimits);

        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _assertPendingCloseLimits(firstOrderId, params.closeLimits);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        _assertStoredCloseLimits(protectionId, params.closeLimits);
        _assertPendingCloseLimits(retryOrderId, params.closeLimits);
    }

    function test_ProtectionCloseLimits_ExcessExecutionNotionalFailsWithoutSettlingPosition() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, 0);
        uint256 expectedNotionalAssets = (POSITION_SIZE * LONG_TAKE_PROFIT) / 1e20;
        params.closeLimits.maxExecutionNotionalAssets = expectedNotionalAssets - 1;

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(params);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _assertPendingCloseLimits(linkedOrderId, params.closeLimits);

        uint256 balanceBefore = clearinghouse.balanceAssets(ALICE);
        uint256 actionReserveBefore = clearinghouse.actionReserveAssets(ALICE);
        bytes[] memory executionData = _mockPythUpdateData(LONG_TAKE_PROFIT);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(linkedOrderId, executionData);

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "bounded close must fail");
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV3Types.TerminalReason.ConstraintViolation),
            "financial bound must cause typed failure"
        );
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), linkedOrderId);
        assertEq(
            uint8(outcome.failedConstraint),
            uint8(OrderV3Types.ConstraintKind.ExecutionNotional),
            "receipt must identify the exceeded ceiling"
        );
        assertEq(
            outcome.failureSelector,
            ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
            "receipt must preserve the typed policy error"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, POSITION_SIZE, "rejected close must leave the position open");
        assertEq(clearinghouse.balanceAssets(ALICE), balanceBefore, "rejected close must not debit settlement");
        assertEq(
            clearinghouse.actionReserveAssets(ALICE),
            actionReserveBefore,
            "rejected close must not consume action reserve"
        );
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "failed protected close must relatch for a trader-authorized retry"
        );
    }

    function test_ProtectionCloseLimits_OnlyOwnerCanAmendLatchedLimitsForNextRetry() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, 0);
        params.closeLimits.maxExecutionNotionalAssets = 1e6;

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(params);
        PositionProtectionTypes.CloseFinancialLimits memory amendedLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: 25_000e6,
            maxGrossAccountDebitAssets: 25_000e6,
            maxActionChargeAssets: 25_000e6,
            maxExplicitFeesAssets: 25_000e6
        });

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotLatched.selector);
        protectionActions.amendLatchedPositionProtectionCloseLimits(protectionId, amendedLimits);

        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "first attempt must relatch before amendment"
        );

        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionActions.amendLatchedPositionProtectionCloseLimits(protectionId, amendedLimits);
        _assertStoredCloseLimits(protectionId, params.closeLimits);

        vm.prank(ALICE);
        protectionActions.amendLatchedPositionProtectionCloseLimits(protectionId, amendedLimits);
        _assertStoredCloseLimits(protectionId, amendedLimits);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);
        _assertPendingCloseLimits(retryOrderId, amendedLimits);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotLatched.selector);
        protectionActions.amendLatchedPositionProtectionCloseLimits(protectionId, params.closeLimits);
        _assertPendingCloseLimits(retryOrderId, amendedLimits);

        bytes[] memory executionData = _mockPythUpdateData(LONG_TAKE_PROFIT);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(retryOrderId, executionData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "amended retry must execute");
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "amended retry must close the protected position");
    }

    function test_RetryPositionProtectionClose_StaleOldAttemptCallbacksCannotMutateReplacement() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 oldOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyAssets = 0;
        _expireProtectionAttempt(oldOrderId, EXECUTION_KEEPER);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);

        vm.startPrank(address(router));
        protectionBook.afterOrderTerminal(oldOrderId, ALICE, IOrderRouterAccounting.OrderStatus.Executed);
        bool retained =
            protectionBook.handleFailedProtectionAttempt(oldOrderId, ALICE, OrderV3Types.TerminalReason.Expired);
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
        assertEq(
            protectionViews.activePositionProtectionId(ALICE), protectionId, "replacement must keep the trade lock"
        );
        assertFalse(router.lifecycleBook().isProtectionAttempt(oldOrderId), "old attempt marker must stay cleared");
        assertTrue(
            router.lifecycleBook().isProtectionAttempt(retryOrderId), "replacement attempt marker must stay live"
        );
        assertEq(router.pendingOrderCounts(ALICE), 1, "obsolete callbacks must not unlink the replacement");
        assertEq(
            _orderRecord(retryOrderId).executionBountyAssets, executionBountyAssets, "replacement stays zero bounty"
        );
    }

    function test_RetryPositionProtectionClose_OracleWindowStartsStrictlyAfterFreshCommit() public {
        _startRecordingLogs();
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
        OrderV3Types.ExecutionResult memory result = router.executeOrder(retryOrderId, oldWindowData);
        assertEq(result.orderId, retryOrderId);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));

        bytes[] memory commitBoundaryData =
            _mockUniquePythUpdateDataAt(MARK_PRICE, retryOrder.commitTime, retryOrder.commitTime - 1);
        vm.prank(EXECUTION_KEEPER);
        result = router.executeOrder(retryOrderId, commitBoundaryData);
        assertEq(result.orderId, retryOrderId);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));

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
        _startRecordingLogs();
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
        OrderV3Types.ExecutionResult memory result = router.executeOrder(retryOrderId, afterDeadlineData);
        assertEq(result.orderId, retryOrderId);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));

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
        _startRecordingLogs();
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

        uint256 executionBountyAssets = 0;
        uint256 executorBalanceBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
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
            clearinghouse.balanceAssets(EXECUTION_KEEPER) - executorBalanceBefore,
            executionBountyAssets,
            "successful retry should pay the original bounty exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "success should clear bounty reserve");
        assertEq(clearinghouse.actionReserveAssets(ALICE), 0, "success should consume the action reserve");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), retryOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Executed), "successful retry receipt");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None), "paid disposition");
        assertEq(outcome.bountyRecipient, address(0), "receipt bounty recipient");
        assertEq(outcome.bountyAssets, executionBountyAssets, "receipt bounty amount");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "success should clear attempt marker");
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "successful retry should fully close the position");
    }

    function test_MismatchedProtectionExpiry_RelatchesAndRetries() public {
        _assertMismatchedProtectionExpiry(0, 0, CfdTypes.Side.LONG);
    }

    function testFuzz_MismatchedProtectionExpiry_AllCleanupRoutes(
        uint8 anomalySeed,
        uint8 routeSeed,
        bool shortSide
    ) public {
        _assertMismatchedProtectionExpiry(
            uint8(bound(anomalySeed, 0, 5)),
            uint8(bound(routeSeed, 0, 2)),
            shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG
        );
    }

    function _assertMismatchedProtectionExpiry(
        uint8 anomaly,
        uint8 route,
        CfdTypes.Side side
    ) internal {
        _startRecordingLogs();
        uint256 triggerPrice = side == CfdTypes.Side.LONG ? LONG_TAKE_PROFIT : SHORT_TAKE_PROFIT;
        uint64 protectionId = _createSingleLegProtection(side, triggerPrice, 0);
        uint64 attemptId = _triggerAt(protectionId, triggerPrice);
        _damageProtectionAttemptReservation(attemptId, anomaly);
        bytes32 bucketsBefore = keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ALICE)));
        uint256 keeperBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        uint256 triggerKeeperBefore = clearinghouse.balanceAssets(TRIGGER_KEEPER);
        bytes32 limitsBefore = keccak256(abi.encode(protectionViews.closeFinancialLimits(protectionId)));
        vm.warp(uint256(router.lifecycleBook().orderTiming(attemptId).executionDeadline) + 1);
        vm.prank(EXECUTION_KEEPER);
        if (route == 0) {
            router.expireOrder(attemptId);
        } else if (route == 1) {
            router.executeOrder(attemptId, new bytes[](0));
        } else {
            OrderV3Types.BatchResult memory batch = router.executeOrderBatch(attemptId, new bytes[](0));
            assertEq(batch.terminalCount, 1, "batch removes the expired head");
        }
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), attemptId);
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.ExpiredReservationMismatch));
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(outcome.bountyAssets, 0, "recovery cannot fabricate a refund");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None));
        assertEq(keccak256(abi.encode(clearinghouse.getAccountAssetBuckets(ALICE))), bucketsBefore);
        assertEq(clearinghouse.balanceAssets(EXECUTION_KEEPER), keeperBefore, "no cleaner payout");
        assertEq(clearinghouse.balanceAssets(TRIGGER_KEEPER), triggerKeeperBefore, "trigger paid only once");
        assertFalse(router.lifecycleBook().isProtectionAttempt(attemptId), "terminal lifecycle marker cleared");
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(router.pendingCloseSize(ALICE), 0);
        assertEq(router.accountHeadOrderId(ALICE), 0);
        PositionProtectionTypes.PositionProtectionView memory latched =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(latched.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
            "surviving position retains retry"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId);
        assertEq(latched.triggerMarkPrice, triggerPrice, "trigger mandate retained");
        assertEq(keccak256(abi.encode(protectionViews.closeFinancialLimits(protectionId))), limitsBefore);
        IMarginClearinghouse.BountyReservation memory oldRecord =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, attemptId);
        if (anomaly >= 3) {
            assertEq(uint8(oldRecord.state), uint8(IMarginClearinghouse.BountyReservationState.Quarantined));
        }
        if (anomaly == 2) {
            assertEq(oldRecord.account, address(0xBAD), "foreign ownership remains intact");
        }
        bytes32 oldRecordHash = keccak256(abi.encode(oldRecord));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotPending.selector);
        router.expireOrder(attemptId);

        _assertProtectionRetryCloses(protectionId, attemptId, triggerPrice, oldRecordHash);
    }

    function _assertProtectionRetryCloses(
        uint64 protectionId,
        uint64 attemptId,
        uint256 triggerPrice,
        bytes32 oldRecordHash
    ) internal {
        vm.prank(CAROL);
        uint64 retryId = protectionActions.retryPositionProtectionClose(protectionId);
        assertGt(retryId, attemptId, "fresh child identity");
        assertEq(
            keccak256(abi.encode(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, attemptId))),
            oldRecordHash,
            "retry does not rewrite disputed old record"
        );
        assertEq(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, retryId).amountAssets, 0);
        vm.prank(address(router));
        protectionBook.afterOrderTerminal(attemptId, ALICE, IOrderRouterAccounting.OrderStatus.Failed);
        assertEq(
            protectionViews.getPositionProtection(protectionId).linkedOrderId,
            retryId,
            "stale callback cannot remove retry"
        );
        bytes[] memory retryData = _mockPythUpdateData(triggerPrice);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(retryId, retryData);
        assertEq(
            uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "retry can close unchanged position"
        );
        (uint256 remaining,,,,,,) = engine.positions(ALICE);
        assertEq(remaining, 0);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Executed)
        );
    }

    function testFuzz_MismatchedProtectionExpiry_ChangedPositionStillFails(
        uint8 changeSeed
    ) public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 attemptId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 change = bound(changeSeed, 0, 2);
        // Model an out-of-band size/side change through the trusted Engine test helper.
        _close(ALICE, CfdTypes.Side.LONG, change == 0 ? POSITION_SIZE / 2 : POSITION_SIZE, LONG_TAKE_PROFIT);
        if (change == 2) {
            _open(ALICE, CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_TAKE_PROFIT);
        }
        _damageProtectionAttemptReservation(attemptId, 0);
        vm.warp(uint256(router.lifecycleBook().orderTiming(attemptId).executionDeadline) + 1);
        router.expireOrder(attemptId);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed)
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0);
        assertEq(router.pendingOrderCounts(ALICE), 0);
        assertEq(router.pendingCloseSize(ALICE), 0);
        assertEq(
            uint8(_verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), attemptId).reason),
            uint8(OrderV3Types.TerminalReason.ExpiredReservationMismatch)
        );
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotFound.selector);
        protectionActions.retryPositionProtectionClose(protectionId);
    }

    function test_MismatchedProtectionExpiry_ReceiptFailureRollsBackRelatchAndCleanup() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 attemptId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _damageProtectionAttemptReservation(attemptId, 3);
        vm.warp(uint256(router.lifecycleBook().orderTiming(attemptId).executionDeadline) + 1);
        bytes32 beforeState = _protectionRecoveryStateHash(protectionId, attemptId);
        vm.mockCallRevert(
            address(router.lifecycleBook()),
            abi.encodeWithSelector(IOrderLifecycleBook.finalize.selector),
            bytes("forced receipt failure")
        );
        vm.expectRevert(bytes("forced receipt failure"));
        router.expireOrder(attemptId);
        vm.clearMockedCalls();
        assertEq(
            _protectionRecoveryStateHash(protectionId, attemptId),
            beforeState,
            "receipt failure restores all lifecycle and accounting state"
        );
        assertTrue(router.lifecycleBook().isProtectionAttempt(attemptId));
        router.expireOrder(attemptId);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Latched)
        );
        _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), attemptId);
    }

    function _protectionRecoveryStateHash(
        uint64 protectionId,
        uint64 attemptId
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                protectionViews.getPositionProtection(protectionId),
                protectionViews.activePositionProtectionId(ALICE),
                _orderRecord(attemptId),
                router.lifecycleBook().pendingIntent(attemptId),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, attemptId),
                clearinghouse.getAccountAssetBuckets(ALICE),
                router.pendingOrderCounts(ALICE),
                router.pendingCloseSize(ALICE),
                router.nextExecuteId(),
                router.accountHeadOrderId(ALICE),
                router.globalTailOrderId()
            )
        );
    }

    // Synthetic corruption tests recovery behavior; these fixtures do not imply public callers can corrupt the ledger.
    function _damageProtectionAttemptReservation(
        uint64 attemptId,
        uint8 anomaly
    ) internal {
        vm.record();
        clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, attemptId);
        (bytes32[] memory slots,) = vm.accesses(address(clearinghouse));
        if (anomaly == 0) {
            vm.prank(address(router));
            clearinghouse.takeBountyReservation(ALICE, IMarginClearinghouse.BountyKind.Order, attemptId);
        } else if (anomaly == 1) {
            vm.store(address(clearinghouse), slots[0], bytes32(0));
            vm.store(address(clearinghouse), bytes32(uint256(slots[0]) + 1), bytes32(0));
        } else if (anomaly == 2) {
            uint256 word = uint256(vm.load(address(clearinghouse), slots[0]));
            vm.store(
                address(clearinghouse),
                slots[0],
                bytes32((word & ~uint256(type(uint160).max)) | uint160(address(0xBAD)))
            );
        } else if (anomaly == 3) {
            bytes32 fundingSlot = bytes32(uint256(slots[0]) + 1);
            vm.store(
                address(clearinghouse),
                fundingSlot,
                bytes32(uint256(vm.load(address(clearinghouse), fundingSlot)) + (uint256(1) << 8))
            );
        } else if (anomaly == 4) {
            vm.record();
            router.lifecycleBook().pendingIntent(attemptId);
            (bytes32[] memory intentSlots,) = vm.accesses(address(router.lifecycleBook()));
            vm.store(address(router.lifecycleBook()), bytes32(uint256(intentSlots[0]) + 3), bytes32(uint256(1)));
        } else {
            vm.store(
                address(clearinghouse),
                slots[0],
                bytes32(uint256(vm.load(address(clearinghouse), slots[0])) + (uint256(1) << 160))
            );
        }
    }

    function test_FailedProtectionAttempt_PositionMismatchFailsAndPaysCleanerExactlyOnce() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyAssets = 0;

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
        uint256 poolDepthAssets = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(outOfBandPartialClose, MARK_PRICE, poolDepthAssets, uint64(block.timestamp));
        (uint256 mismatchedSize,,,,,,) = engine.positions(ALICE);
        assertEq(mismatchedSize, POSITION_SIZE - 100e18, "fixture should change the protected position size");

        uint256 cleanerBalanceBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        _expireProtectionAttempt(linkedOrderId, EXECUTION_KEEPER);

        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "mismatched position should terminally fail protection"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "terminal mismatch should clear active id");
        assertEq(
            clearinghouse.balanceAssets(EXECUTION_KEEPER) - cleanerBalanceBefore,
            executionBountyAssets,
            "mismatch cleaner should receive the child bounty exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "mismatch should clear reserve view");
        assertEq(clearinghouse.actionReserveAssets(ALICE), 0, "mismatch payout should consume the action reserve");

        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), linkedOrderId);
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Expired), "mismatch receipt reason");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None), "paid receipt");
        assertEq(outcome.bountyRecipient, address(0), "cleaner receipt recipient");
        assertEq(outcome.bountyAssets, executionBountyAssets, "cleaner receipt bounty");
        assertFalse(router.lifecycleBook().isProtectionAttempt(linkedOrderId), "mismatch should clear attempt marker");
    }

    function test_RetryPositionProtectionClose_StaysZeroBountyAfterTriggerConfigChangeWithoutFreshFunds() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        _withdrawAllFreeSettlement(ALICE);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 originalBountyAssets = 0;
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        uint256 actionReserveBefore = clearinghouse.actionReserveAssets(ALICE);
        assertEq(actionReserveBefore, originalBountyAssets, "expired close must retain no bounty reserve");
        assertEq(_freeSettlementAssets(ALICE), 0, "fixture should leave no fresh retry funding");

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionTriggerBountyAssets += 100_000;
        _setRouterConfig(config);

        vm.prank(CAROL);
        uint64 retryOrderId = protectionActions.retryPositionProtectionClose(protectionId);

        assertEq(
            _orderRecord(retryOrderId).executionBountyAssets,
            originalBountyAssets,
            "retry child must remain zero bounty"
        );
        assertEq(
            router.lifecycleBook().pendingIntent(retryOrderId).executionBountyAssets,
            originalBountyAssets,
            "lifecycle intent should authenticate zero bounty"
        );
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            originalBountyAssets,
            "trigger config change must not create an execution reserve"
        );
        assertEq(clearinghouse.actionReserveAssets(ALICE), actionReserveBefore, "retry should not alter reserve amount");
        assertEq(_freeSettlementAssets(ALICE), 0, "retry should not debit unavailable free settlement");
    }

    function test_Batch_ExpiredProtectionHeadRelatchesAndLaterOrderExecutes() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint64 linkedValidUntil = router.lifecycleBook().orderTiming(linkedOrderId).executionDeadline;

        vm.warp(block.timestamp + 30);
        vm.prank(BOB);
        uint64 bobOrderId = router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0, false);
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
        assertEq(latched.linkedOrderId, linkedOrderId, "batch cleanup should retain last attempt identity");
        OrderV3Types.CompactOutcome memory protectionOutcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), linkedOrderId);
        assertEq(
            uint8(protectionOutcome.bountyDisposition),
            uint8(OrderV3Types.BountyDisposition.None),
            "batch head receipt should retain bounty"
        );
        assertEq(
            uint8(_verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), bobOrderId).status),
            uint8(OrderV3Types.LifecycleStatus.Executed),
            "later target should execute in the same batch"
        );
        assertEq(router.nextExecuteId(), 0, "batch should advance beyond both orders");
        (uint256 bobSize,,,,,,) = engine.positions(BOB);
        assertEq(bobSize, POSITION_SIZE, "later account order should reach the Engine");
    }

    function test_RepeatedProtectionAttemptExpiryRetry_ConservesSingleBounty() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 attemptOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        uint256 executionBountyAssets = 0;
        uint256 freeSettlementBefore = _freeSettlementAssets(ALICE);
        uint256 actionReserveBefore = clearinghouse.actionReserveAssets(ALICE);

        for (uint256 i; i < 2; ++i) {
            uint256 cleanerBalanceBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
            _expireProtectionAttempt(attemptOrderId, EXECUTION_KEEPER);

            PositionProtectionTypes.PositionProtectionView memory latched =
                protectionViews.getPositionProtection(protectionId);
            assertEq(
                uint8(latched.status),
                uint8(PositionProtectionTypes.PositionProtectionStatus.Latched),
                "each expiry should return to the durable latch"
            );
            assertEq(
                clearinghouse.balanceAssets(EXECUTION_KEEPER),
                cleanerBalanceBefore,
                "expiry cleaner should remain unpaid on every cycle"
            );
            assertEq(_freeSettlementAssets(ALICE), freeSettlementBefore, "cycles must not change free settlement");
            assertEq(
                clearinghouse.actionReserveAssets(ALICE),
                actionReserveBefore,
                "cycles must not duplicate or consume reserved settlement"
            );
            assertEq(
                router.getAccountReservations(ALICE).executionBountyAssets,
                executionBountyAssets,
                "exactly one execution bounty should remain reserved"
            );

            uint64 previousOrderId = attemptOrderId;
            vm.prank(CAROL);
            attemptOrderId = protectionActions.retryPositionProtectionClose(protectionId);
            assertGt(attemptOrderId, previousOrderId, "each attempt should receive a new id");
            assertEq(
                _orderRecord(attemptOrderId).executionBountyAssets,
                executionBountyAssets,
                "new child should own the same single bounty"
            );
            assertEq(
                protectionViews.getPositionProtection(protectionId).linkedOrderId,
                attemptOrderId,
                "Book must track only the newest live attempt"
            );
        }
    }

    function test_RetryPositionProtectionClose_RemainsAvailableAcrossSafetyModes() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 firstOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expireProtectionAttempt(firstOrderId, EXECUTION_KEEPER);

        vm.warp(FRIDAY_FAD_START - 1);
        _refreshMark(MARK_PRICE);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        routerAdmin.pause();
        vm.warp(FRIDAY_FAD_START + 3 hours);

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

        uint256 executionBountyAssets = 0;
        uint256 executorBalanceBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(MARK_PRICE)), 0, int32(-8), uint64(block.timestamp));
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(retryOrderId, _priceData(MARK_PRICE));

        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), retryOrderId);
        assertEq(uint8(outcome.executionMode), uint8(OrderV3Types.ExecutionMode.Frozen), "frozen execution mode");
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None), "frozen payout");
        assertEq(outcome.bountyRecipient, address(0), "frozen executor should receive bounty");
        assertEq(
            clearinghouse.balanceAssets(EXECUTION_KEEPER) - executorBalanceBefore,
            executionBountyAssets,
            "frozen retry should pay exactly once"
        );
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "frozen success clears reserve");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "frozen success clears marker");
    }

    function test_CancelPositionProtection_RefundsExactReserveAndClearsTradeLock() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        uint256 freeBefore = _freeSettlementAssets(ALICE);

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementAssets(ALICE), freeBefore - _totalProtectionBountyAssets(), "reserve after create");

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(protectionId);

        PositionProtectionTypes.PositionProtectionView memory cancelled =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(cancelled.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Cancelled),
            "cancelled lifecycle"
        );
        assertEq(cancelled.triggerBountyAssets, 0, "cancel should clear trigger bounty ownership");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "cancel should clear active id");
        assertEq(_freeSettlementAssets(ALICE), freeBefore, "cancel should refund exact reserve");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "reservation view after cancel");
    }

    function test_CancelAndCommitClose_LongLiveExecutes() public {
        _assertCancelAndCommitCloseExecutes(CfdTypes.Side.LONG, false);
    }

    function test_CancelAndCommitClose_ShortLiveExecutes() public {
        _assertCancelAndCommitCloseExecutes(CfdTypes.Side.SHORT, false);
    }

    function test_CancelAndCommitClose_LongFrozenUsesAllowedStaleQuote() public {
        _assertCancelAndCommitCloseExecutes(CfdTypes.Side.LONG, true);
    }

    function test_CancelAndCommitClose_ShortFrozenUsesAllowedStaleQuote() public {
        _assertCancelAndCommitCloseExecutes(CfdTypes.Side.SHORT, true);
    }

    function test_CancelAndCommitClose_HostRejectsDirectSidecarAndForeignDelegateCalls() public {
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        bytes memory callData = abi.encodeCall(router.commitProtectedClose, (ALICE, request, uint256(0)));
        bytes memory unauthorized = abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        address sidecar = router.liquidationBatchSidecar();
        (bool directSuccess, bytes memory directRevert) = sidecar.call(callData);
        assertFalse(directSuccess, "direct sidecar call forbidden");
        assertEq(directRevert, unauthorized, "direct sidecar caller must fail binding");
        (bool foreignSuccess, bytes memory foreignRevert) = sidecar.delegatecall(callData);
        assertFalse(foreignSuccess, "foreign delegatecall forbidden");
        assertEq(foreignRevert, unauthorized, "foreign delegate context must fail binding");
    }

    function test_CancelAndCommitClose_PreservesBoundedIntentAndFifo() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.prank(BOB);
        router.commitOrder(CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0, false);
        uint64 head = router.nextExecuteId();
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.targetPrice = 105_000_000;
        request.bounds.allowedExecutionModes = 1;
        request.bounds.executionWindowSeconds = 37;
        request.bounds.maxExecutionBountyAssets = 0;
        request.bounds.maxExecutionNotionalAssets = 12_345e6;
        request.bounds.maxGrossAccountDebitAssets = 678e6;
        request.bounds.maxActionChargeAssets = 123e6;
        request.bounds.maxExplicitFeesAssets = 45e6;
        request.bounds.maxPostPositionSize = 0;
        request.bounds.minPostPositionEquityAssets = 19e6;
        request.bounds.maxPostLeverageBps = 1;
        uint64 nextBefore = router.nextCommitId();
        uint256 refund = protectionViews.getPositionProtection(protectionId).triggerBountyAssets;
        uint256 freeBefore = _freeSettlementAssets(ALICE);
        uint256 keeperBefore = clearinghouse.balanceAssets(TRIGGER_KEEPER);

        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);

        assertEq(orderId, nextBefore, "fresh ordinary order id");
        assertEq(router.nextCommitId(), nextBefore + 1, "one new id");
        assertEq(router.nextExecuteId(), head, "foreign FIFO head retained");
        assertEq(router.globalTailOrderId(), orderId, "manual close joins FIFO tail");
        assertEq(_orderRecord(head).nextGlobalOrderId, orderId, "head links to close");
        assertEq(_orderRecord(orderId).prevGlobalOrderId, head, "close links to head");
        OrderV3Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(orderId);
        assertEq(pending.account, ALICE, "caller account retained");
        assertEq(pending.clientOrderId, request.clientOrderId, "public client id retained");
        assertEq(pending.intentHash, router.lifecycleBook().hashOrderRequest(ALICE, request), "request hash retained");
        assertEq(keccak256(abi.encode(pending.bounds)), keccak256(abi.encode(request.bounds)), "all bounds retained");
        assertEq(router.lifecycleBook().clientIntent(ALICE, request.clientOrderId).orderId, orderId, "client id bound");
        CfdTypes.Order memory order = _orderRecord(orderId).core;
        assertEq(order.targetPrice, request.targetPrice, "target retained");
        assertEq(order.sizeDelta, POSITION_SIZE, "full size retained");
        assertEq(order.marginDelta, 0, "close has no margin delta");
        assertTrue(order.isClose, "ordinary reduce-only close");
        assertFalse(router.lifecycleBook().isProtectionAttempt(orderId), "manual close has no trigger-attempt marker");
        assertEq(router.pendingOrderCounts(ALICE), 1, "exactly one close");
        assertEq(router.pendingCloseSize(ALICE), POSITION_SIZE, "full close reserved");
        assertEq(_freeSettlementAssets(ALICE), freeBefore + refund, "trigger reserve refunded");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "zero-bounty close");
        assertEq(clearinghouse.balanceAssets(TRIGGER_KEEPER), keeperBefore, "manual exit pays no trigger bounty");
        _assertManualExitProtectionCancelled(protectionId);

        bytes[] memory updateData = _mockPythUpdateData(95_000_000);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector);
        router.executeOrder(orderId, updateData);
    }

    function test_CancelAndCommitClose_RejectsUnauthorizedAndMalformedPositionRequest() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);

        request.isClose = false;
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__NotCloseOrder.selector)
        );
        request.isClose = true;
        request.side = CfdTypes.Side.SHORT;
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = POSITION_SIZE / 2;
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
        request.sizeDelta = POSITION_SIZE + 100e18;
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
        request.sizeDelta = POSITION_SIZE;
        request.marginDelta = 1;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__CloseWithPositiveMargin.selector)
        );
    }

    function test_CancelAndCommitClose_RejectsChangedOrMissingLivePosition() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        _close(ALICE, CfdTypes.Side.LONG, POSITION_SIZE / 2, MARK_PRICE);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
        _close(ALICE, CfdTypes.Side.LONG, POSITION_SIZE / 2, MARK_PRICE);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
        _open(ALICE, CfdTypes.Side.SHORT, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PositionChanged.selector)
        );
    }

    function test_CancelAndCommitClose_RejectsPendingOrdersWithoutMutation() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        vm.mockCall(
            address(router), abi.encodeWithSignature("pendingOrderCounts(address)", ALICE), abi.encode(uint256(1))
        );
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PendingOrdersExist.selector)
        );
        vm.clearMockedCalls();
    }

    function test_CancelAndCommitClose_RejectsPendingOpenTriggeredLatchedAndCancelled() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory openRequest =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        vm.prank(ALICE);
        (uint64 parentId, uint64 pendingId) =
            protectionActions.commitOpenOrderWithProtection(openRequest, _params(LONG_TAKE_PROFIT, 0));
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        _expectCancelAndCommitCloseRevert(
            pendingId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ProtectionNotArmed.selector)
        );
        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(pendingId);
        _expectCancelAndCommitCloseRevert(
            pendingId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ProtectionNotFound.selector)
        );
        bytes[] memory openData = _mockPythUpdateData(MARK_PRICE);
        router.executeOrder(parentId, openData);
        _refreshMark(MARK_PRICE);
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));
        uint64 attemptId = _triggerAt(protectionId, LONG_TAKE_PROFIT);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ProtectionNotArmed.selector)
        );
        _expireProtectionAttempt(attemptId, EXECUTION_KEEPER);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ProtectionNotArmed.selector)
        );
    }

    function test_CancelAndCommitClose_InvalidCommitRollsBackCancellationAndRefund() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        bytes32 configHash = request.bounds.expectedConfigHash;
        request.bounds.expectedConfigHash = bytes32(0);
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__ExecutionConfigMismatch.selector, bytes32(0), configHash
            )
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.targetPrice = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroTargetPrice.selector)
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.clientOrderId = bytes32(0);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroClientOrderId.selector)
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.allowedExecutionModes = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__InvalidExecutionModeMask.selector)
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.submitBy = uint64(block.timestamp - 1);
        _expectCancelAndCommitCloseRevert(
            protectionId, request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__InvalidSubmitBy.selector)
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.executionWindowSeconds = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__InvalidExecutionWindow.selector)
        );
        request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.maxPostLeverageBps = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroPostLeverageBound.selector)
        );
    }

    function test_CancelAndCommitClose_StaleConfigRollsBackCancellationAndRefund() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        bytes32 previousConfig = router.lifecycleBook().currentExecutionConfigHash();
        _setRouterConfig(_routerConfig());
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        bytes32 currentConfig = request.bounds.expectedConfigHash;
        assertTrue(previousConfig != currentConfig, "configuration must have changed");
        request.bounds.expectedConfigHash = previousConfig;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__ExecutionConfigMismatch.selector, previousConfig, currentConfig
            )
        );
    }

    function test_CancelAndCommitClose_HistoricalReplayAndConflictRollBackCancellation() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        OrderV3Types.OrderRequest memory historical = _manualCloseRequest(CfdTypes.Side.LONG);
        historical.targetPrice = 1;
        vm.prank(ALICE);
        uint64 historicalId = router.commitOrder(historical);
        bytes[] memory executionData = _mockPythUpdateData(95_000_000);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(historicalId, executionData);
        assertEq(
            uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Slippage), "historical close must fail"
        );
        _refreshMark(95_000_000);
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, 0));

        _expectCancelAndCommitCloseRevert(
            protectionId,
            historical,
            abi.encodeWithSelector(PositionProtectionBook.PositionProtectionBook__InvalidHostResponse.selector)
        );
        bytes32 originalHash = router.lifecycleBook().hashOrderRequest(ALICE, historical);
        historical.bounds.maxExplicitFeesAssets -= 1;
        bytes32 conflictHash = router.lifecycleBook().hashOrderRequest(ALICE, historical);
        _expectCancelAndCommitCloseRevert(
            protectionId,
            historical,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
                ALICE,
                historical.clientOrderId,
                originalHash,
                conflictHash
            )
        );
        assertEq(
            router.lifecycleBook().clientIntent(ALICE, historical.clientOrderId).orderId,
            historicalId,
            "historical identity retained"
        );
    }

    function test_CancelAndCommitClose_AccruedCarryCannotBypassGrossDebitBound() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.warp(block.timestamp + 1 hours);
        uint256 carry = _expectedIndexedCarryAssets(ALICE);
        assertGt(carry, 0, "fixture must accrue carry before cancellation");
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.maxGrossAccountDebitAssets = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector,
                OrderV3Types.ConstraintKind.GrossAccountDebit,
                carry,
                uint256(0)
            )
        );
        assertEq(_expectedIndexedCarryAssets(ALICE), carry, "rejected close must not checkpoint accrued carry");
    }

    function test_CancelAndCommitClose_AccruedCarryCannotBypassActionChargeBound() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.warp(block.timestamp + 1 hours);
        uint256 carry = _expectedIndexedCarryAssets(ALICE);
        assertGt(carry, 0, "fixture must accrue carry before cancellation");
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.maxActionChargeAssets = 0;
        _expectCancelAndCommitCloseRevert(
            protectionId,
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector,
                OrderV3Types.ConstraintKind.ActionCharge,
                carry,
                uint256(0)
            )
        );
        assertEq(_expectedIndexedCarryAssets(ALICE), carry, "rejected close must not checkpoint accrued carry");
    }

    function test_CancelAndCommitClose_ExactCarryBoundsRetainCommitmentAndTerminalReceipt() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.warp(block.timestamp + 1 hours);
        uint256 carry = _expectedIndexedCarryAssets(ALICE);
        uint256 settlementBefore = clearinghouse.balanceAssets(ALICE);
        assertGt(carry, 0, "fixture must accrue carry before cancellation");
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.maxGrossAccountDebitAssets = carry;
        request.bounds.maxActionChargeAssets = carry;
        request.bounds.executionWindowSeconds = 1;
        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        CfdEnginePlanTypes.CloseCommitment memory commitment = router.lifecycleBook().pendingIntent(orderId).commitment;
        assertEq(commitment.carryCollectedAssets, carry, "full cancellation-time carry included in bounded commitment");
        assertEq(commitment.carryOutstandingAssets, 0, "funded carry fully collected");
        assertEq(commitment.settlementBeforeAssets, settlementBefore, "commitment starts before carry debit");
        assertEq(commitment.settlementAfterAssets, settlementBefore - carry, "commitment records full carry debit");
        assertEq(clearinghouse.balanceAssets(ALICE), settlementBefore - carry, "carry debited once");
        assertEq(_expectedIndexedCarryAssets(ALICE), 0, "commitment checkpoints carry");
        _assertManualExitProtectionCancelled(protectionId);

        OrderV3Types.ExecutionResult memory result = _expireProtectionAttempt(orderId, EXECUTION_KEEPER);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired), "close expires ordinarily");
        OrderV3Types.OrderReceipt memory receipt =
            _verifiedReceipt(IOrderLifecycleBook(address(router.lifecycleBook())), orderId);
        assertEq(
            keccak256(abi.encode(receipt.commitment)),
            keccak256(abi.encode(commitment)),
            "authenticated terminal receipt retains bounded carry effects"
        );
        assertEq(clearinghouse.balanceAssets(ALICE), settlementBefore - carry, "expiry does not charge carry again");
        _assertManualExitProtectionCancelled(protectionId);
    }

    function test_CancelAndCommitClose_FinancialFailureDoesNotRearmProtection() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.maxExecutionNotionalAssets = 0;
        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        bytes[] memory updateData = _mockPythUpdateData(95_000_000);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "bounded close fails");
        assertEq(
            uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.ConstraintViolation), "bound is enforced"
        );
        assertEq(
            uint8(_verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), orderId).failedConstraint),
            uint8(OrderV3Types.ConstraintKind.ExecutionNotional),
            "notional ceiling enforced"
        );
        _assertManualExitProtectionCancelled(protectionId);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, POSITION_SIZE, "failed close preserves position");
        assertEq(router.pendingOrderCounts(ALICE), 0, "failed close leaves queue");
    }

    function test_CancelAndCommitClose_FrozenExecutionHonorsModeMask() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.warp(FRIDAY_FAD_START - 1);
        _refreshMark(95_000_000);
        vm.warp(FRIDAY_FAD_START + 3 hours);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.allowedExecutionModes = 1;
        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        bytes[] memory updateData = _mockPythUpdateData(95_000_000);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV3Types.TerminalReason.ExecutionModeDisallowed),
            "frozen must remain disallowed by caller"
        );
        _assertManualExitProtectionCancelled(protectionId);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, POSITION_SIZE, "mode rejection preserves position");
    }

    function test_CancelAndCommitClose_ExpiryDoesNotRearmOrPermitProtectionRetry() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(CfdTypes.Side.LONG);
        request.bounds.executionWindowSeconds = 1;
        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        OrderV3Types.ExecutionResult memory result = _expireProtectionAttempt(orderId, EXECUTION_KEEPER);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired), "ordinary close expires");
        _assertManualExitProtectionCancelled(protectionId);
        assertEq(router.pendingOrderCounts(ALICE), 0, "expired close leaves queue");
        assertEq(router.pendingCloseSize(ALICE), 0, "expired size released");
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionNotFound.selector);
        protectionActions.retryPositionProtectionClose(protectionId);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, POSITION_SIZE, "expiry preserves position");
    }

    function test_PostLockRisk_RejectsInitialMarginEqualityAndAcceptsOneMicroAssetsAboveBoundary() public {
        _assertInitialMarginBoundary(false);
    }

    function test_PostLockRisk_DegradedRetainsInitialMarginBoundary() public {
        _assertInitialMarginBoundary(true);
    }

    function _assertInitialMarginBoundary(
        bool degraded
    ) internal {
        _startRecordingLogs();
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);
        RiskBoundaryFixture memory fixture = _postMarkInitialMarginBoundaryFixture(riskParams);

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaAssets + fixture.protectionBountiesAssets);
        _fundTrader(RISK_PLUS_ONE, fixture.plusOneOpeningMarginDeltaAssets + fixture.protectionBountiesAssets);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaAssets, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.LONG, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaAssets, MARK_PRICE);
        _refreshMark(POST_MARK_PRICE);
        assertEq(engine.lastMarkPrice(), POST_MARK_PRICE, "adverse basket mark installed");

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(degraded);

        assertEq(
            clearinghouse.pnlPledgeAssets(RISK_EXACT) - (POSITION_SIZE / CfdTypes.SIZE_QUANTUM)
                * (POST_MARK_PRICE - MARK_PRICE),
            fixture.requirementAssets,
            "exact marked equity boundary"
        );
        assertEq(
            clearinghouse.pnlPledgeAssets(RISK_PLUS_ONE) - (POSITION_SIZE / CfdTypes.SIZE_QUANTUM)
                * (POST_MARK_PRICE - MARK_PRICE),
            fixture.requirementAssets + 1,
            "one-atom marked equity surplus"
        );

        uint256 exactFreeBefore = _freeSettlementAssets(RISK_EXACT);
        assertEq(
            exactFreeBefore,
            fixture.protectionBountiesAssets,
            "exact account should fund both bounties from free settlement"
        );
        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementAssets(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");
        assertEq(protectionViews.activePositionProtectionId(RISK_EXACT), 0, "risk failure must not create protection");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one micro-settlementToken above the inclusive initial-margin boundary should arm"
        );
    }

    function test_PostLockRisk_FreeSettlementCannotCureExactPriceRisk() public {
        _startRecordingLogs();
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);
        RiskBoundaryFixture memory fixture = _postMarkInitialMarginBoundaryFixture(riskParams);
        uint256 surplusFreeSettlementAssets = 5000e6;

        _fundTrader(
            RISK_EXACT,
            fixture.exactOpeningMarginDeltaAssets + fixture.protectionBountiesAssets + surplusFreeSettlementAssets
        );
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaAssets, MARK_PRICE);
        _refreshMark(POST_MARK_PRICE);
        assertEq(engine.lastMarkPrice(), POST_MARK_PRICE, "adverse basket mark installed");

        assertEq(
            clearinghouse.pnlPledgeAssets(RISK_EXACT) - (POSITION_SIZE / CfdTypes.SIZE_QUANTUM)
                * (POST_MARK_PRICE - MARK_PRICE),
            fixture.requirementAssets,
            "price equity at equality"
        );
        assertEq(
            _freeSettlementAssets(RISK_EXACT),
            fixture.protectionBountiesAssets + surplusFreeSettlementAssets,
            "fixture must have abundant generic free settlement"
        );

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            _freeSettlementAssets(RISK_EXACT),
            fixture.protectionBountiesAssets + surplusFreeSettlementAssets,
            "failed protection must roll back the temporary bounty lock"
        );
        assertEq(protectionViews.activePositionProtectionId(RISK_EXACT), 0, "free cash must not create price backing");
    }

    function test_PostLockRisk_SameAccountClaimProvidesOneAtomOfExactPriceCollateral() public {
        _startRecordingLogs();
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);
        RiskBoundaryFixture memory fixture = _postMarkInitialMarginBoundaryFixture(riskParams);

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaAssets + fixture.protectionBountiesAssets);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaAssets, MARK_PRICE);
        _refreshMark(POST_MARK_PRICE);
        assertEq(engine.lastMarkPrice(), POST_MARK_PRICE, "adverse basket mark installed");
        assertEq(
            clearinghouse.pnlPledgeAssets(RISK_EXACT) - (POSITION_SIZE / CfdTypes.SIZE_QUANTUM)
                * (POST_MARK_PRICE - MARK_PRICE),
            fixture.requirementAssets,
            "marked equity starts at equality"
        );

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        _seedAuthenticatedTraderClaim(RISK_EXACT, 1);
        vm.prank(RISK_EXACT);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(engine.traderClaimBalanceAssets(RISK_EXACT), 1, "fixture must add one same-account claim atom");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one claim atom above equality should arm"
        );
    }

    function test_PostLockRisk_UsesStricterFadBoundary() public {
        _startRecordingLogs();
        CfdTypes.RiskParams memory riskParams = _riskParams();
        riskParams.baseCarryBps = 0;
        _setRiskParams(riskParams);

        RiskBoundaryFixture memory fixture = _riskBoundaryFixture(riskParams, riskParams.fadMarginBps);
        assertGt(
            fixture.requirementAssets,
            ((POSITION_SIZE * MARK_PRICE) / 1e20) * riskParams.initMarginBps / 10_000,
            "fixture requires FAD to be stricter than initial"
        );

        vm.warp(FRIDAY_FAD_START - 2);
        _mockPythUpdateData(MARK_PRICE);
        router.updateMarkPrice(_livePriceData(MARK_PRICE));
        assertFalse(engine.isFadWindow(), "positions should open immediately before the FAD boundary");

        _fundTrader(RISK_EXACT, fixture.exactOpeningMarginDeltaAssets + fixture.protectionBountiesAssets);
        _fundTrader(RISK_PLUS_ONE, fixture.plusOneOpeningMarginDeltaAssets + fixture.protectionBountiesAssets);
        _open(RISK_EXACT, CfdTypes.Side.LONG, POSITION_SIZE, fixture.exactOpeningMarginDeltaAssets, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.LONG, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaAssets, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeAssets(RISK_EXACT), fixture.requirementAssets, "exact FAD pledge boundary");
        assertEq(
            clearinghouse.pnlPledgeAssets(RISK_PLUS_ONE), fixture.requirementAssets + 1, "one-atom FAD pledge surplus"
        );

        vm.warp(FRIDAY_FAD_START);
        _mockPythUpdateData(MARK_PRICE);
        router.updateMarkPrice(_livePriceData(MARK_PRICE));
        assertTrue(engine.isFadWindow(), "post-lock risk should use the stricter FAD requirement");

        uint256 exactFreeBefore = _freeSettlementAssets(RISK_EXACT);
        assertGe(exactFreeBefore, fixture.protectionBountiesAssets, "exact-boundary account can fund the bounty itself");
        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(_freeSettlementAssets(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "one micro-settlementToken above the inclusive risk boundary should arm"
        );
    }

    function test_PostLockRisk_RejectsUnderfundedNegativeVpiReserveIndependently() public {
        _startRecordingLogs();
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

        uint256 reserveTargetAssets = uint256(-(vpiAccrued + 1)) + 1;
        assertEq(clearinghouse.vpiRebateReserveAssets(BOB), reserveTargetAssets, "reserve starts exactly funded");
        vm.prank(address(engine));
        clearinghouse.releaseVpiRebateReserve(BOB, 1);

        uint256 freeBefore = _freeSettlementAssets(BOB);
        _refreshMark(MARK_PRICE);
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            clearinghouse.vpiRebateReserveAssets(BOB),
            reserveTargetAssets - 1,
            "failed action must not repair VPI backing"
        );
        assertEq(_freeSettlementAssets(BOB), freeBefore, "failed action must roll back its bounty lock");
        assertEq(protectionViews.activePositionProtectionId(BOB), 0, "VPI delinquency must fail closed");
    }

    function test_PostLockRisk_RejectsCarryLeftUncoveredByLockCheckpoint() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);
        _withdrawAllFreeSettlement(ALICE);

        stdstore.target(address(router)).sig("positionProtectionTriggerBountyAssets()").checked_write(uint256(0));

        // An exact number of weeks preserves the fixture's live oracle window.
        vm.warp(block.timestamp + 1001 * 365 days);
        _refreshMark(MARK_PRICE);
        assertGt(
            _expectedIndexedCarryAssets(ALICE),
            clearinghouse.pnlPledgeAssets(ALICE),
            "fixture must exhaust both position margin and free settlement"
        );

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(
            engine.unsettledCarryAssets(ALICE),
            0,
            "risk failure must roll back the lock-time carry checkpoint with the rest of the action"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "uncovered carry must fail closed");
    }

    function test_Pause_BlocksNewAndReplacementButAllowsCancelAndTrigger() public {
        _startRecordingLogs();
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_TAKE_PROFIT, LONG_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_TAKE_PROFIT, 0);

        routerAdmin.pause();

        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(LONG_TAKE_PROFIT - 1, 0));

        OrderV3Types.OrderRequest memory pausedRequest =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
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

    function test_DefaultDeployment_AllowsProtectionWithoutRouterConfigProposal() public {
        _startRecordingLogs();
        assertEq(routerAdmin.activeConfigVersion(), 1, "fresh Router must use its constructor configuration");
        assertEq(routerAdmin.routerConfigActivationTime(), 0, "protection must not require an activation proposal");
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_TAKE_PROFIT, LONG_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_TAKE_PROFIT, 0);

        vm.prank(ALICE);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(LONG_TAKE_PROFIT - 1, 0));
        assertEq(
            protectionViews.getPositionProtection(cancelledProtectionId).takeProfitTriggerPrice,
            LONG_TAKE_PROFIT - 1,
            "fresh deployment must allow replacement"
        );

        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        vm.prank(CAROL);
        (, uint64 attachedProtectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
        assertEq(
            uint8(protectionViews.getPositionProtection(attachedProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "fresh deployment must allow attached protection"
        );

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(cancelledProtectionId);
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "cancellation must clear protection");

        uint64 linkedOrderId = _triggerAt(triggeredProtectionId, LONG_TAKE_PROFIT);
        assertEq(
            uint8(protectionViews.getPositionProtection(triggeredProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "fresh deployment must allow triggering"
        );
        assertEq(router.accountHeadOrderId(BOB), linkedOrderId, "trigger should append the close normally");
        assertEq(routerAdmin.activeConfigVersion(), 1, "protection must not change the Router configuration");
        assertEq(routerAdmin.routerConfigActivationTime(), 0, "no activation proposal should be pending");
    }

    function test_ReplacePositionProtection_RemainsAvailableInDegradedMode() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertTrue(engine.degradedMode(), "setup should enter degraded mode");

        PositionProtectionTypes.PositionProtectionParams memory replacementParams = _params(LONG_TAKE_PROFIT - 1, 0);
        replacementParams.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: 11_111e6,
            maxGrossAccountDebitAssets: 8888e6,
            maxActionChargeAssets: 777e6,
            maxExplicitFeesAssets: 66e6
        });
        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, replacementParams);
        _assertStoredCloseLimits(protectionId, replacementParams.closeLimits);

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
            replaced.triggerBountyAssets,
            _totalProtectionBountyAssets(),
            "replacement should retain the snapshotted reserve"
        );
    }

    function test_ReplacePositionProtection_UsesCurrentOracleAndResetsPublishBaseline() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        PositionProtectionTypes.PositionProtectionView memory beforeReplacement =
            protectionViews.getPositionProtection(protectionId);
        uint256 bountyBefore = router.getAccountReservations(ALICE).executionBountyAssets;

        vm.warp(block.timestamp + 1);
        vm.prank(address(router));
        IPletherOracle.PriceSnapshot memory current =
            pletherOracle.updatePrice(BOB, _priceData(94_000_000), IPletherOracle.PriceMode.MarkRefresh);
        assertEq(engine.lastMarkPrice(), MARK_PRICE, "engine mark must remain cached");

        vm.prank(ALICE);
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__OracleMarkAhead.selector);
        protectionActions.replacePositionProtection(protectionId, _params(95_000_000, 0));
        router.updateMarkPrice(new bytes[](0));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.replacePositionProtection(protectionId, _params(95_000_000, 0));
        PositionProtectionTypes.PositionProtectionView memory afterRevert =
            protectionViews.getPositionProtection(protectionId);
        assertEq(afterRevert.takeProfitTriggerPrice, beforeReplacement.takeProfitTriggerPrice, "threshold unchanged");
        assertEq(afterRevert.armedAt, beforeReplacement.armedAt, "failed replacement must not rearm");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, bountyBefore, "bounty unchanged");

        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, _params(93_000_000, 0));
        assertEq(protectionViews.getPositionProtection(protectionId).takeProfitTriggerPrice, 93_000_000);

        vm.roll(block.number + 1);
        baseMockPyth.setAllUniquePrices(_basePythFeedIds(), int64(94_000_000), 0, int32(-8), current.publishTime, 0);
        bytes[] memory samePublicationData = new bytes[](1);
        samePublicationData[0] = hex"01";
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TriggerPublishTimeNotAdvanced.selector);
        protectionActions.triggerPositionProtection(protectionId, samePublicationData);
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "nonadvancing publication must preserve armed protection"
        );
    }

    function test_ProtectionBook_NonTriggerActionsRejectEthAndNeverCustodyIt() public {
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(IPositionProtectionActions.createPositionProtection, (params));
        calls[1] = abi.encodeCall(IPositionProtectionActions.replacePositionProtection, (uint64(1), params));
        calls[2] = abi.encodeCall(IPositionProtectionActions.cancelPositionProtection, (uint64(1)));
        calls[3] = abi.encodeCall(IPositionProtectionActions.commitOpenOrderWithProtection, (request, params));
        calls[4] =
            abi.encodeCall(IPositionProtectionActions.cancelPositionProtectionAndCommitClose, (uint64(1), request));

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
        _startRecordingLogs();
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.activate(1, MARK_PRICE, uint64(block.timestamp), 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.afterOrderTerminal(1, ALICE, IOrderRouterAccounting.OrderStatus.Failed);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.handleFailedProtectionAttempt(1, ALICE, OrderV3Types.TerminalReason.Expired);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.failPendingOpenForRiskOff(1, ALICE);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.forfeitOnLiquidation(ALICE);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.commitProtectionCloseAttempt(1, ALICE, CfdTypes.Side.LONG, POSITION_SIZE);
    }

    function test_ProtectionBook_FailedAttemptHookValidatesAttemptAccountAndReason() public {
        _startRecordingLogs();

        vm.prank(address(router));
        assertFalse(
            protectionBook.handleFailedProtectionAttempt(404, ALICE, OrderV3Types.TerminalReason.Expired),
            "unknown attempts should be ignored"
        );

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        vm.prank(address(router));
        vm.expectRevert(IOrderRouterErrors.OrderRouter__PositionChanged.selector);
        protectionBook.handleFailedProtectionAttempt(linkedOrderId, BOB, OrderV3Types.TerminalReason.Expired);

        vm.prank(address(router));
        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__InvalidTerminalReason.selector);
        protectionBook.handleFailedProtectionAttempt(linkedOrderId, ALICE, OrderV3Types.TerminalReason.Executed);

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
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory protectedOpenRequest;
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.commitProtectedOpen(ALICE, protectedOpenRequest);

        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        router.commitProtectedClose(ALICE, protectedOpenRequest, 0);

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        _mockPythUpdateData(LONG_TAKE_PROFIT);
        bytes memory refreshCall =
            abi.encodeWithSelector(router.updateMarkPrice.selector, _livePriceData(LONG_TAKE_PROFIT));
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
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);
        _mockPythUpdateData(LONG_TAKE_PROFIT);
        bytes[] memory updateData = _livePriceData(LONG_TAKE_PROFIT);
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
        _startRecordingLogs();
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
        _startRecordingLogs();
        _createSingleLegProtection(CfdTypes.Side.LONG, LONG_TAKE_PROFIT, 0);

        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));
    }

    function test_Liquidation_ArmedProtectionForfeitsTriggerBountyAndTerminalizes() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _liquidateProtectedPositionAsKeeper();

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "armed protection should terminalize as liquidated"
        );
        assertEq(liquidated.triggerBountyAssets, 0, "liquidation should consume the unpaid trigger bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear active protection");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "no bounty reservation should remain");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            _totalProtectionBountyAssets(),
            "unpaid trigger bounty should be forfeited exactly once"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_TriggeredProtectionForfeitsLinkedCloseBountyExactlyOnce() public {
        _startRecordingLogs();
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.LONG, 0, LONG_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_STOP_LOSS);

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _liquidateProtectedPositionAsKeeper();

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
        assertEq(_orderRecord(linkedOrderId).executionBountyAssets, 0, "linked order bounty should be consumed");
        assertEq(router.pendingOrderCounts(ALICE), 0, "liquidation should unlink the generated close");
        assertEq(router.pendingCloseSize(ALICE), 0, "liquidation should clear generated close size");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "no bounty reservation should remain");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            0,
            "only the unpaid linked-close bounty should be forfeited at liquidation"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_LatchedProtectionHasNoCloseBountyToForfeit() public {
        _startRecordingLogs();
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
        assertEq(latched.linkedOrderId, linkedOrderId, "latch retains the last attempt identity");
        assertEq(router.pendingOrderCounts(ALICE), 0, "latched protection should have no live child");

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _liquidateProtectedPositionAsKeeper();

        PositionProtectionTypes.PositionProtectionView memory liquidated =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(liquidated.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Liquidated),
            "liquidation should terminalize the latch"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "liquidation should clear the trade lock");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "no bounty reserve should remain");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            0,
            "latched zero-bounty close must not credit the treasury"
        );
        OrderV3Types.CompactOutcome memory expiredOutcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), linkedOrderId);
        assertEq(
            uint8(expiredOutcome.bountyDisposition),
            uint8(OrderV3Types.BountyDisposition.None),
            "liquidation must not rewrite the prior attempt receipt"
        );
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "liquidation should remove the protected position");
    }

    function test_Liquidation_LiveRetriedChildCleansLatestLinkageAndBountyExactlyOnce() public {
        _startRecordingLogs();
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
        assertEq(_orderRecord(retryOrderId).executionBountyAssets, 0, "retry child must remain zero bounty");

        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        _liquidateProtectedPositionAsKeeper();

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
        assertEq(_orderRecord(retryOrderId).executionBountyAssets, 0, "latest child bounty should be consumed");
        assertEq(router.pendingOrderCounts(ALICE), 0, "latest child should be removed from account queue");
        assertEq(router.pendingCloseSize(ALICE), 0, "latest child should be removed from close aggregate");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "all bounty reserve should clear");
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            0,
            "liquidating a zero-bounty retry must not credit the treasury"
        );

        OrderV3Types.CompactOutcome memory retryOutcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), retryOrderId);
        assertEq(
            uint8(retryOutcome.reason),
            uint8(OrderV3Types.TerminalReason.AccountLiquidated),
            "latest child should receive liquidation terminal evidence"
        );
        assertEq(
            uint8(retryOutcome.bountyDisposition),
            uint8(OrderV3Types.BountyDisposition.None),
            "latest child receipt should authenticate forfeiture"
        );
        assertEq(retryOutcome.bountyRecipient, address(0), "unpaid liquidation has no bounty recipient");
        assertFalse(router.lifecycleBook().isProtectionAttempt(retryOrderId), "liquidation should clear attempt marker");
    }

    function test_AttachedOpen_InheritsSettlementBufferAdmissionAtCommit() public {
        _startRecordingLogs();
        uint256 size = 100_000e18;
        uint256 marginAssets = 5000e6;
        _open(BOB, CfdTypes.Side.SHORT, size, marginAssets, MARK_PRICE);

        uint256 maxLiabilityAssets = _maxLiability();
        uint256 settlementBufferAssets = _settlementBufferTargetAssets(maxLiabilityAssets);
        uint256 underBufferedAssets = maxLiabilityAssets + settlementBufferAssets - 1;
        _drainPoolTo(underBufferedAssets);

        assertGe(pool.totalAssets(), maxLiabilityAssets, "setup must remain raw solvent");
        assertLt(
            pool.totalAssets(),
            maxLiabilityAssets + settlementBufferAssets,
            "setup must miss only the settlement-buffer admission target"
        );
        assertEq(
            engineLens.previewOpenRevertCode(ALICE, CfdTypes.Side.LONG, size, marginAssets, MARK_PRICE),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "the attached parent must inherit the ordinary open buffer gate"
        );

        uint256 freeBefore = _freeSettlementAssets(ALICE);
        OrderV3Types.OrderRequest memory request = _boundedOpenRequest(CfdTypes.Side.LONG, size, marginAssets, 0);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)
            )
        );
        protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        assertEq(_freeSettlementAssets(ALICE), freeBefore, "commit rejection must roll back every tentative lock");
        assertEq(
            PositionProtectionBook(address(protectionBook)).nextPositionProtectionId(),
            1,
            "commit rejection must not allocate a protection id"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "commit rejection must not create a trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "commit rejection must not enqueue a parent order");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets, 0, "commit rejection must reserve no bounty"
        );
    }

    function test_AttachedOpen_PostCommitBufferInvalidationRefundsAndUnlocksProtection() public {
        _startRecordingLogs();
        uint256 size = 100_000e18;
        uint256 marginAssets = 5000e6;
        _open(BOB, CfdTypes.Side.SHORT, size, marginAssets, MARK_PRICE);

        uint256 freeBefore = _freeSettlementAssets(ALICE);
        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, size, marginAssets, 0), _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)
        );
        vm.stopPrank();
        uint256 parentBountyAssets = _executionBountyReserve(parentOrderId);

        uint256 maxLiabilityAssets = _maxLiability();
        uint256 settlementBufferAssets = _settlementBufferTargetAssets(maxLiabilityAssets);
        _drainPoolTo(maxLiabilityAssets + settlementBufferAssets - 1);
        assertGe(pool.totalAssets(), maxLiabilityAssets, "post-commit drift must remain raw solvent");
        assertLt(
            pool.totalAssets(),
            maxLiabilityAssets + settlementBufferAssets,
            "post-commit drift must leave the parent one atom below its buffer target"
        );

        uint256 branch = vm.snapshotState();
        vm.prank(address(router));
        clearinghouse.releaseOrderReservationForTerminalCleanup(parentOrderId);
        assertEq(
            engineLens.previewOpenRevertCode(ALICE, CfdTypes.Side.LONG, size, marginAssets, MARK_PRICE),
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
        assertEq(failed.triggerBountyAssets, 0, "invalidation must refund the trigger bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "invalidation must release the trade lock");
        assertEq(router.pendingOrderCounts(ALICE), 0, "invalidation must remove the parent from the queue");
        assertEq(router.getAccountReservations(ALICE).committedMarginAssets, 0, "parent margin must be unlocked");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "all bounty reservations must clear");
        assertEq(
            _freeSettlementAssets(ALICE),
            freeBefore - parentBountyAssets,
            "margin and protection bounties must return while the existing parent-bounty policy pays the keeper"
        );
        assertEq(
            _settlementBalance(EXECUTION_KEEPER) - keeperBefore,
            parentBountyAssets,
            "the ordinary parent execution bounty must follow the existing terminal-failure policy"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "invalidated attached open must create no position");
    }

    function test_AttachedOpen_SuccessArmsProtectionAtomically() public {
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: 13_333e6,
            maxGrossAccountDebitAssets: 9999e6,
            maxActionChargeAssets: 888e6,
            maxExplicitFeesAssets: 77e6
        });

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0), params
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
        _assertStoredCloseLimits(protectionId, params.closeLimits);
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            _totalProtectionBountyAssets() + _executionBountyReserve(parentOrderId),
            "view should include parent and staged-protection bounties"
        );

        PositionProtectionTypes.PositionProtectionParams memory replacement = _params(85_000_000, 115_000_000);
        replacement.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: 14_444e6,
            maxGrossAccountDebitAssets: 8888e6,
            maxActionChargeAssets: 666e6,
            maxExplicitFeesAssets: 55e6
        });
        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, replacement);
        _assertStoredCloseLimits(protectionId, replacement.closeLimits);
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
        _assertStoredCloseLimits(protectionId, replacement.closeLimits);
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            _totalProtectionBountyAssets(),
            "only protection bounties should remain after opening bounty payment"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, POSITION_SIZE, "parent should open the position");

        uint64 linkedOrderId = _triggerAt(protectionId, replacement.takeProfitTriggerPrice);
        _assertPendingCloseLimits(linkedOrderId, replacement.closeLimits);
    }

    function test_AttachedOpen_ValidFillSurvivesIfAcceptedMarkIsAheadOfEngine() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(request, params);

        uint64 commitTime = uint64(block.timestamp);
        vm.warp(commitTime + 2);
        // Reproduce a valid accepted basket that has not yet been installed by the Router.
        bytes[] memory liveData = _livePriceData(MARK_PRICE);
        vm.prank(address(router));
        pletherOracle.updatePrice(address(this), liveData, IPletherOracle.PriceMode.MarkRefresh);
        assertEq(engine.lastMarkTime(), commitTime, "oracle acceptance alone must not update Engine");

        bytes[] memory executionData = _mockPythUpdateData(MARK_PRICE);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrder(parentOrderId, executionData);

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(uint8(_orderRecord(parentOrderId).status), uint8(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint8(protection.status), uint8(PositionProtectionTypes.PositionProtectionStatus.Failed));
        assertEq(protection.triggerBountyAssets, 0, "unarmed trigger bounty must be released");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "failed protection must release lock");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "bounty reserve must clear");
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, POSITION_SIZE, "valid parent fill must survive protection failure");
    }

    function test_AttachedOpen_RetainsCallerBoundedRequestAndPublicIdentity() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        request.clientOrderId = keccak256("bounded-protected-parent");
        request.bounds.submitBy = uint64(block.timestamp + 1);
        request.bounds.executionWindowSeconds = uint32(uint256(uint64(block.timestamp + 1)) - block.timestamp);
        request.bounds.allowedExecutionModes = 1;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        OrderV3Types.ClientIntent memory intent = router.lifecycleBook().clientIntent(ALICE, request.clientOrderId);
        OrderV3Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(parentOrderId);
        (IOrderRouterAccounting.PendingOrderView memory parent,) = router.getPendingOrderView(parentOrderId);
        assertFalse(OrderV3Types.isProtocolClientOrderId(request.clientOrderId), "parent must use public id namespace");
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
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        bytes32 currentConfigHash = request.bounds.expectedConfigHash;

        request.bounds.expectedConfigHash = bytes32(0);
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__ExecutionConfigMismatch.selector, bytes32(0), currentConfigHash
            )
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        request.targetPrice = 0;
        _expectAttachedOpenCommitRevert(
            request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ZeroTargetPrice.selector)
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        request.isClose = true;
        _expectAttachedOpenCommitRevert(
            request, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__Unauthorized.selector)
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        request.clientOrderId = OrderV3Types.protocolClientOrderId(keccak256("protected-parent"));
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdDomainMismatch.selector, request.clientOrderId, false
            )
        );

        request = _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        uint256 executionBountyAssets = _quoteOpenOrderExecutionBountyAssets(POSITION_SIZE);
        request.bounds.maxExecutionBountyAssets = executionBountyAssets - 1;
        _expectAttachedOpenCommitRevert(
            request,
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound.selector,
                executionBountyAssets,
                executionBountyAssets - 1
            )
        );
    }

    function test_AttachedOpen_RejectsStaleConfigAtCommitAndRollsBack() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        bytes32 staleConfigHash = request.bounds.expectedConfigHash;
        _setRouterConfig(_routerConfig());
        _refreshMark(MARK_PRICE);
        request.bounds.submitBy = uint64(block.timestamp + router.maxExecutionWindowSeconds());
        request.bounds.executionWindowSeconds =
            uint32(uint256(uint64(block.timestamp + router.maxExecutionWindowSeconds())) - block.timestamp);
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
        _startRecordingLogs();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        routerAdmin.proposeRouterConfig(config);
        uint256 activationTime = routerAdmin.routerConfigActivationTime();
        vm.warp(activationTime - 1);
        _refreshMark(MARK_PRICE);

        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
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
        OrderV3Types.ExecutionResult memory result = router.executeOrder(parentOrderId, new bytes[](0));

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.ConfigMismatch), "parent failure reason"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_DisallowedExecutionModeFailsParentAndProtection() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        request.bounds.allowedExecutionModes = 2;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        assertFalse(engine.isFadWindow(), "execution must occur in live mode");
        bytes[] memory updateData = _mockPythUpdateData(MARK_PRICE);
        uint256 keeperBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        uint256 expectedBounty = _orderRecord(parentOrderId).executionBountyAssets;
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(parentOrderId, updateData);
        assertEq(clearinghouse.balanceAssets(EXECUTION_KEEPER) - keeperBefore, expectedBounty, "parent cleaner credit");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), parentOrderId);
        assertEq(outcome.executor, EXECUTION_KEEPER, "parent terminal executor");
        assertEq(outcome.bountyRecipient, EXECUTION_KEEPER, "parent bounty recipient");

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV3Types.TerminalReason.ExecutionModeDisallowed),
            "parent failure reason"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_FinancialBoundFailureFailsParentAndProtection() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        uint256 executionNotionalAssets = (POSITION_SIZE * MARK_PRICE) / 1e20;
        request.bounds.maxExecutionNotionalAssets = executionNotionalAssets - 1;

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        bytes[] memory updateData = _mockPythUpdateData(MARK_PRICE);
        uint256 keeperBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        uint256 expectedBounty = _orderRecord(parentOrderId).executionBountyAssets;
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(parentOrderId, updateData);
        assertEq(clearinghouse.balanceAssets(EXECUTION_KEEPER) - keeperBefore, expectedBounty, "parent cleaner credit");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), parentOrderId);
        assertEq(outcome.executor, EXECUTION_KEEPER, "parent terminal executor");
        assertEq(outcome.bountyRecipient, EXECUTION_KEEPER, "parent bounty recipient");

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed), "parent lifecycle");
        assertEq(
            uint8(result.terminalReason),
            uint8(OrderV3Types.TerminalReason.ConstraintViolation),
            "parent failure reason"
        );
        assertEq(
            uint8(
                _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), parentOrderId).failedConstraint
            ),
            uint8(OrderV3Types.ConstraintKind.ExecutionNotional),
            "failed bound"
        );
        _assertAttachedOpenTerminalFailure(parentOrderId, protectionId);
    }

    function test_AttachedOpen_ExactReplayAndClientIdConflictAreRejectedWithoutMutation() public {
        _startRecordingLogs();
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(request, params);

        uint256 freeBefore = _freeSettlementAssets(ALICE);
        uint64 nextParentBefore = router.nextCommitId();
        uint64 nextProtectionBefore = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();
        bytes32 protectionHash = keccak256(abi.encode(protectionViews.getPositionProtection(protectionId)));

        vm.expectRevert(PositionProtectionBook.PositionProtectionBook__InvalidHostResponse.selector);
        vm.prank(ALICE);
        protectionActions.commitOpenOrderWithProtection(request, params);

        OrderV3Types.OrderRequest memory conflict =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        conflict.clientOrderId = request.clientOrderId;
        conflict.bounds.maxExplicitFeesAssets -= 1;
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
        assertEq(_freeSettlementAssets(ALICE), freeBefore, "retry must roll back tentative bounty locks");
        assertEq(
            keccak256(abi.encode(protectionViews.getPositionProtection(protectionId))),
            protectionHash,
            "retry must not mutate protection"
        );
        assertEq(router.lifecycleBook().clientIntent(ALICE, request.clientOrderId).orderId, parentOrderId);
    }

    function test_AttachedOpen_LegacyScalarSelectorIsUnavailable() public {
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        bytes4 legacySelector =
            bytes4(keccak256("commitOpenOrderWithProtection(uint8,uint256,uint256,uint256,(uint256,uint256))"));
        assertTrue(legacySelector != IPositionProtectionActions.commitOpenOrderWithProtection.selector);

        vm.prank(ALICE);
        (bool success,) = address(protectionBook)
            .call(
                abi.encodeWithSelector(
                    legacySelector, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, uint256(0), params
                )
            );

        assertFalse(success, "legacy scalar selector must be unavailable");
        assertEq(router.pendingOrderCounts(ALICE), 0, "legacy call must not commit an order");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "legacy call must not create protection");
    }

    function test_Trigger_PublicRawIdPreclaimCannotPoisonProtocolClose() public {
        _startRecordingLogs();
        _open(ALICE, CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, MARK_PRICE);

        uint64 protectionId = PositionProtectionBook(address(protectionBook)).nextPositionProtectionId();
        uint64 poisonOrderId = router.nextCommitId();
        uint64 predictedLinkedOrderId = poisonOrderId + 1;
        bytes32 rawTriggerDigest = keccak256(
            abi.encode(
                "PLETHER_POSITION_PROTECTION_TRIGGER_V3",
                block.chainid,
                address(router),
                ALICE,
                protectionId,
                predictedLinkedOrderId
            )
        );
        bytes32 protocolClientOrderId = OrderV3Types.protocolClientOrderId(rawTriggerDigest);

        OrderV3Types.OrderRequest memory poisonRequest = _publicBoundedRequest(rawTriggerDigest, true);
        poisonRequest.bounds.submitBy = uint64(block.timestamp + 1);
        poisonRequest.bounds.executionWindowSeconds = uint32(uint256(uint64(block.timestamp + 1)) - block.timestamp);
        vm.prank(ALICE);
        assertEq(router.commitOrder(poisonRequest), poisonOrderId, "public preclaim order id");

        vm.warp(uint256(poisonRequest.bounds.submitBy) + 1);
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory poisonResult = router.executeOrder(poisonOrderId, new bytes[](0));
        assertEq(uint8(poisonResult.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        _refreshMark(MARK_PRICE);

        vm.prank(ALICE);
        assertEq(
            protectionActions.createPositionProtection(_params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)),
            protectionId,
            "fixture protection id"
        );
        uint64 linkedOrderId = _triggerAt(protectionId, LONG_TAKE_PROFIT);

        assertEq(linkedOrderId, predictedLinkedOrderId, "fixture must target the formerly colliding close");
        assertTrue(OrderV3Types.isProtocolClientOrderId(protocolClientOrderId));
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
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, 0);

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0), params
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

        vm.roll(uint256(armed.armedBlock) + 1);
        baseMockPyth.setAllPrices(
            _basePythFeedIds(), int64(uint64(crossedTakeProfit)), 0, int32(-8), engine.lastMarkTime()
        );
        bytes[] memory fillPublicationData = new bytes[](1);
        fillPublicationData[0] = hex"01";
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TriggerPublishTimeNotAdvanced.selector);
        protectionActions.triggerPositionProtection(protectionId, fillPublicationData);

        uint64 linkedOrderId = _triggerAt(protectionId, crossedTakeProfit);
        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            crossedTakeProfit
        );
    }

    function test_AttachedOpen_StageAndPendingReplacementRejectCrossedCurrentOracle() public {
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        pletherOracle.updatePrice(BOB, _priceData(LONG_TAKE_PROFIT), IPletherOracle.PriceMode.MarkRefresh);
        assertEq(engine.lastMarkPrice(), MARK_PRICE, "oracle update must not refresh the engine mark");
        _expectAttachedOpenCommitRevert(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0),
            abi.encodeWithSelector(PositionProtectionBook.PositionProtectionBook__OracleMarkAhead.selector)
        );
        router.updateMarkPrice(new bytes[](0));

        _expectAttachedOpenCommitRevert(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0),
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector)
        );

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        router.updateMarkPrice(_livePriceData(MARK_PRICE));
        OrderV3Types.OrderRequest memory request =
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) =
            protectionActions.commitOpenOrderWithProtection(request, _params(80_000_000, LONG_STOP_LOSS));

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        pletherOracle.updatePrice(BOB, _priceData(LONG_TAKE_PROFIT), IPletherOracle.PriceMode.MarkRefresh);
        router.updateMarkPrice(new bytes[](0));
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.replacePositionProtection(protectionId, _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS));

        PositionProtectionTypes.PositionProtectionView memory pending =
            protectionViews.getPositionProtection(protectionId);
        assertEq(uint8(pending.status), uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen));
        assertEq(pending.takeProfitTriggerPrice, 80_000_000, "failed replacement must preserve staged threshold");
        assertEq(pending.parentOrderId, parentOrderId, "failed replacement must preserve parent");
        assertEq(router.pendingOrderCounts(ALICE), 1, "failed replacement must leave parent queued");
    }

    function test_AttachedOpen_SlippageFailureRefundsProtectionBounties() public {
        _startRecordingLogs();
        uint256 freeBefore = _freeSettlementAssets(ALICE);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);

        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, LONG_STOP_LOSS), params
        );
        vm.stopPrank();
        uint256 parentBountyAssets = _executionBountyReserve(parentOrderId);

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
        assertEq(failed.triggerBountyAssets, 0, "failed attached protection should release trigger bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "failure should clear active protection");
        assertEq(router.pendingOrderCounts(ALICE), 0, "failed parent should leave no order");
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, 0, "failure should clear all reserves");
        assertEq(
            _freeSettlementAssets(ALICE),
            freeBefore - parentBountyAssets,
            "only the ordinary parent clearer bounty should remain spent"
        );
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "slippage-failed parent must not create a position");
    }

    function test_AttachedOpen_RiskOffRefundFailsProtectionAndReleasesAllReservesExactlyOnce() public {
        _startRecordingLogs();
        RiskOffRefundFixture memory fixture;
        fixture.freeBefore = _freeSettlementAssets(ALICE);
        fixture.settlementBefore = _settlementBalance(ALICE);
        fixture.cleanerSettlementBefore = _settlementBalance(CAROL);

        vm.startPrank(ALICE);
        (fixture.parentOrderId, fixture.protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0),
            _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS)
        );
        vm.stopPrank();

        fixture.parentMarginAssets = _remainingCommittedMargin(fixture.parentOrderId);
        fixture.parentBountyAssets = _executionBountyReserve(fixture.parentOrderId);
        fixture.protectionBountiesAssets = _totalProtectionBountyAssets();

        {
            uint256 totalReservedAssets =
                fixture.parentMarginAssets + fixture.parentBountyAssets + fixture.protectionBountiesAssets;
            IOrderRouterAccounting.AccountReservationView memory stagedReservations =
                router.getAccountReservations(ALICE);

            assertEq(
                fixture.freeBefore - _freeSettlementAssets(ALICE),
                totalReservedAssets,
                "setup must lock every reserve exactly"
            );
            assertEq(_settlementBalance(ALICE), fixture.settlementBefore, "reservation must not debit gross settlement");
            assertEq(stagedReservations.committedMarginAssets, fixture.parentMarginAssets, "parent margin reserve");
            assertEq(
                stagedReservations.executionBountyAssets,
                fixture.parentBountyAssets + fixture.protectionBountiesAssets,
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
        _startRecordingLogs();
        vm.prank(CAROL);
        router.clearRiskOffOrder(fixture.parentOrderId);
        {
            Vm.Log[] memory riskOffLogs = _takeRecordedLogs();
            vm.clearMockedCalls();
            _assertSingleRiskOffRefund(
                riskOffLogs,
                ALICE,
                fixture.parentMarginAssets,
                fixture.parentBountyAssets + fixture.protectionBountiesAssets
            );
        }

        assertEq(
            uint8(_orderRecord(fixture.parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "risk-off parent must fail"
        );
        assertEq(_orderRecord(fixture.parentOrderId).executionBountyAssets, 0, "parent must retain no unpaid bounty");
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
            assertEq(failed.triggerBountyAssets, 0, "risk-off must refund the trigger bounty");
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
                releasedParent.originalAmountAssets,
                fixture.parentMarginAssets,
                "parent original margin must be retained"
            );
            assertEq(releasedParent.remainingAmountAssets, 0, "parent margin must have no remainder");
        }
        {
            IOrderRouterAccounting.AccountReservationView memory clearedReservations =
                router.getAccountReservations(ALICE);
            assertEq(clearedReservations.committedMarginAssets, 0, "no parent margin may remain reserved");
            assertEq(clearedReservations.executionBountyAssets, 0, "no parent or protection bounty may remain reserved");
            assertEq(clearedReservations.pendingOrderCount, 0, "no parent order may remain live");
        }
        assertEq(_freeSettlementAssets(ALICE), fixture.freeBefore, "every reserve must return to free settlement");
        assertEq(_settlementBalance(ALICE), fixture.settlementBefore, "risk-off refund must preserve gross settlement");
        assertEq(
            _settlementBalance(CAROL), fixture.cleanerSettlementBefore, "permissionless cleaner must receive no bounty"
        );

        vm.prank(CAROL);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(fixture.parentOrderId);

        assertEq(_freeSettlementAssets(ALICE), fixture.freeBefore, "retry must not double-release reserves");
        assertEq(_settlementBalance(CAROL), fixture.cleanerSettlementBefore, "retry must not credit the cleaner");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyAssets,
            0,
            "retry must leave all bounty reserves cleared"
        );
        assertEq(
            clearinghouse.getOrderReservation(fixture.parentOrderId).remainingAmountAssets,
            0,
            "retry must release no margin"
        );
    }

    function test_AttachedOpen_RiskOffClearinghouseFailureRollsBackProtectionAndRouter() public {
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);
        vm.startPrank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0), params
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
        uint256 freeSettlementBefore = _freeSettlementAssets(ALICE);

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
        assertEq(_freeSettlementAssets(ALICE), freeSettlementBefore, "free settlement must roll back");
    }

    function test_AttachedOpen_ParentExpiryBatchFailsProtectionsAndRefundsTheirBounties() public {
        _startRecordingLogs();
        PositionProtectionTypes.PositionProtectionParams memory params = _params(LONG_TAKE_PROFIT, LONG_STOP_LOSS);

        vm.startPrank(ALICE);
        (uint64 aliceParentId, uint64 aliceProtectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0), params
        );
        vm.stopPrank();
        vm.startPrank(BOB);
        (uint64 bobParentId, uint64 bobProtectionId) = protectionActions.commitOpenOrderWithProtection(
            _boundedOpenRequest(CfdTypes.Side.LONG, POSITION_SIZE, POSITION_MARGIN_ASSETS, 0), params
        );
        vm.stopPrank();
        assertEq(aliceParentId, 1, "Alice parent queue id");
        assertEq(bobParentId, 2, "Bob parent queue id");

        vm.warp(block.timestamp + router.maxExecutionWindowSeconds() + 1);
        bytes[] memory empty = new bytes[](0);
        vm.prank(EXECUTION_KEEPER);
        router.executeOrderBatch(bobParentId, empty);

        _assertExpiredAttachedProtection(ALICE, aliceParentId, aliceProtectionId);
        _assertExpiredAttachedProtection(BOB, bobParentId, bobProtectionId);
        assertEq(router.nextExecuteId(), 0, "batch expiry should fully drain the parent queue");
    }

    function _assertCancelAndCommitCloseExecutes(
        CfdTypes.Side side,
        bool frozen
    ) internal {
        _startRecordingLogs();
        uint64 protectionId =
            _createSingleLegProtection(side, side == CfdTypes.Side.LONG ? LONG_TAKE_PROFIT : SHORT_TAKE_PROFIT, 0);
        if (frozen) {
            // Frozen execution replays the last mark installed while the market was live.
            vm.warp(FRIDAY_FAD_START - 1);
            _refreshMark(95_000_000);
            uint64 publication = engine.lastMarkTime();
            vm.warp(FRIDAY_FAD_START + 3 hours);
            assertTrue(engine.isOracleFrozen(), "frozen calendar fixture");
            // A different Pyth storage price must not replace the frozen engine mark.
            baseMockPyth.setAllPrices(_basePythFeedIds(), int64(105_000_000), 0, int32(-8), publication);
            assertGt(
                block.timestamp - publication,
                pletherOracle.orderExecutionStalenessLimit(),
                "quote stale under live rules"
            );
            assertLe(block.timestamp - publication, engine.fadMaxStaleness(), "quote allowed under frozen rules");
            vm.prank(TRIGGER_KEEPER);
            vm.expectRevert(IOrderRouterErrors.OrderRouter__ConditionalTriggerFrozen.selector);
            protectionActions.triggerPositionProtection(protectionId, _priceData(95_000_000));
            routerAdmin.pause();
            stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        }
        OrderV3Types.OrderRequest memory request = _manualCloseRequest(side);
        request.bounds.allowedExecutionModes = frozen ? 4 : 1;
        uint256 freeBefore = _freeSettlementAssets(ALICE);
        uint256 refund = protectionViews.getPositionProtection(protectionId).triggerBountyAssets;
        uint256 triggerKeeperBefore = clearinghouse.balanceAssets(TRIGGER_KEEPER);
        uint256 executorBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        router.commitOrder(request);
        vm.prank(ALICE);
        uint64 orderId = protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        assertEq(_freeSettlementAssets(ALICE), freeBefore + refund, "unpaid trigger bounty refunded atomically");
        assertEq(clearinghouse.balanceAssets(TRIGGER_KEEPER), triggerKeeperBefore, "trigger keeper not paid");
        assertFalse(router.lifecycleBook().isProtectionAttempt(orderId), "ordinary manual close");
        _assertManualExitProtectionCancelled(protectionId);

        bytes[] memory updateData;
        uint64 expectedPublication;
        if (frozen) {
            IPletherOracle.PriceSnapshot memory quote =
                pletherOracle.getLatestPrice(IPletherOracle.PriceMode.OrderExecution);
            assertEq(quote.price, 95_000_000, "asymmetric frozen engine mark");
            expectedPublication = quote.publishTime;
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            updateData = new bytes[](1);
            updateData[0] = hex"01";
        } else {
            updateData = _mockPythUpdateData(95_000_000);
        }
        vm.prank(EXECUTION_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "manual close executes");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), orderId);
        assertEq(
            uint8(outcome.executionMode),
            uint8(frozen ? OrderV3Types.ExecutionMode.Frozen : OrderV3Types.ExecutionMode.Live),
            "authorized execution mode"
        );
        assertEq(outcome.executionPrice, 95_000_000, "execution uses validated basket price");
        if (frozen) {
            assertEq(outcome.oraclePublishTime, expectedPublication, "frozen execution accepts pre-commit stale quote");
        }
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None), "no execution bounty");
        assertEq(clearinghouse.balanceAssets(EXECUTION_KEEPER), executorBefore, "executor receives no bounty");
        (uint256 remainingSize,,,,,,) = engine.positions(ALICE);
        assertEq(remainingSize, 0, "entire position closed");
        assertEq(router.pendingOrderCounts(ALICE), 0, "completed close leaves queue");
        assertEq(router.pendingCloseSize(ALICE), 0, "completed size released");
        _assertManualExitProtectionCancelled(protectionId);
    }

    function _manualCloseRequest(
        CfdTypes.Side side
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request = _publicBoundedRequest(keccak256(abi.encode("manual-protected-exit", router.nextCommitId())), true);
        request.side = side;
        request.targetPrice = side == CfdTypes.Side.LONG ? engine.CAP_PRICE() : 1;
    }

    function _assertManualExitProtectionCancelled(
        uint64 protectionId
    ) internal view {
        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Cancelled),
            "protection remains cancelled"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "active protection cleared");
        assertEq(protection.triggerBountyAssets, 0, "trigger reserve released");
        assertEq(protection.linkedOrderId, 0, "manual close does not become a trigger child");
        assertEq(
            uint8(protection.triggeredLeg),
            uint8(PositionProtectionTypes.PositionProtectionTriggerLeg.None),
            "no trigger recorded"
        );
    }

    function _expectCancelAndCommitCloseRevert(
        uint64 protectionId,
        OrderV3Types.OrderRequest memory request,
        bytes memory expectedRevert
    ) internal {
        bytes32 beforeState = _manualExitStateHash(protectionId, request.clientOrderId);
        vm.prank(ALICE);
        vm.expectRevert(expectedRevert);
        protectionActions.cancelPositionProtectionAndCommitClose(protectionId, request);
        assertEq(
            _manualExitStateHash(protectionId, request.clientOrderId),
            beforeState,
            "failed atomic exit rolls back all protection, reserve, queue and identity state"
        );
    }

    function _manualExitStateHash(
        uint64 protectionId,
        bytes32 clientOrderId
    ) internal view returns (bytes32) {
        bytes32 protectionHash = keccak256(
            abi.encode(
                protectionViews.getPositionProtection(protectionId),
                protectionViews.closeFinancialLimits(protectionId),
                protectionViews.activePositionProtectionId(ALICE),
                PositionProtectionBook(address(protectionBook)).nextPositionProtectionId()
            )
        );
        bytes32 accountHash = keccak256(
            abi.encode(
                clearinghouse.balanceAssets(ALICE),
                _freeSettlementAssets(ALICE),
                clearinghouse.actionReserveAssets(ALICE),
                router.getAccountReservations(ALICE),
                router.pendingCloseSize(ALICE),
                router.accountHeadOrderId(ALICE)
            )
        );
        bytes32 queueHash = keccak256(
            abi.encode(
                router.nextCommitId(),
                router.nextExecuteId(),
                router.globalTailOrderId(),
                router.lifecycleBook().clientIntent(ALICE, clientOrderId)
            )
        );
        return keccak256(abi.encode(protectionHash, accountHash, queueHash));
    }

    function _createSingleLegProtection(
        CfdTypes.Side side,
        uint256 takeProfit,
        uint256 stopLoss
    ) internal returns (uint64 protectionId) {
        return _createProtectionFor(ALICE, side, POSITION_SIZE, POSITION_MARGIN_ASSETS, takeProfit, stopLoss);
    }

    function _createProtectionFor(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 marginAssets,
        uint256 takeProfit,
        uint256 stopLoss
    ) internal returns (uint64 protectionId) {
        _open(account, side, size, marginAssets, MARK_PRICE);
        vm.prank(account);
        protectionId = protectionActions.createPositionProtection(_params(takeProfit, stopLoss));
    }

    function _triggerAt(
        uint64 protectionId,
        uint256 price
    ) internal returns (uint64 linkedOrderId) {
        _mockPythUpdateData(price);
        bytes[] memory updateData = _livePriceData(price);
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

    function _mockArbitrumBlockNumber(
        uint256 l2Block
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(l2Block));
    }

    function _expireProtectionAttempt(
        uint64 orderId,
        address cleaner
    ) internal returns (OrderV3Types.ExecutionResult memory result) {
        uint64 submitBy = router.lifecycleBook().orderTiming(orderId).executionDeadline;
        assertGt(submitBy, block.timestamp, "fixture requires a live attempt before expiry");
        vm.warp(uint256(submitBy) + 1);
        vm.prank(cleaner);
        result = router.executeOrder(orderId, new bytes[](0));
    }

    function _expectTriggerNotMet(
        uint64 protectionId,
        uint256 price
    ) internal {
        _mockPythUpdateData(price);
        bytes[] memory updateData = _livePriceData(price);
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
        if (block.timestamp <= engine.lastMarkTime()) {
            vm.warp(uint256(engine.lastMarkTime()) + 1);
        }
        router.updateMarkPrice(_livePriceData(price));
    }

    function _livePriceData(
        uint256 price
    ) internal view returns (bytes[] memory updateData) {
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](ids.length);
        uint256 previous = engine.lastMarkTime();
        for (uint256 i; i < ids.length; ++i) {
            ticks[i] =
                MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, block.timestamp, previous));
        }
        updateData = new bytes[](1);
        updateData[0] = abi.encode(ticks);
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
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max
        });
    }

    function _assertStoredCloseLimits(
        uint64 protectionId,
        PositionProtectionTypes.CloseFinancialLimits memory expected
    ) internal view {
        PositionProtectionTypes.CloseFinancialLimits memory actual = protectionViews.closeFinancialLimits(protectionId);
        assertEq(actual.maxExecutionNotionalAssets, expected.maxExecutionNotionalAssets, "stored notional ceiling");
        assertEq(actual.maxGrossAccountDebitAssets, expected.maxGrossAccountDebitAssets, "stored gross debit ceiling");
        assertEq(actual.maxActionChargeAssets, expected.maxActionChargeAssets, "stored action charge ceiling");
        assertEq(actual.maxExplicitFeesAssets, expected.maxExplicitFeesAssets, "stored explicit fees ceiling");
    }

    function _assertPendingCloseLimits(
        uint64 orderId,
        PositionProtectionTypes.CloseFinancialLimits memory expected
    ) internal view {
        OrderV3Types.ExecutionBounds memory policy = router.lifecycleBook().pendingPolicy(orderId);
        assertEq(policy.maxExecutionNotionalAssets, expected.maxExecutionNotionalAssets, "pending notional ceiling");
        assertEq(policy.maxGrossAccountDebitAssets, expected.maxGrossAccountDebitAssets, "pending gross debit ceiling");
        assertEq(policy.maxActionChargeAssets, expected.maxActionChargeAssets, "pending action charge ceiling");
        assertEq(policy.maxExplicitFeesAssets, expected.maxExplicitFeesAssets, "pending explicit fees ceiling");
    }

    function _publicBoundedRequest(
        bytes32 clientOrderId,
        bool isClose
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = clientOrderId;
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = POSITION_SIZE;
        request.marginDelta = isClose ? 0 : POSITION_MARGIN_ASSETS;
        request.targetPrice = isClose ? engine.CAP_PRICE() : 1;
        request.isClose = isClose;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(block.timestamp + router.maxExecutionWindowSeconds()),
            executionWindowSeconds: uint32(
                uint256(uint64(block.timestamp + router.maxExecutionWindowSeconds())) - block.timestamp
            ),
            allowedExecutionModes: 1 | 2 | 4,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyAssets: type(uint256).max,
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceAssets: 0,
            minPostPositionEquityAssets: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _boundedOpenRequest(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request = _publicBoundedRequest(bytes32(uint256(router.nextCommitId())), false);
        request.side = side;
        request.sizeDelta = sizeDelta;
        request.marginDelta = marginDelta;
        request.targetPrice = targetPrice == 0 ? (side == CfdTypes.Side.LONG ? 1 : engine.CAP_PRICE()) : targetPrice;
    }

    function _expectAttachedOpenCommitRevert(
        OrderV3Types.OrderRequest memory request,
        bytes memory revertData
    ) internal {
        uint256 freeBefore = _freeSettlementAssets(ALICE);
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
        assertEq(_freeSettlementAssets(ALICE), freeBefore, "rejection must roll back protection bounty locks");
        assertEq(router.pendingOrderCounts(ALICE), 0, "rejection must not queue parent");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "rejection must not stage protection");
    }

    /// @dev The fixture opens 10,000 settlement token notional with a 10 bps reserve and a 50% keeper share.
    function _liquidateProtectedPositionAsKeeper() internal {
        _mockPythUpdateData(150_000_000);
        bytes[] memory updateData = _livePriceData(150_000_000);
        uint256 expectedReserve = ((POSITION_SIZE * MARK_PRICE) / 1e20) * 10 / 10_000;
        assertEq(clearinghouse.liquidationReserveAssets(ALICE), expectedReserve, "funded opening reserve");
        uint256 keeperBefore = clearinghouse.balanceAssets(EXECUTION_KEEPER);
        uint256 harnessBefore = clearinghouse.balanceAssets(address(this));
        vm.prank(EXECUTION_KEEPER);
        router.executeLiquidation(ALICE, updateData);
        assertEq(
            clearinghouse.balanceAssets(EXECUTION_KEEPER) - keeperBefore,
            expectedReserve / 2,
            "liquidation keeper receives the reserve-capped share"
        );
        assertEq(clearinghouse.balanceAssets(address(this)), harnessBefore, "fixture cannot receive keeper credit");
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
        assertEq(failed.triggerBountyAssets, 0, "trigger bounty must clear");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "trade lock must clear");
        assertEq(router.pendingOrderCounts(ALICE), 0, "parent must leave queue");
        (uint256 liveSize,,,,,,) = engine.positions(ALICE);
        assertEq(liveSize, 0, "failed parent must not create position");
    }

    function _totalProtectionBountyAssets() internal view returns (uint256) {
        return router.positionProtectionTriggerBountyAssets();
    }

    function _settlementBufferTargetAssets(
        uint256 maxLiabilityAssets
    ) internal view returns (uint256) {
        return SolvencyAccountingLib.settlementBufferTargetAssets(maxLiabilityAssets, engine.settlementBufferBps());
    }

    function _drainPoolTo(
        uint256 targetAssets
    ) internal {
        uint256 assets = pool.totalAssets();
        assertGt(assets, targetAssets, "fixture must have drainable pool assets");
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), assets - targetAssets);
        assertEq(pool.totalAssets(), targetAssets, "fixture must reach the requested pool assets");
    }

    function _riskBoundaryFixture(
        CfdTypes.RiskParams memory riskParams,
        uint256 requiredMarginBps
    ) internal view returns (RiskBoundaryFixture memory fixture) {
        uint256 notionalAssets = (POSITION_SIZE * MARK_PRICE) / 1e20;
        fixture.requirementAssets = (notionalAssets * requiredMarginBps) / 10_000;
        fixture.exactOpeningMarginDeltaAssets = fixture.requirementAssets
            + _engineExecutionFeeAssets(POSITION_SIZE, MARK_PRICE)
            + _liquidationReserveTargetAssets(notionalAssets, riskParams);
        fixture.plusOneOpeningMarginDeltaAssets = fixture.exactOpeningMarginDeltaAssets + 1;
        fixture.protectionBountiesAssets = _totalProtectionBountyAssets();
    }

    function _postMarkInitialMarginBoundaryFixture(
        CfdTypes.RiskParams memory riskParams
    ) internal view returns (RiskBoundaryFixture memory fixture) {
        fixture = _riskBoundaryFixture(riskParams, riskParams.initMarginBps);
        uint256 lots = POSITION_SIZE / CfdTypes.SIZE_QUANTUM;
        uint256 postMarkRequirement = lots * POST_MARK_PRICE * riskParams.initMarginBps / 10_000;
        uint256 openingSurplus = lots * (POST_MARK_PRICE - MARK_PRICE) + postMarkRequirement - fixture.requirementAssets;
        fixture.exactOpeningMarginDeltaAssets += openingSurplus;
        fixture.plusOneOpeningMarginDeltaAssets += openingSurplus;
        fixture.requirementAssets = postMarkRequirement;
    }

    function _liquidationReserveTargetAssets(
        uint256 notionalAssets,
        CfdTypes.RiskParams memory riskParams
    ) internal pure returns (uint256 reserveTargetAssets) {
        reserveTargetAssets = (notionalAssets * riskParams.bountyBps) / 10_000;
        if (reserveTargetAssets < riskParams.minBountyAssets) {
            reserveTargetAssets = riskParams.minBountyAssets;
        }
    }

    function _seedAuthenticatedTraderClaim(
        address account,
        uint256 claimAssets
    ) internal {
        bytes32 oldCurveHash = terminalNavBook.curveHashOf(account);
        uint256 oldAccountClaimAssets = engine.traderClaimBalanceAssets(account);
        uint256 oldTotalClaimAssets = engine.totalTraderClaimBalanceAssets();
        stdstore.target(address(engine)).sig("traderClaimBalanceAssets(address)").with_key(account)
            .checked_write(claimAssets);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceAssets()")
            .checked_write(oldTotalClaimAssets - oldAccountClaimAssets + claimAssets);
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(account, oldCurveHash);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
    }

    function _withdrawAllFreeSettlement(
        address account
    ) internal {
        uint256 freeSettlementAssets = _freeSettlementAssets(account);
        vm.prank(account);
        clearinghouse.withdraw(account, freeSettlementAssets);
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
        assertEq(failed.triggerBountyAssets, 0, "expiry should refund the staged trigger bounty");
        assertEq(protectionViews.activePositionProtectionId(account), 0, "expiry should clear the trade lock");
        assertEq(
            uint8(_orderRecord(parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "expired parent should be terminally failed"
        );
        assertEq(router.pendingOrderCounts(account), 0, "expiry should clear the account queue");
        assertEq(router.getAccountReservations(account).executionBountyAssets, 0, "expiry should clear every reserve");
    }

    function _assertSingleRiskOffRefund(
        Vm.Log[] memory logs,
        address expectedAccount,
        uint256 expectedMarginAssets,
        uint256 expectedBountyAssets
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
            (uint256 releasedMarginAssets, uint256 refundableBountyAssets) = abi.decode(entry.data, (uint256, uint256));
            assertEq(releasedMarginAssets, expectedMarginAssets, "risk-off released margin");
            assertEq(refundableBountyAssets, expectedBountyAssets, "risk-off aggregate bounty refund");
        }
        assertEq(matches, 1, "exactly one aggregate risk-off refund event");
    }

}

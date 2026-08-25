// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PositionProtectionBook} from "@plether/perps/PositionProtectionBook.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionBook} from "@plether/perps/interfaces/IPositionProtectionBook.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
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
    uint256 internal constant BULL_TAKE_PROFIT = 90_000_000;
    uint256 internal constant BULL_STOP_LOSS = 110_000_000;
    uint256 internal constant BEAR_TAKE_PROFIT = 110_000_000;
    uint256 internal constant BEAR_STOP_LOSS = 90_000_000;
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
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        _open(ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__DegradedMode.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc,
            0,
            "failed protection creation must roll back both bounty locks"
        );
    }

    function test_CreatePositionProtection_RejectsEmptyOrAboveCapThresholds() public {
        _open(ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

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

    function test_CreatePositionProtection_ValidatesBullGeometryAndArmsOffQueue() public {
        _open(ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(BULL_STOP_LOSS, BULL_TAKE_PROFIT));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(MARK_PRICE, 0));

        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(protectionId, 1, "first protection id");
        assertEq(protectionViews.activePositionProtectionId(ALICE), protectionId, "active protection id");
        assertEq(protection.account, ALICE, "protection owner");
        assertEq(uint8(protection.side), uint8(CfdTypes.Side.BULL), "protected side");
        assertEq(protection.size, POSITION_SIZE, "full position size");
        assertEq(protection.takeProfitTriggerPrice, BULL_TAKE_PROFIT, "take-profit threshold");
        assertEq(protection.stopLossTriggerPrice, BULL_STOP_LOSS, "stop-loss threshold");
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

    function test_CreatePositionProtection_ValidatesBearGeometry() public {
        _open(ALICE, CfdTypes.Side.BEAR, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidProtectionPrices.selector);
        protectionActions.createPositionProtection(_params(BEAR_STOP_LOSS, BEAR_TAKE_PROFIT));

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionTriggerAlreadyMet.selector);
        protectionActions.createPositionProtection(_params(MARK_PRICE, 0));

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BEAR_TAKE_PROFIT, BEAR_STOP_LOSS));

        PositionProtectionTypes.PositionProtectionView memory protection =
            protectionViews.getPositionProtection(protectionId);
        assertEq(uint8(protection.side), uint8(CfdTypes.Side.BEAR), "protected side");
        assertEq(
            uint8(protection.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "bear protection should arm"
        );
    }

    function test_BullTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);

        _expectTriggerNotMet(protectionId, BULL_TAKE_PROFIT + 2);
        uint64 linkedOrderId = _triggerAt(protectionId, BULL_TAKE_PROFIT);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            BULL_TAKE_PROFIT
        );
    }

    function test_BullStopLoss_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, 0, BULL_STOP_LOSS);

        _expectTriggerNotMet(protectionId, BULL_STOP_LOSS - 1);
        uint64 linkedOrderId = _triggerAt(protectionId, BULL_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, BULL_STOP_LOSS
        );
    }

    function test_BearTakeProfit_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BEAR, BEAR_TAKE_PROFIT, 0);

        _expectTriggerNotMet(protectionId, BEAR_TAKE_PROFIT - 1);
        uint64 linkedOrderId = _triggerAt(protectionId, BEAR_TAKE_PROFIT);

        _assertTriggered(
            protectionId,
            linkedOrderId,
            PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit,
            BEAR_TAKE_PROFIT
        );
    }

    function test_BearStopLoss_TriggersAtEqualityAndRejectsWrongDirection() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BEAR, 0, BEAR_STOP_LOSS);

        _expectTriggerNotMet(protectionId, BEAR_STOP_LOSS + 2);
        uint64 linkedOrderId = _triggerAt(protectionId, BEAR_STOP_LOSS);

        _assertTriggered(
            protectionId, linkedOrderId, PositionProtectionTypes.PositionProtectionTriggerLeg.StopLoss, BEAR_STOP_LOSS
        );
    }

    function test_TriggerPositionProtection_RejectsSameBlockAndOldPublishTime() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);
        PositionProtectionTypes.PositionProtectionView memory armed =
            protectionViews.getPositionProtection(protectionId);

        bytes[] memory sameBlockData = _priceData(BULL_TAKE_PROFIT);
        vm.prank(TRIGGER_KEEPER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SameBlockTrigger.selector);
        protectionActions.triggerPositionProtection(protectionId, sameBlockData);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(BULL_TAKE_PROFIT)), 0, int32(-8), armed.armedAt);
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
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);

        vm.prank(BOB);
        router.commitOrder(CfdTypes.Side.BEAR, POSITION_SIZE, POSITION_MARGIN_USDC, 0, false);
        assertEq(router.nextExecuteId(), 1, "foreign order should be queue head");

        uint256 triggerKeeperBefore = clearinghouse.balanceUsdc(TRIGGER_KEEPER);
        uint64 linkedOrderId = _triggerAt(protectionId, BULL_TAKE_PROFIT);
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
        assertEq(closeOrder.targetPrice, 0, "linked close should be market-style");
        assertEq(uint8(closeOrder.side), uint8(CfdTypes.Side.BULL), "linked close side");
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
        bytes[] memory closeExecutionData = _mockPythUpdateData(BULL_TAKE_PROFIT);
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

    function test_CancelPositionProtection_RefundsExactReserveAndClearsTradeLock() public {
        _open(ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        uint256 freeBefore = _freeSettlementUsdc(ALICE);

        vm.prank(ALICE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));
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
        _open(RISK_EXACT, CfdTypes.Side.BULL, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.BULL, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaUsdc, MARK_PRICE);

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
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));
        assertEq(_freeSettlementUsdc(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");
        assertEq(protectionViews.activePositionProtectionId(RISK_EXACT), 0, "risk failure must not create protection");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));
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
        _open(RISK_EXACT, CfdTypes.Side.BULL, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "price pledge at equality");
        assertEq(
            _freeSettlementUsdc(RISK_EXACT),
            fixture.protectionBountiesUsdc + surplusFreeSettlementUsdc,
            "fixture must have abundant generic free settlement"
        );

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

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
        _open(RISK_EXACT, CfdTypes.Side.BULL, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "pledge starts at equality");

        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        _seedAuthenticatedTraderClaim(RISK_EXACT, 1);
        vm.prank(RISK_EXACT);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

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
        _open(RISK_EXACT, CfdTypes.Side.BULL, POSITION_SIZE, fixture.exactOpeningMarginDeltaUsdc, MARK_PRICE);
        _open(RISK_PLUS_ONE, CfdTypes.Side.BULL, POSITION_SIZE, fixture.plusOneOpeningMarginDeltaUsdc, MARK_PRICE);

        assertEq(clearinghouse.pnlPledgeUsdc(RISK_EXACT), fixture.requirementUsdc, "exact FAD pledge boundary");
        assertEq(clearinghouse.pnlPledgeUsdc(RISK_PLUS_ONE), fixture.requirementUsdc + 1, "one-atom FAD pledge surplus");

        vm.warp(FRIDAY_FAD_START);
        router.updateMarkPrice(_mockPythUpdateData(MARK_PRICE));
        assertTrue(engine.isFadWindow(), "post-lock risk should use the stricter FAD requirement");

        uint256 exactFreeBefore = _freeSettlementUsdc(RISK_EXACT);
        assertGe(exactFreeBefore, fixture.protectionBountiesUsdc, "exact-boundary account can fund the bounty itself");
        vm.prank(RISK_EXACT);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));
        assertEq(_freeSettlementUsdc(RISK_EXACT), exactFreeBefore, "risk failure must roll back the bounty lock");

        vm.prank(RISK_PLUS_ONE);
        uint64 protectionId = protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));
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
        _open(ALICE, CfdTypes.Side.BEAR, size, 5000e6, MARK_PRICE, depth);
        _open(BOB, CfdTypes.Side.BULL, size, 5000e6, MARK_PRICE, depth);
        (,,,,,, int256 vpiAccrued) = engine.positions(BOB);
        assertLt(vpiAccrued, 0, "rebate-side fixture must have negative lifetime VPI");

        uint256 reserveTargetUsdc = uint256(-(vpiAccrued + 1)) + 1;
        assertEq(clearinghouse.vpiRebateReserveUsdc(BOB), reserveTargetUsdc, "reserve starts exactly funded");
        vm.prank(address(engine));
        clearinghouse.releaseVpiRebateReserve(BOB, 1);

        uint256 freeBefore = _freeSettlementUsdc(BOB);
        vm.prank(BOB);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        assertEq(
            clearinghouse.vpiRebateReserveUsdc(BOB), reserveTargetUsdc - 1, "failed action must not repair VPI backing"
        );
        assertEq(_freeSettlementUsdc(BOB), freeBefore, "failed action must roll back its bounty lock");
        assertEq(protectionViews.activePositionProtectionId(BOB), 0, "VPI delinquency must fail closed");
    }

    function test_PostLockRisk_RejectsCarryLeftUncoveredByLockCheckpoint() public {
        _open(ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, MARK_PRICE);
        _withdrawAllFreeSettlement(ALICE);

        stdstore.target(address(router)).sig("closeOrderExecutionBountyUsdc()").checked_write(uint256(0));
        stdstore.target(address(router)).sig("positionProtectionTriggerBountyUsdc()").checked_write(uint256(0));

        vm.warp(block.timestamp + 365 days);
        _refreshMark(MARK_PRICE);
        assertGt(_expectedIndexedCarryUsdc(ALICE), 0, "fixture must accrue carry with no eligible free settlement");

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        protectionActions.createPositionProtection(_params(BULL_TAKE_PROFIT, BULL_STOP_LOSS));

        assertEq(
            engine.unsettledCarryUsdc(ALICE),
            0,
            "risk failure must roll back the lock-time carry checkpoint with the rest of the action"
        );
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "uncovered carry must fail closed");
    }

    function test_Pause_BlocksNewAndReplacementButAllowsCancelAndTrigger() public {
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, BULL_TAKE_PROFIT, BULL_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, BULL_TAKE_PROFIT, 0);

        routerAdmin.pause();

        vm.prank(ALICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(BULL_TAKE_PROFIT - 1, 0));

        vm.prank(CAROL);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS)
        );

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(cancelledProtectionId);
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "pause must not block cancellation");

        uint64 linkedOrderId = _triggerAt(triggeredProtectionId, BULL_TAKE_PROFIT);
        assertEq(
            uint8(protectionViews.getPositionProtection(triggeredProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "pause must not block a safety trigger"
        );
        assertEq(router.accountHeadOrderId(BOB), linkedOrderId, "paused trigger should append the close normally");
    }

    function test_FeatureOff_BlocksNewAndReplacementButAllowsCancelAndTrigger() public {
        uint64 cancelledProtectionId = _createProtectionFor(
            ALICE, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, BULL_TAKE_PROFIT, BULL_STOP_LOSS
        );
        uint64 triggeredProtectionId =
            _createProtectionFor(BOB, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, BULL_TAKE_PROFIT, 0);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.positionProtectionCommitsEnabled = false;
        _setRouterConfig(config);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionDisabled.selector);
        protectionActions.replacePositionProtection(cancelledProtectionId, _params(BULL_TAKE_PROFIT - 1, 0));

        vm.prank(CAROL);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionDisabled.selector);
        protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS)
        );

        vm.prank(ALICE);
        protectionActions.cancelPositionProtection(cancelledProtectionId);
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "feature-off must not block cancellation");

        uint64 linkedOrderId = _triggerAt(triggeredProtectionId, BULL_TAKE_PROFIT);
        assertEq(
            uint8(protectionViews.getPositionProtection(triggeredProtectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Triggered),
            "feature-off must not disable existing safety instructions"
        );
        assertEq(router.accountHeadOrderId(BOB), linkedOrderId, "feature-off trigger should append the close normally");
    }

    function test_ReplacePositionProtection_RemainsAvailableInDegradedMode() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertTrue(engine.degradedMode(), "setup should enter degraded mode");

        vm.prank(ALICE);
        protectionActions.replacePositionProtection(protectionId, _params(BULL_TAKE_PROFIT - 1, 0));

        PositionProtectionTypes.PositionProtectionView memory replaced =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(replaced.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
            "geometry-only replacement should remain available in degraded mode"
        );
        assertEq(replaced.takeProfitTriggerPrice, BULL_TAKE_PROFIT - 1, "replacement threshold");
        assertEq(replaced.armedAt, block.timestamp, "replacement should restart time separation");
        assertEq(replaced.armedBlock, block.number, "replacement should restart block separation");
        assertEq(
            replaced.triggerBountyUsdc + replaced.executionBountyUsdc,
            _totalProtectionBountyUsdc(),
            "replacement should retain the snapshotted reserve"
        );
    }

    function test_ProtectionBook_NonTriggerActionsRejectEthAndNeverCustodyIt() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IPositionProtectionActions.createPositionProtection, (params));
        calls[1] = abi.encodeCall(IPositionProtectionActions.replacePositionProtection, (uint64(1), params));
        calls[2] = abi.encodeCall(IPositionProtectionActions.cancelPositionProtection, (uint64(1)));
        calls[3] = abi.encodeCall(
            IPositionProtectionActions.commitOpenOrderWithProtection,
            (CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params)
        );

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
        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.activate(1, MARK_PRICE, uint64(block.timestamp), 1);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.afterOrderTerminal(1, ALICE, IOrderRouterAccounting.OrderStatus.Failed);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.failPendingOpenForRiskOff(1, ALICE);

        vm.expectRevert(IOrderRouterErrors.OrderRouter__Unauthorized.selector);
        protectionBook.forfeitOnLiquidation(ALICE);
    }

    function test_Router_IgnoresBookTrailingMetadataFromUntrustedCaller() public {
        bytes memory commitCall = abi.encodeWithSelector(
            router.commitOrder.selector, CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, false
        );
        vm.prank(BOB);
        (bool commitSuccess,) = address(router).call(abi.encodePacked(commitCall, abi.encode(ALICE)));
        assertTrue(commitSuccess, "ordinary callers may still submit canonical orders with ignored trailing bytes");
        assertEq(_orderRecord(1).core.account, BOB, "only the Book may supply a trailing canonical account");

        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);
        bytes memory refreshCall =
            abi.encodeWithSelector(router.updateMarkPrice.selector, _mockPythUpdateData(BULL_TAKE_PROFIT));
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
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);
        bytes[] memory updateData = _mockPythUpdateData(BULL_TAKE_PROFIT);
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
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, BULL_TAKE_PROFIT, 0);

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        router.commitOrder(CfdTypes.Side.BULL, POSITION_SIZE, 0, 0, true);

        (, uint256 marginBefore,,,,,) = engine.positions(ALICE);
        vm.prank(ALICE);
        engine.addMargin(ALICE, 100e6);
        (, uint256 marginAfter,,,,,) = engine.positions(ALICE);
        assertEq(marginAfter, marginBefore + 100e6, "protection should not block add-margin safety action");

        _triggerAt(protectionId, BULL_TAKE_PROFIT);
        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ProtectionActive.selector);
        router.commitOrder(CfdTypes.Side.BULL, POSITION_SIZE, 0, 0, true);
    }

    function test_Liquidation_ArmedProtectionForfeitsBothBountiesAndTerminalizes() public {
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, 0, BULL_STOP_LOSS);
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
        uint64 protectionId = _createSingleLegProtection(CfdTypes.Side.BULL, 0, BULL_STOP_LOSS);
        _withdrawAllFreeSettlement(ALICE);
        uint64 linkedOrderId = _triggerAt(protectionId, BULL_STOP_LOSS);

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

    function test_AttachedOpen_SuccessArmsProtectionAtomically() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );

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
        assertEq(uint8(armed.side), uint8(CfdTypes.Side.BULL), "armed side should match actual position");
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

    function test_AttachedOpen_ThresholdCrossedBeforeFillArmsThenTriggersOnLaterTick() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, 0);

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );

        uint256 crossedTakeProfit = BULL_TAKE_PROFIT - 2;
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
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, BULL_STOP_LOSS, params
        );
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
        uint256 freeBefore = _freeSettlementUsdc(ALICE);
        uint256 settlementBefore = _settlementBalance(ALICE);
        uint256 cleanerSettlementBefore = _settlementBalance(CAROL);
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);

        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );

        uint256 parentMarginUsdc = _remainingCommittedMargin(parentOrderId);
        uint256 parentBountyUsdc = _executionBountyReserve(parentOrderId);
        uint256 protectionBountiesUsdc = _totalProtectionBountyUsdc();
        uint256 totalReservedUsdc = parentMarginUsdc + parentBountyUsdc + protectionBountiesUsdc;
        IOrderRouterAccounting.AccountReservationView memory stagedReservations = router.getAccountReservations(ALICE);

        assertEq(freeBefore - _freeSettlementUsdc(ALICE), totalReservedUsdc, "setup must lock every reserve exactly");
        assertEq(_settlementBalance(ALICE), settlementBefore, "reservation must not debit gross settlement");
        assertEq(stagedReservations.committedMarginUsdc, parentMarginUsdc, "parent margin reserve");
        assertEq(
            stagedReservations.executionBountyUsdc,
            parentBountyUsdc + protectionBountiesUsdc,
            "parent and protection bounty reserves"
        );
        assertEq(stagedReservations.pendingOrderCount, 1, "only the parent open should be queued");
        assertEq(
            uint8(protectionViews.getPositionProtection(protectionId).status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.PendingOpen),
            "protection must be pending on its parent"
        );

        routerAdmin.pause();
        assertTrue(routerAdmin.paused(), "risk-off must pause new risk");
        assertEq(routerAdmin.riskOffOrderCutoff(), parentOrderId, "cutoff must include the attached parent");

        vm.mockCallRevert(
            address(engine),
            abi.encodeCall(ICfdEngineCore.realizeCarryBeforeMarginChange, (ALICE)),
            bytes("risk-off must not checkpoint carry")
        );
        vm.recordLogs();
        vm.prank(CAROL);
        router.clearRiskOffOrder(parentOrderId);
        Vm.Log[] memory riskOffLogs = vm.getRecordedLogs();
        vm.clearMockedCalls();
        _assertSingleRiskOffRefund(riskOffLogs, ALICE, parentMarginUsdc, parentBountyUsdc + protectionBountiesUsdc);

        assertEq(
            uint8(_orderRecord(parentOrderId).status),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "risk-off parent must fail"
        );
        assertEq(_orderRecord(parentOrderId).executionBountyUsdc, 0, "parent must retain no unpaid bounty");
        assertFalse(_orderRecord(parentOrderId).inAccountQueue, "parent must leave the account queue");
        assertFalse(_orderRecord(parentOrderId).inMarginQueue, "parent must leave the margin queue");
        assertEq(_orderRecord(parentOrderId).nextGlobalOrderId, 0, "parent global next link");
        assertEq(_orderRecord(parentOrderId).prevGlobalOrderId, 0, "parent global previous link");
        assertEq(_orderRecord(parentOrderId).nextAccountOrderId, 0, "parent account next link");
        assertEq(_orderRecord(parentOrderId).prevAccountOrderId, 0, "parent account previous link");
        assertEq(_orderRecord(parentOrderId).nextMarginOrderId, 0, "parent margin next link");
        assertEq(_orderRecord(parentOrderId).prevMarginOrderId, 0, "parent margin previous link");
        assertEq(router.nextExecuteId(), 0, "global queue must be empty");
        assertEq(router.globalTailOrderId(), 0, "global tail must be empty");
        assertEq(router.accountHeadOrderId(ALICE), 0, "account queue must be empty");
        assertEq(router.marginHeadOrderId(ALICE), 0, "margin queue head must be empty");
        assertEq(router.marginTailOrderId(ALICE), 0, "margin queue tail must be empty");
        assertEq(router.pendingOrderCounts(ALICE), 0, "parent must no longer count as pending");

        PositionProtectionTypes.PositionProtectionView memory failed =
            protectionViews.getPositionProtection(protectionId);
        assertEq(
            uint8(failed.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.Failed),
            "risk-off parent must fail its staged protection"
        );
        assertEq(failed.parentOrderId, parentOrderId, "terminal protection should retain its parent id");
        assertEq(failed.linkedOrderId, 0, "failed staged protection must never create a close");
        assertEq(failed.triggerBountyUsdc, 0, "risk-off must refund the trigger bounty");
        assertEq(failed.executionBountyUsdc, 0, "risk-off must refund the staged close bounty");
        assertEq(protectionViews.activePositionProtectionId(ALICE), 0, "risk-off must clear the active protection");

        IMarginClearinghouse.OrderReservation memory releasedParent = clearinghouse.getOrderReservation(parentOrderId);
        assertEq(
            uint8(releasedParent.status),
            uint8(IMarginClearinghouse.ReservationStatus.Released),
            "parent margin reservation must be released"
        );
        assertEq(releasedParent.originalAmountUsdc, parentMarginUsdc, "parent original margin must be retained");
        assertEq(releasedParent.remainingAmountUsdc, 0, "parent margin must have no remainder");
        IOrderRouterAccounting.AccountReservationView memory clearedReservations = router.getAccountReservations(ALICE);
        assertEq(clearedReservations.committedMarginUsdc, 0, "no parent margin may remain reserved");
        assertEq(clearedReservations.executionBountyUsdc, 0, "no parent or protection bounty may remain reserved");
        assertEq(clearedReservations.pendingOrderCount, 0, "no parent order may remain live");
        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "every reserve must return to free settlement");
        assertEq(_settlementBalance(ALICE), settlementBefore, "risk-off refund must preserve gross settlement");
        assertEq(_settlementBalance(CAROL), cleanerSettlementBefore, "permissionless cleaner must receive no bounty");

        vm.prank(CAROL);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(parentOrderId);

        assertEq(_freeSettlementUsdc(ALICE), freeBefore, "retry must not double-release reserves");
        assertEq(_settlementBalance(CAROL), cleanerSettlementBefore, "retry must not credit the cleaner");
        assertEq(
            router.getAccountReservations(ALICE).executionBountyUsdc, 0, "retry must leave all bounty reserves cleared"
        );
        assertEq(
            clearinghouse.getOrderReservation(parentOrderId).remainingAmountUsdc, 0, "retry must release no margin"
        );
    }

    function test_AttachedOpen_RiskOffClearinghouseFailureRollsBackProtectionAndRouter() public {
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);
        vm.prank(ALICE);
        (uint64 parentOrderId, uint64 protectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );
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
        PositionProtectionTypes.PositionProtectionParams memory params = _params(BULL_TAKE_PROFIT, BULL_STOP_LOSS);

        vm.prank(ALICE);
        (uint64 aliceParentId, uint64 aliceProtectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );
        vm.prank(BOB);
        (uint64 bobParentId, uint64 bobProtectionId) = protectionActions.commitOpenOrderWithProtection(
            CfdTypes.Side.BULL, POSITION_SIZE, POSITION_MARGIN_USDC, 0, params
        );
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

    function _totalProtectionBountyUsdc() internal view returns (uint256) {
        return router.positionProtectionTriggerBountyUsdc() + router.closeOrderExecutionBountyUsdc();
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

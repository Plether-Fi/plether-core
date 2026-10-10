// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";

import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract FadStalenessTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    uint256 constant FRIDAY_18UTC = 1_772_820_000;
    uint256 constant SATURDAY_NOON = 1_772_884_800;
    uint256 constant SUNDAY_21UTC = 1_773_003_600;
    uint256 constant MONDAY_NOON = 1_773_057_600;
    uint256 constant WEDNESDAY_NOON = 1_773_230_400;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
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

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        engine.setTerminalNavBook(address(new TerminalNavBookV2(address(engine), uint32(engine.CAP_PRICE()))));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        engineLens = new CfdEngineLens(address(engine));
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

        _fundJunior(bob, 1_000_000 * 1e6);

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(alice, 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        uint256 WEDNESDAY_BEFORE = FRIDAY_18UTC - 2 days;
        vm.warp(WEDNESDAY_BEFORE);
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), uint64(WEDNESDAY_BEFORE + 6));

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(WEDNESDAY_BEFORE + 50);
        bytes[] memory setupPyth = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, setupPyth);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        require(size == 10_000 * 1e18, "setUp: position not opened");

        vm.warp(FRIDAY_18UTC);
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_18UTC + 6);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _currentTimestamp() internal view returns (uint256 ts) {
        return block.timestamp;
    }

    function _addFadDays(
        uint256[] memory timestamps
    ) internal {
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = timestamps;
        _setCalendarConfig(config);
    }

    function _removeFadDays(
        uint256[] memory
    ) internal {
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](0);
        _setCalendarConfig(config);
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = _engineFreshnessConfig();
        config.fadMaxStaleness = val;
        _setFreshnessConfig(config);
    }

    function _setFadRunway(
        uint256 val
    ) internal {
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadRunwaySeconds = val;
        _setCalendarConfig(config);
    }

    function test_FadWindow_CloseOrder_AllowedDuringFrozenWithPreFreezeCommit() public {
        _startRecordingLogs();
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(fridayClose - 6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(fridayClose + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Close order should execute during frozen oracle");
    }

    function test_FadWindow_OpenOrder_BlockedDuringFrozen() public {
        _startRecordingLogs();
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FadWindow_MevCheckDisabledDuringFrozen() public {
        _startRecordingLogs();
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Frozen-window close should execute without MEV rejection");
    }

    function test_FadWindow_ExcessStaleness_CloseGracefullyCancelled() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_Liquidation_AcceptsStalePrice() public {
        _startRecordingLogs();
        address aliceAccount = alice;
        uint64 fridayPublishTime = uint64(FRIDAY_18UTC + 6);
        vm.prank(address(router));
        engine.updateMarkPrice(180_000_000, uint64(block.timestamp));

        mockPyth.setAllPrices(feedIds, int64(180_000_000), int32(-8), fridayPublishTime);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();

        router.executeLiquidation(aliceAccount, empty);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Liquidation should succeed during FAD with stale price");
        assertEq(
            engine.lastMarkTime(), fridayPublishTime, "Liquidation should accept the frozen-window Friday publish time"
        );
    }

    function test_FadWindow_MarkRefresh_AcceptsStaleFridayPrice() public {
        _startRecordingLogs();
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
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = _pythUpdateData();
        address aliceAccount = alice;

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeLiquidation(aliceAccount, empty);
    }

    function test_FadBatch_CloseAllowedDuringFrozenWithPreFreezeCommit() public {
        _startRecordingLogs();
        uint256 fridayClose = FRIDAY_18UTC + 4 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayClose);

        vm.warp(fridayClose - 6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 0, true);

        vm.warp(fridayClose + 1);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 5000 * 1e18, "Partial close should reduce position");
    }

    function test_FadBatch_ExcessStaleness_FrozenReverts() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        vm.roll(block.number + 1);
        router.executeOrderBatch(2, empty);
    }

    function test_Weekday_CloseExpiresAfterDefaultMaxExecutionWindowSeconds() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 6);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 5000 * 1e18, 0, 0, true);

        vm.warp(WEDNESDAY_NOON + 67);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000 * 1e18, "Expired weekday close should leave the position unchanged");
        assertEq(
            uint256(OrderRouterDebugLens.loadRawOrderRecord(vm, router, 2).status),
            uint256(IOrderRouterAccounting.OrderStatus.None)
        );
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 2);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.Expired));
    }

    function test_Weekday_OpenOrder_Allowed() public {
        _startRecordingLogs();
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(carol, 10_000 * 1e6);
        vm.stopPrank();

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 10);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(WEDNESDAY_NOON + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address carolAccount = carol;
        (uint256 size,,,,,,) = engine.positions(carolAccount);
        assertGt(size, 0, "Weekday open orders should work normally");
    }

    function test_Admin_AddFadDay() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow(), "Wednesday should be FAD after admin override");
    }

    function test_Admin_RemoveFadDay() public {
        _startRecordingLogs();
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
        _startRecordingLogs();
        assertEq(engine.fadMaxStaleness(), 3 days);
        _setFadMaxStaleness(5 days);
        assertEq(engine.fadMaxStaleness(), 5 days);
    }

    function test_Admin_SetFadMaxStaleness_ZeroReverts() public {
        _startRecordingLogs();
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = _engineFreshnessConfig();
        config.fadMaxStaleness = 0;
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__ZeroStaleness.selector);
        engineAdmin.proposeFreshnessConfig(config);
    }

    function test_Admin_AddFadDays_NonOwner_Reverts() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;

        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = timestamps;
        vm.prank(alice);
        vm.expectRevert();
        engineAdmin.proposeCalendarConfig(config);
    }

    function test_Admin_EmptyDays_Reverts() public {
        _startRecordingLogs();
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](0);
        _setCalendarConfig(config);
        assertEq(engine.fadDayOverrides(MONDAY_NOON / 86_400), false);
    }

    function test_AdminFadDay_BlockedDuringFrozen() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = MONDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(MONDAY_NOON);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FridayFadOnly_MevCheckStillActive() public {
        _startRecordingLogs();
        uint256 fridayFadStart = FRIDAY_18UTC + 3 hours + 30 minutes;

        uint256 publishTime = fridayFadStart - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(fridayFadStart);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(fridayFadStart + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(2, empty);
    }

    function test_FridayFadOnly_FreshPriceStillWorks() public {
        _startRecordingLogs();
        uint256 fridayFadStart = FRIDAY_18UTC + 3 hours + 30 minutes;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayFadStart + 6);

        vm.warp(fridayFadStart);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(fridayFadStart + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Close with fresh price should succeed during Friday gap");
    }

    function test_FridayFadOnly_OpenStillBlocked() public {
        _startRecordingLogs();
        uint256 fridayFadStart = FRIDAY_18UTC + 3 hours + 30 minutes;

        vm.warp(fridayFadStart);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_FridayFadOnly_HistoricalSettlementWindowAllowsDelayedReveal() public {
        _startRecordingLogs();
        uint256 fridayFadStart = FRIDAY_18UTC + 3 hours + 30 minutes;

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 300;
        vm.warp(fridayFadStart - 48 hours - 1);
        routerAdmin.proposeRouterConfig(config);
        vm.warp(fridayFadStart);
        routerAdmin.finalizeRouterConfig();

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), fridayFadStart + 1);

        vm.warp(fridayFadStart);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(fridayFadStart + 63);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Historical settlement should use the post-commit tick inside the settlement window");
    }

    function test_SundayDst_OracleUnfrozenAt21() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 6);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Close should succeed at Sunday 21:00 with fresh price");
    }

    function test_SundayDst_MevEnforcedAt21() public {
        _startRecordingLogs();
        uint256 publishTime = SUNDAY_21UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(2, empty);
    }

    function test_SundayDst_StillFadAt21() public {
        _startRecordingLogs();
        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 300 * 1e6, 0.8e8, false);
    }

    function test_SundayDst_PreOpenStalenessRejects() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 12 hours);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(2, empty);
    }

    function test_Runway_FadActivatesBeforeHoliday() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 tuesdayJustOutside = wednesdayMidnight - 1 hours - 1;

        vm.warp(tuesdayJustOutside);
        assertFalse(engine.isFadWindow(), "Before runway: FAD should be inactive");

        uint256 tuesdayRunwayStart = wednesdayMidnight - 1 hours;
        vm.warp(tuesdayRunwayStart);
        assertTrue(engine.isFadWindow(), "At runway start: FAD should be active");

        uint256 duringRunway = wednesdayMidnight - 30 minutes;
        vm.warp(duringRunway);
        assertTrue(engine.isFadWindow(), "During runway: FAD should be active");
    }

    function test_Runway_OracleFrozenOnlyOnHolidayDay() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 runwayStart = wednesdayMidnight - 1 hours;

        vm.warp(runwayStart);
        assertTrue(engine.isFadWindow());

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector);
        router.commitOrder(CfdTypes.Side.SHORT, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), runwayStart + 6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(runwayStart + 50);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 10);
        router.executeOrder(2, empty);

        address aliceAccount = alice;
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Close with fresh price works during runway");
    }

    function test_Runway_MevStillEnforcedDuringRunway() public {
        _startRecordingLogs();
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 runwayTime = wednesdayMidnight - 30 minutes;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), runwayTime - 60);

        vm.warp(runwayTime);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 0, 0, true);

        vm.warp(runwayTime + 30);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(2, empty);
    }

    function test_Runway_SetFadRunway() public {
        _startRecordingLogs();
        assertEq(engine.fadRunwaySeconds(), 1 hours);
        _setFadRunway(6 hours);
        assertEq(engine.fadRunwaySeconds(), 6 hours);
    }

    function test_Runway_TooLong_Reverts() public {
        _startRecordingLogs();
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadRunwaySeconds = 25 hours;
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__RunwayTooLong.selector);
        engineAdmin.proposeCalendarConfig(config);
    }

}

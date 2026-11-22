// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

/// @notice Holiday reopening must restore live prices and ordering while retaining all-day FAD controls.
contract HolidayOverrideRegressionTest is BasePerpTest {

    address internal constant LONG_TRADER = address(0xA11CE);
    address internal constant SHORT_TRADER = address(0xCA201);
    uint256 internal constant SUMMER_REOPEN = 1_773_262_800; // Wednesday 2026-03-11 21:00 UTC.
    uint256 internal constant WINTER_REOPEN = 1_768_428_000; // Wednesday 2026-01-14 22:00 UTC.
    uint256 internal constant PRE_HOLIDAY_PRICE = 80_000_000;
    uint256 internal constant SIZE = 400_000e18;
    uint256 internal constant MARGIN = 20_000e6;
    uint256 internal constant DEPOSIT = 40_000e6;

    function setUp() public override {
        super.setUp();
        _fundTrader(LONG_TRADER, DEPOSIT);
        _fundTrader(SHORT_TRADER, DEPOSIT);
    }

    function test_HolidayBeforeReopen_PreservesFrozenMarkAndSameBlockClose() public {
        _prepareHoliday(SUMMER_REOPEN, false);
        vm.warp(SUMMER_REOPEN - 1);
        assertTrue(engine.isOracleFrozen());
        assertTrue(engine.isFadWindow());

        router.updateMarkPrice(_payload(78_400_000, SUMMER_REOPEN - 1, SUMMER_REOPEN - 2));
        assertEq(engine.lastMarkPrice(), PRE_HOLIDAY_PRICE, "closed-market refresh must replay the frozen mark");

        vm.prank(LONG_TRADER);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 0, 0, true);
        _startRecordingLogs();
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder(closeId, _payload(78_400_000, SUMMER_REOPEN - 1, SUMMER_REOPEN - 2));
        _assertExecuted(result);
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), closeId);
        assertEq(receipt.executionPrice, PRE_HOLIDAY_PRICE);
        assertEq(uint8(receipt.executionMode), uint8(OrderV3Types.ExecutionMode.Frozen));
        assertGt(receipt.economics.frozenSpreadAssets, 0);
        assertEq(_positionSize(LONG_TRADER), 0);
    }

    function test_HolidaySummerReopen_AcceptsFreshMarkAtBoundary() public {
        _assertReopenAcceptsFreshMark(SUMMER_REOPEN);
    }

    function test_HolidayWinterReopen_AcceptsFreshMarkAtBoundary() public {
        _assertReopenAcceptsFreshMark(WINTER_REOPEN);
    }

    function test_HolidayReopen_MissingFreshPricesCannotReplayHolidayMark() public {
        _prepareHoliday(SUMMER_REOPEN, false);
        vm.warp(SUMMER_REOPEN);
        assertFalse(engine.isOracleFrozen());

        bytes[] memory noUpdate = new bytes[](0);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.updateMarkPrice(noUpdate);
        assertEq(engine.lastMarkPrice(), PRE_HOLIDAY_PRICE);

        vm.prank(LONG_TRADER);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 0, 0, true);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(SUMMER_REOPEN + 2);
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder(closeId, _payload(PRE_HOLIDAY_PRICE, SUMMER_REOPEN - 1 days, 0));
        _assertPending(result, OrderV3Types.PendingReason.HistoricalPriceUnavailable);
        assertEq(_positionSize(LONG_TRADER), SIZE, "missing history must leave the close pending");
    }

    function test_HolidayReopen_RestoresSameBlockAndPostCommitPriceRequirements() public {
        _prepareHoliday(SUMMER_REOPEN, false);
        vm.warp(SUMMER_REOPEN + 30 minutes);
        uint256 commitTime = vm.getBlockTimestamp();
        vm.prank(LONG_TRADER);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 0, 0, true);

        // A valid post-commit tick alone does not permit execution in the commitment block.
        vm.warp(commitTime + 1);
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder(closeId, _payload(78_400_000, commitTime + 1, commitTime));
        _assertPending(result, OrderV3Types.PendingReason.SameBlock);
        assertEq(_positionSize(LONG_TRADER), SIZE);

        vm.roll(vm.getBlockNumber() + 1);
        // Neither a pre-commit nor an equal-commit tick can become a frozen-price close.
        result = router.executeOrder(closeId, _payload(PRE_HOLIDAY_PRICE, commitTime - 1, commitTime - 2));
        _assertPending(result, OrderV3Types.PendingReason.HistoricalPriceUnavailable);
        result = router.executeOrder(closeId, _payload(PRE_HOLIDAY_PRICE, commitTime, commitTime - 1));
        _assertPending(result, OrderV3Types.PendingReason.HistoricalPriceUnavailable);
        assertEq(_positionSize(LONG_TRADER), SIZE);

        _startRecordingLogs();
        result = router.executeOrder(closeId, _payload(78_400_000, commitTime + 1, commitTime));
        _assertExecuted(result);
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), closeId);
        assertEq(receipt.executionPrice, 78_400_000, "close must receive the reopened market price");
        assertEq(uint8(receipt.executionMode), uint8(OrderV3Types.ExecutionMode.Fad));
        assertEq(receipt.economics.frozenSpreadAssets, 0);
        assertEq(_positionSize(LONG_TRADER), 0);
    }

    function test_HolidayGapDown_HedgedBookCannotExtractFromLps() public {
        _assertHedgedBookPaysOnlyCosts(78_400_000);
    }

    function test_HolidayGapUp_HedgedBookCannotExtractFromLps() public {
        _assertHedgedBookPaysOnlyCosts(81_600_000);
    }

    function _assertReopenAcceptsFreshMark(
        uint256 reopen
    ) internal {
        _prepareHoliday(reopen, false);
        vm.warp(reopen - 1);
        assertTrue(engine.isOracleFrozen());
        vm.warp(reopen);
        assertFalse(engine.isOracleFrozen(), "holiday freeze must end at the New York reopen");
        assertFalse(pletherOracle.isOracleFrozen());
        assertTrue(engine.isFadWindow(), "holiday FAD controls remain active through midnight");

        router.updateMarkPrice(_payload(78_400_000, reopen, reopen - 1));
        assertEq(engine.lastMarkPrice(), 78_400_000);
        assertEq(engine.lastMarkTime(), reopen);
    }

    function _assertHedgedBookPaysOnlyCosts(
        uint256 reopenPrice
    ) internal {
        _prepareHoliday(SUMMER_REOPEN, true);
        // LONG profits when this protocol's basket falls, so SHORT is the losing leg for a downward gap.
        CfdTypes.Side losingSide = reopenPrice < PRE_HOLIDAY_PRICE ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        address loser = losingSide == CfdTypes.Side.LONG ? LONG_TRADER : SHORT_TRADER;
        address winner = loser == LONG_TRADER ? SHORT_TRADER : LONG_TRADER;
        CfdTypes.Side winningSide = losingSide == CfdTypes.Side.LONG ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;

        _startRecordingLogs();
        uint64 losingClose = _liveOrder(loser, losingSide, true, reopenPrice, SUMMER_REOPEN + 30 minutes);
        uint256 nextDay = SUMMER_REOPEN / 1 days * 1 days + 1 days;
        uint64 winningClose = _liveOrder(winner, winningSide, true, reopenPrice, nextDay + 30);
        OrderV3Types.OrderReceipt memory losingReceipt = _verifiedReceipt(router.lifecycleBook(), losingClose);
        OrderV3Types.OrderReceipt memory winningReceipt = _verifiedReceipt(router.lifecycleBook(), winningClose);

        assertEq(losingReceipt.executionPrice, reopenPrice, "losing leg cannot use the pre-holiday mark");
        assertLt(losingReceipt.economics.realizedPnlAssets, 0, "the losing leg must recognize the market loss");
        assertEq(losingReceipt.economics.realizedPnlAssets + winningReceipt.economics.realizedPnlAssets, 0);
        int256 net = int256(
            _settlementBalance(LONG_TRADER) + _settlementBalance(SHORT_TRADER)
                + engine.traderClaimBalanceAssets(LONG_TRADER) + engine.traderClaimBalanceAssets(SHORT_TRADER)
        ) - int256(2 * DEPOSIT);
        assertLt(net, 0, "opposite positions must pay costs instead of extracting the holiday gap");
        assertGt(net, -2000e6, "the round trip should only incur ordinary fees and carry");
        assertEq(_positionSize(LONG_TRADER), 0);
        assertEq(_positionSize(SHORT_TRADER), 0);
    }

    function _prepareHoliday(
        uint256 reopen,
        bool balancedBook
    ) internal {
        uint256 dayStart = reopen / 1 days * 1 days;
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](1);
        config.fadDayTimestamps[0] = dayStart + 12 hours;
        _setCalendarConfig(config);

        _liveOrder(LONG_TRADER, CfdTypes.Side.LONG, false, PRE_HOLIDAY_PRICE, dayStart - 12 hours);
        if (balancedBook) {
            _liveOrder(SHORT_TRADER, CfdTypes.Side.SHORT, false, PRE_HOLIDAY_PRICE, dayStart - 12 hours + 10 minutes);
        }
        vm.warp(dayStart - 1 hours);
        router.updateMarkPrice(_payload(PRE_HOLIDAY_PRICE, dayStart - 1 hours, dayStart - 12 hours));
        assertEq(engine.lastMarkPrice(), PRE_HOLIDAY_PRICE);
        assertEq(engine.lastMarkTime(), dayStart - 1 hours);
    }

    function _liveOrder(
        address trader,
        CfdTypes.Side side,
        bool isClose,
        uint256 price,
        uint256 at
    ) internal returns (uint64 orderId) {
        vm.warp(at);
        vm.prank(trader);
        orderId = router.commitOrder(side, SIZE, isClose ? 0 : MARGIN, 0, isClose);
        vm.warp(at + 2);
        vm.roll(vm.getBlockNumber() + 1);
        _assertExecuted(router.executeOrder(orderId, _payload(price, at + 1, at)));
    }

    function _payload(
        uint256 price,
        uint256 publishTime,
        uint256 previousPublishTime
    ) internal pure returns (bytes[] memory updateData) {
        bytes32[] memory feedIds = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](feedIds.length);
        for (uint256 i; i < feedIds.length; ++i) {
            ticks[i] = MockPyth.FeedUpdate(
                feedIds[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, publishTime, previousPublishTime)
            );
        }
        updateData = new bytes[](1);
        updateData[0] = abi.encode(ticks);
    }

    function _positionSize(
        address trader
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(trader);
    }

    function _assertExecuted(
        OrderV3Types.ExecutionResult memory result
    ) internal pure {
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "order must execute");
    }

    function _assertPending(
        OrderV3Types.ExecutionResult memory result,
        OrderV3Types.PendingReason reason
    ) internal pure {
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(reason));
    }

}

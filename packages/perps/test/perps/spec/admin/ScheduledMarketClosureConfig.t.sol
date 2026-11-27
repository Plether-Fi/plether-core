// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {SettlementMonitorLensTestFixture} from "../../shared/SettlementMonitorLensFixture.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

contract ScheduledMarketClosureConfigTest is SettlementMonitorLensTestFixture {

    uint64 private constant MONDAY = 1_796_655_600; // December 7, 2026 at 15:00 UTC.
    uint64 private constant TUESDAY = MONDAY + 1 days;
    uint64 private constant FRIDAY_CLOSE = 1_797_026_400; // December 11, 2026 at 22:00 UTC.

    function test_MarketClosureReplacementChangesActiveCalendarOnlyAfterFinalization() public {
        _setCalendarConfig(_singleClosure(MONDAY, MONDAY + 2 hours));
        uint64 activeVersion = engineAdmin.activeConfigVersion();
        bytes32 activeDigest = monitorLens.observableConfigDigest();
        assertNotEq(activeDigest, bytes32(0));

        uint256 replaceAt = MONDAY + 30 minutes;
        vm.warp(replaceAt - engineAdmin.TIMELOCK_DELAY());
        engineAdmin.proposeCalendarConfig(_singleClosure(TUESDAY, TUESDAY + 1 hours));
        assertEq(engineAdmin.calendarConfigActivationTime(), replaceAt);

        vm.warp(replaceAt - 1);
        assertTrue(engine.isOracleFrozen(), "the prior interval remains active while replacement is pending");
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TimelockNotReady.selector);
        engineAdmin.finalizeCalendarConfig();
        assertEq(engineAdmin.activeConfigVersion(), activeVersion);
        assertEq(monitorLens.observableConfigDigest(), activeDigest);

        vm.warp(replaceAt);
        assertTrue(engine.isOracleFrozen(), "reaching the timelock does not apply the proposal");
        engineAdmin.finalizeCalendarConfig();
        assertFalse(engine.isOracleFrozen(), "finalization removes the prior interval");
        assertEq(engineAdmin.getPendingCalendarConfig().marketClosures.length, 0);
        assertEq(engine.marketClosureCount(), 1);
        (uint64 start, uint64 end) = engine.marketClosures(0);
        assertEq(start, TUESDAY);
        assertEq(end, TUESDAY + 1 hours);
        assertEq(engineAdmin.activeConfigVersion(), activeVersion + 1);
        bytes32 replacementDigest = monitorLens.observableConfigDigest();
        assertNotEq(replacementDigest, bytes32(0));
        assertNotEq(replacementDigest, activeDigest);

        _assertCalendar(TUESDAY, true, true);
        _assertCalendar(TUESDAY + 1 hours, true, false);
    }

    function test_CancelledReplacementKeepsMarketClosuresAndFinalizedEmptyConfigClearsThem() public {
        uint64 followingMonday = MONDAY + 7 days;
        ICfdEngineAdminHost.EngineCalendarConfig memory schedule = _config(2);
        schedule.marketClosures[0] = _closure(MONDAY, MONDAY + 1 hours);
        schedule.marketClosures[1] = _closure(followingMonday, followingMonday + 1 hours);
        _setCalendarConfig(schedule);
        uint64 activeVersion = engineAdmin.activeConfigVersion();

        engineAdmin.proposeCalendarConfig(_singleClosure(TUESDAY, TUESDAY + 1 hours));
        engineAdmin.cancelCalendarConfig();
        assertEq(engineAdmin.calendarConfigActivationTime(), 0);
        assertEq(engineAdmin.getPendingCalendarConfig().marketClosures.length, 0);
        assertEq(engineAdmin.activeConfigVersion(), activeVersion);
        _assertCalendar(MONDAY, true, true);
        _assertCalendar(TUESDAY, false, false);

        uint256 replaceAt = followingMonday + 30 minutes;
        vm.warp(replaceAt - engineAdmin.TIMELOCK_DELAY());
        engineAdmin.proposeCalendarConfig(_config(0));
        vm.warp(replaceAt);
        assertTrue(engine.isOracleFrozen(), "an empty pending schedule cannot clear the active interval");
        engineAdmin.finalizeCalendarConfig();
        assertFalse(engine.isOracleFrozen());
        assertFalse(engine.isFadWindow());
        assertEq(engine.marketClosureCount(), 0);
        assertEq(engineAdmin.activeConfigVersion(), activeVersion + 1);
    }

    function test_InvalidMarketClosuresCannotReplacePendingSchedule() public {
        ICfdEngineAdminHost.EngineCalendarConfig memory valid = _singleClosure(MONDAY, MONDAY + 1 hours);
        engineAdmin.proposeCalendarConfig(valid);
        uint256 activation = engineAdmin.calendarConfigActivationTime();

        ICfdEngineAdminHost.EngineCalendarConfig memory invalid = _singleClosure(MONDAY, MONDAY);
        _expectInvalidClosure(invalid, 0);
        invalid.marketClosures[0].endTime = MONDAY - 1;
        _expectInvalidClosure(invalid, 0);

        invalid = _config(2);
        invalid.marketClosures[0] = valid.marketClosures[0];
        invalid.marketClosures[1] = _closure(MONDAY + 30 minutes, MONDAY + 2 hours);
        _expectInvalidClosure(invalid, 1);
        invalid.marketClosures[1] = _closure(MONDAY - 2 hours, MONDAY - 1 hours);
        _expectInvalidClosure(invalid, 1);

        invalid = _config(engineAdmin.MAX_MARKET_CLOSURES() + 1);
        vm.expectRevert(CfdEngineAdmin.CfdEngineAdmin__TooManyMarketClosures.selector);
        engineAdmin.proposeCalendarConfig(invalid);

        assertEq(engineAdmin.calendarConfigActivationTime(), activation);
        ICfdEngineAdminHost.EngineCalendarConfig memory pending = engineAdmin.getPendingCalendarConfig();
        assertEq(pending.marketClosures.length, 1);
        assertEq(pending.marketClosures[0].startTime, MONDAY);
        assertEq(pending.marketClosures[0].endTime, MONDAY + 1 hours);
        vm.warp(activation);
        engineAdmin.finalizeCalendarConfig();
        _assertCalendar(MONDAY, true, true);
    }

    function test_MarketClosureGapIsUnfrozenAndAdjacentIntervalsStayFrozen() public {
        uint64 firstEnd = MONDAY + 1 hours;
        uint64 secondStart = firstEnd + 10 minutes;
        uint64 secondEnd = secondStart + 1 hours;
        uint64 thirdEnd = secondEnd + 1 hours;
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _config(3);
        config.fadRunwaySeconds = 0;
        config.marketClosures[0] = _closure(MONDAY, firstEnd);
        config.marketClosures[1] = _closure(secondStart, secondEnd);
        config.marketClosures[2] = _closure(secondEnd, thirdEnd);
        _setCalendarConfig(config);

        _assertCalendar(MONDAY - 1, false, false);
        _assertCalendar(MONDAY, true, true);
        _assertCalendar(firstEnd, true, false);
        _assertCalendar(secondStart - 1, true, false);
        _assertCalendar(secondStart, true, true);
        _assertCalendar(secondEnd, true, true);
        _assertCalendar(thirdEnd, true, false);
        _assertCalendar(thirdEnd + 15 minutes, false, false);
    }

    function test_MarketClosureEndDoesNotThawOverlappingRecurringWeekend() public {
        uint64 start = FRIDAY_CLOSE - 15 minutes;
        uint64 end = FRIDAY_CLOSE + 15 minutes;
        _setCalendarConfig(_singleClosure(start, end));

        _assertCalendar(start - 1, true, false);
        _assertCalendar(start, true, true);
        _assertCalendar(end, true, true);
        _assertCalendar(FRIDAY_CLOSE + 2 days, true, false);
        _assertCalendar(FRIDAY_CLOSE + 2 days + 15 minutes, false, false);
    }

    function _assertCalendar(
        uint256 timestamp,
        bool fad,
        bool frozen
    ) private {
        vm.warp(timestamp);
        assertEq(engine.isFadWindow(), fad);
        assertEq(engine.isOracleFrozen(), frozen);
    }

    function _expectInvalidClosure(
        ICfdEngineAdminHost.EngineCalendarConfig memory config,
        uint256 index
    ) private {
        vm.expectRevert(abi.encodeWithSelector(CfdEngineAdmin.CfdEngineAdmin__InvalidMarketClosure.selector, index));
        engineAdmin.proposeCalendarConfig(config);
    }

    function _singleClosure(
        uint64 start,
        uint64 end
    ) private view returns (ICfdEngineAdminHost.EngineCalendarConfig memory config) {
        config = _config(1);
        config.marketClosures[0] = _closure(start, end);
    }

    function _config(
        uint256 count
    ) private view returns (ICfdEngineAdminHost.EngineCalendarConfig memory config) {
        config = _engineCalendarConfig();
        config.marketClosures = new ICfdEngineAdminHost.MarketClosure[](count);
    }

    function _closure(
        uint64 start,
        uint64 end
    ) private pure returns (ICfdEngineAdminHost.MarketClosure memory) {
        return ICfdEngineAdminHost.MarketClosure({startTime: start, endTime: end});
    }

}

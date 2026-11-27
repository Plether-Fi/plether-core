// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {Test} from "forge-std/Test.sol";

contract MarketCalendarHarness {

    function marketStatus(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) external pure returns (bool fadWindow, bool oracleFrozen) {
        return MarketCalendarLib.marketStatus(timestamp, todayOverride, tomorrowOverride, fadRunwaySeconds);
    }

    function isFadWindow(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) external pure returns (bool) {
        (bool fadWindow,) = MarketCalendarLib.marketStatus(timestamp, todayOverride, tomorrowOverride, fadRunwaySeconds);
        return fadWindow;
    }

    function isOracleFrozen(
        uint256 timestamp,
        bool todayOverride
    ) external pure returns (bool) {
        (, bool frozen) = MarketCalendarLib.marketStatus(timestamp, todayOverride, false, 0);
        return frozen;
    }

    function newYorkMarketBoundary(
        uint256 timestamp
    ) external pure returns (uint256) {
        uint256 dayOfWeek = ((timestamp / 86_400) + 4) % 7;
        return MarketCalendarLib.newYorkMarketBoundary(timestamp, dayOfWeek);
    }

}

contract MarketCalendarLibTest is Test {

    MarketCalendarHarness internal calendar = new MarketCalendarHarness();

    function test_OracleFrozen_UsesSummerDaylightTimeBoundaries() public view {
        assertFalse(calendar.isOracleFrozen(1_784_926_799, false)); // Friday 2026-07-24 20:59:59 UTC
        assertTrue(calendar.isOracleFrozen(1_784_926_800, false)); // Friday 2026-07-24 21:00:00 UTC
        assertTrue(calendar.isOracleFrozen(1_785_099_599, false)); // Sunday 2026-07-26 20:59:59 UTC
        assertFalse(calendar.isOracleFrozen(1_785_099_600, false)); // Sunday 2026-07-26 21:00:00 UTC
    }

    function test_OracleFrozen_UsesWinterStandardTimeBoundaries() public view {
        assertFalse(calendar.isOracleFrozen(1_768_600_799, false)); // Friday 2026-01-16 21:59:59 UTC
        assertTrue(calendar.isOracleFrozen(1_768_600_800, false)); // Friday 2026-01-16 22:00:00 UTC
        assertTrue(calendar.isOracleFrozen(1_768_773_599, false)); // Sunday 2026-01-18 21:59:59 UTC
        assertFalse(calendar.isOracleFrozen(1_768_773_600, false)); // Sunday 2026-01-18 22:00:00 UTC
    }

    function test_OracleFrozen_SpringTransitionWeekendUsesDifferentOffsets() public view {
        assertFalse(calendar.isOracleFrozen(1_772_834_399, false)); // Friday 2026-03-06 21:59:59 UTC
        assertTrue(calendar.isOracleFrozen(1_772_834_400, false)); // Friday 2026-03-06 22:00:00 UTC
        assertTrue(calendar.isOracleFrozen(1_773_003_599, false)); // Sunday 2026-03-08 20:59:59 UTC
        assertFalse(calendar.isOracleFrozen(1_773_003_600, false)); // Sunday 2026-03-08 21:00:00 UTC
    }

    function test_OracleFrozen_FallTransitionWeekendUsesDifferentOffsets() public view {
        assertFalse(calendar.isOracleFrozen(1_793_393_999, false)); // Friday 2026-10-30 20:59:59 UTC
        assertTrue(calendar.isOracleFrozen(1_793_394_000, false)); // Friday 2026-10-30 21:00:00 UTC
        assertTrue(calendar.isOracleFrozen(1_793_570_399, false)); // Sunday 2026-11-01 21:59:59 UTC
        assertFalse(calendar.isOracleFrozen(1_793_570_400, false)); // Sunday 2026-11-01 22:00:00 UTC
    }

    function test_FadWindow_DerivesSpringTransitionShouldersFromFxBoundary() public view {
        assertFalse(calendar.isFadWindow(1_772_833_799, false, false, 0)); // Friday 21:49:59 UTC
        assertTrue(calendar.isFadWindow(1_772_833_800, false, false, 0)); // Friday 21:50:00 UTC
        assertFalse(calendar.isOracleFrozen(1_772_833_800, false));

        assertFalse(calendar.isOracleFrozen(1_773_003_600, false)); // Sunday 21:00:00 UTC
        assertTrue(calendar.isFadWindow(1_773_003_899, false, false, 0)); // Sunday 21:04:59 UTC
        assertFalse(calendar.isFadWindow(1_773_003_900, false, false, 0)); // Sunday 21:05:00 UTC
    }

    function test_FadWindow_DerivesFallTransitionShouldersFromFxBoundary() public view {
        assertFalse(calendar.isFadWindow(1_793_393_399, false, false, 0)); // Friday 20:49:59 UTC
        assertTrue(calendar.isFadWindow(1_793_393_400, false, false, 0)); // Friday 20:50:00 UTC
        assertFalse(calendar.isOracleFrozen(1_793_393_400, false));

        assertFalse(calendar.isOracleFrozen(1_793_570_400, false)); // Sunday 22:00:00 UTC
        assertTrue(calendar.isFadWindow(1_793_570_699, false, false, 0)); // Sunday 22:04:59 UTC
        assertFalse(calendar.isFadWindow(1_793_570_700, false, false, 0)); // Sunday 22:05:00 UTC
    }

    function test_OverridesRemainUtcDayBased() public view {
        uint256 wednesdayNoon = 1_784_721_600; // Wednesday 2026-07-22 12:00:00 UTC
        assertTrue(calendar.isOracleFrozen(wednesdayNoon, true));
        assertTrue(calendar.isFadWindow(wednesdayNoon, true, false, 0));
        assertFalse(calendar.isOracleFrozen(wednesdayNoon, false));
        assertFalse(calendar.isFadWindow(wednesdayNoon, false, false, 0));
    }

    function test_OverrideFrozen_EndsAtNewYorkReopenEveryWeekday() public view {
        _assertOverrideWeek(1_784_505_600, 21 hours); // Monday 2026-07-20, daylight time
        _assertOverrideWeek(1_768_176_000, 22 hours); // Monday 2026-01-12, standard time
    }

    function test_OverrideFrozen_ConsecutiveDaysThawBeforeUtcMidnight() public view {
        uint256[2] memory days_ = [uint256(1_784_678_400), uint256(1_768_348_800)];
        uint256[2] memory boundaries = [uint256(21 hours), uint256(22 hours)];
        for (uint256 season; season < days_.length; ++season) {
            uint256 dayStart = days_[season];
            (bool fad, bool frozen) = calendar.marketStatus(dayStart + boundaries[season], true, true, 24 hours);
            assertTrue(fad, "The override keeps FAD active after reopening");
            assertFalse(frozen, "Tomorrow's override must not extend today's closure");
            (fad, frozen) = calendar.marketStatus(dayStart + 1 days - 1, true, true, 24 hours);
            assertTrue(fad);
            assertFalse(frozen, "The tail remains live through the last UTC second");
            (fad, frozen) = calendar.marketStatus(dayStart + 1 days, true, false, 24 hours);
            assertTrue(fad);
            assertTrue(frozen, "The next overridden UTC day starts a new closure");
            (fad, frozen) = calendar.marketStatus(dayStart + 1 days + boundaries[season], true, false, 24 hours);
            assertTrue(fad);
            assertFalse(frozen, "The next override also ends at its reopening boundary");
            (fad, frozen) = calendar.marketStatus(dayStart + 2 days, false, false, 24 hours);
            assertFalse(fad, "All-day FAD ends when the last overridden UTC day ends");
            assertFalse(frozen);
        }
    }

    function test_OverrideFrozen_DstSundayReopensAtAdjustedBoundary() public view {
        uint256[2] memory sundays = [uint256(1_772_928_000), uint256(1_793_491_200)];
        uint256[2] memory boundaries = [uint256(21 hours), uint256(22 hours)];
        for (uint256 season; season < sundays.length; ++season) {
            uint256 reopen = sundays[season] + boundaries[season];
            assertTrue(calendar.isOracleFrozen(reopen - 1, true));
            assertFalse(calendar.isOracleFrozen(reopen, true));
            assertFalse(calendar.isOracleFrozen(reopen + 1, true));
            assertTrue(calendar.isFadWindow(reopen + 1 hours, true, false, 0));
        }
    }

    function test_FadRunway_NeverFreezesThePreOverrideTail() public view {
        uint256 tail = 1_784_678_400 - 1; // Tuesday 2026-07-21 23:59:59 UTC
        (bool fad, bool frozen) = calendar.marketStatus(tail, false, true, 1 hours);
        assertTrue(fad, "The next day's override activates only FAD during its runway");
        assertFalse(frozen, "The runway must keep ordinary oracle freshness checks");
    }

    function _assertOverrideWeek(
        uint256 monday,
        uint256 marketBoundary
    ) internal view {
        for (uint256 weekday; weekday < 7; ++weekday) {
            uint256 dayStart = monday + weekday * 1 days;
            uint256 reopen = dayStart + marketBoundary;
            bool recurringWeekendClosure = weekday == 4 || weekday == 5;
            assertTrue(calendar.isOracleFrozen(dayStart, true), "Every override starts frozen at UTC midnight");
            assertTrue(calendar.isOracleFrozen(reopen - 1, true), "The override stays frozen before reopening");
            assertEq(calendar.isOracleFrozen(reopen, true), recurringWeekendClosure, "Reopening is inclusive");
            assertEq(calendar.isOracleFrozen(reopen + 1, true), recurringWeekendClosure);
            assertEq(calendar.isOracleFrozen(dayStart + 1 days - 1, true), recurringWeekendClosure);
            assertTrue(calendar.isFadWindow(dayStart, true, false, 0));
            assertTrue(calendar.isFadWindow(reopen, true, false, 0), "FAD survives the oracle reopening");
            assertTrue(calendar.isFadWindow(dayStart + 1 days - 1, true, false, 0));
        }
    }

    function test_NewYorkDst_TransitionInstantsAreInclusiveAndExclusive() public view {
        assertEq(calendar.newYorkMarketBoundary(1_772_953_199), 22 hours); // March 08 06:59:59 UTC
        assertEq(calendar.newYorkMarketBoundary(1_772_953_200), 21 hours); // March 08 07:00:00 UTC
        assertEq(calendar.newYorkMarketBoundary(1_793_512_799), 21 hours); // November 01 05:59:59 UTC
        assertEq(calendar.newYorkMarketBoundary(1_793_512_800), 22 hours); // November 01 06:00:00 UTC
    }

    function test_FadRunway_StartsExactlyAtConfiguredLookAhead() public view {
        assertFalse(calendar.isFadWindow(1_784_674_799, false, true, 1 hours)); // Tuesday 22:59:59 UTC
        assertTrue(calendar.isFadWindow(1_784_674_800, false, true, 1 hours)); // Tuesday 23:00:00 UTC
    }

    function test_OracleFrozen_Handles2100NonLeapYear() public view {
        assertFalse(calendar.isOracleFrozen(4_108_571_999, false)); // Friday 2100-03-12 21:59:59 UTC
        assertTrue(calendar.isOracleFrozen(4_108_572_000, false)); // Friday 2100-03-12 22:00:00 UTC
        assertTrue(calendar.isOracleFrozen(4_108_741_199, false)); // Sunday 2100-03-14 20:59:59 UTC
        assertFalse(calendar.isOracleFrozen(4_108_741_200, false)); // Sunday 2100-03-14 21:00:00 UTC
    }

    function test_OracleFrozen_Handles2400LeapYear() public view {
        assertFalse(calendar.isOracleFrozen(13_575_506_399, false)); // Friday 2400-03-10 21:59:59 UTC
        assertTrue(calendar.isOracleFrozen(13_575_506_400, false)); // Friday 2400-03-10 22:00:00 UTC
        assertTrue(calendar.isOracleFrozen(13_575_675_599, false)); // Sunday 2400-03-12 20:59:59 UTC
        assertFalse(calendar.isOracleFrozen(13_575_675_600, false)); // Sunday 2400-03-12 21:00:00 UTC
    }

}

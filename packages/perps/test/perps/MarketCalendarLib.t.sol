// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {Test} from "forge-std/Test.sol";

contract MarketCalendarHarness {

    function isFadWindow(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) external pure returns (bool) {
        return MarketCalendarLib.isFadWindow(timestamp, todayOverride, tomorrowOverride, fadRunwaySeconds);
    }

    function isOracleFrozen(
        uint256 timestamp,
        bool todayOverride
    ) external pure returns (bool) {
        return MarketCalendarLib.isOracleFrozen(timestamp, todayOverride);
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
        assertFalse(calendar.isFadWindow(1_772_832_599, false, false, 0)); // Friday 21:29:59 UTC
        assertTrue(calendar.isFadWindow(1_772_832_600, false, false, 0)); // Friday 21:30:00 UTC
        assertFalse(calendar.isOracleFrozen(1_772_832_600, false));

        assertFalse(calendar.isOracleFrozen(1_773_003_600, false)); // Sunday 21:00:00 UTC
        assertTrue(calendar.isFadWindow(1_773_004_499, false, false, 0)); // Sunday 21:14:59 UTC
        assertFalse(calendar.isFadWindow(1_773_004_500, false, false, 0)); // Sunday 21:15:00 UTC
    }

    function test_FadWindow_DerivesFallTransitionShouldersFromFxBoundary() public view {
        assertFalse(calendar.isFadWindow(1_793_392_199, false, false, 0)); // Friday 20:29:59 UTC
        assertTrue(calendar.isFadWindow(1_793_392_200, false, false, 0)); // Friday 20:30:00 UTC
        assertFalse(calendar.isOracleFrozen(1_793_392_200, false));

        assertFalse(calendar.isOracleFrozen(1_793_570_400, false)); // Sunday 22:00:00 UTC
        assertTrue(calendar.isFadWindow(1_793_571_299, false, false, 0)); // Sunday 22:14:59 UTC
        assertFalse(calendar.isFadWindow(1_793_571_300, false, false, 0)); // Sunday 22:15:00 UTC
    }

    function test_OverridesRemainUtcDayBased() public view {
        uint256 wednesdayNoon = 1_784_721_600; // Wednesday 2026-07-22 12:00:00 UTC
        assertTrue(calendar.isOracleFrozen(wednesdayNoon, true));
        assertTrue(calendar.isFadWindow(wednesdayNoon, true, false, 0));
        assertFalse(calendar.isOracleFrozen(wednesdayNoon, false));
        assertFalse(calendar.isFadWindow(wednesdayNoon, false, false, 0));
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

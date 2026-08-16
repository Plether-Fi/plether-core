// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title MarketCalendarLib
/// @notice Evaluates recurring weekend and governance-configured perps risk-control windows.
library MarketCalendarLib {

    /// @dev Number of seconds in a UTC day.
    uint256 internal constant SECONDS_PER_DAY = 86_400;
    /// @dev UTC second-of-day of the 17:00 New York FX boundary while daylight saving time is active.
    uint256 internal constant NEW_YORK_DST_MARKET_BOUNDARY = 21 hours;
    /// @dev UTC second-of-day of the 17:00 New York FX boundary while standard time is active.
    uint256 internal constant NEW_YORK_STANDARD_MARKET_BOUNDARY = 22 hours;
    /// @dev FAD starts this long before the Friday FX close.
    uint256 internal constant FAD_LEAD = 30 minutes;
    /// @dev FAD remains active this long after the Sunday FX open.
    uint256 internal constant FAD_LAG = 15 minutes;
    /// @dev New York enters daylight saving time at 02:00 local standard time (07:00 UTC).
    uint256 internal constant NEW_YORK_DST_START_UTC = 7 hours;
    /// @dev New York returns to standard time at 02:00 local daylight time (06:00 UTC).
    uint256 internal constant NEW_YORK_DST_END_UTC = 6 hours;

    /// @notice Returns whether Friday Afternoon Deleverage controls are active at a timestamp.
    /// @dev The recurring window starts 30 minutes before Friday's 17:00 New York FX close and ends 15 minutes after
    ///      Sunday's 17:00 New York FX open. A configured override activates FAD for its entire UTC day;
    ///      `fadRunwaySeconds` may also activate FAD before an overridden following day.
    /// @param timestamp Timestamp to classify.
    /// @param todayOverride Whether the timestamp's UTC day is an admin-configured FAD day.
    /// @param tomorrowOverride Whether the following UTC day is an admin-configured FAD day.
    /// @param fadRunwaySeconds Lead time before a configured following day, in seconds.
    /// @return Whether FAD controls are active.
    function isFadWindow(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) internal pure returns (bool) {
        (bool fadWindow,) = marketStatus(timestamp, todayOverride, tomorrowOverride, fadRunwaySeconds);
        return fadWindow;
    }

    /// @notice Returns whether the calendar permits operation with a frozen oracle at a timestamp.
    /// @dev The recurring window follows Pyth's FX hours: Friday 17:00 New York time through Sunday 16:59:59 New York
    ///      time. The UTC boundary is 21:00 during US daylight saving time and 22:00 during US standard time. A
    ///      configured override freezes the oracle regime for its entire UTC day; unlike FAD, the runway does not
    ///      extend this window.
    /// @param timestamp Timestamp to classify.
    /// @param todayOverride Whether the timestamp's UTC day is an admin-configured frozen-oracle day.
    /// @return Whether the frozen-oracle regime is active.
    function isOracleFrozen(
        uint256 timestamp,
        bool todayOverride
    ) internal pure returns (bool) {
        (, bool oracleFrozen) = marketStatus(timestamp, todayOverride, false, 0);
        return oracleFrozen;
    }

    /// @notice Returns both recurring market-calendar regimes with one New York boundary calculation.
    /// @param timestamp Timestamp to classify.
    /// @param todayOverride Whether the timestamp's UTC day is an admin-configured FAD and frozen-oracle day.
    /// @param tomorrowOverride Whether the following UTC day is an admin-configured FAD and frozen-oracle day.
    /// @param fadRunwaySeconds Look-ahead interval before an overridden following UTC day.
    /// @return fadWindow Whether FAD controls are active.
    /// @return oracleFrozen Whether frozen-oracle policy is active.
    function marketStatus(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) internal pure returns (bool fadWindow, bool oracleFrozen) {
        (uint256 dayOfWeek, uint256 secondOfDay) = _dayAndSecond(timestamp);

        if (dayOfWeek == 5) {
            uint256 marketBoundary = newYorkMarketBoundary(timestamp, dayOfWeek);
            fadWindow = secondOfDay >= marketBoundary - FAD_LEAD;
            oracleFrozen = secondOfDay >= marketBoundary;
        } else if (dayOfWeek == 6) {
            fadWindow = true;
            oracleFrozen = true;
        } else if (dayOfWeek == 0) {
            uint256 marketBoundary = newYorkMarketBoundary(timestamp, dayOfWeek);
            fadWindow = secondOfDay < marketBoundary + FAD_LAG;
            oracleFrozen = secondOfDay < marketBoundary;
        }

        if (todayOverride) {
            return (true, true);
        }
        if (!fadWindow && fadRunwaySeconds != 0 && tomorrowOverride) {
            uint256 secondsUntilTomorrow = SECONDS_PER_DAY - secondOfDay;
            fadWindow = secondsUntilTomorrow <= fadRunwaySeconds;
        }
    }

    /// @notice Returns the UTC second-of-day for the 17:00 New York FX boundary at a timestamp.
    /// @dev Uses the post-2007 US daylight-saving rules: the second Sunday in March at 07:00 UTC through the first
    ///      Sunday in November at 06:00 UTC. These rules are intentionally evaluated on-chain so Friday and Sunday can
    ///      use different UTC offsets on DST-transition weekends.
    function newYorkMarketBoundary(
        uint256 timestamp,
        uint256 dayOfWeek
    ) internal pure returns (uint256) {
        return _isNewYorkDaylightSavingTime(timestamp, dayOfWeek)
            ? NEW_YORK_DST_MARKET_BOUNDARY
            : NEW_YORK_STANDARD_MARKET_BOUNDARY;
    }

    /// @notice Returns whether New York daylight saving time is active at a Unix timestamp.
    function _isNewYorkDaylightSavingTime(
        uint256 timestamp,
        uint256 dayOfWeek
    ) private pure returns (bool) {
        (uint256 month, uint256 dayOfMonth) = _monthAndDay(timestamp / SECONDS_PER_DAY);

        if (month > 3 && month < 11) {
            return true;
        }
        if (month < 3 || month > 11) {
            return false;
        }

        uint256 firstDayOfMonth = (dayOfWeek + 7 - ((dayOfMonth - 1) % 7)) % 7;
        uint256 firstSunday = firstDayOfMonth == 0 ? 1 : 8 - firstDayOfMonth;
        uint256 secondOfDay = timestamp % SECONDS_PER_DAY;

        if (month == 3) {
            uint256 secondSunday = firstSunday + 7;
            if (dayOfMonth != secondSunday) {
                return dayOfMonth > secondSunday;
            }
            return secondOfDay >= NEW_YORK_DST_START_UTC;
        }

        if (dayOfMonth != firstSunday) {
            return dayOfMonth < firstSunday;
        }
        return secondOfDay < NEW_YORK_DST_END_UTC;
    }

    /// @notice Converts a Unix day number to its Gregorian month and day.
    /// @dev Uses a constant-time civil-calendar conversion and applies the current US DST rules proleptically. The
    ///      protocol only consumes post-deployment timestamps, for which the post-2007 rules are authoritative.
    function _monthAndDay(
        uint256 daysSinceEpoch
    ) private pure returns (uint256 month, uint256 dayOfMonth) {
        uint256 shiftedDays = daysSinceEpoch + 719_468;
        uint256 era = shiftedDays / 146_097;
        uint256 dayOfEra = shiftedDays - era * 146_097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        dayOfMonth = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
    }

    /// @notice Converts a Unix timestamp to Sunday-based UTC weekday and zero-based second of day.
    /// @param timestamp Unix timestamp to convert.
    /// @return dayOfWeek UTC weekday where Sunday is 0, Friday is 5, and Saturday is 6.
    /// @return secondOfDay UTC second of day in the range 0 through 86,399.
    function _dayAndSecond(
        uint256 timestamp
    ) private pure returns (uint256 dayOfWeek, uint256 secondOfDay) {
        dayOfWeek = ((timestamp / SECONDS_PER_DAY) + 4) % 7;
        secondOfDay = timestamp % SECONDS_PER_DAY;
    }

}

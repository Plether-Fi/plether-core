// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title MarketCalendarLib
/// @notice Evaluates recurring weekend and governance-configured perps risk-control windows in UTC.
library MarketCalendarLib {

    /// @dev Number of seconds in a UTC day.
    uint256 internal constant SECONDS_PER_DAY = 86_400;
    /// @dev Number of seconds in an hour.
    uint256 internal constant SECONDS_PER_HOUR = 3600;

    /// @notice Returns whether Friday Afternoon Deleverage controls are active at a timestamp.
    /// @dev The recurring window is Friday 19:00 UTC through Sunday 21:59:59 UTC. A configured override activates
    ///      FAD for its entire UTC day; `fadRunwaySeconds` may also activate FAD before an overridden following day.
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
        (uint256 dayOfWeek, uint256 hourOfDay) = _dayAndHour(timestamp);

        if (dayOfWeek == 5 && hourOfDay >= 19) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 22) {
            return true;
        }
        if (todayOverride) {
            return true;
        }

        if (fadRunwaySeconds > 0) {
            uint256 secondsUntilTomorrow = SECONDS_PER_DAY - (timestamp % SECONDS_PER_DAY);
            if (secondsUntilTomorrow <= fadRunwaySeconds && tomorrowOverride) {
                return true;
            }
        }

        return false;
    }

    /// @notice Returns whether the calendar permits operation with a frozen oracle at a timestamp.
    /// @dev The recurring window is Friday 22:00 UTC through Sunday 20:59:59 UTC. A configured override freezes the
    ///      oracle regime for its entire UTC day; unlike FAD, the runway does not extend this window.
    /// @param timestamp Timestamp to classify.
    /// @param todayOverride Whether the timestamp's UTC day is an admin-configured frozen-oracle day.
    /// @return Whether the frozen-oracle regime is active.
    function isOracleFrozen(
        uint256 timestamp,
        bool todayOverride
    ) internal pure returns (bool) {
        (uint256 dayOfWeek, uint256 hourOfDay) = _dayAndHour(timestamp);

        if (dayOfWeek == 5 && hourOfDay >= 22) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 21) {
            return true;
        }

        return todayOverride;
    }

    /// @notice Converts a Unix timestamp to Sunday-based UTC weekday and zero-based hour.
    /// @param timestamp Unix timestamp to convert.
    /// @return dayOfWeek UTC weekday where Sunday is 0, Friday is 5, and Saturday is 6.
    /// @return hourOfDay UTC hour in the range 0 through 23.
    function _dayAndHour(
        uint256 timestamp
    ) private pure returns (uint256 dayOfWeek, uint256 hourOfDay) {
        dayOfWeek = ((timestamp / SECONDS_PER_DAY) + 4) % 7;
        hourOfDay = (timestamp % SECONDS_PER_DAY) / SECONDS_PER_HOUR;
    }

}

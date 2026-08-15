// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title MarketCalendarLib
/// @notice Evaluates recurring weekend and governance-configured perps risk-control windows in UTC.
library MarketCalendarLib {

    /// @dev Number of seconds in a UTC day.
    uint256 internal constant SECONDS_PER_DAY = 86_400;

    /// @notice Classifies the recurring and current-day governance-configured risk-control windows at a timestamp.
    /// @dev This is the canonical implementation of the recurring calendar. FAD runs Friday 19:00 UTC through Sunday
    ///      21:59:59 UTC, while oracle-frozen mode runs Friday 22:00 UTC through Sunday 20:59:59 UTC. An override
    ///      activates both controls for its entire UTC day.
    /// @param timestamp Timestamp to classify.
    /// @param todayOverride Whether the timestamp's UTC day is an admin-configured override day.
    /// @return fadWindow Whether FAD controls are active.
    /// @return oracleFrozen Whether frozen-oracle policy is active.
    function marketStatus(
        uint256 timestamp,
        bool todayOverride
    ) internal pure returns (bool fadWindow, bool oracleFrozen) {
        uint256 today = timestamp / SECONDS_PER_DAY;
        uint256 secondsIntoDay = timestamp % SECONDS_PER_DAY;
        uint256 dayOfWeek = (today + 4) % 7;
        bool isSaturday = dayOfWeek == 6;

        fadWindow = todayOverride || isSaturday || (dayOfWeek == 5 && secondsIntoDay >= 19 hours)
            || (dayOfWeek == 0 && secondsIntoDay < 22 hours);

        oracleFrozen = todayOverride || isSaturday || (dayOfWeek == 5 && secondsIntoDay >= 22 hours)
            || (dayOfWeek == 0 && secondsIntoDay < 21 hours);
    }

    /// @notice Returns whether a timestamp falls within the configured lead time before its next UTC day.
    /// @param timestamp Timestamp to classify.
    /// @param fadRunwaySeconds Configured lead time before the following override day, in seconds.
    /// @return Whether FAD runway controls are active at the timestamp.
    function isFadRunway(
        uint256 timestamp,
        uint256 fadRunwaySeconds
    ) internal pure returns (bool) {
        return fadRunwaySeconds > 0 && SECONDS_PER_DAY - (timestamp % SECONDS_PER_DAY) <= fadRunwaySeconds;
    }

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
        (bool fadWindow,) = marketStatus(timestamp, todayOverride);
        return fadWindow || (tomorrowOverride && isFadRunway(timestamp, fadRunwaySeconds));
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
        (, bool oracleFrozen) = marketStatus(timestamp, todayOverride);
        return oracleFrozen;
    }

}

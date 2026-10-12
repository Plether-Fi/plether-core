// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Input-only calendar for the mixed fixture, whose administrative override set is empty.
/// @dev Find Gregorian year boundaries from elapsed leap days, then construct the two US DST transition
/// Sundays directly. This intentionally does not use production date conversion or market-calendar helpers.
library MarketCalendarReference {

    function status(
        uint256 timestamp
    ) internal pure returns (bool fad, bool frozen) {
        uint256 day = timestamp / 1 days;
        uint256 weekday = (day + 4) % 7;
        if (weekday != 0 && weekday != 5 && weekday != 6) {
            return (false, false);
        }
        if (weekday == 6) {
            return (true, true);
        }
        uint256 year = 1970 + day / 366;
        while (_firstDay(year + 1) <= day) {
            ++year;
        }
        uint256 leap = _leap(year) ? 1 : 0;
        uint256 march = _firstDay(year) + 59 + leap;
        uint256 november = _firstDay(year) + 304 + leap;
        uint256 dstStart = (march + (7 - (march + 4) % 7) % 7 + 7) * 1 days + 7 hours;
        uint256 dstEnd = (november + (7 - (november + 4) % 7) % 7) * 1 days + 6 hours;
        uint256 boundary = timestamp >= dstStart && timestamp < dstEnd ? 21 hours : 22 hours;
        uint256 second = timestamp % 1 days;
        if (weekday == 5) {
            return (second >= boundary - 30 minutes, second >= boundary);
        }
        return (second < boundary + 15 minutes, second < boundary);
    }

    function _firstDay(
        uint256 year
    ) private pure returns (uint256) {
        uint256 previous = year - 1;
        return 365 * (year - 1970) + previous / 4 - previous / 100 + previous / 400 - 477;
    }

    function _leap(
        uint256 year
    ) private pure returns (bool) {
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    }

}

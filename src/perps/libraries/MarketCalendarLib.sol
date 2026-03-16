// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library MarketCalendarLib {

    uint256 internal constant SECONDS_PER_DAY = 86_400;
    uint256 internal constant SECONDS_PER_HOUR = 3600;

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

    function _dayAndHour(
        uint256 timestamp
    ) private pure returns (uint256 dayOfWeek, uint256 hourOfDay) {
        dayOfWeek = ((timestamp / SECONDS_PER_DAY) + 4) % 7;
        hourOfDay = (timestamp % SECONDS_PER_DAY) / SECONDS_PER_HOUR;
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

library MarketCalendarLib {

    uint256 internal constant SECONDS_PER_DAY = 86_400;
    uint256 internal constant FRIDAY_FAD_START = 21 hours + 30 minutes;
    uint256 internal constant FRIDAY_ORACLE_FREEZE_START = 22 hours;
    uint256 internal constant SUNDAY_ORACLE_FREEZE_END = 21 hours;
    uint256 internal constant SUNDAY_FAD_END = 21 hours + 15 minutes;

    function isFadWindow(
        uint256 timestamp,
        bool todayOverride,
        bool tomorrowOverride,
        uint256 fadRunwaySeconds
    ) internal pure returns (bool) {
        (uint256 dayOfWeek, uint256 secondOfDay) = _dayAndSecond(timestamp);

        if (dayOfWeek == 5 && secondOfDay >= FRIDAY_FAD_START) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && secondOfDay < SUNDAY_FAD_END) {
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
        (uint256 dayOfWeek, uint256 secondOfDay) = _dayAndSecond(timestamp);

        if (dayOfWeek == 5 && secondOfDay >= FRIDAY_ORACLE_FREEZE_START) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && secondOfDay < SUNDAY_ORACLE_FREEZE_END) {
            return true;
        }

        return todayOverride;
    }

    function _dayAndSecond(
        uint256 timestamp
    ) private pure returns (uint256 dayOfWeek, uint256 secondOfDay) {
        dayOfWeek = ((timestamp / SECONDS_PER_DAY) + 4) % 7;
        secondOfDay = timestamp % SECONDS_PER_DAY;
    }

}

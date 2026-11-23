// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

contract EngineMarketCalendarTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_MarketCalendar_SundayBoundariesMatchLiveSemantics() public {
        uint256 sundayTwentyFiftyNine = 1_710_104_399;
        uint256 sundayTwentyOne = 1_710_104_400;
        uint256 sundayTwentyOneFourteenFiftyNine = 1_710_105_299;
        uint256 sundayTwentyOneFifteen = 1_710_105_300;

        vm.warp(sundayTwentyFiftyNine);
        assertTrue(engine.isOracleFrozen(), "Sunday 20:59:59 should still be oracle frozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");
        assertTrue(engine.isFadWindow(), "Sunday 20:59:59 should still be FAD");

        vm.warp(sundayTwentyOne);
        assertFalse(engine.isOracleFrozen(), "Sunday 21:00:00 should unfreeze oracle mode");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");
        assertTrue(engine.isFadWindow(), "Sunday 21:00:00 should remain in FAD");

        vm.warp(sundayTwentyOneFourteenFiftyNine);
        assertFalse(engine.isOracleFrozen(), "Sunday 21:14:59 should remain unfrozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");
        assertTrue(engine.isFadWindow(), "Sunday 21:14:59 should remain in FAD");

        vm.warp(sundayTwentyOneFifteen);
        assertFalse(engine.isOracleFrozen(), "Sunday 21:15:00 should remain unfrozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");
        assertFalse(engine.isFadWindow(), "Sunday 21:15:00 should end FAD");
    }

    function test_MarketCalendar_FridayBoundariesMatchLiveSemantics() public {
        uint256 fridayBeforeFad = 1_729_283_399;
        uint256 fridayFadStart = 1_729_283_400;
        uint256 fridayBeforeFreeze = fridayFadStart + 30 minutes - 1;
        uint256 fridayFreezeStart = fridayFadStart + 30 minutes;

        vm.warp(fridayBeforeFad);
        assertFalse(engine.isFadWindow(), "Friday 20:29:59 should be live");
        assertFalse(engine.isOracleFrozen(), "Friday 20:29:59 should not be oracle frozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");

        vm.warp(fridayFadStart);
        assertTrue(engine.isFadWindow(), "Friday 20:30:00 should start FAD");
        assertFalse(engine.isOracleFrozen(), "Friday 20:30:00 should not be oracle frozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");

        vm.warp(fridayBeforeFreeze);
        assertTrue(engine.isFadWindow(), "Friday 20:59:59 should remain in FAD");
        assertFalse(engine.isOracleFrozen(), "Friday 20:59:59 should not be oracle frozen");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");

        vm.warp(fridayFreezeStart);
        assertTrue(engine.isFadWindow(), "Friday 21:00:00 should remain in FAD");
        assertTrue(engine.isOracleFrozen(), "Friday 21:00:00 should start oracle-frozen mode");
        assertEq(pletherOracle.isOracleFrozen(), engine.isOracleFrozen(), "Oracle and engine calendar should agree");
    }

    function test_MarketCalendar_HolidayReopenMatchesOracleAndPool() public {
        uint256[2] memory days_ = [uint256(1_784_678_400), uint256(1_768_348_800)];
        uint256[2] memory boundaries = [uint256(21 hours), uint256(22 hours)];
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _engineCalendarConfig();
        config.fadDayTimestamps = new uint256[](4);
        for (uint256 season; season < days_.length; ++season) {
            // Governance continues to accept arbitrary timestamps normalized to UTC override dates.
            config.fadDayTimestamps[season * 2] = days_[season] + 12 hours;
            config.fadDayTimestamps[season * 2 + 1] = days_[season] + 1 days + 12 hours;
        }
        config.fadRunwaySeconds = 24 hours;
        _setCalendarConfig(config);

        for (uint256 season; season < days_.length; ++season) {
            uint256 dayStart = days_[season];
            uint256 boundary = boundaries[season];
            _assertCalendarStatus(dayStart, true, true);
            _assertCalendarStatus(dayStart + boundary - 1, true, true);
            _assertCalendarStatus(dayStart + boundary, false, true);
            _assertCalendarStatus(dayStart + boundary + 1, false, true);
            _assertCalendarStatus(dayStart + 1 days - 1, false, true);
            _assertCalendarStatus(dayStart + 1 days, true, true);
            _assertCalendarStatus(dayStart + 1 days + boundary, false, true);
            _assertCalendarStatus(dayStart + 2 days, false, false);
        }
    }

    function _assertCalendarStatus(
        uint256 timestamp,
        bool frozen,
        bool fad
    ) internal {
        vm.warp(timestamp);
        assertEq(engine.isOracleFrozen(), frozen, "Engine must classify the holiday boundary correctly");
        assertEq(pletherOracle.isOracleFrozen(), frozen, "Oracle must follow the canonical engine calendar");
        assertEq(pool.isOracleFrozen(), frozen, "LP pricing must follow the canonical engine calendar");
        assertEq(engine.isFadWindow(), fad, "FAD remains independent of the shorter frozen interval");
    }

}

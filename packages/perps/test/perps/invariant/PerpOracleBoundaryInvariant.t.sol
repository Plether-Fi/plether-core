// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpOracleHandler} from "./handlers/PerpOracleHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";

contract PerpOracleBoundaryInvariantTest is BasePerpInvariantTest {

    PerpOracleHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpOracleHandler(usdc, mockPyth, engine, clearinghouse, router);
        handler.seedPositions();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.warpToOracleBoundary.selector;
        selectors[1] = handler.warpForward.selector;
        selectors[2] = handler.syncMarkNow.selector;
        selectors[3] = handler.configureFadDayTomorrow.selector;
        selectors[4] = handler.configureFadMaxStaleness.selector;
        selectors[5] = handler.ensureActorPosition.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _assertInvariant_OracleFrozenMatchesBoundaryFormula() internal view {
        assertEq(
            engine.isOracleFrozen(),
            _expectedOracleFrozen(block.timestamp),
            "Oracle frozen flag must match boundary formula"
        );
    }

    function _assertInvariant_FadWindowMatchesBoundaryFormula() internal view {
        assertEq(
            engine.isFadWindow(),
            _expectedFadWindow(block.timestamp),
            "FAD flag must match boundary and override formula"
        );
    }

    function _assertInvariant_MaintenanceMarginMatchesFadWindow() internal view {
        uint256 price = 1e8;
        uint256 size = 10_000e18;
        uint256 maint = _maintenanceMarginUsdc(size, price);
        uint256 notionalUsdc = (size * price) / 1e20;
        uint256 expectedBps = engine.isFadWindow() ? 300 : 100;
        assertEq(maint, (notionalUsdc * expectedBps) / 10_000, "Maintenance margin must switch with FAD mode");
    }

    function _assertInvariant_HousePoolSnapshotUsesCorrectFreshnessLimit() internal view {
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(300);
        if (!snapshot.markFreshnessRequired) {
            assertEq(snapshot.maxMarkStaleness, 0, "No live liability should imply no freshness bound");
            return;
        }

        uint256 expectedLiveLimit = engine.engineMarkStalenessLimit() < 300 ? engine.engineMarkStalenessLimit() : 300;
        uint256 expectedMaxStaleness = engine.isOracleFrozen() ? engine.fadMaxStaleness() : expectedLiveLimit;
        assertEq(
            snapshot.maxMarkStaleness,
            expectedMaxStaleness,
            "House-pool snapshot freshness limit must follow frozen/live reconcile policy"
        );
    }

    function _assertInvariant_PositionViewsRespectCurrentFadMode() internal view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address account = handler.actorAt(i);
            AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
                engineAccountLens.getAccountLedgerSnapshot(account);
            if (!snapshot.hasPosition) {
                continue;
            }

            uint256 expectedMaint = _maintenanceMarginUsdc(snapshot.size, engine.lastMarkPrice());
            uint256 weekdayMaint = (((snapshot.size * engine.lastMarkPrice()) / 1e20) * 100) / 10_000;
            uint256 fadMaint = (((snapshot.size * engine.lastMarkPrice()) / 1e20) * 300) / 10_000;
            if (engine.isFadWindow()) {
                assertEq(expectedMaint, fadMaint, "FAD mode must use the elevated maintenance margin bps");
            } else {
                assertEq(expectedMaint, weekdayMaint, "Non-FAD mode must use the weekday maintenance margin bps");
            }
        }
    }

    function _expectedOracleFrozen(
        uint256 timestamp
    ) internal view returns (bool) {
        uint256 dayOfWeek = ((timestamp / 86_400) + 4) % 7;
        uint256 secondOfDay = timestamp % 86_400;
        uint256 marketBoundary = _expectedMarketBoundary(timestamp, dayOfWeek);
        if (dayOfWeek == 5 && secondOfDay >= marketBoundary) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && secondOfDay < marketBoundary) {
            return true;
        }
        return engine.fadDayOverrides(timestamp / 86_400);
    }

    function _expectedFadWindow(
        uint256 timestamp
    ) internal view returns (bool) {
        uint256 dayIndex = timestamp / 86_400;
        uint256 dayOfWeek = (dayIndex + 4) % 7;
        uint256 secondOfDay = timestamp % 86_400;
        uint256 marketBoundary = _expectedMarketBoundary(timestamp, dayOfWeek);
        if (dayOfWeek == 5 && secondOfDay >= marketBoundary - 30 minutes) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && secondOfDay < marketBoundary + 15 minutes) {
            return true;
        }
        if (engine.fadDayOverrides(dayIndex)) {
            return true;
        }

        uint256 runway = engine.fadRunwaySeconds();
        uint256 secondsUntilTomorrow = 86_400 - secondOfDay;
        return runway > 0 && secondsUntilTomorrow <= runway && engine.fadDayOverrides(dayIndex + 1);
    }

    function _expectedMarketBoundary(
        uint256 timestamp,
        uint256 dayOfWeek
    ) internal pure returns (uint256) {
        return _expectedNewYorkDst(timestamp, dayOfWeek) ? 21 hours : 22 hours;
    }

    function _expectedNewYorkDst(
        uint256 timestamp,
        uint256 dayOfWeek
    ) internal pure returns (bool) {
        (uint256 month, uint256 dayOfMonth) = _monthAndDay(timestamp / 86_400);
        if (month > 3 && month < 11) {
            return true;
        }
        if (month < 3 || month > 11) {
            return false;
        }

        uint256 firstDayOfMonth = (dayOfWeek + 7 - ((dayOfMonth - 1) % 7)) % 7;
        uint256 firstSunday = firstDayOfMonth == 0 ? 1 : 8 - firstDayOfMonth;
        if (month == 3) {
            uint256 secondSunday = firstSunday + 7;
            return dayOfMonth > secondSunday || (dayOfMonth == secondSunday && timestamp % 86_400 >= 7 hours);
        }
        return dayOfMonth < firstSunday || (dayOfMonth == firstSunday && timestamp % 86_400 < 6 hours);
    }

    function _monthAndDay(
        uint256 daysSinceEpoch
    ) internal pure returns (uint256 month, uint256 dayOfMonth) {
        uint256 shiftedDays = daysSinceEpoch + 719_468;
        uint256 era = shiftedDays / 146_097;
        uint256 dayOfEra = shiftedDays - era * 146_097;
        uint256 yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        uint256 dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        uint256 monthPrime = (5 * dayOfYear + 2) / 153;
        dayOfMonth = dayOfYear - (153 * monthPrime + 2) / 5 + 1;
        month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9;
    }

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_OracleFrozenMatchesBoundaryFormula();
        _assertInvariant_FadWindowMatchesBoundaryFormula();
        _assertInvariant_MaintenanceMarginMatchesFadWindow();
        _assertInvariant_HousePoolSnapshotUsesCorrectFreshnessLimit();
        _assertInvariant_PositionViewsRespectCurrentFadMode();
    }

}

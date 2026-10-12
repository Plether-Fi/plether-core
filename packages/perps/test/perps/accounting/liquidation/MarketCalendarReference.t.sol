// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {MarketCalendarReference} from "../../invariant/ghost/MarketCalendarReference.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Fixed UTC vectors for the independent mixed-fixture calendar, with an explicitly empty override set.
/// @dev Golden Unix timestamps were checked offline with Python datetime and zoneinfo America/New_York.
/// Friday close and Sunday reopen occur at 17:00 New York time; tests need no Python, FFI, or production helpers.
contract MarketCalendarReferenceTest is Test {

    function test_March2026FridayFadShoulderMovesWithDst() public pure {
        _assertFridayClose(1_772_834_400); // Friday 2026-03-06 22:00:00 UTC, before DST.
        _assertFridayClose(1_773_435_600); // Friday 2026-03-13 21:00:00 UTC, after DST.
    }

    function test_March2026SundayReopenShoulderUsesTheNewOffset() public pure {
        _assertSundayReopen(1_772_402_400); // Sunday 2026-03-01 22:00:00 UTC, before DST.
        _assertSundayReopen(1_773_003_600); // Sunday 2026-03-08 21:00:00 UTC, DST transition day.
    }

    function test_November2026FridayFadShoulderMovesBackToStandardTime() public pure {
        _assertFridayClose(1_793_394_000); // Friday 2026-10-30 21:00:00 UTC, before DST ends.
        _assertFridayClose(1_794_002_400); // Friday 2026-11-06 22:00:00 UTC, after DST ends.
    }

    function test_November2026SundayReopenShoulderUsesTheNewOffset() public pure {
        _assertSundayReopen(1_792_962_000); // Sunday 2026-10-25 21:00:00 UTC, before DST ends.
        _assertSundayReopen(1_793_570_400); // Sunday 2026-11-01 22:00:00 UTC, DST transition day.
    }

    function test_DstClockChangesDoNotReopenTheSundayMorningMarket() public pure {
        _assertStatus(1_772_953_199, true, true); // 2026-03-08 06:59:59 UTC: 01:59:59 EST.
        _assertStatus(1_772_953_200, true, true); // 2026-03-08 07:00:00 UTC: 03:00:00 EDT.
        _assertStatus(1_793_512_799, true, true); // 2026-11-01 05:59:59 UTC: 01:59:59 EDT.
        _assertStatus(1_793_512_800, true, true); // 2026-11-01 06:00:00 UTC: 01:00:00 EST.
    }

    function test_WeekdaysAndSaturdaysWithNoAdministrativeOverrides() public pure {
        _assertStatus(0, false, false); // Thursday 1970-01-01 00:00:00 UTC.
        _assertStatus(1_772_755_199, false, false); // Thursday 2026-03-05 23:59:59 UTC.
        _assertStatus(1_772_841_600, true, true); // Saturday 2026-03-07 00:00:00 UTC.
        _assertStatus(1_773_014_400, false, false); // Monday 2026-03-09 00:00:00 UTC.
        _assertStatus(1_793_448_000, true, true); // Saturday 2026-10-31 12:00:00 UTC.
        _assertStatus(1_793_577_600, false, false); // Monday 2026-11-02 00:00:00 UTC.
    }

    function test_LeapCentury2000AndNonLeapCentury2100KeepGregorianBoundaries() public pure {
        _assertStatus(951_825_600, false, false); // Tuesday 2000-02-29 12:00:00 UTC, a real leap day.
        _assertFridayClose(4_107_362_400); // Friday 2100-02-26 22:00:00 UTC.
        _assertSundayReopen(4_107_535_200); // Sunday 2100-02-28 22:00:00 UTC.
        _assertStatus(4_107_542_400, false, false); // Monday 2100-03-01 00:00:00 UTC; no February 29.
        _assertFridayClose(4_108_572_000); // Friday 2100-03-12 22:00:00 UTC, before DST.
        _assertSundayReopen(4_108_741_200); // Sunday 2100-03-14 21:00:00 UTC, DST transition day.
        _assertFridayClose(4_109_173_200); // Friday 2100-03-19 21:00:00 UTC, after DST.
        // A phantom leap day in 2100 would shift March's computed first Sunday in this later year.
        _assertSundayReopen(4_265_989_200); // Sunday 2105-03-08 21:00:00 UTC, DST transition day.
    }

    function _assertFridayClose(
        uint256 closeTime
    ) private pure {
        _assertStatus(closeTime - 30 minutes - 1, false, false);
        _assertStatus(closeTime - 30 minutes, true, false);
        _assertStatus(closeTime - 1, true, false);
        _assertStatus(closeTime, true, true);
        _assertStatus(closeTime + 1, true, true);
    }

    function _assertSundayReopen(
        uint256 reopenTime
    ) private pure {
        _assertStatus(reopenTime - 1, true, true);
        _assertStatus(reopenTime, true, false);
        _assertStatus(reopenTime + 15 minutes - 1, true, false);
        _assertStatus(reopenTime + 15 minutes, false, false);
    }

    function _assertStatus(
        uint256 timestamp,
        bool expectedFad,
        bool expectedFrozen
    ) private pure {
        (bool fad, bool frozen) = MarketCalendarReference.status(timestamp);
        assertEq(fad, expectedFad, "fixed UTC FAD classification with no overrides");
        assertEq(frozen, expectedFrozen, "fixed UTC frozen classification with no overrides");
    }

}

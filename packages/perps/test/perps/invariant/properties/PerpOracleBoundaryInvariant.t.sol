// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpInvariantTest} from "../BasePerpInvariantTest.sol";
import {PerpOracleHandler} from "../handlers/PerpOracleHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

contract PerpOracleBoundaryInvariantTest is BasePerpInvariantTest {

    PerpOracleHandler internal handler;

    address internal constant OPEN_MARGIN_PROBE = address(0x7200);
    address internal constant LONG_MARGIN_PROBE = address(0x7201);
    address internal constant SHORT_MARGIN_PROBE = address(0x7202);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        // Isolate calendar-driven margin changes: these fixed reference positions never accrue carry.
        params.baseCarryBps = 0;
    }

    function setUp() public override {
        super.setUp();

        _depositMarginProbe(OPEN_MARGIN_PROBE);
        _openMarginProbe(LONG_MARGIN_PROBE, CfdTypes.Side.LONG, 0.8e8, 200e6);
        _openMarginProbe(SHORT_MARGIN_PROBE, CfdTypes.Side.SHORT, 1.2e8, 300e6);

        handler = new PerpOracleHandler(settlementToken, mockPyth, engine, clearinghouse, router);
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

    function test_MarkSyncRejectsBackwardTimeAndChangedEqualTime() public {
        handler.warpToOracleBoundary(8);
        handler.syncMarkNow(1e8);
        uint64 markTime = engine.lastMarkTime();
        handler.syncMarkNow(1.1e8);
        assertEq(engine.lastMarkTime(), markTime);
        assertEq(engine.lastMarkPrice(), 1e8);

        handler.warpToOracleBoundary(0);
        handler.syncMarkNow(0.9e8);
        assertEq(engine.lastMarkTime(), markTime, "Backward rejection must preserve the mark timestamp");
        assertEq(engine.lastMarkPrice(), 1e8, "Backward rejection must preserve the mark price");
        assertEq(handler.markSyncAttempts(), 3);
        assertEq(handler.successfulMarkSyncs(), 1);
        assertEq(handler.expectedOutOfOrderRejections(), 2);
        _assertAllInvariants();
    }

    function test_MarkSyncRejectsUnknownAndMalformedErrors() public {
        handler.warpToOracleBoundary(8);
        handler.syncMarkNow(1e8);
        handler.warpToOracleBoundary(0);
        bytes memory callData = abi.encodeWithSelector(engine.updateMarkPrice.selector, 1e8, uint64(block.timestamp));
        bytes[] memory reasons = new bytes[](3);
        reasons[0] = abi.encodeWithSignature("Error(string)", "unexpected dependency failure");
        reasons[1] = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        reasons[2] = abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector, uint256(1));
        for (uint256 i; i < reasons.length; ++i) {
            vm.mockCallRevert(address(engine), callData, reasons[i]);
            vm.expectRevert(
                abi.encodeWithSelector(PerpOracleHandler.PerpOracleHandler__UnexpectedRevert.selector, reasons[i])
            );
            handler.syncMarkNow(1e8);
        }
        vm.clearMockedCalls();
        assertEq(handler.expectedOutOfOrderRejections(), 0, "Unexpected errors must not count as expected rejection");
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
        bool fad = _expectedFadWindow(block.timestamp);
        ICfdEngineTypes.OpenPreview memory longPreview =
            engineLens.previewOpen(OPEN_MARGIN_PROBE, CfdTypes.Side.LONG, 10_000e18, 1000e6, 0.8e8);
        ICfdEngineTypes.OpenPreview memory shortPreview =
            engineLens.previewOpen(OPEN_MARGIN_PROBE, CfdTypes.Side.SHORT, 10_000e18, 1000e6, 1.2e8);
        assertTrue(longPreview.valid, "Funded reference long must be admitted");
        assertTrue(shortPreview.valid, "Funded reference short must be admitted");
        // Known policy examples: $8,000/$12,000 notional require 1% ordinarily and 3% in FAD.
        // Read the production planner result; do not calculate and compare a test-only margin helper.
        assertEq(longPreview.maintenanceMarginAssets, fad ? 240e6 : 80e6, "Long maintenance must match known policy");
        assertEq(shortPreview.maintenanceMarginAssets, fad ? 360e6 : 120e6, "Short maintenance must match known policy");
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

    function _assertInvariant_LiquidationEligibilityMatchesFadWindow() internal view {
        bool fad = _expectedFadWindow(block.timestamp);
        ICfdEngineTypes.LiquidationPreview memory longPreview = engineLens.previewLiquidation(LONG_MARGIN_PROBE, 0.8e8);
        ICfdEngineTypes.LiquidationPreview memory shortPreview =
            engineLens.previewLiquidation(SHORT_MARGIN_PROBE, 1.2e8);
        // $200 less $3.20 execution fee and $7.20 liquidation reserve leaves $189.60 price equity;
        // $300 less $4.80 and $10.80 leaves $284.40. Both exceed weekday maintenance and fail FAD.
        assertEq(longPreview.equityAssets, 189.6e6, "Long reference equity must remain fixed");
        assertEq(shortPreview.equityAssets, 284.4e6, "Short reference equity must remain fixed");
        assertEq(longPreview.liquidatable, fad, "Long eligibility must cross the known FAD margin boundary");
        assertEq(shortPreview.liquidatable, fad, "Short eligibility must cross the known FAD margin boundary");
    }

    function test_MarginPolicyProbesCrossEveryOracleBoundary() public {
        for (uint256 mode; mode < 16; ++mode) {
            handler.warpToOracleBoundary(mode);
            _assertAllInvariants();
        }
    }

    function test_RealAccountHealthAndPublicMarginCrossFadBoundary() public {
        handler.warpToOracleBoundary(8);
        handler.syncMarkNow(0.8e8);
        _assertLongProbeAccount(false, 80e6);
        handler.warpToOracleBoundary(9);
        _assertLongProbeAccount(true, 240e6);
    }

    function test_FaultControlInvariantRejectsWrongProductionMaintenance() public {
        for (uint256 mode; mode < 2; ++mode) {
            handler.warpToOracleBoundary(mode);
            ICfdEngineTypes.OpenPreview memory corrupt =
                engineLens.previewOpen(OPEN_MARGIN_PROBE, CfdTypes.Side.LONG, 10_000e18, 1000e6, 0.8e8);
            corrupt.maintenanceMarginAssets += 1;
            vm.mockCall(
                address(engineLens),
                abi.encodeCall(
                    engineLens.previewOpen, (OPEN_MARGIN_PROBE, CfdTypes.Side.LONG, 10_000e18, 1000e6, 0.8e8)
                ),
                abi.encode(corrupt)
            );
            vm.expectRevert();
            this.invariant_OracleCalendarMarginsAndFreshnessMatchPolicy();
            vm.clearMockedCalls();
            _assertAllInvariants();
        }
    }

    function test_FaultControlInvariantRejectsWrongProductionLiquidationEligibility() public {
        for (uint256 mode; mode < 2; ++mode) {
            handler.warpToOracleBoundary(mode);
            ICfdEngineTypes.LiquidationPreview memory corrupt = engineLens.previewLiquidation(LONG_MARGIN_PROBE, 0.8e8);
            corrupt.liquidatable = !corrupt.liquidatable;
            vm.mockCall(
                address(engineLens),
                abi.encodeCall(engineLens.previewLiquidation, (LONG_MARGIN_PROBE, 0.8e8)),
                abi.encode(corrupt)
            );
            vm.expectRevert();
            this.invariant_OracleCalendarMarginsAndFreshnessMatchPolicy();
            vm.clearMockedCalls();
            _assertAllInvariants();
        }
    }

    function _assertLongProbeAccount(
        bool expectedLiquidatable,
        uint256 expectedMaintenance
    ) internal view {
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(LONG_MARGIN_PROBE);
        PerpsViewTypes.PositionView memory position = publicLens.getPosition(LONG_MARGIN_PROBE);
        assertTrue(snapshot.hasPosition, "Reference position must exist");
        assertEq(
            snapshot.netEquityAssets, 189.6e6, "Reference price equity must stay between weekday and FAD maintenance"
        );
        assertEq(snapshot.liquidatable, expectedLiquidatable, "Real account health must follow the FAD threshold");
        assertEq(
            position.maintenanceMarginAssets, expectedMaintenance, "Public margin must report the known requirement"
        );
        assertEq(position.liquidatable, expectedLiquidatable, "Public health must follow the FAD threshold");
    }

    function _depositMarginProbe(
        address account
    ) internal {
        settlementToken.mint(account, 10_000e6);
        vm.startPrank(account);
        settlementToken.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(account, 10_000e6);
        vm.stopPrank();
    }

    function _openMarginProbe(
        address account,
        CfdTypes.Side side,
        uint256 price,
        uint256 margin
    ) internal {
        _depositMarginProbe(account);
        uint256 depth = housePool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: 10_000e18,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
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

    function invariant_OracleCalendarMarginsAndFreshnessMatchPolicy() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        assertEq(
            handler.markSyncAttempts(),
            handler.successfulMarkSyncs() + handler.expectedOutOfOrderRejections(),
            "Every completed mark-sync attempt must have an exact classified outcome"
        );
        _assertInvariant_OracleFrozenMatchesBoundaryFormula();
        _assertInvariant_FadWindowMatchesBoundaryFormula();
        _assertInvariant_MaintenanceMarginMatchesFadWindow();
        _assertInvariant_HousePoolSnapshotUsesCorrectFreshnessLimit();
        _assertInvariant_LiquidationEligibilityMatchesFadWindow();
    }

}

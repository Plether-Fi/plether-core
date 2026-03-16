// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpOracleHandler} from "./handlers/PerpOracleHandler.sol";

contract PerpOracleBoundaryInvariantTest is BasePerpInvariantTest {

    PerpOracleHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpOracleHandler(usdc, engine, clearinghouse, router);
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

    function invariant_OracleFrozenMatchesBoundaryFormula() public view {
        assertEq(
            engine.isOracleFrozen(),
            _expectedOracleFrozen(block.timestamp),
            "Oracle frozen flag must match boundary formula"
        );
    }

    function invariant_FadWindowMatchesMaintenanceMarginMode() public view {
        uint256 price = 1e8;
        uint256 size = 10_000e18;
        uint256 maint = engine.getMaintenanceMarginUsdc(size, price);
        uint256 notionalUsdc = (size * price) / 1e20;
        uint256 expectedBps = engine.isFadWindow() ? 300 : 100;
        assertEq(maint, (notionalUsdc * expectedBps) / 10_000, "Maintenance margin must switch with FAD mode");
    }

    function invariant_HousePoolSnapshotUsesCorrectFreshnessLimit() public view {
        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(300);
        if (!snapshot.markFreshnessRequired) {
            assertEq(snapshot.maxMarkStaleness, 0, "No live liability should imply no freshness bound");
            return;
        }

        assertEq(
            snapshot.maxMarkStaleness,
            engine.isOracleFrozen() ? engine.fadMaxStaleness() : 300,
            "House-pool snapshot freshness limit must follow frozen/unfrozen mode"
        );
    }

    function invariant_PositionViewsRespectCurrentFadMode() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.actorAt(i))));
            ICfdEngine.AccountLedgerSnapshot memory snapshot = engine.getAccountLedgerSnapshot(accountId);
            if (!snapshot.hasPosition) {
                continue;
            }

            uint256 expectedMaint = engine.getMaintenanceMarginUsdc(snapshot.size, engine.lastMarkPrice());
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
        uint256 hourOfDay = (timestamp % 86_400) / 3600;
        if (dayOfWeek == 5 && hourOfDay >= 22) {
            return true;
        }
        if (dayOfWeek == 6) {
            return true;
        }
        if (dayOfWeek == 0 && hourOfDay < 21) {
            return true;
        }
        return engine.fadDayOverrides(timestamp / 86_400);
    }

}

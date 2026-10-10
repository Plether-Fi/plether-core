// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {OracleSynchronizationHandler} from "../handlers/OracleSynchronizationHandler.sol";

contract OracleSynchronizationInvariantTest is BasePerpTest {

    OracleSynchronizationHandler internal handler;

    function setUp() public override {
        super.setUp();
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        handler =
            new OracleSynchronizationHandler(router, engine, clearinghouse, baseMockPyth, usdc, _basePythFeedIds());
        handler.execute(0, 0, false, false);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.execute.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ExecutionInstalledMarksAlwaysHaveStoredFeedCoverage() public view {
        assertGt(handler.resolutions(), 0, "must exercise real oracle resolutions");
        assertFalse(handler.coverageViolation(), "execution retained an uncovered mark");
    }

}

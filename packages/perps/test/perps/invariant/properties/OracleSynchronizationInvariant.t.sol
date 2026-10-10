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
        assertEq(handler.executed(), 1, "warm-up must execute an order");
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.execute.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ExecutionInstalledMarksAlwaysHaveStoredFeedCoverage() public view {
        assertGt(handler.executed(), 0, "must exercise authenticated executed orders");
        assertEq(handler.resolutions(), handler.executed() + handler.plannerRejected(), "terminal outcome accounting");
        assertEq(
            handler.attempts(), handler.resolutions() + handler.commitRejected(), "all attempted actions accounted for"
        );
        assertEq(
            handler.healthyRetries(),
            handler.injectedWriteFailures() + handler.injectedCoverageFailures(),
            "all injected faults retried"
        );
        assertGe(baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A).publishTime, engine.lastMarkTime());
        assertGe(baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_B).publishTime, engine.lastMarkTime());
    }

}

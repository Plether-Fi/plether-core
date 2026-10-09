// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {OracleEthConservationHandler} from "./handlers/OracleEthConservationHandler.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

contract OracleEthConservationInvariantTest is BasePerpTest {

    OracleEthConservationHandler internal handler;

    function setUp() public override {
        super.setUp();
        bytes32[] memory ids = new bytes32[](6);
        uint256[] memory weights = new uint256[](6);
        uint256[] memory bases = new uint256[](6);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = bytes32(i + 1);
            weights[i] = i == 5 ? 0.5e18 : 0.1e18;
            bases[i] = 1e8;
        }
        baseMockPyth.setAllPrices(ids, 100_000_000, -8, block.timestamp);
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(baseMockPyth), ids, weights, bases, new bool[](6)
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        baseMockPyth.setAllPrices(ids, 100_000_000, -8, block.timestamp);
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        handler = new OracleEthConservationHandler(
            router, engine, clearinghouse, pletherOracle, routerAdmin, baseMockPyth, usdc, ids
        );
        // These are the only ETH topups. Baselines are captured after all three fixed budgets are installed.
        for (uint256 i; i < 3; ++i) {
            vm.deal(address(handler.actors(i)), 1 ether);
        }
        handler.initialize();
        _prelude();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.exercise.selector;
        selectors[1] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _prelude() private {
        for (uint8 i; i < 11; ++i) {
            handler.exercise(i, i % 3, 1 gwei, 3, 0);
            assertEq(handler.violation(), 0, "scenario prelude");
        }
        for (uint8 kind; kind < 5; ++kind) {
            handler.exercise(6, kind % 3, 1 gwei, kind, 0);
            assertEq(handler.violation(), 0, "rollback prelude");
        }
        // Independent Oracle/Admin deferrals, failed claims, reentrant claims, and repeated claims.
        handler.exercise(4, 0, 1 gwei, 3, 5);
        handler.claim(0, true, 1);
        handler.claim(0, false, 2);
        handler.claim(0, true, 3);
        handler.claim(0, false, 3);
        handler.claim(0, true, 0);
        // Both immediate callbacks burn their stipend, then recover through uncapped accepting claims.
        handler.exercise(4, 1, 1 gwei, 3, 10);
        handler.claim(1, true, 0);
        handler.claim(1, false, 0);
        // Both immediate callbacks attempt reentry and still accept the exact refunds.
        handler.exercise(4, 2, 1 gwei, 3, 15);
        // A beneficiary may legitimately claim the other ledger during a claim callback, in either direction.
        handler.exercise(4, 0, 1 gwei, 3, 5);
        handler.claim(0, true, 4);
        handler.exercise(4, 1, 1 gwei, 3, 5);
        handler.claim(1, false, 4);
        assertEq(handler.violation(), 0, "refund prelude");
    }

    function invariant_EthConservedAcrossFeesRefundsAndClaims() public view {
        assertEq(handler.violation(), 0, "unexpected protocol outcome or accounting transition");
        assertEq(handler.accountingError(), 0, "ETH conservation or fee/callback accounting");
    }

    function invariant_AllRequiredPathsRemainExercised() public view {
        for (uint256 i; i < 11; ++i) {
            assertGt(handler.scenarios(i), 0, "missing fee scenario");
        }
        for (uint256 i; i < 5; ++i) {
            assertGt(handler.rollbackCases(i), 0, "missing rollback scenario");
        }
        assertGt(handler.executedRoundTrips(), 0, "missing actual order execution");
        assertGt(handler.caughtItemFailures(), 0, "missing caught item rollback");
        assertGt(handler.reentryAttempts(), 0, "missing observed reentry attempt");
        assertGt(handler.successfulOracleClaims(), 0, "missing Oracle claim");
        assertGt(handler.successfulAdminClaims(), 0, "missing Admin claim");
        assertGt(handler.failedClaims(), 0, "missing rejected or duplicate claim");
        assertGt(handler.crossLedgerClaims(), 1, "missing legitimate cross-ledger callback claims");
    }

}

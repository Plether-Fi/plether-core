// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {OracleFreshnessPolicyLib} from "../../src/perps/libraries/OracleFreshnessPolicyLib.sol";
import {Test} from "forge-std/Test.sol";

contract OracleFreshnessPolicyTest is Test {

    function test_OpenExecution_IsCloseOnlyDuringFrozenOrFad() public pure {
        OracleFreshnessPolicyLib.Policy memory frozenPolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.OpenExecution, true, false, 60, 60, 60, 15, 3 days
        );
        OracleFreshnessPolicyLib.Policy memory fadPolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.OpenExecution, false, true, 60, 60, 60, 15, 3 days
        );
        OracleFreshnessPolicyLib.Policy memory livePolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.OpenExecution, false, false, 60, 60, 60, 15, 3 days
        );

        assertTrue(frozenPolicy.closeOnly);
        assertTrue(fadPolicy.closeOnly);
        assertFalse(livePolicy.closeOnly);
        assertEq(livePolicy.maxStaleness, 60);
    }

    function test_CloseExecution_RemainsExecutableButUsesExecutionFreshness() public pure {
        OracleFreshnessPolicyLib.Policy memory policy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.CloseExecution, false, true, 60, 60, 60, 15, 3 days
        );

        assertFalse(policy.closeOnly);
        assertEq(policy.maxStaleness, 60);
    }

    function test_Liquidation_UsesLiquidationFreshnessUnlessFrozen() public pure {
        OracleFreshnessPolicyLib.Policy memory livePolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.Liquidation, false, false, 60, 60, 60, 15, 3 days
        );
        OracleFreshnessPolicyLib.Policy memory frozenPolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.Liquidation, true, false, 60, 60, 60, 15, 3 days
        );

        assertEq(livePolicy.maxStaleness, 15);
        assertEq(frozenPolicy.maxStaleness, 3 days);
    }

    function test_PoolReconcile_UsesTighterEnginePoolFreshness() public pure {
        OracleFreshnessPolicyLib.Policy memory policy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile, false, false, 60, 300, 0, 0, 3 days
        );
        OracleFreshnessPolicyLib.Policy memory reversePolicy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.PoolReconcile, false, false, 300, 60, 0, 0, 3 days
        );

        assertEq(policy.maxStaleness, 60);
        assertEq(reversePolicy.maxStaleness, 60);
    }

    function test_CloseCommitFallback_RequiresStoredMarkButAllowsAnyStoredAge() public pure {
        OracleFreshnessPolicyLib.Policy memory policy = OracleFreshnessPolicyLib.getPolicy(
            OracleFreshnessPolicyLib.Mode.CloseCommitFallback, false, false, 60, 60, 60, 15, 3 days
        );

        assertTrue(policy.requireStoredMark);
        assertTrue(policy.allowAnyStoredMark);
        assertEq(policy.maxStaleness, 0);
    }

}

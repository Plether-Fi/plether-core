// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {Test} from "forge-std/Test.sol";

contract QueuedOpenNumericDomainTest is Test {

    function test_ReserveProductOverflowExcludesOnlyTheInvalidPrices() public pure {
        CfdTypes.RiskParams memory params;
        params.bountyBps = type(uint256).max;
        params.minBountyAssets = 1;

        assertEq(
            uint8(
                CfdEnginePlanLib.getQueuedOpenRevertCode(0, CfdTypes.SIZE_QUANTUM, type(uint256).max, 1, 2, 0, params)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK)
        );
        assertEq(
            uint8(
                CfdEnginePlanLib.getQueuedOpenRevertCode(0, CfdTypes.SIZE_QUANTUM, type(uint256).max, 2, 2, 0, params)
            ),
            uint8(CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED)
        );
    }

}

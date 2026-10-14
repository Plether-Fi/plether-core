// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @dev Exposes unchanged checked arithmetic as a domain oracle, plus the production reverting wrapper.
contract NumericDomainMathHarness {

    function oldSkewCost(
        uint256 skew,
        uint256 depth,
        uint256 factor
    ) external pure returns (uint256) {
        if (skew == 0 || depth == 0) {
            return 0;
        }
        uint256 scaledSkew = skew * 1e12;
        uint256 scaledDepth = depth * 1e12;
        uint256 squareOverDepth = scaledSkew * scaledSkew / scaledDepth;
        return (factor * squareOverDepth) / 1e18 / 2 / 1e12;
    }

    function productionSkewCost(
        uint256 skew,
        uint256 depth,
        uint256 factor
    ) external pure returns (uint256) {
        return CfdMath.getSkewCost(skew, depth, factor);
    }

}

contract NumericDomainLensHarness is CfdEngineLens {

    constructor() CfdEngineLens(address(0)) {}

    function formatOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta,
        ICfdEnginePlanner planner
    ) external pure returns (ICfdEngineTypes.OpenPreview memory) {
        return _openPreviewFromPlan(snap, delta, 0, planner);
    }

}

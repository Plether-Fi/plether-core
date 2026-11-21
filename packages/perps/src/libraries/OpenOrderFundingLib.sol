// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";

/// @notice Shared own-funds check for opening-order admission and execution.
library OpenOrderFundingLib {

    /// @dev Existing pledge, claims, free cash, and negative VPI cannot fund this order's own risk.
    ///      Admission supplies quoted VPI when available; execution always supplies the live planned VPI.
    function validate(
        CfdTypes.RiskParams memory risk,
        bool isFadWindow,
        uint256 notionalAssets,
        uint256 executionFeeAssets,
        int256 vpiAssets,
        uint256 marginAssets,
        OrderV3Types.ExecutionBounds memory bounds
    ) internal pure returns (CfdEnginePlanTypes.OpenRevertCode) {
        uint256 costAssets = executionFeeAssets + (vpiAssets > 0 ? uint256(vpiAssets) : 0);
        uint256 reserveAssets = Math.max((notionalAssets * risk.bountyBps) / 10_000, risk.minBountyAssets);
        if (costAssets > marginAssets || reserveAssets > marginAssets - costAssets) {
            return CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
        }
        uint256 equityAssets = marginAssets - costAssets - reserveAssets;
        uint256 initialRequirementAssets =
            Math.max((notionalAssets * risk.initMarginBps) / 10_000, risk.minBountyAssets);
        uint256 activeRequirementAssets =
            (notionalAssets * (isFadWindow ? risk.fadMarginBps : risk.maintMarginBps)) / 10_000;
        if (equityAssets <= initialRequirementAssets || equityAssets <= activeRequirementAssets) {
            return CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN;
        }
        if (equityAssets < bounds.minPostPositionEquityAssets) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation(
                OrderV3Types.ConstraintKind.PostPositionEquity, equityAssets, bounds.minPostPositionEquityAssets
            );
        }
        uint256 leverageBps = Math.mulDiv(notionalAssets, 10_000, equityAssets, Math.Rounding.Ceil);
        if (leverageBps > bounds.maxPostLeverageBps) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation(
                OrderV3Types.ConstraintKind.PostLeverage, leverageBps, bounds.maxPostLeverageBps
            );
        }
        return CfdEnginePlanTypes.OpenRevertCode.OK;
    }

}

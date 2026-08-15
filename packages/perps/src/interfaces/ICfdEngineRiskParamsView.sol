// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice ABI-compatible struct view of the engine's public `riskParams` tuple getter.
/// @dev The struct's static fields have the same return encoding as the generated getter's ten-value tuple.
interface ICfdEngineRiskParamsView {

    function riskParams() external view returns (CfdTypes.RiskParams memory);

}

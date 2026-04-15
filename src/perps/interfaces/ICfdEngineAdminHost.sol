// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngineAdminHost {

    function applyRiskParams(
        CfdTypes.RiskParams memory riskParams_
    ) external;

    function addFadDays(
        uint256[] calldata timestamps
    ) external;

    function removeFadDays(
        uint256[] calldata timestamps
    ) external;

    function setFadMaxStaleness(
        uint256 seconds_
    ) external;

    function setFadRunway(
        uint256 seconds_
    ) external;

    function setEngineMarkStalenessLimit(
        uint256 seconds_
    ) external;
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngineAdminHost {

    struct EngineRiskConfig {
        CfdTypes.RiskParams riskParams;
        uint256 executionFeeBps;
    }

    struct EngineCalendarConfig {
        uint256[] fadDayTimestamps;
        uint256 fadRunwaySeconds;
    }

    struct EngineFreshnessConfig {
        uint256 fadMaxStaleness;
        uint256 engineMarkStalenessLimit;
    }

    function applyRiskConfig(
        EngineRiskConfig calldata config
    ) external;

    function applyCalendarConfig(
        EngineCalendarConfig calldata config
    ) external;

    function applyFreshnessConfig(
        EngineFreshnessConfig calldata config
    ) external;

}

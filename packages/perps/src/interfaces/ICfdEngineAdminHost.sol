// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Engine host surface called by the timelocked engine admin.
interface ICfdEngineAdminHost {

    /// @notice Risk parameters, execution fee, and frozen close spread staged by governance.
    struct EngineRiskConfig {
        CfdTypes.RiskParams riskParams;
        uint256 executionFeeBps;
        /// @notice Fixed LP-owned spread charged only on oracle-frozen close/reduce notional, in basis points.
        uint256 frozenCloseSpreadBps;
    }

    /// @notice FAD calendar override timestamps and deleverage runway.
    struct EngineCalendarConfig {
        uint256[] fadDayTimestamps;
        uint256 fadRunwaySeconds;
    }

    /// @notice Mark freshness limits for frozen and live-market policy.
    struct EngineFreshnessConfig {
        uint256 fadMaxStaleness;
        uint256 engineMarkStalenessLimit;
    }

    /// @notice Applies finalized risk parameters, execution fee, and frozen close spread.
    /// @param config Risk configuration to apply
    function applyRiskConfig(
        EngineRiskConfig calldata config
    ) external;

    /// @notice Applies finalized FAD calendar overrides.
    /// @param config Calendar configuration to apply
    function applyCalendarConfig(
        EngineCalendarConfig calldata config
    ) external;

    /// @notice Applies finalized freshness limits.
    /// @param config Freshness configuration to apply
    function applyFreshnessConfig(
        EngineFreshnessConfig calldata config
    ) external;

}

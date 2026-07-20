// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Engine host surface called by the timelocked engine admin.
interface ICfdEngineAdminHost {

    /// @notice Risk parameters, execution fee, and frozen close spread staged by governance.
    /// @param riskParams VPI, skew, margin, carry, and liquidation-bounty parameters.
    /// @param executionFeeBps Protocol fee charged on executed notional, in basis points.
    /// @param frozenCloseSpreadBps LP-owned spread charged on oracle-frozen voluntary close notional, in basis points.
    struct EngineRiskConfig {
        CfdTypes.RiskParams riskParams;
        uint256 executionFeeBps;
        uint256 frozenCloseSpreadBps;
    }

    /// @notice FAD calendar override timestamps and deleverage runway.
    /// @param fadDayTimestamps Unix timestamps whose normalized UTC day numbers are configured as all-day FAD and
    ///        oracle-frozen overrides; duplicate normalized days are ignored by the engine.
    /// @param fadRunwaySeconds Look-ahead duration before an override day during which FAD restrictions apply.
    struct EngineCalendarConfig {
        uint256[] fadDayTimestamps;
        uint256 fadRunwaySeconds;
    }

    /// @notice Mark freshness limits for frozen and live-market policy.
    /// @param fadMaxStaleness Maximum cached-mark age while the oracle is frozen, in seconds.
    /// @param engineMarkStalenessLimit Engine component of the live cached-mark age limit, in seconds.
    struct EngineFreshnessConfig {
        uint256 fadMaxStaleness;
        uint256 engineMarkStalenessLimit;
    }

    /// @notice Applies finalized risk parameters, execution fee, and frozen close spread.
    /// @dev Callable only by the engine's configured admin. The admin owns validation and timelock enforcement; the
    ///      engine advances carry indexes before changing the carry rate.
    /// @param config Risk configuration to apply
    function applyRiskConfig(
        EngineRiskConfig calldata config
    ) external;

    /// @notice Applies finalized FAD calendar overrides.
    /// @dev Callable only by the configured admin. Replaces the complete override set after normalizing each input to
    ///      a Unix day number. The admin owns validation and timelock enforcement.
    /// @param config Calendar configuration to apply
    function applyCalendarConfig(
        EngineCalendarConfig calldata config
    ) external;

    /// @notice Applies finalized freshness limits.
    /// @dev Callable only by the configured admin, which owns validation and timelock enforcement.
    /// @param config Freshness configuration to apply
    function applyFreshnessConfig(
        EngineFreshnessConfig calldata config
    ) external;

}

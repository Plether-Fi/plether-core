// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Engine host surface called by the timelocked engine admin.
interface ICfdEngineAdminHost {

    /// @notice Risk parameters, execution fee, frozen close spread, and settlement buffer staged by governance.
    /// @param riskParams VPI, skew, margin, carry, and liquidation-bounty parameters.
    /// @param executionFeeBps Protocol fee charged on executed notional, in basis points.
    /// @param frozenCloseSpreadBps LP-owned spread charged on oracle-frozen voluntary close notional, in basis points.
    /// @param settlementBufferBps Protected headroom per unit of maximum directional liability, in basis points.
    struct EngineRiskConfig {
        CfdTypes.RiskParams riskParams;
        uint256 executionFeeBps;
        uint256 frozenCloseSpreadBps;
        uint256 settlementBufferBps;
    }

    /// @notice Scheduled market closure as a half-open interval of Unix timestamps.
    /// @param startTime First second when frozen-oracle policy applies.
    /// @param endTime First second after the closure, subject to any other active calendar rules.
    struct MarketClosure {
        uint64 startTime;
        uint64 endTime;
    }

    /// @notice FAD calendar override timestamps, deleverage runway, and scheduled market closures.
    /// @param fadDayTimestamps Unix timestamps whose normalized UTC day numbers activate all-day FAD and add freezing
    ///        only before that day's 17:00 New York boundary. Recurring weekend freezing still applies; duplicate
    ///        normalized days are ignored by the engine.
    /// @param fadRunwaySeconds Duration of FAD restrictions before an override day or scheduled closure starts.
    /// @param marketClosures Scheduled closures ordered by start time with no overlaps. FAD also stays active for
    ///        15 minutes after each closure ends.
    struct EngineCalendarConfig {
        uint256[] fadDayTimestamps;
        uint256 fadRunwaySeconds;
        MarketClosure[] marketClosures;
    }

    /// @notice Mark freshness limits for frozen and live-market policy.
    /// @param fadMaxStaleness Maximum cached-mark age while the oracle is frozen, in seconds.
    /// @param engineMarkStalenessLimit Engine component of the live cached-mark age limit, in seconds.
    struct EngineFreshnessConfig {
        uint256 fadMaxStaleness;
        uint256 engineMarkStalenessLimit;
    }

    /// @notice Applies finalized risk parameters, execution fee, frozen close spread, and settlement buffer.
    /// @dev Callable only by the engine's configured admin. The admin owns validation and timelock enforcement; the
    ///      engine advances the carry index before changing the carry rate.
    /// @param config Risk configuration to apply
    function applyRiskConfig(
        EngineRiskConfig calldata config
    ) external;

    /// @notice Applies the finalized FAD calendar and scheduled closures.
    /// @dev Callable only by the configured admin. Replaces the day overrides and closure intervals. Each day
    ///      override is normalized to a Unix day number. The admin owns validation and timelock enforcement.
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

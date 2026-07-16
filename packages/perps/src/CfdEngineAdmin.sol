// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

/// @notice Timelocked two-step owner-controlled admin for CfdEngine risk, FAD calendar, and freshness configuration.
contract CfdEngineAdmin is Ownable2Step {

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant MAX_FROZEN_CLOSE_SPREAD_BPS = 1000;

    ICfdEngineAdminHost public immutable engine;

    ICfdEngineAdminHost.EngineRiskConfig public pendingRiskConfig;
    uint256 public riskConfigActivationTime;

    ICfdEngineAdminHost.EngineCalendarConfig private _pendingCalendarConfig;
    uint256 public calendarConfigActivationTime;

    ICfdEngineAdminHost.EngineFreshnessConfig public pendingFreshnessConfig;
    uint256 public freshnessConfigActivationTime;

    error CfdEngineAdmin__NoProposal();
    error CfdEngineAdmin__TimelockNotReady();
    error CfdEngineAdmin__ZeroStaleness();
    error CfdEngineAdmin__RunwayTooLong();
    error CfdEngineAdmin__InvalidRiskParams();
    error CfdEngineAdmin__InvalidExecutionFee();

    event RiskConfigProposed(ICfdEngineAdminHost.EngineRiskConfig config, uint256 activationTime);
    event RiskConfigFinalized(ICfdEngineAdminHost.EngineRiskConfig config);
    event RiskConfigCancelled();
    event CalendarConfigProposed(ICfdEngineAdminHost.EngineCalendarConfig config, uint256 activationTime);
    event CalendarConfigFinalized(ICfdEngineAdminHost.EngineCalendarConfig config);
    event CalendarConfigCancelled();
    event FreshnessConfigProposed(ICfdEngineAdminHost.EngineFreshnessConfig config, uint256 activationTime);
    event FreshnessConfigFinalized(ICfdEngineAdminHost.EngineFreshnessConfig config);
    event FreshnessConfigCancelled();

    /// @param engine_ Engine host that receives finalized configuration
    /// @param initialOwner Owner allowed to propose, cancel, and finalize configuration
    constructor(
        address engine_,
        address initialOwner
    ) Ownable(initialOwner) {
        engine = ICfdEngineAdminHost(engine_);
    }

    /// @notice Proposes risk parameters, execution-fee, and frozen-close-spread changes behind the timelock.
    /// @param config Risk configuration to validate and stage
    function proposeRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig calldata config
    ) external onlyOwner {
        _validateRiskParams(config.riskParams);
        if (config.executionFeeBps == 0 || config.executionFeeBps > 10_000) {
            revert CfdEngineAdmin__InvalidExecutionFee();
        }
        if (config.frozenCloseSpreadBps == 0 || config.frozenCloseSpreadBps > MAX_FROZEN_CLOSE_SPREAD_BPS) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        pendingRiskConfig = config;
        riskConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RiskConfigProposed(config, riskConfigActivationTime);
    }

    /// @notice Finalizes the pending risk configuration after the timelock expires.
    function finalizeRiskConfig() external onlyOwner {
        _requireTimelockReady(riskConfigActivationTime);
        ICfdEngineAdminHost.EngineRiskConfig memory config = pendingRiskConfig;
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        engine.applyRiskConfig(config);
        emit RiskConfigFinalized(config);
    }

    /// @notice Cancels any pending risk configuration.
    function cancelRiskConfig() external onlyOwner {
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        emit RiskConfigCancelled();
    }

    /// @notice Proposes FAD calendar overrides and runway seconds behind the timelock.
    /// @param config Calendar configuration to validate and stage
    function proposeCalendarConfig(
        ICfdEngineAdminHost.EngineCalendarConfig calldata config
    ) external onlyOwner {
        if (config.fadRunwaySeconds > 24 hours) {
            revert CfdEngineAdmin__RunwayTooLong();
        }
        delete _pendingCalendarConfig.fadDayTimestamps;
        _pendingCalendarConfig.fadDayTimestamps = config.fadDayTimestamps;
        _pendingCalendarConfig.fadRunwaySeconds = config.fadRunwaySeconds;
        calendarConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit CalendarConfigProposed(config, calendarConfigActivationTime);
    }

    /// @notice Finalizes the pending calendar configuration after the timelock expires.
    function finalizeCalendarConfig() external onlyOwner {
        _requireTimelockReady(calendarConfigActivationTime);
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _pendingCalendarConfig;
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        engine.applyCalendarConfig(config);
        emit CalendarConfigFinalized(config);
    }

    /// @notice Cancels any pending calendar configuration.
    function cancelCalendarConfig() external onlyOwner {
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        emit CalendarConfigCancelled();
    }

    /// @notice Returns the pending calendar configuration, including staged dynamic FAD days.
    /// @return config Pending calendar configuration
    function getPendingCalendarConfig() external view returns (ICfdEngineAdminHost.EngineCalendarConfig memory config) {
        config = _pendingCalendarConfig;
    }

    /// @notice Proposes engine freshness limits behind the timelock.
    /// @param config Freshness configuration to validate and stage
    function proposeFreshnessConfig(
        ICfdEngineAdminHost.EngineFreshnessConfig calldata config
    ) external onlyOwner {
        if (config.fadMaxStaleness == 0 || config.engineMarkStalenessLimit == 0) {
            revert CfdEngineAdmin__ZeroStaleness();
        }
        pendingFreshnessConfig = config;
        freshnessConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FreshnessConfigProposed(config, freshnessConfigActivationTime);
    }

    /// @notice Finalizes the pending freshness configuration after the timelock expires.
    function finalizeFreshnessConfig() external onlyOwner {
        _requireTimelockReady(freshnessConfigActivationTime);
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = pendingFreshnessConfig;
        delete pendingFreshnessConfig;
        freshnessConfigActivationTime = 0;
        engine.applyFreshnessConfig(config);
        emit FreshnessConfigFinalized(config);
    }

    /// @notice Cancels any pending freshness configuration.
    function cancelFreshnessConfig() external onlyOwner {
        delete pendingFreshnessConfig;
        freshnessConfigActivationTime = 0;
        emit FreshnessConfigCancelled();
    }

    function _requireTimelockReady(
        uint256 activationTime
    ) internal view {
        if (activationTime == 0) {
            revert CfdEngineAdmin__NoProposal();
        }
        if (block.timestamp < activationTime) {
            revert CfdEngineAdmin__TimelockNotReady();
        }
    }

    function _validateRiskParams(
        CfdTypes.RiskParams memory riskParams_
    ) internal pure {
        if (riskParams_.maintMarginBps == 0 || riskParams_.initMarginBps < riskParams_.maintMarginBps) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.fadMarginBps < riskParams_.maintMarginBps) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.initMarginBps > 10_000 || riskParams_.fadMarginBps > 10_000) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.baseCarryBps > 100_000) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.minBountyUsdc == 0 || riskParams_.bountyBps == 0) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
    }

}

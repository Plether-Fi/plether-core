// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {ICfdEngineAdminHost} from "./interfaces/ICfdEngineAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CfdEngineAdmin is Ownable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;

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

    constructor(address engine_, address initialOwner) Ownable(initialOwner) {
        engine = ICfdEngineAdminHost(engine_);
    }

    function proposeRiskConfig(
        ICfdEngineAdminHost.EngineRiskConfig calldata config
    ) external onlyOwner {
        _validateRiskParams(config.riskParams);
        if (config.executionFeeBps == 0 || config.executionFeeBps > 10_000) {
            revert CfdEngineAdmin__InvalidExecutionFee();
        }
        pendingRiskConfig = config;
        riskConfigActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RiskConfigProposed(config, riskConfigActivationTime);
    }

    function finalizeRiskConfig() external onlyOwner {
        _requireTimelockReady(riskConfigActivationTime);
        ICfdEngineAdminHost.EngineRiskConfig memory config = pendingRiskConfig;
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        engine.applyRiskConfig(config);
        emit RiskConfigFinalized(config);
    }

    function cancelRiskConfig() external onlyOwner {
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        emit RiskConfigCancelled();
    }

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

    function finalizeCalendarConfig() external onlyOwner {
        _requireTimelockReady(calendarConfigActivationTime);
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _pendingCalendarConfig;
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        engine.applyCalendarConfig(config);
        emit CalendarConfigFinalized(config);
    }

    function cancelCalendarConfig() external onlyOwner {
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        emit CalendarConfigCancelled();
    }

    function getPendingCalendarConfig()
        external
        view
        returns (ICfdEngineAdminHost.EngineCalendarConfig memory config)
    {
        config = _pendingCalendarConfig;
    }

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

    function finalizeFreshnessConfig() external onlyOwner {
        _requireTimelockReady(freshnessConfigActivationTime);
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = pendingFreshnessConfig;
        delete pendingFreshnessConfig;
        freshnessConfigActivationTime = 0;
        engine.applyFreshnessConfig(config);
        emit FreshnessConfigFinalized(config);
    }

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
        if (riskParams_.minBountyUsdc == 0 || riskParams_.bountyBps == 0) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
        if (riskParams_.maxSkewRatio > CfdMath.WAD) {
            revert CfdEngineAdmin__InvalidRiskParams();
        }
    }
}

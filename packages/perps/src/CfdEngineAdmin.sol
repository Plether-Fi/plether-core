// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";

/// @title CfdEngineAdmin
/// @notice Timelocked, two-step owner-controlled administrator for risk, FAD calendar, and mark freshness.
/// @dev Risk, calendar, and freshness proposals use independent single-slot queues. Re-proposing a category overwrites
///      its pending value and restarts that category's 48-hour delay. Proposals survive ownership transfer, so the
///      current owner at execution time may finalize or cancel them. Finalization is permitted at or after its activation
///      timestamp and proposals do not expire. Basis-point values use a 10,000 denominator, WAD values use 1e18,
///      USDC amounts use 6 decimals, and timestamps/durations use seconds.
contract CfdEngineAdmin is Ownable2Step {

    /// @notice Delay between a proposal and its earliest finalization, in seconds.
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    /// @notice Maximum oracle-frozen close spread, in basis points (10%).
    uint256 public constant MAX_FROZEN_CLOSE_SPREAD_BPS = 1000;

    /// @notice Engine host that receives finalized configuration.
    ICfdEngineAdminHost public immutable engine;

    /// @notice Latest staged risk, execution-fee, and frozen-spread configuration.
    ICfdEngineAdminHost.EngineRiskConfig public pendingRiskConfig;
    /// @notice Earliest Unix timestamp for risk finalization, or zero when none is active.
    uint256 public riskConfigActivationTime;

    ICfdEngineAdminHost.EngineCalendarConfig private _pendingCalendarConfig;
    /// @notice Earliest Unix timestamp for calendar finalization, or zero when none is active.
    uint256 public calendarConfigActivationTime;

    /// @notice Latest staged frozen-market and live cached-mark freshness limits.
    ICfdEngineAdminHost.EngineFreshnessConfig public pendingFreshnessConfig;
    /// @notice Earliest Unix timestamp for freshness finalization, or zero when none is active.
    uint256 public freshnessConfigActivationTime;

    /// @notice Thrown when finalization is requested without an active proposal in that category.
    error CfdEngineAdmin__NoProposal();
    /// @notice Thrown when finalization is requested before the category's activation timestamp.
    error CfdEngineAdmin__TimelockNotReady();
    /// @notice Thrown when either proposed freshness duration is zero.
    error CfdEngineAdmin__ZeroStaleness();
    /// @notice Thrown when the proposed pre-FAD runway exceeds 24 hours.
    error CfdEngineAdmin__RunwayTooLong();
    /// @notice Thrown when a risk parameter or frozen-close spread violates the accepted bounds.
    error CfdEngineAdmin__InvalidRiskParams();
    /// @notice Thrown when the execution fee is zero or exceeds 10,000 basis points.
    error CfdEngineAdmin__InvalidExecutionFee();

    /// @notice Emitted when the current owner stages or replaces the risk-category proposal.
    /// @param config Complete staged risk configuration.
    /// @param activationTime Earliest Unix timestamp at which it may be finalized.
    event RiskConfigProposed(ICfdEngineAdminHost.EngineRiskConfig config, uint256 activationTime);
    /// @notice Emitted after a staged risk configuration is applied to the engine.
    /// @param config Risk configuration applied to the engine.
    event RiskConfigFinalized(ICfdEngineAdminHost.EngineRiskConfig config);
    /// @notice Emitted whenever the owner clears the risk proposal slot, including when it was already empty.
    event RiskConfigCancelled();
    /// @notice Emitted when the current owner stages or replaces the calendar-category proposal.
    /// @param config Complete staged FAD-day replacement and runway.
    /// @param activationTime Earliest Unix timestamp at which it may be finalized.
    event CalendarConfigProposed(ICfdEngineAdminHost.EngineCalendarConfig config, uint256 activationTime);
    /// @notice Emitted after a staged calendar configuration is applied to the engine.
    /// @param config Calendar configuration applied to the engine.
    event CalendarConfigFinalized(ICfdEngineAdminHost.EngineCalendarConfig config);
    /// @notice Emitted whenever the owner clears the calendar proposal, including when it was already inactive.
    event CalendarConfigCancelled();
    /// @notice Emitted when the current owner stages or replaces the freshness-category proposal.
    /// @param config Complete staged oracle-frozen and live cached-mark freshness limits.
    /// @param activationTime Earliest Unix timestamp at which it may be finalized.
    event FreshnessConfigProposed(ICfdEngineAdminHost.EngineFreshnessConfig config, uint256 activationTime);
    /// @notice Emitted after a staged freshness configuration is applied to the engine.
    /// @param config Freshness configuration applied to the engine.
    event FreshnessConfigFinalized(ICfdEngineAdminHost.EngineFreshnessConfig config);
    /// @notice Emitted whenever the owner clears the freshness proposal slot, including when it was already empty.
    event FreshnessConfigCancelled();

    /// @notice Creates an administrator bound to one engine host and initial owner.
    /// @dev `engine_` is stored without zero-address, code-size, or interface validation. The inherited `Ownable`
    ///      constructor rejects a zero `initialOwner`.
    /// @param engine_ Engine host that receives finalized configuration.
    /// @param initialOwner Initial owner allowed to propose, cancel, and finalize configuration.
    constructor(
        address engine_,
        address initialOwner
    ) Ownable(initialOwner) {
        engine = ICfdEngineAdminHost(engine_);
    }

    /// @notice Validates and stages risk parameters, execution fee, and oracle-frozen close spread.
    /// @dev Callable only by the current owner. Replaces any pending risk proposal and resets its delay. Maintenance
    ///      margin must be nonzero; initial margin must be at least maintenance; FAD margin must be at least maintenance;
    ///      initial and FAD margin may not exceed 10,000 bps; annual base carry may not exceed 100,000 bps; minimum
    ///      bounty and bounty bps must be nonzero; and max skew may not exceed 1e18. There is no admin-side upper bound
    ///      on `vpiFactor` or `bountyBps`, and FAD margin need not be at least initial margin. The open/close execution
    ///      fee must be 1..10,000 bps and the oracle-frozen close spread must be 1..1,000 bps.
    /// @param config Complete risk configuration to validate and stage.
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

    /// @notice Applies the pending risk configuration once its timelock has elapsed.
    /// @dev Callable only by the current owner. Clears the local proposal before calling the engine, but an engine revert
    ///      rolls back those clears and the event. The canonical engine checkpoints both side carry indexes under the old
    ///      carry rate before replacing risk parameters, execution fee, and frozen-close spread.
    function finalizeRiskConfig() external onlyOwner {
        _requireTimelockReady(riskConfigActivationTime);
        ICfdEngineAdminHost.EngineRiskConfig memory config = pendingRiskConfig;
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        engine.applyRiskConfig(config);
        emit RiskConfigFinalized(config);
    }

    /// @notice Immediately clears the risk proposal slot and activation timestamp.
    /// @dev Callable only by the current owner. This operation is idempotent and emits even if no proposal exists.
    function cancelRiskConfig() external onlyOwner {
        delete pendingRiskConfig;
        riskConfigActivationTime = 0;
        emit RiskConfigCancelled();
    }

    /// @notice Stages a complete replacement set of FAD calendar overrides and a pre-day runway.
    /// @dev Callable only by the current owner. Replaces any pending calendar proposal and resets its delay. Only the
    ///      runway is validated: it may be 0..86,400 seconds inclusive, while timestamps may be arbitrary. On engine
    ///      application, timestamps are floored to UTC day numbers and duplicates are ignored; configured days activate
    ///      both FAD and oracle-frozen mode for that day, while the runway only extends FAD before a configured day.
    /// @param config Full FAD timestamp replacement and runway duration to stage.
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

    /// @notice Applies the pending full calendar replacement once its timelock has elapsed.
    /// @dev Callable only by the current owner. An empty day list clears all admin overrides but not built-in calendar
    ///      behavior. This clears the staged timestamp array and activation time before the engine call; a revert rolls
    ///      everything back. This function does not clear the private staged runway scalar, which is not evidence of an
    ///      active proposal; `calendarConfigActivationTime` is authoritative.
    function finalizeCalendarConfig() external onlyOwner {
        _requireTimelockReady(calendarConfigActivationTime);
        ICfdEngineAdminHost.EngineCalendarConfig memory config = _pendingCalendarConfig;
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        engine.applyCalendarConfig(config);
        emit CalendarConfigFinalized(config);
    }

    /// @notice Immediately clears the staged calendar day array and activation timestamp.
    /// @dev Callable only by the current owner. This operation is idempotent and emits even if no proposal exists. The
    ///      staged runway scalar remains observable through `getPendingCalendarConfig`; an activation time of zero means
    ///      there is no active proposal.
    function cancelCalendarConfig() external onlyOwner {
        delete _pendingCalendarConfig.fadDayTimestamps;
        calendarConfigActivationTime = 0;
        emit CalendarConfigCancelled();
    }

    /// @notice Returns the staged calendar storage, including its dynamic FAD-day array.
    /// @dev After finalization or cancellation, the returned day array is empty but the previous runway value can remain;
    ///      consult `calendarConfigActivationTime` to determine whether the returned value is an active proposal.
    /// @return config Stored calendar proposal data.
    function getPendingCalendarConfig() external view returns (ICfdEngineAdminHost.EngineCalendarConfig memory config) {
        config = _pendingCalendarConfig;
    }

    /// @notice Validates and stages oracle-frozen and live cached-mark freshness limits.
    /// @dev Callable only by the current owner. Replaces any pending freshness proposal and resets its delay. Both limits
    ///      must be nonzero seconds, with no admin-side maximum. `fadMaxStaleness` applies when the oracle is frozen, not
    ///      throughout the entire FAD window. The live engine limit caps HousePool reconcile freshness and is combined
    ///      with the pool limit by taking the tighter nonzero duration; router execution limits are configured separately.
    /// @param config Frozen-market and live engine freshness durations to validate and stage.
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

    /// @notice Applies the pending freshness configuration once its timelock has elapsed.
    /// @dev Callable only by the current owner. Clears the local proposal before calling the engine, but an engine revert
    ///      rolls back those clears and the event.
    function finalizeFreshnessConfig() external onlyOwner {
        _requireTimelockReady(freshnessConfigActivationTime);
        ICfdEngineAdminHost.EngineFreshnessConfig memory config = pendingFreshnessConfig;
        delete pendingFreshnessConfig;
        freshnessConfigActivationTime = 0;
        engine.applyFreshnessConfig(config);
        emit FreshnessConfigFinalized(config);
    }

    /// @notice Immediately clears the freshness proposal slot and activation timestamp.
    /// @dev Callable only by the current owner. This operation is idempotent and emits even if no proposal exists.
    function cancelFreshnessConfig() external onlyOwner {
        delete pendingFreshnessConfig;
        freshnessConfigActivationTime = 0;
        emit FreshnessConfigCancelled();
    }

    /// @notice Requires an active proposal whose activation timestamp has been reached.
    /// @param activationTime Category activation time in Unix seconds, or zero when no proposal is active.
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

    /// @notice Validates the risk-parameter bounds enforced at proposal time.
    /// @param riskParams_ Proposed VPI, skew, margin, carry, and bounty configuration.
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

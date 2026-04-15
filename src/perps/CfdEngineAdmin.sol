// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {CfdMath} from "./CfdMath.sol";
import {ICfdEngineAdminHost} from "./interfaces/ICfdEngineAdminHost.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CfdEngineAdmin is Ownable {

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    ICfdEngineAdminHost public immutable engine;

    CfdTypes.RiskParams public pendingRiskParams;
    uint256 public riskParamsActivationTime;

    uint256[] private _pendingAddFadDays;
    uint256 public addFadDaysActivationTime;

    uint256[] private _pendingRemoveFadDays;
    uint256 public removeFadDaysActivationTime;

    uint256 public pendingFadMaxStaleness;
    uint256 public fadMaxStalenessActivationTime;

    uint256 public pendingFadRunway;
    uint256 public fadRunwayActivationTime;

    uint256 public pendingEngineMarkStalenessLimit;
    uint256 public engineMarkStalenessActivationTime;

    error CfdEngineAdmin__NoProposal();
    error CfdEngineAdmin__TimelockNotReady();
    error CfdEngineAdmin__EmptyDays();
    error CfdEngineAdmin__ZeroStaleness();
    error CfdEngineAdmin__RunwayTooLong();
    error CfdEngineAdmin__InvalidRiskParams();

    event RiskParamsProposed(uint256 activationTime);
    event RiskParamsFinalized();
    event RiskParamsProposalCancelled();
    event AddFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event AddFadDaysFinalized();
    event AddFadDaysProposalCancelled();
    event RemoveFadDaysProposed(uint256[] timestamps, uint256 activationTime);
    event RemoveFadDaysFinalized();
    event RemoveFadDaysProposalCancelled();
    event FadMaxStalenessProposed(uint256 newStaleness, uint256 activationTime);
    event FadMaxStalenessFinalized();
    event FadRunwayProposed(uint256 newRunway, uint256 activationTime);
    event FadRunwayFinalized();
    event EngineMarkStalenessLimitProposed(uint256 newStaleness, uint256 activationTime);

    constructor(address engine_, address initialOwner) Ownable(initialOwner) {
        engine = ICfdEngineAdminHost(engine_);
    }

    function proposeRiskParams(
        CfdTypes.RiskParams memory riskParams_
    ) external onlyOwner {
        _validateRiskParams(riskParams_);
        pendingRiskParams = riskParams_;
        riskParamsActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RiskParamsProposed(riskParamsActivationTime);
    }

    function finalizeRiskParams() external onlyOwner {
        _requireTimelockReady(riskParamsActivationTime);
        CfdTypes.RiskParams memory nextRiskParams = pendingRiskParams;
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
        engine.applyRiskParams(nextRiskParams);
        emit RiskParamsFinalized();
    }

    function cancelRiskParamsProposal() external onlyOwner {
        delete pendingRiskParams;
        riskParamsActivationTime = 0;
        emit RiskParamsProposalCancelled();
    }

    function proposeAddFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngineAdmin__EmptyDays();
        }
        _pendingAddFadDays = timestamps;
        addFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit AddFadDaysProposed(timestamps, addFadDaysActivationTime);
    }

    function finalizeAddFadDays() external onlyOwner {
        _requireTimelockReady(addFadDaysActivationTime);
        uint256[] memory timestamps = _pendingAddFadDays;
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
        engine.addFadDays(timestamps);
        emit AddFadDaysFinalized();
    }

    function cancelAddFadDaysProposal() external onlyOwner {
        delete _pendingAddFadDays;
        addFadDaysActivationTime = 0;
        emit AddFadDaysProposalCancelled();
    }

    function proposeRemoveFadDays(
        uint256[] calldata timestamps
    ) external onlyOwner {
        if (timestamps.length == 0) {
            revert CfdEngineAdmin__EmptyDays();
        }
        _pendingRemoveFadDays = timestamps;
        removeFadDaysActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit RemoveFadDaysProposed(timestamps, removeFadDaysActivationTime);
    }

    function finalizeRemoveFadDays() external onlyOwner {
        _requireTimelockReady(removeFadDaysActivationTime);
        uint256[] memory timestamps = _pendingRemoveFadDays;
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
        engine.removeFadDays(timestamps);
        emit RemoveFadDaysFinalized();
    }

    function cancelRemoveFadDaysProposal() external onlyOwner {
        delete _pendingRemoveFadDays;
        removeFadDaysActivationTime = 0;
        emit RemoveFadDaysProposalCancelled();
    }

    function proposeFadMaxStaleness(
        uint256 seconds_
    ) external onlyOwner {
        if (seconds_ == 0) {
            revert CfdEngineAdmin__ZeroStaleness();
        }
        pendingFadMaxStaleness = seconds_;
        fadMaxStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadMaxStalenessProposed(seconds_, fadMaxStalenessActivationTime);
    }

    function finalizeFadMaxStaleness() external onlyOwner {
        _requireTimelockReady(fadMaxStalenessActivationTime);
        uint256 nextValue = pendingFadMaxStaleness;
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
        engine.setFadMaxStaleness(nextValue);
        emit FadMaxStalenessFinalized();
    }

    function cancelFadMaxStalenessProposal() external onlyOwner {
        pendingFadMaxStaleness = 0;
        fadMaxStalenessActivationTime = 0;
    }

    function proposeFadRunway(
        uint256 seconds_
    ) external onlyOwner {
        if (seconds_ > 24 hours) {
            revert CfdEngineAdmin__RunwayTooLong();
        }
        pendingFadRunway = seconds_;
        fadRunwayActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit FadRunwayProposed(seconds_, fadRunwayActivationTime);
    }

    function finalizeFadRunway() external onlyOwner {
        _requireTimelockReady(fadRunwayActivationTime);
        uint256 nextValue = pendingFadRunway;
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
        engine.setFadRunway(nextValue);
        emit FadRunwayFinalized();
    }

    function cancelFadRunwayProposal() external onlyOwner {
        pendingFadRunway = 0;
        fadRunwayActivationTime = 0;
    }

    function proposeEngineMarkStalenessLimit(
        uint256 newStaleness
    ) external onlyOwner {
        if (newStaleness == 0) {
            revert CfdEngineAdmin__ZeroStaleness();
        }
        pendingEngineMarkStalenessLimit = newStaleness;
        engineMarkStalenessActivationTime = block.timestamp + TIMELOCK_DELAY;
        emit EngineMarkStalenessLimitProposed(newStaleness, engineMarkStalenessActivationTime);
    }

    function finalizeEngineMarkStalenessLimit() external onlyOwner {
        _requireTimelockReady(engineMarkStalenessActivationTime);
        uint256 nextValue = pendingEngineMarkStalenessLimit;
        pendingEngineMarkStalenessLimit = 0;
        engineMarkStalenessActivationTime = 0;
        engine.setEngineMarkStalenessLimit(nextValue);
    }

    function cancelEngineMarkStalenessLimitProposal() external onlyOwner {
        pendingEngineMarkStalenessLimit = 0;
        engineMarkStalenessActivationTime = 0;
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

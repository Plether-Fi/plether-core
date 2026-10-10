// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EmergencyPauseCoordinator} from "@plether/perps/EmergencyPauseCoordinator.sol";
import {Test} from "forge-std/Test.sol";

contract EmergencyPauseTargetMock is Pausable {

    address public pauser;
    uint64 public riskOffOrderCutoff;
    uint64 public nextRiskOffOrderCutoff;
    uint256 public pauseCalls;
    uint256 public settlementPauseCalls;
    bool public failPause;
    bool public failSettlementPause;
    bool public lpEpochSettlementPaused;

    error EmergencyPauseTargetMock__Unauthorized();
    error EmergencyPauseTargetMock__ForcedFailure();

    function setPauser(
        address newPauser
    ) external {
        pauser = newPauser;
    }

    function setNextRiskOffOrderCutoff(
        uint64 cutoff
    ) external {
        nextRiskOffOrderCutoff = cutoff;
    }

    function setFailPause(
        bool shouldFail
    ) external {
        failPause = shouldFail;
    }

    function setFailSettlementPause(
        bool shouldFail
    ) external {
        failSettlementPause = shouldFail;
    }

    function forcePause() external {
        _pause();
    }

    function forceLpEpochSettlementPause() external {
        lpEpochSettlementPaused = true;
    }

    function pause() external {
        if (msg.sender != pauser) {
            revert EmergencyPauseTargetMock__Unauthorized();
        }
        if (failPause) {
            revert EmergencyPauseTargetMock__ForcedFailure();
        }
        ++pauseCalls;
        riskOffOrderCutoff = nextRiskOffOrderCutoff;
        _pause();
    }

    function unpause() external {
        _unpause();
    }

    function pauseLpEpochSettlement() external {
        if (msg.sender != pauser) {
            revert EmergencyPauseTargetMock__Unauthorized();
        }
        if (failSettlementPause) {
            revert EmergencyPauseTargetMock__ForcedFailure();
        }
        ++settlementPauseCalls;
        lpEpochSettlementPaused = true;
    }

    function unpauseLpEpochSettlement() external {
        lpEpochSettlementPaused = false;
    }

}

abstract contract EmergencyPauseCoordinatorTestFixture is Test {

    uint256 internal constant COORDINATOR_RUNTIME_SIZE_TARGET = 6000;
    address internal constant OWNER = address(0xA11CE);
    address internal constant NEXT_OWNER = address(0xB0B);
    address internal constant GUARDIAN = address(0xCAFE);
    address internal constant STRANGER = address(0xBAD);
    uint64 internal constant CUTOFF = 42;
    bytes32 internal constant REASON_HASH = keccak256("oracle-divergence");
    bytes32 internal constant EVIDENCE_HASH = keccak256("incident-2026-08-24");

    EmergencyPauseTargetMock internal routerAdmin;
    EmergencyPauseTargetMock internal housePool;
    EmergencyPauseCoordinator internal coordinator;

    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event EmergencyContainmentTriggered(
        address indexed guardian,
        bytes32 indexed reasonHash,
        bytes32 indexed evidenceHash,
        EmergencyPauseCoordinator.ContainmentAction action,
        uint64 riskOffOrderCutoff,
        uint8 previousRestrictionMask,
        uint8 newRestrictionMask
    );

    function setUp() public {
        routerAdmin = new EmergencyPauseTargetMock();
        housePool = new EmergencyPauseTargetMock();
        routerAdmin.setNextRiskOffOrderCutoff(CUTOFF);
        coordinator = new EmergencyPauseCoordinator(address(routerAdmin), address(housePool), OWNER);
        routerAdmin.setPauser(address(coordinator));
        housePool.setPauser(address(coordinator));
    }

    function _setGuardian(
        address newGuardian
    ) internal {
        vm.prank(OWNER);
        coordinator.setGuardian(newGuardian);
    }

}

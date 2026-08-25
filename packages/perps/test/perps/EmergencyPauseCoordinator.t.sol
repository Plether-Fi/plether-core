// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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

contract EmergencyPauseCoordinatorTest is Test {

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

    function test_ConstructorBindsComponentsAndStartsGuardianDisabled() public view {
        assertEq(address(coordinator.ROUTER_ADMIN()), address(routerAdmin));
        assertEq(address(coordinator.HOUSE_POOL()), address(housePool));
        assertEq(coordinator.owner(), OWNER);
        assertEq(coordinator.guardian(), address(0));
        assertEq(coordinator.ROUTER_ADMIN_PAUSED_MASK(), 1);
        assertEq(coordinator.HOUSE_POOL_PAUSED_MASK(), 2);
        assertEq(coordinator.LP_EPOCH_SETTLEMENT_PAUSED_MASK(), 4);
        assertEq(coordinator.RISK_OFF_PAUSED_MASK(), 3);
        assertEq(coordinator.FULL_CONTAINMENT_PAUSED_MASK(), 7);
        assertLe(address(coordinator).code.length, COORDINATOR_RUNTIME_SIZE_TARGET);
    }

    function test_ConstructorRejectsZeroRouterAdmin() public {
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__ZeroAddress.selector);
        new EmergencyPauseCoordinator(address(0), address(housePool), OWNER);
    }

    function test_ConstructorRejectsZeroHousePool() public {
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__ZeroAddress.selector);
        new EmergencyPauseCoordinator(address(routerAdmin), address(0), OWNER);
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new EmergencyPauseCoordinator(address(routerAdmin), address(housePool), address(0));
    }

    function test_ConstructorRejectsDuplicateTargets() public {
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__DuplicateTarget.selector);
        new EmergencyPauseCoordinator(address(routerAdmin), address(routerAdmin), OWNER);
    }

    function test_ConstructorRejectsRouterAdminWithoutCode() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                EmergencyPauseCoordinator.EmergencyPauseCoordinator__TargetHasNoCode.selector, STRANGER
            )
        );
        new EmergencyPauseCoordinator(STRANGER, address(housePool), OWNER);
    }

    function test_ConstructorRejectsHousePoolWithoutCode() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                EmergencyPauseCoordinator.EmergencyPauseCoordinator__TargetHasNoCode.selector, STRANGER
            )
        );
        new EmergencyPauseCoordinator(address(routerAdmin), STRANGER, OWNER);
    }

    function test_SetGuardianIsOwnerOnlyAndAcceptsZero() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        coordinator.setGuardian(GUARDIAN);

        vm.expectEmit(true, true, false, true, address(coordinator));
        emit GuardianUpdated(address(0), GUARDIAN);
        vm.prank(OWNER);
        coordinator.setGuardian(GUARDIAN);
        assertEq(coordinator.guardian(), GUARDIAN);

        vm.expectEmit(true, true, false, true, address(coordinator));
        emit GuardianUpdated(GUARDIAN, address(0));
        vm.prank(OWNER);
        coordinator.setGuardian(address(0));
        assertEq(coordinator.guardian(), address(0));
    }

    function test_OwnershipTransferUsesTwoStepAcceptance() public {
        vm.prank(OWNER);
        coordinator.transferOwnership(NEXT_OWNER);
        assertEq(coordinator.owner(), OWNER);
        assertEq(coordinator.pendingOwner(), NEXT_OWNER);

        vm.prank(NEXT_OWNER);
        coordinator.acceptOwnership();
        assertEq(coordinator.owner(), NEXT_OWNER);
        assertEq(coordinator.pendingOwner(), address(0));

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        coordinator.setGuardian(GUARDIAN);

        vm.prank(NEXT_OWNER);
        coordinator.setGuardian(GUARDIAN);
        assertEq(coordinator.guardian(), GUARDIAN);
    }

    function test_AllTriggersAreGuardianOnlyEvenForOwner() public {
        _setGuardian(GUARDIAN);

        vm.prank(OWNER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.prank(OWNER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        vm.prank(OWNER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);

        vm.prank(STRANGER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.prank(STRANGER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        vm.prank(STRANGER);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);
    }

    function test_DisabledGuardianCannotTrigger() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseCoordinator.EmergencyPauseCoordinator__UnauthorizedGuardian.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);
    }

    function test_CoordinatorExposesNoRecoveryOrArbitraryCallSurface() public {
        (bool unpauseOk,) = address(coordinator).call(abi.encodeWithSignature("unpause()"));
        (bool unpauseSettlementOk,) = address(coordinator).call(abi.encodeWithSignature("unpauseLpEpochSettlement()"));
        (bool arbitraryCallOk,) = address(coordinator)
            .call(abi.encodeWithSignature("execute(address,bytes)", address(routerAdmin), bytes("")));

        assertFalse(unpauseOk);
        assertFalse(unpauseSettlementOk);
        assertFalse(arbitraryCallOk);
    }

    function test_TriggerPausesBothComponentsAndReturnsCanonicalCutoff() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.RiskOff, CUTOFF, 0, 3
        );
        vm.prank(GUARDIAN);
        uint64 cutoff = coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        assertEq(cutoff, CUTOFF);
        assertTrue(routerAdmin.paused());
        assertTrue(housePool.paused());
        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 1);
    }

    function test_TriggerAcceptsZeroIncidentHashes() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, bytes32(0), bytes32(0), EmergencyPauseCoordinator.ContainmentAction.RiskOff, CUTOFF, 0, 3
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerEmergencyPause(bytes32(0), bytes32(0)), CUTOFF);
    }

    function test_RepeatedTriggerSkipsBothPausedComponents() public {
        _setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.RiskOff, CUTOFF, 3, 3
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH), CUTOFF);
        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 1);
    }

    function test_TriggerOnlyPausesHousePoolWhenRouterAdminWasPaused() public {
        routerAdmin.forcePause();
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.RiskOff, 0, 1, 3
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH), 0);
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 1);
    }

    function test_TriggerOnlyPausesRouterAdminWhenHousePoolWasPaused() public {
        housePool.forcePause();
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.RiskOff, CUTOFF, 2, 3
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH), CUTOFF);
        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 0);
    }

    function test_RiskOffPreservesSettlementHoldAndIncludesItInMasks() public {
        housePool.forceLpEpochSettlementPause();
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.RiskOff, CUTOFF, 4, 7
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH), CUTOFF);

        assertTrue(housePool.lpEpochSettlementPaused());
        assertEq(housePool.settlementPauseCalls(), 0);
    }

    function test_HousePoolPauseFailureRollsBackRouterPauseAndCutoff() public {
        housePool.setFailPause(true);
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__ForcedFailure.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertFalse(housePool.paused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 0);
    }

    function test_MissingComponentPauserWiringRollsBackRouterPauseAndCutoff() public {
        housePool.setPauser(address(0));
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__Unauthorized.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
        assertEq(routerAdmin.pauseCalls(), 0);
    }

    function test_MissingRouterAdminPauserWiringDoesNotPauseHousePool() public {
        routerAdmin.setPauser(address(0));
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__Unauthorized.selector);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertFalse(housePool.paused());
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 0);
    }

    function test_SettlementHoldOnlyPausesLpEpochSettlement() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.LpSettlementHold, 0, 0, 4
        );
        vm.prank(GUARDIAN);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertFalse(housePool.paused());
        assertTrue(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 0);
        assertEq(housePool.settlementPauseCalls(), 1);
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
    }

    function test_RepeatedSettlementHoldSkipsAlreadyActiveGate() public {
        _setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, REASON_HASH, EVIDENCE_HASH, EmergencyPauseCoordinator.ContainmentAction.LpSettlementHold, 0, 4, 4
        );
        vm.prank(GUARDIAN);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        assertEq(housePool.settlementPauseCalls(), 1);
    }

    function test_SettlementHoldPreservesExistingRiskOffCutoff() public {
        _setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN,
            REASON_HASH,
            EVIDENCE_HASH,
            EmergencyPauseCoordinator.ContainmentAction.LpSettlementHold,
            CUTOFF,
            3,
            7
        );
        vm.prank(GUARDIAN);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        assertEq(routerAdmin.riskOffOrderCutoff(), CUTOFF);
        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 1);
        assertEq(housePool.settlementPauseCalls(), 1);
    }

    function test_SettlementHoldAcceptsZeroIncidentHashes() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, bytes32(0), bytes32(0), EmergencyPauseCoordinator.ContainmentAction.LpSettlementHold, 0, 0, 4
        );
        vm.prank(GUARDIAN);
        coordinator.triggerLpEpochSettlementHold(bytes32(0), bytes32(0));
    }

    function test_SettlementHoldFailureDoesNotChangeExistingRiskOffState() public {
        _setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        coordinator.triggerEmergencyPause(REASON_HASH, EVIDENCE_HASH);
        housePool.setFailSettlementPause(true);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__ForcedFailure.selector);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        assertTrue(routerAdmin.paused());
        assertTrue(housePool.paused());
        assertFalse(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.riskOffOrderCutoff(), CUTOFF);
        assertEq(housePool.settlementPauseCalls(), 0);
    }

    function test_MissingHousePoolPauserWiringPreventsSettlementHold() public {
        housePool.setPauser(address(0));
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__Unauthorized.selector);
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);

        assertFalse(housePool.lpEpochSettlementPaused());
        assertEq(housePool.settlementPauseCalls(), 0);
    }

    function test_FullContainmentActivatesEveryRestrictionAndReturnsCutoff() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN,
            REASON_HASH,
            EVIDENCE_HASH,
            EmergencyPauseCoordinator.ContainmentAction.FullContainment,
            CUTOFF,
            0,
            7
        );
        vm.prank(GUARDIAN);
        uint64 cutoff = coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);

        assertEq(cutoff, CUTOFF);
        assertTrue(routerAdmin.paused());
        assertTrue(housePool.paused());
        assertTrue(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 1);
        assertEq(housePool.settlementPauseCalls(), 1);
    }

    function test_RepeatedFullContainmentSkipsEveryActiveRestriction() public {
        _setGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN,
            REASON_HASH,
            EVIDENCE_HASH,
            EmergencyPauseCoordinator.ContainmentAction.FullContainment,
            CUTOFF,
            7,
            7
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH), CUTOFF);

        assertEq(routerAdmin.pauseCalls(), 1);
        assertEq(housePool.pauseCalls(), 1);
        assertEq(housePool.settlementPauseCalls(), 1);
    }

    function testFuzz_FullContainmentHandlesEveryPartialRestrictionCombination(
        uint8 initialRestrictionMask
    ) public {
        initialRestrictionMask &= 7;
        if ((initialRestrictionMask & 1) != 0) {
            routerAdmin.forcePause();
        }
        if ((initialRestrictionMask & 2) != 0) {
            housePool.forcePause();
        }
        if ((initialRestrictionMask & 4) != 0) {
            housePool.forceLpEpochSettlementPause();
        }
        _setGuardian(GUARDIAN);

        uint64 expectedCutoff = (initialRestrictionMask & 1) == 0 ? CUTOFF : 0;
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN,
            REASON_HASH,
            EVIDENCE_HASH,
            EmergencyPauseCoordinator.ContainmentAction.FullContainment,
            expectedCutoff,
            initialRestrictionMask,
            7
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH), expectedCutoff);

        assertTrue(routerAdmin.paused());
        assertTrue(housePool.paused());
        assertTrue(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.pauseCalls(), (initialRestrictionMask & 1) == 0 ? 1 : 0);
        assertEq(housePool.pauseCalls(), (initialRestrictionMask & 2) == 0 ? 1 : 0);
        assertEq(housePool.settlementPauseCalls(), (initialRestrictionMask & 4) == 0 ? 1 : 0);
    }

    function test_FullContainmentAcceptsZeroIncidentHashes() public {
        _setGuardian(GUARDIAN);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EmergencyContainmentTriggered(
            GUARDIAN, bytes32(0), bytes32(0), EmergencyPauseCoordinator.ContainmentAction.FullContainment, CUTOFF, 0, 7
        );
        vm.prank(GUARDIAN);
        assertEq(coordinator.triggerFullContainment(bytes32(0), bytes32(0)), CUTOFF);
    }

    function test_FullContainmentSettlementFailureRollsBackEveryRestrictionAndCutoff() public {
        housePool.setFailSettlementPause(true);
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__ForcedFailure.selector);
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertFalse(housePool.paused());
        assertFalse(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 0);
        assertEq(housePool.settlementPauseCalls(), 0);
    }

    function test_FullContainmentEntryFailureRollsBackRouterAndNeverTouchesSettlementGate() public {
        housePool.setFailPause(true);
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(EmergencyPauseTargetMock.EmergencyPauseTargetMock__ForcedFailure.selector);
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);

        assertFalse(routerAdmin.paused());
        assertFalse(housePool.paused());
        assertFalse(housePool.lpEpochSettlementPaused());
        assertEq(routerAdmin.riskOffOrderCutoff(), 0);
        assertEq(routerAdmin.pauseCalls(), 0);
        assertEq(housePool.pauseCalls(), 0);
        assertEq(housePool.settlementPauseCalls(), 0);
    }

    function test_SettlementHoldGasIsBounded() public {
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        uint256 gasBefore = gasleft();
        coordinator.triggerLpEpochSettlementHold(REASON_HASH, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        assertLe(gasUsed, 100_000);
    }

    function test_FullContainmentGasIsBounded() public {
        _setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        uint256 gasBefore = gasleft();
        coordinator.triggerFullContainment(REASON_HASH, EVIDENCE_HASH);
        uint256 gasUsed = gasBefore - gasleft();

        assertLe(gasUsed, 250_000);
    }

    function _setGuardian(
        address newGuardian
    ) internal {
        vm.prank(OWNER);
        coordinator.setGuardian(newGuardian);
    }

}

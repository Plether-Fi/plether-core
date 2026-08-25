// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHousePoolEmergencyAdmin} from "@plether/perps/interfaces/IHousePoolEmergencyAdmin.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";

/// @title EmergencyPauseCoordinator
/// @notice Allows one guardian to activate fixed emergency-containment actions across the perps stack.
/// @dev The coordinator can only add restrictions. It cannot unpause components, change their configuration, set
///      prices, move funds, or make arbitrary calls. Governance retains recovery authority directly on each component.
///      The reason and evidence hashes are advisory incident metadata and are not interpreted on-chain.
contract EmergencyPauseCoordinator is Ownable2Step {

    /// @notice Fixed containment actions available to the guardian.
    enum ContainmentAction {
        RiskOff,
        LpSettlementHold,
        FullContainment
    }

    /// @notice Bit identifying the router-admin pause state in event masks.
    uint8 public constant ROUTER_ADMIN_PAUSED_MASK = 1 << 0;
    /// @notice Bit identifying the HousePool LP-entry pause state in event masks.
    uint8 public constant HOUSE_POOL_PAUSED_MASK = 1 << 1;
    /// @notice Bit identifying the HousePool LP epoch-settlement hold in event masks.
    uint8 public constant LP_EPOCH_SETTLEMENT_PAUSED_MASK = 1 << 2;
    /// @notice Restrictions activated by `triggerEmergencyPause`.
    uint8 public constant RISK_OFF_PAUSED_MASK = ROUTER_ADMIN_PAUSED_MASK | HOUSE_POOL_PAUSED_MASK;
    /// @notice Restrictions activated by `triggerFullContainment`.
    uint8 public constant FULL_CONTAINMENT_PAUSED_MASK = RISK_OFF_PAUSED_MASK | LP_EPOCH_SETTLEMENT_PAUSED_MASK;

    /// @notice Router administrative component that blocks new open commits and owns the persistent cutoff.
    IOrderRouterEmergencyAdmin public immutable ROUTER_ADMIN;
    /// @notice HousePool component whose independent gates block LP entry and LP epoch settlement.
    IHousePoolEmergencyAdmin public immutable HOUSE_POOL;

    /// @notice Account authorized to activate the composite emergency pause; zero disables triggering.
    address public guardian;

    /// @notice A required constructor address was zero.
    error EmergencyPauseCoordinator__ZeroAddress();
    /// @notice RouterAdmin and HousePool were configured as the same target.
    error EmergencyPauseCoordinator__DuplicateTarget();
    /// @notice A configured component did not have deployed bytecode.
    error EmergencyPauseCoordinator__TargetHasNoCode(address target);
    /// @notice A caller other than the configured guardian attempted to trigger the emergency pause.
    error EmergencyPauseCoordinator__UnauthorizedGuardian();

    /// @notice Emitted when governance changes or disables the guardian role.
    /// @param previousGuardian Previously configured guardian
    /// @param newGuardian Newly configured guardian, or zero when disabled
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    /// @notice Emitted after a fixed containment action completes atomically.
    /// @param guardian Account that triggered containment
    /// @param reasonHash Stable application-defined incident reason hash
    /// @param evidenceHash Hash of any archived off-chain incident evidence
    /// @param action Fixed containment action that was requested
    /// @param riskOffOrderCutoff Inclusive highest order id invalidated by the router pause
    /// @param previousRestrictionMask Restriction mask observed before containment
    /// @param newRestrictionMask Restriction mask observed after containment
    event EmergencyContainmentTriggered(
        address indexed guardian,
        bytes32 indexed reasonHash,
        bytes32 indexed evidenceHash,
        ContainmentAction action,
        uint64 riskOffOrderCutoff,
        uint8 previousRestrictionMask,
        uint8 newRestrictionMask
    );

    /// @notice Creates a least-authority coordinator bound permanently to one RouterAdmin and HousePool.
    /// @dev The guardian starts disabled and must be configured separately by `initialOwner`. Both component owners
    ///      must also configure this coordinator as their pauser before it can trigger containment.
    /// @param routerAdmin Router administrative component that owns the persistent risk-off cutoff
    /// @param housePool HousePool whose emergency pause blocks LP entry
    /// @param initialOwner Initial governance owner allowed to rotate or disable the guardian
    constructor(
        address routerAdmin,
        address housePool,
        address initialOwner
    ) Ownable(initialOwner) {
        if (routerAdmin == address(0) || housePool == address(0)) {
            revert EmergencyPauseCoordinator__ZeroAddress();
        }
        if (routerAdmin == housePool) {
            revert EmergencyPauseCoordinator__DuplicateTarget();
        }
        if (routerAdmin.code.length == 0) {
            revert EmergencyPauseCoordinator__TargetHasNoCode(routerAdmin);
        }
        if (housePool.code.length == 0) {
            revert EmergencyPauseCoordinator__TargetHasNoCode(housePool);
        }

        ROUTER_ADMIN = IOrderRouterEmergencyAdmin(routerAdmin);
        HOUSE_POOL = IHousePoolEmergencyAdmin(housePool);
    }

    /// @notice Changes or disables the account authorized to activate composite containment.
    /// @dev Owner only. The zero address intentionally disables the guardian without granting recovery authority.
    /// @param newGuardian New guardian account, or zero to disable guardian triggering
    function setGuardian(
        address newGuardian
    ) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Atomically pauses new open commits and LP entry, returning the canonical persistent order cutoff.
    /// @dev Guardian only. Already-paused components are skipped so repeated and partial-state calls are idempotent.
    ///      RouterAdmin is paused first so any HousePool failure rolls back both its pause and cutoff. Zero incident
    ///      hashes are accepted because incomplete metadata must never block containment.
    /// @param reasonHash Stable application-defined incident reason hash
    /// @param evidenceHash Hash of archived off-chain evidence associated with the incident
    /// @return riskOffOrderCutoff Inclusive highest order id invalidated by the RouterAdmin pause
    function triggerEmergencyPause(
        bytes32 reasonHash,
        bytes32 evidenceHash
    ) external returns (uint64 riskOffOrderCutoff) {
        _requireGuardian();
        uint8 previousRestrictionMask = _restrictionMask();
        _activateRiskOff(previousRestrictionMask);
        riskOffOrderCutoff = ROUTER_ADMIN.riskOffOrderCutoff();
        emit EmergencyContainmentTriggered(
            msg.sender,
            reasonHash,
            evidenceHash,
            ContainmentAction.RiskOff,
            riskOffOrderCutoff,
            previousRestrictionMask,
            _restrictionMask()
        );
    }

    /// @notice Pauses LP epoch settlement without pausing trading risk or LP request admission.
    /// @dev Guardian only. An already-active hold is skipped. Zero incident hashes are accepted.
    /// @param reasonHash Stable application-defined incident reason hash
    /// @param evidenceHash Hash of archived off-chain evidence associated with the incident
    function triggerLpEpochSettlementHold(
        bytes32 reasonHash,
        bytes32 evidenceHash
    ) external {
        _requireGuardian();
        uint8 previousRestrictionMask = _restrictionMask();
        _activateLpEpochSettlementHold(previousRestrictionMask);
        emit EmergencyContainmentTriggered(
            msg.sender,
            reasonHash,
            evidenceHash,
            ContainmentAction.LpSettlementHold,
            ROUTER_ADMIN.riskOffOrderCutoff(),
            previousRestrictionMask,
            _restrictionMask()
        );
    }

    /// @notice Atomically pauses new trading risk, LP entry, and LP epoch settlement.
    /// @dev Guardian only. Restrictions already active are skipped. RouterAdmin is paused first so any later failure
    ///      rolls back its pause and persistent cutoff. Zero incident hashes are accepted.
    /// @param reasonHash Stable application-defined incident reason hash
    /// @param evidenceHash Hash of archived off-chain evidence associated with the incident
    /// @return riskOffOrderCutoff Inclusive highest order id invalidated by the RouterAdmin pause
    function triggerFullContainment(
        bytes32 reasonHash,
        bytes32 evidenceHash
    ) external returns (uint64 riskOffOrderCutoff) {
        _requireGuardian();
        uint8 previousRestrictionMask = _restrictionMask();
        _activateRiskOff(previousRestrictionMask);
        _activateLpEpochSettlementHold(previousRestrictionMask);
        riskOffOrderCutoff = ROUTER_ADMIN.riskOffOrderCutoff();
        emit EmergencyContainmentTriggered(
            msg.sender,
            reasonHash,
            evidenceHash,
            ContainmentAction.FullContainment,
            riskOffOrderCutoff,
            previousRestrictionMask,
            _restrictionMask()
        );
    }

    function _requireGuardian() private view {
        if (msg.sender != guardian) {
            revert EmergencyPauseCoordinator__UnauthorizedGuardian();
        }
    }

    function _activateRiskOff(
        uint8 previousRestrictionMask
    ) private {
        if ((previousRestrictionMask & ROUTER_ADMIN_PAUSED_MASK) == 0) {
            ROUTER_ADMIN.pause();
        }
        if ((previousRestrictionMask & HOUSE_POOL_PAUSED_MASK) == 0) {
            HOUSE_POOL.pause();
        }
    }

    function _activateLpEpochSettlementHold(
        uint8 previousRestrictionMask
    ) private {
        if ((previousRestrictionMask & LP_EPOCH_SETTLEMENT_PAUSED_MASK) == 0) {
            HOUSE_POOL.pauseLpEpochSettlement();
        }
    }

    function _restrictionMask() private view returns (uint8 restrictionMask) {
        if (ROUTER_ADMIN.paused()) {
            restrictionMask |= ROUTER_ADMIN_PAUSED_MASK;
        }
        if (HOUSE_POOL.paused()) {
            restrictionMask |= HOUSE_POOL_PAUSED_MASK;
        }
        if (HOUSE_POOL.lpEpochSettlementPaused()) {
            restrictionMask |= LP_EPOCH_SETTLEMENT_PAUSED_MASK;
        }
    }

}

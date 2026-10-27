// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Frozen pre-refactor treasury behavior for differential regression tests.
/// @dev Treasury state, events, and functions are copied verbatim from CfdEngine.sol at
///      4f7126640e7ffb877e1820e38b721383f4a752d9. The constructor retains only its ownership and treasury initialization.
///      Keep this reference independent of CfdTreasury so representation changes cannot silently update the oracle.
contract LegacyTreasuryReference is ICfdEngineTypes, Ownable2Step {

    struct TreasuryConfig {
        // Full-slot address word avoids read-modify-write masking; inputs are always zero-extended addresses.
        uint256 account;
        uint256 lockedUntil;
    }

    TreasuryConfig private _currentTreasury;
    TreasuryConfig private _pendingTreasury;

    /// @notice Emitted when an immediate setter changes the account designated to receive future protocol fees.
    /// @dev Scheduled activation is resolved by timestamp and emits no automatic event.
    /// @param treasury New protocol treasury clearinghouse account.
    event ProtocolTreasuryUpdated(address indexed treasury);

    /// @notice Emitted when the owner immediately commits a treasury for a chosen duration.
    /// @param treasury Treasury protected against replacement, including by a subsequent owner.
    /// @param lockedUntil Unix timestamp at which treasury updates become available again.
    event ProtocolTreasuryLocked(address indexed treasury, uint256 lockedUntil);

    /// @notice Schedules or replaces the successor at the current treasury's unchanged lock expiry.
    /// @dev Activation is resolved by timestamp; no transaction or event is required at activationTime.
    event ProtocolTreasuryProposed(address indexed treasury, uint256 activationTime, uint256 lockedUntil);

    /// @notice Cancels a pending successor without changing the current treasury or its lock expiry.
    event ProtocolTreasuryProposalCancelled();

    constructor() Ownable(msg.sender) {
        _currentTreasury.account = uint160(msg.sender);
    }

    /// @notice Clearinghouse account credited with protocol fees and forfeited bounties at the current timestamp.
    /// @dev A scheduled successor becomes active at the previous lock's expiry without a transaction.
    function protocolTreasury() public view returns (address) {
        return address(uint160(_activeTreasury().account));
    }

    /// @notice Lock expiry of the effective treasury; an elapsed timestamp is retained after expiry.
    function protocolTreasuryLockedUntil() public view returns (uint256) {
        return _activeTreasury().lockedUntil;
    }

    /// @notice Pending successor, activation timestamp, and next lock expiry; all zero once active or cancelled.
    function pendingProtocolTreasury()
        external
        view
        returns (address treasury, uint256 activationTime, uint256 lockedUntil)
    {
        uint256 account = _pendingTreasury.account;
        uint256 activation = _currentTreasury.lockedUntil;
        bool hasAccount = account != 0;
        bool beforeActivation = block.timestamp < activation;
        // Keep the readiness comparisons in Solidity so Forge can instrument them. All account writes are
        // zero-extended addresses; assembly only encodes the three ABI words to keep the engine deployable.
        assembly ("memory-safe") {
            let pending := and(hasAccount, beforeActivation)
            let result := mload(0x40)
            mstore(result, mul(pending, account))
            mstore(add(result, 0x20), mul(pending, activation))
            mstore(add(result, 0x40), mul(pending, sload(add(_pendingTreasury.slot, 1))))
            return(result, 0x60)
        }
    }

    /// @notice Queues or replaces the treasury that automatically takes effect when the current lock expires.
    /// @dev Owner-only; requires an active lock. Replacement leaves the current lock's expiry unchanged.
    /// @param treasury Nonzero clearinghouse account for future fees after activation.
    /// @param nextLockDuration Seconds to lock the successor from the scheduled activation time; zero leaves it unlocked.
    function proposeProtocolTreasury(
        address treasury,
        uint256 nextLockDuration
    ) external onlyOwner {
        TreasuryConfig storage active = _activeTreasury();
        uint256 activationTime = active.lockedUntil;
        if (block.timestamp >= activationTime) {
            revert CfdEngine__TreasuryNotLocked();
        }
        if (treasury == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        _currentTreasury.account = active.account;
        _currentTreasury.lockedUntil = activationTime;
        uint256 lockedUntil = activationTime + nextLockDuration;
        _pendingTreasury.account = uint160(treasury);
        _pendingTreasury.lockedUntil = lockedUntil;
        emit ProtocolTreasuryProposed(treasury, activationTime, lockedUntil);
    }

    /// @notice Cancels the pending successor before activation without restarting or removing the current lock.
    function cancelProtocolTreasuryProposal() external onlyOwner {
        if (!_hasPendingTreasury()) {
            revert CfdEngine__NoTreasuryProposal();
        }
        delete _pendingTreasury.account;
        emit ProtocolTreasuryProposalCancelled();
    }

    /// @dev A matured pending slot remains active even after its own lock expires. Only a new proposal copies
    ///      it into the current slot before reusing the pending slot; immediate setters modify the active slot.
    function _activeTreasury() internal view returns (TreasuryConfig storage active) {
        active = _currentTreasury;
        if (_pendingTreasury.account != 0 && block.timestamp >= _currentTreasury.lockedUntil) {
            active = _pendingTreasury;
        }
    }

    function _hasPendingTreasury() internal view returns (bool pending) {
        return _pendingTreasury.account != 0 && block.timestamp < _currentTreasury.lockedUntil;
    }

    /// @notice Immediately updates the protocol treasury without starting a new lock.
    /// @dev Owner-only; reverts while a treasury lock is active, even for the current address.
    ///      Existing balances remain in their original accounts. Once unlocked, the current address is a no-op.
    /// @param treasury Nonzero clearinghouse account that will receive future protocol fee credits.
    function setProtocolTreasury(
        address treasury
    ) external onlyOwner {
        _setProtocolTreasury(treasury);
    }

    /// @notice Immediately sets the protocol treasury and prevents further updates for lockDuration seconds.
    /// @dev Owner-only. Can lock the current address. An active lock cannot be shortened, extended, or bypassed
    ///      through ownership transfer. Existing balances and withdrawals are unaffected. Expiry allows updates
    ///      at block.timestamp >= protocolTreasuryLockedUntil(). A queued successor activates at expiry.
    /// @param treasury Nonzero clearinghouse account that will receive future protocol fee credits.
    /// @param lockDuration Positive lock duration in seconds. Timestamp overflow reverts atomically.
    function setProtocolTreasury(
        address treasury,
        uint256 lockDuration
    ) external onlyOwner {
        if (lockDuration == 0) {
            revert CfdEngine__InvalidTreasuryLockDuration();
        }
        TreasuryConfig storage active = _setProtocolTreasury(treasury);
        uint256 lockedUntil = block.timestamp + lockDuration;
        active.lockedUntil = lockedUntil;
        emit ProtocolTreasuryLocked(treasury, lockedUntil);
    }

    /// @dev Shared guard for both public setters, including same-address calls.
    function _setProtocolTreasury(
        address treasury
    ) internal returns (TreasuryConfig storage active) {
        active = _activeTreasury();
        if (block.timestamp < active.lockedUntil) {
            revert CfdEngine__TreasuryLocked(active.lockedUntil);
        }
        if (treasury == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (uint160(treasury) != active.account) {
            active.account = uint160(treasury);
            emit ProtocolTreasuryUpdated(treasury);
        }
    }

}

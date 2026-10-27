// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @title CfdTreasury
/// @notice Owner-controlled treasury locks and automatic successor scheduling, stored in the inheriting engine.
abstract contract CfdTreasury is ICfdEngineTypes, Ownable2Step {

    uint256 internal constant MAX_TREASURY_LOCK_DURATION = 90 days;

    struct TreasuryConfig {
        address account;
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
        _currentTreasury.account = msg.sender;
    }

    /// @notice Clearinghouse account credited with protocol fees and forfeited bounties at the current timestamp.
    /// @dev A scheduled successor becomes active at the previous lock's expiry without a transaction.
    function protocolTreasury() public view returns (address) {
        return _activeTreasury().account;
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
        if (!_hasPendingTreasury()) {
            return (address(0), 0, 0);
        }
        return (_pendingTreasury.account, _currentTreasury.lockedUntil, _pendingTreasury.lockedUntil);
    }

    /// @notice Queues or replaces the treasury that automatically takes effect when the current lock expires.
    /// @dev Owner-only; requires an active lock. Replacement leaves the current lock's expiry unchanged.
    /// @param treasury Nonzero clearinghouse account for future fees after activation.
    /// @param nextLockDuration Seconds to lock the successor from activation, at most 90 days; zero leaves it unlocked.
    function proposeProtocolTreasury(
        address treasury,
        uint256 nextLockDuration
    ) external onlyOwner {
        _syncTreasury();
        uint256 activationTime = _currentTreasury.lockedUntil;
        if (block.timestamp >= activationTime) {
            revert CfdEngine__TreasuryNotLocked();
        }
        if (treasury == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (nextLockDuration > MAX_TREASURY_LOCK_DURATION) {
            revert CfdEngine__InvalidTreasuryLockDuration();
        }
        uint256 lockedUntil = activationTime + nextLockDuration;
        _pendingTreasury.account = treasury;
        _pendingTreasury.lockedUntil = lockedUntil;
        emit ProtocolTreasuryProposed(treasury, activationTime, lockedUntil);
    }

    /// @notice Cancels the pending successor before activation without restarting or removing the current lock.
    function cancelProtocolTreasuryProposal() external onlyOwner {
        if (!_hasPendingTreasury()) {
            revert CfdEngine__NoTreasuryProposal();
        }
        delete _pendingTreasury;
        emit ProtocolTreasuryProposalCancelled();
    }

    /// @dev Views resolve activation by timestamp, even before the next treasury mutation persists it.
    function _activeTreasury() internal view returns (TreasuryConfig storage active) {
        active = _currentTreasury;
        if (_pendingTreasury.account != address(0) && block.timestamp >= _currentTreasury.lockedUntil) {
            active = _pendingTreasury;
        }
    }

    /// @dev Persist an activated successor before modifying treasury state; mutations always use the current slot.
    function _syncTreasury() internal {
        if (_pendingTreasury.account != address(0) && block.timestamp >= _currentTreasury.lockedUntil) {
            _currentTreasury = _pendingTreasury;
            delete _pendingTreasury;
        }
    }

    function _hasPendingTreasury() internal view returns (bool pending) {
        return _pendingTreasury.account != address(0) && block.timestamp < _currentTreasury.lockedUntil;
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
    /// @param lockDuration Positive lock duration in seconds, at most 90 days. Timestamp overflow reverts atomically.
    function setProtocolTreasury(
        address treasury,
        uint256 lockDuration
    ) external onlyOwner {
        if (lockDuration == 0 || lockDuration > MAX_TREASURY_LOCK_DURATION) {
            revert CfdEngine__InvalidTreasuryLockDuration();
        }
        _setProtocolTreasury(treasury);
        uint256 lockedUntil = block.timestamp + lockDuration;
        _currentTreasury.lockedUntil = lockedUntil;
        emit ProtocolTreasuryLocked(treasury, lockedUntil);
    }

    /// @dev Shared guard for both public setters, including same-address calls.
    function _setProtocolTreasury(
        address treasury
    ) internal {
        _syncTreasury();
        if (block.timestamp < _currentTreasury.lockedUntil) {
            revert CfdEngine__TreasuryLocked(_currentTreasury.lockedUntil);
        }
        if (treasury == address(0)) {
            revert CfdEngine__ZeroAddress();
        }
        if (treasury != _currentTreasury.account) {
            _currentTreasury.account = treasury;
            emit ProtocolTreasuryUpdated(treasury);
        }
    }

}

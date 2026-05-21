// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Administrative surface for perps configuration, emergency controls, and one-time setup.
interface IPerpsAdmin {

    /// @notice Updates the account allowed to pause alongside the owner.
    /// @param newPauser New emergency pauser account
    function setPauser(
        address newPauser
    ) external;

    /// @notice Pauses the contract's guarded user actions.
    function pause() external;

    /// @notice Unpauses the contract's guarded user actions.
    function unpause() external;

}

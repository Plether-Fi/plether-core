// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Common emergency-pause selector shape exposed by perps administrative components.
/// @dev This is a logical role interface rather than a guarantee that one contract controls every perps component.
interface IPerpsAdmin {

    /// @notice Updates the account allowed to pause alongside the owner.
    /// @dev Implementations restrict this to their owner; the zero address disables the separate pauser role.
    /// @param newPauser New emergency pauser account, or zero to clear the role
    function setPauser(
        address newPauser
    ) external;

    /// @notice Pauses the contract's guarded user actions.
    /// @dev Callable by the component owner or configured emergency pauser. The exact guarded actions are
    ///      component-specific; execution, withdrawals, or liquidation may intentionally remain available.
    function pause() external;

    /// @notice Unpauses the contract's guarded user actions.
    /// @dev Implementations restrict recovery to their owner.
    function unpause() external;

}

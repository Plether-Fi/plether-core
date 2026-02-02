// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title IYieldAdapter
/// @notice Extended interface for yield adapters that support interest accrual.
/// @dev Optional extension to IERC4626 for adapters with pending interest.
interface IYieldAdapter {

    /// @notice Forces the underlying protocol to accrue pending interest.
    /// @dev Call before reading totalAssets() if exact values are needed for calculations.
    function accrueInterest() external;

}

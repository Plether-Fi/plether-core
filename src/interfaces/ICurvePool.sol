// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICurvePool {
    /// @notice Get expected output amount
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /// @notice Exchange tokens in the pool
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input token
    /// @param min_dy Minimum amount of output token to receive
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

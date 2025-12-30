// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal Curve StableSwap pool interface
interface ICurvePool {
    /// @notice Exchange tokens in the pool
    /// @param i Index of input token
    /// @param j Index of output token
    /// @param dx Amount of input tokens
    /// @param min_dy Minimum output tokens (slippage protection)
    /// @return dy Actual output tokens received
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy);
}

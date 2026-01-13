// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title ICurvePool
/// @notice Interface for Curve StableSwap pools.
/// @dev Used for USDC/DXY-BEAR swaps. Indices: USDC=0, DXY-BEAR=1.
interface ICurvePool {
    /// @notice Calculates expected output for a swap.
    /// @param i Input token index.
    /// @param j Output token index.
    /// @param dx Input amount.
    /// @return Expected output amount.
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);

    /// @notice Executes a token swap.
    /// @param i Input token index.
    /// @param j Output token index.
    /// @param dx Input amount.
    /// @param min_dy Minimum output (slippage protection).
    /// @return Actual output amount.
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    /// @notice Returns EMA oracle price (18 decimals).
    /// @return Price of token1 in terms of token0.
    function price_oracle() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Minimal swap router interface for Curve pool integration
interface ISwapRouter {
    /// @notice Swap exact input amount for output tokens
    /// @param tokenIn Address of input token
    /// @param tokenOut Address of output token
    /// @param amountIn Amount of input tokens to swap
    /// @param minAmountOut Minimum output tokens to receive (slippage protection)
    /// @return amountOut Actual output tokens received
    function exchange(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}

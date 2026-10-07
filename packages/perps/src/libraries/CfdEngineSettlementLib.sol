// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CfdEngineSettlementLib
/// @notice Legacy close-settlement result type retained in engine plan deltas for ABI compatibility.
/// @dev Monetary values are 6-decimal USDC. The current isolated close planner leaves these fields zero and
///      reports price-PnL collection, action charges, fees, and write-offs directly on `CloseDelta`.
library CfdEngineSettlementLib {

    /// @notice Former combined close-loss allocation, retained only as a zero-valued compatibility result.
    /// @param seizedUsdc Legacy collateral collection field; currently zero.
    /// @param shortfallUsdc Legacy collection-shortfall field; currently zero.
    /// @param collectedExecFeeUsdc Legacy collected-execution-fee field; currently zero.
    /// @param retainedExecFeeUsdc Legacy withheld-execution-fee field; currently zero.
    /// @param badDebtUsdc Legacy write-off field; currently zero and never accumulated as protocol debt.
    struct CloseSettlementResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
        uint256 collectedExecFeeUsdc;
        uint256 retainedExecFeeUsdc;
        uint256 badDebtUsdc;
    }

}

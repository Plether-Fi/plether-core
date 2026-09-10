// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CfdEngineSettlementLib
/// @notice Shared close-settlement result type carried by engine plan deltas.
/// @dev Monetary values are 6-decimal USDC.
library CfdEngineSettlementLib {

    /// @notice Allocation of a close loss across collateral, execution fees, and base trading loss.
    /// @dev `badDebtUsdc` intentionally excludes uncollected execution fees and frozen-close spread. Those charges
    ///      may contribute to `shortfallUsdc`, but only the uncollected base amount is protocol bad debt.
    /// @param seizedUsdc Account collateral collected toward the total amount owed.
    /// @param shortfallUsdc Total amount owed but not collected, including any uncollected charges.
    /// @param collectedExecFeeUsdc Execution fee contained in seized collateral.
    /// @param retainedExecFeeUsdc Execution fee offset by trader profit outside `owedUsdc` and marked for pool top-up.
    /// @param badDebtUsdc Uncollected base loss after prioritizing collected execution fee; excludes fee and spread.
    struct CloseSettlementResult {
        uint256 seizedUsdc;
        uint256 shortfallUsdc;
        uint256 collectedExecFeeUsdc;
        uint256 retainedExecFeeUsdc;
        uint256 badDebtUsdc;
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title ProtocolLensViewTypes
/// @notice Shared return types for protocol-wide accounting diagnostics.
library ProtocolLensViewTypes {

    /// @notice Conservative protocol accounting and solvency snapshot.
    /// @dev All monetary fields use USDC's 6 decimals.
    /// @param poolAssetsUsdc Canonical physical assets recognized by the HousePool.
    /// @param netPhysicalAssetsUsdc Pool assets net of protocol-treasury settlement credited in custody.
    /// @param maxLiabilityUsdc Larger of the bull-side and bear-side maximum-profit envelopes.
    /// @param effectiveSolvencyAssetsUsdc Pool assets after aggregate trader claims, floored at zero.
    /// @param withdrawalReservedUsdc Maximum position liability plus aggregate trader claims.
    /// @param freeUsdc Pool assets above maximum position liability and aggregate trader claims.
    /// @param protocolTreasuryBalanceUsdc Settlement credited to the protocol treasury in the clearinghouse.
    /// @param accumulatedBadDebtUsdc Aggregate recognized protocol bad debt not yet recapitalized.
    /// @param totalTraderClaimBalanceUsdc Aggregate unpaid trader claims.
    /// @param degradedMode Whether the engine has entered insolvency-protection mode.
    /// @param hasLiveLiability Whether either side has a nonzero maximum-profit liability.
    struct ProtocolAccountingSnapshot {
        uint256 poolAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 effectiveSolvencyAssetsUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 protocolTreasuryBalanceUsdc;
        uint256 accumulatedBadDebtUsdc;
        uint256 totalTraderClaimBalanceUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

}

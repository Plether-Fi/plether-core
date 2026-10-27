// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title ProtocolLensViewTypes
/// @notice Shared return types for protocol-wide accounting diagnostics.
library ProtocolLensViewTypes {

    /// @notice Conservative protocol accounting and solvency snapshot.
    /// @dev All monetary fields use settlement token's 6 decimals.
    /// @param poolAssets Canonical physical assets recognized by the HousePool.
    /// @param netPhysicalAssets Canonical pool assets, equal to poolAssets. Treasury settlement is held
    ///        separately in the clearinghouse and must not be subtracted again; trader claims are also separate.
    /// @param maxLiabilityAssets Larger of the long-side and short-side maximum-profit envelopes.
    /// @param effectiveSolvencyAssets Pool assets after aggregate trader claims, floored at zero.
    /// @param withdrawalReservedAssets Maximum position liability, aggregate trader claims, and settlement buffer.
    /// @param freeAssets Pool assets above maximum position liability, aggregate trader claims, and settlement buffer.
    /// @param protocolTreasuryBalanceAssets Settlement credited to the protocol treasury in the clearinghouse.
    /// @param totalTraderClaimBalanceAssets Aggregate unpaid trader claims.
    /// @param degradedMode Whether the engine has entered insolvency-protection mode.
    /// @param hasLiveLiability Whether either side has a nonzero maximum-profit liability.
    struct ProtocolAccountingSnapshot {
        uint256 poolAssets;
        uint256 netPhysicalAssets;
        uint256 maxLiabilityAssets;
        uint256 effectiveSolvencyAssets;
        uint256 withdrawalReservedAssets;
        uint256 freeAssets;
        uint256 protocolTreasuryBalanceAssets;
        uint256 totalTraderClaimBalanceAssets;
        bool degradedMode;
        bool hasLiveLiability;
    }

}

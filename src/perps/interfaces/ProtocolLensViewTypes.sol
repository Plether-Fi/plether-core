// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library ProtocolLensViewTypes {

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

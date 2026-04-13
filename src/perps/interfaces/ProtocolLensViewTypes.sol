// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library ProtocolLensViewTypes {

    struct ProtocolAccountingSnapshot {
        uint256 vaultAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 effectiveSolvencyAssetsUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 accumulatedFeesUsdc;
        uint256 accumulatedBadDebtUsdc;
        uint256 totalDeferredPayoutUsdc;
        uint256 totalDeferredKeeperCreditUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

}

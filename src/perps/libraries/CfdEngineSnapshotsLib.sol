// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CfdEngineSnapshotsLib {

    struct FundingSnapshot {
        int256 bullFunding;
        int256 bearFunding;
        int256 solvencyFunding;
        int256 withdrawalFundingLiability;
    }

    struct SolvencySnapshot {
        uint256 physicalAssets;
        uint256 protocolFees;
        uint256 netPhysicalAssets;
        uint256 maxLiability;
        int256 solvencyFunding;
        uint256 effectiveSolvencyAssets;
    }

    function buildFundingSnapshot(
        int256 bullFunding,
        int256 bearFunding,
        uint256 totalBullMargin,
        uint256 totalBearMargin
    ) internal pure returns (FundingSnapshot memory snapshot) {
        snapshot.bullFunding = bullFunding;
        snapshot.bearFunding = bearFunding;

        int256 cappedBullFunding = bullFunding;
        int256 cappedBearFunding = bearFunding;
        if (cappedBullFunding < -int256(totalBullMargin)) {
            cappedBullFunding = -int256(totalBullMargin);
        }
        if (cappedBearFunding < -int256(totalBearMargin)) {
            cappedBearFunding = -int256(totalBearMargin);
        }

        snapshot.solvencyFunding = cappedBullFunding + cappedBearFunding;
        if (bullFunding > 0) {
            snapshot.withdrawalFundingLiability += bullFunding;
        }
        if (bearFunding > 0) {
            snapshot.withdrawalFundingLiability += bearFunding;
        }
    }

    function getWithdrawalReservedUsdc(
        uint256 maxLiability,
        uint256 protocolFees,
        int256 fundingLiability
    ) internal pure returns (uint256 reservedUsdc) {
        reservedUsdc = maxLiability + protocolFees;
        if (fundingLiability > 0) {
            reservedUsdc += uint256(fundingLiability);
        }
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library ClaimEngineViewTypes {

    /// @notice Aggregate trader claim status under the current beneficiary-balance model.
    struct TraderClaimStatus {
        uint256 traderClaimBalanceUsdc;
        bool traderClaimServiceableNow;
    }

}

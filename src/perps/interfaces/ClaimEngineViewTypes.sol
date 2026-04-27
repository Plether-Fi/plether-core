// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library ClaimEngineViewTypes {

    /// @notice Aggregate claim status backed by clearinghouse non-spendable claim balances.
    struct ClaimStatus {
        uint256 traderClaimBalanceUsdc;
        bool traderClaimServiceableNow;
        uint256 keeperClaimBalanceUsdc;
        bool keeperClaimServiceableNow;
    }

}

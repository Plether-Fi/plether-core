// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title ClaimEngineViewTypes
/// @notice Shared return types for trader-claim diagnostics.
library ClaimEngineViewTypes {

    /// @notice Per-beneficiary trader claim balance plus a producer-defined availability indicator.
    /// @param traderClaimBalanceUsdc Unpaid trader value recorded for the account, with 6 decimals.
    /// @param traderClaimServiceableNow Whether the producing view reports current claim serviceability. This flag
    ///        alone does not guarantee that the full claim or aggregate claim balance can be settled.
    struct TraderClaimStatus {
        uint256 traderClaimBalanceUsdc;
        bool traderClaimServiceableNow;
    }

}

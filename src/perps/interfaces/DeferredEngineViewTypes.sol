// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library DeferredEngineViewTypes {

    /// @notice Aggregate deferred-claim status under the current beneficiary-balance model.
    struct DeferredPayoutStatus {
        uint256 deferredTraderPayoutUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredClearerBountyUsdc;
        bool liquidationBountyClaimableNow;
    }

}

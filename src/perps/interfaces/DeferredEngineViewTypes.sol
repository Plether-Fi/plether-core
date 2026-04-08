// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library DeferredEngineViewTypes {

    struct DeferredTraderStatus {
        uint64 claimId;
        uint256 deferredPayoutUsdc;
        bool isHead;
        bool claimableNow;
    }

    struct DeferredClearerStatus {
        uint64 claimId;
        uint256 deferredBountyUsdc;
        bool isHead;
        bool claimableNow;
    }

    struct DeferredPayoutStatus {
        uint256 deferredTraderPayoutUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredClearerBountyUsdc;
        bool liquidationBountyClaimableNow;
    }
}

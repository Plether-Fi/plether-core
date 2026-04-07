// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library DeferredEngineViewTypes {

    enum DeferredClaimType {
        TraderPayout,
        ClearerBounty
    }

    struct DeferredClaim {
        DeferredClaimType claimType;
        bytes32 accountId;
        address keeper;
        uint256 remainingUsdc;
        uint64 prevClaimId;
        uint64 nextClaimId;
    }

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

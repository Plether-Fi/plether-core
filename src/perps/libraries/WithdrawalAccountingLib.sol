// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library WithdrawalAccountingLib {

    struct WithdrawalState {
        uint256 physicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 protocolFeesUsdc;
        uint256 fundingLiabilityUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredClearerBountyUsdc;
        uint256 reservedUsdc;
        uint256 freeUsdc;
    }

    function buildWithdrawalState(
        uint256 physicalAssetsUsdc,
        uint256 maxLiabilityUsdc,
        uint256 protocolFeesUsdc,
        uint256 fundingLiabilityUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (WithdrawalState memory state) {
        state.physicalAssetsUsdc = physicalAssetsUsdc;
        state.maxLiabilityUsdc = maxLiabilityUsdc;
        state.protocolFeesUsdc = protocolFeesUsdc;
        state.fundingLiabilityUsdc = fundingLiabilityUsdc;
        state.deferredTraderPayoutUsdc = deferredTraderPayoutUsdc;
        state.deferredClearerBountyUsdc = deferredClearerBountyUsdc;

        state.reservedUsdc = maxLiabilityUsdc + protocolFeesUsdc + deferredTraderPayoutUsdc + deferredClearerBountyUsdc
            + fundingLiabilityUsdc;
        state.freeUsdc = physicalAssetsUsdc > state.reservedUsdc ? physicalAssetsUsdc - state.reservedUsdc : 0;
    }

}

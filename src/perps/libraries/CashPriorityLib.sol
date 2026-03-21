// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    function reservedSeniorCashUsdc(
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (uint256) {
        return deferredTraderPayoutUsdc + deferredClearerBountyUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (uint256) {
        return _saturatingSub(
            physicalAssetsUsdc, reservedSeniorCashUsdc(deferredTraderPayoutUsdc, deferredClearerBountyUsdc)
        );
    }

    function availableCashForDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        uint256 reservedCashUsdc = reservedSeniorCashUsdc(deferredTraderPayoutUsdc, deferredClearerBountyUsdc);
        uint256 reservedOtherClaimsUsdc = _saturatingSub(reservedCashUsdc, claimAmountUsdc);
        return _saturatingSub(physicalAssetsUsdc, reservedOtherClaimsUsdc);
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForFreshPayouts(physicalAssetsUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc);
    }

    function canPayDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForDeferredClaim(
                    physicalAssetsUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc, claimAmountUsdc
                );
    }

    function _saturatingSub(
        uint256 lhs,
        uint256 rhs
    ) private pure returns (uint256) {
        return lhs > rhs ? lhs - rhs : 0;
    }

}

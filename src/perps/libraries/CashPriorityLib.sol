// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 freeCashUsdc;
        uint256 deferredClaimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(physicalAssetsUsdc, deferredTraderCreditUsdc);
    }

    function reserveDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 deferredClaimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(physicalAssetsUsdc, deferredTraderCreditUsdc);

        if (physicalAssetsUsdc < reservation.totalSeniorClaimsUsdc) {
            return reservation;
        }

        uint256 otherDeferredClaimsUsdc = reservation.totalSeniorClaimsUsdc > deferredClaimAmountUsdc
            ? reservation.totalSeniorClaimsUsdc - deferredClaimAmountUsdc
            : 0;
        uint256 cashAfterOtherDeferredClaims = _saturatingSub(physicalAssetsUsdc, otherDeferredClaimsUsdc);
        reservation.deferredClaimServiceableUsdc = deferredClaimAmountUsdc < cashAfterOtherDeferredClaims
            ? deferredClaimAmountUsdc
            : cashAfterOtherDeferredClaims;
    }

    function reservedSeniorCashUsdc(
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (uint256) {
        return deferredTraderCreditUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, deferredTraderCreditUsdc).freeCashUsdc;
    }

    function availableCashForDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveDeferredClaim(physicalAssetsUsdc, deferredTraderCreditUsdc, claimAmountUsdc)
        .deferredClaimServiceableUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return
            amountUsdc > 0 && amountUsdc <= availableCashForFreshPayouts(physicalAssetsUsdc, deferredTraderCreditUsdc);
    }

    function canPayDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForDeferredBeneficiaryClaim(
                physicalAssetsUsdc, deferredTraderCreditUsdc, claimAmountUsdc
            );
    }

    function _saturatingSub(
        uint256 lhs,
        uint256 rhs
    ) private pure returns (uint256) {
        return lhs > rhs ? lhs - rhs : 0;
    }

    function _buildSeniorCashReservation(
        uint256 physicalAssetsUsdc,
        uint256 deferredTraderCreditUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.deferredTraderCreditUsdc = deferredTraderCreditUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(deferredTraderCreditUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.freeCashUsdc = _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
    }

}

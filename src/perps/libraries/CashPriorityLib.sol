// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 freeCashUsdc;
        uint256 claimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(physicalAssetsUsdc, traderClaimBalanceUsdc);
    }

    function reserveClaimService(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(physicalAssetsUsdc, traderClaimBalanceUsdc);

        if (physicalAssetsUsdc < reservation.totalSeniorClaimsUsdc) {
            return reservation;
        }

        uint256 otherClaimsUsdc = reservation.totalSeniorClaimsUsdc > claimAmountUsdc
            ? reservation.totalSeniorClaimsUsdc - claimAmountUsdc
            : 0;
        uint256 cashAfterOtherClaims = _saturatingSub(physicalAssetsUsdc, otherClaimsUsdc);
        reservation.claimServiceableUsdc =
            claimAmountUsdc < cashAfterOtherClaims ? claimAmountUsdc : cashAfterOtherClaims;
    }

    function reservedSeniorCashUsdc(
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return traderClaimBalanceUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, traderClaimBalanceUsdc).freeCashUsdc;
    }

    function availableCashForClaimService(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveClaimService(physicalAssetsUsdc, traderClaimBalanceUsdc, claimAmountUsdc).claimServiceableUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0 && amountUsdc <= availableCashForFreshPayouts(physicalAssetsUsdc, traderClaimBalanceUsdc);
    }

    function canServiceClaim(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForClaimService(physicalAssetsUsdc, traderClaimBalanceUsdc, claimAmountUsdc);
    }

    function _saturatingSub(
        uint256 lhs,
        uint256 rhs
    ) private pure returns (uint256) {
        return lhs > rhs ? lhs - rhs : 0;
    }

    function _buildSeniorCashReservation(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.traderClaimBalanceUsdc = traderClaimBalanceUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(traderClaimBalanceUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.freeCashUsdc = _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
    }

}

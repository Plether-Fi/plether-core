// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 keeperClaimBalanceUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 protocolFeeWithdrawalUsdc;
        uint256 freeCashUsdc;
        uint256 claimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc
        );
    }

    function reserveClaimService(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc
        );

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
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return traderClaimBalanceUsdc + keeperClaimBalanceUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc)
        .freeCashUsdc;
    }

    function availableCashForClaimService(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveClaimService(
            physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc, claimAmountUsdc
        )
        .claimServiceableUsdc;
    }

    function availableCashForProtocolFeeWithdrawal(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc)
        .protocolFeeWithdrawalUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForFreshPayouts(
                physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc
            );
    }

    function canServiceClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForClaimService(
                physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc, claimAmountUsdc
            );
    }

    function canWithdrawProtocolFees(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForProtocolFeeWithdrawal(
                physicalAssetsUsdc, protocolFeesUsdc, traderClaimBalanceUsdc, keeperClaimBalanceUsdc
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
        uint256 protocolFeesUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 keeperClaimBalanceUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.protocolFeesUsdc = protocolFeesUsdc;
        reservation.traderClaimBalanceUsdc = traderClaimBalanceUsdc;
        reservation.keeperClaimBalanceUsdc = keeperClaimBalanceUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(traderClaimBalanceUsdc, keeperClaimBalanceUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.protocolFeeWithdrawalUsdc = protocolFeesUsdc
            < _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc)
            ? protocolFeesUsdc
            : _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
        reservation.freeCashUsdc =
            _saturatingSub(_saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc), protocolFeesUsdc);
    }

}

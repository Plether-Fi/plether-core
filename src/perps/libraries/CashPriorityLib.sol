// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 protocolFeeWithdrawalUsdc;
        uint256 freeCashUsdc;
        uint256 deferredClaimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc);
    }

    function reserveDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 deferredClaimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc);

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
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc).freeCashUsdc;
    }

    function availableCashForDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveDeferredClaim(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc, claimAmountUsdc)
        .deferredClaimServiceableUsdc;
    }

    function availableCashForProtocolFeeWithdrawal(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc
    ) internal pure returns (uint256) {
        return
            reserveFreshPayouts(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc)
            .protocolFeeWithdrawalUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForFreshPayouts(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc);
    }

    function canPayDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForDeferredBeneficiaryClaim(
                physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc, claimAmountUsdc
            );
    }

    function canWithdrawProtocolFees(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderCreditUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForProtocolFeeWithdrawal(physicalAssetsUsdc, protocolFeesUsdc, deferredTraderCreditUsdc);
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
        uint256 deferredTraderCreditUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.protocolFeesUsdc = protocolFeesUsdc;
        reservation.deferredTraderCreditUsdc = deferredTraderCreditUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(deferredTraderCreditUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.protocolFeeWithdrawalUsdc = protocolFeesUsdc
            < _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc)
            ? protocolFeesUsdc
            : _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
        reservation.freeCashUsdc =
            _saturatingSub(_saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc), protocolFeesUsdc);
    }

}

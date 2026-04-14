// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredKeeperCreditUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 protocolFeeWithdrawalUsdc;
        uint256 freeCashUsdc;
        uint256 deferredClaimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
        );
    }

    function reserveDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc,
        uint256 deferredClaimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
        );
        reservation.deferredClaimServiceableUsdc =
            deferredClaimAmountUsdc < physicalAssetsUsdc ? deferredClaimAmountUsdc : physicalAssetsUsdc;
    }

    function reservedSeniorCashUsdc(
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc
    ) internal pure returns (uint256) {
        return deferredTraderPayoutUsdc + deferredKeeperCreditUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
        )
        .freeCashUsdc;
    }

    function availableCashForDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveDeferredClaim(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc, claimAmountUsdc
        )
        .deferredClaimServiceableUsdc;
    }

    function availableCashForProtocolFeeWithdrawal(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
        )
        .protocolFeeWithdrawalUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForFreshPayouts(
                physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
            );
    }

    function canPayDeferredBeneficiaryClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForDeferredBeneficiaryClaim(
                physicalAssetsUsdc,
                protocolFeesUsdc,
                deferredTraderPayoutUsdc,
                deferredKeeperCreditUsdc,
                claimAmountUsdc
            );
    }

    function canWithdrawProtocolFees(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForProtocolFeeWithdrawal(
                physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredKeeperCreditUsdc
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
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredKeeperCreditUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.protocolFeesUsdc = protocolFeesUsdc;
        reservation.deferredTraderPayoutUsdc = deferredTraderPayoutUsdc;
        reservation.deferredKeeperCreditUsdc = deferredKeeperCreditUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(deferredTraderPayoutUsdc, deferredKeeperCreditUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.protocolFeeWithdrawalUsdc = protocolFeesUsdc
            < _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc)
            ? protocolFeesUsdc
            : _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
        reservation.freeCashUsdc =
            _saturatingSub(_saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc), protocolFeesUsdc);
    }

}

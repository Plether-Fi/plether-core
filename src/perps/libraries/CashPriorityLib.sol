// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

library CashPriorityLib {

    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 protocolFeesUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredClearerBountyUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 protocolFeeWithdrawalUsdc;
        uint256 freeCashUsdc;
        uint256 headClaimServiceableUsdc;
    }

    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
        );
    }

    function reserveDeferredHeadClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 headClaimAmountUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        reservation = _buildSeniorCashReservation(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
        );
        reservation.headClaimServiceableUsdc =
            headClaimAmountUsdc < physicalAssetsUsdc ? headClaimAmountUsdc : physicalAssetsUsdc;
    }

    function reservedSeniorCashUsdc(
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (uint256) {
        return deferredTraderPayoutUsdc + deferredClearerBountyUsdc;
    }

    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
        )
        .freeCashUsdc;
    }

    function availableCashForDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveDeferredHeadClaim(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc, claimAmountUsdc
        )
        .headClaimServiceableUsdc;
    }

    function availableCashForProtocolFeeWithdrawal(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(
            physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
        )
        .protocolFeeWithdrawalUsdc;
    }

    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForFreshPayouts(
                physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
            );
    }

    function canPayDeferredClaim(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForDeferredClaim(
                physicalAssetsUsdc,
                protocolFeesUsdc,
                deferredTraderPayoutUsdc,
                deferredClearerBountyUsdc,
                claimAmountUsdc
            );
    }

    function canWithdrawProtocolFees(
        uint256 physicalAssetsUsdc,
        uint256 protocolFeesUsdc,
        uint256 deferredTraderPayoutUsdc,
        uint256 deferredClearerBountyUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0
            && amountUsdc
                <= availableCashForProtocolFeeWithdrawal(
                physicalAssetsUsdc, protocolFeesUsdc, deferredTraderPayoutUsdc, deferredClearerBountyUsdc
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
        uint256 deferredClearerBountyUsdc
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssetsUsdc = physicalAssetsUsdc;
        reservation.protocolFeesUsdc = protocolFeesUsdc;
        reservation.deferredTraderPayoutUsdc = deferredTraderPayoutUsdc;
        reservation.deferredClearerBountyUsdc = deferredClearerBountyUsdc;
        reservation.totalSeniorClaimsUsdc = reservedSeniorCashUsdc(deferredTraderPayoutUsdc, deferredClearerBountyUsdc);
        reservation.reservedSeniorCashUsdc = reservation.totalSeniorClaimsUsdc;
        reservation.protocolFeeWithdrawalUsdc = protocolFeesUsdc
            < _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc)
            ? protocolFeesUsdc
            : _saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc);
        reservation.freeCashUsdc =
            _saturatingSub(_saturatingSub(physicalAssetsUsdc, reservation.reservedSeniorCashUsdc), protocolFeesUsdc);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CashPriorityLib
/// @notice Computes cash reserved for existing trader claims before fresh protocol payouts.
library CashPriorityLib {

    /// @notice Snapshot of senior claim reservations and the cash left for a requested action.
    /// @dev All fields are USDC amounts with 6 decimals.
    /// @param physicalAssetsUsdc Physical pool cash included in the priority calculation.
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims.
    /// @param totalSeniorClaimsUsdc Total claims senior to fresh payouts; currently trader claims only.
    /// @param reservedSeniorCashUsdc Senior claim amount notionally reserved; it may exceed physical assets.
    /// @param freeCashUsdc Physical cash left for fresh payouts after the senior reservation.
    /// @param claimServiceableUsdc Amount of the selected existing claim that can be serviced in full-priority order.
    struct SeniorCashReservation {
        uint256 physicalAssetsUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 totalSeniorClaimsUsdc;
        uint256 reservedSeniorCashUsdc;
        uint256 freeCashUsdc;
        uint256 claimServiceableUsdc;
    }

    /// @notice Reserves aggregate trader claims and reports cash available for a fresh payout.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims (6 decimals).
    /// @return reservation Senior reservation and residual free-cash snapshot.
    function reserveFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(physicalAssetsUsdc, traderClaimBalanceUsdc);
    }

    /// @notice Computes cash serviceable for one existing claim while preserving all other trader claims.
    /// @dev Returns zero serviceable cash whenever physical assets cannot cover the aggregate claim balance; claims
    ///      are not serviced pro rata in that state. `claimAmountUsdc` is expected to be part of the aggregate balance.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims including the selected claim (6 decimals).
    /// @param claimAmountUsdc Selected claim amount to service (6 decimals).
    /// @return reservation Senior reservation snapshot with `claimServiceableUsdc` populated.
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

    /// @notice Returns cash senior to fresh payouts for the current priority model.
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims (6 decimals).
    /// @return Aggregate senior cash reservation (6 decimals).
    function reservedSeniorCashUsdc(
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return traderClaimBalanceUsdc;
    }

    /// @notice Returns physical cash remaining after reserving aggregate trader claims.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims (6 decimals).
    /// @return Cash available for fresh payouts (6 decimals).
    function availableCashForFreshPayouts(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc
    ) internal pure returns (uint256) {
        return reserveFreshPayouts(physicalAssetsUsdc, traderClaimBalanceUsdc).freeCashUsdc;
    }

    /// @notice Returns how much of one existing claim is serviceable under strict claim priority.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims including the selected claim (6 decimals).
    /// @param claimAmountUsdc Selected claim amount (6 decimals).
    /// @return Serviceable amount of the selected claim (6 decimals).
    function availableCashForClaimService(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (uint256) {
        return reserveClaimService(physicalAssetsUsdc, traderClaimBalanceUsdc, claimAmountUsdc).claimServiceableUsdc;
    }

    /// @notice Returns whether a positive fresh payout fits entirely within unreserved cash.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims (6 decimals).
    /// @param amountUsdc Fresh payout amount (6 decimals).
    /// @return Whether the full payout is currently affordable.
    function canPayFreshPayout(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 amountUsdc
    ) internal pure returns (bool) {
        return amountUsdc > 0 && amountUsdc <= availableCashForFreshPayouts(physicalAssetsUsdc, traderClaimBalanceUsdc);
    }

    /// @notice Returns whether a positive existing claim can be serviced in full under strict claim priority.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims including the selected claim (6 decimals).
    /// @param claimAmountUsdc Selected claim amount (6 decimals).
    /// @return Whether the selected claim can be serviced in full.
    function canServiceClaim(
        uint256 physicalAssetsUsdc,
        uint256 traderClaimBalanceUsdc,
        uint256 claimAmountUsdc
    ) internal pure returns (bool) {
        return claimAmountUsdc > 0
            && claimAmountUsdc
                <= availableCashForClaimService(physicalAssetsUsdc, traderClaimBalanceUsdc, claimAmountUsdc);
    }

    /// @notice Subtracts `rhs` from `lhs`, flooring the result at zero.
    /// @param lhs Minuend.
    /// @param rhs Subtrahend.
    /// @return Saturating subtraction result.
    function _saturatingSub(
        uint256 lhs,
        uint256 rhs
    ) private pure returns (uint256) {
        return lhs > rhs ? lhs - rhs : 0;
    }

    /// @notice Builds the common senior reservation fields used by payout and claim-service checks.
    /// @param physicalAssetsUsdc Physical pool assets (6 decimals).
    /// @param traderClaimBalanceUsdc Aggregate outstanding trader claims (6 decimals).
    /// @return reservation Senior reservation and residual free-cash snapshot.
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

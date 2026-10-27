// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @title CashPriorityLib
/// @notice Computes cash reserved for existing trader claims before fresh protocol payouts.
library CashPriorityLib {

    /// @notice Snapshot of senior claim reservations and the cash left for a requested action.
    /// @dev All fields are settlement token amounts with 6 decimals.
    /// @param physicalAssets Physical pool cash included in the priority calculation.
    /// @param traderClaimBalanceAssets Aggregate outstanding trader claims.
    /// @param totalSeniorClaimsAssets Total claims senior to fresh payouts; currently trader claims only.
    /// @param reservedSeniorCashAssets Senior claim amount notionally reserved; it may exceed physical assets.
    /// @param freeCashAssets Physical cash left for fresh payouts after the senior reservation.
    struct SeniorCashReservation {
        uint256 physicalAssets;
        uint256 traderClaimBalanceAssets;
        uint256 totalSeniorClaimsAssets;
        uint256 reservedSeniorCashAssets;
        uint256 freeCashAssets;
    }

    /// @notice Reserves aggregate trader claims and reports cash available for a fresh payout.
    /// @param physicalAssets Physical pool assets (6 decimals).
    /// @param traderClaimBalanceAssets Aggregate outstanding trader claims (6 decimals).
    /// @return reservation Senior reservation and residual free-cash snapshot.
    function reserveFreshPayouts(
        uint256 physicalAssets,
        uint256 traderClaimBalanceAssets
    ) internal pure returns (SeniorCashReservation memory reservation) {
        return _buildSeniorCashReservation(physicalAssets, traderClaimBalanceAssets);
    }

    /// @notice Returns cash senior to fresh payouts for the current priority model.
    /// @param traderClaimBalanceAssets Aggregate outstanding trader claims (6 decimals).
    /// @return Aggregate senior cash reservation (6 decimals).
    function reservedSeniorCashAssets(
        uint256 traderClaimBalanceAssets
    ) internal pure returns (uint256) {
        return traderClaimBalanceAssets;
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

    /// @notice Builds the senior reservation fields used by fresh-payout checks.
    /// @param physicalAssets Physical pool assets (6 decimals).
    /// @param traderClaimBalanceAssets Aggregate outstanding trader claims (6 decimals).
    /// @return reservation Senior reservation and residual free-cash snapshot.
    function _buildSeniorCashReservation(
        uint256 physicalAssets,
        uint256 traderClaimBalanceAssets
    ) private pure returns (SeniorCashReservation memory reservation) {
        reservation.physicalAssets = physicalAssets;
        reservation.traderClaimBalanceAssets = traderClaimBalanceAssets;
        reservation.totalSeniorClaimsAssets = reservedSeniorCashAssets(traderClaimBalanceAssets);
        reservation.reservedSeniorCashAssets = reservation.totalSeniorClaimsAssets;
        reservation.freeCashAssets = _saturatingSub(physicalAssets, reservation.reservedSeniorCashAssets);
    }

}

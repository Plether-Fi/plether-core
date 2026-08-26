// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title JuniorMaintenanceFeeMathLib
/// @notice Fixed-hour dilution math for the Junior tranche maintenance fee.
/// @dev The hourly fee is rounded down and retention is rounded up at every multiplication. The resulting fee-share
///      quote therefore never exceeds the configured nominal charge. Callers are responsible for selecting at most
///      `MAX_CHARGE_HOURS` completed Unix-hour periods and for applying any catch-up forgiveness policy.
library JuniorMaintenanceFeeMathLib {

    /// @notice Fixed-point scale used for hourly retention math.
    uint256 internal constant RAY = 1e27;

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Number of fixed 365-day-year hours used to convert nominal APR into an hourly fee.
    uint256 internal constant HOURS_PER_YEAR = 8760;

    /// @notice Maximum governance-configurable nominal annual fee.
    uint256 internal constant MAX_APR_BPS = 1000;

    /// @notice Maximum number of completed hours charged by one crystallization.
    uint256 internal constant MAX_CHARGE_HOURS = HOURS_PER_YEAR;

    /// @notice The nominal annual fee exceeds the protocol cap.
    error JuniorMaintenanceFeeMathLib__InvalidAprBps(uint256 aprBps);

    /// @notice The requested crystallization period exceeds the bounded one-year catch-up window.
    error JuniorMaintenanceFeeMathLib__InvalidChargeableHours(uint256 chargeableHours);

    /// @notice Converts a nominal annual basis-point rate into a downward-rounded hourly RAY rate.
    function hourlyFeeRay(
        uint256 aprBps
    ) internal pure returns (uint256) {
        if (aprBps > MAX_APR_BPS) {
            revert JuniorMaintenanceFeeMathLib__InvalidAprBps(aprBps);
        }

        return Math.mulDiv(aprBps, RAY, BPS * HOURS_PER_YEAR, Math.Rounding.Floor);
    }

    /// @notice Returns the upward-rounded retained Junior ownership fraction after completed fee hours.
    /// @dev Exponentiation by squaring keeps execution logarithmic in `chargeableHours`.
    function retentionRay(
        uint256 aprBps,
        uint256 chargeableHours
    ) internal pure returns (uint256) {
        if (chargeableHours > MAX_CHARGE_HOURS) {
            revert JuniorMaintenanceFeeMathLib__InvalidChargeableHours(chargeableHours);
        }

        uint256 hourlyRetentionRay = RAY - hourlyFeeRay(aprBps);
        return _rayPowUp(hourlyRetentionRay, chargeableHours);
    }

    /// @notice Returns Junior shares to mint so the recipient owns the accrued fraction after dilution.
    /// @param rawSupply Existing ERC-20 Junior supply, excluding the ERC-4626 virtual-share offset.
    /// @param aprBps Nominal annual maintenance fee in basis points.
    /// @param chargeableHours Number of completed fee hours, capped at one fixed year.
    function pendingFeeShares(
        uint256 rawSupply,
        uint256 aprBps,
        uint256 chargeableHours
    ) internal pure returns (uint256 feeShares) {
        uint256 retainedRay = retentionRay(aprBps, chargeableHours);
        if (rawSupply == 0 || retainedRay == RAY) {
            return 0;
        }

        return Math.mulDiv(rawSupply, RAY - retainedRay, retainedRay, Math.Rounding.Floor);
    }

    /// @dev Computes `baseRay**exponent` in RAY scale, rounding every multiplication toward greater retention.
    function _rayPowUp(
        uint256 baseRay,
        uint256 exponent
    ) private pure returns (uint256 resultRay) {
        resultRay = RAY;

        while (exponent != 0) {
            if (exponent & 1 != 0) {
                resultRay = Math.mulDiv(resultRay, baseRay, RAY, Math.Rounding.Ceil);
            }

            exponent >>= 1;
            if (exponent != 0) {
                baseRay = Math.mulDiv(baseRay, baseRay, RAY, Math.Rounding.Ceil);
            }
        }
    }

}

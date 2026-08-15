// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title HousePoolSeniorCapacityLib
/// @notice Pure protected-senior exposure, admission-capacity, and tranche-ratio helpers.
/// @dev Senior exposure is the greater of current senior principal and its protected high-water mark. Accepted but
///      unfinalized senior deposits are treated as committed exposure for senior admission; the junior-withdrawal
///      covenant intentionally protects active exposure only because pending reservations remain refundable.
library HousePoolSeniorCapacityLib {

    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Returns the senior amount protected by principal accounting or the high-water mark.
    function protectedExposure(
        uint256 seniorPrincipal,
        uint256 seniorHighWaterMark
    ) internal pure returns (uint256) {
        return seniorPrincipal > seniorHighWaterMark ? seniorPrincipal : seniorHighWaterMark;
    }

    /// @notice Returns senior exposure capacity remaining after active exposure and pending reservations.
    /// @dev The absolute and ratio limits both constrain committed exposure. A 0-bps share permits no senior
    ///      exposure, while 10,000 bps disables only the ratio constraint. Subtraction saturates at zero.
    function depositCapacity(
        uint256 seniorPrincipal,
        uint256 seniorHighWaterMark,
        uint256 juniorPrincipal,
        uint256 reservedSeniorDepositAssetsUsdc,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) internal pure returns (uint256) {
        uint256 exposure = protectedExposure(seniorPrincipal, seniorHighWaterMark);
        uint256 limit = exposureLimit(juniorPrincipal, maxSeniorExposureUsdc, maxSeniorShareBps);
        if (exposure >= limit) {
            return 0;
        }

        uint256 remaining = limit - exposure;
        return reservedSeniorDepositAssetsUsdc < remaining ? remaining - reservedSeniorDepositAssetsUsdc : 0;
    }

    /// @notice Returns whether active protected exposure plus all reservations fits both governed limits.
    function commitmentsWithinLimits(
        uint256 seniorPrincipal,
        uint256 seniorHighWaterMark,
        uint256 juniorPrincipal,
        uint256 reservedSeniorDepositAssetsUsdc,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) internal pure returns (bool) {
        uint256 exposure = protectedExposure(seniorPrincipal, seniorHighWaterMark);
        if (reservedSeniorDepositAssetsUsdc > type(uint256).max - exposure) {
            return false;
        }
        uint256 committedExposure = exposure + reservedSeniorDepositAssetsUsdc;
        return committedExposure <= exposureLimit(juniorPrincipal, maxSeniorExposureUsdc, maxSeniorShareBps);
    }

    /// @notice Caps junior withdrawals so remaining junior capital preserves the governed senior-share limit.
    /// @dev The covenant protects active exposure only; pending senior reservations may instead become invalid and
    ///      refundable. A 0-bps share permits junior withdrawals only when active exposure is zero; 10,000 bps is
    ///      unrestricted.
    function juniorWithdrawalRatioCap(
        uint256 seniorPrincipal,
        uint256 seniorHighWaterMark,
        uint256 juniorPrincipal,
        uint256 maxSeniorShareBps
    ) internal pure returns (uint256) {
        if (maxSeniorShareBps >= BPS) {
            return juniorPrincipal;
        }

        uint256 exposure = protectedExposure(seniorPrincipal, seniorHighWaterMark);
        if (exposure == 0) {
            return juniorPrincipal;
        }
        if (maxSeniorShareBps == 0) {
            return 0;
        }

        uint256 requiredJunior =
            _saturatingMulDiv(exposure, BPS - maxSeniorShareBps, maxSeniorShareBps, Math.Rounding.Ceil);
        return juniorPrincipal > requiredJunior ? juniorPrincipal - requiredJunior : 0;
    }

    /// @notice Returns the lower of the absolute exposure ceiling and the share-derived ceiling.
    function exposureLimit(
        uint256 juniorPrincipal,
        uint256 maxSeniorExposureUsdc,
        uint256 maxSeniorShareBps
    ) internal pure returns (uint256) {
        uint256 ratioLimit = _ratioExposureLimit(juniorPrincipal, maxSeniorShareBps);
        return maxSeniorExposureUsdc < ratioLimit ? maxSeniorExposureUsdc : ratioLimit;
    }

    function _ratioExposureLimit(
        uint256 juniorPrincipal,
        uint256 maxSeniorShareBps
    ) private pure returns (uint256) {
        if (maxSeniorShareBps == 0) {
            return 0;
        }
        if (maxSeniorShareBps >= BPS) {
            return type(uint256).max;
        }
        return _saturatingMulDiv(juniorPrincipal, maxSeniorShareBps, BPS - maxSeniorShareBps, Math.Rounding.Floor);
    }

    function _saturatingMulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator,
        Math.Rounding rounding
    ) private pure returns (uint256) {
        if (x == 0 || y == 0) {
            return 0;
        }
        if (y > denominator) {
            uint256 maxSafeX = Math.mulDiv(type(uint256).max, denominator, y);
            if (x > maxSafeX) {
                return type(uint256).max;
            }
        }
        return Math.mulDiv(x, y, denominator, rounding);
    }

}

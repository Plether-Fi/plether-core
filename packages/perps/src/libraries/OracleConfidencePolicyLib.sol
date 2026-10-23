// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Shared confidence bounds for router proposals and oracle configuration application.
library OracleConfidencePolicyLib {

    /// @dev The combined maximum adjustment must be strictly less than the raw basket price. Check individual
    ///      bounds first so malformed inputs cannot overflow the product. Capped order prices need a runtime check too.
    function isValidConfig(
        uint256 maxConfidenceRatioBps,
        uint256 adverseMultiplierBps
    ) internal pure returns (bool) {
        return maxConfidenceRatioBps <= 10_000 && adverseMultiplierBps <= 30_000
            && maxConfidenceRatioBps * adverseMultiplierBps < 100_000_000;
    }

}

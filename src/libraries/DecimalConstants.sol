// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @title DecimalConstants
/// @notice Shared decimal scaling constants for the Plether protocol.
/// @dev Centralizes decimal conversions to prevent scaling bugs.
library DecimalConstants {
    // Scaling Factors
    // USDC (6 dec) + Chainlink (8 dec) -> Token (18 dec): 10^(18+8-6) = 10^20
    uint256 internal constant USDC_TO_TOKEN_SCALE = 1e20;

    // Chainlink (8 dec) -> Morpho (36 dec): 10^(36-8) = 10^28
    uint256 internal constant CHAINLINK_TO_MORPHO_SCALE = 1e28;

    // Chainlink (8 dec) -> Token (18 dec): 10^(18-8) = 10^10
    uint256 internal constant CHAINLINK_TO_TOKEN_SCALE = 1e10;
}

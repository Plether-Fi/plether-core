// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/**
 * @title ISyntheticSplitter
 * @notice Minimal interface for external contracts to interact with SyntheticSplitter.
 * @dev Used by ZapRouter and other integrations.
 */
interface ISyntheticSplitter {
    // ==========================================
    // DATA TYPES
    // ==========================================

    /**
     * @notice Defines the current lifecycle state of the protocol.
     * @param ACTIVE Normal operations. Minting and burning enabled.
     * @param PAUSED Security pause. Minting disabled, burn may be restricted if insolvent.
     * @param SETTLED End of life. Cap breached. Only emergencyRedeem enabled.
     */
    enum Status {
        ACTIVE,
        PAUSED,
        SETTLED
    }

    // ==========================================
    // CORE USER FUNCTIONS
    // ==========================================

    /**
     * @notice Deposits collateral to mint equal amounts of DXY-BEAR and DXY-BULL tokens.
     * @dev Requires approval on USDC. Amount is in 18-decimal token units.
     * @param amount The amount of token pairs to mint.
     */
    function mint(uint256 amount) external;

    /**
     * @notice Burns equal amounts of DXY-BEAR and DXY-BULL tokens to retrieve collateral.
     * @dev Works when not liquidated. May be restricted when paused and insolvent.
     * @param amount The amount of token pairs to burn.
     */
    function burn(uint256 amount) external;

    /**
     * @notice Emergency exit after liquidation. Burns DXY-BEAR for its full CAP value.
     * @dev Only works when protocol is liquidated (price >= CAP).
     * @param amount The amount of DXY-BEAR tokens to burn.
     */
    function emergencyRedeem(uint256 amount) external;

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    /**
     * @notice Returns the current protocol lifecycle status.
     * @return The current Status enum value.
     */
    function currentStatus() external view returns (Status);
}

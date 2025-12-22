// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ISyntheticSplitter {
    // ==========================================
    // DATA TYPES
    // ==========================================

    /**
     * @notice Defines the current lifecycle state of the protocol.
     * @param ACTIVE Normal operations. Minting and Pair Redeeming enabled.
     * @param PAUSED Security pause. Minting disabled. Redemption may be restricted.
     * @param SETTLED End of life. Cap/Floor hit. Only Single-Sided Redemption enabled.
     */
    enum Status {
        ACTIVE,
        PAUSED,
        SETTLED
    }

    // ==========================================
    // EVENTS
    // ==========================================

    event Mint(address indexed user, uint256 collateralDeposited, uint256 tokensMinted);
    event RedeemPair(address indexed user, uint256 tokensBurned, uint256 collateralReturned);
    event RedeemSettled(address indexed user, address indexed token, uint256 tokensBurned, uint256 collateralReturned);

    event ProtocolSettled(uint256 finalPrice, uint256 timestamp);
    event YieldSkimmed(address indexed treasury, uint256 amount);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ==========================================
    // CORE USER FUNCTIONS
    // ==========================================

    /**
     * @notice Deposits collateral to mint equal amounts of Long and Short tokens.
     * @dev Requires approval on the stablecoin (USDT).
     * @param amount The amount of collateral to deposit (e.g., 200 USDT).
     */
    function mint(uint256 amount) external;

    /**
     * @notice Burns equal amounts of Long and Short tokens to retrieve collateral.
     * @dev Only works when Status is ACTIVE.
     * @param amount The amount of tokens to burn (e.g. 100 mDXY + 100 mInvDXY).
     */
    function redeemPair(uint256 amount) external;

    /**
     * @notice Emergency/Final exit. Burns a single token for its settled value.
     * @dev Only works when Status is SETTLED.
     * @param token The address of the token to burn (either mDXY or mInvDXY).
     * @param amount The amount of tokens to burn.
     */
    function redeemSettled(address token, uint256 amount) external;

    // ==========================================
    // ADMIN / KEEPER FUNCTIONS
    // ==========================================

    /**
     * @notice Calculates excess yield (Buffer + Vault - Liabilities) and sends to Treasury.
     * @dev Can be public (anyone can call), or restricted to keepers.
     */
    function skimYield() external;

    /**
     * @notice Updates the Yield Vault adapter.
     * @param newVault The address of the new ERC-4626 compliant adapter.
     */
    function setVault(address newVault) external;

    /**
     * @notice Updates the Treasury address (where yield goes).
     * @param newTreasury The new address (Multisig / DAO / Staking Contract).
     */
    function setTreasury(address newTreasury) external;

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    function currentStatus() external view returns (Status);

    /**
     * @notice Returns the frozen settlement price.
     * @return price The price at which the protocol settled (0 if Active).
     */
    function settledPrice() external view returns (uint256);

    /**
     * @notice Returns the current Collateralization Ratio components.
     * @return totalCollateral Total USDT held (Buffer + Vault).
     * @return totalLiabilities Total USDT owed to token holders.
     */
    function getSystemSolvency() external view returns (uint256 totalCollateral, uint256 totalLiabilities);
}

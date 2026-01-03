// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Morpho Blue market parameters struct
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm; // Interest Rate Model
    uint256 lltv; // Liquidation LTV
}

/// @notice Minimal interface for Morpho Blue protocol
interface IMorpho {
    // ==========================================
    // AUTHORIZATION
    // ==========================================

    /// @notice Set authorization for an address to act on behalf of the caller
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    /// @notice Check if an address is authorized to act on behalf of another
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    // ==========================================
    // MARKET MANAGEMENT
    // ==========================================

    /// @notice Create a new market
    function createMarket(MarketParams memory marketParams) external;

    /// @notice Get market ID from params
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);

    // ==========================================
    // LENDER FUNCTIONS (Supply loan tokens to earn yield)
    // ==========================================

    /// @notice Supply loan assets to a Morpho market as a lender
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    /// @notice Withdraw loan assets from a Morpho market as a lender
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    // ==========================================
    // BORROWER FUNCTIONS (Collateral and borrowing)
    // ==========================================

    /// @notice Supply collateral to a Morpho market as a borrower
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalfOf, bytes calldata data)
        external;

    /// @notice Withdraw collateral from a Morpho market as a borrower
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalfOf, address receiver)
        external;

    /// @notice Borrow assets from a Morpho market
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesIssued);

    /// @notice Repay borrowed assets to a Morpho market
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    /// @notice Get position data for a user in a market
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    /// @notice Get market data
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

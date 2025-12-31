// SPDX-License-Identifier: MIT
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
    /// @notice Supply assets to a Morpho market
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

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

    /// @notice Withdraw assets from a Morpho market
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    /// @notice Check if an address is authorized to act on behalf of another
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

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

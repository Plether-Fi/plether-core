// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

/// @notice Morpho Blue market configuration.
/// @param loanToken Asset being borrowed.
/// @param collateralToken Asset used as collateral.
/// @param oracle Price oracle for collateral valuation.
/// @param irm Interest rate model contract.
/// @param lltv Liquidation loan-to-value ratio.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @title IMorpho
/// @notice Minimal interface for Morpho Blue lending protocol.
/// @dev See https://docs.morpho.org for full documentation.
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
    // INTEREST ACCRUAL
    // ==========================================

    /// @notice Accrue interest for a market
    function accrueInterest(MarketParams memory marketParams) external;

    // ==========================================
    // LIQUIDATION
    // ==========================================

    /// @notice Liquidate an unhealthy position
    /// @param marketParams The market parameters
    /// @param borrower The address of the borrower to liquidate
    /// @param seizedAssets The amount of collateral to seize
    /// @param repaidShares The amount of debt shares to repay (alternative to seizedAssets)
    /// @param data Callback data
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256 assetsSeized, uint256 assetsRepaid);

    // ==========================================
    // FLASH LOANS
    // ==========================================

    /// @notice Execute a flash loan
    /// @param token The token to flash loan
    /// @param assets The amount of tokens to flash loan
    /// @param data Arbitrary data to pass to the callback
    /// @dev Morpho flash loans are fee-free. Callback must repay exact amount.
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

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

/// @title IMorphoFlashLoanCallback
/// @notice Callback interface for Morpho flash loan receivers.
interface IMorphoFlashLoanCallback {
    /// @notice Called by Morpho during flash loan execution.
    /// @param assets Amount of tokens borrowed.
    /// @param data Arbitrary data passed through from flashLoan call.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

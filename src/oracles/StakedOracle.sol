// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IOracle {
    /// @notice Returns the price of 1 unit of Collateral, quoted in Loan Token.
    /// @dev Scaled by 10**(36 - baseUnit + quoteUnit) typically, but here we just respect the underlying oracle's scale.
    function price() external view returns (uint256);
}

/**
 * @title StakedOracle
 * @notice Wrapper that calculates the price of an ERC-4626 share based on the underlying asset price.
 * @dev Price = UnderlyingPrice * ExchangeRate
 * This allows Morpho to see the 'real' value of the collateral as it accrues yield.
 */
contract StakedOracle is IOracle {
    IERC4626 public immutable VAULT;
    IOracle public immutable UNDERLYING_ORACLE;
    uint256 public immutable UNDERLYING_DECIMALS;

    error StakedOracle__InvalidPrice();

    /**
     * @param _vault The ERC-4626 Staked Token (e.g. stDXY-BULL)
     * @param _underlyingOracle The oracle for the raw token (e.g. DXY-BULL Chainlink Oracle)
     */
    constructor(address _vault, address _underlyingOracle) {
        VAULT = IERC4626(_vault);
        UNDERLYING_ORACLE = IOracle(_underlyingOracle);
        // We need decimals to scale the exchange rate correctly
        UNDERLYING_DECIMALS = 10 ** IERC20Metadata(VAULT.asset()).decimals();
    }

    function price() external view override returns (uint256) {
        // 1. Get the price of the raw DXY-BULL token
        // Example: $1.05 (scaled 1e36)
        uint256 rawPrice = UNDERLYING_ORACLE.price();
        if (rawPrice == 0) revert StakedOracle__InvalidPrice();

        // 2. Get the Exchange Rate (How much DXY-BULL is 1 stDXY-BULL worth?)
        // Example: 1.02 (Yield has accrued)
        // convertToAssets(1e18) returns 1.02e18
        uint256 oneShare = 10 ** IERC20Metadata(address(VAULT)).decimals();
        uint256 assetsPerShare = VAULT.convertToAssets(oneShare);

        // 3. Calculate Staked Price
        // Price = RawPrice * (Assets / 1 Share)
        // We divide by UNDERLYING_DECIMALS to normalize the exchange rate
        return (rawPrice * assetsPerShare) / UNDERLYING_DECIMALS;
    }
}

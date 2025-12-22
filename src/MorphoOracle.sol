// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./interfaces/AggregatorV3Interface.sol";

interface IMorphoOracle {
    /// @notice Returns the price of 1 unit of collateral, quoted in the loan asset, scaled to 1e36.
    function price() external view returns (uint256);
}

contract MorphoOracle is IMorphoOracle {
    AggregatorV3Interface public immutable basketOracle;
    uint256 public immutable CAP;
    bool public immutable isInverse; // True = Bull Token (Cap - Price)

    // Scaling: 8 decimals (Chainlink) -> 36 decimals (Morpho)
    uint256 constant SCALE_FACTOR = 1e28;

    error MorphoOracle__InvalidPrice();
    error MorphoOracle__CapBreached();

    /**
     * @param _basketOracle Address of your BasketOracle
     * @param _cap The Splitter Cap in 8 decimals (e.g. $2.00 = 200,000,000)
     * @param _isInverse If true, calculates (Cap - Price). If false, returns Price.
     */
    constructor(address _basketOracle, uint256 _cap, bool _isInverse) {
        basketOracle = AggregatorV3Interface(_basketOracle);
        CAP = _cap;
        isInverse = _isInverse;
    }

    function price() external view override returns (uint256) {
        // 1. Get Price from Basket (8 decimals)
        (, int256 rawPrice,,,) = basketOracle.latestRoundData();

        // Safety: Valid price and not stale (simple check, consumer can add strict staleness)
        if (rawPrice <= 0) revert MorphoOracle__InvalidPrice();

        uint256 basketPrice = uint256(rawPrice);
        uint256 finalPrice;

        // 2. Calculate Token Value
        if (isInverse) {
            // Logic for Bull Token (mDXY)
            // Value = Cap - Basket

            if (basketPrice >= CAP) {
                // Scenario: Dollar crashed hard, or Basket pumped hard.
                // The Bull token is effectively worthless (or negative, which implies 0).
                // We return 0 so the lending market knows the collateral is dead.
                return 0;
            }
            finalPrice = CAP - basketPrice;
        } else {
            // Logic for Bear Token (mInvDXY)
            // Value = Basket
            finalPrice = basketPrice;
        }

        // 3. Scale Up to 1e36
        // Example: Price $1.00 (10^8) * 10^28 = 10^36
        return finalPrice * SCALE_FACTOR;
    }
}

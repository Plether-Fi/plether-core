// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockOracle is AggregatorV3Interface {

    int256 public price;
    uint8 public _decimals;
    string public _description;
    uint256 public _updatedAt;

    constructor(
        int256 _initialPrice,
        string memory description_
    ) {
        price = _initialPrice;
        _decimals = 8; // Default to Chainlink USD standard
        _description = description_;
        _updatedAt = block.timestamp;
    }

    // Test Helper: Allow us to change the price dynamically
    function updatePrice(
        int256 _newPrice
    ) external {
        price = _newPrice;
        _updatedAt = block.timestamp;
    }

    // Required by Interface
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, _updatedAt, _updatedAt, 1);
    }

    // Helper to simulate stale data
    function setUpdatedAt(
        uint256 _timestamp
    ) external {
        _updatedAt = _timestamp;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, _updatedAt, _updatedAt, 1);
    }

}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockOracle is AggregatorV3Interface {

    struct Round {
        int256 price;
        uint256 updatedAt;
    }

    uint8 public _decimals;
    string public _description;
    uint80 public currentRoundId;
    mapping(uint80 => Round) public rounds;

    constructor(
        int256 _initialPrice,
        string memory description_
    ) {
        _decimals = 8;
        _description = description_;
        currentRoundId = 1;
        rounds[1] = Round(_initialPrice, block.timestamp);
    }

    function updatePrice(
        int256 _newPrice
    ) external {
        currentRoundId++;
        rounds[currentRoundId] = Round(_newPrice, block.timestamp);
    }

    function setUpdatedAt(
        uint256 _timestamp
    ) external {
        rounds[currentRoundId].updatedAt = _timestamp;
    }

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
        uint80 _roundId
    ) external view override returns (uint80, int256, uint256, uint256, uint80) {
        Round storage r = rounds[_roundId];
        require(r.updatedAt != 0, "No data for round");
        return (_roundId, r.price, r.updatedAt, r.updatedAt, _roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        Round storage r = rounds[currentRoundId];
        return (currentRoundId, r.price, r.updatedAt, r.updatedAt, currentRoundId);
    }

}

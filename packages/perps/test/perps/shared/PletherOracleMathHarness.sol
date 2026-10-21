// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PletherOracle} from "@plether/perps/PletherOracle.sol";

/// @dev Only supplies the policy views consumed by public oracle reads; no pricing implementation lives here.
contract OracleMathPolicyFixture {

    address public immutable orderRouter = msg.sender;
    uint256 public constant CAP_PRICE = 2e8;
    uint64 public constant lastMarkTime = 0;
    uint256 public constant engineMarkStalenessLimit = 60;
    uint256 public constant markStalenessLimit = 60;
    uint256 public constant fadMaxStaleness = 3 days;
    bool public constant isFadWindow = false;
    bool public constant isOracleFrozen = false;

}

/// @dev Exposes inherited production arithmetic without copying it. Basket tests use PletherOracle public reads.
contract PletherOracleMathHarness is PletherOracle {

    constructor(
        address policy,
        address pyth
    ) PletherOracle(policy, policy, pyth, _feedIds(), _weights(), _basePrices(), new bool[](1)) {}

    function normalizePythPrice(
        int64 price,
        int32 exponent
    ) external pure returns (uint256) {
        return _normalizePythPrice(price, exponent);
    }

    function invertPythPrice(
        int64 price,
        int32 exponent
    ) external pure returns (uint256) {
        return _invertPythPrice(price, exponent);
    }

    function _feedIds() private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = bytes32(uint256(1));
    }

    function _weights() private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = 1e18;
    }

    function _basePrices() private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = 1e8;
    }

}

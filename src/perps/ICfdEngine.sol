// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";

interface ICfdEngine {

    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (int256 settlementUsdc);

    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (uint256 keeperBountyUsdc);

    function globalBullMaxProfit() external view returns (uint256);
    function globalBearMaxProfit() external view returns (uint256);
    function accumulatedFeesUsdc() external view returns (uint256);

}

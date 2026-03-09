// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngine {

    /// @notice Settles funding and processes an open/close order at the given oracle price
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (int256 settlementUsdc);

    /// @notice Liquidates an undercollateralized position, returns keeper bounty in USDC
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Worst-case payout for all BULL positions (6 decimals)
    function globalBullMaxProfit() external view returns (uint256);
    /// @notice Worst-case payout for all BEAR positions (6 decimals)
    function globalBearMaxProfit() external view returns (uint256);
    /// @notice Accumulated execution fees awaiting withdrawal (6 decimals)
    function accumulatedFeesUsdc() external view returns (uint256);

    /// @notice True during weekend FX closure or admin-configured FAD days
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed during FAD windows
    function fadMaxStaleness() external view returns (uint256);

}

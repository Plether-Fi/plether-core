// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IOrderRouterAdminHost {

    struct RouterConfig {
        uint256 maxOrderAge;
        uint256 orderExecutionStalenessLimit;
        uint256 liquidationStalenessLimit;
        uint256 pythMaxConfidenceRatioBps;
        uint256 minOpenNotionalUsdc;
        uint256 openOrderExecutionBountyBps;
        uint256 minOpenOrderExecutionBountyUsdc;
        uint256 maxOpenOrderExecutionBountyUsdc;
        uint256 closeOrderExecutionBountyUsdc;
        uint256 maxPendingOrders;
        uint256 minEngineGas;
        uint256 maxPruneOrdersPerCall;
    }

    struct OracleConfig {
        address pyth;
        bytes32[] feedIds;
        uint256[] quantities;
        uint256[] basePrices;
        bool[] inversions;
    }

    function applyRouterConfig(
        RouterConfig calldata config
    ) external;

    function applyOracleConfig(
        OracleConfig calldata config
    ) external;

}

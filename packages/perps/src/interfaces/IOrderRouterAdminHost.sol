// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Router host surface called by the timelocked router admin.
interface IOrderRouterAdminHost {

    struct RouterConfig {
        uint256 maxOrderAge;
        uint256 orderExecutionStalenessLimit;
        uint256 liquidationStalenessLimit;
        uint256 pythMaxConfidenceRatioBps;
        uint256 orderSettlementWindow;
        uint256 maxComponentPublishTimeDivergence;
        uint256 adverseConfidenceMultiplierBps;
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
        address pletherOracle;
    }

    /// @notice Applies finalized router queue, bounty, and execution bounds.
    /// @param config Router configuration to apply
    function applyRouterConfig(
        RouterConfig calldata config
    ) external;

    /// @notice Applies finalized oracle integration configuration.
    /// @param config Oracle configuration to apply
    function applyOracleConfig(
        OracleConfig calldata config
    ) external;

}

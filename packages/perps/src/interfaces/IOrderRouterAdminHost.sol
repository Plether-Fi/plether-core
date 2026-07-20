// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Router host surface called by the timelocked router admin.
interface IOrderRouterAdminHost {

    /// @notice Complete router queue, oracle-policy, bounty, and execution-resource configuration.
    /// @param maxOrderAge Maximum pending lifetime before an order is expired, in seconds.
    /// @param orderExecutionStalenessLimit Maximum live order-execution price age, in seconds.
    /// @param liquidationStalenessLimit Maximum live liquidation price age, in seconds.
    /// @param pythMaxConfidenceRatioBps Maximum Pyth confidence interval divided by component price, in basis points.
    /// @param orderSettlementWindow Post-commit window searched for a unique historical execution basket, in seconds.
    /// @param maxComponentPublishTimeDivergence Maximum publish-time spread for historical baskets, in seconds.
    /// @param adverseConfidenceMultiplierBps Multiplier applied to basket confidence for account-adverse prices, in bps.
    /// @param minOpenNotionalUsdc Minimum open/increase notional accepted at commit, in 6-decimal USDC.
    /// @param openOrderExecutionBountyBps Open bounty rate applied to reference notional, in basis points.
    /// @param minOpenOrderExecutionBountyUsdc Minimum open-order bounty in 6-decimal USDC.
    /// @param maxOpenOrderExecutionBountyUsdc Maximum open-order bounty in 6-decimal USDC.
    /// @param closeOrderExecutionBountyUsdc Fixed close-order bounty in 6-decimal USDC.
    /// @param maxPendingOrders Maximum number of live pending orders per account.
    /// @param minEngineGas Minimum EIP-150-forwardable gas required before an engine execution attempt.
    /// @param maxPruneOrdersPerCall Maximum expired queue heads one execution call may terminally prune.
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

    /// @notice Address-only Plether oracle integration configuration.
    /// @param pletherOracle Deployed oracle bound to this router's engine and HousePool and exposing nonzero Pyth.
    struct OracleConfig {
        address pletherOracle;
    }

    /// @notice Applies finalized router queue, bounty, and execution bounds.
    /// @dev Callable only by this router's deployed admin. Also forwards the oracle-policy subset to the active oracle;
    ///      the admin is responsible for validation and timelock enforcement.
    /// @param config Router configuration to apply
    function applyRouterConfig(
        RouterConfig calldata config
    ) external;

    /// @notice Applies finalized oracle integration configuration.
    /// @dev Callable only by the router admin. The router validates deployed code, nonzero Pyth, and matching engine and
    ///      HousePool bindings before replacing the active oracle.
    /// @param config Oracle configuration to apply
    function applyOracleConfig(
        OracleConfig calldata config
    ) external;

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderCommitHandler} from "@plether/perps/router/OrderCommitHandler.sol";
import {OrderExecutionHandler} from "@plether/perps/router/OrderExecutionHandler.sol";
import {OrderLiquidationHandler} from "@plether/perps/router/OrderLiquidationHandler.sol";

/// @title OrderHandler
/// @notice Composes commit, execution, and liquidation handlers and applies admin-finalized configuration.
abstract contract OrderHandler is OrderCommitHandler, OrderExecutionHandler, OrderLiquidationHandler {

    /// @notice Applies a complete router and active-oracle policy configuration after admin authentication.
    /// @dev Time values are seconds, monetary values are 6-decimal USDC, ratios are basis points, gas is
    ///      unscaled gas units, and count limits are unscaled. The admin validates bounds before forwarding.
    /// @param config Timelocked configuration finalized by this router's admin.
    function _applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) internal {
        _onlyAdmin();
        maxOrderAge = config.maxOrderAge;
        minOpenNotionalUsdc = config.minOpenNotionalUsdc;
        pletherOracle.applyConfig(
            IPletherOracle.OracleConfig({
                orderExecutionStalenessLimit: config.orderExecutionStalenessLimit,
                liquidationStalenessLimit: config.liquidationStalenessLimit,
                pythMaxConfidenceRatioBps: config.pythMaxConfidenceRatioBps,
                orderSettlementWindow: config.orderSettlementWindow,
                maxComponentPublishTimeDivergence: config.maxComponentPublishTimeDivergence,
                adverseConfidenceMultiplierBps: config.adverseConfidenceMultiplierBps
            })
        );
        openOrderExecutionBountyBps = config.openOrderExecutionBountyBps;
        minOpenOrderExecutionBountyUsdc = config.minOpenOrderExecutionBountyUsdc;
        maxOpenOrderExecutionBountyUsdc = config.maxOpenOrderExecutionBountyUsdc;
        closeOrderExecutionBountyUsdc = config.closeOrderExecutionBountyUsdc;
        maxPendingOrders = config.maxPendingOrders;
        minEngineGas = config.minEngineGas;
        maxPruneOrdersPerCall = config.maxPruneOrdersPerCall;
    }

    /// @notice Installs an admin-finalized Plether oracle after wiring validation.
    /// @param config Timelocked oracle-address configuration finalized by this router's admin.
    function _applyOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) internal {
        _onlyAdmin();
        _setOracleConfig(config.pletherOracle);
    }

}

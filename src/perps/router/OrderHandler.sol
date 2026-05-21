// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAdminHost} from "../interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "../interfaces/IPletherOracle.sol";
import {OrderCommitHandler} from "./OrderCommitHandler.sol";
import {OrderExecutionHandler} from "./OrderExecutionHandler.sol";
import {OrderLiquidationHandler} from "./OrderLiquidationHandler.sol";

/// @notice Composes the router's internal action handlers behind the external OrderRouter facade.
abstract contract OrderHandler is OrderCommitHandler, OrderExecutionHandler, OrderLiquidationHandler {

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

    function _applyOracleConfig(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) internal {
        _onlyAdmin();
        _setOracleConfig(config.pletherOracle);
    }

}

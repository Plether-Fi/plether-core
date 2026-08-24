// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderBountyAccounting} from "@plether/perps/router/OrderBountyAccounting.sol";
import {OrderExecutionHandler} from "@plether/perps/router/OrderExecutionHandler.sol";
import {OrderLiquidationHandler} from "@plether/perps/router/OrderLiquidationHandler.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";
import {PositionProtectionHandler} from "@plether/perps/router/PositionProtectionHandler.sol";

/// @title OrderHandler
/// @notice Composes commit, execution, and liquidation handlers and applies admin-finalized configuration.
abstract contract OrderHandler is PositionProtectionHandler, OrderExecutionHandler, OrderLiquidationHandler {

    function _additionalExecutionBountyUsdc(
        address account
    ) internal view override(PositionProtectionHandler, OrderReservationAccounting) returns (uint256) {
        return PositionProtectionHandler._additionalExecutionBountyUsdc(account);
    }

    function _afterOrderDeleted(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal override(PositionProtectionHandler, OrderRouterBase) {
        PositionProtectionHandler._afterOrderDeleted(orderId, account, terminalStatus);
    }

    function _protectionBountiesToForfeitOnLiquidation(
        address account
    ) internal override(PositionProtectionHandler, OrderBountyAccounting) returns (uint256 forfeitedUsdc) {
        return PositionProtectionHandler._protectionBountiesToForfeitOnLiquidation(account);
    }

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
                basketMaxConfidenceRatioBps: config.basketMaxConfidenceRatioBps,
                orderSettlementWindow: config.orderSettlementWindow,
                maxComponentPublishTimeDivergence: config.maxComponentPublishTimeDivergence,
                adverseConfidenceMultiplierBps: config.adverseConfidenceMultiplierBps
            })
        );
        openOrderExecutionBountyBps = config.openOrderExecutionBountyBps;
        minOpenOrderExecutionBountyUsdc = config.minOpenOrderExecutionBountyUsdc;
        maxOpenOrderExecutionBountyUsdc = config.maxOpenOrderExecutionBountyUsdc;
        closeOrderExecutionBountyUsdc = config.closeOrderExecutionBountyUsdc;
        positionProtectionCommitsEnabled = config.positionProtectionCommitsEnabled;
        positionProtectionTriggerBountyUsdc = config.positionProtectionTriggerBountyUsdc;
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

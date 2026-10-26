// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {OrderBountyAccounting} from "@plether/perps/router/OrderBountyAccounting.sol";
import {OrderExecutionHandler} from "@plether/perps/router/OrderExecutionHandler.sol";
import {OrderLiquidationHandler} from "@plether/perps/router/OrderLiquidationHandler.sol";
import {OrderRouterBase} from "@plether/perps/router/OrderRouterBase.sol";
import {PositionProtectionHandler} from "@plether/perps/router/PositionProtectionHandler.sol";

/// @title OrderHandler
/// @notice Composes commit, execution, and liquidation handlers and applies admin-finalized configuration.
abstract contract OrderHandler is PositionProtectionHandler, OrderExecutionHandler, OrderLiquidationHandler {

    function _afterOrderDeleted(
        uint64 orderId,
        address account,
        IOrderRouterAccounting.OrderStatus terminalStatus
    ) internal override(PositionProtectionHandler, OrderRouterBase) {
        PositionProtectionHandler._afterOrderDeleted(orderId, account, terminalStatus);
    }

    function _protectionBountiesToForfeitOnLiquidation(
        address account
    ) internal override(PositionProtectionHandler, OrderBountyAccounting) returns (uint256 forfeitedAssets) {
        return PositionProtectionHandler._protectionBountiesToForfeitOnLiquidation(account);
    }

    function _failPendingOpenProtectionForRiskOff(
        uint64 parentOrderId,
        address account
    ) internal returns (uint256 refundableProtectionBountyAssets) {
        return positionProtectionBook.failPendingOpenForRiskOff(parentOrderId, account);
    }

    /// @notice Applies the pre-oracle portion of a finalized configuration after admin authentication.
    /// @dev Time values are seconds, monetary values are 6-decimal settlement token, ratios are basis points, gas is
    ///      unscaled gas units, and count limits are unscaled. The admin validates bounds before forwarding.
    /// @param config Timelocked configuration finalized by this router's admin.
    function _applyRouterConfig(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) internal {
        _onlyAdmin();
        maxExecutionWindowSeconds = config.maxExecutionWindowSeconds;
        minOpenNotionalAssets = config.minOpenNotionalAssets;
    }

    /// @notice Applies the post-oracle Router fields of an authenticated finalized configuration.
    /// @dev The external Router entrypoint invokes the immutable sidecar between these two storage phases so the
    ///      active oracle observes exactly the same update ordering as the former in-Router implementation.
    function _applyRouterConfigAfterOracle(
        IOrderRouterAdminHost.RouterConfig calldata config
    ) internal {
        openOrderExecutionBountyBps = config.openOrderExecutionBountyBps;
        minOpenOrderExecutionBountyAssets = config.minOpenOrderExecutionBountyAssets;
        maxOpenOrderExecutionBountyAssets = config.maxOpenOrderExecutionBountyAssets;
        positionProtectionTriggerBountyAssets = config.positionProtectionTriggerBountyAssets;
        maxPendingOrders = config.maxPendingOrders;
        minEngineGas = config.minEngineGas;
        maxPruneOrdersPerCall = config.maxPruneOrdersPerCall;
    }

    /// @notice Authenticates an admin-finalized oracle rotation and validates candidate wiring before policy copying.
    /// @param config Timelocked oracle-address configuration finalized by this router's admin.
    function _validateOracleRotation(
        IOrderRouterAdminHost.OracleConfig calldata config
    ) internal view {
        _onlyAdmin();
        _validateOracleConfig(config.pletherOracle);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderLiquidationBatchLogic} from "@plether/perps/router/OrderLiquidationBatchLogic.sol";

/// @title OrderRouterLiquidationBatchSidecar
/// @notice Immutable stateless delegate module for the Router's keeper and liquidation orchestration.
/// @dev Declares no mutable storage and accepts delegated execution only in its exact constructor-bound Router.
contract OrderRouterLiquidationBatchSidecar is OrderLiquidationBatchLogic {

    error OrderRouterLiquidationBatchSidecar__ZeroRouter();

    /// @notice Only Router address in which this code may execute by delegatecall.
    address public immutable ROUTER;

    constructor(
        address expectedRouter
    ) {
        if (expectedRouter == address(0)) {
            revert OrderRouterLiquidationBatchSidecar__ZeroRouter();
        }
        ROUTER = expectedRouter;
    }

    function _delegatedLogicRouter() internal view override returns (address) {
        return ROUTER;
    }

}

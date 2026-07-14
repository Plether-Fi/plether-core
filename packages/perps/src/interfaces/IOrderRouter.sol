// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPerpsTraderActions} from "@plether/perps/interfaces/IPerpsTraderActions.sol";

/// @notice Full delayed-order router surface plus canonical router errors and events.
interface IOrderRouter is IPerpsKeeper, IPerpsTraderActions, IOrderRouterAccounting, IOrderRouterAdminHost {

    error OrderRouter__ZeroSize();
    error OrderRouter__OracleValidation(uint8 code);
    error OrderRouter__QueueState(uint8 code);
    error OrderRouter__CommitValidation(uint8 code);
    error OrderRouter__InsufficientGas();
    error OrderRouter__PredictableOpenInvalid(uint8 code);

    event OrderCommitted(uint64 indexed orderId, address indexed account, CfdTypes.Side side);

    /// @notice Push a fresh mark price to the engine without processing an order.
    /// @param pythUpdateData Pyth price update blobs; attach ETH to cover the Pyth fee
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable;

}

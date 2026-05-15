// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IOrderRouterAccounting} from "./IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "./IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "./IPerpsKeeper.sol";
import {IPerpsTraderActions} from "./IPerpsTraderActions.sol";

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
    function updateMarkPrice(
        bytes[] calldata pythUpdateData
    ) external payable;

}

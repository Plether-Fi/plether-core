// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

/// @notice Trader-facing action surface aligned with the current delayed-order router model.
interface IPerpsTraderActions {

    function submitOrder(
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDeltaUsdc,
        uint256 acceptablePrice,
        bool isReduceOnly
    ) external;

}

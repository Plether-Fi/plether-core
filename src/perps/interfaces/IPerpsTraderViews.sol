// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact trader-facing read surface for the simplified perps product API.
interface IPerpsTraderViews {

    function getTraderAccount(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData);

    function getPosition(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PositionView memory viewData);

    function getPendingOrders(
        bytes32 accountId
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending);

    function isLiquidatable(
        bytes32 accountId
    ) external view returns (bool);
}

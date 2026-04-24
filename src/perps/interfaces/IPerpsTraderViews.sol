// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact trader-facing read surface for the simplified perps product API.
interface IPerpsTraderViews {

    function getTraderAccount(
        address account
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData);

    function getPosition(
        address account
    ) external view returns (PerpsViewTypes.PositionView memory viewData);

    function getPendingOrders(
        address account
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending);

    function isLiquidatable(
        address account
    ) external view returns (bool);

}

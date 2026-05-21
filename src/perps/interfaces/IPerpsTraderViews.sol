// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "./PerpsViewTypes.sol";

/// @notice Compact trader-facing read surface for the simplified perps product API.
interface IPerpsTraderViews {

    /// @notice Returns compact account equity, withdrawable balance, and queued margin state.
    /// @param account Account to inspect
    /// @return viewData Trader account summary
    function getTraderAccount(
        address account
    ) external view returns (PerpsViewTypes.TraderAccountView memory viewData);

    /// @notice Returns compact current-position state.
    /// @param account Account to inspect
    /// @return viewData Position summary
    function getPosition(
        address account
    ) external view returns (PerpsViewTypes.PositionView memory viewData);

    /// @notice Returns currently pending delayed orders for an account.
    /// @param account Account to inspect
    /// @return pending Pending orders in account queue order
    function getPendingOrders(
        address account
    ) external view returns (PerpsViewTypes.PendingOrderView[] memory pending);

    /// @notice Returns whether the account's current live position is liquidatable.
    /// @param account Account to inspect
    function isLiquidatable(
        address account
    ) external view returns (bool);

}

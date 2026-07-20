// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @notice Compact protocol-wide read surface implemented by `PerpsPublicLens` for product consumers.
interface IProtocolViews {

    /// @notice Returns high-level protocol runtime status flags.
    /// @dev Phase is `Configuring` until engine pool/router wiring and the HousePool risk lifecycle are active,
    ///      `Degraded` when the wired engine's insolvency latch is set, and `Active` otherwise. Price uses 8 decimals
    ///      and mark time is a Unix timestamp; this view reports state but does not enforce mark freshness.
    /// @return viewData Protocol phase, cached mark, FAD, oracle-frozen, trading, and withdrawal status
    function getProtocolStatus() external view returns (PerpsViewTypes.ProtocolStatusView memory viewData);

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

/// @notice Rich protocol and HousePool integration read surface for internal tooling.
interface ICfdEngineProtocolLens {

    /// @notice Returns the detailed protocol accounting snapshot.
    /// @dev Legacy detailed protocol lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews`, `IPerpsLPViews`, and
    ///      `IProtocolViews` via `PerpsPublicLens`.
    /// @return snapshot Protocol-level accounting, liability, and solvency values
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot);

    /// @notice Builds the HousePool accounting snapshot against a caller-supplied freshness limit.
    /// @param markStalenessLimit Pool-configured live mark staleness limit
    /// @return snapshot Engine input values consumed by HousePool accounting
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot);

    /// @notice Returns HousePool-facing runtime status sourced from the engine.
    /// @return snapshot Current engine mark time and runtime mode flags
    function getHousePoolStatusSnapshot()
        external
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot);

}

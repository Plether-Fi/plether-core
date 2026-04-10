// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {HousePoolEngineViewTypes} from "./HousePoolEngineViewTypes.sol";
import {ProtocolLensViewTypes} from "./ProtocolLensViewTypes.sol";

interface ICfdEngineProtocolLens {

    /// @dev Legacy detailed protocol lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews`, `IPerpsLPViews`, and
    ///      `IProtocolViews` via `PerpsPublicLens`.
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot);

    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot);

    function getHousePoolStatusSnapshot()
        external
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot);

}

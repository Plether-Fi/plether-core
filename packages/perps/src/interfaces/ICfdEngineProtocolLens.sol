// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

/// @notice Rich protocol and HousePool integration read surface for internal tooling.
/// @dev Permissionless and read-only. Reads cached state without refreshing a mark or mutating the engine. Monetary
///      fields use 6-decimal USDC, prices use 8 decimals, and timestamps or durations use seconds.
interface ICfdEngineProtocolLens {

    /// @notice Returns the detailed protocol accounting snapshot.
    /// @dev Legacy detailed protocol lens kept for internal tooling, tests, and migration.
    ///      Product-facing consumers should prefer `IPerpsTraderViews`, `IPerpsLPViews`, and
    ///      `IProtocolViews` via `PerpsPublicLens`.
    /// @dev Maximum liability is the larger side's maximum-profit envelope. Trader claims are senior pool liabilities:
    ///      they increase withdrawal reserve and reduce effective solvency assets. The protocol treasury balance is
    ///      reported separately and is not an additional solvency deduction in this snapshot.
    /// @return snapshot Protocol-level accounting, liability, claim, and degraded-mode values
    function getProtocolAccountingSnapshot()
        external
        view
        returns (ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot);

    /// @notice Builds the HousePool accounting snapshot against a caller-supplied freshness limit.
    /// @dev Reports custody-capped `HousePool.totalAssets()` plus one authenticated Engine terminal-NAV snapshot:
    ///      signed LP terminal delta, trader claims, larger-side maximum liability, book version, and position flags.
    ///      Supplemental reserve is the liability-scaled settlement buffer. Open positions require freshness; frozen
    ///      mode uses `fadMaxStaleness`, while live policy selects the tighter nonzero engine/pool limit. This function
    ///      selects but does not test the age.
    /// @param markStalenessLimit Pool-configured live mark age limit in seconds; zero delegates to the engine limit
    /// @return snapshot Engine inputs consumed by HousePool reconcile, deposit, and withdrawal accounting
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot);

    /// @notice Returns HousePool-facing runtime status sourced from the engine.
    /// @return snapshot Current cached mark publish time plus oracle-frozen and degraded-mode flags
    function getHousePoolStatusSnapshot()
        external
        view
        returns (HousePoolEngineViewTypes.HousePoolStatusSnapshot memory snapshot);

}

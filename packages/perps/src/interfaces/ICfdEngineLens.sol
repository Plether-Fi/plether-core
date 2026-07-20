// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

/// @notice Read-only planner and liquidation diagnostics for the CFD engine.
/// @dev The lens does not ingest Pyth data, validate oracle freshness, or mutate engine state. Callers supply candidate
///      prices and publish times. USDC amounts use 6 decimals, prices use 8 decimals, and sizes use 18 decimals.
interface ICfdEngineLens {

    /// @notice Returns the engine inspected by this lens.
    /// @return Bound CfdEngine address
    function engine() external view returns (address);

    /// @notice Previews a close/decrease against current pool depth.
    /// @dev Uses current effective `HousePool.totalAssets()` (accounted assets capped by raw custody) for both planning
    ///      solvency and available pool cash. The supplied price is clamped to the engine cap; the preview does not
    ///      validate oracle freshness or slippage.
    /// @param account Account whose position would be closed
    /// @param sizeDelta Position size to close (18 decimals)
    /// @param oraclePrice Candidate execution price, clamped to `CAP_PRICE` (8 decimals)
    /// @return preview Close economics and projected post-operation solvency
    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview);

    /// @notice Previews an open/increase against current pool depth.
    /// @dev This is read-only and uses the caller-supplied oracle price/publish time; it does not ingest Pyth
    ///      updates, fetch Hermes data, validate timing/freshness, or mutate engine mark state. Uses current effective
    ///      `HousePool.totalAssets()` and clamps execution economics to `CAP_PRICE`.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta (18 decimals)
    /// @param marginDelta Margin supplied with the hypothetical order in USDC
    /// @param oraclePrice Oracle price used for the simulation, clamped to CAP_PRICE for execution economics
    /// @param publishTime Hypothetical oracle publish timestamp; currently retained for planner parity
    /// @return preview Validity, economics, projected position health, and liquidation boundary
    function previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (ICfdEngineTypes.OpenPreview memory preview);

    /// @notice Previews the open/increase business-rule revert code at current pool depth.
    /// @dev Equivalent to `uint8(previewOpen(...).invalidReason)` and subject to the same read-only assumptions.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta (18 decimals)
    /// @param marginDelta Margin supplied with the hypothetical order in USDC
    /// @param oraclePrice Candidate execution price (8 decimals)
    /// @param publishTime Hypothetical oracle publish timestamp
    /// @return code Numeric `OpenRevertCode` value
    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code);

    /// @notice Previews how an open/increase failure would be categorized by router policy.
    /// @dev Uses the planner result at current effective pool depth; it does not reproduce router timing, pause,
    ///      slippage, queue, or oracle-validation gates.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta (18 decimals)
    /// @param marginDelta Margin supplied with the hypothetical order in USDC
    /// @param oraclePrice Candidate execution price (8 decimals)
    /// @param publishTime Hypothetical oracle publish timestamp
    /// @return category Commit-time open failure policy category
    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category);

    /// @notice Simulates a close/decrease at caller-supplied pool depth.
    /// @dev Treats `poolDepthUsdc` as both solvency assets and available pool cash; it does not read hypothetical token
    ///      custody or mutate protocol state. Carry-index projection still uses live effective HousePool assets. The
    ///      execution price is clamped to the engine cap.
    /// @param account Account whose position would be closed
    /// @param sizeDelta Position size to close (18 decimals)
    /// @param oraclePrice Candidate execution price (8 decimals)
    /// @param poolDepthUsdc Caller-supplied hypothetical solvency assets and available cash in USDC
    /// @return preview Close economics and projected post-operation solvency
    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview);

    /// @notice Previews liquidation against current pool depth.
    /// @dev Models forfeiture of the account's pending execution bounties before terminal collateral is evaluated.
    ///      Uses current effective `HousePool.totalAssets()`, clamps the price, and does not validate oracle freshness.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Candidate liquidation execution price (8 decimals)
    /// @return preview Liquidation economics and projected post-operation solvency
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview);

    /// @notice Simulates liquidation at caller-supplied pool depth.
    /// @dev Models pending-bounty forfeiture and treats the supplied depth as both solvency assets and pool cash; it
    ///      does not mutate queues or custody and does not validate oracle freshness. Carry-index projection still uses
    ///      live effective HousePool assets.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Candidate liquidation execution price (8 decimals)
    /// @param poolDepthUsdc Caller-supplied hypothetical solvency assets and available cash in USDC
    /// @return preview Liquidation economics and projected post-operation solvency
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview);

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {ICfdEngineTypes} from "./ICfdEngineTypes.sol";

/// @notice Read-only planner and liquidation diagnostics for the CFD engine.
interface ICfdEngineLens {

    /// @notice Returns the engine inspected by this lens.
    function engine() external view returns (address);

    /// @notice Previews a close/decrease against current pool depth.
    /// @param account Account whose position would be closed
    /// @param sizeDelta Position size to close
    /// @param oraclePrice Oracle price used for the simulation
    /// @return preview Close result and revert code
    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview);

    /// @notice Previews an open/increase against current pool depth.
    /// @dev This is read-only and uses the caller-supplied oracle price/publish time; it does not ingest Pyth
    ///      updates, fetch Hermes data, or mutate engine mark state.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta
    /// @param marginDelta Margin delta encoded as the order value
    /// @param oraclePrice Oracle price used for the simulation, clamped to CAP_PRICE for execution economics
    /// @param publishTime Oracle publish timestamp used for the simulated mark
    /// @return preview Open result, economics, and projected risk
    function previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (ICfdEngineTypes.OpenPreview memory preview);

    /// @notice Previews the open/increase business-rule revert code at current pool depth.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta
    /// @param marginDelta Margin delta encoded as the order value
    /// @param oraclePrice Oracle price used for the simulation
    /// @param publishTime Oracle publish timestamp used for the simulated mark
    /// @return code Numeric OpenRevertCode value
    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code);

    /// @notice Previews how an open/increase failure would be categorized by router policy.
    /// @param account Account that would open or increase the position
    /// @param side Position side
    /// @param sizeDelta Position size delta
    /// @param marginDelta Margin delta encoded as the order value
    /// @param oraclePrice Oracle price used for the simulation
    /// @param publishTime Oracle publish timestamp used for the simulated mark
    /// @return category Open failure policy category
    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category);

    /// @notice Simulates a close/decrease at caller-supplied pool depth.
    /// @param account Account whose position would be closed
    /// @param sizeDelta Position size to close
    /// @param oraclePrice Oracle price used for the simulation
    /// @param poolDepthUsdc Hypothetical HousePool depth
    /// @return preview Close result and revert code
    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview);

    /// @notice Previews liquidation against current pool depth.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the preview
    /// @return preview Liquidation result and bounty data
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview);

    /// @notice Simulates liquidation at caller-supplied pool depth.
    /// @param account Account whose position would be tested
    /// @param oraclePrice Oracle price used for the simulation
    /// @param poolDepthUsdc Hypothetical HousePool depth
    /// @return preview Liquidation result and bounty data
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview);

}

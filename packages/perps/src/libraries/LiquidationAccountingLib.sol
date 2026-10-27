// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidationAccountingLib
/// @notice Calculates maintenance requirement, liquidation-charge allocation, and residual settlement for a liquidated position.
/// @dev Monetary fields use 6-decimal settlement token, rates use a 10,000 basis-point denominator, and callers supply the scale
///      converting `size * oraclePrice` to settlement token. Rate calculations use integer division and round down.
library LiquidationAccountingLib {

    /// @notice Risk and liquidation-charge values for a liquidation candidate.
    /// @param equityAssets Signed position equity before the liquidation charge; negative values denote a collateral deficit.
    /// @param reachableCollateralAssets Account collateral eligible for terminal settlement.
    /// @param maintenanceMarginAssets Maintenance or FAD margin requirement at the supplied price.
    /// @param liquidationChargeAssets Total charge after applying the minimum and reachable-collateral cap.
    /// @param keeperBountyAssets Keeper-owned share of the total liquidation charge.
    /// @param protocolLiquidationFeeAssets Protocol-treasury share of the total liquidation charge.
    /// @param lpLiquidationFeeAssets LP-owned remainder after keeper and protocol allocations.
    struct LiquidationState {
        int256 equityAssets;
        uint256 reachableCollateralAssets;
        uint256 maintenanceMarginAssets;
        uint256 liquidationChargeAssets;
        uint256 keeperBountyAssets;
        uint256 protocolLiquidationFeeAssets;
        uint256 lpLiquidationFeeAssets;
    }

    /// @notice Builds liquidation requirements and allocates the collectible charge among keeper, protocol, and LPs.
    /// @dev Notional is `floor(size * oraclePrice / tokenScale)`. The total charge is the greater of the notional-based
    ///      amount and `minBountyAssets`, then capped to `reachableCollateralAssets`; therefore a zero-notional position can
    ///      still produce a minimum charge when collateral is reachable. Keeper and protocol allocations each round
    ///      down according to their configured shares; LPs receive the exact remainder. Callers must ensure the two
    ///      configured shares sum to at most 10,000 bps. A zero `tokenScale` reverts.
    /// @param size Position size in the caller's token precision, conventionally 18 decimals.
    /// @param oraclePrice Liquidation price in the caller's oracle precision, conventionally 8 decimals.
    /// @param reachableCollateralAssets Terminal collateral eligible for settlement.
    /// @param equityAssets Signed position equity before the liquidation charge.
    /// @param maintMarginBps Active maintenance or FAD margin rate in basis points.
    /// @param minBountyAssets Minimum requested total liquidation charge.
    /// @param bountyBps Variable total liquidation-charge rate on notional, in basis points.
    /// @param keeperShareBps Keeper share of the collected charge, in basis points.
    /// @param protocolShareBps Protocol-treasury share of the collected charge, in basis points.
    /// @param tokenScale Divisor converting raw `size * oraclePrice` into 6-decimal settlement token.
    /// @return state Equity, collateral, maintenance requirement, total charge, keeper/protocol allocations, and LP fee.
    function buildLiquidationState(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralAssets,
        int256 equityAssets,
        uint256 maintMarginBps,
        uint256 minBountyAssets,
        uint256 bountyBps,
        uint256 keeperShareBps,
        uint256 protocolShareBps,
        uint256 tokenScale
    ) internal pure returns (LiquidationState memory state) {
        state.reachableCollateralAssets = reachableCollateralAssets;
        state.equityAssets = equityAssets;

        uint256 notionalAssets = (size * oraclePrice) / tokenScale;
        state.maintenanceMarginAssets = (notionalAssets * maintMarginBps) / 10_000;

        uint256 liquidationChargeAssets = (notionalAssets * bountyBps) / 10_000;
        if (liquidationChargeAssets < minBountyAssets) {
            liquidationChargeAssets = minBountyAssets;
        }

        if (liquidationChargeAssets > reachableCollateralAssets) {
            liquidationChargeAssets = reachableCollateralAssets;
        }

        state.liquidationChargeAssets = liquidationChargeAssets;
        state.keeperBountyAssets = Math.mulDiv(liquidationChargeAssets, keeperShareBps, 10_000);
        state.protocolLiquidationFeeAssets = Math.mulDiv(liquidationChargeAssets, protocolShareBps, 10_000);
        state.lpLiquidationFeeAssets =
            liquidationChargeAssets - state.keeperBountyAssets - state.protocolLiquidationFeeAssets;
    }

}

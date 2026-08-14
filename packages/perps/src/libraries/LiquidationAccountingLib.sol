// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEngineSettlementLib} from "@plether/perps/libraries/CfdEngineSettlementLib.sol";

/// @title LiquidationAccountingLib
/// @notice Calculates maintenance requirement, liquidation-charge allocation, and residual settlement for a liquidated position.
/// @dev Monetary fields use 6-decimal USDC, rates use a 10,000 basis-point denominator, and callers supply the scale
///      converting `size * oraclePrice` to USDC. Rate calculations use integer division and round down.
library LiquidationAccountingLib {

    /// @notice Risk and liquidation-charge values for a liquidation candidate.
    /// @param equityUsdc Signed position equity before the liquidation charge; negative values denote a collateral deficit.
    /// @param reachableCollateralUsdc Account collateral eligible for terminal settlement.
    /// @param maintenanceMarginUsdc Maintenance or FAD margin requirement at the supplied price.
    /// @param liquidationChargeUsdc Total charge after applying the minimum and reachable-collateral cap.
    /// @param keeperBountyUsdc Keeper-owned share of the total liquidation charge.
    /// @param protocolLiquidationFeeUsdc Protocol-treasury share of the total liquidation charge.
    /// @param lpLiquidationFeeUsdc LP-owned remainder after keeper and protocol allocations.
    struct LiquidationState {
        int256 equityUsdc;
        uint256 reachableCollateralUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 liquidationChargeUsdc;
        uint256 keeperBountyUsdc;
        uint256 protocolLiquidationFeeUsdc;
        uint256 lpLiquidationFeeUsdc;
    }

    /// @notice Builds liquidation requirements and allocates the collectible charge among keeper, protocol, and LPs.
    /// @dev Notional is `floor(size * oraclePrice / tokenScale)`. The total charge is the greater of the notional-based
    ///      amount and `minBountyUsdc`, then capped to `reachableCollateralUsdc`; therefore a zero-notional position can
    ///      still produce a minimum charge when collateral is reachable. Keeper and protocol allocations each round
    ///      down according to their configured shares; LPs receive the exact remainder. Callers must ensure the two
    ///      configured shares sum to at most 10,000 bps. A zero `tokenScale` reverts.
    /// @param size Position size in the caller's token precision, conventionally 18 decimals.
    /// @param oraclePrice Liquidation price in the caller's oracle precision, conventionally 8 decimals.
    /// @param reachableCollateralUsdc Terminal collateral eligible for settlement.
    /// @param equityUsdc Signed position equity before the liquidation charge.
    /// @param maintMarginBps Active maintenance or FAD margin rate in basis points.
    /// @param minBountyUsdc Minimum requested total liquidation charge.
    /// @param bountyBps Variable total liquidation-charge rate on notional, in basis points.
    /// @param keeperShareBps Keeper share of the collected charge, in basis points.
    /// @param protocolShareBps Protocol-treasury share of the collected charge, in basis points.
    /// @param tokenScale Divisor converting raw `size * oraclePrice` into 6-decimal USDC.
    /// @return state Equity, collateral, maintenance requirement, total charge, keeper/protocol allocations, and LP fee.
    function buildLiquidationState(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralUsdc,
        int256 equityUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 keeperShareBps,
        uint256 protocolShareBps,
        uint256 tokenScale
    ) internal pure returns (LiquidationState memory state) {
        state.reachableCollateralUsdc = reachableCollateralUsdc;
        state.equityUsdc = equityUsdc;

        uint256 notionalUsdc = (size * oraclePrice) / tokenScale;
        state.maintenanceMarginUsdc = (notionalUsdc * maintMarginBps) / 10_000;

        uint256 liquidationChargeUsdc = (notionalUsdc * bountyBps) / 10_000;
        if (liquidationChargeUsdc < minBountyUsdc) {
            liquidationChargeUsdc = minBountyUsdc;
        }

        if (liquidationChargeUsdc > reachableCollateralUsdc) {
            liquidationChargeUsdc = reachableCollateralUsdc;
        }

        state.liquidationChargeUsdc = liquidationChargeUsdc;
        state.keeperBountyUsdc = Math.mulDiv(liquidationChargeUsdc, keeperShareBps, 10_000);
        state.protocolLiquidationFeeUsdc = Math.mulDiv(liquidationChargeUsdc, protocolShareBps, 10_000);
        state.lpLiquidationFeeUsdc =
            liquidationChargeUsdc - state.keeperBountyUsdc - state.protocolLiquidationFeeUsdc;
    }

    /// @notice Converts liquidation equity net of the total charge into seizure, payout, or bad-debt settlement.
    /// @dev Uses all `reachableCollateralUsdc` as the existing account balance for settlement. A nonnegative residual
    ///      targets that remaining balance; a negative residual seizes all reachable collateral and reports its full
    ///      magnitude as bad debt. Equity and the total charge must fit the supported signed range; signed subtraction and
    ///      negating `type(int256).min` otherwise revert or follow explicit fixed-width conversion semantics.
    /// @param state Liquidation equity, reachable collateral, and split liquidation charge.
    /// @return result Target balance, seizure, fresh payout, and bad-debt allocation after subtracting the total charge.
    function settlementForState(
        LiquidationState memory state
    ) internal pure returns (CfdEngineSettlementLib.LiquidationSettlementResult memory result) {
        result = CfdEngineSettlementLib.liquidationSettlementResult(
            state.reachableCollateralUsdc, state.equityUsdc - int256(state.liquidationChargeUsdc)
        );
    }

}

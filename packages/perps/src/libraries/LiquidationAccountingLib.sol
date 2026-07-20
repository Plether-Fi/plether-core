// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEngineSettlementLib} from "@plether/perps/libraries/CfdEngineSettlementLib.sol";

/// @title LiquidationAccountingLib
/// @notice Calculates maintenance requirement, keeper bounty, and residual settlement for a liquidated position.
/// @dev Monetary fields use 6-decimal USDC, rates use a 10,000 basis-point denominator, and callers supply the scale
///      converting `size * oraclePrice` to USDC. Rate calculations use integer division and round down.
library LiquidationAccountingLib {

    /// @notice Risk and bounty values for a liquidation candidate.
    /// @param equityUsdc Signed position equity before the keeper bounty; negative values denote a collateral deficit.
    /// @param reachableCollateralUsdc Account collateral eligible for terminal settlement.
    /// @param maintenanceMarginUsdc Maintenance or FAD margin requirement at the supplied price.
    /// @param keeperBountyUsdc Keeper bounty after applying the minimum and reachable-collateral cap.
    struct LiquidationState {
        int256 equityUsdc;
        uint256 reachableCollateralUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 keeperBountyUsdc;
    }

    /// @notice Builds liquidation requirements and the collectible keeper bounty.
    /// @dev Notional is `floor(size * oraclePrice / tokenScale)`. The bounty is the greater of the notional-based
    ///      amount and `minBountyUsdc`, then capped to `reachableCollateralUsdc`; therefore a zero-notional position can
    ///      still produce a minimum bounty when collateral is reachable. A zero `tokenScale` reverts.
    /// @param size Position size in the caller's token precision, conventionally 18 decimals.
    /// @param oraclePrice Liquidation price in the caller's oracle precision, conventionally 8 decimals.
    /// @param reachableCollateralUsdc Terminal collateral eligible for settlement.
    /// @param equityUsdc Signed position equity before bounty.
    /// @param maintMarginBps Active maintenance or FAD margin rate in basis points.
    /// @param minBountyUsdc Minimum requested keeper bounty.
    /// @param bountyBps Variable keeper-bounty rate on notional, in basis points.
    /// @param tokenScale Divisor converting raw `size * oraclePrice` into 6-decimal USDC.
    /// @return state Equity, collateral, maintenance requirement, and capped keeper bounty.
    function buildLiquidationState(
        uint256 size,
        uint256 oraclePrice,
        uint256 reachableCollateralUsdc,
        int256 equityUsdc,
        uint256 maintMarginBps,
        uint256 minBountyUsdc,
        uint256 bountyBps,
        uint256 tokenScale
    ) internal pure returns (LiquidationState memory state) {
        state.reachableCollateralUsdc = reachableCollateralUsdc;
        state.equityUsdc = equityUsdc;

        uint256 notionalUsdc = (size * oraclePrice) / tokenScale;
        state.maintenanceMarginUsdc = (notionalUsdc * maintMarginBps) / 10_000;

        uint256 bounty = (notionalUsdc * bountyBps) / 10_000;
        if (bounty < minBountyUsdc) {
            bounty = minBountyUsdc;
        }

        if (bounty > reachableCollateralUsdc) {
            bounty = reachableCollateralUsdc;
        }

        state.keeperBountyUsdc = bounty;
    }

    /// @notice Converts liquidation equity net of keeper bounty into seizure, payout, or bad-debt settlement.
    /// @dev Uses all `reachableCollateralUsdc` as the existing account balance for settlement. A nonnegative residual
    ///      targets that remaining balance; a negative residual seizes all reachable collateral and reports its full
    ///      magnitude as bad debt. Equity and bounty must fit the supported signed range; signed subtraction and
    ///      negating `type(int256).min` otherwise revert or follow explicit fixed-width conversion semantics.
    /// @param state Liquidation equity, reachable collateral, and keeper bounty.
    /// @return result Target balance, seizure, fresh payout, and bad-debt allocation after subtracting the bounty.
    function settlementForState(
        LiquidationState memory state
    ) internal pure returns (CfdEngineSettlementLib.LiquidationSettlementResult memory result) {
        result = CfdEngineSettlementLib.liquidationSettlementResult(
            state.reachableCollateralUsdc, state.equityUsdc - int256(state.keeperBountyUsdc)
        );
    }

}

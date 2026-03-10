// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

interface ICfdEngine {

    /// @notice Settles funding and processes an open/close order at the given oracle price
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (int256 settlementUsdc);

    /// @notice Liquidates an undercollateralized position, returns keeper bounty in USDC
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Worst-case payout for all BULL positions (6 decimals)
    function globalBullMaxProfit() external view returns (uint256);
    /// @notice Worst-case payout for all BEAR positions (6 decimals)
    function globalBearMaxProfit() external view returns (uint256);
    /// @notice Accumulated execution fees awaiting withdrawal (6 decimals)
    function accumulatedFeesUsdc() external view returns (uint256);

    /// @notice Aggregate unrealized PnL of all open positions at lastMarkPrice.
    ///         Positive = traders winning (house liability). Negative = traders losing (house asset).
    function getUnrealizedTraderPnl() external view returns (int256);

    /// @notice Aggregate unrealized funding PnL across all open positions.
    ///         Positive = traders are net funding receivers (vault liability).
    function getUnrealizedFundingPnl() external view returns (int256);

    /// @notice Combined MtM: per-side (PnL + funding), capped at deposited margin.
    ///         Positive = vault owes traders (liability). Negative = traders owe vault (capped asset).
    function getVaultMtmAdjustment() external view returns (int256);

    /// @notice Timestamp of the last mark price update
    function lastMarkTime() external view returns (uint64);

    /// @notice Push a fresh mark price without processing an order
    function updateMarkPrice(
        uint256 price
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    function CAP_PRICE() external view returns (uint256);

    /// @notice True during weekend FX closure or admin-configured FAD days
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed during FAD windows
    function fadMaxStaleness() external view returns (uint256);

    /// @notice Whether a given day number is an admin-configured FAD override
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

}

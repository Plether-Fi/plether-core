// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stateful CFD trading engine: processes orders, settles funding, and liquidates positions.
interface ICfdEngine {

    struct LiquidationPreview {
        bool liquidatable;
        uint256 oraclePrice;
        int256 equityUsdc;
        int256 pnlUsdc;
        int256 fundingUsdc;
        uint256 reachableCollateralUsdc;
        uint256 keeperBountyUsdc;
        uint256 seizedCollateralUsdc;
        uint256 immediatePayoutUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
    }

    /// @notice Margin clearinghouse address used for account margin locking/unlocking
    function clearinghouse() external view returns (address);

    /// @notice Settlement token used for fees, margin, and payouts
    function USDC() external view returns (IERC20);

    /// @notice Last mark price observed by the engine (8 decimals)
    function lastMarkPrice() external view returns (uint256);

    /// @notice Settles funding and processes an open/close order at the given oracle price
    /// @param order              Order to execute (contains accountId, market, direction, size)
    /// @param currentOraclePrice Mark price from the oracle (8 decimals)
    /// @param vaultDepthUsdc     Available vault liquidity, used for open-interest caps (6 decimals)
    /// @param publishTime        Oracle publish timestamp, used for funding rate accrual
    function processOrder(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external;

    /// @notice Records a deferred liquidation bounty when immediate vault payment is unavailable.
    function recordDeferredLiquidationBounty(
        address keeper,
        uint256 amountUsdc
    ) external;

    /// @notice Liquidates an undercollateralized position, returns keeper bounty in USDC
    /// @param accountId          Account holding the position to liquidate
    /// @param currentOraclePrice Mark price from the oracle (8 decimals)
    /// @param vaultDepthUsdc     Available vault liquidity (6 decimals)
    /// @param publishTime        Oracle publish timestamp
    /// @return keeperBountyUsdc  Bounty paid to the liquidation keeper (6 decimals)
    function liquidatePosition(
        bytes32 accountId,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime,
        uint256 pendingVaultPayoutUsdc
    ) external returns (uint256 keeperBountyUsdc);

    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Worst-case payout for all BULL positions (6 decimals)
    function globalBullMaxProfit() external view returns (uint256);
    /// @notice Worst-case payout for all BEAR positions (6 decimals)
    function globalBearMaxProfit() external view returns (uint256);
    /// @notice Worst-case directional liability after taking the max of bull/bear payout bounds.
    function getMaxLiability() external view returns (uint256);
    /// @notice Accumulated execution fees awaiting withdrawal (6 decimals)
    function accumulatedFeesUsdc() external view returns (uint256);
    /// @notice Total withdrawal reserve required by current protocol liabilities.
    function getWithdrawalReservedUsdc() external view returns (uint256);

    /// @notice Deferred profitable-close payouts still owed to traders.
    function totalDeferredPayoutUsdc() external view returns (uint256);

    /// @notice Deferred liquidation bounties still owed after failed immediate payout.
    function totalDeferredLiquidationBountyUsdc() external view returns (uint256);

    /// @notice Aggregate unrealized PnL of all open positions at lastMarkPrice.
    ///         Positive = traders winning (house liability). Negative = traders losing (house asset).
    function getUnrealizedTraderPnl() external view returns (int256);

    /// @notice Aggregate unrealized funding PnL across all open positions.
    ///         Positive = traders are net funding receivers (vault liability).
    function getUnrealizedFundingPnl() external view returns (int256);

    /// @notice Aggregate unrealized funding PnL with negative per-side funding capped by backing margin.
    ///         Positive = traders are net funding receivers after clipping uncollectible debts.
    function getCappedFundingPnl() external view returns (int256);

    /// @notice Aggregate funding liabilities only, excluding any trader debts owed to the vault.
    ///         Used by withdrawal firewalls that must assume funding receivables are uncollectible
    ///         until physically seized.
    function getLiabilityOnlyFundingPnl() external view returns (int256);

    /// @notice Combined MtM liability: per-side (PnL + funding), clamped at zero.
    ///         Positive = vault owes traders (unrealized liability). Zero = traders losing or neutral.
    ///         Unrealized trader losses are not counted as vault assets.
    function getVaultMtmAdjustment() external view returns (int256);

    /// @notice Timestamp of the last mark price update
    function lastMarkTime() external view returns (uint64);

    /// @notice Returns true when the engine currently has open bounded liability that depends on mark freshness.
    function hasLiveLiability() external view returns (bool);

    /// @notice Push a fresh mark price without processing an order
    /// @param price       New mark price (8 decimals)
    /// @param publishTime Oracle publish timestamp for the price update
    function updateMarkPrice(
        uint256 price,
        uint64 publishTime
    ) external;

    /// @notice Protocol cap price (8 decimals). Oracle prices are clamped to this.
    function CAP_PRICE() external view returns (uint256);

    /// @notice True during weekend FX closure or admin-configured FAD days
    function isFadWindow() external view returns (bool);

    /// @notice Maximum oracle staleness allowed during FAD windows
    function fadMaxStaleness() external view returns (uint256);

    /// @notice True only when FX markets are actually closed and oracle freshness can be relaxed.
    function isOracleFrozen() external view returns (bool);

    /// @notice Returns true when the account currently has an open position.
    function hasOpenPosition(
        bytes32 accountId
    ) external view returns (bool);

    /// @notice Returns the current position size for an account (18 decimals).
    function getPositionSize(
        bytes32 accountId
    ) external view returns (uint256);

    /// @notice Returns the stored side for an open position.
    function getPositionSide(
        bytes32 accountId
    ) external view returns (CfdTypes.Side);

    /// @notice True when the engine has latched degraded mode after a close revealed insolvency.
    function degradedMode() external view returns (bool);

    /// @notice Whether a given day number is an admin-configured FAD override
    function fadDayOverrides(
        uint256 dayNumber
    ) external view returns (bool);

}

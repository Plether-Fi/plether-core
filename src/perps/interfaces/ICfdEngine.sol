// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";
import {CfdTypes} from "../CfdTypes.sol";
import {DeferredEngineViewTypes} from "./DeferredEngineViewTypes.sol";
import {EngineStatusViewTypes} from "./EngineStatusViewTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stateful CFD trading engine: processes orders and liquidates positions.
/// @dev This remains a rich internal/admin integration interface.
///      Product-facing consumers should prefer the slim public surfaces in
///      `IPerpsTraderActions`, `IPerpsTraderViews`, `IPerpsLPActions`, `IPerpsLPViews`,
///      `IPerpsKeeper`, `IProtocolViews`, and `IMarginAccount`.
///      Live protocol contracts should prefer smaller role-specific interfaces like `ICfdEngineCore`.
interface ICfdEngine {

    error CfdEngine__TypedOrderFailure(
        CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose
    );
    error CfdEngine__MarkPriceOutOfOrder();

    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
        int256 fundingIndex;
        int256 entryFunding;
    }

    struct LiquidationPreview {
        bool liquidatable;
        uint256 oraclePrice;
        int256 equityUsdc;
        int256 pnlUsdc;
        int256 fundingUsdc;
        uint256 reachableCollateralUsdc;
        uint256 keeperBountyUsdc;
        uint256 seizedCollateralUsdc;
        uint256 settlementRetainedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredPayoutUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        int256 solvencyFundingPnlUsdc;
    }

    /// @notice Margin clearinghouse address used for account margin locking/unlocking
    function clearinghouse() external view returns (address);

    /// @notice Current order router allowed to execute orders through the engine.
    function orderRouter() external view returns (address);

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

    /// @notice Router-facing order execution entrypoint with typed business-rule failures.
    /// @dev Reverts with `CfdEngine__TypedOrderFailure` for expected order invalidations so the
    ///      router can apply deterministic failed-order bounty policy without selector matching.
    function processOrderTyped(
        CfdTypes.Order memory order,
        uint256 currentOraclePrice,
        uint256 vaultDepthUsdc,
        uint64 publishTime
    ) external;

    /// @notice Returns the current open-path revert code using canonical vault depth and a caller-supplied oracle snapshot.
    function previewOpenRevertCode(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code);

    /// @notice Returns the semantic commit-time policy category for the current open-path invalidation, if any.
    function previewOpenFailurePolicyCategory(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category);

    /// @notice Records a deferred clearer bounty when immediate vault payment is unavailable.
    /// @dev Deferred keeper bounties are later claimed as clearinghouse credit, not direct wallet transfer.
    function recordDeferredClearerBounty(
        address keeper,
        uint256 amountUsdc
    ) external;

    function getDeferredClaimHead() external view returns (DeferredEngineViewTypes.DeferredClaim memory claim);

    /// @notice Reserves close-order execution bounty from free settlement first, then active position margin.
    function reserveCloseOrderExecutionBounty(
        bytes32 accountId,
        uint256 amountUsdc,
        address recipient
    ) external;

    /// @notice Pulls router-custodied cancellation fees into protocol revenue.
    function absorbRouterCancellationFee(
        uint256 amountUsdc
    ) external;

    /// @notice Books router-delivered protocol-owned inflow as accumulated fees after the router has already paid the vault.
    function recordRouterProtocolFee(
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
        uint64 publishTime
    ) external returns (uint256 keeperBountyUsdc);

    /// @notice Canonical liquidation preview using the vault's current accounted depth.
    function previewLiquidation(
        bytes32 accountId,
        uint256 oraclePrice
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Hypothetical liquidation simulation at a caller-supplied vault depth.
    function simulateLiquidation(
        bytes32 accountId,
        uint256 oraclePrice,
        uint256 vaultDepthUsdc
    ) external view returns (LiquidationPreview memory preview);

    /// @notice Returns the accounting state for a given side.
    function getSideState(
        CfdTypes.Side side
    ) external view returns (SideState memory);

    /// @notice Worst-case directional liability after taking the max of bull/bear payout bounds.
    function getMaxLiability() external view returns (uint256);
    /// @notice Accumulated execution fees awaiting withdrawal (6 decimals)
    function accumulatedFeesUsdc() external view returns (uint256);
    /// @notice Total withdrawal reserve required by current protocol liabilities.
    function getWithdrawalReservedUsdc() external view returns (uint256);

    /// @notice Deferred profitable-close payouts still owed to traders.
    function totalDeferredPayoutUsdc() external view returns (uint256);

    /// @notice Deferred liquidation bounties still owed after failed immediate payout.
    function totalDeferredClearerBountyUsdc() external view returns (uint256);

    function deferredClaimHeadId() external view returns (uint64);

    /// @notice Aggregate unrealized PnL of all open positions at lastMarkPrice.
    ///         Positive = traders winning (house liability). Negative = traders losing (house asset).
    function getUnrealizedTraderPnl() external view returns (int256);

    /// @notice Timestamp of the last mark price update
    function lastMarkTime() external view returns (uint64);

    /// @notice Returns true when the engine currently has open bounded liability that depends on mark freshness.
    function hasLiveLiability() external view returns (bool);

    /// @notice Materializes accrued funding into storage so subsequent reads reflect current state.
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

    /// @notice High-level protocol lifecycle used by external status consumers.
    ///         `Active` means the engine is wired and the vault has enabled live risk-taking.
    enum ProtocolPhase {
        Configuring,
        Active,
        Degraded
    }

    function getProtocolPhase() external view returns (ProtocolPhase);

    function getProtocolStatus() external view returns (EngineStatusViewTypes.ProtocolStatus memory);

}

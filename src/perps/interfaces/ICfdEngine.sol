// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stateful CFD trading engine: processes orders, settles funding, and liquidates positions.
interface ICfdEngine {

    enum OrderExecutionFailureClass {
        UserOrderInvalid,
        ProtocolStateInvalidated
    }

    error CfdEngine__TypedOrderFailure(OrderExecutionFailureClass failureClass, uint8 failureCode, bool isClose);

    /// @notice Compact per-account ledger view spanning trader-owned settlement buckets and router-reserved order state.
    /// @dev `settlementBalanceUsdc`, `freeSettlementUsdc`, `activePositionMarginUsdc`, `otherLockedMarginUsdc`, and
    ///      `deferredPayoutUsdc` are trader-owned value or obligations recorded by the protocol.
    ///      `executionEscrowUsdc` is router-custodied order bounty escrow attributed to the account.
    ///      `committedMarginUsdc` remains trader-owned settlement reserved for queued orders inside the clearinghouse.
    struct AccountLedgerView {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 executionEscrowUsdc;
        uint256 committedMarginUsdc;
        uint256 deferredPayoutUsdc;
        uint256 pendingOrderCount;
    }

    /// @notice Expanded per-account ledger snapshot for debugging account health, reachability, and queued-order state.
    /// @dev Extends `AccountLedgerView` with typed clearinghouse locked-margin buckets, terminal settlement reachability,
    ///      equity, buying power, and live position risk.
    struct AccountLedgerSnapshot {
        uint256 settlementBalanceUsdc;
        uint256 freeSettlementUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 positionMarginBucketUsdc;
        uint256 committedOrderMarginBucketUsdc;
        uint256 reservedSettlementBucketUsdc;
        uint256 executionEscrowUsdc;
        uint256 committedMarginUsdc;
        uint256 deferredPayoutUsdc;
        uint256 pendingOrderCount;
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        bool hasPosition;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        int256 unrealizedPnlUsdc;
        int256 pendingFundingUsdc;
        int256 netEquityUsdc;
        bool liquidatable;
    }

    struct ProtocolAccountingSnapshot {
        uint256 vaultAssetsUsdc;
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 effectiveSolvencyAssetsUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 accumulatedFeesUsdc;
        uint256 accumulatedBadDebtUsdc;
        int256 cappedFundingPnlUsdc;
        uint256 liabilityOnlyFundingPnlUsdc;
        uint256 totalDeferredPayoutUsdc;
        uint256 totalDeferredClearerBountyUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    struct HousePoolInputSnapshot {
        uint256 netPhysicalAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 withdrawalFundingLiabilityUsdc;
        uint256 unrealizedMtmLiabilityUsdc;
        uint256 deferredTraderPayoutUsdc;
        uint256 deferredClearerBountyUsdc;
        uint256 protocolFeesUsdc;
        bool markFreshnessRequired;
        uint256 maxMarkStaleness;
    }

    struct HousePoolStatusSnapshot {
        uint64 lastMarkTime;
        bool oracleFrozen;
        bool degradedMode;
    }

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

    /// @notice Records a deferred clearer bounty when immediate vault payment is unavailable.
    function recordDeferredClearerBounty(
        address keeper,
        uint256 amountUsdc
    ) external;

    /// @notice Pulls router-custodied cancellation fees into protocol revenue.
    function absorbRouterCancellationFee(
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

    function previewLiquidation(
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
    /// @notice Compact per-account ledger view spanning clearinghouse, router escrow, and deferred trader payout state.
    function getAccountLedgerView(
        bytes32 accountId
    ) external view returns (AccountLedgerView memory viewData);
    /// @notice Expanded per-account ledger snapshot for debugging account health and settlement reachability across protocol components.
    function getAccountLedgerSnapshot(
        bytes32 accountId
    ) external view returns (AccountLedgerSnapshot memory snapshot);
    /// @notice Canonical protocol-wide accounting snapshot across physical assets, liabilities, fees, bad debt, and deferred obligations.
    function getProtocolAccountingSnapshot() external view returns (ProtocolAccountingSnapshot memory snapshot);
    /// @notice Accumulated execution fees awaiting withdrawal (6 decimals)
    function accumulatedFeesUsdc() external view returns (uint256);
    /// @notice Total withdrawal reserve required by current protocol liabilities.
    function getWithdrawalReservedUsdc() external view returns (uint256);

    /// @notice Canonical accounting snapshot consumed by HousePool.
    /// @param markStalenessLimit Normal live-market staleness limit configured by HousePool.
    function getHousePoolInputSnapshot(
        uint256 markStalenessLimit
    ) external view returns (HousePoolInputSnapshot memory snapshot);

    /// @notice Canonical non-accounting market/status snapshot consumed by HousePool.
    function getHousePoolStatusSnapshot() external view returns (HousePoolStatusSnapshot memory snapshot);

    /// @notice Deferred profitable-close payouts still owed to traders.
    function totalDeferredPayoutUsdc() external view returns (uint256);

    /// @notice Deferred liquidation bounties still owed after failed immediate payout.
    function totalDeferredClearerBountyUsdc() external view returns (uint256);

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
    function getLiabilityOnlyFundingPnl() external view returns (uint256);

    /// @notice Combined MtM liability: per-side (PnL + funding), clamped at zero.
    ///         Positive = vault owes traders (unrealized liability). Zero = traders losing or neutral.
    ///         Unrealized trader losses are not counted as vault assets.
    function getVaultMtmAdjustment() external view returns (uint256);

    /// @notice Timestamp of the last mark price update
    function lastMarkTime() external view returns (uint64);

    /// @notice Returns true when the engine currently has open bounded liability that depends on mark freshness.
    function hasLiveLiability() external view returns (bool);

    /// @notice Materializes accrued funding into storage so subsequent reads reflect current state.
    function syncFunding() external;

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

    enum ProtocolPhase {
        Configuring,
        Active,
        Degraded
    }

    struct ProtocolStatus {
        ProtocolPhase phase;
        uint64 lastMarkTime;
        uint256 lastMarkPrice;
        bool oracleFrozen;
        bool fadWindow;
        uint256 fadMaxStaleness;
    }

    function getProtocolPhase() external view returns (ProtocolPhase);

    function getProtocolStatus() external view returns (ProtocolStatus memory);

}

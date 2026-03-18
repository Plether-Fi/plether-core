// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "./CfdTypes.sol";
import {IMarginClearinghouse} from "./interfaces/IMarginClearinghouse.sol";
import {CfdEngineSettlementLib} from "./libraries/CfdEngineSettlementLib.sol";
import {CloseAccountingLib} from "./libraries/CloseAccountingLib.sol";
import {LiquidationAccountingLib} from "./libraries/LiquidationAccountingLib.sol";
import {MarginClearinghouseAccountingLib} from "./libraries/MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "./libraries/OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "./libraries/PositionRiskAccountingLib.sol";

/// @title CfdEnginePlanTypes
/// @notice Snapshot and delta structs for the plan→apply architecture.
///         Plan functions are pure over a RawSnapshot and return typed deltas.
///         Apply functions consume deltas to perform state mutations and external calls.
library CfdEnginePlanTypes {

    // ──────────────────────────────────────────────
    //  SNAPSHOT (input to all plan functions)
    // ──────────────────────────────────────────────

    struct SideSnapshot {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
        int256 fundingIndex;
        int256 entryFunding;
    }

    struct RawSnapshot {
        CfdTypes.Position position;
        bytes32 accountId;

        uint256 currentTimestamp;
        uint64 lastFundingTime;
        uint256 lastMarkPrice;
        uint64 lastMarkTime;

        SideSnapshot bullSide;
        SideSnapshot bearSide;

        uint256 vaultAssetsUsdc;
        uint256 vaultCashUsdc;

        IMarginClearinghouse.AccountUsdcBuckets accountBuckets;
        IMarginClearinghouse.LockedMarginBuckets lockedBuckets;

        uint64[] marginReservationIds;

        uint256 accumulatedFeesUsdc;
        uint256 accumulatedBadDebtUsdc;
        uint256 totalDeferredPayoutUsdc;
        uint256 totalDeferredClearerBountyUsdc;
        uint256 deferredPayoutForAccount;
        bool degradedMode;

        uint256 capPrice;
        CfdTypes.RiskParams riskParams;
        bool isFadWindow;
    }

    // ──────────────────────────────────────────────
    //  FUNDING DELTA (shared sub-delta)
    // ──────────────────────────────────────────────

    enum FundingPayoutType {
        NONE,
        MARGIN_CREDIT,
        CLOSE_SETTLEMENT,
        DEFERRED_PAYOUT,
        LOSS_CONSUMED,
        LOSS_UNCOVERED_REVERT,
        LOSS_UNCOVERED_CLOSE
    }

    struct FundingDelta {
        int256 bullFundingIndexDelta;
        int256 bearFundingIndexDelta;
        uint256 fundingAbsSkewUsdc;
        uint64 newLastFundingTime;

        uint256 newLastMarkPrice;
        uint64 newLastMarkTime;

        int256 pendingFundingUsdc;
        int256 closeFundingSettlementUsdc;
        FundingPayoutType payoutType;

        uint256 fundingVaultPayoutUsdc;
        uint256 fundingClearinghouseCreditUsdc;

        uint256 fundingLossConsumedFromMargin;
        uint256 fundingLossConsumedFromFree;
        uint256 fundingLossUncovered;

        uint256 posMarginIncrease;
        uint256 posMarginDecrease;

        int256 sideEntryFundingDelta;
        int256 newPosEntryFundingIndex;
    }

    // ──────────────────────────────────────────────
    //  OPEN DELTA
    // ──────────────────────────────────────────────

    enum OpenRevertCode {
        OK,
        MUST_CLOSE_OPPOSING,
        DEGRADED_MODE,
        POSITION_TOO_SMALL,
        SKEW_TOO_HIGH,
        MARGIN_DRAINED_BY_FEES,
        INSUFFICIENT_INITIAL_MARGIN,
        SOLVENCY_EXCEEDED,
        FUNDING_EXCEEDS_MARGIN
    }

    struct OpenDelta {
        bool valid;
        OpenRevertCode revertCode;

        FundingDelta funding;
        OpenAccountingLib.OpenState openState;

        CfdTypes.Side posSide;
        uint256 newPosSize;
        uint256 newPosEntryPrice;
        int256 posVpiAccruedDelta;
        uint256 posMaxProfitIncrease;
        uint256 posMarginAfter;

        uint256 sideOiIncrease;
        int256 sideEntryNotionalDelta;
        int256 sideEntryFundingContribution;
        uint256 sideMaxProfitIncrease;

        int256 tradeCostUsdc;
        uint256 marginDeltaUsdc;
        int256 netMarginChange;
        uint256 vaultRebatePayoutUsdc;

        uint256 executionFeeUsdc;

        uint256 totalMarginBefore;
        uint256 totalMarginAfterFunding;
        uint256 totalMarginAfterOpen;

        bytes32 accountId;
        uint256 sizeDelta;
        uint256 price;
    }

    // ──────────────────────────────────────────────
    //  CLOSE DELTA
    // ──────────────────────────────────────────────

    enum CloseRevertCode {
        OK,
        CLOSE_SIZE_EXCEEDS,
        DUST_POSITION,
        PARTIAL_CLOSE_UNDERWATER,
        FUNDING_PARTIAL_CLOSE_UNDERWATER
    }

    enum SettlementType {
        ZERO,
        GAIN,
        LOSS
    }

    struct CloseDelta {
        bool valid;
        CloseRevertCode revertCode;

        FundingDelta funding;
        CloseAccountingLib.CloseState closeState;
        uint256 postBullOi;
        uint256 postBearOi;

        uint256 posMarginAfter;
        uint256 posSizeDelta;
        uint256 posMaxProfitReduction;
        int256 posVpiAccruedReduction;
        bool deletePosition;

        CfdTypes.Side side;
        uint256 sideOiDecrease;
        uint256 sideEntryNotionalReduction;
        int256 sideEntryFundingReduction;
        uint256 sideMaxProfitReduction;

        uint256 unlockMarginUsdc;

        SettlementType settlementType;

        uint256 traderPayoutUsdc;
        bool payoutIsImmediate;
        bool payoutIsDeferred;

        CfdEngineSettlementLib.CloseSettlementResult lossResult;
        MarginClearinghouseAccountingLib.SettlementConsumption lossConsumption;
        uint256 syncMarginQueueAmount;

        uint256 executionFeeUsdc;
        uint256 badDebtUsdc;

        uint256 totalMarginBefore;
        uint256 totalMarginAfterFunding;
        uint256 totalMarginAfterClose;

        bool triggersDegradedMode;

        bytes32 accountId;
        uint256 sizeDelta;
        uint256 price;
        int256 realizedPnlUsdc;
    }

    // ──────────────────────────────────────────────
    //  LIQUIDATION DELTA
    // ──────────────────────────────────────────────

    struct LiquidationDelta {
        bool liquidatable;

        FundingDelta funding;

        PositionRiskAccountingLib.PositionRiskState riskState;
        LiquidationAccountingLib.LiquidationState liquidationState;

        CfdTypes.Side side;
        uint256 posSize;
        uint256 posMargin;
        uint256 posMaxProfit;
        uint256 posEntryPrice;
        int256 posEntryFundingIndex;

        uint256 sideOiDecrease;
        uint256 sideMaxProfitDecrease;
        uint256 sideEntryNotionalReduction;
        int256 sideEntryFundingReduction;
        uint256 sideTotalMarginReduction;

        uint256 keeperBountyUsdc;

        int256 residualUsdc;
        MarginClearinghouseAccountingLib.LiquidationResidualPlan residualPlan;

        uint256 traderPayoutUsdc;
        bool payoutIsImmediate;
        bool payoutIsDeferred;

        uint256 syncMarginQueueAmount;

        uint256 badDebtUsdc;

        bool triggersDegradedMode;

        bytes32 accountId;
        uint256 price;
    }

    // ──────────────────────────────────────────────
    //  OPEN PREVIEW (new — did not exist before)
    // ──────────────────────────────────────────────

    struct OpenPreview {
        bool valid;
        uint8 invalidCode;
        uint256 executionPrice;
        uint256 sizeDelta;
        int256 fundingUsdc;
        int256 vpiUsdc;
        uint256 executionFeeUsdc;
        int256 tradeCostUsdc;
        uint256 newSize;
        uint256 newEntryPrice;
        uint256 marginAfter;
        uint256 addedMaxProfitUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

}

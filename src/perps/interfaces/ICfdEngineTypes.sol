// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../CfdTypes.sol";

/// @notice Shared CfdEngine structs and custom errors.
interface ICfdEngineTypes {

    error CfdEngine__Unauthorized();
    error CfdEngine__VaultAlreadySet();
    error CfdEngine__RouterAlreadySet();
    error CfdEngine__DependenciesAlreadySet();
    error CfdEngine__NoFeesToWithdraw();
    error CfdEngine__NoDeferredTraderCredit();
    error CfdEngine__InsufficientVaultLiquidity();
    error CfdEngine__NoDeferredKeeperCredit();
    error CfdEngine__MustCloseOpposingPosition();
    error CfdEngine__CarryExceedsMargin();
    error CfdEngine__VaultSolvencyExceeded();
    error CfdEngine__MarginDrainedByFees();
    error CfdEngine__CloseSizeExceedsPosition();
    error CfdEngine__NoPositionToLiquidate();
    error CfdEngine__PositionIsSolvent();
    error CfdEngine__PostOpSolvencyBreach();
    error CfdEngine__InsufficientInitialMargin();
    error CfdEngine__PositionTooSmall();
    error CfdEngine__WithdrawBlockedByOpenPosition();
    error CfdEngine__EmptyDays();
    error CfdEngine__ZeroStaleness();
    error CfdEngine__ZeroAmount();
    error CfdEngine__RunwayTooLong();
    error CfdEngine__PartialCloseUnderwaterCarry();
    error CfdEngine__DustPosition();
    error CfdEngine__MarkPriceStale();
    error CfdEngine__MarkPriceOutOfOrder();
    error CfdEngine__NotClearinghouse();
    error CfdEngine__NotAccountOwner();
    error CfdEngine__NoOpenPosition();
    error CfdEngine__BadDebtTooLarge();
    error CfdEngine__InvalidRiskParams();
    error CfdEngine__SkewTooHigh();
    error CfdEngine__DegradedMode();
    error CfdEngine__NotDegraded();
    error CfdEngine__StillInsolvent();
    error CfdEngine__ZeroAddress();
    error CfdEngine__InsufficientCloseOrderBountyBacking();

    struct AccountCollateralView {
        uint256 settlementBalanceUsdc;
        uint256 lockedMarginUsdc;
        uint256 activePositionMarginUsdc;
        uint256 otherLockedMarginUsdc;
        uint256 freeSettlementUsdc;
        uint256 closeReachableUsdc;
        uint256 terminalReachableUsdc;
        uint256 accountEquityUsdc;
        uint256 freeBuyingPowerUsdc;
        uint256 deferredTraderCreditUsdc;
    }

    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 entryNotionalUsdc;
        uint256 physicalReachableCollateralUsdc;
        uint256 nettableDeferredTraderCreditUsdc;
        int256 unrealizedPnlUsdc;
        int256 netEquityUsdc;
        uint256 maxProfitUsdc;
        bool liquidatable;
    }

    struct ProtocolAccountingView {
        uint256 vaultAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 accumulatedFeesUsdc;
        uint256 totalDeferredTraderCreditUsdc;
        uint256 totalDeferredKeeperCreditUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    struct ClosePreview {
        bool valid;
        CfdTypes.CloseInvalidReason invalidReason;
        uint256 executionPrice;
        uint256 sizeDelta;
        int256 realizedPnlUsdc;
        int256 vpiDeltaUsdc;
        uint256 vpiUsdc;
        uint256 executionFeeUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 seizedCollateralUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct LiquidationPreview {
        bool liquidatable;
        uint256 oraclePrice;
        int256 equityUsdc;
        int256 pnlUsdc;
        uint256 reachableCollateralUsdc;
        uint256 keeperBountyUsdc;
        uint256 seizedCollateralUsdc;
        uint256 settlementRetainedUsdc;
        uint256 freshTraderPayoutUsdc;
        uint256 existingDeferredConsumedUsdc;
        uint256 existingDeferredRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 deferredTraderCreditUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    struct DeferredCreditStatus {
        uint256 deferredTraderCreditUsdc;
        bool traderPayoutClaimableNow;
        uint256 deferredKeeperCreditUsdc;
        bool keeperCreditClaimableNow;
    }

    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
    }

    struct StoredPosition {
        uint256 size;
        uint256 entryPrice;
        uint256 maxProfitUsdc;
        CfdTypes.Side side;
        uint64 lastUpdateTime;
        uint64 lastCarryTimestamp;
        int256 vpiAccrued;
    }

}

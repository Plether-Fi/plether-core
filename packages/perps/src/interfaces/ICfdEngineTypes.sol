// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice Shared CfdEngine errors, events, and ABI view types.
/// @dev Unless a field says otherwise, USDC amounts use 6 decimals, prices use 8 decimals, position sizes use
///      18 decimals, basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
interface ICfdEngineTypes {

    /// @notice The caller is not the configured router, settlement sidecar, or timelocked admin required by the call.
    error CfdEngine__Unauthorized();
    /// @notice The owner attempted to replace the one-time-configured HousePool.
    error CfdEngine__PoolAlreadySet();
    /// @notice The owner attempted to replace the one-time-configured order router.
    error CfdEngine__RouterAlreadySet();
    /// @notice At least one planner, settlement-sidecar, or admin dependency was already configured.
    error CfdEngine__DependenciesAlreadySet();
    /// @notice The proposed settlement sidecar has no code, cannot report its engine, or is bound to another engine.
    error CfdEngine__InvalidSettlementSidecar();
    /// @notice The proposed timelocked admin is not bound to this engine.
    error CfdEngine__InvalidAdmin();
    /// @notice The current protocol-treasury account still has a clearinghouse balance and therefore cannot be replaced.
    error CfdEngine__ProtocolTreasuryBalanceNotEmpty();
    /// @notice The account attempted to settle a zero trader-claim balance.
    error CfdEngine__NoTraderClaim();
    /// @notice HousePool cash cannot presently service the selected trader claim under aggregate claim priority.
    error CfdEngine__InsufficientPoolLiquidity();
    /// @notice Legacy selector for an open/increase opposing an existing position; current planning uses typed failure.
    error CfdEngine__MustCloseOpposingPosition();
    /// @notice Legacy selector for carry exceeding reachable collateral; current planning uses typed failure.
    error CfdEngine__CarryExceedsMargin();
    /// @notice Legacy selector for a planned HousePool solvency breach; current planning uses typed failure.
    error CfdEngine__PoolSolvencyExceeded();
    /// @notice Legacy selector for fees draining open margin; current planning uses typed failure.
    error CfdEngine__MarginDrainedByFees();
    /// @notice Legacy selector for an oversized close; current planning uses typed failure.
    error CfdEngine__CloseSizeExceedsPosition();
    /// @notice Liquidation was requested for an account without an open position.
    error CfdEngine__NoPositionToLiquidate();
    /// @notice Liquidation was requested for a position that satisfies the active maintenance requirement.
    error CfdEngine__PositionIsSolvent();
    /// @notice A planned terminal operation would leave effective pool assets below maximum position liability.
    error CfdEngine__PostOpSolvencyBreach();
    /// @notice Legacy selector for insufficient initial margin; current planning uses typed failure.
    error CfdEngine__InsufficientInitialMargin();
    /// @notice A position or requested change is below the protocol's minimum economic size.
    error CfdEngine__PositionTooSmall();
    /// @notice A clearinghouse withdrawal would leave an open position below its required collateral level.
    error CfdEngine__WithdrawBlockedByOpenPosition();
    /// @notice Legacy selector for an empty FAD-day update; current timelocked admin uses its own validation errors.
    error CfdEngine__EmptyDays();
    /// @notice Legacy selector for zero staleness; current timelocked admin uses its own validation errors.
    error CfdEngine__ZeroStaleness();
    /// @notice An operation that requires a positive amount received zero.
    error CfdEngine__ZeroAmount();
    /// @notice Legacy selector for excessive FAD runway; current timelocked admin uses its own validation errors.
    error CfdEngine__RunwayTooLong();
    /// @notice Legacy selector for an underwater partial close; current planning uses typed failure.
    error CfdEngine__PartialCloseUnderwaterCarry();
    /// @notice Legacy selector for close remainder dust; current planning uses typed failure.
    error CfdEngine__DustPosition();
    /// @notice A live-market operation requires a fresher cached engine mark.
    error CfdEngine__MarkPriceStale();
    /// @notice An oracle publish timestamp predates the engine's stored mark timestamp.
    error CfdEngine__MarkPriceOutOfOrder();
    /// @notice A clearinghouse-only hook was called by another address.
    error CfdEngine__NotClearinghouse();
    /// @notice An account-owner-only operation was called by an address other than the account.
    error CfdEngine__NotAccountOwner();
    /// @notice An operation requiring an existing position was requested for an account without one.
    error CfdEngine__NoOpenPosition();
    /// @notice A bad-debt repayment exceeds the engine's accumulated bad debt.
    error CfdEngine__BadDebtTooLarge();
    /// @notice Risk, fee, spread, price-cap, or liquidation-bounty parameters violate engine bounds.
    error CfdEngine__InvalidRiskParams();
    /// @notice Legacy selector for excessive side skew; current planning uses typed failure.
    error CfdEngine__SkewTooHigh();
    /// @notice A risk-increasing or withdrawal action was attempted while degraded mode is latched.
    error CfdEngine__DegradedMode();
    /// @notice Degraded-mode recovery was requested while degraded mode was not latched.
    error CfdEngine__NotDegraded();
    /// @notice Degraded-mode recovery was requested before adjusted pool solvency recovered.
    error CfdEngine__StillInsolvent();
    /// @notice A required dependency, token, account, or recipient address is zero.
    error CfdEngine__ZeroAddress();
    /// @notice Free settlement and the proportional position-margin slice cannot fully back a close-order bounty.
    error CfdEngine__InsufficientCloseOrderBountyBacking();
    /// @notice Reports an expected planner rejection to the router without relying on individual error selectors.
    /// @param failureCategory Router policy category that determines whether the failed order is terminal.
    /// @param failureCode Numeric open- or close-planner revert code, interpreted according to `isClose`.
    /// @param isClose Whether `failureCode` is a `CloseRevertCode` rather than an `OpenRevertCode`.
    error CfdEngine__TypedOrderFailure(
        CfdEnginePlanTypes.ExecutionFailurePolicyCategory failureCategory, uint8 failureCode, bool isClose
    );

    /// @notice Legacy carry-index event retained in the ABI; the current engine does not emit it.
    /// @param bullIndex Updated BULL carry index, scaled by 1e18.
    /// @param bearIndex Updated BEAR carry index, scaled by 1e18.
    /// @param absSkewUsdc Absolute directional skew used for the update, in USDC.
    event CarryUpdated(int256 bullIndex, int256 bearIndex, uint256 absSkewUsdc);
    /// @notice Emitted after an open or increase is settled.
    /// @param account Account whose position was opened or increased.
    /// @param side Resulting position side.
    /// @param sizeDelta Position size added, with 18 decimals.
    /// @param price Execution price, with 8 decimals.
    /// @param marginDelta Order-supplied margin, in USDC; this is not necessarily the net post-fee margin change.
    event PositionOpened(
        address indexed account, CfdTypes.Side side, uint256 sizeDelta, uint256 price, uint256 marginDelta
    );
    /// @notice Emitted after a close or decrease is settled.
    /// @param account Account whose position was reduced or deleted.
    /// @param side Position side before the close.
    /// @param sizeDelta Position size closed, with 18 decimals.
    /// @param price Execution price, with 8 decimals.
    /// @param pnl Realized price PnL in signed USDC, before separate VPI, carry, fee, and frozen-spread accounting.
    event PositionClosed(address indexed account, CfdTypes.Side side, uint256 sizeDelta, uint256 price, int256 pnl);
    /// @notice Emitted after an unsafe position is liquidated and removed.
    /// @param account Liquidated account.
    /// @param side Liquidated position side.
    /// @param size Full liquidated position size, with 18 decimals.
    /// @param price Liquidation execution price, with 8 decimals.
    /// @param keeperBounty Bounty credited to the keeper in USDC.
    event PositionLiquidated(
        address indexed account, CfdTypes.Side side, uint256 size, uint256 price, uint256 keeperBounty
    );
    /// @notice Emitted after an account owner locks additional free settlement as active position margin.
    /// @param account Position account whose margin increased.
    /// @param amount Added margin in USDC.
    event MarginAdded(address indexed account, uint256 amount);
    /// @notice Legacy event describing FAD override days added by administrative configuration.
    /// @param timestamps Input Unix timestamps whose normalized day numbers were added.
    event FadDaysAdded(uint256[] timestamps);
    /// @notice Legacy event describing FAD override days removed by administrative configuration.
    /// @param timestamps Input Unix timestamps whose normalized day numbers were removed.
    event FadDaysRemoved(uint256[] timestamps);
    /// @notice Legacy event describing a change to the oracle-frozen staleness limit.
    /// @param newStaleness New maximum mark age in seconds.
    event FadMaxStalenessUpdated(uint256 newStaleness);
    /// @notice Legacy event describing a change to the pre-FAD deleverage runway.
    /// @param newRunway New runway duration in seconds.
    event FadRunwayUpdated(uint256 newRunway);
    /// @notice Legacy event describing a change to the engine's live cached-mark staleness component.
    /// @param newStaleness New maximum age in seconds.
    event EngineMarkStalenessLimitUpdated(uint256 newStaleness);
    /// @notice Emitted after owner-funded recapitalization reduces accumulated bad debt.
    /// @param amount Bad debt cleared in USDC.
    /// @param remaining Bad debt remaining in USDC.
    event BadDebtCleared(uint256 amount, uint256 remaining);
    /// @notice Emitted when a terminal settlement latches degraded mode because adjusted solvency is negative.
    /// @param effectiveAssets Effective pool assets after senior trader-claim reservation, in USDC.
    /// @param maxLiability Larger side's maximum-profit liability after settlement, in USDC.
    /// @param triggeringAccount Account whose settlement exposed the shortfall.
    event DegradedModeEntered(uint256 effectiveAssets, uint256 maxLiability, address indexed triggeringAccount);
    /// @notice Emitted when the owner clears degraded mode after adjusted solvency recovers.
    event DegradedModeCleared();
    /// @notice Emitted when an unaffordable fresh payout becomes a senior HousePool trader claim.
    /// @param account Claim beneficiary.
    /// @param amountUsdc Claim recorded in USDC.
    event TraderClaimRecorded(address indexed account, uint256 amountUsdc);
    /// @notice Emitted when an existing trader claim is paid into its beneficiary's clearinghouse balance.
    /// @param account Claim beneficiary.
    /// @param amountUsdc Claim settled in USDC.
    event TraderClaimSettled(address indexed account, uint256 amountUsdc);
    /// @notice Emitted when a clearinghouse-reserved execution bounty is credited to a beneficiary or treasury.
    /// @param sourceAccount Account whose reserved-settlement bucket funded the credit.
    /// @param beneficiary Clearinghouse account receiving the settlement credit.
    /// @param amountUsdc Amount reclassified in USDC; no ERC20 transfer occurs.
    event BountyCredited(address indexed sourceAccount, address indexed beneficiary, uint256 amountUsdc);
    /// @notice Emitted when elapsed carry cannot be collected and is added to an account's unsettled carry.
    /// @param account Position account whose carry was checkpointed.
    /// @param addedUnsettledCarryUsdc Newly added uncovered carry in USDC.
    /// @param totalUnsettledCarryUsdc Account's total unsettled carry after the checkpoint, in USDC.
    event CarryCheckpointed(address indexed account, uint256 addedUnsettledCarryUsdc, uint256 totalUnsettledCarryUsdc);
    /// @notice Emitted when carry is collected from an account and routed to the HousePool claimant path.
    /// @param account Position account paying carry.
    /// @param realizedCarryUsdc Total carry collected in USDC.
    /// @param freeSettlementConsumedUsdc Portion collected from free settlement, in USDC.
    /// @param marginConsumedUsdc Portion collected from active position margin, in USDC.
    /// @param remainingUnsettledCarryUsdc Previously checkpointed carry still unpaid after collection, in USDC.
    event CarryRealized(
        address indexed account,
        uint256 realizedCarryUsdc,
        uint256 freeSettlementConsumedUsdc,
        uint256 marginConsumedUsdc,
        uint256 remainingUnsettledCarryUsdc
    );
    /// @notice Legacy token-sweep event retained in the ABI; the current engine does not emit it.
    /// @param token Swept ERC20 token.
    /// @param to Recipient of the swept tokens.
    /// @param amount Amount transferred in the token's native decimals.
    event TokenSwept(address indexed token, address indexed to, uint256 amount);

    /// @notice Detailed clearinghouse custody, settlement-reachability, and trader-claim view for one account.
    /// @dev Every monetary field is USDC. Trader claims are senior HousePool liabilities and are not clearinghouse
    ///      collateral. `closeReachableUsdc` is the legacy free-settlement value, while terminal reachability may
    ///      include locked value that a full-close or liquidation path can release and consume.
    /// @param settlementBalanceUsdc Total clearinghouse settlement balance, including locked buckets.
    /// @param lockedMarginUsdc Sum of active-position, committed-order, and reserved-settlement buckets.
    /// @param activePositionMarginUsdc Clearinghouse custody bucket backing the live position.
    /// @param otherLockedMarginUsdc Sum of committed-order and reserved-settlement buckets.
    /// @param freeSettlementUsdc Settlement balance not assigned to any locked bucket.
    /// @param closeReachableUsdc Legacy close reachability value, exactly equal to `freeSettlementUsdc`.
    /// @param terminalReachableUsdc Settlement balance available to terminal close/liquidation after excluding
    ///        router-attributed execution-bounty reserves; this can include releasable locked value.
    /// @param accountEquityUsdc Clearinghouse-local settlement balance, excluding unrealized PnL and trader claims.
    /// @param freeBuyingPowerUsdc Clearinghouse-local free settlement, excluding engine withdrawal guards.
    /// @param traderClaimBalanceUsdc Separate senior HousePool payout liability owed to the account.
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
        uint256 traderClaimBalanceUsdc;
    }

    /// @notice Legacy detailed position-risk ABI shape; current live lenses do not return this struct.
    /// @dev When populated under the legacy semantics, PnL excludes carry and VPI. `netEquityUsdc` deducts stored plus
    ///      elapsed carry and any negative accumulated VPI rebate liability from physical reachable collateral and
    ///      cached-mark PnL; it excludes trader claims. Liquidatability uses the active FAD or normal maintenance ratio
    ///      without enforcing mark freshness.
    /// @param exists Whether the account has a nonzero live position.
    /// @param side Position direction; zero-valued when `exists` is false.
    /// @param size Position size, with 18 decimals.
    /// @param margin Active position margin in USDC.
    /// @param entryPrice Average entry price, with 8 decimals.
    /// @param entryNotionalUsdc Legacy 6-decimal USDC entry-notional field, distinct from raw side-state notional.
    /// @param physicalReachableCollateralUsdc Terminally reachable clearinghouse collateral, excluding trader claims.
    /// @param nettableTraderClaimUsdc Existing trader claim shown separately for settlement diagnostics.
    /// @param unrealizedPnlUsdc Signed cached-mark price PnL before carry and VPI.
    /// @param netEquityUsdc Signed physical equity after price PnL, carry, and negative VPI adjustments.
    /// @param maxProfitUsdc Position's capped maximum-profit envelope.
    /// @param liquidatable Whether physical net equity is at or below the active maintenance requirement.
    struct PositionView {
        bool exists;
        CfdTypes.Side side;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 entryNotionalUsdc;
        uint256 physicalReachableCollateralUsdc;
        uint256 nettableTraderClaimUsdc;
        int256 unrealizedPnlUsdc;
        int256 netEquityUsdc;
        uint256 maxProfitUsdc;
        bool liquidatable;
    }

    /// @notice Legacy protocol-wide pool-asset, liability, reservation, and degraded-mode view.
    /// @param poolAssetsUsdc Canonical physical HousePool assets.
    /// @param maxLiabilityUsdc Larger side's aggregate maximum-profit liability.
    /// @param withdrawalReservedUsdc Cash reserved against maximum position liability and trader claims.
    /// @param freeUsdc Pool cash above `withdrawalReservedUsdc`.
    /// @param protocolTreasuryBalanceUsdc Clearinghouse balance of the configured protocol treasury.
    /// @param totalTraderClaimBalanceUsdc Aggregate senior trader-claim liability owed by the HousePool.
    /// @param degradedMode Whether terminal insolvency has latched risk-increasing operations off.
    /// @param hasLiveLiability Whether either side has a nonzero maximum-profit liability.
    struct ProtocolAccountingView {
        uint256 poolAssetsUsdc;
        uint256 maxLiabilityUsdc;
        uint256 withdrawalReservedUsdc;
        uint256 freeUsdc;
        uint256 protocolTreasuryBalanceUsdc;
        uint256 totalTraderClaimBalanceUsdc;
        bool degradedMode;
        bool hasLiveLiability;
    }

    /// @notice Read-only projection of close/decrease economics and post-settlement solvency.
    /// @dev Prices use 8 decimals, sizes use 18 decimals, and all monetary fields use 6-decimal USDC. A false `valid`
    ///      value makes `invalidReason` authoritative; remaining fields can be partially populated up to the failure.
    /// @param valid Whether the planner would accept the close.
    /// @param invalidReason Public reason for a rejected close.
    /// @param executionPrice Caller-supplied price clamped to the engine cap.
    /// @param sizeDelta Requested close size.
    /// @param realizedPnlUsdc Signed price PnL realized by the requested size before separate costs.
    /// @param vpiDeltaUsdc Signed close VPI: positive is a charge and negative is a rebate.
    /// @param vpiUsdc Positive VPI charge exposed for legacy clients; zero for rebates.
    /// @param executionFeeUsdc Protocol execution fee assessed on the close notional.
    /// @param freshTraderPayoutUsdc New value owed to the trader by this close, whether immediate or deferred.
    /// @param existingTraderClaimConsumedUsdc Existing claim value netted into the settlement.
    /// @param existingTraderClaimRemainingUsdc Existing claim left after settlement netting.
    /// @param immediatePayoutUsdc Portion of the fresh payout paid immediately into clearinghouse settlement.
    /// @param traderClaimBalanceUsdc Projected claim balance after consuming old claims and recording deferred payout.
    /// @param seizedCollateralUsdc Physical account collateral transferred to the pool on a loss.
    /// @param badDebtUsdc Uncovered loss newly accumulated as bad debt.
    /// @param remainingSize Position size after the close.
    /// @param remainingMargin Active position margin after the close.
    /// @param triggersDegradedMode Whether this operation newly reveals adjusted pool insolvency.
    /// @param postOpDegradedMode Projected degraded-mode latch after settlement.
    /// @param effectiveAssetsAfterUsdc Projected physical pool assets net of senior trader claims.
    /// @param maxLiabilityAfterUsdc Projected larger-side maximum-profit liability.
    /// @param frozenSpreadUsdc LP-owned spread assessed on an oracle-frozen voluntary close.
    /// @param frozenSpreadPaidUsdc Assessed frozen spread recovered from retained value, physical collateral, or
    ///        existing-claim netting.
    /// @param frozenSpreadWaivedUsdc Assessed frozen spread left uncollected; it does not become bad debt.
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
        uint256 existingTraderClaimConsumedUsdc;
        uint256 existingTraderClaimRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 seizedCollateralUsdc;
        uint256 badDebtUsdc;
        uint256 remainingSize;
        uint256 remainingMargin;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
        // Append-only fields preserve every pre-existing ABI tuple offset for legacy clients.
        uint256 frozenSpreadUsdc;
        uint256 frozenSpreadPaidUsdc;
        uint256 frozenSpreadWaivedUsdc;
    }

    /// @notice Read-only open/increase trade-ticket preview.
    /// @dev Unless stated otherwise, USDC fields use 6 decimals, prices use 8 decimals, and position sizes use 18
    ///      decimals. Invalid previews return authoritative validity fields; economics/risk fields may be zero or
    ///      partial depending on where planning stopped.
    /// @param valid Whether the planner would accept the open/increase.
    /// @param invalidReason Typed planner rejection code.
    /// @param failureCategory Commit-time policy category for `invalidReason`.
    /// @param executionPrice Caller-supplied oracle price clamped to the engine cap.
    /// @param sizeDelta Requested position-size increase.
    /// @param notionalUsdc Notional represented by `sizeDelta` at `executionPrice`.
    /// @param marginDeltaUsdc Order-supplied margin.
    /// @param vpiUsdc Signed VPI for the trade: positive is a charge and negative is a rebate.
    /// @param executionFeeUsdc Protocol execution fee assessed on trade notional.
    /// @param tradeCostUsdc Total signed immediate trade cost, including VPI and execution fee.
    /// @param poolRebatePayoutUsdc Pool-funded amount required by a negative `tradeCostUsdc`.
    /// @param pendingCarryUsdc Stored plus elapsed position carry realized before the increase.
    /// @param initialMarginRequirementUsdc Initial-margin requirement for the projected position.
    /// @param maintenanceMarginUsdc Active FAD or normal maintenance requirement for the projected position.
    /// @param postSize Projected total position size.
    /// @param postMarginUsdc Projected clearinghouse position-margin bucket after carry and open-cost mutation; a
    ///        negative trade-cost rebate can be included even though projected risk does not count it as supplied margin.
    /// @param postEntryPrice Projected size-weighted entry price.
    /// @param postVpiAccrued Projected lifetime signed VPI balance.
    /// @param postUnrealizedPnlUsdc Projected signed price PnL at `executionPrice`, excluding carry and VPI.
    /// @param postEquityUsdc Projected signed physical position equity at `executionPrice`.
    /// @param postHealthBps Projected equity divided by maintenance requirement, in basis points; zero when undefined.
    /// @param postLiquidatable Whether the projected position meets the active liquidation condition.
    /// @param hasLiquidationPrice Whether a liquidation boundary exists within the capped price domain.
    /// @param liquidationPrice Boundary price in `[0, CAP_PRICE]` at which liquidation begins.
    struct OpenPreview {
        // Validity.
        bool valid;
        CfdEnginePlanTypes.OpenRevertCode invalidReason;
        CfdEnginePlanTypes.OpenFailurePolicyCategory failureCategory;
        // Trade economics.
        uint256 executionPrice;
        uint256 sizeDelta;
        uint256 notionalUsdc;
        uint256 marginDeltaUsdc;
        int256 vpiUsdc;
        uint256 executionFeeUsdc;
        int256 tradeCostUsdc;
        uint256 poolRebatePayoutUsdc;
        uint256 pendingCarryUsdc;
        // Margin and projected post-trade position.
        uint256 initialMarginRequirementUsdc;
        uint256 maintenanceMarginUsdc;
        uint256 postSize;
        uint256 postMarginUsdc;
        uint256 postEntryPrice;
        int256 postVpiAccrued;
        // Projected post-trade health.
        int256 postUnrealizedPnlUsdc;
        int256 postEquityUsdc;
        uint256 postHealthBps;
        bool postLiquidatable;
        // Liquidation threshold inside [0, CAP_PRICE], if one exists.
        bool hasLiquidationPrice;
        uint256 liquidationPrice;
    }

    /// @notice Read-only projection of liquidation economics and post-settlement solvency.
    /// @dev `oraclePrice` is clamped to the engine cap. Every monetary field is 6-decimal USDC. The simulation
    ///      models forfeiture of the account's pending execution bounties before computing terminal reachability.
    /// @param liquidatable Whether the position is at or below its active maintenance requirement.
    /// @param oraclePrice Price used by the simulation, with 8 decimals.
    /// @param equityUsdc Signed liquidation equity after price PnL, carry, and VPI adjustments.
    /// @param pnlUsdc Signed price PnL before carry and VPI.
    /// @param reachableCollateralUsdc Account collateral reachable after modeled bounty forfeiture.
    /// @param keeperBountyUsdc Keeper bounty owed by the liquidation.
    /// @param seizedCollateralUsdc Settlement value transferred from the account to the pool.
    /// @param settlementRetainedUsdc Existing account settlement left with the trader toward positive residual equity.
    /// @param freshTraderPayoutUsdc New surplus value owed to the trader after liquidation.
    /// @param existingTraderClaimConsumedUsdc Existing claim value netted into liquidation settlement.
    /// @param existingTraderClaimRemainingUsdc Existing claim left after settlement netting.
    /// @param immediatePayoutUsdc Portion of fresh trader payout paid immediately into clearinghouse settlement.
    /// @param traderClaimBalanceUsdc Projected claim balance after netting and any deferred fresh payout.
    /// @param badDebtUsdc Uncovered liquidation loss newly accumulated as bad debt.
    /// @param triggersDegradedMode Whether liquidation newly reveals adjusted pool insolvency.
    /// @param postOpDegradedMode Projected degraded-mode latch after liquidation.
    /// @param effectiveAssetsAfterUsdc Projected physical pool assets net of senior trader claims.
    /// @param maxLiabilityAfterUsdc Projected larger-side maximum-profit liability.
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
        uint256 existingTraderClaimConsumedUsdc;
        uint256 existingTraderClaimRemainingUsdc;
        uint256 immediatePayoutUsdc;
        uint256 traderClaimBalanceUsdc;
        uint256 badDebtUsdc;
        bool triggersDegradedMode;
        bool postOpDegradedMode;
        uint256 effectiveAssetsAfterUsdc;
        uint256 maxLiabilityAfterUsdc;
    }

    /// @notice Legacy trader-claim balance and immediate-serviceability view.
    /// @param traderClaimBalanceUsdc Senior HousePool payout liability owed to the account.
    /// @param traderClaimServiceableNow Whether aggregate HousePool cash can service the full selected claim now.
    struct TraderClaimStatus {
        uint256 traderClaimBalanceUsdc;
        bool traderClaimServiceableNow;
    }

    /// @notice Aggregate engine accounting for one position side.
    /// @param maxProfitUsdc Sum of capped maximum-profit envelopes for the side.
    /// @param openInterest Aggregate position size for the side, with 18 decimals.
    /// @param entryNotional Raw aggregate `size * entryPrice` numerator with 26 decimals; divide by 1e20 for USDC.
    /// @param totalMargin Aggregate active position margin for the side, in USDC.
    struct SideState {
        uint256 maxProfitUsdc;
        uint256 openInterest;
        uint256 entryNotional;
        uint256 totalMargin;
    }

}

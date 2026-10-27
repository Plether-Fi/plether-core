// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineOpenQuoter} from "@plether/perps/CfdEngineOpenQuoter.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineRiskParamsView} from "@plether/perps/interfaces/ICfdEngineRiskParamsView.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterEmergencyAdmin} from "@plether/perps/interfaces/IOrderRouterEmergencyAdmin.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @dev Minimal canonical Router binding used by the refund-aware liquidation preview.
interface ILiquidationPreviewRouter is IOrderRouterAccounting {

    function admin() external view returns (address);
    function positionProtectionBook() external view returns (address);

}

/// @title CfdEngineLens
/// @notice Permissionless open, close, and liquidation planning diagnostics for one CFD engine.
/// @dev The lens reads cached protocol state and caller-supplied hypothetical values but does not ingest oracle updates,
///      validate router/order timing policy, refresh the mark, checkpoint carry, or mutate state. Expected planner
///      business failures are encoded in preview fields; inconsistent dependencies, malformed inputs, and arithmetic
///      violations can still revert. Unless stated otherwise, settlement token amounts use 6 decimals, prices use 8 decimals, sizes
///      use 18 decimals, basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
contract CfdEngineLens is ICfdEngineLens {

    /// @notice Engine instance permanently inspected by this lens.
    CfdEngine public immutable engineContract;

    /// @notice Stateless search helper, deployed with the lens to isolate its runtime bytecode budget.
    CfdEngineOpenQuoter internal immutable openQuoter;

    /// @notice Binds the lens to one engine instance.
    /// @dev Performs no zero-address, code-size, or interface validation. Invalid bindings can deploy successfully but
    ///      cause later reads to revert.
    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
        openQuoter = new CfdEngineOpenQuoter();
    }

    /// @notice Returns the engine address inspected by this lens.
    /// @return The immutable `CfdEngine` address.
    function engine() external view returns (address) {
        return address(engineContract);
    }

    /// @notice Previews a close/decrease using current pool assets as both accounting depth and available cash.
    /// @dev The oracle price is capped at `CAP_PRICE`. This performs no oracle freshness, publish-time, target-price, or
    ///      router authorization check. No position, invalid size quantum, zero/oversized close, underfunded VPI reserve,
    ///      and uncollectible partial-close action charges are reported through `invalidReason`. Invalid results can
    ///      contain economics calculated before the failing check. Frozen-market spread fields distinguish assessed,
    ///      collectible, and waived amounts.
    /// @param account Account whose current position is hypothetically reduced.
    /// @param sizeDelta Position size to close, with 18 decimals.
    /// @param oraclePrice Candidate close price, with 8 decimals.
    /// @return preview Close economics, settlement routing, claim effects, and projected solvency.
    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @notice Previews an open or same-side increase using current pool assets and account state.
    /// @dev The oracle price is capped at `CAP_PRICE`. This does not validate oracle freshness, order commitment,
    ///      target-price, or router authorization. Invalid results expose the typed code/category and only fields
    ///      populated before the failing check. Projected health and liquidation
    ///      price are calculated only after a valid plan; liquidation price is an integer threshold within
    ///      `[0, CAP_PRICE]` when one exists.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side; an existing opposite-side position produces a typed failure.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal settlement token units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @return preview Open economics and projected post-trade position, health, and liquidation threshold.
    function previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.OpenPreview memory preview) {
        preview = _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice);
    }

    /// @notice Quotes the largest open or same-side increase accepted by the current engine plan.
    /// @dev Uses carry-adjusted interval bounds without assuming monotonic planner validity. Returns the complete
    ///      preview and next-quantum rejection alongside the maximum. Zero-capacity diagnostics describe the minimum
    ///      notional-admissible candidate. Search exhaustion explicitly reverts. Router and terminal-book execution
    ///      gates remain outside the quote; price/time and dependency/numeric assumptions match `previewOpen`.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side.
    /// @param marginDelta Margin supplied by the hypothetical order, in 6-decimal settlement token units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @return quote Largest planner-valid increase, its economics, and a limiting rejection code.
    function quoteMaxOpen(
        address account,
        CfdTypes.Side side,
        uint256 marginDelta,
        uint256 oraclePrice
    ) external view returns (MaxOpenQuote memory quote) {
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, engineContract.pool().totalAssets());
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 0,
            marginDelta: marginDelta,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: side,
            isClose: false
        });
        CfdEnginePlanTypes.OpenDelta memory delta;
        ICfdEnginePlanner planner = engineContract.planner();
        (quote.maxSizeDelta, delta, quote.limitingReason) = openQuoter.quote(planner, snap, order, oraclePrice);
        quote.preview = _openPreviewFromPlan(snap, delta, marginDelta, planner);
    }

    /// @notice Returns the numeric typed business-rule result for the same plan as `previewOpen`.
    /// @dev Inputs, capping, and possible dependency/arithmetic reverts match
    ///      `previewOpen`.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal settlement token units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @return code Numeric value of `CfdEnginePlanTypes.OpenRevertCode`; zero is `OK`.
    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice
    ) external view returns (uint8 code) {
        return uint8(_previewOpen(account, side, sizeDelta, marginDelta, oraclePrice).invalidReason);
    }

    /// @notice Classifies the same open plan for commit-time and execution-only router failure policy.
    /// @dev Inputs, capping, and possible dependency/arithmetic reverts match
    ///      `previewOpen`. This uses `getOpenFailurePolicyCategory`, not the execution-only classifier.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal settlement token units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @return category Commit-time-rejectable, execution-time user/protocol invalidation, or `None`.
    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category) {
        return _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice).failureCategory;
    }

    /// @notice Simulates a close/decrease with caller-supplied hypothetical pool accounting depth and cash.
    /// @dev Matches `previewClose` except `poolDepthAssets` replaces current pool assets for VPI, payout affordability,
    ///      and solvency calculations. Side carry-index projection still uses the live pool's actual `totalAssets`.
    /// @param account Account whose current position is hypothetically reduced.
    /// @param sizeDelta Position size to close, with 18 decimals.
    /// @param oraclePrice Candidate close price, with 8 decimals.
    /// @param poolDepthAssets Hypothetical pool assets and cash, in 6-decimal settlement token units.
    /// @return preview Close economics, settlement routing, claim effects, and projected solvency.
    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthAssets
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, poolDepthAssets);
    }

    /// @notice Previews full liquidation using current pool assets as both accounting depth and available cash.
    /// @dev The oracle price is capped at `CAP_PRICE`. The lens hypothetically forfeits the account's router execution-
    ///      bounty reserve before planning, matching terminal liquidation reachability. It performs no oracle freshness,
    ///      publish-time, or router authorization validation. An account without a position returns a nonliquidatable
    ///      preview with only the capped oracle price populated. An underfunded negative-VPI reserve makes planning
    ///      revert instead of returning a liquidatable preview. This kernel preview omits risk-off refunds;
    ///      use previewRouterLiquidation to model the Router's preceding queue cleanup.
    /// @param account Account whose current position is tested and hypothetically liquidated.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @return preview Liquidation eligibility, P+C equity, charge split, settlement, claims, and projected solvency.
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @inheritdoc ICfdEngineLens
    function previewRouterLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (RouterLiquidationPreview memory preview) {
        if (_position(account).size == 0) {
            preview.liquidation.oraclePrice =
                oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
            return preview;
        }
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, engineContract.pool().totalAssets());
        _applyRouterRiskOffRefunds(snap, preview);
        _applyLiquidationPreviewForfeiture(snap);
        preview.liquidation = _liquidationPreviewFromSnapshot(snap, oraclePrice);
    }

    /// @notice Simulates full liquidation with caller-supplied hypothetical pool accounting depth and cash.
    /// @dev Matches `previewLiquidation` except `poolDepthAssets` replaces current pool assets for payout-affordability and
    ///      solvency calculations. Side carry-index projection still uses the live pool's actual `totalAssets`.
    /// @param account Account whose current position is tested and hypothetically liquidated.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @param poolDepthAssets Hypothetical pool assets and cash, in 6-decimal settlement token units.
    /// @return preview Liquidation eligibility, P+C equity, charge split, settlement, claims, and projected solvency.
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthAssets
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, poolDepthAssets);
    }

    /// @notice Returns the canonical liquidation-eligibility bit at an explicit pool depth.
    function isLiquidatableAt(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthAssets
    ) external view returns (bool liquidatable) {
        return _previewLiquidation(account, oraclePrice, poolDepthAssets).liquidatable;
    }

    /// @notice Builds an open plan and, on success, projects post-trade risk and a liquidation threshold.
    /// @param account Account whose position and collateral seed the plan.
    /// @param side Requested position side.
    /// @param sizeDelta Requested size increase, with 18 decimals.
    /// @param marginDelta Requested margin contribution, in 6-decimal settlement token units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @return preview Typed open result and projected position/risk fields.
    function _previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice
    ) internal view returns (ICfdEngineTypes.OpenPreview memory preview) {
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, engineContract.pool().totalAssets());
        CfdEnginePlanTypes.OpenDelta memory delta = _planOpen(snap, account, side, sizeDelta, marginDelta, oraclePrice);

        return _openPreviewFromPlan(snap, delta, marginDelta, engineContract.planner());
    }

    /// @notice Builds identical open economics for standalone previews and maximum-size quotes.
    function _openPreviewFromPlan(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint256 marginDelta,
        ICfdEnginePlanner planner
    ) internal pure returns (ICfdEngineTypes.OpenPreview memory preview) {
        uint256 price = delta.price;
        preview.executionPrice = price;
        preview.sizeDelta = delta.sizeDelta;
        preview.marginDeltaAssets = marginDelta;

        preview.valid = delta.valid;
        preview.invalidReason = delta.revertCode;
        preview.failureCategory = planner.getOpenFailurePolicyCategory(delta.revertCode);
        preview.notionalAssets = delta.openState.notionalAssets;
        preview.vpiAssets = delta.openState.vpiAssets;
        preview.executionFeeAssets = delta.executionFeeAssets;
        preview.tradeCostAssets = delta.tradeCostAssets;
        preview.poolRebatePayoutAssets = delta.poolRebatePayoutAssets;
        preview.pendingCarryAssets = delta.pendingCarryAssets;
        preview.initialMarginRequirementAssets = delta.openState.initialMarginRequirementAssets;
        preview.maintenanceMarginAssets = delta.openState.maintenanceMarginAssets;
        preview.postSize = delta.newPosSize;
        preview.postMarginAssets = delta.positionMarginAfterOpen;
        preview.postEntryPrice = delta.newPosEntryPrice;
        if (delta.revertCode == CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED) {
            return preview;
        }
        preview.postVpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;
        if (!delta.valid) {
            // Early failures may have no open economics. Only correct a constructed position's requirement;
            // do not turn an uncomputed diagnostic into an apparently complete preview.
            if (delta.openState.newSize != 0) {
                preview.maintenanceMarginAssets = Math.mulDiv(
                    delta.openState.newSize / CfdTypes.SIZE_QUANTUM * price,
                    snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps,
                    10_000
                );
            }
            return preview;
        }

        CfdTypes.Position memory projected = _projectOpenPosition(snap.position, delta);
        uint256 reachableCollateralAssets = delta.positionMarginAfterOpen + snap.traderClaimBalanceForAccount;
        uint256 maintenanceBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        PositionRiskAccountingLib.PositionRiskState memory risk = PositionRiskAccountingLib.buildExactPriceRiskState(
            projected, delta.newPosEntryCostAssetAtoms, price, snap.capPrice, reachableCollateralAssets, maintenanceBps
        );

        preview.postUnrealizedPnlAssets = risk.unrealizedPnlAssets;
        preview.postEquityAssets = risk.equityAssets;
        preview.maintenanceMarginAssets = risk.maintenanceMarginAssets;
        preview.postLiquidatable = risk.liquidatable;
        preview.postHealthBps = _healthBps(risk.equityAssets, risk.maintenanceMarginAssets);
        (preview.hasLiquidationPrice, preview.liquidationPrice) = _findLiquidationPrice(
            projected, delta.newPosEntryCostAssetAtoms, snap.capPrice, reachableCollateralAssets, maintenanceBps
        );
    }

    /// @notice Calls the canonical open planner against one already-built snapshot.
    function _planOpen(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice
    ) internal view returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: side,
            isClose: false
        });
        return engineContract.planner().planOpen(snap, order, oraclePrice);
    }

    /// @notice Builds a close plan against current account state and supplied hypothetical pool depth.
    /// @param account Account whose position is reduced.
    /// @param sizeDelta Requested size reduction, with 18 decimals.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param poolDepthAssets Pool assets and cash used by the plan, in 6-decimal settlement token units.
    /// @return preview Typed close result, settlement routing, and projected solvency.
    function _previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthAssets
    ) internal view returns (ICfdEngineTypes.ClosePreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;
        ICfdEnginePlanner planner = engineContract.planner();

        CfdTypes.Position memory pos = _position(account);
        if (pos.size == 0) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.NoPosition;
            return preview;
        }
        if (sizeDelta == 0 || sizeDelta > pos.size) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.BadSize;
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, poolDepthAssets);
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: sizeDelta,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: pos.side,
            isClose: true
        });
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, oraclePrice);

        preview.realizedPnlAssets = delta.realizedPnlAssets;
        preview.remainingMargin = delta.posMarginAfter;
        preview.remainingSize = pos.size - sizeDelta;
        preview.vpiDeltaAssets = delta.closeState.vpiDeltaAssets;
        if (delta.closeState.vpiDeltaAssets > 0) {
            preview.vpiAssets = uint256(delta.closeState.vpiDeltaAssets);
        }
        preview.executionFeeAssets = delta.executionFeeAssets;
        preview.frozenSpreadAssets = delta.closeState.frozenSpreadAssets;
        preview.frozenSpreadPaidAssets = _frozenSpreadPaidAssets(delta);
        preview.frozenSpreadWaivedAssets = preview.frozenSpreadAssets - preview.frozenSpreadPaidAssets;

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.DustPosition;
            return preview;
        }
        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.INVALID_SIZE_QUANTUM) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.InvalidSizeQuantum;
            return preview;
        }
        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.VPI_REBATE_RESERVE_UNDERFUNDED) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.VpiRebateReserveUnderfunded;
            return preview;
        }
        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_ACTION_CHARGE_UNCOLLECTIBLE) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.PartialActionChargeUncollectible;
            return preview;
        }

        // Typed failure-code dispatch must use exact equality; balances do not select this enum value.
        // slither-disable-next-line incorrect-equality
        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNHEALTHY) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.PartialCloseUnhealthy;
            return preview;
        }
        preview.freshTraderPayoutAssets = delta.freshTraderPayoutAssets;
        preview.existingTraderClaimConsumedAssets = delta.existingTraderClaimConsumedAssets;
        preview.existingTraderClaimRemainingAssets = delta.existingTraderClaimRemainingAssets;
        // Mirror settlement routing: partial-close price cash stays pledged; action rebates are always free.
        preview.payoutToFreeSettlementAssets = delta.actionRebatePaidAssets;
        if (delta.pricePayoutIsImmediate) {
            if (delta.deletePosition) {
                preview.payoutToFreeSettlementAssets += delta.pricePayoutAssets;
            } else {
                preview.payoutToPnlPledgeAssets = delta.pricePayoutAssets;
            }
        }
        preview.deferredPayoutAssets = delta.pricePayoutCreatesClaim ? delta.pricePayoutAssets : 0;
        preview.immediatePayoutAssets = preview.payoutToPnlPledgeAssets + preview.payoutToFreeSettlementAssets;
        preview.traderClaimBalanceAssets = delta.existingTraderClaimRemainingAssets + preview.deferredPayoutAssets;
        preview.seizedCollateralAssets = delta.pricePnlPledgeConsumedAssets;

        preview.valid = delta.valid;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterAssets = delta.solvency.effectiveAssetsAfterAssets;
        preview.maxLiabilityAfterAssets = delta.solvency.maxLiabilityAfterAssets;
    }

    /// @notice Derives assessed frozen-market spread recovered from new price gain and eligible action collateral.
    /// @param delta Planned close result.
    /// @return paidAssets Collectible frozen spread in 6-decimal settlement token units.
    function _frozenSpreadPaidAssets(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (uint256 paidAssets) {
        uint256 priorChargesAssets =
            delta.closeState.executionFeeAssets + delta.pendingCarryAssets - delta.realizedCarryAssets;
        if (delta.closeState.vpiDeltaAssets > 0) {
            priorChargesAssets += uint256(delta.closeState.vpiDeltaAssets);
        }
        uint256 effectiveSpreadAssets;
        if (delta.actionChargeAssessedAssets > priorChargesAssets) {
            effectiveSpreadAssets = delta.actionChargeAssessedAssets - priorChargesAssets;
            if (effectiveSpreadAssets > delta.closeState.frozenSpreadAssets) {
                effectiveSpreadAssets = delta.closeState.frozenSpreadAssets;
            }
        }
        uint256 recoveredActionAssets = delta.actionChargeWithheldAssets + delta.actionChargeCollectedAssets;
        if (recoveredActionAssets <= priorChargesAssets) {
            return 0;
        }
        paidAssets = recoveredActionAssets - priorChargesAssets;
        if (paidAssets > effectiveSpreadAssets) {
            paidAssets = effectiveSpreadAssets;
        }
    }

    /// @notice Applies an open delta to a memory position for risk simulation.
    /// @dev `positionMarginAfterOpen` is already the exact isolated PnL pledge after action costs and reserve carve-out.
    /// @param current Current position before the hypothetical open.
    /// @param delta Valid planned open delta.
    /// @return projected Post-open position used for risk calculations.
    function _projectOpenPosition(
        CfdTypes.Position memory current,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal pure returns (CfdTypes.Position memory projected) {
        projected = current;
        projected.side = delta.posSide;
        projected.size = delta.newPosSize;
        projected.margin = delta.positionMarginAfterOpen;
        projected.entryPrice = delta.newPosEntryPrice;
        projected.maxProfitAssets = current.maxProfitAssets + delta.posMaxProfitIncrease;
        projected.vpiAccrued = current.vpiAccrued + delta.posVpiAccruedDelta;
    }

    /// @notice Expresses positive equity as a percentage of maintenance requirement.
    /// @dev Returns zero when equity is nonpositive or the requirement is zero; otherwise it is not capped at 10,000.
    /// @param equityAssets Signed projected equity in 6-decimal settlement token units.
    /// @param maintenanceMarginAssets Projected maintenance requirement in 6-decimal settlement token units.
    /// @return healthBps Equity divided by maintenance margin, using a 10,000 denominator.
    function _healthBps(
        int256 equityAssets,
        uint256 maintenanceMarginAssets
    ) internal pure returns (uint256 healthBps) {
        if (equityAssets <= 0 || maintenanceMarginAssets == 0) {
            return 0;
        }
        return (SafeCast.toUint256(equityAssets) * 10_000) / maintenanceMarginAssets;
    }

    /// @notice Finds the integer liquidation boundary within the engine price domain.
    /// @dev For LONG positions this returns the lowest liquidatable price; for SHORT positions, the highest. If the
    ///      position is never liquidatable within `[0, capPrice]`, the boolean is false and price is zero.
    /// @param projected Position whose threshold is searched.
    /// @param capPrice Inclusive upper price bound, with 8 decimals.
    /// @param reachableCollateralAssets Projected PnL pledge plus same-account claim, in 6-decimal settlement token units.
    /// @param maintenanceBps Active maintenance or FAD margin rate.
    /// @return hasLiquidationPrice Whether a liquidation boundary exists in the searched domain.
    /// @return liquidationPrice Integer boundary price, with 8 decimals.
    function _findLiquidationPrice(
        CfdTypes.Position memory projected,
        uint256 entryCostAssetAtoms,
        uint256 capPrice,
        uint256 reachableCollateralAssets,
        uint256 maintenanceBps
    ) internal pure returns (bool hasLiquidationPrice, uint256 liquidationPrice) {
        bool liquidatableAtZero = _isProjectedLiquidatable(
            projected, entryCostAssetAtoms, 0, capPrice, reachableCollateralAssets, maintenanceBps
        );
        bool liquidatableAtCap = _isProjectedLiquidatable(
            projected, entryCostAssetAtoms, capPrice, capPrice, reachableCollateralAssets, maintenanceBps
        );

        if (projected.side == CfdTypes.Side.LONG) {
            if (!liquidatableAtCap) {
                return (false, 0);
            }
            if (liquidatableAtZero) {
                return (true, 0);
            }
            uint256 low;
            uint256 high = capPrice;
            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (_isProjectedLiquidatable(
                        projected, entryCostAssetAtoms, mid, capPrice, reachableCollateralAssets, maintenanceBps
                    )) {
                    high = mid;
                } else {
                    low = mid + 1;
                }
            }
            return (true, high);
        }

        if (!liquidatableAtZero) {
            return (false, 0);
        }
        if (liquidatableAtCap) {
            return (true, capPrice);
        }
        uint256 lo;
        uint256 hi = capPrice;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_isProjectedLiquidatable(
                    projected, entryCostAssetAtoms, mid, capPrice, reachableCollateralAssets, maintenanceBps
                )) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return (true, lo);
    }

    /// @notice Tests projected position equity at one candidate price.
    /// @param projected Position to test.
    /// @param price Candidate price, with 8 decimals.
    /// @param capPrice Engine price cap, with 8 decimals.
    /// @param reachableCollateralAssets Projected PnL pledge plus same-account claim, in 6-decimal settlement token units.
    /// @param maintenanceBps Active maintenance or FAD margin rate.
    /// @return Whether equity is at or below the requirement.
    function _isProjectedLiquidatable(
        CfdTypes.Position memory projected,
        uint256 entryCostAssetAtoms,
        uint256 price,
        uint256 capPrice,
        uint256 reachableCollateralAssets,
        uint256 maintenanceBps
    ) internal pure returns (bool) {
        return PositionRiskAccountingLib.buildExactPriceRiskState(
            projected, entryCostAssetAtoms, price, capPrice, reachableCollateralAssets, maintenanceBps
        )
        .liquidatable;
    }

    /// @notice Builds liquidation diagnostics using current account state and supplied hypothetical pool depth.
    /// @param account Account whose position is tested.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @param poolDepthAssets Pool assets and cash used by the plan, in 6-decimal settlement token units.
    /// @return preview Eligibility, settlement routing, claims, and projected solvency.
    function _previewLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthAssets
    ) internal view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.oraclePrice = price;
        if (_position(account).size == 0) {
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, poolDepthAssets);
        _applyLiquidationPreviewForfeiture(snap);
        return _liquidationPreviewFromSnapshot(snap, oraclePrice);
    }

    function _liquidationPreviewFromSnapshot(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 oraclePrice
    ) internal view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview.oraclePrice = oraclePrice > snap.capPrice ? snap.capPrice : oraclePrice;
        CfdEnginePlanTypes.LiquidationDelta memory delta = engineContract.planner().planLiquidation(snap, oraclePrice);

        preview.liquidatable = delta.liquidatable;
        preview.reachableCollateralAssets = delta.liquidationReachableCollateralAssets;
        preview.pnlAssets = delta.riskState.unrealizedPnlAssets;
        preview.equityAssets = delta.riskState.equityAssets;
        preview.liquidationChargeAssets = delta.liquidationChargeAssets;
        preview.keeperBountyAssets = delta.keeperBountyAssets;
        preview.protocolLiquidationFeeAssets = delta.protocolLiquidationFeeAssets;
        preview.lpLiquidationFeeAssets = delta.lpLiquidationFeeAssets;
        preview.seizedCollateralAssets = delta.settlementSeizedAssets;
        preview.settlementRetainedAssets = delta.settlementRetainedAssets;
        preview.freshTraderPayoutAssets = delta.freshTraderPayoutAssets;
        preview.existingTraderClaimConsumedAssets = delta.existingTraderClaimConsumedAssets;
        preview.existingTraderClaimRemainingAssets = delta.existingTraderClaimRemainingAssets;
        preview.immediatePayoutAssets = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutAssets : 0;
        preview.traderClaimBalanceAssets = delta.existingTraderClaimRemainingAssets;
        if (delta.freshPayoutCreatesClaim) {
            preview.traderClaimBalanceAssets += delta.freshTraderPayoutAssets;
        }
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterAssets = delta.solvency.effectiveAssetsAfterAssets;
        preview.maxLiabilityAfterAssets = delta.solvency.maxLiabilityAfterAssets;
    }

    /// @dev Mirrors only the custody reclassification performed by releaseInvalidatedOrderReserves. It neither
    ///      transfers settlement token nor checkpoints carry; the subsequent planner sees newly free settlement for carry payment.
    function _applyRouterRiskOffRefunds(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        RouterLiquidationPreview memory preview
    ) internal view {
        ILiquidationPreviewRouter router = ILiquidationPreviewRouter(engineContract.orderRouter());
        preview.riskOffCutoff = IOrderRouterEmergencyAdmin(router.admin()).riskOffOrderCutoff();
        if (preview.riskOffCutoff == 0) {
            return;
        }
        IPositionProtectionViews protectionBook = IPositionProtectionViews(router.positionProtectionBook());
        uint64 protectionId = protectionBook.activePositionProtectionId(snap.account);
        PositionProtectionTypes.PositionProtectionView memory protection;
        if (protectionId != 0) {
            protection = protectionBook.getPositionProtection(protectionId);
        }
        uint256 remaining = router.pendingOrderCounts(snap.account);
        for (uint64 orderId = router.accountHeadOrderId(snap.account); orderId != 0;) {
            if (remaining == 0) {
                revert CfdEngineLens__InvalidRouterQueue();
            }
            --remaining;
            (IOrderRouterAccounting.PendingOrderView memory pending, uint64 next) = router.getPendingOrderView(orderId);
            if (!pending.isClose && orderId <= preview.riskOffCutoff) {
                ++preview.refundedOrderCount;
                preview.releasedCommittedMarginAssets += pending.committedMarginAssets;
                preview.releasedBountyAssets += pending.executionBountyAssets;
                if (
                    protection.status == PositionProtectionTypes.PositionProtectionStatus.PendingOpen
                        && protection.parentOrderId == orderId && protection.account == snap.account
                ) {
                    preview.releasedBountyAssets += IMarginClearinghouse(engineContract.clearinghouse())
                    .getBountyReservation(IMarginClearinghouse.BountyKind.ProtectionTrigger, protectionId)
                    .amountAssets;
                }
            }
            orderId = next;
        }
        uint256 released = preview.releasedCommittedMarginAssets + preview.releasedBountyAssets;
        snap.lockedBuckets.committedOrderMarginAssets -= preview.releasedCommittedMarginAssets;
        snap.lockedBuckets.reservedSettlementAssets -= preview.releasedBountyAssets;
        snap.lockedBuckets.totalLockedMarginAssets -= released;
        snap.actionReserveAssets -= preview.releasedBountyAssets;
        snap.protectedExecutionBountyAssets -= preview.releasedBountyAssets;
        snap.accountBuckets.otherLockedMarginAssets -= released;
        snap.accountBuckets.totalLockedMarginAssets -= released;
        snap.accountBuckets.freeSettlementAssets = snap.accountBuckets.settlementBalanceAssets
            > snap.accountBuckets.totalLockedMarginAssets
            ? snap.accountBuckets.settlementBalanceAssets - snap.accountBuckets.totalLockedMarginAssets
            : 0;
    }

    /// @notice Reconstructs planner input from engine and clearinghouse state plus hypothetical pool depth.
    /// @dev `poolDepthAssets` populates both asset and cash fields. This lens does not populate the last-mark context
    ///      used only by close-commitment planning. Current carry indexes use actual assets net of claims rather than
    ///      hypothetical depth. VPI and skew subtract claims from the gross planning input.
    /// @param account Account whose position, buckets, carry, and claims are loaded.
    /// @param poolDepthAssets Hypothetical pool assets and cash, in 6-decimal settlement token units.
    /// @return snap Raw planner snapshot.
    function _buildRawSnapshot(
        address account,
        uint256 poolDepthAssets
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineTypes.SideState memory long;
        ICfdEngineTypes.SideState memory short;
        (long.maxProfitAssets, long.openInterest, long.entryNotional, long.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.LONG));
        (short.maxProfitAssets, short.openInterest, short.entryNotional, short.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.SHORT));
        snap.position = _position(account);
        snap.positionEntryCostAssetAtoms = engineContract.positionEntryCostAssetAtoms(account);
        snap.account = account;
        snap.currentTimestamp = block.timestamp;
        (snap.positionBorrowBaseAssets, snap.positionLastCarryIndex,) = engineContract.positionCarryState(account);
        snap.longSide = _sideSnapshot(CfdTypes.Side.LONG, long);
        snap.shortSide = _sideSnapshot(CfdTypes.Side.SHORT, short);
        snap.poolAssets = poolDepthAssets;
        snap.poolCashAssets = poolDepthAssets;
        IHousePool pool = IHousePool(address(engineContract.pool()));
        snap.poolAdditionalReservedAssets =
            pool.pendingRecapitalizationAssets() + pool.pendingTradingRevenueAssets() + pool.unassignedAssets();
        snap.poolQueuesTradingRevenue = pool.seniorPrincipal() == 0 && pool.juniorPrincipal() == 0;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engineContract.clearinghouse());
        snap.accountBuckets = clearinghouse.getAccountAssetBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.liquidationReserveAssets = clearinghouse.liquidationReserveAssets(account);
        snap.actionReserveAssets = clearinghouse.actionReserveAssets(account);
        snap.vpiRebateReserveAssets = clearinghouse.vpiRebateReserveAssets(account);
        snap.protectedExecutionBountyAssets = clearinghouse.totalBountyReservationsAssets(account);
        snap.unsettledCarryAssets = engineContract.unsettledCarryAssets(account);
        snap.totalTraderClaimBalanceAssets = engineContract.totalTraderClaimBalanceAssets();
        snap.traderClaimBalanceForAccount = engineContract.traderClaimBalanceAssets(account);
        snap.degradedMode = engineContract.degradedMode();
        snap.capPrice = engineContract.CAP_PRICE();
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engineContract.executionFeeBps();
        snap.settlementBufferBps = engineContract.settlementBufferBps();
        snap.isFadWindow = engineContract.isFadWindow();
        snap.oracleFrozen = engineContract.isOracleFrozen();
        snap.frozenCloseSpreadBps = engineContract.frozenCloseSpreadBps();
    }

    /// @notice Adjusts a memory snapshot for execution-bounty value forfeited before liquidation settlement.
    /// @dev Does nothing without a nonzero bounty reserve. The debit and lock release are capped
    ///      by the corresponding snapshot buckets and no live state is changed.
    /// @param snap Snapshot mutated in memory before liquidation planning.
    function _applyLiquidationPreviewForfeiture(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal pure {
        uint256 forfeitedAssets = snap.protectedExecutionBountyAssets;
        if (forfeitedAssets == 0) {
            return;
        }
        if (forfeitedAssets > snap.accountBuckets.settlementBalanceAssets) {
            forfeitedAssets = snap.accountBuckets.settlementBalanceAssets;
        }
        snap.accountBuckets.settlementBalanceAssets -= forfeitedAssets;

        uint256 releasedReserveAssets = forfeitedAssets;
        if (releasedReserveAssets > snap.lockedBuckets.reservedSettlementAssets) {
            releasedReserveAssets = snap.lockedBuckets.reservedSettlementAssets;
        }
        snap.lockedBuckets.reservedSettlementAssets -= releasedReserveAssets;
        snap.lockedBuckets.totalLockedMarginAssets -= releasedReserveAssets;
        snap.actionReserveAssets =
            snap.actionReserveAssets > releasedReserveAssets ? snap.actionReserveAssets - releasedReserveAssets : 0;
        snap.protectedExecutionBountyAssets = 0;
        uint256 accountReserveReleaseAssets = releasedReserveAssets;
        if (accountReserveReleaseAssets > snap.accountBuckets.otherLockedMarginAssets) {
            accountReserveReleaseAssets = snap.accountBuckets.otherLockedMarginAssets;
        }
        snap.accountBuckets.otherLockedMarginAssets -= accountReserveReleaseAssets;
        snap.accountBuckets.totalLockedMarginAssets -= accountReserveReleaseAssets;
        snap.accountBuckets.freeSettlementAssets = snap.accountBuckets.settlementBalanceAssets
            > snap.accountBuckets.totalLockedMarginAssets
            ? snap.accountBuckets.settlementBalanceAssets - snap.accountBuckets.totalLockedMarginAssets
            : 0;
    }

    /// @notice Reconstructs the current position plus its separately stored carry timestamp.
    /// @param account Account whose position is loaded.
    /// @return pos Current engine position.
    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitAssets, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engineContract.positions(account);
        (,, pos.lastCarryTimestamp) = engineContract.positionCarryState(account);
    }

    /// @notice Extends an aggregate side-state tuple with current borrow base and projected carry index.
    /// @param sideId Side identifier used for carry state.
    /// @param side Aggregate side state loaded from the engine.
    /// @return snap Complete planner side snapshot.
    function _sideSnapshot(
        CfdTypes.Side sideId,
        ICfdEngineTypes.SideState memory side
    ) internal view returns (CfdEnginePlanTypes.SideSnapshot memory snap) {
        snap = CfdEnginePlanTypes.SideSnapshot({
            maxProfitAssets: side.maxProfitAssets,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin,
            borrowBaseAssets: engineContract.sideBorrowBaseAssets(uint256(sideId)),
            carryIndex: _currentSideCarryIndex(sideId)
        });
    }

    /// @notice Projects a side's cumulative carry index through the current block timestamp.
    /// @dev Utilization uses live assets net of trader claims, including during hypothetical-depth simulations.
    /// @param side Side whose index is projected.
    /// @return Current cumulative carry index, scaled by 1e18.
    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,,,) = engineContract.riskParams();
        return PositionRiskAccountingLib.computeCurrentCarryIndex(
            engineContract.sideCarryIndex(sideIndex),
            engineContract.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engineContract.sideBorrowBaseAssets(sideIndex),
            PositionRiskAccountingLib.computeNetPoolDepthAssets(
                engineContract.pool().totalAssets(), engineContract.totalTraderClaimBalanceAssets()
            ),
            baseCarryBps
        );
    }

    /// @notice Reconstructs the engine's current risk-parameter struct from its public tuple getter.
    /// @return params Current risk, VPI, carry, margin, and bounty settings.
    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        params = ICfdEngineRiskParamsView(address(engineContract)).riskParams();
    }

}

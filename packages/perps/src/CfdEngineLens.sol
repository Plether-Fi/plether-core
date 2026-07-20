// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {OpenAccountingLib} from "@plether/perps/libraries/OpenAccountingLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @title CfdEngineLens
/// @notice Permissionless open, close, and liquidation planning diagnostics for one CFD engine.
/// @dev The lens reads cached protocol state and caller-supplied hypothetical values but does not ingest oracle updates,
///      validate router/order timing policy, refresh the mark, checkpoint carry, or mutate state. Expected planner
///      business failures are encoded in preview fields; inconsistent dependencies, malformed inputs, and arithmetic
///      violations can still revert. Unless stated otherwise, USDC amounts use 6 decimals, prices use 8 decimals, sizes
///      use 18 decimals, basis-point values use a 10,000 denominator, and timestamps are Unix seconds.
contract CfdEngineLens is ICfdEngineLens {

    /// @notice Engine instance permanently inspected by this lens.
    CfdEngine public immutable engineContract;

    /// @notice Binds the lens to one engine instance.
    /// @dev Performs no zero-address, code-size, or interface validation. Invalid bindings can deploy successfully but
    ///      cause later reads to revert.
    /// @param engine_ Deployed `CfdEngine` instance to inspect.
    constructor(
        address engine_
    ) {
        engineContract = CfdEngine(engine_);
    }

    /// @notice Returns the engine address inspected by this lens.
    /// @return The immutable `CfdEngine` address.
    function engine() external view returns (address) {
        return address(engineContract);
    }

    /// @notice Previews a close/decrease using current pool assets as both accounting depth and available cash.
    /// @dev The oracle price is capped at `CAP_PRICE`. This performs no oracle freshness, publish-time, target-price, or
    ///      router authorization check. No-position, zero/oversized close, dust remainder, and underwater partial-close
    ///      failures are reported through `invalidReason`; invalid results can contain economics calculated before the
    ///      failing check. Frozen-market spread fields distinguish assessed, collectible, and waived amounts.
    /// @param account Account whose current position is hypothetically reduced.
    /// @param sizeDelta Position size to close, with 18 decimals.
    /// @param oraclePrice Candidate close price, with 8 decimals.
    /// @return preview Close economics, settlement routing, claim/bad-debt effects, and projected solvency.
    function previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @notice Previews an open or same-side increase using current pool assets and account state.
    /// @dev The oracle price is capped at `CAP_PRICE`. This does not validate oracle freshness, order commitment,
    ///      target-price, or router authorization. `publishTime` is copied into snapshot context and passed to the pure
    ///      planner, but current planning calculations do not use it. Invalid results expose the typed code/category and
    ///      only fields populated before the failing check. Projected health and liquidation price are calculated only
    ///      after a valid plan; liquidation price is an integer threshold within `[0, CAP_PRICE]` when one exists.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side; an existing opposite-side position produces a typed failure.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal USDC units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param publishTime Candidate oracle publish timestamp in Unix seconds; currently nonbinding in the planner.
    /// @return preview Open economics and projected post-trade position, health, and liquidation threshold.
    function previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (ICfdEngineTypes.OpenPreview memory preview) {
        preview = _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime);
    }

    /// @notice Returns the numeric typed business-rule result for the same plan as `previewOpen`.
    /// @dev Inputs, capping, nonbinding publish-time behavior, and possible dependency/arithmetic reverts match
    ///      `previewOpen`.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal USDC units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param publishTime Candidate oracle publish timestamp in Unix seconds.
    /// @return code Numeric value of `CfdEnginePlanTypes.OpenRevertCode`; zero is `OK`.
    function previewOpenRevertCode(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (uint8 code) {
        return uint8(_previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime).invalidReason);
    }

    /// @notice Classifies the same open plan for commit-time and execution-only router failure policy.
    /// @dev Inputs, capping, nonbinding publish-time behavior, and possible dependency/arithmetic reverts match
    ///      `previewOpen`. This uses `getOpenFailurePolicyCategory`, not the execution-only classifier.
    /// @param account Account that would open or increase a position.
    /// @param side Resulting position side.
    /// @param sizeDelta Position size increase, with 18 decimals.
    /// @param marginDelta Margin supplied by the order, in 6-decimal USDC units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param publishTime Candidate oracle publish timestamp in Unix seconds.
    /// @return category Commit-time-rejectable, execution-time user/protocol invalidation, or `None`.
    function previewOpenFailurePolicyCategory(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) external view returns (CfdEnginePlanTypes.OpenFailurePolicyCategory category) {
        return _previewOpen(account, side, sizeDelta, marginDelta, oraclePrice, publishTime).failureCategory;
    }

    /// @notice Simulates a close/decrease with caller-supplied hypothetical pool accounting depth and cash.
    /// @dev Matches `previewClose` except `poolDepthUsdc` replaces current pool assets for VPI, payout affordability,
    ///      and solvency calculations. Side carry-index projection still uses the live pool's actual `totalAssets`.
    /// @param account Account whose current position is hypothetically reduced.
    /// @param sizeDelta Position size to close, with 18 decimals.
    /// @param oraclePrice Candidate close price, with 8 decimals.
    /// @param poolDepthUsdc Hypothetical pool assets and cash, in 6-decimal USDC units.
    /// @return preview Close economics, settlement routing, claim/bad-debt effects, and projected solvency.
    function simulateClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.ClosePreview memory preview) {
        preview = _previewClose(account, sizeDelta, oraclePrice, poolDepthUsdc);
    }

    /// @notice Previews full liquidation using current pool assets as both accounting depth and available cash.
    /// @dev The oracle price is capped at `CAP_PRICE`. The lens hypothetically forfeits the account's router execution-
    ///      bounty reserve before planning, matching terminal liquidation reachability. It performs no oracle freshness,
    ///      publish-time, or router authorization validation. An account without a position returns a nonliquidatable
    ///      preview with only the capped oracle price populated.
    /// @param account Account whose current position is tested and hypothetically liquidated.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @return preview Liquidation eligibility, equity, bounty, settlement, claims, bad debt, and projected solvency.
    function previewLiquidation(
        address account,
        uint256 oraclePrice
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, engineContract.pool().totalAssets());
    }

    /// @notice Simulates full liquidation with caller-supplied hypothetical pool accounting depth and cash.
    /// @dev Matches `previewLiquidation` except `poolDepthUsdc` replaces current pool assets for payout-affordability and
    ///      solvency calculations. Side carry-index projection still uses the live pool's actual `totalAssets`.
    /// @param account Account whose current position is tested and hypothetically liquidated.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @param poolDepthUsdc Hypothetical pool assets and cash, in 6-decimal USDC units.
    /// @return preview Liquidation eligibility, equity, bounty, settlement, claims, bad debt, and projected solvency.
    function simulateLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) external view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        preview = _previewLiquidation(account, oraclePrice, poolDepthUsdc);
    }

    /// @notice Builds an open plan and, on success, projects post-trade risk and a liquidation threshold.
    /// @param account Account whose position and collateral seed the plan.
    /// @param side Requested position side.
    /// @param sizeDelta Requested size increase, with 18 decimals.
    /// @param marginDelta Requested margin contribution, in 6-decimal USDC units.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param publishTime Candidate mark publish timestamp in Unix seconds.
    /// @return preview Typed open result and projected position/risk fields.
    function _previewOpen(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 oraclePrice,
        uint64 publishTime
    ) internal view returns (ICfdEngineTypes.OpenPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.executionPrice = price;
        preview.sizeDelta = sizeDelta;
        preview.marginDeltaUsdc = marginDelta;

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(account, oraclePrice, engineContract.pool().totalAssets(), publishTime);
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
        ICfdEnginePlanner planner = engineContract.planner();
        CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, oraclePrice, publishTime);

        preview.valid = delta.valid;
        preview.invalidReason = delta.revertCode;
        preview.failureCategory = planner.getOpenFailurePolicyCategory(delta.revertCode);
        preview.notionalUsdc = delta.openState.notionalUsdc;
        preview.vpiUsdc = delta.openState.vpiUsdc;
        preview.executionFeeUsdc = delta.executionFeeUsdc;
        preview.tradeCostUsdc = delta.tradeCostUsdc;
        preview.poolRebatePayoutUsdc = delta.poolRebatePayoutUsdc;
        preview.pendingCarryUsdc = delta.pendingCarryUsdc;
        preview.initialMarginRequirementUsdc = delta.openState.initialMarginRequirementUsdc;
        preview.maintenanceMarginUsdc = delta.openState.maintenanceMarginUsdc;
        preview.postSize = delta.newPosSize;
        preview.postMarginUsdc = delta.positionMarginAfterOpen;
        preview.postEntryPrice = delta.newPosEntryPrice;
        preview.postVpiAccrued = snap.position.vpiAccrued + delta.posVpiAccruedDelta;

        if (!delta.valid) {
            return preview;
        }

        CfdTypes.Position memory projected = _projectOpenPosition(snap.position, delta);
        uint256 reachableCollateralUsdc =
            _postOpenReachableCollateral(snap, delta.pendingCarryUsdc, delta.tradeCostUsdc);
        uint256 maintenanceBps = snap.isFadWindow ? snap.riskParams.fadMarginBps : snap.riskParams.maintMarginBps;
        PositionRiskAccountingLib.PositionRiskState memory risk =
            PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
                projected, price, snap.capPrice, 0, reachableCollateralUsdc, maintenanceBps
            );

        preview.postUnrealizedPnlUsdc = risk.unrealizedPnlUsdc;
        preview.postEquityUsdc = risk.equityUsdc;
        preview.maintenanceMarginUsdc = risk.maintenanceMarginUsdc;
        preview.postLiquidatable = risk.liquidatable;
        preview.postHealthBps = _healthBps(risk.equityUsdc, risk.maintenanceMarginUsdc);
        (preview.hasLiquidationPrice, preview.liquidationPrice) =
            _findLiquidationPrice(projected, snap.capPrice, reachableCollateralUsdc, maintenanceBps);
    }

    /// @notice Builds a close plan against current account state and supplied hypothetical pool depth.
    /// @param account Account whose position is reduced.
    /// @param sizeDelta Requested size reduction, with 18 decimals.
    /// @param oraclePrice Candidate execution price, with 8 decimals.
    /// @param poolDepthUsdc Pool assets and cash used by the plan, in 6-decimal USDC units.
    /// @return preview Typed close result, settlement routing, and projected solvency.
    function _previewClose(
        address account,
        uint256 sizeDelta,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
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

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, oraclePrice, poolDepthUsdc, 0);
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
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, oraclePrice, 0);

        preview.realizedPnlUsdc = delta.realizedPnlUsdc;
        preview.remainingMargin = delta.posMarginAfter;
        preview.remainingSize = pos.size - sizeDelta;
        preview.vpiDeltaUsdc = delta.closeState.vpiDeltaUsdc;
        if (delta.closeState.vpiDeltaUsdc > 0) {
            preview.vpiUsdc = uint256(delta.closeState.vpiDeltaUsdc);
        }
        preview.executionFeeUsdc = delta.executionFeeUsdc;
        preview.frozenSpreadUsdc = delta.closeState.frozenSpreadUsdc;
        preview.frozenSpreadPaidUsdc = _frozenSpreadPaidUsdc(delta);
        preview.frozenSpreadWaivedUsdc = preview.frozenSpreadUsdc - preview.frozenSpreadPaidUsdc;

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.DustPosition;
            return preview;
        }

        preview.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        preview.existingTraderClaimConsumedUsdc = delta.existingTraderClaimConsumedUsdc;
        preview.existingTraderClaimRemainingUsdc = delta.existingTraderClaimRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.traderClaimBalanceUsdc =
            delta.existingTraderClaimRemainingUsdc + (delta.freshPayoutCreatesClaim ? delta.freshTraderPayoutUsdc : 0);
        if (delta.settlementType == CfdEnginePlanTypes.SettlementType.LOSS) {
            preview.seizedCollateralUsdc = delta.lossConsumption.totalConsumedUsdc;
            preview.badDebtUsdc = delta.badDebtUsdc;
        }

        if (delta.revertCode == CfdEnginePlanTypes.CloseRevertCode.PARTIAL_CLOSE_UNDERWATER) {
            preview.invalidReason = CfdTypes.CloseInvalidReason.PartialCloseUnderwater;
            return preview;
        }

        preview.valid = delta.valid;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    /// @notice Derives the portion of assessed frozen-market spread recovered by settlement and claim netting.
    /// @param delta Planned close result.
    /// @return paidUsdc Collectible frozen spread in 6-decimal USDC units.
    function _frozenSpreadPaidUsdc(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure returns (uint256 paidUsdc) {
        if (delta.settlementType != CfdEnginePlanTypes.SettlementType.LOSS) {
            return delta.closeState.frozenSpreadUsdc;
        }

        uint256 uncollectedExecFeeUsdc = delta.closeState.executionFeeUsdc - delta.lossResult.retainedExecFeeUsdc
            - delta.lossResult.collectedExecFeeUsdc;
        uint256 uncollectedSpreadUsdc =
            delta.lossResult.shortfallUsdc - uncollectedExecFeeUsdc - delta.lossResult.badDebtUsdc;
        uint256 claimBadDebtRecoveryUsdc = delta.lossResult.badDebtUsdc - delta.badDebtUsdc;
        uint256 claimSpreadRecoveryUsdc =
            delta.existingTraderClaimConsumedUsdc - delta.traderClaimFeeRecoveryUsdc - claimBadDebtRecoveryUsdc;
        return delta.closeState.frozenSpreadUsdc - (uncollectedSpreadUsdc - claimSpreadRecoveryUsdc);
    }

    /// @notice Applies an open delta to a memory position for risk simulation.
    /// @dev Negative trade cost is a pool-funded rebate and is removed from the effective position-margin basis to avoid
    ///      double counting the rebate in reachable collateral.
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
        projected.margin =
            OpenAccountingLib.effectiveMarginAfterTradeCost(delta.positionMarginAfterOpen, delta.tradeCostUsdc);
        projected.entryPrice = delta.newPosEntryPrice;
        projected.maxProfitUsdc = current.maxProfitUsdc + delta.posMaxProfitIncrease;
        projected.vpiAccrued = current.vpiAccrued + delta.posVpiAccruedDelta;
    }

    /// @notice Projects generic account collateral after pending-carry realization and open trade cost.
    /// @param snap Pre-open account snapshot.
    /// @param pendingCarryUsdc Carry hypothetically realized before the open.
    /// @param tradeCostUsdc Signed VPI plus fee; positive is a debit and negative a rebate.
    /// @return reachableCollateralUsdc Projected collateral reachable for position risk.
    function _postOpenReachableCollateral(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc,
        int256 tradeCostUsdc
    ) internal pure returns (uint256 reachableCollateralUsdc) {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            _accountBucketsAfterOpenCarryRealization(snap, pendingCarryUsdc);
        reachableCollateralUsdc = MarginClearinghouseAccountingLib.getGenericReachableUsdc(buckets);
        if (tradeCostUsdc > 0) {
            uint256 costUsdc = SafeCast.toUint256(tradeCostUsdc);
            reachableCollateralUsdc = reachableCollateralUsdc > costUsdc ? reachableCollateralUsdc - costUsdc : 0;
        } else if (tradeCostUsdc < 0) {
            reachableCollateralUsdc += SafeCast.toUint256(-tradeCostUsdc);
        }
    }

    /// @notice Projects account buckets after fully collectible pending carry.
    /// @dev If carry is zero, no position exists, or carry has a shortfall, the original buckets are returned. The full
    ///      planner treats a shortfall as an open failure before projected risk is calculated.
    /// @param snap Pre-open account and locked-bucket snapshot.
    /// @param pendingCarryUsdc Carry to collect, in 6-decimal USDC units.
    /// @return buckets Projected clearinghouse account buckets.
    function _accountBucketsAfterOpenCarryRealization(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        uint256 pendingCarryUsdc
    ) internal pure returns (IMarginClearinghouse.AccountUsdcBuckets memory buckets) {
        buckets = snap.accountBuckets;
        if (pendingCarryUsdc == 0 || snap.position.size == 0) {
            return buckets;
        }

        MarginClearinghouseAccountingLib.SettlementConsumption memory consumption =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, pendingCarryUsdc);
        if (consumption.uncoveredUsdc > 0) {
            return buckets;
        }

        return MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(
            buckets.settlementBalanceUsdc - consumption.totalConsumedUsdc,
            snap.lockedBuckets.positionMarginUsdc - consumption.activeMarginConsumedUsdc,
            snap.lockedBuckets.committedOrderMarginUsdc,
            snap.lockedBuckets.reservedSettlementUsdc
        );
    }

    /// @notice Expresses positive equity as a percentage of maintenance requirement.
    /// @dev Returns zero when equity is nonpositive or the requirement is zero; otherwise it is not capped at 10,000.
    /// @param equityUsdc Signed projected equity in 6-decimal USDC units.
    /// @param maintenanceMarginUsdc Projected maintenance requirement in 6-decimal USDC units.
    /// @return healthBps Equity divided by maintenance margin, using a 10,000 denominator.
    function _healthBps(
        int256 equityUsdc,
        uint256 maintenanceMarginUsdc
    ) internal pure returns (uint256 healthBps) {
        if (equityUsdc <= 0 || maintenanceMarginUsdc == 0) {
            return 0;
        }
        return (SafeCast.toUint256(equityUsdc) * 10_000) / maintenanceMarginUsdc;
    }

    /// @notice Finds the integer liquidation boundary within the engine price domain.
    /// @dev For BULL positions this returns the lowest liquidatable price; for BEAR positions, the highest. If the
    ///      position is never liquidatable within `[0, capPrice]`, the boolean is false and price is zero.
    /// @param projected Position whose threshold is searched.
    /// @param capPrice Inclusive upper price bound, with 8 decimals.
    /// @param reachableCollateralUsdc Projected generic collateral in 6-decimal USDC units.
    /// @param maintenanceBps Active maintenance or FAD margin rate.
    /// @return hasLiquidationPrice Whether a liquidation boundary exists in the searched domain.
    /// @return liquidationPrice Integer boundary price, with 8 decimals.
    function _findLiquidationPrice(
        CfdTypes.Position memory projected,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 maintenanceBps
    ) internal pure returns (bool hasLiquidationPrice, uint256 liquidationPrice) {
        bool liquidatableAtZero =
            _isProjectedLiquidatable(projected, 0, capPrice, reachableCollateralUsdc, maintenanceBps);
        bool liquidatableAtCap =
            _isProjectedLiquidatable(projected, capPrice, capPrice, reachableCollateralUsdc, maintenanceBps);

        if (projected.side == CfdTypes.Side.BULL) {
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
                if (_isProjectedLiquidatable(projected, mid, capPrice, reachableCollateralUsdc, maintenanceBps)) {
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
            if (_isProjectedLiquidatable(projected, mid, capPrice, reachableCollateralUsdc, maintenanceBps)) {
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
    /// @param reachableCollateralUsdc Projected collateral in 6-decimal USDC units.
    /// @param maintenanceBps Active maintenance or FAD margin rate.
    /// @return Whether equity is at or below the requirement.
    function _isProjectedLiquidatable(
        CfdTypes.Position memory projected,
        uint256 price,
        uint256 capPrice,
        uint256 reachableCollateralUsdc,
        uint256 maintenanceBps
    ) internal pure returns (bool) {
        return PositionRiskAccountingLib.buildPositionRiskStateWithCarry(
            projected, price, capPrice, 0, reachableCollateralUsdc, maintenanceBps
        )
        .liquidatable;
    }

    /// @notice Builds liquidation diagnostics using current account state and supplied hypothetical pool depth.
    /// @param account Account whose position is tested.
    /// @param oraclePrice Candidate liquidation price, with 8 decimals.
    /// @param poolDepthUsdc Pool assets and cash used by the plan, in 6-decimal USDC units.
    /// @return preview Eligibility, settlement routing, claims, bad debt, and projected solvency.
    function _previewLiquidation(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc
    ) internal view returns (ICfdEngineTypes.LiquidationPreview memory preview) {
        uint256 price = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        preview.oraclePrice = price;
        ICfdEnginePlanner planner = engineContract.planner();
        if (_position(account).size == 0) {
            return preview;
        }

        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(account, oraclePrice, poolDepthUsdc, 0);
        _applyLiquidationPreviewForfeiture(account, snap);
        CfdEnginePlanTypes.LiquidationDelta memory delta = planner.planLiquidation(snap, oraclePrice, 0);

        preview.liquidatable = delta.liquidatable;
        preview.reachableCollateralUsdc = delta.liquidationReachableCollateralUsdc;
        preview.pnlUsdc = delta.riskState.unrealizedPnlUsdc;
        preview.equityUsdc = delta.liquidationState.equityUsdc;
        preview.keeperBountyUsdc = delta.keeperBountyUsdc;
        preview.seizedCollateralUsdc = delta.residualPlan.settlementSeizedUsdc;
        preview.settlementRetainedUsdc = delta.settlementRetainedUsdc;
        preview.freshTraderPayoutUsdc = delta.freshTraderPayoutUsdc;
        preview.existingTraderClaimConsumedUsdc = delta.existingTraderClaimConsumedUsdc;
        preview.existingTraderClaimRemainingUsdc = delta.existingTraderClaimRemainingUsdc;
        preview.immediatePayoutUsdc = delta.freshPayoutIsImmediate ? delta.freshTraderPayoutUsdc : 0;
        preview.traderClaimBalanceUsdc = delta.existingTraderClaimRemainingUsdc;
        if (delta.freshPayoutCreatesClaim) {
            preview.traderClaimBalanceUsdc += delta.freshTraderPayoutUsdc;
        }
        preview.badDebtUsdc = delta.badDebtUsdc;
        preview.triggersDegradedMode = delta.solvency.triggersDegradedMode;
        preview.postOpDegradedMode = delta.solvency.postOpDegradedMode;
        preview.effectiveAssetsAfterUsdc = delta.solvency.effectiveAssetsAfterUsdc;
        preview.maxLiabilityAfterUsdc = delta.solvency.maxLiabilityAfterUsdc;
    }

    /// @notice Reconstructs planner input from engine and clearinghouse state plus hypothetical depth and mark context.
    /// @dev `poolDepthUsdc` populates both asset and cash fields. A nonzero stored mark overrides `oraclePrice` in the
    ///      snapshot's contextual last-mark field, and a zero `publishTime` keeps the stored mark time. The current planner
    ///      does not enforce freshness from those context fields. Current carry indexes use actual pool assets rather than
    ///      the hypothetical depth. Margin reservation IDs are not populated by this lens.
    /// @param account Account whose position, buckets, carry, and claims are loaded.
    /// @param oraclePrice Candidate mark price, with 8 decimals.
    /// @param poolDepthUsdc Hypothetical pool assets and cash, in 6-decimal USDC units.
    /// @param publishTime Candidate mark publish time, or zero to retain the stored time.
    /// @return snap Raw planner snapshot.
    function _buildRawSnapshot(
        address account,
        uint256 oraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineTypes.SideState memory bull;
        ICfdEngineTypes.SideState memory bear;
        (bull.maxProfitUsdc, bull.openInterest, bull.entryNotional, bull.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.BULL));
        (bear.maxProfitUsdc, bear.openInterest, bear.entryNotional, bear.totalMargin) =
            engineContract.sides(uint8(CfdTypes.Side.BEAR));
        uint256 lastMarkPrice = engineContract.lastMarkPrice();
        uint64 lastMarkTime = engineContract.lastMarkTime();
        uint256 liveMarkAge = block.timestamp > lastMarkTime ? block.timestamp - lastMarkTime : 0;
        uint256 maxStaleness = engineContract.isOracleFrozen()
            ? engineContract.fadMaxStaleness()
            : engineContract.engineMarkStalenessLimit();

        snap.position = _position(account);
        snap.account = account;
        snap.currentTimestamp = block.timestamp;
        snap.lastMarkPrice = oraclePrice > engineContract.CAP_PRICE() ? engineContract.CAP_PRICE() : oraclePrice;
        if (lastMarkPrice != 0) {
            snap.lastMarkPrice = lastMarkPrice;
        }
        snap.lastMarkTime = publishTime == 0 ? lastMarkTime : publishTime;
        (snap.positionBorrowBaseUsdc, snap.positionLastCarryIndex,) = engineContract.positionCarryState(account);
        snap.bullSide = _sideSnapshot(CfdTypes.Side.BULL, bull);
        snap.bearSide = _sideSnapshot(CfdTypes.Side.BEAR, bear);
        snap.poolAssetsUsdc = poolDepthUsdc;
        snap.poolCashUsdc = poolDepthUsdc;
        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engineContract.clearinghouse());
        snap.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snap.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snap.accumulatedBadDebtUsdc = engineContract.accumulatedBadDebtUsdc();
        snap.unsettledCarryUsdc = engineContract.unsettledCarryUsdc(account);
        snap.totalTraderClaimBalanceUsdc = engineContract.totalTraderClaimBalanceUsdc();
        snap.traderClaimBalanceForAccount = engineContract.traderClaimBalanceUsdc(account);
        snap.degradedMode = engineContract.degradedMode();
        snap.capPrice = engineContract.CAP_PRICE();
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engineContract.executionFeeBps();
        snap.isFadWindow = engineContract.isFadWindow();
        snap.oracleFrozen = engineContract.isOracleFrozen();
        snap.frozenCloseSpreadBps = engineContract.frozenCloseSpreadBps();
        liveMarkAge;
        maxStaleness;
    }

    /// @notice Adjusts a memory snapshot for execution-bounty value forfeited before liquidation settlement.
    /// @dev Does nothing without a configured router or a nonzero bounty reserve. The debit and lock release are capped
    ///      by the corresponding snapshot buckets and no live state is changed.
    /// @param account Account whose router reservation is queried.
    /// @param snap Snapshot mutated in memory before liquidation planning.
    function _applyLiquidationPreviewForfeiture(
        address account,
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) internal view {
        address orderRouter = engineContract.orderRouter();
        if (orderRouter == address(0)) {
            return;
        }

        uint256 forfeitedUsdc = IOrderRouterAccounting(orderRouter).getAccountReservations(account).executionBountyUsdc;
        if (forfeitedUsdc == 0) {
            return;
        }
        if (forfeitedUsdc > snap.accountBuckets.settlementBalanceUsdc) {
            forfeitedUsdc = snap.accountBuckets.settlementBalanceUsdc;
        }
        snap.accountBuckets.settlementBalanceUsdc -= forfeitedUsdc;

        uint256 releasedReserveUsdc = forfeitedUsdc;
        if (releasedReserveUsdc > snap.lockedBuckets.reservedSettlementUsdc) {
            releasedReserveUsdc = snap.lockedBuckets.reservedSettlementUsdc;
        }
        snap.lockedBuckets.reservedSettlementUsdc -= releasedReserveUsdc;
        snap.lockedBuckets.totalLockedMarginUsdc -= releasedReserveUsdc;
        uint256 accountReserveReleaseUsdc = releasedReserveUsdc;
        if (accountReserveReleaseUsdc > snap.accountBuckets.otherLockedMarginUsdc) {
            accountReserveReleaseUsdc = snap.accountBuckets.otherLockedMarginUsdc;
        }
        snap.accountBuckets.otherLockedMarginUsdc -= accountReserveReleaseUsdc;
        snap.accountBuckets.totalLockedMarginUsdc -= accountReserveReleaseUsdc;
        snap.accountBuckets.freeSettlementUsdc = snap.accountBuckets.settlementBalanceUsdc
            > snap.accountBuckets.totalLockedMarginUsdc
            ? snap.accountBuckets.settlementBalanceUsdc - snap.accountBuckets.totalLockedMarginUsdc
            : 0;
    }

    /// @notice Reconstructs the current position plus its separately stored carry timestamp.
    /// @param account Account whose position is loaded.
    /// @return pos Current engine position.
    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
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
            maxProfitUsdc: side.maxProfitUsdc,
            openInterest: side.openInterest,
            entryNotional: side.entryNotional,
            totalMargin: side.totalMargin,
            borrowBaseUsdc: engineContract.sideBorrowBaseUsdc(uint256(sideId)),
            carryIndex: _currentSideCarryIndex(sideId)
        });
    }

    /// @notice Projects a side's cumulative carry index through the current block timestamp.
    /// @dev Utilization uses the live pool's current `totalAssets`, including during hypothetical-depth simulations.
    /// @param side Side whose index is projected.
    /// @return Current cumulative carry index, scaled by 1e18.
    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,) = engineContract.riskParams();
        return PositionRiskAccountingLib.computeCurrentCarryIndex(
            engineContract.sideCarryIndex(sideIndex),
            engineContract.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engineContract.sideBorrowBaseUsdc(sideIndex),
            engineContract.pool().totalAssets(),
            baseCarryBps
        );
    }

    /// @notice Reconstructs the engine's current risk-parameter struct from its public tuple getter.
    /// @return params Current risk, VPI, carry, margin, and bounty settings.
    function _riskParams() internal view returns (CfdTypes.RiskParams memory params) {
        (
            params.vpiFactor,
            params.maxSkewRatio,
            params.maintMarginBps,
            params.initMarginBps,
            params.fadMarginBps,
            params.baseCarryBps,
            params.minBountyUsdc,
            params.bountyBps
        ) = engineContract.riskParams();
    }

}

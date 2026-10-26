// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEngineCollateralSnapshotLib} from "@plether/perps/libraries/CfdEngineCollateralSnapshotLib.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @dev Permissionless Engine read surface used to build policy-evaluation snapshots.
interface ICfdOrderPolicyEngineView {

    function positions(
        address account
    )
        external
        view
        returns (
            uint256 size,
            uint256 margin,
            uint256 entryPrice,
            uint256 maxProfitAssets,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostAssetAtoms(
        address account
    ) external view returns (uint256);

    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseAssets, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    function sides(
        uint256 index
    ) external view returns (uint256 maxProfitAssets, uint256 openInterest, uint256 entryNotional, uint256 totalMargin);

    function sideBorrowBaseAssets(
        uint256 index
    ) external view returns (uint256);

    function sideCarryIndex(
        uint256 index
    ) external view returns (uint256);

    function sideCarryTimestamp(
        uint256 index
    ) external view returns (uint64);

    function planner() external view returns (address);

    function pool() external view returns (address);

    function clearinghouse() external view returns (address);

    function orderRouter() external view returns (address);

    function lastMarkPrice() external view returns (uint256);

    function lastMarkTime() external view returns (uint64);

    function riskParams() external view returns (CfdTypes.RiskParams memory);

    function traderClaimBalanceAssets(
        address account
    ) external view returns (uint256);

    function unsettledCarryAssets(
        address account
    ) external view returns (uint256);

    function totalTraderClaimBalanceAssets() external view returns (uint256);

    function degradedMode() external view returns (bool);

    function CAP_PRICE() external view returns (uint256);

    function executionFeeBps() external view returns (uint256);
    function settlementBufferBps() external view returns (uint256);

    function isFadWindow() external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function frozenCloseSpreadBps() external view returns (uint256);

}

/// @title CfdOrderPolicyEvaluatorBase
/// @notice Shared policy coordinator that derives a plan or evaluates a caller-supplied plan.
/// @dev Provides internal snapshot, planner-call, and bound-check helpers for the public evaluator and close preview.
///      `_assessOrder` reads the supplied Engine and its dependencies and invokes one open or close planner. Its
///      snapshot reads the Engine's live `settlementBufferBps`, so planning enforces the configured buffer.
///      Pure helpers accept caller-supplied snapshots and deltas for deterministic simulation. Bounds follow
///      `ConstraintKind` order and equality passes. Full closes skip post-position equity and leverage bounds.
abstract contract CfdOrderPolicyEvaluatorBase {

    uint256 private constant BPS = 10_000;

    function _settlementAfterBounty(
        uint256 settlementAssets,
        uint256 bountyAssets,
        bool bountyReturnsToAccount
    ) private pure returns (uint256) {
        if (settlementAssets < bountyAssets) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking(
                settlementAssets, bountyAssets
            );
        }
        return bountyReturnsToAccount ? settlementAssets : settlementAssets - bountyAssets;
    }

    struct AssessmentContext {
        address engineAddress;
        address executor;
        uint256 currentOraclePrice;
        uint256 poolDepthAssets;
        uint256 executionBountyAssets;
    }

    function _assessOrder(
        AssessmentContext memory context,
        CfdTypes.Order memory order,
        OrderV3Types.ExecutionBounds memory bounds
    ) internal view returns (OrderV3Types.ExecutionAssessment memory assessment) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(context.engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, context.poolDepthAssets);
        return _assessSnapshot(context, order, bounds, planner, snapshot);
    }

    function _assessSnapshot(
        AssessmentContext memory context,
        CfdTypes.Order memory order,
        OrderV3Types.ExecutionBounds memory bounds,
        ICfdEnginePlanner planner,
        CfdEnginePlanTypes.RawSnapshot memory snapshot
    ) internal view returns (OrderV3Types.ExecutionAssessment memory) {
        bool bountyReturnsToAccount = context.executor == order.account;
        OrderV3Types.ExecutionBounds memory boundsCopy = bounds;

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory closeDelta =
                planner.planClose(snapshot, order, context.currentOraclePrice);
            return
                _evaluateClose(snapshot, closeDelta, boundsCopy, context.executionBountyAssets, bountyReturnsToAccount);
        }

        CfdEnginePlanTypes.OpenDelta memory openDelta = planner.planOpen(snapshot, order, context.currentOraclePrice);
        return _evaluateOpen(snapshot, openDelta, boundsCopy, context.executionBountyAssets, bountyReturnsToAccount);
    }

    function _evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.OpenDelta memory delta,
        OrderV3Types.ExecutionBounds memory bounds,
        uint256 executionBountyAssets,
        bool bountyReturnsToAccount
    ) internal pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        _requireValidOpenDelta(delta);
        assessment.mode = _requireAllowedMode(snapshot, bounds.allowedExecutionModes);
        assessment =
            _buildOpenAssessment(snapshot, delta, executionBountyAssets, bountyReturnsToAccount, assessment.mode);
        _enforceBounds(assessment, bounds, executionBountyAssets, false);
    }

    function _evaluateClose(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.CloseDelta memory delta,
        OrderV3Types.ExecutionBounds memory bounds,
        uint256 executionBountyAssets,
        bool bountyReturnsToAccount
    ) internal pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        _requireValidCloseDelta(delta);
        assessment.mode = _requireAllowedMode(snapshot, bounds.allowedExecutionModes);
        assessment =
            _buildCloseAssessment(snapshot, delta, executionBountyAssets, bountyReturnsToAccount, assessment.mode);
        _enforceBounds(assessment, bounds, executionBountyAssets, delta.deletePosition);
    }

    function _buildRawSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        address account,
        uint256 poolDepthAssets
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        return _buildRawSnapshot(engine, planner, account, poolDepthAssets, IHousePool(engine.pool()).totalAssets());
    }

    /// @dev Authoritative assessment already read canonical pool cash. Reuse that observation; simulation callers
    ///      may supply a different pricing depth and must use the four-argument overload to read historical carry cash.
    function _buildRawSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        address account,
        uint256 poolDepthAssets,
        uint256 poolCashAssets
    ) internal view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        (
            snapshot.position.size,
            snapshot.position.margin,
            snapshot.position.entryPrice,
            snapshot.position.maxProfitAssets,
            snapshot.position.side,
            snapshot.position.lastUpdateTime,
            snapshot.position.vpiAccrued
        ) = engine.positions(account);
        snapshot.positionEntryCostAssetAtoms = engine.positionEntryCostAssetAtoms(account);
        (snapshot.positionBorrowBaseAssets, snapshot.positionLastCarryIndex, snapshot.position.lastCarryTimestamp) =
            engine.positionCarryState(account);

        snapshot.account = account;
        snapshot.currentTimestamp = block.timestamp;
        snapshot.lastMarkPrice = engine.lastMarkPrice();
        snapshot.lastMarkTime = engine.lastMarkTime();
        snapshot.riskParams = engine.riskParams();

        snapshot.poolCashAssets = poolCashAssets;
        IHousePool pool = IHousePool(engine.pool());
        snapshot.poolAdditionalReservedAssets =
            pool.pendingRecapitalizationAssets() + pool.pendingTradingRevenueAssets() + pool.unassignedAssets();
        snapshot.poolQueuesTradingRevenue = pool.seniorPrincipal() == 0 && pool.juniorPrincipal() == 0;
        snapshot.totalTraderClaimBalanceAssets = engine.totalTraderClaimBalanceAssets();
        uint256 carryDepthAssets = PositionRiskAccountingLib.computeNetPoolDepthAssets(
            snapshot.poolCashAssets, snapshot.totalTraderClaimBalanceAssets
        );
        snapshot.longSide =
            _sideSnapshot(engine, planner, CfdTypes.Side.LONG, carryDepthAssets, snapshot.riskParams.baseCarryBps);
        snapshot.shortSide =
            _sideSnapshot(engine, planner, CfdTypes.Side.SHORT, carryDepthAssets, snapshot.riskParams.baseCarryBps);
        snapshot.poolAssets = poolDepthAssets;

        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engine.clearinghouse());
        CfdEngineCollateralSnapshotLib.load(snapshot, clearinghouse, account, false);

        snapshot.unsettledCarryAssets = engine.unsettledCarryAssets(account);
        snapshot.traderClaimBalanceForAccount = engine.traderClaimBalanceAssets(account);
        snapshot.degradedMode = engine.degradedMode();
        snapshot.capPrice = engine.CAP_PRICE();
        snapshot.executionFeeBps = engine.executionFeeBps();
        snapshot.settlementBufferBps = engine.settlementBufferBps();
        snapshot.isFadWindow = engine.isFadWindow();
        snapshot.oracleFrozen = engine.isOracleFrozen();
        snapshot.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
    }

    function _sideSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        CfdTypes.Side side,
        uint256 poolDepthAssets,
        uint256 baseCarryBps
    ) private view returns (CfdEnginePlanTypes.SideSnapshot memory snapshot) {
        uint256 index = uint256(side);
        (snapshot.maxProfitAssets, snapshot.openInterest, snapshot.entryNotional, snapshot.totalMargin) =
            engine.sides(index);
        snapshot.borrowBaseAssets = engine.sideBorrowBaseAssets(index);
        snapshot.carryIndex = planner.computeCurrentCarryIndex(
            engine.sideCarryIndex(index),
            engine.sideCarryTimestamp(index),
            block.timestamp,
            snapshot.borrowBaseAssets,
            poolDepthAssets,
            baseCarryBps
        );
    }

    function _requireValidOpenDelta(
        CfdEnginePlanTypes.OpenDelta memory delta
    ) private pure {
        if (delta.revertCode != CfdEnginePlanTypes.OpenRevertCode.OK) {
            revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
                CfdEnginePlanLib.getExecutionFailurePolicyCategory(delta.revertCode), uint8(delta.revertCode), false
            );
        }
        if (!delta.valid) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InvalidPlannerResult();
        }
    }

    function _requireValidCloseDelta(
        CfdEnginePlanTypes.CloseDelta memory delta
    ) private pure {
        if (delta.revertCode != CfdEnginePlanTypes.CloseRevertCode.OK) {
            revert ICfdEngineTypes.CfdEngine__TypedOrderFailure(
                CfdEnginePlanLib.getExecutionFailurePolicyCategory(delta.revertCode), uint8(delta.revertCode), true
            );
        }
        if (!delta.valid) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InvalidPlannerResult();
        }
    }

    function _requireAllowedMode(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint8 allowedExecutionModes
    ) private pure returns (OrderV3Types.ExecutionMode mode) {
        if (snapshot.oracleFrozen) {
            mode = OrderV3Types.ExecutionMode.Frozen;
        } else if (snapshot.isFadWindow) {
            mode = OrderV3Types.ExecutionMode.Fad;
        } else {
            mode = OrderV3Types.ExecutionMode.Live;
        }

        uint8 modeBit = mode == OrderV3Types.ExecutionMode.Live ? 1 : mode == OrderV3Types.ExecutionMode.Fad ? 2 : 4;
        if (allowedExecutionModes & modeBit == 0) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed(
                mode, allowedExecutionModes
            );
        }
    }

    function _buildOpenAssessment(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint256 executionBountyAssets,
        bool bountyReturnsToAccount,
        OrderV3Types.ExecutionMode mode
    ) private pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        uint256 positiveTradeCostAssets = 0;
        uint256 tradeRebateAssets = 0;
        if (delta.tradeCostAssets >= 0) {
            positiveTradeCostAssets = uint256(delta.tradeCostAssets);
        } else {
            tradeRebateAssets = _negativeMagnitude(delta.tradeCostAssets);
        }

        // A zero-size snapshot deliberately does not realize an inconsistent stale carry value during Engine apply.
        // slither-disable-next-line incorrect-equality
        uint256 realizedCarryAssets = snapshot.position.size == 0 ? 0 : delta.pendingCarryAssets;

        assessment.mode = mode;
        assessment.executionNotionalAssets = delta.openState.notionalAssets;
        assessment.grossAccountDebitAssets = realizedCarryAssets + positiveTradeCostAssets + executionBountyAssets;
        assessment.actionChargeAssessedAssets = _netOpenActionCharge(realizedCarryAssets, delta.tradeCostAssets);
        assessment.actionChargeCollectedAssets = realizedCarryAssets + positiveTradeCostAssets;
        assessment.explicitFeesAssets = delta.executionFeeAssets;
        assessment.preSettlementBalanceAssets = snapshot.accountBuckets.settlementBalanceAssets;

        uint256 postSettlementBalanceAssets = assessment.preSettlementBalanceAssets - realizedCarryAssets;
        if (positiveTradeCostAssets > 0) {
            postSettlementBalanceAssets -= positiveTradeCostAssets;
        } else if (tradeRebateAssets > 0) {
            postSettlementBalanceAssets += tradeRebateAssets;
        }
        assessment.postSettlementBalanceAssets =
            _settlementAfterBounty(postSettlementBalanceAssets, executionBountyAssets, bountyReturnsToAccount);

        assessment.vpiAssets = delta.posVpiAccruedDelta;
        assessment.carryAssets = realizedCarryAssets;
        assessment.executionFeeAssets = delta.executionFeeAssets;
        assessment.preTraderClaimAssets = snapshot.traderClaimBalanceForAccount;
        assessment.postTraderClaimAssets = snapshot.traderClaimBalanceForAccount;
        assessment.postPositionSize = delta.newPosSize;
        assessment.postPositionMarginAssets = delta.positionMarginAfterOpen;

        CfdTypes.Position memory projectedPosition = snapshot.position;
        projectedPosition.side = delta.posSide;
        projectedPosition.size = delta.newPosSize;
        projectedPosition.margin = delta.positionMarginAfterOpen;
        projectedPosition.entryPrice = delta.newPosEntryPrice;
        projectedPosition.maxProfitAssets = snapshot.position.maxProfitAssets + delta.posMaxProfitIncrease;
        projectedPosition.vpiAccrued = snapshot.position.vpiAccrued + delta.posVpiAccruedDelta;

        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.newPosEntryCostAssetAtoms,
            delta.price,
            snapshot.capPrice,
            assessment.postPositionMarginAssets + assessment.postTraderClaimAssets,
            0
        );
        assessment.postPositionEquityAssets = riskState.equityAssets;
        assessment.postLeverageBps = _postLeverageBps(riskState.currentNotionalAssets, riskState.equityAssets);
    }

    function _buildCloseAssessment(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint256 executionBountyAssets,
        bool bountyReturnsToAccount,
        OrderV3Types.ExecutionMode mode
    ) private pure returns (OrderV3Types.ExecutionAssessment memory assessment) {
        assessment.mode = mode;
        assessment.close = OrderV3Types.CloseEconomics({
            postFreeSettlementAssets: 0,
            safeMarginReleaseAssets: delta.safeMarginReleaseAssets,
            actionChargeFromReleasedMarginAssets: delta.actionChargeFromReleasedMarginAssets,
            netReleasedMarginAssets: delta.netReleasedMarginAssets,
            priceLossAssets: delta.priceLossAssets,
            pricePnlClaimConsumedAssets: delta.pricePnlClaimConsumedAssets,
            pricePnlPledgeConsumedAssets: delta.pricePnlPledgeConsumedAssets,
            priceLossWrittenOffAssets: delta.priceLossWrittenOffAssets,
            actionChargeWithheldAssets: delta.actionChargeWithheldAssets,
            actionChargeWaivedAssets: delta.actionChargeWaivedAssets
        });
        assessment.executionNotionalAssets = CfdMath.sizeToLots(delta.sizeDelta) * delta.price;
        assessment.grossAccountDebitAssets = delta.pricePnlClaimConsumedAssets + delta.pricePnlPledgeConsumedAssets
            + delta.realizedCarryAssets + delta.actionChargeCollectedAssets + executionBountyAssets;
        assessment.actionChargeAssessedAssets = _netOpenActionCharge(
            delta.realizedCarryAssets, int256(delta.actionChargeAssessedAssets) - int256(delta.actionRebateAssets)
        );
        assessment.actionChargeCollectedAssets = delta.realizedCarryAssets + delta.actionChargeCollectedAssets;
        assessment.explicitFeesAssets = delta.closeState.executionFeeAssets + delta.closeState.frozenSpreadAssets;
        assessment.preSettlementBalanceAssets = snapshot.accountBuckets.settlementBalanceAssets;

        uint256 postSettlementBalanceAssets = assessment.preSettlementBalanceAssets - delta.realizedCarryAssets
            - delta.pricePnlPledgeConsumedAssets - delta.actionChargeCollectedAssets;
        if (delta.pricePayoutIsImmediate) {
            postSettlementBalanceAssets += delta.pricePayoutAssets;
        }
        postSettlementBalanceAssets += delta.actionRebatePaidAssets;
        assessment.postSettlementBalanceAssets =
            _settlementAfterBounty(postSettlementBalanceAssets, executionBountyAssets, bountyReturnsToAccount);

        assessment.realizedPnlAssets = delta.realizedPnlAssets;
        assessment.vpiAssets = delta.closeState.vpiDeltaAssets;
        assessment.carryAssets = delta.pendingCarryAssets;
        assessment.executionFeeAssets = delta.closeState.executionFeeAssets;
        assessment.frozenSpreadAssets = delta.closeState.frozenSpreadAssets;
        assessment.preTraderClaimAssets = snapshot.traderClaimBalanceForAccount;
        assessment.postTraderClaimAssets = snapshot.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedAssets;
        if (delta.pricePayoutCreatesClaim) {
            assessment.postTraderClaimAssets += delta.pricePayoutAssets;
        }
        assessment.postPositionSize = delta.closeState.remainingSize;
        assessment.postPositionMarginAssets = delta.posMarginAfter;
        uint256 actionReserveAfter = snapshot.actionReserveAssets - delta.actionReserveConsumedAssets
            - (delta.vpiRebateReserveBeforeAssets - delta.vpiRebateReserveAfterAssets);
        // Pure simulation may omit the reservation; canonical close assessment always authenticates it.
        actionReserveAfter = actionReserveAfter > executionBountyAssets ? actionReserveAfter - executionBountyAssets : 0;
        uint256 lockedAfter = delta.posMarginAfter + snapshot.liquidationReserveAssets
            - delta.liquidationReserveReleaseAssets + snapshot.lockedBuckets.committedOrderMarginAssets
            - delta.actionCommittedMarginConsumedAssets + actionReserveAfter;
        assessment.close.postFreeSettlementAssets = assessment.postSettlementBalanceAssets > lockedAfter
            ? assessment.postSettlementBalanceAssets - lockedAfter
            : 0;

        if (delta.deletePosition) {
            return assessment;
        }

        CfdTypes.Position memory projectedPosition = snapshot.position;
        projectedPosition.size = delta.closeState.remainingSize;
        projectedPosition.margin = delta.posMarginAfter;
        projectedPosition.entryPrice = delta.posEntryPriceAfter;
        projectedPosition.maxProfitAssets = snapshot.position.maxProfitAssets - delta.posMaxProfitReduction;
        projectedPosition.vpiAccrued = snapshot.position.vpiAccrued - delta.posVpiAccruedReduction;

        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.posEntryCostAfterAssetAtoms,
            delta.price,
            snapshot.capPrice,
            assessment.postPositionMarginAssets + assessment.postTraderClaimAssets,
            0
        );
        assessment.postPositionEquityAssets = riskState.equityAssets;
        assessment.postLeverageBps = _postLeverageBps(riskState.currentNotionalAssets, riskState.equityAssets);
    }

    function _includeCommitment(
        OrderV3Types.ExecutionAssessment memory assessment,
        CfdEnginePlanTypes.CloseCommitment memory effects,
        OrderV3Types.ExecutionBounds memory bounds,
        uint256 bounty
    ) internal pure {
        assessment.grossAccountDebitAssets += effects.carryCollectedAssets;
        assessment.actionChargeAssessedAssets += effects.carryCollectedAssets;
        assessment.actionChargeCollectedAssets += effects.carryCollectedAssets;
        assessment.carryAssets += effects.carryCollectedAssets;
        // Zero residual size identifies a full close; strict partial bounds apply to every positive remainder.
        // slither-disable-next-line incorrect-equality
        _enforceBounds(assessment, bounds, bounty, assessment.postPositionSize == 0);
    }

    /// @dev Bound precedence is deliberately identical to the order of `ConstraintKind` values.
    function _enforceBounds(
        OrderV3Types.ExecutionAssessment memory assessment,
        OrderV3Types.ExecutionBounds memory bounds,
        uint256 executionBountyAssets,
        bool fullClose
    ) private pure {
        _requireMaximum(
            OrderV3Types.ConstraintKind.ExecutionBounty, executionBountyAssets, bounds.maxExecutionBountyAssets
        );
        _requireMaximum(
            OrderV3Types.ConstraintKind.ExecutionNotional,
            assessment.executionNotionalAssets,
            bounds.maxExecutionNotionalAssets
        );
        _requireMaximum(
            OrderV3Types.ConstraintKind.GrossAccountDebit,
            assessment.grossAccountDebitAssets,
            bounds.maxGrossAccountDebitAssets
        );
        _requireMaximum(
            OrderV3Types.ConstraintKind.ActionCharge,
            assessment.actionChargeAssessedAssets,
            bounds.maxActionChargeAssets
        );
        _requireMaximum(
            OrderV3Types.ConstraintKind.ExplicitFees, assessment.explicitFeesAssets, bounds.maxExplicitFeesAssets
        );
        _requireMaximum(
            OrderV3Types.ConstraintKind.PostPositionSize, assessment.postPositionSize, bounds.maxPostPositionSize
        );
        _requireMinimum(
            OrderV3Types.ConstraintKind.PostSettlementBalance,
            assessment.postSettlementBalanceAssets,
            bounds.minPostSettlementBalanceAssets
        );

        if (fullClose) {
            return;
        }

        uint256 normalizedEquityAssets =
            assessment.postPositionEquityAssets > 0 ? uint256(assessment.postPositionEquityAssets) : 0;
        if (assessment.postPositionEquityAssets < 0 || normalizedEquityAssets < bounds.minPostPositionEquityAssets) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation(
                OrderV3Types.ConstraintKind.PostPositionEquity,
                normalizedEquityAssets,
                bounds.minPostPositionEquityAssets
            );
        }
        _requireMaximum(OrderV3Types.ConstraintKind.PostLeverage, assessment.postLeverageBps, bounds.maxPostLeverageBps);
    }

    function _requireMaximum(
        OrderV3Types.ConstraintKind constraint,
        uint256 actual,
        uint256 limit
    ) private pure {
        if (actual > limit) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation(constraint, actual, limit);
        }
    }

    function _requireMinimum(
        OrderV3Types.ConstraintKind constraint,
        uint256 actual,
        uint256 limit
    ) private pure {
        if (actual < limit) {
            revert ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation(constraint, actual, limit);
        }
    }

    function _netOpenActionCharge(
        uint256 pendingCarryAssets,
        int256 tradeCostAssets
    ) private pure returns (uint256 actionChargeAssets) {
        if (tradeCostAssets >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return pendingCarryAssets + uint256(tradeCostAssets);
        }
        uint256 rebateAssets = _negativeMagnitude(tradeCostAssets);
        return pendingCarryAssets > rebateAssets ? pendingCarryAssets - rebateAssets : 0;
    }

    function _negativeMagnitude(
        int256 value
    ) private pure returns (uint256 magnitude) {
        return uint256(-(value + 1)) + 1;
    }

    function _postLeverageBps(
        uint256 postNotionalAssets,
        int256 postEquityAssets
    ) private pure returns (uint256 leverageBps) {
        if (postEquityAssets <= 0) {
            return type(uint256).max;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(postNotionalAssets, BPS, uint256(postEquityAssets), Math.Rounding.Ceil);
    }

}

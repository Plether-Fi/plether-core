// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";

/// @dev Exact permissionless Engine read surface needed to reproduce `CfdEngineSettlementSidecar.buildRawSnapshot`.
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
            uint256 maxProfitUsdc,
            CfdTypes.Side side,
            uint64 lastUpdateTime,
            int256 vpiAccrued
        );

    function positionEntryCostUsdcAtoms(
        address account
    ) external view returns (uint256);

    function positionCarryState(
        address account
    ) external view returns (uint256 borrowBaseUsdc, uint256 lastCarryIndex, uint64 lastCarryTimestamp);

    function sides(
        uint256 index
    ) external view returns (uint256 maxProfitUsdc, uint256 openInterest, uint256 entryNotional, uint256 totalMargin);

    function sideBorrowBaseUsdc(
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

    function traderClaimBalanceUsdc(
        address account
    ) external view returns (uint256);

    function unsettledCarryUsdc(
        address account
    ) external view returns (uint256);

    function totalTraderClaimBalanceUsdc() external view returns (uint256);

    function degradedMode() external view returns (bool);

    function CAP_PRICE() external view returns (uint256);

    function executionFeeBps() external view returns (uint256);

    function isFadWindow() external view returns (bool);

    function isOracleFrozen() external view returns (bool);

    function frozenCloseSpreadBps() external view returns (uint256);

}

/// @title CfdOrderPolicyEvaluator
/// @notice Stateless policy coordinator that derives an authoritative plan or evaluates a caller-supplied plan.
/// @dev `assessOrder` reads only the supplied Engine and its configured dependencies, reproduces the settlement
///      sidecar snapshot, and invokes exactly one open or close planning entrypoint. The pure entrypoints remain useful
///      for deterministic simulation and parity testing. Bounds are evaluated in `ConstraintKind` order; equality
///      passes. A full close checks every non-position bound but skips equity and leverage because no position remains.
contract CfdOrderPolicyEvaluator is ICfdOrderPolicyEvaluator {

    uint256 private constant BPS = 10_000;

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function assessOrder(
        address engineAddress,
        CfdTypes.Order calldata order,
        address executor,
        uint256 currentOraclePrice,
        uint256 poolDepthUsdc,
        uint64 publishTime,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external view returns (OrderV2Types.ExecutionAssessment memory assessment) {
        ICfdOrderPolicyEngineView engine = ICfdOrderPolicyEngineView(engineAddress);
        ICfdEnginePlanner planner = ICfdEnginePlanner(engine.planner());
        CfdEnginePlanTypes.RawSnapshot memory snapshot =
            _buildRawSnapshot(engine, planner, order.account, poolDepthUsdc);
        bool bountyReturnsToAccount = executor == order.account;
        OrderV2Types.ExecutionBounds memory boundsCopy = bounds;

        if (order.isClose) {
            CfdEnginePlanTypes.CloseDelta memory closeDelta =
                planner.planClose(snapshot, order, currentOraclePrice, publishTime);
            return _evaluateClose(snapshot, closeDelta, boundsCopy, executionBountyUsdc, bountyReturnsToAccount);
        }

        CfdEnginePlanTypes.OpenDelta memory openDelta =
            planner.planOpen(snapshot, order, currentOraclePrice, publishTime);
        return _evaluateOpen(snapshot, openDelta, boundsCopy, executionBountyUsdc, bountyReturnsToAccount);
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.OpenDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.OpenDelta memory deltaCopy = delta;
        OrderV2Types.ExecutionBounds memory boundsCopy = bounds;
        return _evaluateOpen(snapshotCopy, deltaCopy, boundsCopy, executionBountyUsdc, false);
    }

    /// @inheritdoc ICfdOrderPolicyEvaluator
    function evaluateClose(
        CfdEnginePlanTypes.RawSnapshot calldata snapshot,
        CfdEnginePlanTypes.CloseDelta calldata delta,
        OrderV2Types.ExecutionBounds calldata bounds,
        uint256 executionBountyUsdc
    ) external pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        CfdEnginePlanTypes.RawSnapshot memory snapshotCopy = snapshot;
        CfdEnginePlanTypes.CloseDelta memory deltaCopy = delta;
        OrderV2Types.ExecutionBounds memory boundsCopy = bounds;
        return _evaluateClose(snapshotCopy, deltaCopy, boundsCopy, executionBountyUsdc, false);
    }

    function _evaluateOpen(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.OpenDelta memory delta,
        OrderV2Types.ExecutionBounds memory bounds,
        uint256 executionBountyUsdc,
        bool bountyReturnsToAccount
    ) private pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        _requireValidOpenDelta(delta);
        assessment.mode = _requireAllowedMode(snapshot, bounds.allowedExecutionModes);
        assessment = _buildOpenAssessment(snapshot, delta, executionBountyUsdc, bountyReturnsToAccount, assessment.mode);
        _enforceBounds(assessment, bounds, executionBountyUsdc, false);
    }

    function _evaluateClose(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.CloseDelta memory delta,
        OrderV2Types.ExecutionBounds memory bounds,
        uint256 executionBountyUsdc,
        bool bountyReturnsToAccount
    ) private pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        _requireValidCloseDelta(delta);
        assessment.mode = _requireAllowedMode(snapshot, bounds.allowedExecutionModes);
        assessment =
            _buildCloseAssessment(snapshot, delta, executionBountyUsdc, bountyReturnsToAccount, assessment.mode);
        _enforceBounds(assessment, bounds, executionBountyUsdc, delta.deletePosition);
    }

    function _buildRawSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        address account,
        uint256 poolDepthUsdc
    ) private view returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        (
            snapshot.position.size,
            snapshot.position.margin,
            snapshot.position.entryPrice,
            snapshot.position.maxProfitUsdc,
            snapshot.position.side,
            snapshot.position.lastUpdateTime,
            snapshot.position.vpiAccrued
        ) = engine.positions(account);
        snapshot.positionEntryCostUsdcAtoms = engine.positionEntryCostUsdcAtoms(account);
        (snapshot.positionBorrowBaseUsdc, snapshot.positionLastCarryIndex, snapshot.position.lastCarryTimestamp) =
            engine.positionCarryState(account);

        snapshot.account = account;
        snapshot.currentTimestamp = block.timestamp;
        snapshot.lastMarkPrice = engine.lastMarkPrice();
        snapshot.lastMarkTime = engine.lastMarkTime();
        snapshot.riskParams = engine.riskParams();

        snapshot.bullSide =
            _sideSnapshot(engine, planner, CfdTypes.Side.BULL, poolDepthUsdc, snapshot.riskParams.baseCarryBps);
        snapshot.bearSide =
            _sideSnapshot(engine, planner, CfdTypes.Side.BEAR, poolDepthUsdc, snapshot.riskParams.baseCarryBps);
        snapshot.poolAssetsUsdc = poolDepthUsdc;
        snapshot.poolCashUsdc = IHousePool(engine.pool()).totalAssets();

        IMarginClearinghouse clearinghouse = IMarginClearinghouse(engine.clearinghouse());
        snapshot.accountBuckets = clearinghouse.getAccountUsdcBuckets(account);
        snapshot.lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        snapshot.liquidationReserveUsdc = clearinghouse.liquidationReserveUsdc(account);
        snapshot.actionReserveUsdc = clearinghouse.actionReserveUsdc(account);
        snapshot.vpiRebateReserveUsdc = clearinghouse.vpiRebateReserveUsdc(account);
        address orderRouter = engine.orderRouter();
        if (orderRouter != address(0)) {
            snapshot.protectedExecutionBountyUsdc =
            IOrderRouterAccounting(orderRouter).getAccountReservations(account).executionBountyUsdc;
        }
        // The clearinghouse bucket is the canonical active-margin source even if the Engine tuple was stale.
        snapshot.position.margin = snapshot.lockedBuckets.positionMarginUsdc;

        snapshot.unsettledCarryUsdc = engine.unsettledCarryUsdc(account);
        snapshot.totalTraderClaimBalanceUsdc = engine.totalTraderClaimBalanceUsdc();
        snapshot.traderClaimBalanceForAccount = engine.traderClaimBalanceUsdc(account);
        snapshot.degradedMode = engine.degradedMode();
        snapshot.capPrice = engine.CAP_PRICE();
        snapshot.executionFeeBps = engine.executionFeeBps();
        snapshot.isFadWindow = engine.isFadWindow();
        snapshot.oracleFrozen = engine.isOracleFrozen();
        snapshot.frozenCloseSpreadBps = engine.frozenCloseSpreadBps();
    }

    function _sideSnapshot(
        ICfdOrderPolicyEngineView engine,
        ICfdEnginePlanner planner,
        CfdTypes.Side side,
        uint256 poolDepthUsdc,
        uint256 baseCarryBps
    ) private view returns (CfdEnginePlanTypes.SideSnapshot memory snapshot) {
        uint256 index = uint256(side);
        (snapshot.maxProfitUsdc, snapshot.openInterest, snapshot.entryNotional, snapshot.totalMargin) =
            engine.sides(index);
        snapshot.borrowBaseUsdc = engine.sideBorrowBaseUsdc(index);
        snapshot.carryIndex = planner.computeCurrentCarryIndex(
            engine.sideCarryIndex(index),
            engine.sideCarryTimestamp(index),
            block.timestamp,
            snapshot.borrowBaseUsdc,
            poolDepthUsdc,
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
            revert CfdOrderPolicyEvaluator__InvalidPlannerResult();
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
            revert CfdOrderPolicyEvaluator__InvalidPlannerResult();
        }
    }

    function _requireAllowedMode(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        uint8 allowedExecutionModes
    ) private pure returns (OrderV2Types.ExecutionMode mode) {
        if (snapshot.oracleFrozen) {
            mode = OrderV2Types.ExecutionMode.Frozen;
        } else if (snapshot.isFadWindow) {
            mode = OrderV2Types.ExecutionMode.Fad;
        } else {
            mode = OrderV2Types.ExecutionMode.Live;
        }

        uint8 modeBit = mode == OrderV2Types.ExecutionMode.Live ? 1 : mode == OrderV2Types.ExecutionMode.Fad ? 2 : 4;
        if (allowedExecutionModes & modeBit == 0) {
            revert CfdOrderPolicyEvaluator__ExecutionModeDisallowed(mode, allowedExecutionModes);
        }
    }

    function _buildOpenAssessment(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.OpenDelta memory delta,
        uint256 executionBountyUsdc,
        bool bountyReturnsToAccount,
        OrderV2Types.ExecutionMode mode
    ) private pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        uint256 positiveTradeCostUsdc = 0;
        uint256 tradeRebateUsdc = 0;
        if (delta.tradeCostUsdc >= 0) {
            positiveTradeCostUsdc = uint256(delta.tradeCostUsdc);
        } else {
            tradeRebateUsdc = _negativeMagnitude(delta.tradeCostUsdc);
        }

        // A zero-size snapshot deliberately does not realize an inconsistent stale carry value during Engine apply.
        // slither-disable-next-line incorrect-equality
        uint256 realizedCarryUsdc = snapshot.position.size == 0 ? 0 : delta.pendingCarryUsdc;

        assessment.mode = mode;
        assessment.executionNotionalUsdc = delta.openState.notionalUsdc;
        assessment.grossAccountDebitUsdc = realizedCarryUsdc + positiveTradeCostUsdc + executionBountyUsdc;
        assessment.actionChargeAssessedUsdc = _netOpenActionCharge(realizedCarryUsdc, delta.tradeCostUsdc);
        assessment.actionChargeCollectedUsdc = realizedCarryUsdc + positiveTradeCostUsdc;
        assessment.explicitFeesUsdc = delta.executionFeeUsdc;
        assessment.preSettlementBalanceUsdc = snapshot.accountBuckets.settlementBalanceUsdc;

        uint256 postSettlementBalanceUsdc = assessment.preSettlementBalanceUsdc - realizedCarryUsdc;
        if (positiveTradeCostUsdc > 0) {
            postSettlementBalanceUsdc -= positiveTradeCostUsdc;
        } else if (tradeRebateUsdc > 0) {
            postSettlementBalanceUsdc += tradeRebateUsdc;
        }
        assessment.postSettlementBalanceUsdc = postSettlementBalanceUsdc - executionBountyUsdc;
        if (bountyReturnsToAccount) {
            assessment.postSettlementBalanceUsdc += executionBountyUsdc;
        }

        assessment.vpiUsdc = delta.posVpiAccruedDelta;
        assessment.carryUsdc = realizedCarryUsdc;
        assessment.executionFeeUsdc = delta.executionFeeUsdc;
        assessment.preTraderClaimUsdc = snapshot.traderClaimBalanceForAccount;
        assessment.postTraderClaimUsdc = snapshot.traderClaimBalanceForAccount;
        assessment.postPositionSize = delta.newPosSize;
        assessment.postPositionMarginUsdc = delta.positionMarginAfterOpen;

        CfdTypes.Position memory projectedPosition = snapshot.position;
        projectedPosition.side = delta.posSide;
        projectedPosition.size = delta.newPosSize;
        projectedPosition.margin = delta.positionMarginAfterOpen;
        projectedPosition.entryPrice = delta.newPosEntryPrice;
        projectedPosition.maxProfitUsdc = snapshot.position.maxProfitUsdc + delta.posMaxProfitIncrease;
        projectedPosition.vpiAccrued = snapshot.position.vpiAccrued + delta.posVpiAccruedDelta;

        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.newPosEntryCostUsdcAtoms,
            delta.price,
            snapshot.capPrice,
            assessment.postPositionMarginUsdc + assessment.postTraderClaimUsdc,
            0
        );
        assessment.postPositionEquityUsdc = riskState.equityUsdc;
        assessment.postLeverageBps = _postLeverageBps(riskState.currentNotionalUsdc, riskState.equityUsdc);
    }

    function _buildCloseAssessment(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.CloseDelta memory delta,
        uint256 executionBountyUsdc,
        bool bountyReturnsToAccount,
        OrderV2Types.ExecutionMode mode
    ) private pure returns (OrderV2Types.ExecutionAssessment memory assessment) {
        assessment.mode = mode;
        assessment.executionNotionalUsdc = CfdMath.sizeToLots(delta.sizeDelta) * delta.price;
        assessment.grossAccountDebitUsdc = delta.pricePnlClaimConsumedUsdc + delta.pricePnlPledgeConsumedUsdc
            + delta.actionChargeCollectedUsdc + executionBountyUsdc;
        assessment.actionChargeAssessedUsdc = delta.actionChargeAssessedUsdc;
        assessment.actionChargeCollectedUsdc = delta.actionChargeCollectedUsdc;
        assessment.explicitFeesUsdc = delta.closeState.executionFeeUsdc + delta.closeState.frozenSpreadUsdc;
        assessment.preSettlementBalanceUsdc = snapshot.accountBuckets.settlementBalanceUsdc;

        uint256 postSettlementBalanceUsdc =
            assessment.preSettlementBalanceUsdc - delta.pricePnlPledgeConsumedUsdc - delta.actionChargeCollectedUsdc;
        if (delta.pricePayoutIsImmediate) {
            postSettlementBalanceUsdc += delta.pricePayoutUsdc;
        }
        postSettlementBalanceUsdc += delta.actionRebatePaidUsdc;
        assessment.postSettlementBalanceUsdc = postSettlementBalanceUsdc - executionBountyUsdc;
        if (bountyReturnsToAccount) {
            assessment.postSettlementBalanceUsdc += executionBountyUsdc;
        }

        assessment.realizedPnlUsdc = delta.realizedPnlUsdc;
        assessment.vpiUsdc = delta.closeState.vpiDeltaUsdc;
        assessment.carryUsdc = delta.pendingCarryUsdc;
        assessment.executionFeeUsdc = delta.closeState.executionFeeUsdc;
        assessment.frozenSpreadUsdc = delta.closeState.frozenSpreadUsdc;
        assessment.preTraderClaimUsdc = snapshot.traderClaimBalanceForAccount;
        assessment.postTraderClaimUsdc = snapshot.traderClaimBalanceForAccount - delta.pricePnlClaimConsumedUsdc;
        if (delta.pricePayoutCreatesClaim) {
            assessment.postTraderClaimUsdc += delta.pricePayoutUsdc;
        }
        assessment.postPositionSize = delta.closeState.remainingSize;
        assessment.postPositionMarginUsdc = delta.posMarginAfter;

        if (delta.deletePosition) {
            return assessment;
        }

        CfdTypes.Position memory projectedPosition = snapshot.position;
        projectedPosition.size = delta.closeState.remainingSize;
        projectedPosition.margin = delta.posMarginAfter;
        projectedPosition.entryPrice = delta.posEntryPriceAfter;
        projectedPosition.maxProfitUsdc = snapshot.position.maxProfitUsdc - delta.posMaxProfitReduction;
        projectedPosition.vpiAccrued = snapshot.position.vpiAccrued - delta.posVpiAccruedReduction;

        PositionRiskAccountingLib.PositionRiskState memory riskState = PositionRiskAccountingLib.buildExactPriceRiskState(
            projectedPosition,
            delta.posEntryCostAfterUsdcAtoms,
            delta.price,
            snapshot.capPrice,
            assessment.postPositionMarginUsdc + assessment.postTraderClaimUsdc,
            0
        );
        assessment.postPositionEquityUsdc = riskState.equityUsdc;
        assessment.postLeverageBps = _postLeverageBps(riskState.currentNotionalUsdc, riskState.equityUsdc);
    }

    /// @dev Bound precedence is deliberately identical to the order of `ConstraintKind` values.
    function _enforceBounds(
        OrderV2Types.ExecutionAssessment memory assessment,
        OrderV2Types.ExecutionBounds memory bounds,
        uint256 executionBountyUsdc,
        bool fullClose
    ) private pure {
        _requireMaximum(OrderV2Types.ConstraintKind.ExecutionBounty, executionBountyUsdc, bounds.maxExecutionBountyUsdc);
        _requireMaximum(
            OrderV2Types.ConstraintKind.ExecutionNotional,
            assessment.executionNotionalUsdc,
            bounds.maxExecutionNotionalUsdc
        );
        _requireMaximum(
            OrderV2Types.ConstraintKind.GrossAccountDebit,
            assessment.grossAccountDebitUsdc,
            bounds.maxGrossAccountDebitUsdc
        );
        _requireMaximum(
            OrderV2Types.ConstraintKind.ActionCharge, assessment.actionChargeAssessedUsdc, bounds.maxActionChargeUsdc
        );
        _requireMaximum(
            OrderV2Types.ConstraintKind.ExplicitFees, assessment.explicitFeesUsdc, bounds.maxExplicitFeesUsdc
        );
        _requireMaximum(
            OrderV2Types.ConstraintKind.PostPositionSize, assessment.postPositionSize, bounds.maxPostPositionSize
        );
        _requireMinimum(
            OrderV2Types.ConstraintKind.PostSettlementBalance,
            assessment.postSettlementBalanceUsdc,
            bounds.minPostSettlementBalanceUsdc
        );

        if (fullClose) {
            return;
        }

        uint256 normalizedEquityUsdc =
            assessment.postPositionEquityUsdc > 0 ? uint256(assessment.postPositionEquityUsdc) : 0;
        if (assessment.postPositionEquityUsdc < 0 || normalizedEquityUsdc < bounds.minPostPositionEquityUsdc) {
            revert CfdOrderPolicyEvaluator__ConstraintViolation(
                OrderV2Types.ConstraintKind.PostPositionEquity, normalizedEquityUsdc, bounds.minPostPositionEquityUsdc
            );
        }
        _requireMaximum(OrderV2Types.ConstraintKind.PostLeverage, assessment.postLeverageBps, bounds.maxPostLeverageBps);
    }

    function _requireMaximum(
        OrderV2Types.ConstraintKind constraint,
        uint256 actual,
        uint256 limit
    ) private pure {
        if (actual > limit) {
            revert CfdOrderPolicyEvaluator__ConstraintViolation(constraint, actual, limit);
        }
    }

    function _requireMinimum(
        OrderV2Types.ConstraintKind constraint,
        uint256 actual,
        uint256 limit
    ) private pure {
        if (actual < limit) {
            revert CfdOrderPolicyEvaluator__ConstraintViolation(constraint, actual, limit);
        }
    }

    function _netOpenActionCharge(
        uint256 pendingCarryUsdc,
        int256 tradeCostUsdc
    ) private pure returns (uint256 actionChargeUsdc) {
        if (tradeCostUsdc >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return pendingCarryUsdc + uint256(tradeCostUsdc);
        }
        uint256 rebateUsdc = _negativeMagnitude(tradeCostUsdc);
        return pendingCarryUsdc > rebateUsdc ? pendingCarryUsdc - rebateUsdc : 0;
    }

    function _negativeMagnitude(
        int256 value
    ) private pure returns (uint256 magnitude) {
        return uint256(-(value + 1)) + 1;
    }

    function _postLeverageBps(
        uint256 postNotionalUsdc,
        int256 postEquityUsdc
    ) private pure returns (uint256 leverageBps) {
        if (postEquityUsdc <= 0) {
            return type(uint256).max;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(postNotionalUsdc, BPS, uint256(postEquityUsdc), Math.Rounding.Ceil);
    }

}

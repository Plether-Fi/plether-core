// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {Test} from "forge-std/Test.sol";

contract BountyBackingHarness is CfdOrderPolicyEvaluator {

    function evaluateSelfClose(
        CfdEnginePlanTypes.RawSnapshot memory snapshot,
        CfdEnginePlanTypes.CloseDelta memory delta,
        OrderV3Types.ExecutionBounds memory bounds,
        uint256 bounty
    ) external pure returns (OrderV3Types.ExecutionAssessment memory) {
        return _evaluateClose(snapshot, delta, bounds, bounty, true);
    }

}

/// @dev Synthetic planner snapshots exercise nonzero bounty classification; public close commitment rejects it.
contract CfdOrderPolicyEvaluatorTest is Test {

    uint256 private constant PRICE = 1e8;
    uint256 private constant BOUNTY = 250_000;
    address private constant ENGINE = address(0xE0610E);
    address private constant CLEARINGHOUSE = address(0xC1EA);
    address private constant POOL = address(0xB001);
    address private constant ROUTER = address(0xA0117E);
    address private constant ACCOUNT = address(0xA11CE);

    CfdOrderPolicyEvaluator internal evaluator;
    CfdEnginePlanner internal planner;

    function setUp() public {
        evaluator = new CfdOrderPolicyEvaluator();
        planner = new CfdEnginePlanner();
    }

    function test_CloseReservationCounterexample() public {
        CfdEnginePlanTypes.RawSnapshot memory snap;
        uint256 size = 15_927_400e18;
        uint256 entry = 98_895_064;
        uint256 price = entry * 999 / 1000;
        uint256 bounty = 200_000;
        snap.account = ACCOUNT;
        snap.capPrice = 2e8;
        snap.executionFeeBps = 4;
        snap.poolAssets = 1_000_000_000e6;
        snap.poolCashAssets = snap.poolAssets;
        snap.position.size = size;
        snap.position.margin = 10_000e6;
        snap.position.entryPrice = entry;
        snap.position.side = CfdTypes.Side.SHORT;
        snap.position.maxProfitAssets = size / 1e20 * (snap.capPrice - entry);
        snap.positionEntryCostAssetAtoms = size / 1e20 * entry;
        snap.shortSide.openInterest = size;
        snap.shortSide.maxProfitAssets = snap.position.maxProfitAssets;
        snap.shortSide.totalMargin = snap.position.margin;
        snap.shortSide.entryNotional = snap.positionEntryCostAssetAtoms * 1e12;
        snap.accountBuckets = IMarginClearinghouse.AccountAssetBuckets({
            settlementBalanceAssets: 10_000e6 + bounty,
            activePositionMarginAssets: 10_000e6,
            totalLockedMarginAssets: 10_000e6,
            otherLockedMarginAssets: 0,
            freeSettlementAssets: bounty
        });
        snap.lockedBuckets.positionMarginAssets = 10_000e6;
        snap.lockedBuckets.totalLockedMarginAssets = 10_000e6;
        CfdTypes.Order memory order = CfdTypes.Order(ACCOUNT, size, 0, price, 0, 0, 0, CfdTypes.Side.SHORT, true);
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, order, price);
        assertTrue(delta.valid);
        assertEq(delta.pricePnlPledgeConsumedAssets, 10_000e6);
        assertEq(delta.actionChargeCollectedAssets, bounty);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, 0, bounty
            )
        );
        evaluator.evaluateClose(snap, delta, _permissiveBounds(), bounty);

        // Same custody and position, complete classification equivalent to locking and recording the bounty.
        snap.accountBuckets.freeSettlementAssets = 0;
        snap.accountBuckets.otherLockedMarginAssets = bounty;
        snap.accountBuckets.totalLockedMarginAssets += bounty;
        snap.lockedBuckets.totalLockedMarginAssets += bounty;
        snap.lockedBuckets.reservedSettlementAssets = bounty;
        snap.actionReserveAssets = bounty;
        snap.protectedExecutionBountyAssets = bounty;
        delta = planner.planClose(snap, order, price);
        assertTrue(delta.valid);
        assertEq(delta.actionChargeCollectedAssets, 0);
        OrderV3Types.ExecutionAssessment memory assessment =
            evaluator.evaluateClose(snap, delta, _permissiveBounds(), bounty);
        assertEq(assessment.postSettlementBalanceAssets, 0);
    }

    function test_OpenBountyUnderfundingHasTypedInvariantError() public {
        CfdEnginePlanTypes.RawSnapshot memory snap = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        snap.accountBuckets.settlementBalanceAssets = 2e6;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, 0, BOUNTY
            )
        );
        evaluator.evaluateOpen(snap, delta, _permissiveBounds(), BOUNTY);
    }

    function test_SelfExecutionRequiresBackingAndKeepsGrossDebit() public {
        BountyBackingHarness harness = new BountyBackingHarness();
        CfdEnginePlanTypes.RawSnapshot memory snap;
        CfdEnginePlanTypes.CloseDelta memory delta;
        delta.valid = true;
        delta.deletePosition = true;
        snap.accountBuckets.settlementBalanceAssets = BOUNTY - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, BOUNTY - 1, BOUNTY
            )
        );
        harness.evaluateSelfClose(snap, delta, _permissiveBounds(), BOUNTY);
        snap.accountBuckets.settlementBalanceAssets = BOUNTY;
        OrderV3Types.ExecutionAssessment memory assessment =
            harness.evaluateSelfClose(snap, delta, _permissiveBounds(), BOUNTY);
        assertEq(assessment.postSettlementBalanceAssets, BOUNTY);
        assertEq(assessment.grossAccountDebitAssets, BOUNTY);
    }

    function test_AssessOrderUsesReleasedMarginButKeepsBountyProtectedAndHandlesSelfExecution() public {
        _mockCoordinatorState();
        CfdTypes.Order memory order = CfdTypes.Order({
            account: ACCOUNT,
            sizeDelta: 100_000e18,
            marginDelta: 10_000e6,
            targetPrice: PRICE,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 7,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();

        OrderV3Types.ExecutionAssessment memory externalExecution =
            evaluator.assessOrder(ENGINE, order, address(0xB0B), PRICE, 2_000_000e6, bounds, BOUNTY);
        OrderV3Types.ExecutionAssessment memory selfExecution =
            evaluator.assessOrder(ENGINE, order, ACCOUNT, PRICE, 2_000_000e6, bounds, BOUNTY);

        assertEq(externalExecution.executionNotionalAssets, 100_000e6);
        assertEq(externalExecution.grossAccountDebitAssets, 40e6 + BOUNTY);
        assertEq(externalExecution.actionChargeAssessedAssets, 40e6);
        assertEq(externalExecution.actionChargeCollectedAssets, 40e6);
        assertEq(externalExecution.explicitFeesAssets, 40e6);
        assertEq(externalExecution.preSettlementBalanceAssets, 20_000e6);
        assertEq(externalExecution.postSettlementBalanceAssets, 20_000e6 - 40e6 - BOUNTY);
        assertEq(selfExecution.grossAccountDebitAssets, externalExecution.grossAccountDebitAssets);
        assertEq(selfExecution.postSettlementBalanceAssets, externalExecution.postSettlementBalanceAssets + BOUNTY);
    }

    function test_OpenAssessmentNormalizesEconomicsAndInclusiveBoundsPass() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();

        bounds.maxExecutionBountyAssets = BOUNTY;
        bounds.maxExecutionNotionalAssets = 100e6;
        bounds.maxGrossAccountDebitAssets = 2_250_000;
        bounds.maxActionChargeAssets = 2e6;
        bounds.maxExplicitFeesAssets = 500_000;
        bounds.maxPostPositionSize = CfdTypes.SIZE_QUANTUM;
        bounds.minPostSettlementBalanceAssets = 497_750_000;
        bounds.minPostPositionEquityAssets = 203e6;
        bounds.maxPostLeverageBps = 4927;

        OrderV3Types.ExecutionAssessment memory assessment = evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);

        assertEq(uint8(assessment.mode), uint8(OrderV3Types.ExecutionMode.Live));
        assertEq(assessment.executionNotionalAssets, 100e6);
        assertEq(assessment.grossAccountDebitAssets, 2_250_000);
        assertEq(assessment.actionChargeAssessedAssets, 2e6);
        assertEq(assessment.actionChargeCollectedAssets, 2e6);
        assertEq(assessment.explicitFeesAssets, 500_000);
        assertEq(assessment.preSettlementBalanceAssets, 500e6);
        assertEq(assessment.postSettlementBalanceAssets, 497_750_000);
        assertEq(assessment.realizedPnlAssets, 0);
        assertEq(assessment.vpiAssets, 1_500_000);
        assertEq(assessment.carryAssets, 0);
        assertEq(assessment.executionFeeAssets, 500_000);
        assertEq(assessment.frozenSpreadAssets, 0);
        assertEq(assessment.preTraderClaimAssets, 3e6);
        assertEq(assessment.postTraderClaimAssets, 3e6);
        assertEq(assessment.postPositionSize, CfdTypes.SIZE_QUANTUM);
        assertEq(assessment.postPositionMarginAssets, 200e6);
        assertEq(assessment.postPositionEquityAssets, 203e6);
        assertEq(assessment.postLeverageBps, 4927);
    }

    function test_CloseAssessmentUsesCollectedDebitButAssessedFeesAndSpread() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxExecutionBountyAssets = 1e6;
        bounds.maxExecutionNotionalAssets = 120e6;
        bounds.maxGrossAccountDebitAssets = 27e6;
        bounds.maxActionChargeAssets = 6e6;
        bounds.maxExplicitFeesAssets = 3e6;
        bounds.maxPostPositionSize = CfdTypes.SIZE_QUANTUM;
        bounds.minPostSettlementBalanceAssets = 478e6;
        bounds.minPostPositionEquityAssets = 85e6;
        bounds.maxPostLeverageBps = 14_118;

        OrderV3Types.ExecutionAssessment memory assessment = evaluator.evaluateClose(snapshot, delta, bounds, 1e6);

        assertEq(uint8(assessment.mode), uint8(OrderV3Types.ExecutionMode.Frozen));
        assertEq(assessment.executionNotionalAssets, 120e6);
        assertEq(assessment.grossAccountDebitAssets, 27e6);
        assertEq(assessment.actionChargeAssessedAssets, 6e6);
        assertEq(assessment.actionChargeCollectedAssets, 6e6);
        assertEq(assessment.explicitFeesAssets, 3e6);
        assertEq(assessment.postSettlementBalanceAssets, 478e6);
        assertEq(assessment.realizedPnlAssets, -20e6);
        assertEq(assessment.vpiAssets, 2e6);
        assertEq(assessment.carryAssets, 1e6);
        assertEq(assessment.executionFeeAssets, 2e6);
        assertEq(assessment.frozenSpreadAssets, 1e6);
        assertEq(assessment.preTraderClaimAssets, 10e6);
        assertEq(assessment.postTraderClaimAssets, 5e6);
        assertEq(assessment.postPositionSize, CfdTypes.SIZE_QUANTUM);
        assertEq(assessment.postPositionMarginAssets, 100e6);
        assertEq(assessment.postPositionEquityAssets, 85e6);
        assertEq(assessment.postLeverageBps, 14_118);
    }

    function test_CloseImmediateGainCreditsSettlementWithoutChangingExistingClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _fullCloseGainDelta(snapshot);
        delta.pricePayoutIsImmediate = true;

        OrderV3Types.ExecutionAssessment memory assessment =
            evaluator.evaluateClose(snapshot, delta, _permissiveBounds(), 1e6);

        assertEq(assessment.preSettlementBalanceAssets, 500e6);
        assertEq(assessment.postSettlementBalanceAssets, 519e6);
        assertEq(assessment.preTraderClaimAssets, 10e6);
        assertEq(assessment.postTraderClaimAssets, 10e6);
    }

    function test_CloseDeferredGainCreatesClaimOnTopOfExistingClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _fullCloseGainDelta(snapshot);
        delta.pricePayoutCreatesClaim = true;
        // The planner's legacy diagnostic can remain zero on gain paths; assessment derives claim state canonically.
        delta.existingTraderClaimRemainingAssets = 0;

        OrderV3Types.ExecutionAssessment memory assessment =
            evaluator.evaluateClose(snapshot, delta, _permissiveBounds(), 1e6);

        assertEq(assessment.preSettlementBalanceAssets, 500e6);
        assertEq(assessment.postSettlementBalanceAssets, 499e6);
        assertEq(assessment.preTraderClaimAssets, 10e6);
        assertEq(assessment.postTraderClaimAssets, 30e6);
    }

    function test_NegativeVpiCannotHideExplicitOpenFee() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.tradeCostAssets = -10e6;
        delta.posVpiAccruedDelta = -19e6;
        delta.pendingCarryAssets = 3e6;
        delta.executionFeeAssets = 9e6;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxExplicitFeesAssets = 9e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExplicitFees,
                9e6,
                9e6 - 1
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, 2e6);
    }

    function test_WaivedCloseCollectionCannotHideAssessedFeeAndFrozenSpread() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        delta.deletePosition = true;
        delta.sizeDelta = snapshot.position.size;
        delta.closeState.remainingSize = 0;
        delta.actionChargeCollectedAssets = 0;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxExplicitFeesAssets = 3e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExplicitFees,
                3e6,
                3e6 - 1
            )
        );
        evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
    }

    function test_ConsumedTraderClaimCannotBypassGrossAccountDebitBound() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxGrossAccountDebitAssets = 27e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.GrossAccountDebit,
                27e6,
                27e6 - 1
            )
        );
        evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
    }

    function test_ConstraintPrecedenceStartsWithExecutionBounty() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxExecutionBountyAssets = 0;
        bounds.maxExecutionNotionalAssets = 0;
        bounds.maxGrossAccountDebitAssets = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.ExecutionBounty,
                BOUNTY,
                0
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_PostSettlementMinimumFailsByOneAtom() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostSettlementBalanceAssets = 497_750_001;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostSettlementBalance,
                497_750_000,
                497_750_001
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_PostEquityMinimumFailsByOneAtom() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityAssets = 203e6 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostPositionEquity,
                203e6,
                203e6 + 1
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_PostLeverageRoundsUpAndEqualityPasses() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.traderClaimBalanceForAccount = 0;
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.positionMarginAfterOpen = 30e6;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxPostLeverageBps = 33_333;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostLeverage,
                33_334,
                33_333
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);

        bounds.maxPostLeverageBps = 33_334;
        OrderV3Types.ExecutionAssessment memory assessment = evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
        assertEq(assessment.postLeverageBps, 33_334);
    }

    function test_NonpositivePostEquityAlwaysFailsForRemainingPosition() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.traderClaimBalanceForAccount = 0;
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.positionMarginAfterOpen = 0;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityAssets = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostLeverage,
                type(uint256).max,
                uint256(type(uint32).max)
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_NegativePostEquityFailsEquityBeforeLeverageEvenWhenMinimumIsZero() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.traderClaimBalanceForAccount = 0;
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.positionMarginAfterOpen = 0;
        delta.posSide = CfdTypes.Side.SHORT;
        delta.newPosEntryPrice = 2 * PRICE;
        delta.newPosEntryCostAssetAtoms = 2 * PRICE;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityAssets = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV3Types.ConstraintKind.PostPositionEquity,
                0,
                0
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_FreshOpenDoesNotReportOrDebitUnappliedStaleCarry() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.pendingCarryAssets = 99e6;

        OrderV3Types.ExecutionAssessment memory assessment =
            evaluator.evaluateOpen(snapshot, delta, _permissiveBounds(), BOUNTY);

        assertEq(assessment.carryAssets, 0);
        assertEq(assessment.actionChargeAssessedAssets, 2e6);
        assertEq(assessment.actionChargeCollectedAssets, 2e6);
        assertEq(assessment.grossAccountDebitAssets, 2e6 + BOUNTY);
        assertEq(assessment.postSettlementBalanceAssets, 500e6 - 2e6 - BOUNTY);
    }

    function test_IncreaseReportsCarryActuallyRealizedBeforeOpenCost() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.position.size = CfdTypes.SIZE_QUANTUM;
        snapshot.position.entryPrice = PRICE;
        snapshot.position.side = CfdTypes.Side.SHORT;
        snapshot.positionEntryCostAssetAtoms = PRICE;

        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.newPosSize = 2 * CfdTypes.SIZE_QUANTUM;
        delta.newPosEntryCostAssetAtoms = 2 * PRICE;

        OrderV3Types.ExecutionAssessment memory assessment =
            evaluator.evaluateOpen(snapshot, delta, _permissiveBounds(), BOUNTY);

        assertEq(assessment.carryAssets, 1e6);
        assertEq(assessment.actionChargeAssessedAssets, 3e6);
        assertEq(assessment.actionChargeCollectedAssets, 3e6);
        assertEq(assessment.grossAccountDebitAssets, 3e6 + BOUNTY);
        assertEq(assessment.postSettlementBalanceAssets, 500e6 - 3e6 - BOUNTY);
    }

    function test_FullCloseSkipsPositionEquityAndLeverageFloors() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        delta.deletePosition = true;
        delta.sizeDelta = snapshot.position.size;
        delta.closeState.remainingSize = 0;
        delta.posMarginAfter = 0;
        delta.posEntryPriceAfter = 0;
        delta.posEntryCostAfterAssetAtoms = 0;

        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxPostPositionSize = 0;
        bounds.minPostPositionEquityAssets = type(uint256).max;
        bounds.maxPostLeverageBps = 0;

        OrderV3Types.ExecutionAssessment memory assessment = evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
        assertEq(assessment.postPositionSize, 0);
        assertEq(assessment.postPositionEquityAssets, 0);
        assertEq(assessment.postLeverageBps, 0);
    }

    function test_DisallowedFadModeHasStableTypedError() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.isFadWindow = true;
        OrderV3Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed.selector,
                OrderV3Types.ExecutionMode.Fad,
                uint8(1)
            )
        );
        evaluator.evaluateOpen(snapshot, _baseOpenDelta(), bounds, BOUNTY);
    }

    function test_OpenPlannerFailureKeepsExistingTypedCategoryAndCode() public {
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.valid = false;
        delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
                false
            )
        );
        evaluator.evaluateOpen(_baseOpenSnapshot(), delta, _permissiveBounds(), BOUNTY);
    }

    function test_ClosePlannerFailureKeepsExistingTypedCategoryAndCode() public {
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        delta.valid = false;
        delta.revertCode = CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
                uint8(CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION),
                true
            )
        );
        evaluator.evaluateClose(_baseCloseSnapshot(), delta, _permissiveBounds(), 1e6);
    }

    function test_InvalidPlannerResultWithOkCodeHasStableError() public {
        CfdEnginePlanTypes.OpenDelta memory openDelta = _baseOpenDelta();
        openDelta.valid = false;
        vm.expectRevert(ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InvalidPlannerResult.selector);
        evaluator.evaluateOpen(_baseOpenSnapshot(), openDelta, _permissiveBounds(), BOUNTY);

        CfdEnginePlanTypes.CloseDelta memory closeDelta = _baseCloseDelta();
        closeDelta.valid = false;
        vm.expectRevert(ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InvalidPlannerResult.selector);
        evaluator.evaluateClose(_baseCloseSnapshot(), closeDelta, _permissiveBounds(), 1e6);
    }

    function _baseOpenSnapshot() private pure returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.account = address(0xA11CE);
        snapshot.accountBuckets.settlementBalanceAssets = 500e6;
        snapshot.traderClaimBalanceForAccount = 3e6;
        snapshot.capPrice = 2e8;
    }

    function _baseOpenDelta() private pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        delta.valid = true;
        delta.openState.notionalAssets = 100e6;
        delta.posSide = CfdTypes.Side.SHORT;
        delta.newPosSize = CfdTypes.SIZE_QUANTUM;
        delta.newPosEntryPrice = PRICE;
        delta.newPosEntryCostAssetAtoms = PRICE;
        delta.posVpiAccruedDelta = 1_500_000;
        delta.positionMarginAfterOpen = 200e6;
        delta.tradeCostAssets = 2e6;
        delta.executionFeeAssets = 500_000;
        delta.pendingCarryAssets = 1e6;
        delta.sizeDelta = CfdTypes.SIZE_QUANTUM;
        delta.price = PRICE;
    }

    function _baseCloseSnapshot() private pure returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.account = address(0xA11CE);
        snapshot.position.size = 2 * CfdTypes.SIZE_QUANTUM;
        snapshot.position.margin = 300e6;
        snapshot.position.entryPrice = PRICE;
        snapshot.position.side = CfdTypes.Side.LONG;
        snapshot.positionEntryCostAssetAtoms = 2 * PRICE;
        snapshot.accountBuckets.settlementBalanceAssets = 500e6;
        snapshot.traderClaimBalanceForAccount = 10e6;
        snapshot.capPrice = 2e8;
        snapshot.oracleFrozen = true;
    }

    function _baseCloseDelta() private pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        delta.valid = true;
        delta.closeState.remainingSize = CfdTypes.SIZE_QUANTUM;
        delta.closeState.vpiDeltaAssets = 2e6;
        delta.closeState.executionFeeAssets = 2e6;
        delta.closeState.frozenSpreadAssets = 1e6;
        delta.posMarginAfter = 100e6;
        delta.posEntryPriceAfter = PRICE;
        delta.posEntryCostAfterAssetAtoms = PRICE;
        delta.pricePnlClaimConsumedAssets = 5e6;
        delta.pricePnlPledgeConsumedAssets = 15e6;
        delta.actionChargeAssessedAssets = 6e6;
        delta.actionChargeCollectedAssets = 6e6;
        delta.existingTraderClaimRemainingAssets = 5e6;
        delta.pendingCarryAssets = 1e6;
        delta.sizeDelta = CfdTypes.SIZE_QUANTUM;
        delta.price = 120_000_000;
        delta.realizedPnlAssets = -20e6;
    }

    function _fullCloseGainDelta(
        CfdEnginePlanTypes.RawSnapshot memory snapshot
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        delta.valid = true;
        delta.deletePosition = true;
        delta.sizeDelta = snapshot.position.size;
        delta.price = 120_000_000;
        delta.realizedPnlAssets = 20e6;
        delta.pricePayoutAssets = 20e6;
    }

    function _permissiveBounds() private pure returns (OrderV3Types.ExecutionBounds memory bounds) {
        bounds.allowedExecutionModes = 7;
        bounds.maxExecutionBountyAssets = type(uint256).max;
        bounds.maxExecutionNotionalAssets = type(uint256).max;
        bounds.maxGrossAccountDebitAssets = type(uint256).max;
        bounds.maxActionChargeAssets = type(uint256).max;
        bounds.maxExplicitFeesAssets = type(uint256).max;
        bounds.maxPostPositionSize = type(uint256).max;
        bounds.maxPostLeverageBps = type(uint32).max;
    }

    function _mockCoordinatorState() private {
        vm.mockCall(ENGINE, abi.encodeWithSignature("planner()"), abi.encode(address(planner)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("pool()"), abi.encode(POOL));
        vm.mockCall(ENGINE, abi.encodeWithSignature("clearinghouse()"), abi.encode(CLEARINGHOUSE));
        vm.mockCall(ENGINE, abi.encodeWithSignature("orderRouter()"), abi.encode(ROUTER));
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("positions(address)", ACCOUNT),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), CfdTypes.Side.LONG, uint64(0), int256(0))
        );
        vm.mockCall(ENGINE, abi.encodeWithSignature("positionEntryCostAssetAtoms(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(
            ENGINE,
            abi.encodeWithSignature("positionCarryState(address)", ACCOUNT),
            abi.encode(uint256(0), uint256(0), uint64(block.timestamp))
        );
        vm.mockCall(ENGINE, abi.encodeWithSignature("lastMarkPrice()"), abi.encode(PRICE));
        vm.mockCall(ENGINE, abi.encodeWithSignature("lastMarkTime()"), abi.encode(uint64(block.timestamp)));
        vm.mockCall(ENGINE, abi.encodeWithSignature("riskParams()"), abi.encode(_coordinatorRiskParams()));

        for (uint256 side; side < 2; ++side) {
            vm.mockCall(
                ENGINE,
                abi.encodeWithSignature("sides(uint256)", side),
                abi.encode(uint256(0), uint256(0), uint256(0), uint256(0))
            );
            vm.mockCall(ENGINE, abi.encodeWithSignature("sideBorrowBaseAssets(uint256)", side), abi.encode(0));
            vm.mockCall(ENGINE, abi.encodeWithSignature("sideCarryIndex(uint256)", side), abi.encode(0));
            vm.mockCall(
                ENGINE,
                abi.encodeWithSignature("sideCarryTimestamp(uint256)", side),
                abi.encode(uint64(block.timestamp))
            );
        }

        vm.mockCall(POOL, abi.encodeWithSignature("totalAssets()"), abi.encode(2_000_000e6));
        // Funded LP principals with no pending or unassigned reserves in this bounty-accounting scenario.
        vm.mockCall(POOL, abi.encodeWithSignature("pendingRecapitalizationAssets()"), abi.encode(0));
        vm.mockCall(POOL, abi.encodeWithSignature("pendingTradingRevenueAssets()"), abi.encode(0));
        vm.mockCall(POOL, abi.encodeWithSignature("unassignedAssets()"), abi.encode(0));
        vm.mockCall(POOL, abi.encodeWithSignature("seniorPrincipal()"), abi.encode(1_000_000e6));
        vm.mockCall(POOL, abi.encodeWithSignature("juniorPrincipal()"), abi.encode(1_000_000e6));

        IMarginClearinghouse.PnlIsolationBuckets memory buckets = IMarginClearinghouse.PnlIsolationBuckets({
            settlementBalanceAssets: 20_000e6,
            pnlPledgeAssets: 0,
            liquidationReserveAssets: 0,
            orderMarginAssets: 0,
            actionReserveAssets: BOUNTY,
            vpiRebateReserveAssets: 0,
            totalLockedAssets: BOUNTY,
            freeSettlementAssets: 20_000e6 - BOUNTY
        });
        vm.mockCall(
            CLEARINGHOUSE, abi.encodeWithSignature("getPnlIsolationBuckets(address)", ACCOUNT), abi.encode(buckets)
        );

        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("totalBountyReservationsAssets(address)", ACCOUNT),
            abi.encode(BOUNTY)
        );
        vm.mockCallRevert(
            ROUTER, abi.encodeWithSignature("getAccountReservations(address)", ACCOUNT), "not an accounting authority"
        );

        vm.mockCall(ENGINE, abi.encodeWithSignature("unsettledCarryAssets(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("totalTraderClaimBalanceAssets()"), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("traderClaimBalanceAssets(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("degradedMode()"), abi.encode(false));
        vm.mockCall(ENGINE, abi.encodeWithSignature("CAP_PRICE()"), abi.encode(2e8));
        vm.mockCall(ENGINE, abi.encodeWithSignature("executionFeeBps()"), abi.encode(4));
        vm.mockCall(ENGINE, abi.encodeWithSignature("settlementBufferBps()"), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("isFadWindow()"), abi.encode(false));
        vm.mockCall(ENGINE, abi.encodeWithSignature("isOracleFrozen()"), abi.encode(false));
        vm.mockCall(ENGINE, abi.encodeWithSignature("frozenCloseSpreadBps()"), abi.encode(0));
    }

    function _coordinatorRiskParams() private pure returns (CfdTypes.RiskParams memory params) {
        params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

}

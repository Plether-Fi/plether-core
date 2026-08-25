// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {Test} from "forge-std/Test.sol";

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
            side: CfdTypes.Side.BULL,
            isClose: false
        });
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();

        OrderV2Types.ExecutionAssessment memory externalExecution = evaluator.assessOrder(
            ENGINE, order, address(0xB0B), PRICE, 2_000_000e6, uint64(block.timestamp), bounds, BOUNTY
        );
        OrderV2Types.ExecutionAssessment memory selfExecution =
            evaluator.assessOrder(ENGINE, order, ACCOUNT, PRICE, 2_000_000e6, uint64(block.timestamp), bounds, BOUNTY);

        assertEq(externalExecution.executionNotionalUsdc, 100_000e6);
        assertEq(externalExecution.grossAccountDebitUsdc, 40e6 + BOUNTY);
        assertEq(externalExecution.actionChargeAssessedUsdc, 40e6);
        assertEq(externalExecution.actionChargeCollectedUsdc, 40e6);
        assertEq(externalExecution.explicitFeesUsdc, 40e6);
        assertEq(externalExecution.preSettlementBalanceUsdc, 20_000e6);
        assertEq(externalExecution.postSettlementBalanceUsdc, 20_000e6 - 40e6 - BOUNTY);
        assertEq(selfExecution.grossAccountDebitUsdc, externalExecution.grossAccountDebitUsdc);
        assertEq(selfExecution.postSettlementBalanceUsdc, externalExecution.postSettlementBalanceUsdc + BOUNTY);
    }

    function test_OpenAssessmentNormalizesEconomicsAndInclusiveBoundsPass() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();

        bounds.maxExecutionBountyUsdc = BOUNTY;
        bounds.maxExecutionNotionalUsdc = 100e6;
        bounds.maxGrossAccountDebitUsdc = 2_250_000;
        bounds.maxActionChargeUsdc = 2e6;
        bounds.maxExplicitFeesUsdc = 500_000;
        bounds.maxPostPositionSize = CfdTypes.SIZE_QUANTUM;
        bounds.minPostSettlementBalanceUsdc = 497_750_000;
        bounds.minPostPositionEquityUsdc = 203e6;
        bounds.maxPostLeverageBps = 4927;

        OrderV2Types.ExecutionAssessment memory assessment = evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);

        assertEq(uint8(assessment.mode), uint8(OrderV2Types.ExecutionMode.Live));
        assertEq(assessment.executionNotionalUsdc, 100e6);
        assertEq(assessment.grossAccountDebitUsdc, 2_250_000);
        assertEq(assessment.actionChargeAssessedUsdc, 2e6);
        assertEq(assessment.actionChargeCollectedUsdc, 2e6);
        assertEq(assessment.explicitFeesUsdc, 500_000);
        assertEq(assessment.preSettlementBalanceUsdc, 500e6);
        assertEq(assessment.postSettlementBalanceUsdc, 497_750_000);
        assertEq(assessment.realizedPnlUsdc, 0);
        assertEq(assessment.vpiUsdc, 1_500_000);
        assertEq(assessment.carryUsdc, 0);
        assertEq(assessment.executionFeeUsdc, 500_000);
        assertEq(assessment.frozenSpreadUsdc, 0);
        assertEq(assessment.preTraderClaimUsdc, 3e6);
        assertEq(assessment.postTraderClaimUsdc, 3e6);
        assertEq(assessment.postPositionSize, CfdTypes.SIZE_QUANTUM);
        assertEq(assessment.postPositionMarginUsdc, 200e6);
        assertEq(assessment.postPositionEquityUsdc, 203e6);
        assertEq(assessment.postLeverageBps, 4927);
    }

    function test_CloseAssessmentUsesCollectedDebitButAssessedFeesAndSpread() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxExecutionBountyUsdc = 1e6;
        bounds.maxExecutionNotionalUsdc = 120e6;
        bounds.maxGrossAccountDebitUsdc = 27e6;
        bounds.maxActionChargeUsdc = 6e6;
        bounds.maxExplicitFeesUsdc = 3e6;
        bounds.maxPostPositionSize = CfdTypes.SIZE_QUANTUM;
        bounds.minPostSettlementBalanceUsdc = 478e6;
        bounds.minPostPositionEquityUsdc = 85e6;
        bounds.maxPostLeverageBps = 14_118;

        OrderV2Types.ExecutionAssessment memory assessment = evaluator.evaluateClose(snapshot, delta, bounds, 1e6);

        assertEq(uint8(assessment.mode), uint8(OrderV2Types.ExecutionMode.Frozen));
        assertEq(assessment.executionNotionalUsdc, 120e6);
        assertEq(assessment.grossAccountDebitUsdc, 27e6);
        assertEq(assessment.actionChargeAssessedUsdc, 6e6);
        assertEq(assessment.actionChargeCollectedUsdc, 6e6);
        assertEq(assessment.explicitFeesUsdc, 3e6);
        assertEq(assessment.postSettlementBalanceUsdc, 478e6);
        assertEq(assessment.realizedPnlUsdc, -20e6);
        assertEq(assessment.vpiUsdc, 2e6);
        assertEq(assessment.carryUsdc, 1e6);
        assertEq(assessment.executionFeeUsdc, 2e6);
        assertEq(assessment.frozenSpreadUsdc, 1e6);
        assertEq(assessment.preTraderClaimUsdc, 10e6);
        assertEq(assessment.postTraderClaimUsdc, 5e6);
        assertEq(assessment.postPositionSize, CfdTypes.SIZE_QUANTUM);
        assertEq(assessment.postPositionMarginUsdc, 100e6);
        assertEq(assessment.postPositionEquityUsdc, 85e6);
        assertEq(assessment.postLeverageBps, 14_118);
    }

    function test_CloseImmediateGainCreditsSettlementWithoutChangingExistingClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _fullCloseGainDelta(snapshot);
        delta.pricePayoutIsImmediate = true;

        OrderV2Types.ExecutionAssessment memory assessment =
            evaluator.evaluateClose(snapshot, delta, _permissiveBounds(), 1e6);

        assertEq(assessment.preSettlementBalanceUsdc, 500e6);
        assertEq(assessment.postSettlementBalanceUsdc, 519e6);
        assertEq(assessment.preTraderClaimUsdc, 10e6);
        assertEq(assessment.postTraderClaimUsdc, 10e6);
    }

    function test_CloseDeferredGainCreatesClaimOnTopOfExistingClaim() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _fullCloseGainDelta(snapshot);
        delta.pricePayoutCreatesClaim = true;
        // The planner's legacy diagnostic can remain zero on gain paths; assessment derives claim state canonically.
        delta.existingTraderClaimRemainingUsdc = 0;

        OrderV2Types.ExecutionAssessment memory assessment =
            evaluator.evaluateClose(snapshot, delta, _permissiveBounds(), 1e6);

        assertEq(assessment.preSettlementBalanceUsdc, 500e6);
        assertEq(assessment.postSettlementBalanceUsdc, 499e6);
        assertEq(assessment.preTraderClaimUsdc, 10e6);
        assertEq(assessment.postTraderClaimUsdc, 30e6);
    }

    function test_NegativeVpiCannotHideExplicitOpenFee() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.tradeCostUsdc = -10e6;
        delta.posVpiAccruedDelta = -19e6;
        delta.pendingCarryUsdc = 3e6;
        delta.executionFeeUsdc = 9e6;

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxExplicitFeesUsdc = 9e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.ExplicitFees,
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
        delta.actionChargeCollectedUsdc = 0;

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxExplicitFeesUsdc = 3e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.ExplicitFees,
                3e6,
                3e6 - 1
            )
        );
        evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
    }

    function test_ConsumedTraderClaimCannotBypassGrossAccountDebitBound() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxGrossAccountDebitUsdc = 27e6 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.GrossAccountDebit,
                27e6,
                27e6 - 1
            )
        );
        evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
    }

    function test_ConstraintPrecedenceStartsWithExecutionBounty() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxExecutionBountyUsdc = 0;
        bounds.maxExecutionNotionalUsdc = 0;
        bounds.maxGrossAccountDebitUsdc = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.ExecutionBounty,
                BOUNTY,
                0
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_PostSettlementMinimumFailsByOneAtom() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostSettlementBalanceUsdc = 497_750_001;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.PostSettlementBalance,
                497_750_000,
                497_750_001
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_PostEquityMinimumFailsByOneAtom() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityUsdc = 203e6 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.PostPositionEquity,
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

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.maxPostLeverageBps = 33_333;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.PostLeverage,
                33_334,
                33_333
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);

        bounds.maxPostLeverageBps = 33_334;
        OrderV2Types.ExecutionAssessment memory assessment = evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
        assertEq(assessment.postLeverageBps, 33_334);
    }

    function test_NonpositivePostEquityAlwaysFailsForRemainingPosition() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.traderClaimBalanceForAccount = 0;
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.positionMarginAfterOpen = 0;

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityUsdc = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.PostLeverage,
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
        delta.posSide = CfdTypes.Side.BEAR;
        delta.newPosEntryPrice = 2 * PRICE;
        delta.newPosEntryCostUsdcAtoms = 2 * PRICE;

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.minPostPositionEquityUsdc = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                OrderV2Types.ConstraintKind.PostPositionEquity,
                0,
                0
            )
        );
        evaluator.evaluateOpen(snapshot, delta, bounds, BOUNTY);
    }

    function test_FreshOpenDoesNotReportOrDebitUnappliedStaleCarry() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.pendingCarryUsdc = 99e6;

        OrderV2Types.ExecutionAssessment memory assessment =
            evaluator.evaluateOpen(snapshot, delta, _permissiveBounds(), BOUNTY);

        assertEq(assessment.carryUsdc, 0);
        assertEq(assessment.actionChargeAssessedUsdc, 2e6);
        assertEq(assessment.actionChargeCollectedUsdc, 2e6);
        assertEq(assessment.grossAccountDebitUsdc, 2e6 + BOUNTY);
        assertEq(assessment.postSettlementBalanceUsdc, 500e6 - 2e6 - BOUNTY);
    }

    function test_IncreaseReportsCarryActuallyRealizedBeforeOpenCost() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.position.size = CfdTypes.SIZE_QUANTUM;
        snapshot.position.entryPrice = PRICE;
        snapshot.position.side = CfdTypes.Side.BEAR;
        snapshot.positionEntryCostUsdcAtoms = PRICE;

        CfdEnginePlanTypes.OpenDelta memory delta = _baseOpenDelta();
        delta.newPosSize = 2 * CfdTypes.SIZE_QUANTUM;
        delta.newPosEntryCostUsdcAtoms = 2 * PRICE;

        OrderV2Types.ExecutionAssessment memory assessment =
            evaluator.evaluateOpen(snapshot, delta, _permissiveBounds(), BOUNTY);

        assertEq(assessment.carryUsdc, 1e6);
        assertEq(assessment.actionChargeAssessedUsdc, 3e6);
        assertEq(assessment.actionChargeCollectedUsdc, 3e6);
        assertEq(assessment.grossAccountDebitUsdc, 3e6 + BOUNTY);
        assertEq(assessment.postSettlementBalanceUsdc, 500e6 - 3e6 - BOUNTY);
    }

    function test_FullCloseSkipsPositionEquityAndLeverageFloors() public view {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseCloseSnapshot();
        CfdEnginePlanTypes.CloseDelta memory delta = _baseCloseDelta();
        delta.deletePosition = true;
        delta.sizeDelta = snapshot.position.size;
        delta.closeState.remainingSize = 0;
        delta.posMarginAfter = 0;
        delta.posEntryPriceAfter = 0;
        delta.posEntryCostAfterUsdcAtoms = 0;

        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 4;
        bounds.maxPostPositionSize = 0;
        bounds.minPostPositionEquityUsdc = type(uint256).max;
        bounds.maxPostLeverageBps = 0;

        OrderV2Types.ExecutionAssessment memory assessment = evaluator.evaluateClose(snapshot, delta, bounds, 1e6);
        assertEq(assessment.postPositionSize, 0);
        assertEq(assessment.postPositionEquityUsdc, 0);
        assertEq(assessment.postLeverageBps, 0);
    }

    function test_DisallowedFadModeHasStableTypedError() public {
        CfdEnginePlanTypes.RawSnapshot memory snapshot = _baseOpenSnapshot();
        snapshot.isFadWindow = true;
        OrderV2Types.ExecutionBounds memory bounds = _permissiveBounds();
        bounds.allowedExecutionModes = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed.selector,
                OrderV2Types.ExecutionMode.Fad,
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

    function _baseOpenSnapshot() private pure returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.account = address(0xA11CE);
        snapshot.accountBuckets.settlementBalanceUsdc = 500e6;
        snapshot.traderClaimBalanceForAccount = 3e6;
        snapshot.capPrice = 2e8;
    }

    function _baseOpenDelta() private pure returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        delta.valid = true;
        delta.openState.notionalUsdc = 100e6;
        delta.posSide = CfdTypes.Side.BEAR;
        delta.newPosSize = CfdTypes.SIZE_QUANTUM;
        delta.newPosEntryPrice = PRICE;
        delta.newPosEntryCostUsdcAtoms = PRICE;
        delta.posVpiAccruedDelta = 1_500_000;
        delta.positionMarginAfterOpen = 200e6;
        delta.tradeCostUsdc = 2e6;
        delta.executionFeeUsdc = 500_000;
        delta.pendingCarryUsdc = 1e6;
        delta.sizeDelta = CfdTypes.SIZE_QUANTUM;
        delta.price = PRICE;
    }

    function _baseCloseSnapshot() private pure returns (CfdEnginePlanTypes.RawSnapshot memory snapshot) {
        snapshot.account = address(0xA11CE);
        snapshot.position.size = 2 * CfdTypes.SIZE_QUANTUM;
        snapshot.position.margin = 300e6;
        snapshot.position.entryPrice = PRICE;
        snapshot.position.side = CfdTypes.Side.BULL;
        snapshot.positionEntryCostUsdcAtoms = 2 * PRICE;
        snapshot.accountBuckets.settlementBalanceUsdc = 500e6;
        snapshot.traderClaimBalanceForAccount = 10e6;
        snapshot.capPrice = 2e8;
        snapshot.oracleFrozen = true;
    }

    function _baseCloseDelta() private pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        delta.valid = true;
        delta.closeState.remainingSize = CfdTypes.SIZE_QUANTUM;
        delta.closeState.vpiDeltaUsdc = 2e6;
        delta.closeState.executionFeeUsdc = 2e6;
        delta.closeState.frozenSpreadUsdc = 1e6;
        delta.posMarginAfter = 100e6;
        delta.posEntryPriceAfter = PRICE;
        delta.posEntryCostAfterUsdcAtoms = PRICE;
        delta.pricePnlClaimConsumedUsdc = 5e6;
        delta.pricePnlPledgeConsumedUsdc = 15e6;
        delta.actionChargeAssessedUsdc = 6e6;
        delta.actionChargeCollectedUsdc = 6e6;
        delta.existingTraderClaimRemainingUsdc = 5e6;
        delta.pendingCarryUsdc = 1e6;
        delta.sizeDelta = CfdTypes.SIZE_QUANTUM;
        delta.price = 120_000_000;
        delta.realizedPnlUsdc = -20e6;
    }

    function _fullCloseGainDelta(
        CfdEnginePlanTypes.RawSnapshot memory snapshot
    ) private pure returns (CfdEnginePlanTypes.CloseDelta memory delta) {
        delta.valid = true;
        delta.deletePosition = true;
        delta.sizeDelta = snapshot.position.size;
        delta.price = 120_000_000;
        delta.realizedPnlUsdc = 20e6;
        delta.pricePayoutUsdc = 20e6;
    }

    function _permissiveBounds() private pure returns (OrderV2Types.ExecutionBounds memory bounds) {
        bounds.allowedExecutionModes = 7;
        bounds.maxExecutionBountyUsdc = type(uint256).max;
        bounds.maxExecutionNotionalUsdc = type(uint256).max;
        bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        bounds.maxActionChargeUsdc = type(uint256).max;
        bounds.maxExplicitFeesUsdc = type(uint256).max;
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
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), CfdTypes.Side.BULL, uint64(0), int256(0))
        );
        vm.mockCall(ENGINE, abi.encodeWithSignature("positionEntryCostUsdcAtoms(address)", ACCOUNT), abi.encode(0));
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
            vm.mockCall(ENGINE, abi.encodeWithSignature("sideBorrowBaseUsdc(uint256)", side), abi.encode(0));
            vm.mockCall(ENGINE, abi.encodeWithSignature("sideCarryIndex(uint256)", side), abi.encode(0));
            vm.mockCall(
                ENGINE,
                abi.encodeWithSignature("sideCarryTimestamp(uint256)", side),
                abi.encode(uint64(block.timestamp))
            );
        }

        vm.mockCall(POOL, abi.encodeWithSignature("totalAssets()"), abi.encode(2_000_000e6));

        IMarginClearinghouse.AccountUsdcBuckets memory accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 20_000e6,
            totalLockedMarginUsdc: BOUNTY,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: BOUNTY,
            freeSettlementUsdc: 20_000e6 - BOUNTY
        });
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 0,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: BOUNTY,
            totalLockedMarginUsdc: BOUNTY
        });
        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("getAccountUsdcBuckets(address)", ACCOUNT),
            abi.encode(accountBuckets)
        );
        vm.mockCall(
            CLEARINGHOUSE,
            abi.encodeWithSignature("getLockedMarginBuckets(address)", ACCOUNT),
            abi.encode(lockedBuckets)
        );
        vm.mockCall(CLEARINGHOUSE, abi.encodeWithSignature("liquidationReserveUsdc(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(CLEARINGHOUSE, abi.encodeWithSignature("actionReserveUsdc(address)", ACCOUNT), abi.encode(BOUNTY));
        vm.mockCall(CLEARINGHOUSE, abi.encodeWithSignature("vpiRebateReserveUsdc(address)", ACCOUNT), abi.encode(0));

        IOrderRouterAccounting.AccountReservationView memory reservation = IOrderRouterAccounting.AccountReservationView({
            committedMarginUsdc: 0, executionBountyUsdc: BOUNTY, pendingOrderCount: 1
        });
        vm.mockCall(
            ROUTER, abi.encodeWithSignature("getAccountReservations(address)", ACCOUNT), abi.encode(reservation)
        );

        vm.mockCall(ENGINE, abi.encodeWithSignature("unsettledCarryUsdc(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("totalTraderClaimBalanceUsdc()"), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("traderClaimBalanceUsdc(address)", ACCOUNT), abi.encode(0));
        vm.mockCall(ENGINE, abi.encodeWithSignature("degradedMode()"), abi.encode(false));
        vm.mockCall(ENGINE, abi.encodeWithSignature("CAP_PRICE()"), abi.encode(2e8));
        vm.mockCall(ENGINE, abi.encodeWithSignature("executionFeeBps()"), abi.encode(4));
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
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

}

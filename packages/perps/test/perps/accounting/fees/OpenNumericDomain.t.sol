// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {NumericDomainLensHarness, NumericDomainMathHarness} from "../../shared/NumericDomainHarness.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {OpenAccountingLib} from "@plether/perps/libraries/OpenAccountingLib.sol";
import {Test} from "forge-std/Test.sol";

contract OpenNumericDomainTest is Test {

    uint256 private constant Q = 1e20;
    uint256 private constant MAX_SKEW = 340_282_366_920_938_463_463_374_607;
    NumericDomainMathHarness private math = new NumericDomainMathHarness();

    function _snapshot() private pure returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap.account = address(0xBEEF);
        snap.capPrice = 2e8;
        snap.poolAssets = 1_000_000e6;
        snap.poolCashAssets = snap.poolAssets;
        snap.accountBuckets.settlementBalanceAssets = 100_000e6;
        snap.accountBuckets.freeSettlementAssets = 100_000e6;
        snap.executionFeeBps = 4;
        snap.riskParams.maxSkewRatio = 1e18;
        snap.riskParams.initMarginBps = 150;
        snap.riskParams.maintMarginBps = 100;
        snap.riskParams.fadMarginBps = 300;
        snap.riskParams.minBountyAssets = 1e6;
        snap.riskParams.bountyBps = 10;
        snap.riskParams.vpiFactor = 0.0005e18;
    }

    function _order() private pure returns (CfdTypes.Order memory order) {
        order.account = address(0xBEEF);
        order.sizeDelta = 100 * Q;
        order.marginDelta = 1000e6;
    }

    function _inputs() private pure returns (OpenAccountingLib.OpenInputs memory inputs) {
        inputs.sizeDelta = 17 * Q;
        inputs.price = 123_456_789;
        inputs.capPrice = 2e8;
        inputs.poolDepthAssets = 1_000_000e6;
        inputs.postSkewAssets = 2_098_765_413;
        inputs.executionFeeBps = 4;
        inputs.riskParams = _snapshot().riskParams;
    }

    function _numeric(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Order memory order
    ) private pure {
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, 1e8);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), 11);
    }

    function test_CheckedVpiGoldenVectorsAndBothSigns() public pure {
        // Standalone Python integer vectors, with non-$1 notional, unequal skews, and one-atom dust.
        (bool ok, int256 amount) = CfdMath.tryCalculateVPI(0, 2_098_765_413, 1_000_000_000_000, 500_000_000_000_000);
        assertTrue(ok);
        assertEq(amount, 1101);
        (ok, amount) = CfdMath.tryCalculateVPI(2_098_765_413, 9_876_543_121, 1_234_567_890_123, 500_000_000_000_000);
        assertTrue(ok);
        assertEq(amount, 18_862);
        (ok, amount) = CfdMath.tryCalculateVPI(9_876_543_121, 2_098_765_413, 1_234_567_890_123, 500_000_000_000_000);
        assertTrue(ok);
        assertEq(amount, -18_862);
        (ok, amount) = CfdMath.tryCalculateVPI(1e12, 999_999_999_983, 2_222_222_222_222, 1e15);
        assertTrue(ok);
        assertEq(amount, -1);
    }

    function test_VpiSquareScaleAndFactorBoundaries() public view {
        for (uint256 i; i < 3; ++i) {
            (bool ok, uint256 value) = CfdMath.tryGetSkewCost(MAX_SKEW + i - 1, 1e30, 0);
            assertEq(ok, i < 2, "zero factor does not bypass the original square domain");
            assertEq(value, 0);
        }
        uint256 maxDepth = type(uint256).max / 1e12;
        (bool valid,) = CfdMath.tryGetSkewCost(1, maxDepth, 1);
        assertTrue(valid);
        (valid,) = CfdMath.tryGetSkewCost(1, maxDepth + 1, 1);
        assertFalse(valid);
        uint256 maxFactor = type(uint256).max / 1e12; // skew=depth=1 gives q=1e12.
        (valid,) = CfdMath.tryGetSkewCost(1, 1, maxFactor);
        assertTrue(valid);
        (valid,) = CfdMath.tryGetSkewCost(1, 1, maxFactor + 1);
        assertFalse(valid);
        assertEq(math.productionSkewCost(0, type(uint256).max, type(uint256).max), 0);
        assertEq(math.productionSkewCost(type(uint256).max, 0, type(uint256).max), 0);
    }

    function testFuzz_CheckedVpiMatchesOriginalDomain(
        uint256 skew,
        uint256 depth,
        uint256 factor
    ) public view {
        (bool valid, uint256 value) = CfdMath.tryGetSkewCost(skew, depth, factor);
        try math.oldSkewCost(skew, depth, factor) returns (uint256 oldValue) {
            assertTrue(valid);
            assertEq(value, oldValue);
        } catch (bytes memory reason) {
            assertFalse(valid);
            assertEq(reason, abi.encodeWithSignature("Panic(uint256)", 0x11));
        }
    }

    function testFuzz_InDomainVpiMatchesIndependentIntegerFormula(
        uint128 skewSeed,
        uint128 depthSeed,
        uint64 factorSeed
    ) public view {
        uint256 skew = bound(skewSeed, 1, 1e20);
        uint256 depth = bound(depthSeed, 1e6, 1e26);
        uint256 factor = bound(factorSeed, 0, 1e18);
        // Cancel one scaling factor before squaring; combine the exact divisors. This independent calculation is
        // deliberately restricted to a domain where both representations' intermediate products fit.
        uint256 expected = (skew * skew * 1e12 / depth) * factor / 2e30;
        (bool valid, uint256 actual) = CfdMath.tryGetSkewCost(skew, depth, factor);
        assertTrue(valid);
        assertEq(actual, expected);
    }

    function test_RevertingWrapperStillPanicsOutsideDomain() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        math.productionSkewCost(MAX_SKEW + 1, 1e30, 0);
    }

    function test_NumericGuardFaultControlExposesOriginalPanic() public {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        snap.poolAssets = 1e30;
        snap.poolCashAssets = 1e30;
        uint256 lots = (MAX_SKEW + 1) / 1e8 + 1;
        snap.shortSide.openInterest = lots * Q;
        _numeric(snap, _order());
        // Bypassing the checked construction reproduces the original reachable intermediate overflow.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        math.oldSkewCost(lots * 1e8, snap.poolAssets, snap.riskParams.vpiFactor);
    }

    function test_OpenNonDollarGoldenState() public pure {
        (bool valid, OpenAccountingLib.OpenState memory state, uint256 raw) =
            OpenAccountingLib.tryBuildOpenState(_inputs());
        assertTrue(valid);
        assertEq(state.newSize, 17 * Q);
        assertEq(state.newEntryCostAssetAtoms, 2_098_765_413);
        assertEq(state.newEntryPrice, 123_456_789);
        assertEq(state.vpiAssets, 1101);
        assertEq(state.executionFeeAssets, 839_506);
        assertEq(state.tradeCostAssets, 840_607);
        assertEq(state.initialMarginRequirementAssets, 31_481_481);
        assertEq(state.maintenanceMarginAssets, 20_987_654);
        assertEq(raw, 2_098_765);
    }

    function testFuzz_ValidOpenEconomicsAtCappedAndNonDollarPrices(
        uint16 lotSeed,
        uint32 priceSeed,
        bool shortSide
    ) public view {
        uint256 lots = bound(lotSeed, 17, 500);
        uint256 mark = bound(priceSeed, 60_000_000, 300_000_000);
        uint256 price = mark > 200_000_000 ? 200_000_000 : mark;
        uint256 notional = lots * price;
        uint256 fee = notional * 4 / 10_000;
        uint256 reserve = notional * 10 / 10_000;
        uint256 vpi = (notional * notional * 1e12 / 1_000_000e6) * 0.0005e18 / 2e30;
        CfdTypes.Order memory order = _order();
        order.sizeDelta = lots * Q;
        order.marginDelta = 10_000e6;
        order.side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(_snapshot(), order, mark);
        assertTrue(delta.valid);
        assertEq(delta.newPosEntryCostAssetAtoms, notional);
        assertEq(delta.posVpiAccruedDelta, int256(vpi));
        assertEq(delta.executionFeeAssets, fee);
        assertEq(delta.liquidationReserveAfterAssets, reserve);
        assertEq(delta.positionMarginAfterOpen, 10_000e6 - fee - reserve - vpi);
        assertEq(delta.posMaxProfitIncrease, shortSide ? lots * 200_000_000 - notional : notional);
    }

    function test_SideMarginReplacementDoesNotAddBeforeSubtracting() public pure {
        uint256 signedMax = uint256(type(int256).max);
        assertEq(CfdEnginePlanLib.computeSideTotalMarginAfterOpen(signedMax - 10, 20, 30), signedMax);
        assertEq(CfdEnginePlanLib.computeSideTotalMarginAfterOpen(type(uint256).max, 30, 20), type(uint256).max - 10);
    }

    function test_TerminalBookGrossLotBudgetBothSidesAndAdjacentLots() public pure {
        uint256 maxLots = uint256(int256(type(int112).max));
        for (uint256 side; side < 2; ++side) {
            for (uint256 i; i < 3; ++i) {
                CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
                uint256 oldLots = maxLots + i - 2;
                uint256 longLots = oldLots / 2;
                uint256 shortLots = oldLots - longLots;
                snap.longSide.openInterest = longLots * Q;
                snap.shortSide.openInterest = shortLots * Q;
                snap.longSide.entryNotional = longLots * 1e8 * Q;
                snap.shortSide.entryNotional = shortLots * 1e8 * Q;
                snap.longSide.maxProfitAssets = longLots * 1e8;
                snap.shortSide.maxProfitAssets = shortLots * 1e8;
                snap.poolAssets = 1e44; // balanced sides keep VPI in-domain at the aggregate lot boundary.
                snap.poolCashAssets = 1e44;
                snap.riskParams.minBountyAssets = 1;
                CfdTypes.Order memory order = _order();
                order.side = CfdTypes.Side(side);
                order.sizeDelta = Q;
                order.marginDelta = 10e6;
                CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, 1e8);
                assertEq(delta.valid, i < 2);
                assertEq(uint8(delta.revertCode), i < 2 ? 0 : 11);
            }
        }
    }

    function test_TerminalBookConservativeInterceptEnvelopeBoundary() public pure {
        uint256 maxIntercept = uint256(int256(type(int144).max));
        uint256 cap = type(uint32).max;
        uint256 longLots = maxIntercept / (3 * cap) + 1;
        uint256 shortEntryAtBoundary = (maxIntercept - longLots * cap) / 2;
        for (uint256 i; i < 3; ++i) {
            CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
            snap.capPrice = cap;
            snap.longSide.openInterest = longLots * Q;
            snap.longSide.entryNotional = longLots * cap * Q;
            snap.longSide.maxProfitAssets = longLots * cap;
            uint256 oldShortEntry = shortEntryAtBoundary - cap + i - 1;
            uint256 oldShortLots = longLots; // balanced OI isolates the intercept bound from VPI's square bound.
            snap.shortSide.openInterest = oldShortLots * Q;
            snap.shortSide.entryNotional = oldShortEntry * Q;
            snap.shortSide.maxProfitAssets = oldShortLots * cap - oldShortEntry;
            snap.poolAssets = 1e44;
            snap.poolCashAssets = 1e44;
            snap.riskParams.minBountyAssets = 1;
            CfdTypes.Order memory order = _order();
            order.side = CfdTypes.Side.SHORT;
            order.sizeDelta = Q;
            CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, cap);
            assertEq(delta.valid, i < 2);
            assertEq(uint8(delta.revertCode), i < 2 ? 0 : 11);
        }
    }

    function test_OpenLotAndEntryStorageBoundaries() public pure {
        OpenAccountingLib.OpenInputs memory inputs = _inputs();
        inputs.poolDepthAssets = 0;
        inputs.price = type(uint32).max;
        inputs.capPrice = type(uint32).max;
        for (uint256 i; i < 3; ++i) {
            inputs.sizeDelta = (uint256(type(uint112).max) + i - 1) * Q;
            (bool valid,,) = OpenAccountingLib.tryBuildOpenState(inputs);
            assertEq(valid, i < 2);
        }
        inputs.sizeDelta = Q;
        inputs.currentSize = Q;
        for (uint256 i; i < 3; ++i) {
            inputs.currentEntryCostAssetAtoms = uint256(type(uint144).max) - inputs.price + i - 1;
            (bool valid,,) = OpenAccountingLib.tryBuildOpenState(inputs);
            assertEq(valid, i < 2);
        }
        inputs.currentEntryCostAssetAtoms = 0;
        inputs.currentSize = uint256(type(uint112).max) * Q;
        (bool valid,,) = OpenAccountingLib.tryBuildOpenState(inputs);
        assertFalse(valid, "increase cannot overflow existing lot storage");
    }

    function test_RequestQuantumAndMarginBoundsAreTyped() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        order.sizeDelta = (uint256(type(uint112).max) + 1) * Q;
        _numeric(snap, order);
        order.sizeDelta += 1;
        assertEq(uint8(CfdEnginePlanLib.planOpen(snap, order, 1e8).revertCode), 8);
        order = _order();
        order.marginDelta = uint256(type(int256).max) + 1;
        _numeric(snap, order);
        order.marginDelta = uint256(type(int256).max);
        assertEq(uint8(CfdEnginePlanLib.planOpen(snap, order, 1e8).revertCode), 5, "in-domain but unfunded");
    }

    function test_AggregateExposureAndVpiBoundsAreTyped() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        snap.longSide.openInterest = type(uint256).max - order.sizeDelta + 1;
        _numeric(snap, order);
        snap = _snapshot();
        snap.shortSide.openInterest = type(uint256).max / snap.capPrice + 1;
        _numeric(snap, order);
        snap = _snapshot();
        snap.poolAssets = 1e30;
        snap.poolCashAssets = 1e30;
        snap.shortSide.openInterest = ((MAX_SKEW + 1) / 1e8 + 1) * Q;
        _numeric(snap, order); // healing open still reaches invalid pre-skew square.
    }

    function test_StaleHugeSizeFixtureRejectsSkewBeforeVpi() public pure {
        CfdTypes.Order memory order = _order();
        order.sizeDelta = 1e39;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(_snapshot(), order, 1e8);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), 4);
    }

    function test_BountyProductAndMinimumDoNotPanic() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        snap.riskParams.bountyBps = type(uint256).max;
        _numeric(snap, order);
        snap = _snapshot();
        snap.riskParams.minBountyAssets = type(uint256).max;
        assertEq(uint8(CfdEnginePlanLib.planOpen(snap, order, 1e8).revertCode), 3);
        OpenAccountingLib.OpenInputs memory inputs = _inputs();
        inputs.riskParams.bountyBps = type(uint256).max / (17 * inputs.price);
        (bool valid,,) = OpenAccountingLib.tryBuildOpenState(inputs);
        assertTrue(valid);
        inputs.riskParams.bountyBps += 1;
        (valid,,) = OpenAccountingLib.tryBuildOpenState(inputs);
        assertFalse(valid);
    }

    function test_MinimumBountyQuotientEqualityAndAdjacentAtoms() public pure {
        for (uint256 i; i < 3; ++i) {
            CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
            snap.riskParams.minBountyAssets = 10e6 + i - 1;
            CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, _order(), 1e8);
            assertEq(delta.valid, i < 2);
            assertEq(uint8(delta.revertCode), i < 2 ? 0 : 3);
        }
    }

    function test_LifetimeVpiSignedEqualityAndAdjacentAtoms() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        snap.position.vpiAccrued = type(int256).max - 25_000;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, _order(), 1e8);
        assertTrue(delta.valid, "maximum lifetime sum remains representable");
        snap = _snapshot();
        snap.position.vpiAccrued = type(int256).max - 24_999;
        _numeric(snap, _order());
        snap = _snapshot();
        snap.shortSide.openInterest = 500 * Q;
        snap.position.vpiAccrued = type(int256).min + 225_000;
        _numeric(snap, _order()); // -225,000 VPI would produce the unusable int256.min.
        snap.position.vpiAccrued += 1;
        assertEq(
            uint8(CfdEnginePlanLib.planOpen(snap, _order(), 1e8).revertCode),
            10,
            "one atom above min is numeric-safe but still needs reserve backing"
        );
    }

    function test_LifetimeAndSettlementHeadroomAreTyped() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        snap.position.vpiAccrued = type(int256).max;
        _numeric(snap, order);
        snap.position.vpiAccrued = type(int256).min;
        _numeric(snap, order);
        snap = _snapshot();
        snap.shortSide.openInterest = 500 * Q;
        snap.accountBuckets.settlementBalanceAssets = type(uint256).max;
        snap.accountBuckets.freeSettlementAssets = type(uint256).max;
        snap.riskParams.vpiFactor = 1e18;
        _numeric(snap, order);
        snap = _snapshot();
        snap.poolCashAssets = type(uint256).max;
        _numeric(snap, order);
        snap = _snapshot();
        snap.longSide.entryNotional = type(uint256).max;
        _numeric(snap, order);
        snap = _snapshot();
        snap.longSide.maxProfitAssets = type(uint256).max;
        _numeric(snap, order);
        snap = _snapshot();
        snap.poolAssets = type(uint256).max;
        snap.totalTraderClaimBalanceAssets = type(uint256).max - 1_000_000e6;
        snap.longSide.maxProfitAssets = 1_000_000e6;
        _numeric(snap, order);
        snap = _snapshot();
        snap.longSide.totalMargin = type(uint256).max;
        _numeric(snap, order);
        snap = _snapshot();
        snap.poolCashAssets = type(uint256).max;
        snap.traderClaimBalanceForAccount = uint256(type(int256).max);
        snap.totalTraderClaimBalanceAssets = snap.traderClaimBalanceForAccount;
        snap.poolAssets = snap.totalTraderClaimBalanceAssets + 1_000_000e6;
        _numeric(snap, order);
    }

    function test_HealingExceptionRequiresPositiveEconomicDepth() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        snap.shortSide.openInterest = 500 * Q;
        snap.riskParams.maxSkewRatio = 0;
        assertTrue(CfdEnginePlanLib.planOpen(snap, order, 1e8).valid);
        snap = _snapshot();
        snap.poolAssets = 0;
        snap.riskParams.vpiFactor = type(uint256).max;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, 1e8);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
    }

    function test_CloseSideMismatchPrecedesCarryAndMissingPositionKeepsSizeCode() public pure {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdTypes.Order memory order = _order();
        order.isClose = true;
        order.side = CfdTypes.Side.SHORT;
        snap.position.size = order.sizeDelta;
        snap.positionBorrowBaseAssets = type(uint256).max;
        snap.longSide.carryIndex = type(uint256).max; // proves mismatch cannot touch even an unusable carry snapshot.
        CfdEnginePlanTypes.CloseDelta memory delta = CfdEnginePlanLib.planClose(snap, order, 1e8);
        assertEq(uint8(delta.revertCode), 7);
        assertEq(delta.pendingCarryAssets, 0);
        snap.position.size = 0;
        assertEq(uint8(CfdEnginePlanLib.planClose(snap, order, 1e8).revertCode), 1);
    }

    function test_InvalidPreviewDoesNotRecomputeOverflowingLifetimeVpi() public {
        NumericDomainLensHarness lens = new NumericDomainLensHarness();
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        snap.position.vpiAccrued = type(int256).max;
        CfdEnginePlanTypes.OpenDelta memory delta;
        delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED;
        delta.posVpiAccruedDelta = 1;
        ICfdEngineTypes.OpenPreview memory preview = lens.formatOpen(snap, delta, planner);
        assertFalse(preview.valid);
        assertEq(uint8(preview.invalidReason), 11);
        assertEq(uint8(preview.failureCategory), 1);
        assertEq(uint8(CfdEnginePlanLib.getExecutionFailurePolicyCategory(delta.revertCode)), 2);
        delta.revertCode = CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES;
        delta.posVpiAccruedDelta = 0;
        preview = lens.formatOpen(snap, delta, planner);
        assertFalse(preview.valid);
        assertEq(preview.postVpiAccrued, type(int256).max, "ordinary invalid diagnostics remain available");
    }

}

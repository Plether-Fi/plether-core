// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    OracleSynchronizationRejectingKeeper,
    OracleSynchronizationScenarioBase
} from "./helpers/OracleSynchronizationScenarioBase.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MarketCalendarLib} from "@plether/perps/libraries/MarketCalendarLib.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

/// @notice V3-only release scenarios against authentic Pyth on pinned archival forks.
/// @dev Run through run-oracle-sync-fork.py with --scenario-manifest, which requires --isolate.
///      Gas is the external Router call delta, excluding transaction intrinsic and Arbitrum L1 data fees.
contract OracleSynchronizationGasForkTest is OracleSynchronizationScenarioBase {

    function test_RealPythGas_HistoricalSingle() public {
        SignedFixture memory f = _fixture("historicalA");
        _prepareScenario(f);
        uint64 id = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        _advanceScenario(f.executionTime);
        IPletherOracle.PriceSnapshot memory expected = _expectedHistorical(f, f.data);
        ScenarioEvidence memory e = _newEvidence("historical_single", f.data, 5, f.publishTimes);
        _expectHistoricalParse(f.commitTime, f.data, e.quoteWei);
        _expectStorageUpdates(f.data, e.quoteWei, 1);
        _executeSuccessfulSingle(id, f.data, expected, false, e);
    }

    function test_RealPythGas_SharedBasketBatch() public {
        SignedFixture memory f = _fixture("historicalA");
        _prepareScenario(f);
        uint64 first = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        uint64 last = _commitScenarioOrder(SCENARIO_BOB, false, 1);
        _advanceScenario(f.executionTime);
        IPletherOracle.PriceSnapshot memory expected = _expectedHistorical(f, f.data);
        ScenarioEvidence memory e = _newEvidence("shared_basket_batch", f.data, 5, f.publishTimes);
        _expectHistoricalParse(f.commitTime, f.data, e.quoteWei);
        _expectStorageUpdates(f.data, e.quoteWei, 1);
        uint256 payerBefore = address(this).balance;
        uint256 pythBefore = REAL_PYTH.balance;
        _startRecordingLogs();
        uint256 gasBefore = gasleft();
        OrderV3Types.BatchResult memory result =
            router.executeOrderBatch{value: e.fundedWei, gas: SCENARIO_GAS_CAP}(last, f.data);
        e.callGas = gasBefore - gasleft();
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(uint256(result.stopReason), uint256(OrderV3Types.PendingReason.None));
        _assertExecutedReceipt(first, SCENARIO_ALICE, expected, false);
        _assertExecutedReceipt(last, SCENARIO_BOB, expected, false);
        _completeImmediateEvidence(e, payerBefore, pythBefore, 2);
        _assertInstalledMark(expected);
        e.outcome = "executed";
        e.terminalCount = result.terminalCount;
        e.expectedParseCalls = 1;
        e.expectedUpdateCalls = 1;
        _setOrderEvidence(e, first, 2);
        e.liveReadChecked = true;
        assertGt(pletherOracle.getLatestPrice(), 0);
        _emitEvidence(e, f.data);
    }

    function test_RealPythGas_DistinctBasketBatch() public {
        SignedFixture memory a = _fixture("historicalA");
        SignedFixture memory b = _fixture("historicalB");
        _assertCompatible(a, b);
        _prepareScenario(a);
        uint64 first = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        assertGe(b.commitTime, _minimum(a.publishTimes), "second commit must invalidate first cache");
        _advanceScenario(b.commitTime);
        uint64 last = _commitScenarioOrder(SCENARIO_BOB, false, 1);
        _advanceScenario(b.executionTime);
        bytes[] memory data = _concatenate(a.data, b.data);
        IPletherOracle.PriceSnapshot memory firstExpected = _expectedHistorical(a, data);
        IPletherOracle.PriceSnapshot memory lastExpected = _expectedHistorical(b, data);
        ScenarioEvidence memory e = _newEvidence("distinct_basket_batch", data, 6, b.publishTimes);
        _expectHistoricalParse(a.commitTime, data, e.quoteWei);
        _expectHistoricalParse(b.commitTime, data, e.quoteWei);
        _expectStorageUpdates(data, e.quoteWei, 2);
        uint256 payerBefore = address(this).balance;
        uint256 pythBefore = REAL_PYTH.balance;
        _startRecordingLogs();
        uint256 gasBefore = gasleft();
        OrderV3Types.BatchResult memory result =
            router.executeOrderBatch{value: e.fundedWei, gas: SCENARIO_GAS_CAP}(last, data);
        e.callGas = gasBefore - gasleft();
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(uint256(result.stopReason), uint256(OrderV3Types.PendingReason.None));
        _assertExecutedReceipt(first, SCENARIO_ALICE, firstExpected, false);
        _assertExecutedReceipt(last, SCENARIO_BOB, lastExpected, false);
        _completeImmediateEvidence(e, payerBefore, pythBefore, 4);
        _assertInstalledMark(lastExpected);
        e.outcome = "executed";
        e.terminalCount = result.terminalCount;
        e.expectedParseCalls = 2;
        e.expectedUpdateCalls = 2;
        _setOrderEvidence(e, first, 2);
        e.liveReadChecked = true;
        assertGt(pletherOracle.getLatestPrice(), 0);
        _emitEvidence(e, data);
    }

    function test_RealPythGas_NaturalFrozenClose() public {
        SignedFixture memory opening = _fixture("fridayOpening");
        SignedFixture memory closing = _fixture("fridayClosing");
        _assertCompatible(opening, closing);
        _prepareScenario(opening);
        assertFalse(engine.isFadWindow(), "opening must precede Friday FAD");
        uint64 openId = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        _advanceScenario(opening.executionTime);
        assertFalse(engine.isFadWindow());
        OrderV3Types.ExecutionResult memory opened = router.executeOrder{
            value: 2 * IPyth(REAL_PYTH).getUpdateFee(opening.data), gas: SCENARIO_GAS_CAP
        }(
            openId, opening.data
        );
        assertEq(uint256(opened.status), uint256(OrderV3Types.LifecycleStatus.Executed));
        uint256 day = closing.executionTime / 1 days;
        assertEq((day + 4) % 7, 5, "closing fixture must be Friday");
        assertEq(opening.executionTime / 1 days, day, "fixtures must share their Friday");
        uint256 boundary = day * 1 days + MarketCalendarLib.newYorkMarketBoundary(closing.executionTime, 5);
        assertLt(closing.executionTime, boundary, "closing signed update must precede market close");
        _advanceScenario(boundary);
        assertTrue(engine.isFadWindow());
        assertTrue(pletherOracle.isOracleFrozen(), "natural Friday boundary must freeze oracle");
        uint64 closeId = _commitScenarioOrder(SCENARIO_ALICE, true, type(uint256).max);
        _advanceScenario(boundary + 1);
        IPletherOracle.PriceSnapshot memory expected = _expectedFrozen(uint64(boundary), closing.data);
        ScenarioEvidence memory e = _newEvidence("frozen_close", closing.data, 5, closing.publishTimes);
        assertEq(pletherOracle.getOrderExecutionFee(closing.data), e.quoteWei);
        vm.expectCall(REAL_PYTH, abi.encodePacked(IPyth.parsePriceFeedUpdatesUnique.selector), uint64(0));
        _expectStorageUpdates(closing.data, e.quoteWei, 1);
        _executeSuccessfulSingle(closeId, closing.data, expected, true, e);
    }

    function test_RealPythGas_CaughtTargetFailure() public {
        SignedFixture memory f = _fixture("historicalA");
        _prepareScenario(f);
        uint64 id = _commitScenarioOrder(SCENARIO_ALICE, false, CAP_PRICE + 1);
        _advanceScenario(f.executionTime);
        IPletherOracle.PriceSnapshot memory expected = _expectedHistorical(f, f.data);
        ScenarioEvidence memory e = _newEvidence("caught_target_failure", f.data, 5, f.publishTimes);
        _expectHistoricalParse(f.commitTime, f.data, e.quoteWei);
        _expectStorageUpdates(f.data, e.quoteWei, 1);
        uint256 payerBefore = address(this).balance;
        uint256 pythBefore = REAL_PYTH.balance;
        _startRecordingLogs();
        uint256 gasBefore = gasleft();
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder{value: e.fundedWei, gas: SCENARIO_GAS_CAP}(id, f.data);
        e.callGas = gasBefore - gasleft();
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint256(result.terminalReason), uint256(OrderV3Types.TerminalReason.Slippage));
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), id);
        assertEq(uint256(receipt.status), uint256(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint256(receipt.reason), uint256(OrderV3Types.TerminalReason.Slippage));
        assertEq(receipt.receiptHash, result.receiptHash);
        assertEq(router.nextExecuteId(), 0);
        (uint256 size,,,,,,) = engine.positions(SCENARIO_ALICE);
        assertEq(size, 0);
        _assertInstalledMark(expected);
        _completeImmediateEvidence(e, payerBefore, pythBefore, 2);
        e.outcome = "failed";
        e.terminalCount = 1;
        e.expectedParseCalls = 1;
        e.expectedUpdateCalls = 1;
        _setOrderEvidence(e, id, 1);
        e.liveReadChecked = true;
        assertGt(pletherOracle.getLatestPrice(), 0);
        _emitEvidence(e, f.data);
    }

    function test_RealPythRefund_UnavailableImmediate() public {
        SignedFixture memory f = _fixture("historicalA");
        _prepareScenario(f);
        _advanceScenario(f.executionTime);
        uint64 commit = uint64(vm.getBlockTimestamp());
        uint64 id = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        _advanceScenario(uint256(commit) + 1);
        uint64 markBefore = engine.lastMarkTime();
        uint256 markPriceBefore = engine.lastMarkPrice();
        ScenarioEvidence memory e = _newEvidence("unavailable_immediate", f.data, 5, f.initialTimes);
        _expectHistoricalParse(commit, f.data, e.quoteWei);
        _expectStorageUpdates(f.data, e.quoteWei, 0);
        uint256 payerBefore = address(this).balance;
        uint256 pythBefore = REAL_PYTH.balance;
        uint256 gasBefore = gasleft();
        OrderV3Types.BatchResult memory result =
            router.executeOrderBatch{value: e.fundedWei, gas: SCENARIO_GAS_CAP}(id, f.data);
        e.callGas = gasBefore - gasleft();
        _assertUnavailable(result, id, f.initialTimes, markBefore, markPriceBefore);
        _completeImmediateEvidence(e, payerBefore, pythBefore, 0);
        e.outcome = "pending";
        e.expectedParseCalls = 1;
        e.oracleRefundExercised = e.quoteWei > 0;
        _setOrderEvidence(e, id, 1);
        _emitEvidence(e, f.data);
    }

    function test_RealPythRefund_UnavailableDeferred() public {
        SignedFixture memory f = _fixture("historicalA");
        _prepareScenario(f);
        _advanceScenario(f.executionTime);
        uint64 commit = uint64(vm.getBlockTimestamp());
        uint64 id = _commitScenarioOrder(SCENARIO_ALICE, false, 1);
        _advanceScenario(uint256(commit) + 1);
        uint64 markBefore = engine.lastMarkTime();
        uint256 markPriceBefore = engine.lastMarkPrice();
        OracleSynchronizationRejectingKeeper keeper = new OracleSynchronizationRejectingKeeper();
        ScenarioEvidence memory e = _newEvidence("unavailable_deferred", f.data, 5, f.initialTimes);
        _expectHistoricalParse(commit, f.data, e.quoteWei);
        _expectStorageUpdates(f.data, e.quoteWei, 0);
        uint256 pythBefore = REAL_PYTH.balance;
        OrderV3Types.BatchResult memory result;
        (result, e.callGas) = keeper.execute{value: e.fundedWei}(address(router), id, f.data, SCENARIO_GAS_CAP);
        _assertUnavailable(result, id, f.initialTimes, markBefore, markPriceBefore);
        e.pythFeeDeltaWei = REAL_PYTH.balance - pythBefore;
        assertEq(e.pythFeeDeltaWei, 0);
        assertEq(address(keeper).balance, 0);
        e.oracleCreditedWei = pletherOracle.claimableEth(address(keeper));
        e.routerCreditedWei = routerAdmin.claimableEth(address(keeper));
        assertEq(e.oracleCreditedWei, 2 * e.quoteWei);
        assertEq(e.routerCreditedWei, 3 * e.quoteWei + e.surplusWei);
        assertEq(address(pletherOracle).balance, e.oracleCreditedWei);
        assertEq(address(routerAdmin).balance, e.routerCreditedWei);
        if (e.oracleCreditedWei > 0) {
            keeper.claimOracle(pletherOracle);
            e.oracleClaimedWei = address(keeper).balance;
            assertEq(e.oracleClaimedWei, e.oracleCreditedWei);
            e.oracleRefundExercised = true;
        } else {
            // Zero Pyth fees allocate no Oracle refund and must not create a claim.
            vm.expectRevert();
            keeper.claimOracle(pletherOracle);
        }
        keeper.claimRouter(routerAdmin);
        e.routerClaimedWei = address(keeper).balance - e.oracleClaimedWei;
        assertEq(e.routerClaimedWei, e.routerCreditedWei);
        e.oracleDeferredWei = pletherOracle.claimableEth(address(keeper));
        e.routerDeferredWei = routerAdmin.claimableEth(address(keeper));
        assertEq(e.oracleDeferredWei, 0);
        assertEq(e.routerDeferredWei, 0);
        vm.expectRevert();
        keeper.claimOracle(pletherOracle);
        vm.expectRevert();
        keeper.claimRouter(routerAdmin);
        assertEq(address(keeper).balance, e.fundedWei);
        e.outcome = "pending";
        e.expectedParseCalls = 1;
        e.routerRefundExercised = true;
        _setOrderEvidence(e, id, 1);
        _emitEvidence(e, f.data);
    }

    function _executeSuccessfulSingle(
        uint64 id,
        bytes[] memory data,
        IPletherOracle.PriceSnapshot memory expected,
        bool close,
        ScenarioEvidence memory e
    ) internal {
        uint256 payerBefore = address(this).balance;
        uint256 pythBefore = REAL_PYTH.balance;
        _startRecordingLogs();
        uint256 gasBefore = gasleft();
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder{value: e.fundedWei, gas: SCENARIO_GAS_CAP}(id, data);
        e.callGas = gasBefore - gasleft();
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Executed));
        assertEq(router.nextExecuteId(), 0);
        _assertExecutedReceipt(id, SCENARIO_ALICE, expected, close);
        _assertInstalledMark(expected);
        _completeImmediateEvidence(e, payerBefore, pythBefore, close ? 1 : 2);
        e.outcome = "executed";
        e.terminalCount = 1;
        e.expectedParseCalls = close ? 0 : 1;
        e.expectedUpdateCalls = 1;
        _setOrderEvidence(e, id, 1);
        e.liveReadChecked = true;
        assertGt(pletherOracle.getLatestPrice(), 0);
        _emitEvidence(e, data);
    }

    function _completeImmediateEvidence(
        ScenarioEvidence memory e,
        uint256 payerBefore,
        uint256 pythBefore,
        uint256 feeMultiplier
    ) internal view {
        e.pythFeeDeltaWei = REAL_PYTH.balance - pythBefore;
        assertEq(e.pythFeeDeltaWei, feeMultiplier * e.quoteWei);
        assertEq(payerBefore - address(this).balance, e.pythFeeDeltaWei);
        e.immediateRefundWei = e.fundedWei - (payerBefore - address(this).balance);
        e.routerRefundExercised = e.immediateRefundWei > 0;
        assertEq(pletherOracle.claimableEth(address(this)), 0);
        assertEq(routerAdmin.claimableEth(address(this)), 0);
    }

    function _assertInstalledMark(
        IPletherOracle.PriceSnapshot memory expected
    ) internal view {
        assertEq(engine.lastMarkTime(), expected.publishTime);
        assertEq(engine.lastMarkPrice(), expected.markPrice);
    }

    function _assertUnavailable(
        OrderV3Types.BatchResult memory result,
        uint64 id,
        uint256[] memory initialTimes,
        uint64 markBefore,
        uint256 markPriceBefore
    ) internal view {
        assertEq(result.terminalCount, 0);
        assertEq(result.nextOrderId, id);
        assertEq(uint256(result.stopReason), uint256(OrderV3Types.PendingReason.HistoricalPriceUnavailable));
        assertEq(uint256(router.lifecycleBook().lifecycleStatus(id)), uint256(OrderV3Types.LifecycleStatus.Pending));
        assertEq(engine.lastMarkTime(), markBefore);
        assertEq(engine.lastMarkPrice(), markPriceBefore);
        (uint256 size,,,,,,) = engine.positions(SCENARIO_ALICE);
        assertEq(size, 0);
        _assertStoredTimes(initialTimes);
    }

    function _minimum(
        uint256[] memory values
    ) internal pure returns (uint256 minimum) {
        minimum = type(uint256).max;
        for (uint256 i; i < values.length; ++i) {
            if (values[i] < minimum) {
                minimum = values[i];
            }
        }
    }

    function _concatenate(
        bytes[] memory a,
        bytes[] memory b
    ) internal pure returns (bytes[] memory combined) {
        combined = new bytes[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            combined[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            combined[a.length + i] = b[i];
        }
    }

}

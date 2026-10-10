// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {OracleSynchronizationHandler} from "../../invariant/handlers/OracleSynchronizationHandler.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

/// @dev These controls invoke the real state-machine handler through actual Router/Oracle dependencies.
///      Mocked faults must fail its observability checks; merely comparing fabricated checker inputs is insufficient.
contract OracleSynchronizationHandlerTest is BasePerpTest {

    error UnrelatedDependencyFailure();

    uint64 internal constant PAR_PRICE_SEED = 1_000_000;
    address internal constant FIRST_HANDLER_TRADER = address(100_001);
    OracleSynchronizationHandler internal handler;

    function setUp() public override {
        super.setUp();
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        handler =
            new OracleSynchronizationHandler(router, engine, clearinghouse, baseMockPyth, usdc, _basePythFeedIds());
    }

    function test_HealthyExecutionSettlesCustodyAndBountyOnce() public {
        _assertSingleExecution(false, false, 0, 0, 0);
    }

    function test_InjectedWriteFailureRollsBackThenHealthyRetrySettlesOnce() public {
        _assertSingleExecution(false, true, 1, 0, 1);
    }

    function test_InjectedSkippedWriteRollsBackThenHealthyRetrySettlesOnce() public {
        _assertSingleExecution(true, false, 0, 1, 1);
    }

    function test_WriteFailureTakesPrecedenceOverSkippedWrite() public {
        _assertSingleExecution(true, true, 1, 0, 1);
    }

    function test_OddComponentPriceUsesRoundedBasketForMarkAndPosition() public {
        uint64 rawPrice = 100_000_001;
        uint64 tick = uint64(vm.getBlockTimestamp() + 1);
        handler.execute(PAR_PRICE_SEED + 1, 0, false, false);
        bytes32[] memory feeds = _basePythFeedIds();
        for (uint256 i; i < feeds.length; ++i) {
            assertEq(baseMockPyth.getPriceUnsafe(feeds[i]).price, int64(rawPrice));
            assertEq(baseMockPyth.getPriceUnsafe(feeds[i]).publishTime, tick);
        }
        uint256 basket = 2 * (uint256(rawPrice) / 2);
        assertEq(engine.lastMarkPrice(), basket);
        assertEq(engine.lastMarkTime(), tick);
        (uint256 size,, uint256 entry, uint256 maxProfit, CfdTypes.Side side,,) = engine.positions(FIRST_HANDLER_TRADER);
        assertEq(size, 2000e18);
        assertEq(entry, basket);
        assertEq(uint8(side), uint8(CfdTypes.Side.SHORT));
        assertEq(maxProfit, 20 * (CAP_PRICE - basket));
        assertEq(engine.positionEntryCostUsdcAtoms(FIRST_HANDLER_TRADER), 20 * basket);
        assertEq(handler.executed(), 1);
        assertEq(handler.resolutions(), 1);
    }

    function test_UnexpectedOracleCustomErrorFailsHandler() public {
        _assertUnexpectedOracleRevert(abi.encodeWithSelector(UnrelatedDependencyFailure.selector), false, false);
    }

    function test_UnexpectedOracleEmptyRevertFailsHandler() public {
        _assertUnexpectedOracleRevert(bytes(""), false, false);
    }

    function test_UnexpectedOraclePanicFailsHandler() public {
        _assertUnexpectedOracleRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)), false, false);
    }

    function test_UnrelatedOracleErrorCannotMasqueradeAsInjectedWriteFailure() public {
        _assertUnexpectedOracleRevert(abi.encodeWithSelector(UnrelatedDependencyFailure.selector), false, true);
    }

    function test_WrongCoverageErrorArgumentsCannotMasqueradeAsInjectedFailure() public {
        bytes memory wrongFailure = abi.encodeWithSelector(
            IPletherOracle.PletherOracle__StoredFeedBehind.selector,
            bytes32(uint256(999)),
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + 1
        );
        _assertUnexpectedOracleRevert(wrongFailure, true, false);
    }

    function test_UnexpectedEvaluatorFailureCannotCountAsResolution() public {
        _assertUnexpectedEvaluatorFailure(false, false);
    }

    function test_UnexpectedEvaluatorFailureOnWriteFailureRetryIsNotSwallowed() public {
        // The first attempt fails in Pyth. The mock is first reached by the subsequent healthy retry.
        _assertUnexpectedEvaluatorFailure(false, true);
    }

    function test_UnexpectedEvaluatorFailureOnSkippedWriteRetryIsNotSwallowed() public {
        _assertUnexpectedEvaluatorFailure(true, false);
    }

    function test_MissingInjectedFailureCannotMasqueradeAsExpectedRollback() public {
        uint64 headBefore = router.nextExecuteId();
        uint64 commitBefore = router.nextCommitId();
        // Disable the fault setter itself: the requested write failure never occurs, so the real execution succeeds.
        vm.mockCall(address(baseMockPyth), abi.encodeWithSelector(MockPyth.setUpdateFailure.selector), bytes(""));
        vm.expectRevert(OracleSynchronizationHandler.ExpectedOracleRevertNotObserved.selector);
        handler.execute(PAR_PRICE_SEED, 0, false, true);
        vm.clearMockedCalls();
        assertEq(handler.resolutions(), 0);
        assertEq(handler.attempts(), 0);
        assertEq(router.nextCommitId(), commitBefore);
        assertEq(router.nextExecuteId(), headBefore);
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        assertEq(handler.executed(), 1, "unmocked control must restore a healthy execution");
    }

    function test_ApparentOracleSuccessWithoutStoredFeedUpdatesFailsHandler() public {
        uint64 headBefore = router.nextExecuteId();
        uint64 commitBefore = router.nextCommitId();
        IPletherOracle.PriceSnapshot memory forgedSnapshot = IPletherOracle.PriceSnapshot({
            price: 100_000_000,
            markPrice: 100_000_000,
            publishTime: uint64(vm.getBlockTimestamp() + 1),
            updateFee: 0,
            maxStaleness: 60,
            closeOnly: false,
            oracleFrozen: false,
            isFadWindow: false
        });
        // The real Router can apply this successful-looking response, but neither Pyth counter nor feed is updated.
        vm.mockCall(
            address(pletherOracle),
            abi.encodeWithSelector(IPletherOracle.updateOrderExecutionPrice.selector),
            abi.encode(true, forgedSnapshot)
        );
        vm.expectPartialRevert(OracleSynchronizationHandler.SynchronizationMismatch.selector);
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        vm.clearMockedCalls();
        assertEq(handler.resolutions(), 0);
        assertEq(router.nextCommitId(), commitBefore);
        assertEq(router.nextExecuteId(), headBefore);
        assertEq(baseMockPyth.parseUniqueCallCount(), 0);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), 0);
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        assertEq(handler.executed(), 1);
    }

    function test_FourPersistentActionsEachReachOneTerminalExecution() public {
        uint256 cashBefore = usdc.balanceOf(address(clearinghouse));
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        handler.execute(PAR_PRICE_SEED, 1, false, true);
        handler.execute(PAR_PRICE_SEED, 2, true, false);
        handler.execute(PAR_PRICE_SEED, 3, true, true);
        assertEq(handler.attempts(), 4);
        assertEq(handler.executed(), 4);
        assertEq(handler.resolutions(), 4);
        assertEq(handler.injectedWriteFailures(), 2);
        assertEq(handler.injectedCoverageFailures(), 1);
        assertEq(handler.healthyRetries(), 3);
        assertEq(handler.plannerRejected(), 0);
        assertEq(handler.commitRejected(), 0);
        assertEq(baseMockPyth.parseUniqueCallCount(), 4);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), 4);
        assertEq(clearinghouse.balanceUsdc(address(handler)), 4 * 200_000);
        assertEq(usdc.balanceOf(address(clearinghouse)), cashBefore + 4 * 2000e6);
        assertEq(router.nextExecuteId(), 0);
        for (uint64 id = 1; id <= 4; ++id) {
            assertEq(uint8(router.lifecycleBook().lifecycleStatus(id)), uint8(OrderV3Types.LifecycleStatus.Executed));
            address trader = address(uint160(100_000 + id));
            assertEq(clearinghouse.getAccountReservationSummary(trader).activeReservationCount, 0);
            assertEq(clearinghouse.totalBountyReservationsUsdc(trader), 0);
        }
    }

    function _assertSingleExecution(
        bool skipWrite,
        bool failWrite,
        uint256 expectedWriteFailures,
        uint256 expectedCoverageFailures,
        uint256 expectedRetries
    ) internal {
        uint256 poolCashBefore = usdc.balanceOf(address(pool));
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 treasuryBefore = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        handler.execute(PAR_PRICE_SEED, 0, skipWrite, failWrite);
        assertEq(handler.attempts(), 1);
        assertEq(handler.executed(), 1);
        assertEq(handler.resolutions(), 1);
        assertEq(handler.plannerRejected(), 0);
        assertEq(handler.commitRejected(), 0);
        assertEq(handler.injectedWriteFailures(), expectedWriteFailures);
        assertEq(handler.injectedCoverageFailures(), expectedCoverageFailures);
        assertEq(handler.healthyRetries(), expectedRetries);
        assertEq(baseMockPyth.parseUniqueCallCount(), 1);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), 1);
        assertEq(router.nextExecuteId(), 0);
        assertEq(router.nextCommitId(), 2);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(1)), uint8(OrderV3Types.LifecycleStatus.Executed));

        // 20 lots at $1: the 4-bps execution fee is 0.8 USDC and the 1-bps bounty is 0.2 USDC.
        // Both recipients receive internal custody credits; no wallet transfer or pool inflow is expected.
        assertEq(engine.executionFeeBps(), 4);
        assertEq(router.openOrderExecutionBountyBps(), 1);
        assertEq(clearinghouse.balanceUsdc(FIRST_HANDLER_TRADER), 2000e6 - 800_000 - 200_000);
        assertEq(clearinghouse.balanceUsdc(address(handler)), 200_000);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), treasuryBefore + 800_000);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore + 2000e6);
        assertEq(usdc.balanceOf(address(pool)), poolCashBefore);
        assertEq(usdc.balanceOf(FIRST_HANDLER_TRADER), 0);
        assertEq(usdc.balanceOf(address(handler)), 0);
        assertEq(clearinghouse.getOrderReservation(1).remainingAmountUsdc, 0);
        assertEq(clearinghouse.getAccountReservationSummary(FIRST_HANDLER_TRADER).activeReservationCount, 0);
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, 1);
        assertEq(bounty.account, FIRST_HANDLER_TRADER);
        assertEq(bounty.amountUsdc, 0);
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
        assertEq(clearinghouse.totalBountyReservationsUsdc(FIRST_HANDLER_TRADER), 0);

        vm.prank(address(handler));
        vm.expectPartialRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrder(1, new bytes[](0));
        assertEq(clearinghouse.balanceUsdc(address(handler)), 200_000, "terminal replay cannot pay again");
        assertEq(clearinghouse.balanceUsdc(FIRST_HANDLER_TRADER), 2000e6 - 800_000 - 200_000);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore + 2000e6);
    }

    function _assertUnexpectedOracleRevert(
        bytes memory failure,
        bool skipWrite,
        bool failWrite
    ) internal {
        uint64 headBefore = router.nextExecuteId();
        uint64 commitBefore = router.nextCommitId();
        vm.mockCallRevert(
            address(pletherOracle), abi.encodeWithSelector(IPletherOracle.updateOrderExecutionPrice.selector), failure
        );
        vm.expectPartialRevert(OracleSynchronizationHandler.UnexpectedOracleRevert.selector);
        handler.execute(PAR_PRICE_SEED, 0, skipWrite, failWrite);
        vm.clearMockedCalls();
        assertEq(handler.resolutions(), 0, "unexpected oracle error cannot earn resolution credit");
        assertEq(handler.attempts(), 0, "fatal handler failure rolls back the complete attempted action");
        assertEq(router.nextCommitId(), commitBefore);
        assertEq(router.nextExecuteId(), headBefore);
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        assertEq(handler.executed(), 1, "unmocked control must reach the real execution path");
    }

    function _assertUnexpectedEvaluatorFailure(
        bool skipWrite,
        bool failWrite
    ) internal {
        uint64 headBefore = router.nextExecuteId();
        uint64 commitBefore = router.nextCommitId();
        vm.mockCallRevert(
            address(policyEvaluator),
            abi.encodeWithSelector(ICfdOrderPolicyEvaluator.assessCommittedOrder.selector),
            abi.encodeWithSelector(UnrelatedDependencyFailure.selector)
        );
        vm.expectPartialRevert(OracleSynchronizationHandler.UnexpectedExecutionOutcome.selector);
        handler.execute(PAR_PRICE_SEED, 0, skipWrite, failWrite);
        vm.clearMockedCalls();
        assertEq(handler.resolutions(), 0, "Pending.EngineFailure cannot earn resolution credit");
        assertEq(handler.healthyRetries(), 0, "an unsuccessful retry is not healthy progress");
        assertEq(handler.attempts(), 0);
        assertEq(router.nextCommitId(), commitBefore);
        assertEq(router.nextExecuteId(), headBefore);
        handler.execute(PAR_PRICE_SEED, 0, false, false);
        assertEq(handler.executed(), 1, "clearing the evaluator fault restores the healthy control");
    }

}

/// @dev Small cash fixture reaches the economic boundary in five successful commits, without storage mutation.
abstract contract OracleSynchronizationAdmissionBase is BasePerpTest {

    OracleSynchronizationHandler internal handler;

    function setUp() public override {
        super.setUp();
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        handler =
            new OracleSynchronizationHandler(router, engine, clearinghouse, baseMockPyth, usdc, _basePythFeedIds());
    }

    function _initialJuniorDeposit() internal pure virtual override returns (uint256) {
        return 4015e6;
    }

    function _fourBalancedOpens() internal {
        for (uint256 i; i < 4; ++i) {
            handler.execute(1_000_000, 0, false, false);
        }
        assertEq(handler.executed(), 4);
        assertEq(handler.resolutions(), 4);
        assertEq(handler.commitRejected(), 0);
        assertEq(handler.plannerRejected(), 0);
        assertEq(router.nextCommitId(), 5);
        assertEq(router.nextExecuteId(), 0);
    }

}

contract OracleSynchronizationExactAdmissionTest is OracleSynchronizationAdmissionBase {

    function test_IndependentAdmissionAcceptsExactLiabilityAndBufferCash() public {
        _fourBalancedOpens();
        // Two positions per side owe at most 4,000 USDC. The next SHORT owes 2,000 more;
        // 6,000 liability plus its 25-bps buffer exactly equals the 6,015 USDC physical pool cash.
        assertEq(usdc.balanceOf(address(pool)), 6015e6);
        handler.execute(1_000_000, 0, false, false);
        assertEq(handler.attempts(), 5);
        assertEq(handler.executed(), 5);
        assertEq(handler.resolutions(), 5);
        assertEq(handler.commitRejected(), 0);
        assertEq(handler.plannerRejected(), 0);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(5)), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,,, uint256 maxProfit, CfdTypes.Side side,,) = engine.positions(address(100_005));
        assertEq(size, 2000e18);
        assertEq(maxProfit, 2000e6);
        assertEq(uint8(side), uint8(CfdTypes.Side.SHORT));
        assertEq(router.nextExecuteId(), 0);
    }

    function test_IndependentAdmissionAuthenticatesExecutionPriceRejection() public {
        _fourBalancedOpens();
        uint256 keeperBefore = clearinghouse.balanceUsdc(address(handler));
        uint256 treasuryBefore = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        // Commit at the covered $1 mark is valid. The $0.99 fill raises SHORT maximum profit
        // to 6,020 USDC before the buffer, exceeding 6,015 cash: a guarded terminal rejection.
        handler.execute(0, 0, false, false);
        assertEq(handler.attempts(), 5);
        assertEq(handler.executed(), 4);
        assertEq(handler.resolutions(), 5);
        assertEq(handler.commitRejected(), 0);
        assertEq(handler.plannerRejected(), 1);
        OrderV3Types.TerminalOutcome memory outcome = router.lifecycleBook().terminalOutcome(5);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(outcome.account, address(100_005));
        assertEq(engine.lastMarkPrice(), 99_000_000);
        (uint256 size,,,,,,) = engine.positions(address(100_005));
        assertEq(size, 0);
        assertEq(clearinghouse.balanceUsdc(address(100_005)), 2000e6 - 200_000);
        assertEq(clearinghouse.balanceUsdc(address(handler)), keeperBefore + 200_000);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), treasuryBefore);
        assertEq(clearinghouse.getAccountReservationSummary(address(100_005)).activeReservationCount, 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(address(100_005)), 0);
        assertEq(router.nextCommitId(), 6);
        assertEq(router.nextExecuteId(), 0);
        assertEq(usdc.balanceOf(address(pool)), 6015e6);
    }

}

contract OracleSynchronizationInsufficientAdmissionTest is OracleSynchronizationAdmissionBase {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 4015e6 - 1;
    }

    function test_IndependentAdmissionRejectsOneAtomBelowLiabilityAndBuffer() public {
        _fourBalancedOpens();
        uint256 keeperBefore = clearinghouse.balanceUsdc(address(handler));
        assertEq(usdc.balanceOf(address(pool)), 6015e6 - 1);
        handler.execute(1_000_000, 0, false, false);
        assertEq(handler.attempts(), 5);
        assertEq(handler.executed(), 4);
        assertEq(handler.resolutions(), 4);
        assertEq(handler.commitRejected(), 1);
        assertEq(handler.plannerRejected(), 0);
        assertEq(router.nextCommitId(), 5, "rejected commit must not consume a new id");
        assertEq(router.nextExecuteId(), 0);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(5)), uint8(OrderV3Types.LifecycleStatus.None));
        assertEq(clearinghouse.balanceUsdc(address(100_005)), 2000e6);
        assertEq(clearinghouse.balanceUsdc(address(handler)), keeperBefore);
        assertEq(clearinghouse.getAccountReservationSummary(address(100_005)).activeReservationCount, 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(address(100_005)), 0);
        (uint256 size,,,,,,) = engine.positions(address(100_005));
        assertEq(size, 0);
    }

}

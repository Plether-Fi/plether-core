// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterExecutionHost} from "@plether/perps/interfaces/IOrderRouterExecutionHost.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A queued close binds its side to the live position, even when earlier queued intents fail.
contract OrderRouterCloseSideBindingTest is SourceBoundBountyFixture {

    struct FailedChain {
        uint64 closeId;
        uint64 openId;
        uint64 wrongCloseId;
        uint64 followerId;
    }

    struct FailureState {
        bytes32 position;
        uint256 settlement;
        uint256 executorSettlement;
        uint256 poolAssets;
        uint256 pledge;
        uint256 bounty;
    }

    function test_WrongSideCloseBothDirectionsConfidenceAndExecutors() public {
        for (uint256 side; side < 2; ++side) {
            for (uint256 self; self < 2; ++self) {
                for (uint256 confidence; confidence < 2; ++confidence) {
                    uint256 checkpoint = vm.snapshotState();
                    _failedChain(CfdTypes.Side(side), self != 0, confidence != 0, false);
                    assertTrue(vm.revertToStateAndDelete(checkpoint));
                }
            }
        }
    }

    function test_WrongSidePrecedesSlippageAndDoesNotReachPolicyEvaluator() public {
        // If only the planner were fixed, these requests would terminate as Slippage instead.
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            _failedChain(CfdTypes.Side(side), false, true, true);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
        }
    }

    function test_QueuedFlipSucceedsWhenEarlierIntentsExecute() public {
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            CfdTypes.Side original = CfdTypes.Side(side);
            CfdTypes.Side opposite = _opposite(original);
            _openFunded(original);
            _staleMarkForQueuedFlip();
            uint64 closeId = _bountyCommit(BOUNTY_TRADER, original, true, BOUNTY_SIZE, 0);
            uint64 openId = _bountyCommit(BOUNTY_TRADER, opposite, false, BOUNTY_SIZE, 1000e6);
            uint64 finalCloseId = _bountyCommit(BOUNTY_TRADER, opposite, true, BOUNTY_SIZE, 0);
            _bountyExecute(closeId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            _bountyExecute(openId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            (uint256 liveSize,,,, CfdTypes.Side liveSide,,) = engine.positions(BOUNTY_TRADER);
            assertEq(liveSize, BOUNTY_SIZE);
            assertEq(uint8(liveSide), uint8(opposite));
            assertEq(engine.positionEpoch(BOUNTY_TRADER), 2);
            _bountyExecute(finalCloseId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            (liveSize,,,,,,) = engine.positions(BOUNTY_TRADER);
            assertEq(liveSize, 0);
            _assertBountyResolved(closeId);
            _assertBountyResolved(openId);
            _assertBountyResolved(finalCloseId);
            assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
            assertEq(router.nextExecuteId(), 0);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
        }
    }

    function test_FreshMarkQueuedFlipSucceedsWhenEarlierCloseExecutes() public {
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            CfdTypes.Side original = CfdTypes.Side(side);
            CfdTypes.Side opposite = _opposite(original);
            _openFunded(original);
            assertLe(block.timestamp - engine.lastMarkTime(), pletherOracle.orderExecutionStalenessLimit());

            uint64 closeId = _bountyCommit(BOUNTY_TRADER, original, true, BOUNTY_SIZE, 0);
            uint64 openId = _bountyCommit(BOUNTY_TRADER, opposite, false, BOUNTY_SIZE, 1000e6);
            _bountyExecute(closeId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            _bountyExecute(openId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);

            (uint256 liveSize,,,, CfdTypes.Side liveSide,,) = engine.positions(BOUNTY_TRADER);
            assertEq(liveSize, BOUNTY_SIZE);
            assertEq(uint8(liveSide), uint8(opposite));
            assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
        }
    }

    function test_WrongSideBatchFinalizesEachItemAndExecutesFollower() public {
        _openFunded(CfdTypes.Side.LONG);
        FailedChain memory chain = _commitFailedChain(CfdTypes.Side.LONG, false);
        bytes32 originalPosition = _positionDigest();
        uint256 keeperBefore = clearinghouse.balanceAssets(BOUNTY_KEEPER);
        uint256 allBounties = _bountyReservation(chain.closeId).amountAssets
            + _bountyReservation(chain.openId).amountAssets + _bountyReservation(chain.wrongCloseId).amountAssets
            + _bountyReservation(chain.followerId).amountAssets;
        bytes[] memory update = _mockPythUpdateData(BOUNTY_PRICE);
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(chain.followerId, update);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(result.terminalCount, 4);
        assertEq(result.nextOrderId, 0);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.None));
        assertEq(uint8(_receipt(logs, chain.closeId).reason), uint8(OrderV3Types.TerminalReason.Slippage));
        OrderV3Types.OrderReceipt memory failedOpen = _receipt(logs, chain.openId);
        assertEq(uint8(failedOpen.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(failedOpen.failure.code, uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING));
        _assertSideFailure(_receipt(logs, chain.wrongCloseId));
        assertEq(uint8(_receipt(logs, chain.followerId).status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(_positionDigest(), originalPosition);
        assertEq(clearinghouse.balanceAssets(BOUNTY_KEEPER), keeperBefore + allBounties);
        _assertChainResolved(chain);
    }

    function test_PlannerAndEvaluatorRejectWrongSideBeforeCarryProjection() public {
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            CfdTypes.Side original = CfdTypes.Side(side);
            _openFunded(original);
            CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
            snap.unsettledCarryAssets = 1e6;
            CfdTypes.Order memory wrong = _closeOrder(_opposite(original));
            CfdEnginePlanTypes.CloseDelta memory delta = engine.planner().planClose(snap, wrong, BOUNTY_PRICE);
            assertFalse(delta.valid);
            assertEq(uint8(delta.revertCode), 7);
            assertEq(delta.pendingCarryAssets, 0, "side rejection precedes carry assessment");
            assertEq(delta.realizedCarryAssets, 0, "side rejection precedes carry collection");
            OrderV3Types.OrderRequest memory request = _bountyRequest(original, true, BOUNTY_SIZE, 0);
            vm.expectRevert(_sideFailureData());
            policyEvaluator.evaluateClose(snap, delta, request.bounds, 0);
            uint256 depth = pool.totalAssets();
            vm.expectRevert(_sideFailureData());
            policyEvaluator.assessOrder(address(engine), wrong, BOUNTY_KEEPER, BOUNTY_PRICE, depth, request.bounds, 0);
            CfdTypes.Order memory right = _closeOrder(original);
            delta = engine.planner().planClose(snap, right, BOUNTY_PRICE);
            assertTrue(delta.valid, "same-side close retains existing economics");
            assertEq(delta.pendingCarryAssets, 1e6);
            assertEq(delta.realizedCarryAssets, 1e6);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
        }
    }

    function test_PlannerMissingPositionKeepsExistingSizeFailure() public {
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot();
        CfdEnginePlanTypes.CloseDelta memory delta =
            engine.planner().planClose(snap, _closeOrder(CfdTypes.Side.SHORT), BOUNTY_PRICE);
        assertFalse(delta.valid);
        assertEq(uint8(delta.revertCode), uint8(CfdEnginePlanTypes.CloseRevertCode.CLOSE_SIZE_EXCEEDS));
    }

    function test_WrongSideReceiptFailureRollsBackBountyAndQueueThenRetries() public {
        _openFunded(CfdTypes.Side.LONG);
        FailedChain memory chain = _commitFailedChain(CfdTypes.Side.LONG, false);
        _failPredecessors(chain, BOUNTY_KEEPER);
        bytes32 digest = _bountyStateDigest(chain.wrongCloseId);
        uint256 keeperBefore = clearinghouse.balanceAssets(BOUNTY_KEEPER);
        vm.mockCallRevert(
            address(router.lifecycleBook()),
            abi.encodeWithSelector(IOrderLifecycleBook.finalize.selector),
            hex"12345678"
        );
        bytes[] memory update = _mockPythUpdateData(BOUNTY_PRICE);
        vm.prank(BOUNTY_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(chain.wrongCloseId, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.ReceiptFailure));
        assertEq(_bountyStateDigest(chain.wrongCloseId), digest);
        assertEq(clearinghouse.balanceAssets(BOUNTY_KEEPER), keeperBefore);
        vm.clearMockedCalls();
        _assertSideFailure(
            _bountyExecute(chain.wrongCloseId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Failed)
        );
        _bountyExecute(chain.followerId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _assertChainResolved(chain);
    }

    function test_WrongSideStillWaitsForAuthenticatedMevBoundary() public {
        _openFunded(CfdTypes.Side.LONG);
        FailedChain memory chain = _commitFailedChain(CfdTypes.Side.LONG, false);
        _failPredecessors(chain, BOUNTY_KEEPER);
        bytes32 beforeState = _bountyStateDigest(chain.wrongCloseId);
        IOrderRouterExecutionHost.ItemRequest memory item;
        item.orderId = chain.wrongCloseId;
        item.executor = BOUNTY_KEEPER;
        item.executionPrice = BOUNTY_PRICE;
        item.oraclePublishTime = router.lifecycleBook().orderTiming(chain.wrongCloseId).commitTimestamp;
        vm.prank(address(router));
        OrderV3Types.ExecutionResult memory result = router.executeOrderItemFromSidecar(item);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.MevBoundary));
        assertEq(_bountyStateDigest(chain.wrongCloseId), beforeState);
        _assertSideFailure(
            _bountyExecute(chain.wrongCloseId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Failed)
        );
        _bountyExecute(chain.followerId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _assertChainResolved(chain);
    }

    function _failedChain(
        CfdTypes.Side original,
        bool self,
        bool confidence,
        bool failingSlippage
    ) private {
        _openFunded(original);
        FailedChain memory chain = _commitFailedChain(original, failingSlippage);
        address executor = self ? BOUNTY_TRADER : BOUNTY_KEEPER;
        _failPredecessors(chain, executor);
        FailureState memory beforeState = FailureState({
            position: _positionDigest(),
            settlement: clearinghouse.balanceAssets(BOUNTY_TRADER),
            executorSettlement: clearinghouse.balanceAssets(executor),
            poolAssets: pool.totalAssets(),
            pledge: clearinghouse.pnlPledgeAssets(BOUNTY_TRADER),
            bounty: _bountyReservation(chain.wrongCloseId).amountAssets
        });
        assertEq(beforeState.bounty, 0);
        bytes[] memory update = _mockPythUpdateData(BOUNTY_PRICE);
        if (confidence) {
            uint256 published = _mockHistoricalPublishTime();
            baseMockPyth.setAllUniquePrices(
                _basePythFeedIds(), int64(uint64(BOUNTY_PRICE)), 100_000, -8, published, published - 1
            );
        }
        if (failingSlippage) {
            vm.mockCallRevert(
                address(policyEvaluator),
                abi.encodeWithSelector(policyEvaluator.assessCommittedOrder.selector),
                hex"12345678"
            );
        }
        vm.recordLogs();
        vm.prank(executor);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(chain.wrongCloseId, update);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(chain.wrongCloseId);
        _assertSideFailure(receipt);
        uint256 shift = confidence ? 20_000 : 0; // Two equal feeds, 100_000 confidence atoms, 20% multiplier.
        assertEq(receipt.executionPrice, original == CfdTypes.Side.SHORT ? BOUNTY_PRICE + shift : BOUNTY_PRICE - shift);
        assertEq(receipt.executor, executor);
        assertEq(receipt.bounty.bountyPaidAssets, beforeState.bounty);
        assertEq(receipt.bounty.bountyRefundedAssets, 0);
        assertEq(receipt.bountyRecipient, address(0));
        assertEq(_positionDigest(), beforeState.position);
        assertEq(clearinghouse.pnlPledgeAssets(BOUNTY_TRADER), beforeState.pledge);
        assertEq(clearinghouse.balanceAssets(BOUNTY_TRADER), beforeState.settlement - (self ? 0 : beforeState.bounty));
        assertEq(
            clearinghouse.balanceAssets(executor), beforeState.executorSettlement + (self ? 0 : beforeState.bounty)
        );
        assertEq(pool.totalAssets(), beforeState.poolAssets);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        assertEq(router.nextExecuteId(), chain.followerId);
        vm.clearMockedCalls();
        _bountyExecute(chain.followerId, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        _assertChainResolved(chain);
    }

    function _commitFailedChain(
        CfdTypes.Side original,
        bool failingSlippage
    ) private returns (FailedChain memory chain) {
        _staleMarkForQueuedFlip();
        OrderV3Types.OrderRequest memory request = _bountyRequest(original, true, BOUNTY_SIZE, 0);
        request.targetPrice = original == CfdTypes.Side.LONG ? 1 : CAP_PRICE;
        vm.prank(BOUNTY_TRADER);
        chain.closeId = router.commitOrder(request);
        CfdTypes.Side opposite = _opposite(original);
        chain.openId = _bountyCommit(BOUNTY_TRADER, opposite, false, BOUNTY_SIZE, 1000e6);
        request = _bountyRequest(opposite, true, BOUNTY_SIZE, 0);
        if (failingSlippage) {
            request.targetPrice = opposite == CfdTypes.Side.LONG ? 1 : CAP_PRICE;
        }
        vm.prank(BOUNTY_TRADER);
        chain.wrongCloseId = router.commitOrder(request);
        _fundTrader(BOUNTY_OTHER, 2000e6);
        chain.followerId = _bountyCommit(BOUNTY_OTHER, original, false, BOUNTY_SIZE, 1000e6);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 3);
    }

    function _failPredecessors(
        FailedChain memory chain,
        address executor
    ) private {
        OrderV3Types.OrderReceipt memory receipt =
            _bountyExecute(chain.closeId, BOUNTY_PRICE, executor, OrderV3Types.LifecycleStatus.Failed);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Slippage));
        receipt = _bountyExecute(chain.openId, BOUNTY_PRICE, executor, OrderV3Types.LifecycleStatus.Failed);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(receipt.failure.category, uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid));
        assertEq(receipt.failure.code, uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING));
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), chain.wrongCloseId);
    }

    function _openFunded(
        CfdTypes.Side side
    ) private {
        _fundTrader(BOUNTY_TRADER, 10_000e6);
        uint64 id = _bountyCommit(BOUNTY_TRADER, side, false, BOUNTY_SIZE, 1000e6);
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
    }

    function _staleMarkForQueuedFlip() private {
        // Opposite opens are admissible while the stored mark is stale; execution revalidates live state.
        vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
    }

    function _assertChainResolved(
        FailedChain memory chain
    ) private view {
        _assertBountyResolved(chain.closeId);
        _assertBountyResolved(chain.openId);
        _assertBountyResolved(chain.wrongCloseId);
        _assertBountyResolved(chain.followerId);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_OTHER), 0);
        assertEq(router.nextExecuteId(), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_OTHER);
        assertEq(size, BOUNTY_SIZE, "honest follower executes");
    }

    function _assertSideFailure(
        OrderV3Types.OrderReceipt memory receipt
    ) private pure {
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertFalse(receipt.priceReachedEngine);
        assertEq(receipt.failure.selector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
        assertEq(receipt.failure.category, uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid));
        assertEq(receipt.failure.code, 7);
        assertEq(receipt.failure.revertDataHash, keccak256(_sideFailureData()));
        assertEq(uint8(receipt.failure.constraint), uint8(OrderV3Types.ConstraintKind.None));
        assertEq(receipt.failure.actual, 0);
        assertEq(receipt.failure.limit, 0);
    }

    function _sideFailureData() private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
            uint8(7),
            true
        );
    }

    function _closeOrder(
        CfdTypes.Side side
    ) private pure returns (CfdTypes.Order memory order) {
        order.account = BOUNTY_TRADER;
        order.side = side;
        order.isClose = true;
        order.sizeDelta = BOUNTY_SIZE;
        order.targetPrice = BOUNTY_PRICE;
    }

    function _opposite(
        CfdTypes.Side side
    ) private pure returns (CfdTypes.Side) {
        return side == CfdTypes.Side.LONG ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
    }

    function _snapshot() private returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        uint256 depth = pool.totalAssets();
        address sidecar = address(engine.settlementSidecar());
        vm.prank(address(engine));
        snap = ICfdEngineSettlementSidecar(sidecar).buildRawSnapshot(BOUNTY_TRADER, depth);
    }

    function _positionDigest() private view returns (bytes32) {
        (bool ok, bytes memory state) =
            address(engine).staticcall(abi.encodeWithSelector(engine.positions.selector, BOUNTY_TRADER));
        assertTrue(ok);
        return keccak256(
            abi.encode(state, engine.positionEntryCostAssetAtoms(BOUNTY_TRADER), engine.positionEpoch(BOUNTY_TRADER))
        );
    }

    function _receipt(
        Vm.Log[] memory logs,
        uint64 id
    ) private view returns (OrderV3Types.OrderReceipt memory receipt) {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && uint256(logs[i].topics[1]) == id
            ) {
                (bytes32 hash,, uint64 time, OrderV3Types.OrderReceipt memory found) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertEq(router.lifecycleBook().terminalOutcome(id).receiptHash, hash);
                assertEq(found.orderId, id);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), found.account);
                assertEq(logs[i].topics[3], found.clientOrderId);
                assertTrue(router.lifecycleBook().verifyReceipt(found, time));
                receipt = found;
                ++matches;
            }
        }
        assertEq(matches, 1);
    }

}

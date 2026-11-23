// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @notice Full-stack regression for inclusive commit/execution carry bounds. Only USDG/Pyth are doubles.
contract OpenCommitCarryBoundsTest is BasePerpTest {

    address private constant TRADER = address(0x6202);
    address private constant KEEPER = address(0x6203);
    uint256 private constant MARK = 1e8;
    uint256 private constant INITIAL_SIZE = 50_000e18;
    uint256 private constant INCREASE_SIZE = 10_000e18;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: 20,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function setUp() public override {
        super.setUp();
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.minOpenNotionalAssets = 1000e6;
        _setRouterConfig(config);
        _refreshMark();
        _fundTrader(TRADER, 100_000e6);
    }

    function test_OpenCommit_RecordsActualCarryAndCustody() public {
        _existingPosition(CfdTypes.Side.LONG);
        uint256 due = _expectedIndexedCarryAssets(TRADER);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        uint256 beforePool = pool.totalAssets();
        uint64 id = _commit(_increase(CfdTypes.Side.LONG));
        OrderV3Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(id);
        assertGt(due, 0, "fixture accrues carry");
        assertEq(pending.commitment.carryCollectedAssets, due, "commit records actual collection");
        assertEq(pending.commitment.carryOutstandingAssets, 0);
        assertEq(pending.commitment.settlementBeforeAssets, beforeBalance);
        assertEq(pending.commitment.settlementAfterAssets, beforeBalance - due);
        assertEq(beforeBalance - clearinghouse.balanceAssets(TRADER), due, "carry paid once");
        assertEq(pool.totalAssets() - beforePool, due, "carry credited to LPs once");
        assertEq(_expectedIndexedCarryAssets(TRADER), 0, "later reservation hook does not re-accrue carry");
        assertEq(pending.commitment.bountyFromFreeAssets, pending.executionBountyAssets);
        assertEq(
            pending.commitment.freeSettlementAfterAssets,
            clearinghouse.getAccountAssetBuckets(TRADER).freeSettlementAssets
        );
    }

    function test_OpenCommit_ActionBoundRejectsAndRollsBackCarry() public {
        _existingPosition(CfdTypes.Side.LONG);
        uint256 due = _expectedIndexedCarryAssets(TRADER);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.bounds.maxActionChargeAssets = due - 1;
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector,
                OrderV3Types.ConstraintKind.ActionCharge,
                due,
                due - 1
            )
        );
        vm.prank(TRADER);
        router.commitOrder(request);
        assertEq(_stateHash(), beforeState, "rejection restores custody, carry, curve and queues");
        assertEq(router.lifecycleBook().clientIntent(TRADER, request.clientOrderId).orderId, 0);
    }

    function test_OpenCommit_GrossBoundRejectsAndRollsBackCarry() public {
        _existingPosition(CfdTypes.Side.LONG);
        uint256 due = _expectedIndexedCarryAssets(TRADER);
        uint256 checkpoint = vm.snapshotState();
        uint64 probe = _commit(_increase(CfdTypes.Side.LONG));
        uint256 bounty = router.lifecycleBook().pendingIntent(probe).executionBountyAssets;
        assertTrue(vm.revertToState(checkpoint));
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.bounds.maxGrossAccountDebitAssets = due + bounty - 1;
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector,
                OrderV3Types.ConstraintKind.GrossAccountDebit,
                due + bounty,
                due + bounty - 1
            )
        );
        vm.prank(TRADER);
        router.commitOrder(request);
        assertEq(_stateHash(), beforeState);
        assertEq(router.lifecycleBook().clientIntent(TRADER, request.clientOrderId).orderId, 0);
    }

    function test_OpenExecution_CombinedActionChargeRejectsExecutionOnlyBudget() public {
        _combinedFailure(false);
    }

    function test_OpenExecution_CombinedGrossDebitRejectsExecutionOnlyBudget() public {
        _combinedFailure(true);
    }

    function test_OpenExecution_ExactInclusiveBoundsAndOneAtomLess() public {
        _existingPosition(CfdTypes.Side.LONG);
        Calibration memory expected = _calibrate(CfdTypes.Side.LONG, 0);
        uint256 checkpoint = vm.snapshotState();
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.bounds.maxGrossAccountDebitAssets = expected.gross;
        request.bounds.maxActionChargeAssets = expected.action;
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        OrderV3Types.OrderReceipt memory receipt = _executeAndCompareCommitted(_commit(request));
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(receipt.economics.grossAccountDebitAssets, expected.gross);
        assertEq(receipt.economics.actionChargeAssessedAssets, expected.action);
        assertEq(beforeBalance - clearinghouse.balanceAssets(TRADER), expected.gross);
        assertEq(receipt.commitment.carryCollectedAssets, expected.carry);

        assertTrue(vm.revertToState(checkpoint));
        request.bounds.maxGrossAccountDebitAssets = expected.gross - 1;
        request.bounds.maxActionChargeAssets = type(uint256).max;
        _assertFailure(
            _execute(_commit(request)),
            OrderV3Types.ConstraintKind.GrossAccountDebit,
            expected.gross,
            expected.gross - 1
        );

        assertTrue(vm.revertToState(checkpoint));
        request.bounds.maxGrossAccountDebitAssets = type(uint256).max;
        request.bounds.maxActionChargeAssets = expected.action - 1;
        _assertFailure(
            _execute(_commit(request)), OrderV3Types.ConstraintKind.ActionCharge, expected.action, expected.action - 1
        );
    }

    function test_OpenExecution_NewCarryAndCommittedCarryCountOnce() public {
        _existingPosition(CfdTypes.Side.LONG);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        uint64 id = _commit(_increase(CfdTypes.Side.LONG));
        OrderV3Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(id);
        uint256 afterCommit = clearinghouse.balanceAssets(TRADER);
        vm.warp(vm.getBlockTimestamp() + 30 seconds);
        OrderV3Types.OrderReceipt memory receipt = _execute(id);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertGt(
            receipt.economics.carryAssets, int256(pending.commitment.carryCollectedAssets), "later carry is included"
        );
        assertEq(receipt.commitment.carryCollectedAssets, beforeBalance - afterCommit);
        assertEq(
            receipt.economics.preSettlementBalanceAssets, afterCommit, "receipt prebalance is execution-time custody"
        );
        assertEq(receipt.economics.grossAccountDebitAssets, beforeBalance - clearinghouse.balanceAssets(TRADER));
        assertEq(
            receipt.economics.actionChargeAssessedAssets + pending.executionBountyAssets,
            receipt.economics.grossAccountDebitAssets
        );
        assertEq(receipt.economics.actionChargeCollectedAssets, receipt.economics.actionChargeAssessedAssets);
    }

    function test_OpenCommit_ReplayDoesNotCollectNewCarryOrRewriteEffects() public {
        _existingPosition(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        uint64 id = _commit(request);
        bytes32 originalCommitment = keccak256(abi.encode(router.lifecycleBook().pendingIntent(id).commitment));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertGt(_expectedIndexedCarryAssets(TRADER), 0);
        bytes32 beforeState = _stateHash();
        assertEq(_commit(request), id);
        assertEq(_stateHash(), beforeState, "replay does not touch economic state");
        assertEq(keccak256(abi.encode(router.lifecycleBook().pendingIntent(id).commitment)), originalCommitment);
    }

    function test_OpenCommit_ZeroAddedMarginPreservesReserveAdmissionRejection() public {
        _existingPosition(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.marginDelta = 0;
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED)
            )
        );
        vm.prank(TRADER);
        router.commitOrder(request);
        assertEq(_stateHash(), beforeState, "unfunded reserve rejection preserves carry and custody");
    }

    function test_OpenExecution_ShortIncreaseCountsCarry() public {
        _existingPosition(CfdTypes.Side.SHORT);
        uint256 expectedCarry = _expectedIndexedCarryAssets(TRADER);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        OrderV3Types.OrderReceipt memory receipt = _execute(_commit(_increase(CfdTypes.Side.SHORT)));
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(receipt.commitment.carryCollectedAssets, expectedCarry);
        assertGt(expectedCarry, 0);
        assertEq(receipt.economics.grossAccountDebitAssets, beforeBalance - clearinghouse.balanceAssets(TRADER));
    }

    function test_OpenExecution_SelfBountyReturnDoesNotReduceGrossPolicyDebit() public {
        _existingPosition(CfdTypes.Side.LONG);
        Calibration memory externalExecution = _calibrate(CfdTypes.Side.LONG, 0);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        uint64 id = _commit(_increase(CfdTypes.Side.LONG));
        bytes[] memory data = _mockPythUpdateData(MARK);
        _startRecordingLogs();
        vm.prank(TRADER);
        router.executeOrder(id, data);
        OrderV3Types.OrderReceipt memory receipt =
            _verifiedReceipt(IOrderLifecycleBook(address(router.lifecycleBook())), id);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(receipt.economics.grossAccountDebitAssets, externalExecution.gross);
        assertEq(
            beforeBalance - clearinghouse.balanceAssets(TRADER) + externalExecution.bounty, externalExecution.gross
        );
    }

    function test_OpenExecution_FreshOpenHasNoCommitCarry() public {
        OrderV3Types.OrderReceipt memory receipt = _execute(_commit(_increase(CfdTypes.Side.LONG)));
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(receipt.commitment.carryCollectedAssets, 0);
        assertEq(receipt.commitment.carryOutstandingAssets, 0);
    }

    function test_OpenCommit_ExactCommitBoundsSucceed() public {
        _existingPosition(CfdTypes.Side.LONG);
        Calibration memory expected = _calibrate(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.bounds.maxGrossAccountDebitAssets = expected.carry + expected.bounty;
        request.bounds.maxActionChargeAssets = expected.carry;
        uint64 id = _commit(request);
        assertEq(router.lifecycleBook().pendingIntent(id).commitment.carryCollectedAssets, expected.carry);
        assertEq(router.lifecycleBook().pendingIntent(id).account, TRADER);
    }

    function test_OpenExpiry_RetainsCommitCarryWithoutCollectingItAgain() public {
        _existingPosition(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        uint64 id = _commit(request);
        OrderV3Types.PendingIntent memory pending = router.lifecycleBook().pendingIntent(id);
        uint256 afterCommit = clearinghouse.balanceAssets(TRADER);
        vm.warp(router.lifecycleBook().orderTiming(id).executionDeadline + 1);
        OrderV3Types.OrderReceipt memory receipt = _execute(id);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Expired));
        assertGt(pending.commitment.carryCollectedAssets, 0);
        assertEq(keccak256(abi.encode(receipt.commitment)), keccak256(abi.encode(pending.commitment)));
        assertEq(clearinghouse.balanceAssets(TRADER), afterCommit - pending.executionBountyAssets);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, INITIAL_SIZE);
    }

    function test_OpenCommit_MarginOnlyCheckpointIsRecorded() public {
        _existingPosition(CfdTypes.Side.LONG);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        uint256 due = _expectedIndexedCarryAssets(TRADER);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        uint64 id = router.nextCommitId();
        IOrderLifecycleBook book = IOrderLifecycleBook(address(router.lifecycleBook()));
        // Production requires a positive opening bounty. Exercise the authenticated reservation boundary
        // directly to prove that a future zero-bounty path still records collection by the margin hook.
        vm.prank(address(router));
        book.registerPending(TRADER, id, request, 0);
        bytes memory payload = abi.encodeWithSelector(
            router.executeCommitOrderItem.selector,
            id,
            TRADER,
            request.sizeDelta,
            request.marginDelta,
            request.targetPrice,
            request.side,
            uint256(0),
            uint256(0)
        );
        vm.prank(address(router));
        (bool success, bytes memory result) = address(router).call(payload);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        OrderV3Types.PendingIntent memory pending = book.pendingIntent(id);
        assertGt(due, 0);
        assertEq(pending.commitment.carryCollectedAssets, due);
        assertEq(beforeBalance - clearinghouse.balanceAssets(TRADER), due);
        assertEq(pending.commitment.bountyFromFreeAssets, 0);
        assertEq(
            pending.commitment.freeSettlementAfterAssets,
            clearinghouse.getAccountAssetBuckets(TRADER).freeSettlementAssets
        );
    }

    function test_OpenCommit_ReconciliationRequiresRouterAndPendingOrder() public {
        IOrderLifecycleBook book = IOrderLifecycleBook(address(router.lifecycleBook()));
        CfdEnginePlanTypes.CloseCommitment memory effects;
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__Unauthorized.selector);
        vm.prank(TRADER);
        book.recordCommitment(404, effects, false);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__OrderNotPending.selector, uint64(404))
        );
        vm.prank(address(router));
        book.recordCommitment(404, effects, false);
    }

    function test_PublicLpCashout_ExecutionOnlyCapsCannotCreateIncrementalRevenue() public {
        _fundJuniorPublic(KEEPER, 100_000e6);
        _existingPosition(CfdTypes.Side.LONG);
        Calibration memory expected = _calibrate(CfdTypes.Side.LONG, 0);
        uint256 executionOnlyLimit = expected.action - expected.carry;
        uint256 shares = juniorVault.balanceOf(KEEPER);
        uint256 checkpoint = vm.snapshotState();
        // The lower cap already fails the execution-only assessment; the former bypass reaches the
        // cumulative check. Both must block the increase and leave exactly the same economic state.
        Cashout memory oneAtomBelow = _cashoutBranch(executionOnlyLimit - 1, shares, expected.action);
        assertTrue(vm.revertToState(checkpoint));
        Cashout memory formerBypass = _cashoutBranch(executionOnlyLimit, shares, expected.action);
        assertEq(
            keccak256(abi.encode(formerBypass)),
            keccak256(abi.encode(oneAtomBelow)),
            "both limits block the trade and produce identical cashout"
        );
    }

    struct Cashout {
        uint256 wallet;
        uint256 keeperCustody;
        uint256 traderCustody;
        uint256 treasury;
        uint256 poolCash;
    }

    function _fundJuniorPublic(
        address lp,
        uint256 amount
    ) private {
        settlementToken.mint(lp, amount);
        vm.startPrank(lp);
        settlementToken.approve(address(juniorVault), amount);
        uint256 requestId = juniorVault.requestDeposit(amount, lp, lp);
        vm.stopPrank();
        vm.warp(juniorVault.depositEpochStart(requestId));
        bytes[] memory data = _mockPythUpdateData(MARK);
        vm.prank(KEEPER);
        router.settleLpEpoch(data);
        uint256 claimable = juniorVault.claimableDepositRequest(requestId, lp);
        assertEq(claimable, amount);
        vm.prank(lp);
        juniorVault.claimDeposit(requestId, claimable, lp, lp);
    }

    function _cashoutBranch(
        uint256 actionCap,
        uint256 shares,
        uint256 failedAssessment
    ) private returns (Cashout memory result) {
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        request.bounds.maxActionChargeAssets = actionCap;
        OrderV3Types.OrderReceipt memory receipt = _execute(_commit(request));
        _assertFailure(receipt, OrderV3Types.ConstraintKind.ActionCharge, failedAssessment, actionCap);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, INITIAL_SIZE, "the old position is unchanged");
        vm.prank(KEEPER);
        uint256 redemptionId = juniorVault.requestRedeem(shares, KEEPER, KEEPER);
        vm.warp(pool.lpEpochStart(redemptionId));
        bytes[] memory data = _mockPythUpdateData(MARK);
        vm.prank(KEEPER);
        router.settleLpEpoch(data);
        uint256 claimable = juniorVault.claimableRedeemRequest(redemptionId, KEEPER);
        assertEq(claimable, shares);
        vm.prank(KEEPER);
        juniorVault.claimRedeem(redemptionId, claimable, KEEPER, KEEPER);
        assertEq(juniorVault.balanceOf(KEEPER), 0, "keeper exits all LP shares");
        assertEq(juniorVault.claimableRedeemRequest(redemptionId, KEEPER), 0);
        result.wallet = settlementToken.balanceOf(KEEPER);
        result.keeperCustody = clearinghouse.balanceAssets(KEEPER);
        result.traderCustody = clearinghouse.balanceAssets(TRADER);
        result.treasury = clearinghouse.balanceAssets(engine.protocolTreasury());
        result.poolCash = pool.totalAssets();
    }

    struct Calibration {
        uint256 gross;
        uint256 action;
        uint256 carry;
        uint256 bounty;
    }

    function _calibrate(
        CfdTypes.Side side,
        uint256 delay
    ) private returns (Calibration memory result) {
        uint256 checkpoint = vm.snapshotState();
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        uint64 id = _commit(_increase(side));
        result.carry = beforeBalance - clearinghouse.balanceAssets(TRADER);
        result.bounty = router.lifecycleBook().pendingIntent(id).executionBountyAssets;
        if (delay != 0) {
            vm.warp(vm.getBlockTimestamp() + delay);
        }
        OrderV3Types.OrderReceipt memory receipt = _execute(id);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed), "permissive control executes");
        result.gross = beforeBalance - clearinghouse.balanceAssets(TRADER);
        result.action = result.gross - result.bounty;
        assertGt(result.carry, 0);
        assertTrue(vm.revertToState(checkpoint));
    }

    function _combinedFailure(
        bool grossBound
    ) private {
        _existingPosition(CfdTypes.Side.LONG);
        Calibration memory expected = _calibrate(CfdTypes.Side.LONG, 0);
        OrderV3Types.OrderRequest memory request = _increase(CfdTypes.Side.LONG);
        uint256 actual = grossBound ? expected.gross : expected.action;
        uint256 executionOnlyLimit = actual - expected.carry;
        if (grossBound) {
            request.bounds.maxGrossAccountDebitAssets = executionOnlyLimit;
        } else {
            request.bounds.maxActionChargeAssets = executionOnlyLimit;
        }
        uint64 id = _commit(request);
        assertEq(router.lifecycleBook().pendingIntent(id).commitment.carryCollectedAssets, expected.carry);
        uint256 poolBefore = pool.totalAssets();
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());
        OrderV3Types.OrderReceipt memory receipt = _execute(id);
        _assertFailure(
            receipt,
            grossBound ? OrderV3Types.ConstraintKind.GrossAccountDebit : OrderV3Types.ConstraintKind.ActionCharge,
            actual,
            executionOnlyLimit
        );
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, INITIAL_SIZE, "over-budget increase never applies");
        assertEq(pool.totalAssets(), poolBefore, "blocked trade adds no LP revenue");
        assertEq(clearinghouse.balanceAssets(engine.protocolTreasury()), treasuryBefore, "blocked trade charges no fee");
        assertEq(
            receipt.commitment.carryCollectedAssets, expected.carry, "failed receipt retains legitimate earlier carry"
        );
    }

    function _assertFailure(
        OrderV3Types.OrderReceipt memory receipt,
        OrderV3Types.ConstraintKind kind,
        uint256 actual,
        uint256 limit
    ) private pure {
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.ConstraintViolation));
        assertEq(uint8(receipt.failure.constraint), uint8(kind));
        assertEq(receipt.failure.actual, actual);
        assertEq(receipt.failure.limit, limit);
    }

    function _existingPosition(
        CfdTypes.Side side
    ) private {
        OrderV3Types.OrderRequest memory request = _increase(side);
        request.sizeDelta = INITIAL_SIZE;
        request.marginDelta = 10_000e6;
        OrderV3Types.OrderReceipt memory receipt = _execute(_commit(request));
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 1);
        _refreshMark();
    }

    function _refreshMark() private {
        vm.prank(address(router));
        engine.updateMarkPrice(MARK, uint64(vm.getBlockTimestamp()));
    }

    function _commit(
        OrderV3Types.OrderRequest memory request
    ) private returns (uint64 id) {
        vm.prank(TRADER);
        return router.commitOrder(request);
    }

    function _executeAndCompareCommitted(
        uint64 id
    ) private returns (OrderV3Types.OrderReceipt memory receipt) {
        bytes[] memory data = _mockPythUpdateData(MARK);
        OrderV3Types.ExecutionAssessment memory assessed =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, MARK);
        _startRecordingLogs();
        vm.prank(KEEPER);
        router.executeOrder(id, data);
        receipt = _verifiedReceipt(IOrderLifecycleBook(address(router.lifecycleBook())), id);
        assertEq(receipt.economics.grossAccountDebitAssets, assessed.grossAccountDebitAssets);
        assertEq(receipt.economics.actionChargeAssessedAssets, assessed.actionChargeAssessedAssets);
        assertEq(receipt.economics.actionChargeCollectedAssets, assessed.actionChargeCollectedAssets);
        assertEq(receipt.economics.carryAssets, int256(assessed.carryAssets));
    }

    function _execute(
        uint64 id
    ) private returns (OrderV3Types.OrderReceipt memory receipt) {
        _startRecordingLogs();
        bytes[] memory data = _mockPythUpdateData(MARK);
        vm.prank(KEEPER);
        router.executeOrder(id, data);
        return _verifiedReceipt(IOrderLifecycleBook(address(router.lifecycleBook())), id);
    }

    function _increase(
        CfdTypes.Side side
    ) private view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("open-carry-bound", router.nextCommitId()));
        request.side = side;
        request.sizeDelta = INCREASE_SIZE;
        request.marginDelta = 1000e6;
        request.targetPrice = side == CfdTypes.Side.LONG ? uint256(1) : CAP_PRICE;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds()),
            executionWindowSeconds: uint32(router.maxExecutionWindowSeconds()),
            allowedExecutionModes: 7,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyAssets: type(uint256).max,
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceAssets: 0,
            minPostPositionEquityAssets: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _stateHash() private view returns (bytes32) {
        (bool positionOk, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", TRADER));
        (bool carryOk, bytes memory carry) =
            address(engine).staticcall(abi.encodeWithSignature("positionCarryState(address)", TRADER));
        assertTrue(positionOk && carryOk);
        return keccak256(
            abi.encode(
                position,
                carry,
                clearinghouse.getAccountAssetBuckets(TRADER),
                clearinghouse.getAccountReservationSummary(TRADER),
                engine.unsettledCarryAssets(TRADER),
                engine.carryIndex(),
                engine.carryTimestamp(),
                pool.totalAssets(),
                terminalNavBook.curveHashOf(TRADER),
                router.nextCommitId(),
                router.pendingOrderCounts(TRADER),
                router.accountHeadOrderId(TRADER)
            )
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

/// @dev Public-path regression fixtures deliberately derive expected failures from fixed arithmetic bounds,
///      not the production preview or evaluator. Every terminal assertion authenticates its receipt.
abstract contract NumericDomainRouterFixture is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant KEEPER = address(0xBEEF);
    IOrderLifecycleBook internal book;

    function setUp() public virtual override {
        super.setUp();
        book = IOrderLifecycleBook(address(router.lifecycleBook()));
        _startRecordingLogs();
    }

    function _request(
        bytes32 clientId,
        uint256 size,
        uint256 margin
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = clientId;
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = size;
        request.marginDelta = margin;
        request.targetPrice = 1;
        request.bounds.submitBy = uint64(block.timestamp + 120);
        request.bounds.executionWindowSeconds = 60;
        request.bounds.allowedExecutionModes = 7;
        request.bounds.expectedConfigHash = book.currentExecutionConfigHash();
        request.bounds.maxExecutionBountyAssets = type(uint256).max;
        request.bounds.maxExecutionNotionalAssets = type(uint256).max;
        request.bounds.maxGrossAccountDebitAssets = type(uint256).max;
        request.bounds.maxActionChargeAssets = type(uint256).max;
        request.bounds.maxExplicitFeesAssets = type(uint256).max;
        request.bounds.maxPostPositionSize = type(uint256).max;
        request.bounds.maxPostLeverageBps = type(uint32).max;
    }

    function _commit(
        address account,
        OrderV3Types.OrderRequest memory request
    ) internal returns (uint64) {
        vm.prank(account);
        return router.commitOrder(request);
    }

    function _assertClean(
        address account,
        uint64 orderId
    ) internal view {
        assertEq(_remainingCommittedMargin(orderId), 0, "terminal order must release margin");
        IOrderRouterAccounting.AccountReservationView memory reserves = router.getAccountReservations(account);
        assertEq(reserves.pendingOrderCount, 0, "terminal account queue must be empty");
        assertEq(reserves.committedMarginAssets, 0);
        assertEq(reserves.executionBountyAssets, 0, "terminal bounty must be released");
        assertEq(router.accountHeadOrderId(account), 0);
    }

    function _assertRejected(
        uint64 orderId,
        address account,
        uint256 bounty,
        CfdEnginePlanTypes.OpenRevertCode code
    ) internal {
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(book, orderId);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(receipt.account, account);
        assertEq(receipt.failure.selector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
        assertEq(
            receipt.failure.category, uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated)
        );
        assertEq(receipt.failure.code, uint8(code));
        bytes memory expectedRevert = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
            uint8(code),
            false
        );
        assertEq(receipt.failure.revertDataHash, keccak256(expectedRevert));
        assertFalse(receipt.priceReachedEngine, "planner rejection must precede Engine application");
        assertEq(receipt.expectedConfigHash, receipt.observedConfigHash, "not a configuration rejection");
        assertEq(receipt.bountyRecipient, KEEPER);
        assertEq(receipt.bountyAssets, bounty);
        assertEq(receipt.bounty.bountyPaidAssets, bounty);
        assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.Paid));
        assertEq(receipt.economics.postPositionSize, 0);
        assertEq(receipt.economics.preSettlementBalanceAssets - receipt.economics.postSettlementBalanceAssets, bounty);
        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "failed order must not open exposure");
        _assertClean(account, orderId);
    }

    function _assertExecuted(
        uint64 orderId,
        address account,
        uint256 expectedSize
    ) internal {
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(book, orderId);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Executed));
        assertEq(receipt.account, account);
        assertTrue(receipt.priceReachedEngine);
        assertEq(receipt.economics.postPositionSize, expectedSize);
        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, expectedSize);
        _assertClean(account, orderId);
    }

}

contract OrderRouterNumericDomainTest is NumericDomainRouterFixture {

    function setUp() public override {
        super.setUp();
        _fundTrader(ALICE, 50_000e6);
        _fundTrader(BOB, 50_000e6);
    }

    function test_StaleOriginalExtremeSize_SingleRejectsSkewAndFollowerExecutes() public {
        (uint64 poison, uint64 follower, uint256 totalBounty) = _stalePoisonQueue();
        uint256 poisonBounty = book.pendingIntent(poison).executionBountyAssets;
        uint256 keeperBefore = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory failed = router.executeOrder(poison, updates);
        assertEq(uint8(failed.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(failed.pendingReason), uint8(OrderV3Types.PendingReason.None));
        assertEq(router.nextExecuteId(), follower, "poison order cannot pin FIFO");
        _assertRejected(poison, ALICE, poisonBounty, CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH);
        vm.prank(KEEPER);
        router.executeOrder(follower, updates);
        _assertExecuted(follower, BOB, 10_000e18);
        assertEq(router.nextExecuteId(), 0);
        assertEq(_settlementBalance(KEEPER) - keeperBefore, totalBounty);
    }

    function test_StaleOriginalExtremeSize_BatchRejectsSkewAndDrainsFollower() public {
        (uint64 poison, uint64 follower, uint256 totalBounty) = _stalePoisonQueue();
        uint256 poisonBounty = book.pendingIntent(poison).executionBountyAssets;
        uint256 keeperBefore = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(follower, updates);
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.None));
        _assertRejected(poison, ALICE, poisonBounty, CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH);
        _assertExecuted(follower, BOB, 10_000e18);
        assertEq(_settlementBalance(KEEPER) - keeperBefore, totalBounty);
    }

    function testFuzz_StructuralNumericLimitsRejectedEvenWithStaleMark(
        bool stale,
        bool oversizedMargin
    ) public {
        if (stale) {
            vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
        }
        OrderV3Types.OrderRequest memory request = _request(bytes32("structural-limit"), 10_000e18, 1000e6);
        if (oversizedMargin) {
            request.marginDelta = uint256(type(int256).max) + 1;
        } else {
            request.sizeDelta = (uint256(type(uint112).max) + 1) * CfdTypes.SIZE_QUANTUM;
        }
        uint64 nextId = router.nextCommitId();
        uint64 executeIdBefore = router.nextExecuteId();
        uint256 settlementBefore = _settlementBalance(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, uint8(11))
        );
        vm.prank(ALICE);
        router.commitOrder(request);
        assertEq(router.nextCommitId(), nextId);
        assertEq(_settlementBalance(ALICE), settlementBefore);
        assertEq(router.nextExecuteId(), executeIdBefore);
        _assertClean(ALICE, nextId);
    }

    function test_UnknownArithmeticPanicRemainsPendingWithReservationsAndThenRetries() public {
        uint64 head = _commit(ALICE, _request(bytes32("unknown-panic"), 10_000e18, 1000e6));
        uint64 follower = _commit(BOB, _request(bytes32("panic-follower"), 10_000e18, 1000e6));
        bytes32 intentHash = keccak256(abi.encode(book.pendingIntent(head)));
        uint256 bounty = book.pendingIntent(head).executionBountyAssets;
        uint256 aliceSettlement = _settlementBalance(ALICE);
        uint256 keeperBefore = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.mockCallRevert(
            address(engine),
            abi.encodeWithSelector(ICfdEngineCore.processOrderTyped.selector),
            abi.encodeWithSignature("Panic(uint256)", 0x11)
        );
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(follower, updates);
        assertEq(result.terminalCount, 0);
        assertEq(result.nextOrderId, head);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.EngineFailure));
        assertEq(book.terminalOutcome(head).receiptHash, bytes32(0));
        assertEq(keccak256(abi.encode(book.pendingIntent(head))), intentHash);
        assertEq(_remainingCommittedMargin(head), 1000e6);
        assertEq(router.getAccountReservations(ALICE).executionBountyAssets, bounty);
        assertEq(_settlementBalance(ALICE), aliceSettlement);
        assertEq(_settlementBalance(KEEPER), keeperBefore);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0);
        vm.clearMockedCalls();
        vm.prank(KEEPER);
        result = router.executeOrderBatch(follower, updates);
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        _assertExecuted(head, ALICE, 10_000e18);
        _assertExecuted(follower, BOB, 10_000e18);
    }

    function test_ConfigChangeIsConfigMismatchNotNumericFailure() public {
        ICfdEngineAdminHost.EngineRiskConfig memory config = _engineRiskConfig();
        config.riskParams.vpiFactor = type(uint256).max;
        engineAdmin.proposeRiskConfig(config);
        vm.warp(block.timestamp + 72 hours);
        uint64 orderId = _commit(ALICE, _request(bytes32("config-pinned"), 10_000e18, 1000e6));
        vm.warp(block.timestamp + 1);
        engineAdmin.finalizeRiskConfig();
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(orderId, updates);
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(book, orderId);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.ConfigMismatch));
        assertEq(receipt.failure.code, 0);
        assertFalse(receipt.priceReachedEngine);
        _assertClean(ALICE, orderId);
    }

    function test_NumericCodeDoesNotBroadenUnknownTypedFailureAcceptance() public {
        uint64 orderId = _commit(ALICE, _request(bytes32("typed-whitelist"), 10_000e18, 1000e6));
        uint256 bounty = book.pendingIntent(orderId).executionBountyAssets;
        bytes32 pendingHash = keccak256(abi.encode(book.pendingIntent(orderId)));
        uint256 keeperBefore = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        for (uint256 fault; fault < 3; ++fault) {
            // Numeric open failure requires category 2, code 11, and isClose=false. A category mismatch,
            // an unassigned code, and interpreting the open code as a close failure must all remain retryable.
            bytes memory failure = abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                fault == 0 ? uint8(1) : uint8(2),
                fault == 1 ? uint8(12) : uint8(11),
                fault == 2
            );
            vm.mockCallRevert(
                address(engine), abi.encodeWithSelector(ICfdEngineCore.processOrderTyped.selector), failure
            );
            vm.prank(KEEPER);
            OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updates);
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
            assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.EngineFailure));
            assertEq(router.nextExecuteId(), orderId);
            assertEq(book.terminalOutcome(orderId).receiptHash, bytes32(0));
            assertEq(keccak256(abi.encode(book.pendingIntent(orderId))), pendingHash);
            assertEq(_remainingCommittedMargin(orderId), 1000e6);
            assertEq(router.getAccountReservations(ALICE).executionBountyAssets, bounty);
            assertEq(_settlementBalance(KEEPER), keeperBefore);
        }
        vm.clearMockedCalls();
        vm.prank(KEEPER);
        router.executeOrder(orderId, updates);
        _assertExecuted(orderId, ALICE, 10_000e18);
    }

    function _stalePoisonQueue() private returns (uint64 poison, uint64 follower, uint256 bounty) {
        vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
        OrderV3Types.OrderRequest memory poisonRequest = _request(bytes32("original-1e39"), 1e39, 0);
        uint256 gasBefore = gasleft();
        poison = _commit(ALICE, poisonRequest);
        uint256 commitGas = gasBefore - gasleft();
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(poison);
        assertEq(pending.sizeDelta, 1e39);
        emit log_named_uint("Stale extreme open commit gas", commitGas);
        follower = _commit(BOB, _request(bytes32("healthy-follower"), 10_000e18, 1000e6));
        bounty = book.pendingIntent(poison).executionBountyAssets + book.pendingIntent(follower).executionBountyAssets;
    }

}

/// @notice An order can cross a numeric boundary after an earlier order changes live exposure, even though both
///         commitments were individually admissible. This uses real custody, positions, and public V3 requests.
contract OrderRouterNumericExposureTransitionTest is NumericDomainRouterFixture {

    uint256 private constant LARGE_SIZE = 3e38;
    uint256 private constant LARGE_MARGIN = 1e26;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 2e27;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 1e18;
        params.maxSkewRatio = 1e18;
        params.baseCarryBps = 0;
    }

    function setUp() public override {
        super.setUp();
        _fundTrader(ALICE, 5e26);
        _fundTrader(BOB, 5e26);
        _fundTrader(CAROL, 50_000e6);
    }

    function test_ExposureChangeNumericFailureIsTerminalAndBatchContinues() public {
        (uint64 first, uint64 rejected, uint64 follower) = _queueCrossing();
        uint256 rejectedBounty = book.pendingIntent(rejected).executionBountyAssets;
        uint256 totalBounty = book.pendingIntent(first).executionBountyAssets + rejectedBounty
            + book.pendingIntent(follower).executionBountyAssets;
        uint256 keeperBefore = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(follower, updates);
        assertEq(result.terminalCount, 3);
        assertEq(result.nextOrderId, 0);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.None));
        _assertExecuted(first, ALICE, LARGE_SIZE);
        _assertRejected(rejected, BOB, rejectedBounty, CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED);
        _assertExecuted(follower, CAROL, 10_000e18);
        assertEq(_settlementBalance(KEEPER) - keeperBefore, totalBounty);
    }

    function test_NumericFailureReceiptFaultRollsBackCleanupAndBountyThenRetries() public {
        (uint64 first, uint64 rejected, uint64 follower) = _queueCrossing();
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(first, updates);
        _assertExecuted(first, ALICE, LARGE_SIZE);
        bytes32 pendingHash = keccak256(abi.encode(book.pendingIntent(rejected)));
        uint256 bounty = book.pendingIntent(rejected).executionBountyAssets;
        uint256 keeperBefore = _settlementBalance(KEEPER);
        uint256 bobSettlement = _settlementBalance(BOB);
        vm.mockCallRevert(address(book), abi.encodeWithSelector(book.finalize.selector), hex"12345678");
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(rejected, updates);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.ReceiptFailure));
        assertEq(router.nextExecuteId(), rejected);
        assertEq(book.terminalOutcome(rejected).receiptHash, bytes32(0));
        assertEq(keccak256(abi.encode(book.pendingIntent(rejected))), pendingHash);
        assertEq(_remainingCommittedMargin(rejected), LARGE_MARGIN);
        assertEq(router.getAccountReservations(BOB).executionBountyAssets, bounty);
        assertEq(_settlementBalance(BOB), bobSettlement);
        assertEq(_settlementBalance(KEEPER), keeperBefore);
        vm.clearMockedCalls();
        vm.prank(KEEPER);
        result = router.executeOrder(rejected, updates);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        _assertRejected(rejected, BOB, bounty, CfdEnginePlanTypes.OpenRevertCode.NUMERIC_DOMAIN_EXCEEDED);
        assertEq(_settlementBalance(KEEPER) - keeperBefore, bounty);
        assertEq(router.nextExecuteId(), follower);
        vm.prank(KEEPER);
        router.executeOrder(follower, updates);
        _assertExecuted(follower, CAROL, 10_000e18);
        assertEq(router.nextExecuteId(), 0);
    }

    function _queueCrossing() private returns (uint64 first, uint64 rejected, uint64 follower) {
        // floor(sqrt(uint256.max)): each individual pre-commit square fits; their combined square cannot fit.
        uint256 maxSquareRoot = 340_282_366_920_938_463_463_374_607_431_768_211_455;
        uint256 individualSkewWad = (LARGE_SIZE / CfdTypes.SIZE_QUANTUM) * 1e8 * 1e12;
        assertLt(individualSkewWad, maxSquareRoot);
        assertGt(2 * individualSkewWad, maxSquareRoot);
        assertLt(2 * (LARGE_SIZE / CfdTypes.SIZE_QUANTUM) * 1e8, pool.totalAssets(), "not skew rejection");
        first = _commit(ALICE, _request(bytes32("first-large-open"), LARGE_SIZE, LARGE_MARGIN));
        rejected = _commit(BOB, _request(bytes32("crossing-large-open"), LARGE_SIZE, LARGE_MARGIN));
        follower = _commit(CAROL, _request(bytes32("small-after-crossing"), 10_000e18, 10_000e6));
        assertEq(router.pendingOrderCounts(ALICE), 1);
        assertEq(router.pendingOrderCounts(BOB), 1);
        assertEq(router.pendingOrderCounts(CAROL), 1);
    }

}

/// @notice Exercises the terminal book's real uint144 collateral input through public account and order actions.
contract OrderRouterNumericCollateralCapTest is NumericDomainRouterFixture {

    function setUp() public override {
        super.setUp();
        _fundTrader(ALICE, uint256(type(uint144).max) + 100_000e6);
        _fundTrader(BOB, 50_000e6);
    }

    function _positionAtPledge(
        uint256 pledge
    ) private {
        uint64 initial = _commit(ALICE, _request(bytes32("cap-initial"), 10_000e18, 1000e6));
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(initial, updates);
        _assertExecuted(initial, ALICE, 10_000e18);
        uint256 beforePledge = clearinghouse.pnlPledgeAssets(ALICE);
        vm.prank(ALICE);
        engine.addMargin(ALICE, pledge - beforePledge);
        assertEq(clearinghouse.pnlPledgeAssets(ALICE), pledge);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(ALICE);
    }

    function test_ExactTerminalCollateralCapIncreaseExecutes() public {
        _positionAtPledge(type(uint144).max);
        // Added 100 lots at $1: fee=4e6 and liquidation-reserve increase=10e6; P therefore stays unchanged.
        uint64 orderId = _commit(ALICE, _request(bytes32("cap-equality"), 10_000e18, 14e6));
        uint256 bounty = book.pendingIntent(orderId).executionBountyAssets;
        uint256 custody = _settlementBalance(ALICE);
        uint256 keeper = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(orderId, updates);
        _assertExecuted(orderId, ALICE, 20_000e18);
        assertEq(clearinghouse.pnlPledgeAssets(ALICE), type(uint144).max);
        assertEq(engine.positionEntryCostAssetAtoms(ALICE), 20_000e6);
        assertEq(custody - _settlementBalance(ALICE), 4e6 + bounty);
        assertEq(_settlementBalance(KEEPER) - keeper, bounty);
        assertEq(router.nextExecuteId(), 0);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(ALICE);
    }

    function test_OneAtomBeyondTerminalCollateralCapIsTypedAtCommit() public {
        _positionAtPledge(type(uint144).max);
        OrderV3Types.OrderRequest memory request = _request(bytes32("cap-plus-one"), 10_000e18, 14e6 + 1);
        uint64 nextId = router.nextCommitId();
        uint256 custody = _settlementBalance(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, uint8(11))
        );
        vm.prank(ALICE);
        router.commitOrder(request);
        assertEq(router.nextCommitId(), nextId);
        assertEq(router.nextExecuteId(), 0);
        assertEq(_settlementBalance(ALICE), custody);
        assertEq(clearinghouse.pnlPledgeAssets(ALICE), type(uint144).max);
        assertEq(router.pendingOrderCounts(ALICE), 0);
    }

    function test_PublicMarginChangeReachesTerminalCapFailureAndBatchContinues() public {
        _positionAtPledge(uint256(type(uint144).max) - 1);
        uint64 rejected = _commit(ALICE, _request(bytes32("cap-changed"), 10_000e18, 14e6 + 1));
        uint64 follower = _commit(BOB, _request(bytes32("cap-follower"), 10_000e18, 1000e6));
        uint256 failedBounty = book.pendingIntent(rejected).executionBountyAssets;
        uint256 totalBounty = failedBounty + book.pendingIntent(follower).executionBountyAssets;
        vm.prank(ALICE);
        engine.addMargin(ALICE, 1);
        uint256 custody = _settlementBalance(ALICE);
        uint256 keeper = _settlementBalance(KEEPER);
        bytes[] memory updates = _mockPythUpdateData();
        vm.prank(KEEPER);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(follower, updates);
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.None));
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(book, rejected);
        assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(receipt.failure.selector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
        assertEq(
            receipt.failure.category, uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated)
        );
        assertEq(receipt.failure.code, 11);
        assertFalse(receipt.priceReachedEngine);
        assertEq(
            receipt.failure.revertDataHash,
            keccak256(
                abi.encodeWithSelector(
                    ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                    CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                    uint8(11),
                    false
                )
            )
        );
        assertEq(receipt.economics.postPositionSize, 10_000e18);
        assertEq(receipt.bountyRecipient, KEEPER);
        assertEq(receipt.bounty.bountyPaidAssets, failedBounty);
        assertEq(custody - _settlementBalance(ALICE), failedBounty);
        assertEq(clearinghouse.pnlPledgeAssets(ALICE), type(uint144).max);
        assertEq(_settlementBalance(KEEPER) - keeper, totalBounty);
        _assertClean(ALICE, rejected);
        _assertExecuted(follower, BOB, 10_000e18);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(ALICE);
    }

}

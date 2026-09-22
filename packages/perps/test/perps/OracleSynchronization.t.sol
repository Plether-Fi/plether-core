// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

contract SynchronizationRefundReceiver {

    IPletherOracle public immutable oracle;
    bool public reject = true;
    bool public reentryRejected;

    constructor(
        IPletherOracle oracle_
    ) {
        oracle = oracle_;
    }

    receive() external payable {
        require(!reject, "reject refund");
        (bool ok,) = address(oracle).call(abi.encodeCall(IPletherOracle.claimEthRefund, ()));
        reentryRejected = !ok;
    }

    function claim() external {
        reject = false;
        oracle.claimEthRefund();
    }

    function execute(
        address router,
        uint64 id,
        bytes[] calldata data
    ) external payable {
        IPerpsKeeper(router).executeOrderBatch{value: msg.value}(id, data);
    }

}

/// @notice Explicit payload tests never source signed history from MockPyth's stored-price mapping.
contract OracleSynchronizationTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant FEE = 1 gwei;
    // plether-app ccb8788ed7a3fbdcc258fc0c91f277949913974a: Keeper.hs v2OrderGasLimitCap.
    uint256 internal constant KEEPER_GAS_CAP = 30_000_000;

    function setUp() public override {
        super.setUp();
        baseMockPyth.setSynchronizeLegacyUniquePrices(false);
        baseMockPyth.setFee(FEE);
        vm.deal(address(this), 100 ether);
        _fundTrader(ALICE, 10_000e6);
        _fundTrader(BOB, 10_000e6);
    }

    function _payload(
        uint64 tick,
        uint64 previous
    ) internal pure returns (bytes[] memory data) {
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            updates[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(100_000_000, 100_000, -8, tick, previous));
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _request(
        uint64 commit,
        bool strict
    ) internal pure returns (IPletherOracle.OrderExecutionRequest memory) {
        return IPletherOracle.OrderExecutionRequest(commit, 0, CfdTypes.Side.LONG, false, strict);
    }

    function _commit(
        address trader,
        uint256 target
    ) internal returns (uint64) {
        vm.prank(trader);
        return router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, target, false);
    }

    function _advance(
        uint64 tick
    ) internal {
        vm.warp(tick);
        vm.roll(block.number + 1);
    }

    function _assertCoverage(
        uint256 required
    ) internal view {
        bytes32[] memory ids = _basePythFeedIds();
        for (uint256 i; i < ids.length; ++i) {
            assertGe(baseMockPyth.getPriceUnsafe(ids[i]).publishTime, required);
        }
    }

    function test_Gas_HistoricalExecutionSynchronizesAndPreservesFill() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        uint64 tick = commit + 1;
        _advance(tick);
        assertLt(baseMockPyth.getPriceUnsafe(_basePythFeedIds()[0]).publishTime, tick);
        uint256 beforeBalance = address(this).balance;
        uint256 beforeUpdates = baseMockPyth.updatePriceFeedsCallCount();
        OrderV2Types.ExecutionResult memory result =
            router.executeOrder{value: 3 * FEE, gas: KEEPER_GAS_CAP}(id, _payload(tick, commit));
        assertEq(uint256(result.status), uint256(OrderV2Types.LifecycleStatus.Executed));
        assertEq(beforeBalance - address(this).balance, 2 * FEE);
        assertEq(address(baseMockPyth).balance, 2 * FEE);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), beforeUpdates + 1);
        _assertCoverage(engine.lastMarkTime());
        assertEq(engine.lastMarkTime(), tick);
        assertEq(engine.lastMarkPrice(), 100_000_000);
        (,, uint256 entryPrice,,,,) = engine.positions(ALICE);
        assertEq(entryPrice, 99_980_000);
        assertEq(pletherOracle.getLatestPrice(), 100_000_000);
        assertEq(address(pletherOracle).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_Gas_SharedBasketPaysOnceAndBothOrdersExecute() public {
        uint64 commit = uint64(block.timestamp);
        _commit(ALICE, 0);
        uint64 last = _commit(BOB, 0);
        _advance(commit + 1);
        uint256 updates = baseMockPyth.updatePriceFeedsCallCount();
        uint256 parses = baseMockPyth.parseUniqueCallCount();
        uint256 beforeBalance = address(this).balance;
        OrderV2Types.BatchResult memory result =
            router.executeOrderBatch{value: 5 * FEE, gas: KEEPER_GAS_CAP}(last, _payload(commit + 1, commit));
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates + 1);
        assertEq(baseMockPyth.parseUniqueCallCount(), parses + 1);
        assertEq(beforeBalance - address(this).balance, 2 * FEE);
        (uint256 a,,,,,,) = engine.positions(ALICE);
        (uint256 b,,,,,,) = engine.positions(BOB);
        assertEq(a, 10_000e18);
        assertEq(b, 10_000e18);
        _assertCoverage(engine.lastMarkTime());
    }

    function test_Gas_TerminalItemFailureRetainsSynchronizedMark() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 110_000_000);
        _advance(commit + 1);
        OrderV2Types.ExecutionResult memory result =
            router.executeOrder{value: 2 * FEE, gas: KEEPER_GAS_CAP}(id, _payload(commit + 1, commit));
        assertEq(uint256(result.status), uint256(OrderV2Types.LifecycleStatus.Failed));
        assertEq(engine.lastMarkTime(), commit + 1);
        _assertCoverage(engine.lastMarkTime());
        assertEq(address(baseMockPyth).balance, 2 * FEE);
        assertEq(router.nextExecuteId(), 0);
    }

    function _mixedBatch() internal returns (bytes[] memory data) {
        uint64 commit = uint64(block.timestamp);
        _commit(ALICE, 0);
        _advance(commit + 2);
        _commit(BOB, 0);
        _advance(commit + 3);
        bytes[] memory a = _payload(commit + 1, commit);
        bytes[] memory b = _payload(commit + 3, commit + 2);
        MockPyth.FeedUpdate[] memory first = abi.decode(a[0], (MockPyth.FeedUpdate[]));
        MockPyth.FeedUpdate[] memory second = abi.decode(b[0], (MockPyth.FeedUpdate[]));
        MockPyth.FeedUpdate[] memory both = new MockPyth.FeedUpdate[](first.length + second.length);
        for (uint256 i; i < first.length; ++i) {
            both[i] = first[i];
            both[first.length + i] = second[i];
        }
        data = new bytes[](1);
        data[0] = abi.encode(both);
    }

    function test_Gas_MixedBatchRequiresTwoParsesAndFourFees() public {
        bytes[] memory data = _mixedBatch();
        uint256 updates = baseMockPyth.updatePriceFeedsCallCount();
        uint256 beforeBalance = address(this).balance;
        OrderV2Types.BatchResult memory result = router.executeOrderBatch{value: 6 * FEE, gas: KEEPER_GAS_CAP}(2, data);
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(baseMockPyth.parseUniqueCallCount(), 2);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates + 2);
        assertEq(beforeBalance - address(this).balance, 4 * FEE);
        _assertCoverage(engine.lastMarkTime());
    }

    function test_LaterSynchronizationFailureRevertsCompletedBatchPrefix() public {
        uint64 mark = engine.lastMarkTime();
        bytes[] memory data = _mixedBatch();
        uint256 updates = baseMockPyth.updatePriceFeedsCallCount();
        baseMockPyth.setFailUpdateAtCall(updates + 2);
        vm.expectRevert(bytes("storage update failed"));
        router.executeOrderBatch{value: 4 * FEE}(2, data);
        assertEq(router.nextExecuteId(), 1);
        assertEq(engine.lastMarkTime(), mark);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates);
        assertEq(baseMockPyth.parseUniqueCallCount(), 0);
        assertEq(address(baseMockPyth).balance, 0);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0);
        assertEq(uint256(router.lifecycleBook().lifecycleStatus(1)), uint256(OrderV2Types.LifecycleStatus.Pending));
    }

    function test_LaterInsufficientFundingRevertsCompletedBatchPrefix() public {
        bytes[] memory data = _mixedBatch();
        vm.expectRevert(
            abi.encodeWithSelector(IPletherOracle.PletherOracle__InsufficientFee.selector, 3 * FEE, 4 * FEE)
        );
        router.executeOrderBatch{value: 3 * FEE}(2, data);
        assertEq(router.nextExecuteId(), 1);
        assertEq(address(baseMockPyth).balance, 0);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0);
    }

    function test_UnavailableHistoryPreservesExistingCacheAndReportsForwardedFunding() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 3);
        IPletherOracle.BatchOrderPriceCache memory cache;
        (,, cache) = pletherOracle.updateBatchOrderExecutionPrice{value: 2 * FEE}(
            address(this), _payload(commit + 1, commit), _request(commit, false), cache
        );
        uint256 beforeBalance = address(this).balance;
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot, IPletherOracle.BatchOrderPriceCache memory next) = pletherOracle.updateBatchOrderExecutionPrice{
            value: 2 * FEE
        }(
            address(this), _payload(commit + 1, commit), _request(commit + 1, false), cache
        );
        assertFalse(ok);
        assertEq(snapshot.updateFee, 2 * FEE);
        assertEq(keccak256(abi.encode(next)), keccak256(abi.encode(cache)));
        assertEq(address(this).balance, beforeBalance);
    }

    function test_UpdateFailureBubblesAndRollsBackParseAndMark() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        uint64 oldMark = engine.lastMarkTime();
        _advance(commit + 1);
        baseMockPyth.setUpdateFailure(true, false, bytes32(0));
        vm.expectRevert(bytes("storage update failed"));
        router.executeOrder{value: 2 * FEE}(id, _payload(commit + 1, commit));
        assertEq(baseMockPyth.parseUniqueCallCount(), 0);
        assertEq(address(baseMockPyth).balance, 0);
        assertEq(engine.lastMarkTime(), oldMark);
        assertEq(router.nextExecuteId(), id);
    }

    function test_StorageCoverageChecksEachParsedComponentNotOnlyMinimum() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 2);
        bytes[] memory data = _payload(commit + 1, commit);
        MockPyth.FeedUpdate[] memory updates = abi.decode(data[0], (MockPyth.FeedUpdate[]));
        updates[1].price.publishTime = commit + 2;
        data[0] = abi.encode(updates);
        baseMockPyth.setPrice(updates[1].id, 100_000_000, -8, commit + 1);
        baseMockPyth.setUpdateFailure(false, false, updates[1].id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StoredFeedBehind.selector, updates[1].id, commit + 1, commit + 2
            )
        );
        pletherOracle.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, false));
        assertEq(address(baseMockPyth).balance, 0);
        assertEq(baseMockPyth.parseUniqueCallCount(), 0);
    }

    function test_NewerStorageNeverChangesHistoricalFillOrMovesBackwards() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 3);
        baseMockPyth.setAllPrices(_basePythFeedIds(), 120_000_000, -8, commit + 2);
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) = pletherOracle.updateOrderExecutionPrice{
            value: 2 * FEE
        }(
            address(this), _payload(commit + 1, commit), _request(commit, true)
        );
        assertTrue(ok);
        assertEq(snapshot.price, 99_980_000);
        assertEq(snapshot.markPrice, 100_000_000);
        assertEq(snapshot.publishTime, commit + 1);
        assertEq(baseMockPyth.getPriceUnsafe(_basePythFeedIds()[0]).publishTime, commit + 2);
        assertEq(baseMockPyth.getPriceUnsafe(_basePythFeedIds()[0]).price, 120_000_000);
    }

    function test_EqualAndOlderHistoricalMarksKeepOrdering() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        _advance(commit + 2);
        vm.prank(address(router));
        engine.updateMarkPrice(100_000_000, commit + 2);
        router.executeOrder{value: 2 * FEE}(id, _payload(commit + 1, commit));
        assertEq(engine.lastMarkTime(), commit + 2);
        // Old historical settlement still synchronizes its own payload without pretending to cover a newer mark.
        _assertCoverage(commit + 1);
    }

    function test_EqualTimestampRepairsStorage() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        _advance(commit + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(100_000_000, commit + 1);
        router.executeOrder{value: 2 * FEE}(id, _payload(commit + 1, commit));
        _assertCoverage(engine.lastMarkTime());
        assertEq(pletherOracle.getLatestPrice(), 100_000_000);
    }

    function test_InsufficientExecutionFundingRollsBack() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        _advance(commit + 1);
        vm.expectRevert(abi.encodeWithSelector(IPletherOracle.PletherOracle__InsufficientFee.selector, FEE, 2 * FEE));
        router.executeOrder{value: FEE}(id, _payload(commit + 1, commit));
        assertEq(router.nextExecuteId(), id);
        assertEq(address(baseMockPyth).balance, 0);
    }

    function test_UnavailableHistoryRefundsFundingExactlyOnce() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        _advance(commit + 1);
        uint256 beforeBalance = address(this).balance;
        OrderV2Types.BatchResult memory result =
            router.executeOrderBatch{value: 5 * FEE}(id, _payload(commit + 2, commit + 1));
        assertEq(uint256(result.stopReason), uint256(OrderV2Types.PendingReason.HistoricalPriceUnavailable));
        assertEq(address(this).balance, beforeBalance);
        assertEq(address(baseMockPyth).balance, 0);
        assertEq(address(pletherOracle).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function test_UnavailableHistoryDefersFullFundingAndClaimRejectsReentry() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        _advance(commit + 1);
        SynchronizationRefundReceiver recipient = new SynchronizationRefundReceiver(pletherOracle);
        recipient.execute{value: 5 * FEE}(address(router), id, _payload(commit + 2, commit + 1));
        assertEq(pletherOracle.claimableEth(address(recipient)), 2 * FEE);
        assertEq(routerAdmin.claimableEth(address(recipient)), 3 * FEE);
        assertEq(address(pletherOracle).balance, 2 * FEE);
        assertEq(address(routerAdmin).balance, 3 * FEE);
        assertEq(address(baseMockPyth).balance, 0);
        recipient.claim();
        assertTrue(recipient.reentryRejected());
        assertEq(pletherOracle.claimableEth(address(recipient)), 0);
        assertEq(address(recipient).balance, 2 * FEE);
    }

    function test_CacheReuseRequiresCoverageAndDoesNotRepair() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 1);
        IPletherOracle.BatchOrderPriceCache memory cache;
        (,, cache) = pletherOracle.updateBatchOrderExecutionPrice{value: 2 * FEE}(
            address(this), _payload(commit + 1, commit), _request(commit, false), cache
        );
        uint256 updates = baseMockPyth.updatePriceFeedsCallCount();
        (, IPletherOracle.PriceSnapshot memory reused,) =
            pletherOracle.updateBatchOrderExecutionPrice(address(this), new bytes[](0), _request(commit, false), cache);
        assertEq(reused.updateFee, 0);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates);
        bytes32 lagging = _basePythFeedIds()[_basePythFeedIds().length - 1];
        baseMockPyth.setPrice(lagging, 100_000_000, -8, commit);
        vm.expectRevert(
            abi.encodeWithSelector(IPletherOracle.PletherOracle__StoredFeedBehind.selector, lagging, commit, commit + 1)
        );
        pletherOracle.updateBatchOrderExecutionPrice(address(this), new bytes[](0), _request(commit, false), cache);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates);
    }

    function test_Gas_FrozenCloseExecutesWithOneFee() public {
        uint64 commit = uint64(block.timestamp);
        uint64 open = _commit(ALICE, 0);
        _advance(commit + 1);
        router.executeOrder{value: 2 * FEE}(open, _payload(commit + 1, commit));
        vm.mockCall(address(engine), abi.encodeWithSignature("isOracleFrozen()"), abi.encode(true));
        vm.prank(ALICE);
        uint64 close = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);
        _advance(commit + 2);
        uint256 beforeBalance = address(this).balance;
        uint256 parses = baseMockPyth.parseUniqueCallCount();
        OrderV2Types.ExecutionResult memory result =
            router.executeOrder{value: 3 * FEE, gas: KEEPER_GAS_CAP}(close, _payload(commit + 2, commit + 1));
        assertEq(uint256(result.status), uint256(OrderV2Types.LifecycleStatus.Executed));
        assertEq(beforeBalance - address(this).balance, FEE);
        assertEq(baseMockPyth.parseUniqueCallCount(), parses);
        (uint256 size,,,,,,) = engine.positions(ALICE);
        assertEq(size, 0);
        _assertCoverage(engine.lastMarkTime());
    }

    function test_Gas_FrozenUsesOnlySingleUpdate() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 1);
        vm.mockCall(address(engine), abi.encodeWithSignature("isOracleFrozen()"), abi.encode(true));
        bytes[] memory data = _payload(commit + 1, commit);
        assertEq(pletherOracle.getOrderExecutionFee(data), FEE);
        uint256 parses = baseMockPyth.parseUniqueCallCount();
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) = pletherOracle.updateOrderExecutionPrice{
            value: FEE, gas: KEEPER_GAS_CAP
        }(
            address(this), data, _request(commit, true)
        );
        assertTrue(ok);
        assertTrue(snapshot.oracleFrozen);
        assertEq(snapshot.updateFee, FEE);
        assertEq(baseMockPyth.parseUniqueCallCount(), parses);
        assertEq(address(baseMockPyth).balance, FEE);
    }

    function test_InvalidHistoricalBasketRollsBackBeforeStorageUpdate() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 10);
        bytes[] memory data = _payload(commit + 1, commit);
        MockPyth.FeedUpdate[] memory updates = abi.decode(data[0], (MockPyth.FeedUpdate[]));
        updates[1].price.publishTime = commit + 7;
        data[0] = abi.encode(updates);
        uint256 beforeUpdates = baseMockPyth.updatePriceFeedsCallCount();
        vm.expectPartialRevert(IPletherOracle.PletherOracle__PublishTimeDivergence.selector);
        pletherOracle.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, false));
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), beforeUpdates);
        assertEq(address(baseMockPyth).balance, 0);
        updates[1].price.publishTime = commit + 1;
        updates[0].price.conf = 10_000_000;
        data[0] = abi.encode(updates);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        pletherOracle.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, false));
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), beforeUpdates);
        assertEq(address(baseMockPyth).balance, 0);
    }

    function test_AllSixFeedsAreRequiredAndLastComponentIsChecked() public {
        uint64 commit = uint64(block.timestamp);
        _advance(commit + 1);
        bytes32[] memory ids = new bytes32[](6);
        uint256[] memory weights = new uint256[](6);
        uint256[] memory bases = new uint256[](6);
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](6);
        for (uint256 i; i < 6; ++i) {
            ids[i] = bytes32(uint256(i + 1));
            weights[i] = i == 5 ? 0.5e18 : 0.1e18;
            bases[i] = 1e8;
            updates[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(100_000_000, 0, -8, commit + 1, commit));
            baseMockPyth.setPrice(ids[i], 100_000_000, -8, commit);
        }
        PletherOracle six = new PletherOracle(
            address(engine), address(pool), address(baseMockPyth), ids, weights, bases, new bool[](6)
        );
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(updates);
        baseMockPyth.setUpdateFailure(false, false, ids[5]);
        vm.expectRevert(
            abi.encodeWithSelector(IPletherOracle.PletherOracle__StoredFeedBehind.selector, ids[5], commit, commit + 1)
        );
        six.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, false));
        baseMockPyth.setUpdateFailure(false, false, bytes32(0));
        updates[5].id = bytes32(uint256(99));
        data[0] = abi.encode(updates);
        (bool missing,) = six.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, false));
        assertFalse(missing, "missing sixth feed must be unavailable");
        assertEq(address(baseMockPyth).balance, 0);
        updates[5].id = ids[5];
        data[0] = abi.encode(updates);
        (bool ok,) = six.updateOrderExecutionPrice{value: 2 * FEE}(address(this), data, _request(commit, true));
        assertTrue(ok);
        for (uint256 i; i < 6; ++i) {
            assertEq(baseMockPyth.getPriceUnsafe(ids[i]).publishTime, commit + 1);
        }
    }

    function test_FadStillQuotesTwoFeesAndZeroFeeWorks() public {
        uint64 commit = uint64(block.timestamp);
        vm.mockCall(address(engine), abi.encodeWithSignature("isFadWindow()"), abi.encode(true));
        _advance(commit + 1);
        bytes[] memory data = _payload(commit + 1, commit);
        assertEq(pletherOracle.getOrderExecutionFee(data), 2 * FEE);
        assertEq(pletherOracle.getUpdateFee(data), FEE);
        baseMockPyth.setFee(0);
        (bool ok, IPletherOracle.PriceSnapshot memory snapshot) =
            pletherOracle.updateOrderExecutionPrice(address(this), data, _request(commit, true));
        assertTrue(ok);
        assertTrue(snapshot.isFadWindow);
        assertEq(snapshot.updateFee, 0);
        _assertCoverage(commit + 1);
    }

}

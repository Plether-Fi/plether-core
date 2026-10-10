// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {
    OracleSynchronizationTestBase,
    SynchronizationRefundReceiver
} from "../shared/OracleSynchronizationTestBase.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

contract OracleSynchronizationGasTest is OracleSynchronizationTestBase {

    function test_Gas_HistoricalExecutionSynchronizesAndPreservesFill() public {
        uint64 commit = uint64(block.timestamp);
        uint64 id = _commit(ALICE, 0);
        uint64 tick = commit + 1;
        _advance(tick);
        assertLt(baseMockPyth.getPriceUnsafe(_synchronizationFeedIds()[0]).publishTime, tick);
        uint256 beforeBalance = address(this).balance;
        uint256 beforeUpdates = baseMockPyth.updatePriceFeedsCallCount();
        bytes[] memory data = _payload(tick, commit);
        uint256 beforeGas = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder{value: 3 * FEE, gas: KEEPER_GAS_CAP}(id, data);
        emit log_named_uint("new historical execution call gas", beforeGas - gasleft());
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Executed));
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
        bytes[] memory data = _payload(commit + 1, commit);
        uint256 beforeGas = gasleft();
        OrderV3Types.BatchResult memory result =
            router.executeOrderBatch{value: 5 * FEE, gas: KEEPER_GAS_CAP}(last, data);
        emit log_named_uint("shared basket batch call gas", beforeGas - gasleft());
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
        bytes[] memory data = _payload(commit + 1, commit);
        uint256 beforeGas = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder{value: 2 * FEE, gas: KEEPER_GAS_CAP}(id, data);
        emit log_named_uint("failed item execution call gas", beforeGas - gasleft());
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Failed));
        assertEq(engine.lastMarkTime(), commit + 1);
        _assertCoverage(engine.lastMarkTime());
        assertEq(address(baseMockPyth).balance, 2 * FEE);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_Gas_MixedBatchRequiresTwoParsesAndFourFees() public {
        bytes[] memory data = _mixedBatch();
        uint256 updates = baseMockPyth.updatePriceFeedsCallCount();
        uint256 beforeBalance = address(this).balance;
        uint256 beforeGas = gasleft();
        OrderV3Types.BatchResult memory result = router.executeOrderBatch{value: 6 * FEE, gas: KEEPER_GAS_CAP}(2, data);
        emit log_named_uint("mixed basket batch call gas", beforeGas - gasleft());
        assertEq(result.terminalCount, 2);
        assertEq(result.nextOrderId, 0);
        assertEq(baseMockPyth.parseUniqueCallCount(), 2);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updates + 2);
        assertEq(beforeBalance - address(this).balance, 4 * FEE);
        _assertCoverage(engine.lastMarkTime());
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
        bytes[] memory data = _payload(commit + 2, commit + 1);
        uint256 beforeGas = gasleft();
        OrderV3Types.ExecutionResult memory result =
            router.executeOrder{value: 3 * FEE, gas: KEEPER_GAS_CAP}(close, data);
        emit log_named_uint("frozen close execution call gas", beforeGas - gasleft());
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Executed));
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

}

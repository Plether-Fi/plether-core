// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../packages/perps/test/perps/BasePerpTest.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../script/DeployPerpsArbitrumSepolia.s.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";

/// @notice Same test runs against baseline and candidate. No Pyth code/storage/signature substitution is permitted.
/// @dev Missing fixture or RPC configuration fails; no skip or mock fallback qualifies this release gate.
contract OracleSynchronizationForkTest is BasePerpTest {

    string internal fixture;
    address internal realPyth;
    bytes32[] internal ids;
    bytes[] internal data;
    uint64 internal commitTime;
    uint64 internal executionTime;
    uint64 internal tick;
    uint256 internal forkNumber;

    function setUp() public override {
        fixture = vm.readFile(vm.envString("ORACLE_SYNC_FIXTURE"));
        forkNumber = vm.parseJsonUint(fixture, ".forkBlockNumber");
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), forkNumber);
        assertEq(block.chainid, 421_614);
        assertEq(block.chainid, vm.parseJsonUint(fixture, ".chainId"));
        vm.roll(forkNumber + 1);
        assertEq(blockhash(forkNumber), vm.parseJsonBytes32(fixture, ".forkBlockHash"));
        vm.roll(forkNumber);
        assertEq(block.timestamp, vm.parseJsonUint(fixture, ".forkTimestamp"));
        realPyth = vm.parseJsonAddress(fixture, ".pyth");
        assertEq(realPyth, 0x0B73614636C855Bf23F342F307FB981A3e47f42B);
        assertGt(realPyth.code.length, 0);
        ids = vm.parseJsonBytes32Array(fixture, ".feedIds");
        assertEq(ids.length, 6);
        data = abi.decode(vm.parseJson(fixture, ".updateData"), (bytes[]));
        assertGt(data.length, 0);
        commitTime = uint64(vm.parseJsonUint(fixture, ".commitTimestamp"));
        executionTime = uint64(vm.parseJsonUint(fixture, ".executionTimestamp"));
        uint256[] memory stored = vm.parseJsonUintArray(fixture, ".initialStoredPublishTimes");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime, stored[i]);
        }

        // Deploy/fund only local test contracts. Super setup never calls the real Pyth deployment.
        super.setUp();
        pletherOracle = new ArbitrumSepoliaReleaseOracle(
            address(engine),
            address(pool),
            realPyth,
            ids,
            vm.parseJsonUintArray(fixture, ".quantities"),
            vm.parseJsonUintArray(fixture, ".basePrices"),
            abi.decode(vm.parseJson(fixture, ".inversions"), (bool[]))
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        vm.warp(commitTime);
        vm.roll(forkNumber);
        assertFalse(pletherOracle.isOracleFrozen(), "fixture must exercise historical execution");
        _fundTrader(address(0xA11CE), 10_000e6);
    }

    function test_RealPythBaselineVersusAtomicSynchronization() public {
        bool fixedImplementation = vm.envBool("ORACLE_SYNC_EXPECT_FIXED");
        uint256 fee = IPyth(realPyth).getUpdateFee(data);
        vm.deal(address(this), 10 ether + 4 * fee);
        vm.warp(executionTime);
        uint256 beforeParse = vm.snapshotState();
        PythStructs.PriceFeed[] memory parsed = IPyth(realPyth).parsePriceFeedUpdatesUnique{value: fee}(
            data, ids, commitTime + 1, uint64(commitTime + pletherOracle.orderSettlementWindow())
        );
        uint256[] memory recorded = vm.parseJsonUintArray(fixture, ".publishTimes");
        uint256[] memory previous = vm.parseJsonUintArray(fixture, ".previousPublishTimes");
        uint256 minimum = type(uint256).max;
        for (uint256 i; i < ids.length; ++i) {
            assertEq(parsed[i].id, ids[i]);
            assertEq(parsed[i].price.publishTime, recorded[i]);
            assertLe(previous[i], commitTime);
            assertGt(recorded[i], commitTime);
            assertLe(recorded[i], executionTime);
            if (recorded[i] < minimum) {
                minimum = recorded[i];
            }
        }
        assertTrue(vm.revertToState(beforeParse));
        tick = uint64(minimum);
        uint256 oldest = type(uint256).max;
        for (uint256 i; i < ids.length; ++i) {
            uint256 time = IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime;
            if (time < oldest) {
                oldest = time;
            }
        }
        assertLt(oldest, tick, "already-current storage cannot prove the regression");

        vm.warp(commitTime);
        vm.prank(address(0xA11CE));
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 0, false);
        vm.warp(executionTime);
        vm.roll(vm.parseJsonUint(fixture, ".executionBlock"));
        assertGt(block.number, forkNumber);
        uint256 executionFunding = fixedImplementation ? 2 * fee : fee;
        // Direct resolution supplies expected historical prices; revert all its effects before the real order.
        uint256 beforeResolution = vm.snapshotState();
        (, IPletherOracle.PriceSnapshot memory expected) = pletherOracle.updateOrderExecutionPrice{
            value: executionFunding
        }(
            address(this), data, IPletherOracle.OrderExecutionRequest(commitTime, 0, CfdTypes.Side.LONG, false, true)
        );
        assertTrue(vm.revertToState(beforeResolution));
        uint256 beforeBalance = realPyth.balance;
        OrderV2Types.ExecutionResult memory result =
            router.executeOrder{value: executionFunding, gas: 30_000_000}(id, data);
        assertEq(
            uint256(result.status), uint256(OrderV2Types.LifecycleStatus.Executed), "must execute, not merely return"
        );
        assertEq(engine.lastMarkTime(), tick);
        assertEq(engine.lastMarkPrice(), expected.markPrice);
        (,, uint256 entryPrice,,,,) = engine.positions(address(0xA11CE));
        assertEq(entryPrice, expected.price);
        assertEq(realPyth.balance - beforeBalance, executionFunding);
        emit log_named_uint("historical fill", entryPrice);
        emit log_named_uint("neutral mark", engine.lastMarkPrice());
        if (fixedImplementation) {
            for (uint256 i; i < ids.length; ++i) {
                assertGe(IPyth(realPyth).getPriceUnsafe(ids[i]).publishTime, parsed[i].price.publishTime);
            }
            assertGt(pletherOracle.getLatestPrice(), 0);
        } else {
            vm.expectPartialRevert(IPletherOracle.PletherOracle__PriceOutOfOrder.selector);
            pletherOracle.getLatestPrice();
        }
    }

}

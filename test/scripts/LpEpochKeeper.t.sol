// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {LpEpochKeeper} from "../../script/LpEpochKeeper.s.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {SettlementMonitorViewTypes} from "@plether/perps/interfaces/SettlementMonitorViewTypes.sol";
import {Test} from "forge-std/Test.sol";

contract LpEpochKeeperHarness is LpEpochKeeper {

    function prepareSettlement(
        address monitor,
        address router,
        uint256 observedEpoch
    ) external view returns (SettlementMonitorViewTypes.SettlementStatus memory status, address pool) {
        return _prepareSettlement(monitor, router, observedEpoch);
    }

    function quoteAtomicFee(
        address router,
        bytes[] memory updateData
    ) external view returns (uint256 fee) {
        return _quoteAtomicFee(router, updateData);
    }

    function executeCachedMark(
        address pool,
        uint256 price,
        uint256 publishTime
    ) external {
        _executeCachedMark(pool, price, publishTime);
    }

    function executeAtomicRefresh(
        address router,
        bytes[] memory updateData,
        uint256 fee
    ) external payable {
        _executeAtomicRefresh(router, updateData, fee);
    }

}

contract MockLpEpochSettlementMonitor {

    address public immutable ROUTER;
    address public immutable HOUSE_POOL;

    SettlementMonitorViewTypes.SettlementStatus internal _status;

    constructor(
        address router,
        address pool
    ) {
        ROUTER = router;
        HOUSE_POOL = pool;
    }

    function setStatus(
        SettlementMonitorViewTypes.ExecutionPath executionPath,
        bool hasMaturedWork,
        uint256 executionPathDependencyMask,
        uint256 dependencyFailureMask,
        uint256 cachedMarkPrice,
        uint256 cachedMarkTime
    ) external {
        _status.requiredExecutionPath = executionPath;
        _status.hasMaturedWork = hasMaturedWork;
        _status.executionPathDependencyMask = executionPathDependencyMask;
        _status.dependencyFailureMask = dependencyFailureMask;
        _status.cachedMarkPrice = cachedMarkPrice;
        _status.cachedMarkTime = cachedMarkTime;
    }

    function setLpEpochSettlementPaused(
        bool paused
    ) external {
        _status.lpEpochSettlementPaused = paused;
    }

    function getSettlementStatus(
        uint256
    ) external view returns (SettlementMonitorViewTypes.SettlementStatus memory status) {
        return _status;
    }

}

contract MockLpEpochSettlementPool {

    uint256 public callCount;
    uint256 public lastPrice;
    uint256 public lastPublishTime;
    address public lastCaller;

    function settleLpEpoch(
        uint256 price,
        uint256 publishTime
    ) external {
        ++callCount;
        lastPrice = price;
        lastPublishTime = publishTime;
        lastCaller = msg.sender;
    }

}

contract MockLpEpochSettlementOracle {

    uint256 public fee;
    bytes32 public expectedUpdateDataHash;
    uint256 public orderFee;
    bytes32 public expectedOrderDataHash;

    function configure(
        bytes[] memory updateData,
        uint256 fee_
    ) external {
        expectedUpdateDataHash = keccak256(abi.encode(updateData));
        fee = fee_;
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint256) {
        require(keccak256(abi.encode(updateData)) == expectedUpdateDataHash, "unexpected update data");
        return fee;
    }

    function configureOrderFee(
        bytes[] memory orderData,
        uint256 fee_
    ) external {
        expectedOrderDataHash = keccak256(abi.encode(orderData));
        orderFee = fee_;
    }

    function getOrderExecutionFee(
        bytes[] calldata orderData
    ) external view returns (uint256) {
        require(keccak256(abi.encode(orderData)) == expectedOrderDataHash, "unexpected order data");
        return orderFee;
    }

}

contract MockLpEpochSettlementRouter {

    address public pletherOracle;
    uint256 public callCount;
    uint256 public lastValue;
    bytes32 public lastUpdateDataHash;
    address public lastCaller;
    uint64 public nextExecuteId = 1;
    uint64 public globalTailOrderId;
    uint256 public constant maxPruneOrdersPerCall = 2;
    uint64 public batchEnd;
    uint256 public batchValue;
    address public batchCaller;
    uint64[] public cleanupIds;

    constructor(
        address oracle
    ) {
        pletherOracle = oracle;
    }

    function setPletherOracle(
        address oracle
    ) external {
        pletherOracle = oracle;
    }

    function setQueue(
        uint64 head,
        uint64 tail
    ) external {
        nextExecuteId = head;
        globalTailOrderId = tail;
    }

    function executeOrderBatch(
        uint64 last,
        bytes[] calldata
    ) external payable returns (OrderV3Types.BatchResult memory) {
        batchEnd = last;
        batchValue = msg.value;
        batchCaller = msg.sender;
        return OrderV3Types.BatchResult(nextExecuteId, 0, OrderV3Types.PendingReason.HistoricalPriceUnavailable);
    }

    function clearInvalidOrders(
        uint64[] calldata ids
    ) external returns (uint256, uint256) {
        cleanupIds = ids;
        return (ids.length, 0);
    }

    function settleLpEpoch(
        bytes[] calldata updateData
    ) external payable {
        ++callCount;
        lastValue = msg.value;
        lastUpdateDataHash = keccak256(abi.encode(updateData));
        lastCaller = msg.sender;
    }

}

contract LpEpochKeeperTest is Test {

    LpEpochKeeperHarness internal keeper;
    MockLpEpochSettlementPool internal pool;
    MockLpEpochSettlementOracle internal oracle;
    MockLpEpochSettlementRouter internal router;
    MockLpEpochSettlementMonitor internal monitor;

    uint256 internal constant OBSERVED_EPOCH = 42;
    uint256 internal constant CACHED_PRICE = 123_456_789;
    uint256 internal constant CACHED_TIME = 1_759_000_000;
    uint256 internal constant KEEPER_PRIVATE_KEY = 0xA11CE;

    function setUp() public {
        keeper = new LpEpochKeeperHarness();
        pool = new MockLpEpochSettlementPool();
        oracle = new MockLpEpochSettlementOracle();
        router = new MockLpEpochSettlementRouter(address(oracle));
        monitor = new MockLpEpochSettlementMonitor(address(router), address(pool));
    }

    function test_PrepareSettlementRejectsRouterBindingMismatch() public {
        MockLpEpochSettlementRouter otherRouter = new MockLpEpochSettlementRouter(address(oracle));
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 0, 0, CACHED_PRICE, CACHED_TIME);

        vm.expectRevert(
            abi.encodeWithSelector(
                LpEpochKeeper.LpEpochKeeper__RouterMismatch.selector, address(otherRouter), address(router)
            )
        );
        keeper.prepareSettlement(address(monitor), address(otherRouter), OBSERVED_EPOCH);
    }

    function test_PrepareSettlementRejectsUnknownExecutionPath() public {
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.Unknown, true, 0, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(LpEpochKeeper.LpEpochKeeper__ExecutionPathUnknown.selector, 0));
        keeper.prepareSettlement(address(monitor), address(router), OBSERVED_EPOCH);
    }

    function test_PrepareSettlementRejectsExecutionPathDependencyFailure() public {
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 1 << 3, 1 << 3, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(LpEpochKeeper.LpEpochKeeper__ExecutionPathUnknown.selector, 1 << 3));
        keeper.prepareSettlement(address(monitor), address(router), OBSERVED_EPOCH);
    }

    function test_PrepareSettlementRejectsNoMaturedWork() public {
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.NoMaturedWork, false, 0, 0, 0, 0);

        vm.expectRevert(LpEpochKeeper.LpEpochKeeper__NoMaturedWork.selector);
        keeper.prepareSettlement(address(monitor), address(router), OBSERVED_EPOCH);
    }

    function test_PrepareSettlementPreservesKnownRouteDespiteOptionalDependencyFailure() public {
        uint256 optionalDependencyFailure = 1 << 9;
        monitor.setStatus(
            SettlementMonitorViewTypes.ExecutionPath.CachedMark,
            true,
            0,
            optionalDependencyFailure,
            CACHED_PRICE,
            CACHED_TIME
        );

        (SettlementMonitorViewTypes.SettlementStatus memory status, address selectedPool) =
            keeper.prepareSettlement(address(monitor), address(router), OBSERVED_EPOCH);

        assertEq(uint8(status.requiredExecutionPath), uint8(SettlementMonitorViewTypes.ExecutionPath.CachedMark));
        assertEq(status.dependencyFailureMask, optionalDependencyFailure);
        assertEq(selectedPool, address(pool));
    }

    function test_CachedMarkCallsOnlyHousePoolWithLensArguments() public {
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 0, 0, CACHED_PRICE, CACHED_TIME);
        (SettlementMonitorViewTypes.SettlementStatus memory status, address selectedPool) =
            keeper.prepareSettlement(address(monitor), address(router), OBSERVED_EPOCH);

        keeper.executeCachedMark(selectedPool, status.cachedMarkPrice, status.cachedMarkTime);

        assertEq(pool.callCount(), 1);
        assertEq(pool.lastPrice(), CACHED_PRICE);
        assertEq(pool.lastPublishTime(), CACHED_TIME);
        assertEq(router.callCount(), 0);
    }

    function test_AtomicRefreshQuotesActiveOracleAndForwardsExactFee() public {
        bytes[] memory updateData = _updateData();
        uint256 fee = 17 wei;
        oracle.configure(updateData, 999 wei);

        MockLpEpochSettlementOracle replacementOracle = new MockLpEpochSettlementOracle();
        replacementOracle.configure(updateData, fee);
        router.setPletherOracle(address(replacementOracle));

        uint256 quotedFee = keeper.quoteAtomicFee(address(router), updateData);
        assertEq(quotedFee, fee);

        vm.deal(address(keeper), quotedFee);
        keeper.executeAtomicRefresh(address(router), updateData, quotedFee);

        assertEq(router.callCount(), 1);
        assertEq(router.lastValue(), fee);
        assertEq(router.lastUpdateDataHash(), keccak256(abi.encode(updateData)));
        assertEq(pool.callCount(), 0);
    }

    /// @dev Run cases share one test because Foundry's process-global environment can race between parallel tests.
    function test_RunRejectsHeldRoutesBeforeInputsThenDispatchesAfterRelease() public {
        bytes[] memory updateData = _updateData();

        monitor.setLpEpochSettlementPaused(true);
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 0, 0, CACHED_PRICE, CACHED_TIME);
        _setKeeperEnvironment("not-valid-abi-encoded-bytes");
        vm.setEnv("ORDER_PYTH_UPDATE_DATA", "not-valid-abi-encoded-bytes");
        vm.expectRevert(LpEpochKeeper.LpEpochKeeper__LpEpochSettlementPaused.selector);
        keeper.processOrders();
        vm.expectRevert(LpEpochKeeper.LpEpochKeeper__LpEpochSettlementPaused.selector);
        keeper.run();

        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh, true, 0, 0, 0, 0);
        vm.expectRevert(LpEpochKeeper.LpEpochKeeper__LpEpochSettlementPaused.selector);
        keeper.run();

        router.setPletherOracle(address(0));
        _setKeeperEnvironment(vm.toString(abi.encode(updateData)));
        vm.expectRevert(LpEpochKeeper.LpEpochKeeper__LpEpochSettlementPaused.selector);
        keeper.run();

        assertEq(pool.callCount(), 0, "held cached route must not broadcast");
        assertEq(router.callCount(), 0, "held atomic route must not broadcast");

        router.setPletherOracle(address(oracle));
        monitor.setLpEpochSettlementPaused(false);
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 0, 0, CACHED_PRICE, CACHED_TIME);
        _setKeeperEnvironment("not-valid-abi-encoded-bytes");

        keeper.run();

        assertEq(pool.callCount(), 1);
        assertEq(pool.lastPrice(), CACHED_PRICE);
        assertEq(pool.lastPublishTime(), CACHED_TIME);
        assertEq(pool.lastCaller(), vm.addr(KEEPER_PRIVATE_KEY));
        assertEq(router.callCount(), 0);

        uint256 fee = 23 wei;
        oracle.configure(updateData, fee);
        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.AtomicOracleRefresh, true, 0, 0, 0, 0);
        string memory encodedUpdateData = vm.toString(abi.encode(updateData));
        _setKeeperEnvironment(encodedUpdateData);
        vm.deal(vm.addr(KEEPER_PRIVATE_KEY), fee);

        keeper.run();

        assertEq(router.callCount(), 1);
        assertEq(router.lastValue(), fee);
        assertEq(router.lastUpdateDataHash(), keccak256(abi.encode(updateData)));
        assertEq(router.lastCaller(), vm.addr(KEEPER_PRIVATE_KEY));
        assertEq(pool.callCount(), 1, "atomic route must not call the Pool after the cached pass");

        _checkOrderPass(updateData, fee);
    }

    function _checkOrderPass(
        bytes[] memory updateData,
        uint256 lpFee
    ) private {
        router.setQueue(20, 100);
        uint256 orderFee = 5 wei;
        bytes[] memory orderData = new bytes[](1);
        orderData[0] = hex"9876";
        oracle.configureOrderFee(orderData, orderFee);
        vm.setEnv("ORDER_PYTH_UPDATE_DATA", vm.toString(abi.encode(orderData)));
        address operator = vm.addr(KEEPER_PRIVATE_KEY);
        vm.deal(operator, 4 * orderFee + lpFee);

        keeper.processOrders();
        assertEq(router.batchEnd(), 23, "only four consecutive IDs are eligible for the batch");
        assertEq(router.batchValue(), 4 * orderFee);
        assertEq(router.batchCaller(), operator);
        assertEq(router.nextExecuteId(), 20, "the order pass stopped with the head still pending");

        keeper.run();
        assertEq(router.callCount(), 2, "pending head did not stop atomic LP settlement");

        monitor.setStatus(SettlementMonitorViewTypes.ExecutionPath.CachedMark, true, 0, 0, CACHED_PRICE, CACHED_TIME);
        vm.setEnv("PYTH_UPDATE_DATA", "0x");
        keeper.processOrders();
        assertEq(router.cleanupIds(0), 20);
        assertEq(router.cleanupIds(1), 21);
        keeper.run();
        assertEq(pool.callCount(), 2, "lack of a current basket did not stop cached LP settlement");

        vm.setEnv("ORDER_PYTH_UPDATE_DATA", "0x");
        vm.setEnv("PYTH_UPDATE_DATA", vm.toString(abi.encode(updateData)));
        router.setQueue(24, 24);
        keeper.processOrders();
        assertEq(router.cleanupIds(0), 24, "missing historical data still allows cleanup");
    }

    function _setKeeperEnvironment(
        string memory pythUpdateData
    ) internal {
        vm.setEnv("SETTLEMENT_MONITOR_LENS", vm.toString(address(monitor)));
        vm.setEnv("PERPS_ORDER_ROUTER", vm.toString(address(router)));
        vm.setEnv("OBSERVED_EPOCH", vm.toString(OBSERVED_EPOCH));
        vm.setEnv("KEEPER_PRIVATE_KEY", vm.toString(KEEPER_PRIVATE_KEY));
        vm.setEnv("PYTH_UPDATE_DATA", pythUpdateData);
    }

    function _updateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](2);
        updateData[0] = hex"010203";
        updateData[1] = hex"aabbccdd";
    }

}

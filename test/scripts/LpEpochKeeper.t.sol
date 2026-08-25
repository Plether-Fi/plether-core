// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LpEpochKeeper} from "../../script/LpEpochKeeper.s.sol";
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

}

contract MockLpEpochSettlementRouter {

    address public pletherOracle;
    uint256 public callCount;
    uint256 public lastValue;
    bytes32 public lastUpdateDataHash;
    address public lastCaller;

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

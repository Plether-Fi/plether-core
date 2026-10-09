// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../../packages/perps/test/perps/BasePerpTest.sol";
import {ArbitrumSepoliaReleaseOracle} from "../../../script/DeployPerpsArbitrumSepolia.s.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";

/// @dev Intentionally non-view: each probe must be a real top-level CALL in Forge isolation mode.
contract OracleSynchronizationIsolationProbe {

    uint256 private probeValue = 1;

    function measureColdLoad() external returns (uint256 loadGas, uint256 observed) {
        uint256 beforeGas = gasleft();
        assembly ("memory-safe") {
            observed := sload(probeValue.slot)
        }
        loadGas = beforeGas - gasleft();
    }

}

/// @dev Rejects both refund channels initially, then claims the exact credits without funding another execution.
contract OracleSynchronizationRejectingKeeper {

    bool internal accepting;

    receive() external payable {
        require(accepting, "reject immediate refund");
    }

    function execute(
        address router,
        uint64 id,
        bytes[] calldata data,
        uint256 gasCap
    ) external payable returns (OrderV3Types.BatchResult memory result, uint256 callGas) {
        uint256 beforeGas = gasleft();
        result = IPerpsKeeper(router).executeOrderBatch{value: msg.value, gas: gasCap}(id, data);
        callGas = beforeGas - gasleft();
    }

    function claimOracle(
        IPletherOracle oracle
    ) external {
        accepting = true;
        oracle.claimEthRefund();
    }

    function claimRouter(
        OrderRouterAdmin admin
    ) external {
        accepting = true;
        admin.claimBalance(true);
    }

}

/// @dev Ordinary helper, deliberately separate from the cross-version baseline test entrypoint.
abstract contract OracleSynchronizationScenarioBase is BasePerpTest {

    address internal constant REAL_PYTH = 0x0B73614636C855Bf23F342F307FB981A3e47f42B;
    address internal constant SCENARIO_ALICE = address(0xA11CE);
    address internal constant SCENARIO_BOB = address(0xB0B);
    uint256 internal constant SCENARIO_GAS_CAP = 30_000_000;
    uint256 internal constant SCENARIO_SIZE = 10_000e18;
    uint256 internal constant SCENARIO_REFUND_SURPLUS = 1 gwei;

    struct SignedFixture {
        string json;
        uint256 forkNumber;
        uint256 forkTime;
        bytes32 forkHash;
        uint64 commitTime;
        uint64 executionTime;
        bytes32[] ids;
        uint256[] publishTimes;
        uint256[] previousTimes;
        uint256[] initialTimes;
        bytes[] data;
    }

    struct ScenarioEvidence {
        string scenarioId;
        string outcome;
        uint256 callGas;
        uint256 quoteWei;
        uint256 fundedWei;
        uint256 surplusWei;
        uint256 pythFeeDeltaWei;
        uint256 immediateRefundWei;
        uint256 oracleCreditedWei;
        uint256 routerCreditedWei;
        uint256 oracleDeferredWei;
        uint256 routerDeferredWei;
        uint256 oracleClaimedWei;
        uint256 routerClaimedWei;
        uint256 terminalCount;
        uint256 expectedParseCalls;
        uint256 expectedUpdateCalls;
        bool liveReadChecked;
        bool oracleRefundExercised;
        bool routerRefundExercised;
        uint256[] requiredPublishTimes;
        uint256[] lifecycleStatuses;
        uint256[] orderIds;
        uint256[] orderCommitTimes;
        uint256[] executionDeadlines;
    }

    string internal scenarioManifest;
    bytes32[] internal scenarioFeedIds;
    bool internal scenarioIsolationVerified;

    function setUp() public virtual override {
        assertEq(vm.envString("ORACLE_SYNC_ISOLATION_MODE"), "transaction", "runner must enable --isolate");
        scenarioManifest = vm.readFile(vm.envString("ORACLE_SYNC_SCENARIO_MANIFEST"));
        assertEq(vm.parseJsonUint(scenarioManifest, ".schemaVersion"), 1);
        // Missing fixtures are failures even if a caller selects just one of the required tests.
        _fixture("historicalA");
        _fixture("historicalB");
        _fixture("fridayOpening");
        _fixture("fridayClosing");
    }

    function _fixture(
        string memory key
    ) internal view returns (SignedFixture memory f) {
        string memory path = vm.parseJsonString(scenarioManifest, string.concat(".fixtures.", key));
        require(bytes(path).length != 0, "missing signed fixture path");
        f.json = vm.readFile(path);
        require(vm.parseJsonUint(f.json, ".schemaVersion") == 1, "unsupported signed fixture schema");
        require(vm.parseJsonUint(f.json, ".chainId") == 421_614, "wrong fixture chain");
        require(vm.parseJsonAddress(f.json, ".pyth") == REAL_PYTH, "wrong Pyth deployment");
        f.forkNumber = vm.parseJsonUint(f.json, ".forkBlockNumber");
        f.forkTime = vm.parseJsonUint(f.json, ".forkTimestamp");
        f.forkHash = vm.parseJsonBytes32(f.json, ".forkBlockHash");
        uint256 commit = vm.parseJsonUint(f.json, ".commitTimestamp");
        uint256 execution = vm.parseJsonUint(f.json, ".executionTimestamp");
        require(execution <= type(uint64).max && commit < execution, "invalid fixture times");
        f.commitTime = uint64(commit);
        f.executionTime = uint64(execution);
        f.ids = vm.parseJsonBytes32Array(f.json, ".feedIds");
        f.publishTimes = vm.parseJsonUintArray(f.json, ".publishTimes");
        f.previousTimes = vm.parseJsonUintArray(f.json, ".previousPublishTimes");
        f.initialTimes = vm.parseJsonUintArray(f.json, ".initialStoredPublishTimes");
        f.data = abi.decode(vm.parseJson(f.json, ".updateData"), (bytes[]));
        require(
            f.ids.length == 6 && f.publishTimes.length == 6 && f.previousTimes.length == 6 && f.initialTimes.length == 6
                && f.data.length > 0,
            "incomplete six-feed signed fixture"
        );
        require(f.forkTime <= commit, "fork state must precede commit");
        for (uint256 i; i < 6; ++i) {
            require(f.previousTimes[i] <= commit && commit < f.publishTimes[i], "invalid unique-tick window");
            require(f.publishTimes[i] <= execution && f.publishTimes[i] <= commit + 15, "invalid execution window");
            for (uint256 j; j < i; ++j) {
                require(f.ids[i] != f.ids[j], "duplicate fixture feed");
            }
        }
        for (uint256 i; i < f.data.length; ++i) {
            require(f.data[i].length != 0, "empty signed payload");
        }
    }

    function _prepareScenario(
        SignedFixture memory f
    ) internal {
        vm.createSelectFork(vm.envString("ARB_SEPOLIA_RPC_URL"), f.forkNumber);
        _verifyTransactionIsolation();
        assertEq(block.chainid, 421_614);
        vm.roll(f.forkNumber + 1);
        assertEq(blockhash(f.forkNumber), f.forkHash);
        vm.roll(f.forkNumber);
        assertEq(vm.getBlockTimestamp(), f.forkTime);
        assertGt(REAL_PYTH.code.length, 0);
        scenarioFeedIds = f.ids;
        _assertStoredTimes(f.initialTimes);
        vm.warp(SETUP_TIMESTAMP);
        super.setUp();
        // Only the locally deployed protocol fixture is replaced. Real Pyth code, storage and signatures are untouched.
        pletherOracle = new ArbitrumSepoliaReleaseOracle(
            address(engine),
            address(pool),
            REAL_PYTH,
            f.ids,
            vm.parseJsonUintArray(f.json, ".quantities"),
            vm.parseJsonUintArray(f.json, ".basePrices"),
            abi.decode(vm.parseJson(f.json, ".inversions"), (bool[]))
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(pletherOracle)));
        vm.warp(f.forkTime);
        assertGe(vm.getBlockTimestamp(), routerAdmin.oracleConfigActivationTime());
        routerAdmin.finalizeOracleConfig();
        _assertStoredTimes(f.initialTimes);
        vm.warp(f.commitTime);
        vm.roll(f.forkNumber);
        assertFalse(pletherOracle.isOracleFrozen());
        vm.deal(address(this), 100 ether);
        _fundTrader(SCENARIO_ALICE, 10_000e6);
        _fundTrader(SCENARIO_BOB, 10_000e6);
    }

    function _verifyTransactionIsolation() internal {
        OracleSynchronizationIsolationProbe probe = new OracleSynchronizationIsolationProbe();
        (uint256 firstGas, uint256 firstValue) = probe.measureColdLoad();
        (uint256 secondGas, uint256 secondValue) = probe.measureColdLoad();
        assertEq(firstValue, 1);
        assertEq(secondValue, 1);
        // EIP-2929 cold SLOAD is 2100 gas; the same warm slot is only 100 gas.
        // Small compiler/measurement overhead fits below 3000, far from the warm-call result.
        assertGe(firstGas, 2000, "first probe SLOAD was warm; --isolate is required");
        assertGe(secondGas, 2000, "second probe SLOAD was warm; --isolate is required");
        assertLt(firstGas, 3000);
        assertLt(secondGas, 3000);
        scenarioIsolationVerified = true;
    }

    function _assertCompatible(
        SignedFixture memory a,
        SignedFixture memory b
    ) internal pure {
        require(keccak256(abi.encode(a.ids)) == keccak256(abi.encode(b.ids)), "fixture feed order mismatch");
    }

    function _commitScenarioOrder(
        address account,
        bool close,
        uint256 target
    ) internal returns (uint64 id) {
        uint32 window = uint32(router.maxExecutionWindowSeconds());
        OrderV3Types.OrderRequest memory request = OrderV3Types.OrderRequest({
            clientOrderId: keccak256(abi.encode("real-pyth-v3-gas", account, router.nextCommitId())),
            side: CfdTypes.Side.LONG,
            sizeDelta: SCENARIO_SIZE,
            marginDelta: close ? 0 : 1000e6,
            targetPrice: target,
            isClose: close,
            bounds: OrderV3Types.ExecutionBounds({
                submitBy: uint64(vm.getBlockTimestamp()),
                executionWindowSeconds: window,
                allowedExecutionModes: 7,
                expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
                maxExecutionBountyUsdc: type(uint256).max,
                maxExecutionNotionalUsdc: type(uint256).max,
                maxGrossAccountDebitUsdc: type(uint256).max,
                maxActionChargeUsdc: type(uint256).max,
                maxExplicitFeesUsdc: type(uint256).max,
                maxPostPositionSize: type(uint256).max,
                minPostSettlementBalanceUsdc: 0,
                minPostPositionEquityUsdc: 0,
                maxPostLeverageBps: type(uint32).max
            })
        });
        vm.prank(account);
        id = OrderRouter(payable(address(router))).commitOrder(request);
    }

    function _advanceScenario(
        uint256 timestamp
    ) internal {
        assertGe(timestamp, vm.getBlockTimestamp(), "scenario time must move forward");
        vm.warp(timestamp);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _expectedHistorical(
        SignedFixture memory f,
        bytes[] memory data
    ) internal returns (IPletherOracle.PriceSnapshot memory expected) {
        uint256 checkpoint = vm.snapshotState();
        uint256 q = IPyth(REAL_PYTH).getUpdateFee(data);
        PythStructs.PriceFeed[] memory parsed = IPyth(REAL_PYTH).parsePriceFeedUpdatesUnique{value: q}(
            data, f.ids, f.commitTime + 1, _parseDeadline(f.commitTime)
        );
        assertEq(parsed.length, 6);
        for (uint256 i; i < 6; ++i) {
            assertEq(parsed[i].id, f.ids[i]);
            assertEq(parsed[i].price.publishTime, f.publishTimes[i]);
        }
        bool ok;
        (ok, expected) = pletherOracle.updateOrderExecutionPrice{value: 2 * q}(
            address(this), data, IPletherOracle.OrderExecutionRequest(f.commitTime, 1, CfdTypes.Side.LONG, false, true)
        );
        assertTrue(ok);
        assertFalse(expected.oracleFrozen);
        assertTrue(vm.revertToState(checkpoint));
    }

    function _expectedFrozen(
        uint64 commit,
        bytes[] memory data
    ) internal returns (IPletherOracle.PriceSnapshot memory expected) {
        uint256 checkpoint = vm.snapshotState();
        bool ok;
        (ok, expected) = pletherOracle.updateOrderExecutionPrice{value: IPyth(REAL_PYTH).getUpdateFee(data)}(
            address(this),
            data,
            IPletherOracle.OrderExecutionRequest(commit, type(uint256).max, CfdTypes.Side.LONG, true, true)
        );
        assertTrue(ok);
        assertTrue(expected.oracleFrozen);
        assertTrue(vm.revertToState(checkpoint));
    }

    function _parseDeadline(
        uint64 commit
    ) internal view returns (uint64) {
        uint256 deadline = uint256(commit) + pletherOracle.orderSettlementWindow();
        uint256 timestamp = vm.getBlockTimestamp();
        return uint64(deadline < timestamp ? deadline : timestamp);
    }

    function _expectHistoricalParse(
        uint64 commit,
        bytes[] memory data,
        uint256 q
    ) internal {
        vm.expectCall(
            REAL_PYTH,
            q,
            abi.encodeCall(
                IPyth.parsePriceFeedUpdatesUnique, (data, scenarioFeedIds, commit + 1, _parseDeadline(commit))
            ),
            1
        );
    }

    function _expectStorageUpdates(
        bytes[] memory data,
        uint256 q,
        uint64 count
    ) internal {
        vm.expectCall(REAL_PYTH, q, abi.encodeCall(IPyth.updatePriceFeeds, (data)), count);
    }

    function _assertExecutedReceipt(
        uint64 id,
        address account,
        IPletherOracle.PriceSnapshot memory expected,
        bool close
    ) internal {
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), id);
        assertEq(uint256(receipt.status), uint256(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint256(receipt.reason), uint256(OrderV3Types.TerminalReason.Executed));
        assertEq(receipt.account, account);
        assertEq(receipt.executionPrice, expected.price);
        assertEq(receipt.oraclePublishTime, expected.publishTime);
        assertEq(uint256(receipt.priceSource), uint256(OrderV3Types.PriceSource.OracleExecution));
        assertTrue(receipt.receiptHash != bytes32(0));
        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(account);
        assertEq(size, close ? 0 : SCENARIO_SIZE);
        if (!close) {
            assertEq(entryPrice, expected.price);
        }
    }

    function _assertStoredTimes(
        uint256[] memory expected
    ) internal view {
        for (uint256 i; i < 6; ++i) {
            assertEq(IPyth(REAL_PYTH).getPriceUnsafe(scenarioFeedIds[i]).publishTime, expected[i]);
        }
    }

    function _storedTimes() internal view returns (uint256[] memory times) {
        times = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            times[i] = IPyth(REAL_PYTH).getPriceUnsafe(scenarioFeedIds[i]).publishTime;
        }
    }

    function _setOrderEvidence(
        ScenarioEvidence memory e,
        uint64 first,
        uint256 count
    ) internal view {
        e.lifecycleStatuses = new uint256[](count);
        e.orderIds = new uint256[](count);
        e.orderCommitTimes = new uint256[](count);
        e.executionDeadlines = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            uint64 id = first + uint64(i);
            OrderV3Types.OrderTiming memory timing = router.lifecycleBook().orderTiming(id);
            e.lifecycleStatuses[i] = uint256(router.lifecycleBook().lifecycleStatus(id));
            e.orderIds[i] = id;
            e.orderCommitTimes[i] = timing.commitTimestamp;
            e.executionDeadlines[i] = timing.executionDeadline;
            assertLe(timing.commitTimestamp, vm.getBlockTimestamp());
            assertLe(vm.getBlockTimestamp(), timing.executionDeadline, "scenario order expired before execution");
        }
    }

    function _newEvidence(
        string memory scenario,
        bytes[] memory data,
        uint256 fundingMultiplier,
        uint256[] memory requiredTimes
    ) internal view returns (ScenarioEvidence memory e) {
        e.scenarioId = scenario;
        e.quoteWei = IPyth(REAL_PYTH).getUpdateFee(data);
        assertEq(pletherOracle.getOrderExecutionFee(data), pletherOracle.isOracleFrozen() ? e.quoteWei : 2 * e.quoteWei);
        // Authentic Sepolia Pyth can quote zero. Preserve that policy and still exercise positive Router refunds.
        e.surplusWei = SCENARIO_REFUND_SURPLUS;
        e.fundedWei = fundingMultiplier * e.quoteWei + e.surplusWei;
        e.requiredPublishTimes = requiredTimes;
    }

    function _emitEvidence(
        ScenarioEvidence memory e,
        bytes[] memory data
    ) internal {
        assertTrue(scenarioIsolationVerified, "transaction isolation must be measured");
        assertGt(e.callGas, 0);
        assertLt(e.callGas, SCENARIO_GAS_CAP, "Router call must fit the unchanged keeper cap");
        uint256[] memory stored = _storedTimes();
        for (uint256 i; i < 6; ++i) {
            assertGe(stored[i], e.requiredPublishTimes[i], "missing stored component coverage");
        }
        assertEq(
            e.fundedWei,
            e.pythFeeDeltaWei + e.immediateRefundWei + e.oracleDeferredWei + e.routerDeferredWei + e.oracleClaimedWei
                + e.routerClaimedWei,
            "execution funding must be conserved exactly once"
        );
        assertEq(address(router).balance, 0);
        assertEq(address(pletherOracle).balance, e.oracleDeferredWei);
        assertEq(address(routerAdmin).balance, e.routerDeferredWei);
        uint256 payloadBytes;
        for (uint256 i; i < data.length; ++i) {
            payloadBytes += data[i].length;
        }
        string memory key = string.concat("oracle-sync-", e.scenarioId);
        vm.serializeUint(key, "schemaVersion", 1);
        vm.serializeString(key, "scenarioId", e.scenarioId);
        vm.serializeString(key, "outcome", e.outcome);
        vm.serializeString(key, "isolationMode", "transaction");
        vm.serializeBool(key, "isolationVerified", scenarioIsolationVerified);
        vm.serializeUint(key, "payloadBytes", payloadBytes);
        vm.serializeUint(key, "callGas", e.callGas);
        vm.serializeUint(key, "gasCap", SCENARIO_GAS_CAP);
        vm.serializeUint(key, "quoteWei", e.quoteWei);
        vm.serializeUint(key, "fundedWei", e.fundedWei);
        vm.serializeUint(key, "surplusWei", e.surplusWei);
        vm.serializeUint(key, "pythFeeDeltaWei", e.pythFeeDeltaWei);
        vm.serializeUint(key, "immediateRefundWei", e.immediateRefundWei);
        vm.serializeUint(key, "oracleCreditedWei", e.oracleCreditedWei);
        vm.serializeUint(key, "routerCreditedWei", e.routerCreditedWei);
        vm.serializeUint(key, "oracleDeferredWei", e.oracleDeferredWei);
        vm.serializeUint(key, "routerDeferredWei", e.routerDeferredWei);
        vm.serializeUint(key, "oracleClaimedWei", e.oracleClaimedWei);
        vm.serializeUint(key, "routerClaimedWei", e.routerClaimedWei);
        vm.serializeUint(key, "terminalCount", e.terminalCount);
        vm.serializeUint(key, "expectedParseCalls", e.expectedParseCalls);
        vm.serializeUint(key, "expectedUpdateCalls", e.expectedUpdateCalls);
        vm.serializeBool(key, "liveReadChecked", e.liveReadChecked);
        vm.serializeBool(key, "oracleRefundExercised", e.oracleRefundExercised);
        vm.serializeBool(key, "routerRefundExercised", e.routerRefundExercised);
        vm.serializeUint(key, "markTime", engine.lastMarkTime());
        vm.serializeUint(key, "markPrice", engine.lastMarkPrice());
        vm.serializeUint(key, "executionTimestamp", vm.getBlockTimestamp());
        vm.serializeUint(key, "executionBlock", vm.getBlockNumber());
        vm.serializeUint(key, "orderIds", e.orderIds);
        vm.serializeUint(key, "orderCommitTimes", e.orderCommitTimes);
        vm.serializeUint(key, "executionDeadlines", e.executionDeadlines);
        vm.serializeUint(key, "storedPublishTimes", stored);
        vm.serializeUint(key, "requiredPublishTimes", e.requiredPublishTimes);
        string memory encoded = vm.serializeUint(key, "lifecycleStatuses", e.lifecycleStatuses);
        emit log_named_string("oracle-sync-evidence", encoded);
    }

}

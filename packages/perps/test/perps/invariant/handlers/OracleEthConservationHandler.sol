// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Spends only its setup-funded ETH. Trader collateral and keeper USDC credits never enter this actor's budget.
contract OracleEthKeeper {

    enum Mode {
        Accept,
        Reject,
        Burn,
        Reenter,
        CrossLedger
    }

    event ReentryAttempt(address target, bool succeeded, bytes4 failureSelector);
    event CrossLedgerClaim(bool fromOracle, bool succeeded);

    address public immutable handler;
    address public immutable router;
    address public immutable oracle;
    address public immutable admin;
    Mode public oracleMode;
    Mode public routerMode;
    Mode public claimMode;
    bool private claiming;
    bool private claimingOtherLedger;

    constructor(
        address router_,
        address oracle_,
        address admin_
    ) {
        handler = msg.sender;
        router = router_;
        oracle = oracle_;
        admin = admin_;
    }

    modifier onlyHandler() {
        require(msg.sender == handler, "handler only");
        _;
    }

    function configure(
        Mode oracleMode_,
        Mode routerMode_,
        Mode claimMode_
    ) external onlyHandler {
        oracleMode = oracleMode_;
        routerMode = routerMode_;
        claimMode = claimMode_;
    }

    function execute(
        bytes calldata data,
        uint256 value
    ) external onlyHandler returns (bool, bytes memory) {
        return router.call{value: value}(data);
    }

    function claim(
        bool fromOracle
    ) external onlyHandler returns (bool success) {
        claiming = true;
        bytes memory data = fromOracle
            ? abi.encodeCall(IPletherOracle.claimEthRefund, ())
            : abi.encodeCall(OrderRouterAdmin.claimBalance, (true));
        // A deliberately burning claim recipient must not consume the handler's assertion/cleanup gas.
        (success,) = (fromOracle ? oracle : admin).call{gas: 150_000}(data);
        claiming = false;
    }

    receive() external payable {
        require(msg.sender == router || msg.sender == oracle || msg.sender == admin, "unexpected ETH sender");
        Mode mode = claiming ? claimMode : msg.sender == oracle ? oracleMode : routerMode;
        if (mode == Mode.Reject) {
            revert("refund rejected");
        }
        if (mode == Mode.Burn) {
            assembly ("memory-safe") {
                for {} 1 {} { pop(gas()) }
            }
        }
        if (mode == Mode.Reenter) {
            bytes memory data;
            if (msg.sender == oracle) {
                data = abi.encodeCall(IPletherOracle.claimEthRefund, ());
            } else if (msg.sender == admin) {
                data = abi.encodeCall(OrderRouterAdmin.claimBalance, (true));
            } else {
                data = abi.encodeCall(IPerpsKeeper.executeOrderBatch, (uint64(0), new bytes[](0)));
            }
            (bool success, bytes memory returned) = msg.sender.call{gas: 10_000}(data);
            bytes4 failureSelector;
            if (returned.length >= 4) {
                assembly ("memory-safe") {
                    failureSelector := mload(add(returned, 0x20))
                }
            }
            // Logging avoids a cold SSTORE consuming the bounded immediate-refund stipend.
            emit ReentryAttempt(msg.sender, success, failureSelector);
        }
        if (mode == Mode.CrossLedger && !claimingOtherLedger) {
            claimingOtherLedger = true;
            bool fromOracle = msg.sender == admin;
            bytes memory data = fromOracle
                ? abi.encodeCall(IPletherOracle.claimEthRefund, ())
                : abi.encodeCall(OrderRouterAdmin.claimBalance, (true));
            (bool success,) = (fromOracle ? oracle : admin).call{gas: 80_000}(data);
            claimingOtherLedger = false;
            emit CrossLedgerClaim(fromOracle, success);
        }
    }

}

/// @dev Models ETH from scenario inputs, not snapshot.updateFee, observed fee balances, or observed call counts.
contract OracleEthConservationHandler is Test {

    uint256 public constant MAX_FEE = 1 gwei;
    uint256 private constant PRICE = 100_000_000;
    uint256 private constant SIZE = 2000e18;
    uint256 private constant MARGIN = 500e6;
    bytes32 private constant REENTRY_EVENT = keccak256("ReentryAttempt(address,bool,bytes4)");
    bytes32 private constant CROSS_LEDGER_EVENT = keccak256("CrossLedgerClaim(bool,bool)");

    LegacyOrderRouterHarness public immutable router;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    PletherOracle public immutable oracle;
    OrderRouterAdmin public immutable admin;
    MockPyth public immutable pyth;
    MockUSDC public immutable usdc;
    address public immutable owner;
    OracleEthKeeper[3] public actors;
    bytes32[] private feeds;

    uint256[3] public supplied;
    uint256[3] public immediate;
    uint256[3] public claimed;
    uint256[3] public oracleOwed;
    uint256[3] public adminOwed;
    uint256[3] private initialActorBalances;
    uint256[4] private initialProtocolBalances;
    uint256 public expectedPythFees;
    uint256 public expectedParses;
    uint256 public expectedUpdates;
    uint256 private initialParses;
    uint256 private initialUpdates;
    uint256 private initialTotal;
    bool private initialized;

    uint256 public violation;
    bytes public unexpectedRevertData;
    uint256[11] public scenarios;
    uint256[5] public rollbackCases;
    uint256 public outerReverts;
    uint256 public caughtItemFailures;
    uint256 public reentryAttempts;
    uint256 public successfulOracleClaims;
    uint256 public successfulAdminClaims;
    uint256 public failedClaims;
    uint256 public executedRoundTrips;
    uint256 public executedSharedBatches;
    uint256 public executedMixedBatches;
    uint256 public executedUnavailablePrefixes;
    uint256[5] public executedRollbackPrefixes;
    uint256 public closedBatchPositions;
    uint256 public zeroFeeSurplusRefunds;
    uint256 public crossLedgerClaims;
    uint256 private expectedCrossAttempts;
    bool private expectedCrossSuccess;
    bool private expectedCrossFromOracle;

    uint64[2] private orderIds;
    address[2] private traders;
    uint64[2] private commits;
    uint256 private orderCount;
    uint256 private traderNonce;
    uint256 private activeActor;
    uint256 private activeFee;
    uint256 private excess;
    OracleEthKeeper.Mode private activeOracleMode;
    OracleEthKeeper.Mode private activeRouterMode;
    bool private activeFrozen;

    struct Expectation {
        uint256 parses;
        uint256 updates;
        uint256 unavailableFunding;
        uint32 terminals;
        OrderV3Types.PendingReason stop;
        bool reverts;
        bytes32 revertDataHash;
        uint64 rollbackPrefix;
    }

    constructor(
        LegacyOrderRouterHarness router_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        PletherOracle oracle_,
        OrderRouterAdmin admin_,
        MockPyth pyth_,
        MockUSDC usdc_,
        bytes32[] memory feeds_
    ) {
        router = router_;
        engine = engine_;
        clearinghouse = clearinghouse_;
        oracle = oracle_;
        admin = admin_;
        pyth = pyth_;
        usdc = usdc_;
        feeds = feeds_;
        owner = msg.sender;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = new OracleEthKeeper(address(router_), address(oracle_), address(admin_));
        }
    }

    function initialize() external {
        require(msg.sender == owner && !initialized, "initialize once");
        initialized = true;
        for (uint256 i; i < actors.length; ++i) {
            initialActorBalances[i] = address(actors[i]).balance;
            require(initialActorBalances[i] == 1 ether, "fixed actor funding");
            initialTotal += initialActorBalances[i];
        }
        initialProtocolBalances =
            [address(pyth).balance, address(oracle).balance, address(admin).balance, address(router).balance];
        for (uint256 i; i < 4; ++i) {
            initialTotal += initialProtocolBalances[i];
        }
        initialParses = pyth.parseUniqueCallCount();
        initialUpdates = pyth.updatePriceFeedsCallCount();
        _audit();
    }

    /// @notice Bounded scenarios keep FIFO live while randomizing fee, actor, excess, and both refund dispositions.
    function exercise(
        uint8 scenarioSeed,
        uint8 actorSeed,
        uint256 feeSeed,
        uint256 excessSeed,
        uint8 modeSeed
    ) external {
        if (violation != 0) {
            return;
        }
        // Unexpected handler/protocol reverts must fail the invariant, not become discarded fuzz actions.
        try this.exerciseScenario(scenarioSeed, actorSeed, feeSeed, excessSeed, modeSeed) {}
        catch (bytes memory reason) {
            unexpectedRevertData = reason;
            _fail(30);
        }
    }

    function exerciseScenario(
        uint8 scenarioSeed,
        uint8 actorSeed,
        uint256 feeSeed,
        uint256 excessSeed,
        uint8 modeSeed
    ) external {
        require(msg.sender == address(this), "self only");
        if (violation != 0) {
            return;
        }
        uint256 scenario = scenarioSeed % 11;
        activeActor = actorSeed % actors.length;
        activeFee = scenario == 9 ? 0 : feeSeed % (MAX_FEE + 1);
        // The underfunded case must have a strictly positive shortfall.
        if (scenario == 6 && excessSeed % 5 == 1 && activeFee == 0) {
            activeFee = 1;
        }
        // Surplus is independent of q, so even a zero-fee Pyth quote must return positive excess correctly.
        excess = (excessSeed % 6) * MAX_FEE;
        activeOracleMode = OracleEthKeeper.Mode(modeSeed % 4);
        activeRouterMode = OracleEthKeeper.Mode((modeSeed / 4) % 4);
        actors[activeActor].configure(activeOracleMode, activeRouterMode, OracleEthKeeper.Mode.Accept);
        pyth.setFee(activeFee);
        pyth.setUpdateFailure(false, false, bytes32(0));
        pyth.setFailUpdateAtCall(0);
        _policy(false, false);
        orderCount = 0;
        if (router.nextExecuteId() != 0 && router.nextCommitId() != 1) {
            _fail(1);
            return;
        }

        if (scenario == 0 || scenario == 3 || scenario == 10) {
            _roundTrip(scenario == 3 ? 1 : scenario == 10 ? 2 : 0);
        } else if (scenario == 1 || scenario == 2 || scenario == 9) {
            _successfulBatch(scenario == 2);
        } else if (scenario == 4 || scenario == 5) {
            _unavailable(scenario == 5);
        } else if (scenario == 6) {
            _outerFailure(excessSeed % 5);
        } else if (scenario == 7) {
            _caughtFailure();
        } else {
            _cleanup();
        }
        vm.clearMockedCalls();
        pyth.setUpdateFailure(false, false, bytes32(0));
        pyth.setFailUpdateAtCall(0);
        if (violation == 0 && router.nextExecuteId() != 0) {
            _fail(2);
        }
        if (violation == 0) {
            ++scenarios[scenario];
            if (scenario == 9 && excess != 0) {
                ++zeroFeeSurplusRefunds;
            }
        }
        _audit();
    }

    function claim(
        uint8 actorSeed,
        bool fromOracle,
        uint8 modeSeed
    ) external {
        if (violation != 0) {
            return;
        }
        uint256 actorIndex = actorSeed % actors.length;
        OracleEthKeeper.Mode mode = OracleEthKeeper.Mode(modeSeed % 5);
        actors[actorIndex].configure(OracleEthKeeper.Mode.Accept, OracleEthKeeper.Mode.Accept, mode);
        uint256 amount = fromOracle ? oracleOwed[actorIndex] : adminOwed[actorIndex];
        bool expectedSuccess = amount != 0 && _accepts(mode);
        uint256 otherAmount = fromOracle ? adminOwed[actorIndex] : oracleOwed[actorIndex];
        bool cross = expectedSuccess && mode == OracleEthKeeper.Mode.CrossLedger;
        expectedCrossAttempts = cross ? 1 : 0;
        expectedCrossSuccess = cross && otherAmount != 0;
        expectedCrossFromOracle = !fromOracle;
        bytes32 beforeEth = _ethHash();
        vm.recordLogs();
        bool success = actors[actorIndex].claim(fromOracle);
        _checkReentryLogs(actorIndex, expectedSuccess && mode == OracleEthKeeper.Mode.Reenter ? 1 : 0);
        if (success != expectedSuccess) {
            _fail(3);
        }
        if (success && expectedSuccess) {
            claimed[actorIndex] += amount;
            if (cross) {
                claimed[actorIndex] += otherAmount;
                oracleOwed[actorIndex] = 0;
                adminOwed[actorIndex] = 0;
            }
            if (fromOracle) {
                oracleOwed[actorIndex] = 0;
                ++successfulOracleClaims;
            } else {
                adminOwed[actorIndex] = 0;
                ++successfulAdminClaims;
            }
        } else {
            ++failedClaims;
            if (_ethHash() != beforeEth) {
                _fail(4);
            }
        }
        _audit();
    }

    function _roundTrip(
        uint256 closeRegime
    ) private {
        _commit(false, true, address(0));
        _advance(commits[0] + 1);
        if (!_single(orderIds[0], _data(true), 2 * activeFee + excess, _expected(1, 1, 0, 1))) {
            return;
        }
        if (router.lifecycleBook().lifecycleStatus(orderIds[0]) != OrderV3Types.LifecycleStatus.Executed) {
            _fail(5);
            return;
        }
        address trader = traders[0];
        orderCount = 0;
        _commit(true, true, trader);
        _advance(commits[0] + 1);
        _policy(closeRegime == 1, closeRegime != 0);
        uint256 parses = closeRegime == 1 ? 0 : 1;
        uint256 funding = (parses + 1) * activeFee;
        if (!_single(orderIds[0], _data(true), funding + excess, _expected(parses, 1, 0, 1))) {
            return;
        }
        (uint256 size,,,,,,) = engine.positions(trader);
        if (size != 0 || router.lifecycleBook().lifecycleStatus(orderIds[0]) != OrderV3Types.LifecycleStatus.Executed) {
            _fail(6);
        } else {
            ++executedRoundTrips;
        }
    }

    function _unavailable(
        bool afterPrefix
    ) private {
        if (afterPrefix) {
            _pair(true, true, false);
        } else {
            _commit(false, false, address(0));
            _advance(commits[0] + 1);
        }
        bytes[] memory unavailableData = afterPrefix ? _data(false) : _payload(commits[0] + 2, commits[0] + 1);
        uint256 prefix = afterPrefix ? 1 : 0;
        Expectation memory expectation = _expected(prefix, prefix, 2 * activeFee, uint32(prefix));
        expectation.stop = OrderV3Types.PendingReason.HistoricalPriceUnavailable;
        if (!_batch(unavailableData, (2 * (prefix + 1) * activeFee) + excess, expectation)) {
            return;
        }
        if (router.nextExecuteId() != orderIds[afterPrefix ? 1 : 0]) {
            _fail(7);
        }
        address prefixTrader = traders[0];
        if (afterPrefix) {
            if (!_executedOpen(0)) {
                return;
            }
            ++executedUnavailablePrefixes;
        }
        // A fresh Router call has an empty memory cache and pays for its own new resolution.
        if (!_batch(_data(true), 2 * activeFee, _expected(1, 1, 0, 1))) {
            return;
        }
        _requireFailed(afterPrefix ? 1 : 0);
        if (afterPrefix) {
            _closeBatchPosition(prefixTrader);
        }
    }

    function _outerFailure(
        uint256 kind
    ) private {
        bool pair = kind == 1 || kind == 2 || kind == 4;
        if (pair) {
            _pair(true, true, false);
        } else {
            _commit(false, false, address(0));
            _advance(commits[0] + 1);
        }
        bytes[] memory data = kind == 0 ? _payload(commits[0] + 2, commits[0] + 1) : _data(true);
        uint256 value = (pair ? 4 : 2) * activeFee + excess;
        if (kind == 1) {
            value = 3 * activeFee;
        }
        if (kind == 2) {
            pyth.setFailUpdateAtCall(pyth.updatePriceFeedsCallCount() + 2);
        }
        if (kind == 3) {
            pyth.setUpdateFailure(false, true, bytes32(0));
        }
        if (kind == 4) {
            pyth.setUpdateFailure(false, false, feeds[feeds.length - 1]);
        }
        Expectation memory expectation;
        expectation.reverts = true;
        expectation.revertDataHash = _expectedOuterRevert(kind);
        // Foundry records logs even when the outer call rolls them back. Require a real executed receipt before
        // the later failure, then independently require the tracked pre-call state and ETH to be restored.
        expectation.rollbackPrefix = pair ? orderIds[0] : 0;
        bool matched = kind == 0 ? _single(orderIds[0], data, value, expectation) : _batch(data, value, expectation);
        pyth.setUpdateFailure(false, false, bytes32(0));
        pyth.setFailUpdateAtCall(0);
        if (!matched) {
            return;
        }
        ++rollbackCases[kind];
        if (pair) {
            ++executedRollbackPrefixes[kind];
        }
        uint256 baskets = pair ? 2 : 1;
        if (!_batch(_data(true), 2 * baskets * activeFee, _expected(baskets, baskets, 0, uint32(orderCount)))) {
            return;
        }
        _requireFailed(pair ? 1 : 0);
        if (pair && _executedOpen(0)) {
            _closeBatchPosition(traders[0]);
        }
    }

    function _caughtFailure() private {
        _pair(false, false, true);
        bytes32 itemBefore = _itemHash(1);
        // Match finalize's first static tuple member (orderId), retaining the first item's real receipt path.
        vm.mockCallRevert(
            address(router.lifecycleBook()),
            abi.encodePacked(IOrderLifecycleBook.finalize.selector, bytes32(uint256(orderIds[1]))),
            hex"12345678"
        );
        Expectation memory expectation = _expected(1, 1, 0, 1);
        expectation.stop = OrderV3Types.PendingReason.ReceiptFailure;
        bool matched = _batch(_data(true), 2 * activeFee + excess, expectation);
        vm.clearMockedCalls();
        _policy(false, false);
        if (!matched) {
            return;
        }
        if (_itemHash(1) != itemBefore || router.nextExecuteId() != orderIds[1]) {
            _fail(8);
        }
        if (router.lifecycleBook().lifecycleStatus(orderIds[0]) != OrderV3Types.LifecycleStatus.Failed) {
            _fail(9);
        }
        ++caughtItemFailures;
        // Retrying the valid second order executes it, so close its position within this scenario.
        if (!_batch(_data(true), 2 * activeFee, _expected(1, 1, 0, 1))) {
            return;
        }
        if (_executedOpen(1)) {
            _closeBatchPosition(traders[1]);
        }
    }

    function _cleanup() private {
        _commit(false, false, address(0));
        vm.prank(owner);
        admin.pause();
        _batch(new bytes[](0), activeFee + excess, _expected(0, 0, 0, 1));
        vm.prank(owner);
        admin.unpause();
    }

    function _pair(
        bool mixed,
        bool firstValid,
        bool secondValid
    ) private {
        _commit(false, firstValid, address(0));
        if (mixed) {
            _advance(commits[0] + 2);
        }
        _commit(false, secondValid, address(0));
        _advance(commits[1] + 1);
    }

    function _successfulBatch(
        bool mixed
    ) private {
        _pair(mixed, true, true);
        uint256 baskets = mixed ? 2 : 1;
        if (!_batch(_data(true), 2 * baskets * activeFee + excess, _expected(baskets, baskets, 0, 2))) {
            return;
        }
        if (!_executedOpen(0) || !_executedOpen(1)) {
            return;
        }
        if (mixed) {
            ++executedMixedBatches;
        } else {
            ++executedSharedBatches;
        }
        address firstTrader = traders[0];
        address secondTrader = traders[1];
        if (_closeBatchPosition(firstTrader)) {
            _closeBatchPosition(secondTrader);
        }
    }

    function _executedOpen(
        uint256 index
    ) private returns (bool) {
        (uint256 size,,,,,,) = engine.positions(traders[index]);
        if (
            size != SIZE
                || router.lifecycleBook().lifecycleStatus(orderIds[index]) != OrderV3Types.LifecycleStatus.Executed
        ) {
            _fail(31);
            return false;
        }
        return true;
    }

    function _requireFailed(
        uint256 index
    ) private {
        if (router.lifecycleBook().lifecycleStatus(orderIds[index]) != OrderV3Types.LifecycleStatus.Failed) {
            _fail(32);
        }
    }

    function _closeBatchPosition(
        address trader
    ) private returns (bool) {
        orderCount = 0;
        _commit(true, true, trader);
        _advance(commits[0] + 1);
        if (!_single(orderIds[0], _data(true), 2 * activeFee, _expected(1, 1, 0, 1))) {
            return false;
        }
        (uint256 size,,,,,,) = engine.positions(trader);
        if (size != 0 || router.lifecycleBook().lifecycleStatus(orderIds[0]) != OrderV3Types.LifecycleStatus.Executed) {
            _fail(33);
            return false;
        }
        ++closedBatchPositions;
        return true;
    }

    function _expectedOuterRevert(
        uint256 kind
    ) private view returns (bytes32) {
        bytes memory reason;
        if (kind == 0) {
            reason = abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StalePrice.selector,
                IPletherOracle.PriceMode.OrderExecution,
                bytes32(0),
                uint256(commits[0] + 1),
                oracle.orderExecutionStalenessLimit(),
                uint256(commits[0] + 1)
            );
        } else if (kind == 1) {
            reason = abi.encodeWithSelector(
                IPletherOracle.PletherOracle__InsufficientFee.selector, 3 * activeFee, 4 * activeFee
            );
        } else if (kind == 2) {
            reason = abi.encodeWithSignature("Error(string)", "storage update failed");
        } else {
            uint256 index = kind == 3 ? 0 : 1;
            reason = abi.encodeWithSelector(
                IPletherOracle.PletherOracle__StoredFeedBehind.selector,
                feeds[kind == 3 ? 0 : feeds.length - 1],
                uint256(commits[index]),
                uint256(commits[index] + 1)
            );
        }
        return keccak256(reason);
    }

    function _commit(
        bool close,
        bool valid,
        address existingTrader
    ) private {
        // Read through Vm because viaIR may reuse block.timestamp across earlier vm.warp calls.
        uint64 timestamp = uint64(vm.getBlockTimestamp());
        pyth.setAllPrices(feeds, int64(uint64(PRICE)), -8, timestamp);
        address trader = existingTrader;
        if (!close) {
            trader = address(uint160(0xE70000 + ++traderNonce));
            usdc.mint(trader, 2000e6);
            vm.startPrank(trader);
            usdc.approve(address(clearinghouse), 2000e6);
            clearinghouse.deposit(trader, 2000e6);
            vm.stopPrank();
        }
        vm.prank(trader);
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, SIZE, close ? 0 : MARGIN, valid ? 0 : 110_000_000, close);
        orderIds[orderCount] = id;
        traders[orderCount] = trader;
        commits[orderCount] = timestamp;
        ++orderCount;
    }

    function _data(
        bool includeSecond
    ) private view returns (bytes[] memory data) {
        bool mixed = orderCount == 2 && commits[0] != commits[1] && includeSecond;
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](feeds.length * (mixed ? 2 : 1));
        for (uint256 i; i < feeds.length; ++i) {
            updates[i] = _feed(feeds[i], commits[0] + 1, commits[0]);
            if (mixed) {
                updates[feeds.length + i] = _feed(feeds[i], commits[1] + 1, commits[1]);
            }
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _payload(
        uint64 tick,
        uint64 previous
    ) private view returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](feeds.length);
        for (uint256 i; i < feeds.length; ++i) {
            updates[i] = _feed(feeds[i], tick, previous);
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _feed(
        bytes32 id,
        uint64 tick,
        uint64 previous
    ) private pure returns (MockPyth.FeedUpdate memory) {
        return MockPyth.FeedUpdate(id, MockPyth.MockPrice(int64(uint64(PRICE)), 0, -8, tick, previous));
    }

    function _expected(
        uint256 parses,
        uint256 updates,
        uint256 unavailableFunding,
        uint32 terminals
    ) private pure returns (Expectation memory e) {
        e.parses = parses;
        e.updates = updates;
        e.unavailableFunding = unavailableFunding;
        e.terminals = terminals;
    }

    function _batch(
        bytes[] memory data,
        uint256 value,
        Expectation memory e
    ) private returns (bool) {
        _checkQuote(data);
        return _run(abi.encodeCall(IPerpsKeeper.executeOrderBatch, (orderIds[orderCount - 1], data)), value, e, true);
    }

    function _single(
        uint64 id,
        bytes[] memory data,
        uint256 value,
        Expectation memory e
    ) private returns (bool) {
        _checkQuote(data);
        return _run(abi.encodeCall(IPerpsKeeper.executeOrder, (id, data)), value, e, false);
    }

    function _checkQuote(
        bytes[] memory data
    ) private {
        if (data.length != 0 && oracle.getOrderExecutionFee(data) != activeFee * (activeFrozen ? 1 : 2)) {
            _fail(16);
        }
    }

    function _run(
        bytes memory callData,
        uint256 value,
        Expectation memory e,
        bool batch
    ) private returns (bool) {
        if (violation != 0) {
            return false;
        }
        bytes32 beforeEth = _ethHash();
        bytes32 beforeState = _stateHash();
        vm.recordLogs();
        (bool success, bytes memory returned) = actors[activeActor].execute(callData, value);
        if (success == e.reverts) {
            unexpectedRevertData = returned;
            _checkReentryLogs(activeActor, 0);
            _fail(10);
            return false;
        }
        if (e.reverts) {
            Vm.Log[] memory logs = _checkReentryLogs(activeActor, 0);
            if (keccak256(returned) != e.revertDataHash) {
                unexpectedRevertData = returned;
                _fail(34);
            }
            if (e.rollbackPrefix != 0 && !_recordedExecutedPrefix(logs, e.rollbackPrefix)) {
                _fail(35);
            }
            if (_ethHash() != beforeEth || _stateHash() != beforeState) {
                _fail(11);
            }
            ++outerReverts;
            _audit();
            return violation == 0;
        }
        uint256 fees = (e.parses + e.updates) * activeFee;
        uint256 routerRefund = value - fees - e.unavailableFunding;
        supplied[activeActor] += value;
        expectedPythFees += fees;
        expectedParses += e.parses;
        expectedUpdates += e.updates;
        _refundModel(e.unavailableFunding, true);
        _refundModel(routerRefund, false);
        uint256 attempts = (e.unavailableFunding != 0 && activeOracleMode == OracleEthKeeper.Mode.Reenter ? 1 : 0)
            + (routerRefund != 0 && activeRouterMode == OracleEthKeeper.Mode.Reenter ? 1 : 0);
        _checkReentryLogs(activeActor, attempts);
        if (returned.length != (batch ? 96 : 160)) {
            _fail(17);
            return false;
        }
        if (batch) {
            OrderV3Types.BatchResult memory result = abi.decode(returned, (OrderV3Types.BatchResult));
            if (result.terminalCount != e.terminals || result.stopReason != e.stop) {
                _fail(12);
            }
        } else {
            OrderV3Types.ExecutionResult memory result = abi.decode(returned, (OrderV3Types.ExecutionResult));
            if (result.status == OrderV3Types.LifecycleStatus.Pending) {
                _fail(13);
            }
        }
        _audit();
        return violation == 0;
    }

    function _refundModel(
        uint256 amount,
        bool fromOracle
    ) private {
        if (_accepts(fromOracle ? activeOracleMode : activeRouterMode)) {
            immediate[activeActor] += amount;
        } else if (fromOracle) {
            oracleOwed[activeActor] += amount;
        } else {
            adminOwed[activeActor] += amount;
        }
    }

    function _checkReentryLogs(
        uint256 actorIndex,
        uint256 expected
    ) private returns (Vm.Log[] memory logs) {
        logs = vm.getRecordedLogs();
        uint256 found;
        uint256 crossFound;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(actors[actorIndex]) && logs[i].topics.length != 0
                    && logs[i].topics[0] == REENTRY_EVENT
            ) {
                ++found;
                _checkReentryReason(logs[i].data);
            }
            if (
                logs[i].emitter == address(actors[actorIndex]) && logs[i].topics.length != 0
                    && logs[i].topics[0] == CROSS_LEDGER_EVENT
            ) {
                ++crossFound;
                (bool fromOracle, bool success) = abi.decode(logs[i].data, (bool, bool));
                if (fromOracle != expectedCrossFromOracle || success != expectedCrossSuccess) {
                    _fail(18);
                }
                if (success) {
                    ++crossLedgerClaims;
                }
            }
        }
        if (found != expected) {
            _fail(15);
        }
        reentryAttempts += found;
        if (crossFound != expectedCrossAttempts) {
            _fail(19);
        }
        expectedCrossAttempts = 0;
        expectedCrossSuccess = false;
    }

    function _recordedExecutedPrefix(
        Vm.Log[] memory logs,
        uint64 orderId
    ) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && logs[i].topics[1] == bytes32(uint256(orderId))
            ) {
                (,,, OrderV3Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                return receipt.orderId == orderId && receipt.account == traders[0]
                    && receipt.status == OrderV3Types.LifecycleStatus.Executed
                    && receipt.reason == OrderV3Types.TerminalReason.Executed && receipt.priceReachedEngine
                    && receipt.economics.postPositionSize == SIZE;
            }
        }
        return false;
    }

    function _checkReentryReason(
        bytes memory data
    ) private {
        (address target, bool success, bytes4 selector) = abi.decode(data, (address, bool, bytes4));
        bytes4 expected = target == address(admin)
            ? OrderRouterAdmin.OrderRouterAdmin__NothingToClaim.selector
            : bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        // A zero-balance/invalid-order revert must not masquerade as the Router/Oracle reentrancy guard.
        if (success || selector != expected) {
            _fail(14);
        }
    }

    function accountingError() public view returns (uint256) {
        uint256 totalSupplied;
        uint256 totalReturned;
        uint256 totalOracle;
        uint256 totalAdmin;
        uint256 actualTotal;
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(actors[i]);
            totalSupplied += supplied[i];
            totalReturned += immediate[i] + claimed[i];
            totalOracle += oracleOwed[i];
            totalAdmin += adminOwed[i];
            actualTotal += actor.balance;
            if (actor.balance + supplied[i] != initialActorBalances[i] + immediate[i] + claimed[i]) {
                return 20;
            }
            if (oracle.claimableEth(actor) != oracleOwed[i] || admin.claimableEth(actor) != adminOwed[i]) {
                return 21;
            }
        }
        if (totalSupplied != expectedPythFees + totalReturned + totalOracle + totalAdmin) {
            return 22;
        }
        if (address(pyth).balance != initialProtocolBalances[0] + expectedPythFees) {
            return 23;
        }
        if (address(oracle).balance != initialProtocolBalances[1] + totalOracle) {
            return 24;
        }
        if (address(admin).balance != initialProtocolBalances[2] + totalAdmin) {
            return 25;
        }
        if (address(router).balance != initialProtocolBalances[3]) {
            return 26;
        }
        if (pyth.parseUniqueCallCount() != initialParses + expectedParses) {
            return 27;
        }
        if (pyth.updatePriceFeedsCallCount() != initialUpdates + expectedUpdates) {
            return 28;
        }
        actualTotal += address(pyth).balance + address(oracle).balance + address(admin).balance
        + address(router).balance;
        if (actualTotal != initialTotal) {
            return 29;
        }
        return 0;
    }

    function _ethHash() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(address(router).balance, address(oracle).balance, address(admin).balance, address(pyth).balance)
        );
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(actors[i]);
            digest = keccak256(abi.encode(digest, actor.balance, oracle.claimableEth(actor), admin.claimableEth(actor)));
        }
    }

    function _stateHash() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                engine.lastMarkTime(),
                engine.lastMarkPrice(),
                router.nextExecuteId(),
                router.nextCommitId(),
                pyth.parseUniqueCallCount(),
                pyth.updatePriceFeedsCallCount()
            )
        );
        for (uint256 i; i < feeds.length; ++i) {
            digest = keccak256(abi.encode(digest, pyth.getPriceUnsafe(feeds[i])));
        }
        for (uint256 i; i < orderCount; ++i) {
            digest = keccak256(abi.encode(digest, _itemHash(i)));
        }
        for (uint256 i; i < actors.length; ++i) {
            digest = keccak256(abi.encode(digest, clearinghouse.getAccountUsdcBuckets(address(actors[i]))));
        }
    }

    function _itemHash(
        uint256 index
    ) private view returns (bytes32) {
        (bool success, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", traders[index]));
        require(success, "position read");
        return keccak256(
            abi.encode(
                router.lifecycleBook().pendingIntent(orderIds[index]),
                router.lifecycleBook().terminalOutcome(orderIds[index]),
                clearinghouse.getOrderReservation(orderIds[index]),
                clearinghouse.getAccountUsdcBuckets(traders[index]),
                position
            )
        );
    }

    function _policy(
        bool frozen,
        bool fad
    ) private {
        activeFrozen = frozen;
        vm.mockCall(address(engine), abi.encodeWithSignature("isOracleFrozen()"), abi.encode(frozen));
        vm.mockCall(address(engine), abi.encodeWithSignature("isFadWindow()"), abi.encode(fad));
    }

    function _advance(
        uint64 timestamp
    ) private {
        vm.warp(timestamp);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _accepts(
        OracleEthKeeper.Mode mode
    ) private pure returns (bool) {
        return mode == OracleEthKeeper.Mode.Accept || mode == OracleEthKeeper.Mode.Reenter
            || mode == OracleEthKeeper.Mode.CrossLedger;
    }

    function _audit() private {
        uint256 accountingFailure = accountingError();
        if (accountingFailure != 0) {
            _fail(accountingFailure);
        }
    }

    function _fail(
        uint256 code
    ) private {
        if (violation == 0) {
            violation = code;
        }
    }

}

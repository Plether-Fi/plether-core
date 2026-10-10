// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Persistent live-oracle campaign: fresh accounts, zero VPI, bounded valid history,
///      and no liquidity withdrawals. Only independently predicted solvency failures
///      and the exact injected storage faults are admissible; pending is not success.
contract OracleSynchronizationHandler is Test {

    error UnexpectedOracleRevert(bytes actual, bytes expected);
    error ExpectedOracleRevertNotObserved();
    error UnexpectedCommitRevert(bytes actual);
    error UnexpectedCommitSuccess();
    error UnexpectedExecutionOutcome(
        uint64 id,
        OrderV3Types.LifecycleStatus status,
        OrderV3Types.TerminalReason terminal,
        OrderV3Types.PendingReason pending
    );
    error SynchronizationMismatch();
    error HandlerCheckFailed(bytes32 check);

    struct Action {
        address trader;
        CfdTypes.Side side;
        uint64 id;
        uint64 commit;
        uint64 tick;
        uint256 rawPrice;
        uint256 price;
        uint256 bounty;
        uint256 keeperBefore;
        uint256 treasuryBefore;
        uint256 poolCash;
        uint256 clearingCash;
        uint256 parses;
        uint256 writes;
        bool admitted;
    }

    struct PositionView {
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 maxProfit;
        CfdTypes.Side side;
        uint64 updated;
        int256 vpi;
    }

    LegacyOrderRouterHarness internal immutable router;
    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    MockPyth internal immutable pyth;
    MockUSDC internal immutable usdc;
    bytes32[] internal ids;
    uint256 public attempts;
    uint256 public resolutions;
    uint256 public executed;
    uint256 public plannerRejected;
    uint256 public commitRejected;
    uint256 public injectedWriteFailures;
    uint256 public injectedCoverageFailures;
    uint256 public healthyRetries;
    uint256 public ghostLongMaxProfit;
    uint256 public ghostShortMaxProfit;

    constructor(
        LegacyOrderRouterHarness r,
        CfdEngine e,
        MarginClearinghouse c,
        MockPyth p,
        MockUSDC u,
        bytes32[] memory feeds
    ) {
        router = r;
        engine = e;
        clearinghouse = c;
        pyth = p;
        usdc = u;
        ids = feeds;
        _check(feeds.length == 2, "two-feed-fixture");
    }

    function execute(
        uint64 priceSeed,
        uint8 delaySeed,
        bool skipWrite,
        bool failWrite
    ) external {
        _checkFixture();
        _check(router.globalTailOrderId() == 0, "prior-order-still-pending");
        Action memory a;
        a.trader = address(uint160(100_000 + ++attempts));
        a.id = router.nextCommitId();
        a.side = CfdTypes.Side(uint8(a.id % 2));
        a.commit = uint64(vm.getBlockTimestamp());
        a.tick = a.commit + 1 + delaySeed % 10;
        a.rawPrice = 99_000_000 + priceSeed % 2_000_001;
        // Each equal-weight component rounds separately, including odd raw prices.
        a.price = 2 * (a.rawPrice / 2);
        a.poolCash = usdc.balanceOf(address(engine.pool()));
        usdc.mint(a.trader, 2000e6);
        vm.startPrank(a.trader);
        usdc.approve(address(clearinghouse), 2000e6);
        clearinghouse.deposit(a.trader, 2000e6);
        vm.stopPrank();
        if (!_commit(a)) {
            return;
        }

        vm.warp(a.tick);
        vm.roll(vm.getBlockNumber() + 1);
        a.admitted = _admitted(a.side, a.price, a.poolCash);
        a.keeperBefore = clearinghouse.balanceUsdc(address(this));
        a.treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        a.clearingCash = usdc.balanceOf(address(clearinghouse));
        a.parses = pyth.parseUniqueCallCount();
        a.writes = pyth.updatePriceFeedsCallCount();
        bytes[] memory data = _payload(a);
        pyth.setUpdateFailure(failWrite, skipWrite, bytes32(0));
        if (failWrite || skipWrite) {
            bytes memory expected = failWrite
                ? abi.encodeWithSignature("Error(string)", "storage update failed")
                : abi.encodeWithSelector(
                    IPletherOracle.PletherOracle__StoredFeedBehind.selector,
                    ids[0],
                    pyth.getPriceUnsafe(ids[0]).publishTime,
                    uint256(a.tick)
                );
            bytes32 beforeState = _stateHash(a.trader, a.id);
            _call(a.id, data, expected);
            _check(_stateHash(a.trader, a.id) == beforeState, "oracle-fault-rollback");
            if (failWrite) {
                ++injectedWriteFailures;
            } else {
                ++injectedCoverageFailures;
            }
            pyth.setUpdateFailure(false, false, bytes32(0));
            ++healthyRetries;
        }
        // No catch or pending allowlist on the healthy retry.
        vm.recordLogs();
        OrderV3Types.ExecutionResult memory result = _call(a.id, data, "");
        _terminal(a, result, vm.getRecordedLogs());
        ++resolutions;
        // Exact-once settlement: the drained FIFO cannot pay this bounty twice.
        bytes32 settled = _stateHash(a.trader, a.id);
        _call(a.id, data, abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector));
        _check(_stateHash(a.trader, a.id) == settled, "terminal-replay-mutated");
    }

    function _commit(
        Action memory a
    ) private returns (bool) {
        uint256 mark = engine.lastMarkPrice();
        if (mark == 0) {
            mark = 1e8;
        }
        // The very first unmarked commit deliberately has no fresh-mark preview gate.
        bool rejected = engine.lastMarkTime() != 0 && !_admitted(a.side, mark, a.poolCash);
        bytes32 beforeState = _stateHash(a.trader, a.id);
        vm.prank(a.trader);
        try router.commitOrder(a.side, 2000e18, 500e6, 0, false) returns (uint64 id) {
            if (rejected) {
                revert UnexpectedCommitSuccess();
            }
            _check(id == a.id && router.nextExecuteId() == id, "committed-head");
        } catch (bytes memory reason) {
            bytes memory expected = abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)
            );
            if (!rejected || keccak256(reason) != keccak256(expected)) {
                revert UnexpectedCommitRevert(reason);
            }
            _check(_stateHash(a.trader, a.id) == beforeState, "commit-rejection-rollback");
            ++commitRejected;
            return false;
        }
        a.bounty = (20 * mark * router.openOrderExecutionBountyBps()) / 10_000;
        if (a.bounty < router.minOpenOrderExecutionBountyUsdc()) {
            a.bounty = router.minOpenOrderExecutionBountyUsdc();
        }
        if (a.bounty > router.maxOpenOrderExecutionBountyUsdc()) {
            a.bounty = router.maxOpenOrderExecutionBountyUsdc();
        }
        _check(clearinghouse.getOrderReservation(a.id).remainingAmountUsdc == 500e6, "committed-margin");
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, a.id);
        _check(
            bounty.account == a.trader && bounty.amountUsdc == a.bounty
                && bounty.state == IMarginClearinghouse.BountyReservationState.Active,
            "committed-bounty"
        );
        return true;
    }

    function _call(
        uint64 id,
        bytes[] memory data,
        bytes memory expected
    ) private returns (OrderV3Types.ExecutionResult memory result) {
        (bool ok, bytes memory returned) =
            address(router).call(abi.encodeWithSelector(router.executeOrder.selector, id, data));
        if (!ok) {
            if (expected.length == 0 || keccak256(returned) != keccak256(expected)) {
                revert UnexpectedOracleRevert(returned, expected);
            }
            return result;
        }
        if (expected.length != 0) {
            revert ExpectedOracleRevertNotObserved();
        }
        _check(returned.length == 160, "execution-result-shape");
        return abi.decode(returned, (OrderV3Types.ExecutionResult));
    }

    function _terminal(
        Action memory a,
        OrderV3Types.ExecutionResult memory result,
        Vm.Log[] memory logs
    ) private {
        OrderV3Types.LifecycleStatus status =
            a.admitted ? OrderV3Types.LifecycleStatus.Executed : OrderV3Types.LifecycleStatus.Failed;
        OrderV3Types.TerminalReason reason =
            a.admitted ? OrderV3Types.TerminalReason.Executed : OrderV3Types.TerminalReason.PlannerRejected;
        if (
            result.orderId != a.id || result.status != status || result.terminalReason != reason
                || result.pendingReason != OrderV3Types.PendingReason.None
        ) {
            revert UnexpectedExecutionOutcome(
                result.orderId, result.status, result.terminalReason, result.pendingReason
            );
        }
        _synchronized(a);
        OrderV3Types.OrderReceipt memory receipt = _receipt(a, result, logs);
        _check(
            receipt.executionMode == OrderV3Types.ExecutionMode.Live
                && receipt.priceSource == OrderV3Types.PriceSource.OracleExecution && receipt.executionPrice == a.price
                && receipt.neutralMarkPrice == a.price && receipt.oraclePublishTime == a.tick
                && receipt.priceReachedEngine == a.admitted,
            "receipt-oracle-evidence"
        );
        _check(
            receipt.bountyUsdc == a.bounty && receipt.bounty.bountyPaidUsdc == a.bounty
                && receipt.bounty.bountyEntitlementUsdc == a.bounty
                && receipt.bountyDisposition == OrderV3Types.BountyDisposition.Paid
                && receipt.bountyRecipient == address(this) && receipt.executor == address(this),
            "receipt-bounty"
        );
        if (a.admitted) {
            if (a.side == CfdTypes.Side.LONG) {
                ghostLongMaxProfit += 20 * a.price;
            } else {
                ghostShortMaxProfit += 20 * (2e8 - a.price);
            }
            ++executed;
        } else {
            bytes memory typedFailure = abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
                CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
                false
            );
            _check(
                receipt.failure.selector == ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector
                    && receipt.failure.category
                        == uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated)
                    && receipt.failure.code == uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)
                    && receipt.failure.revertDataHash == keccak256(typedFailure),
                "terminal-solvency-evidence"
            );
            ++plannerRejected;
        }
        _settled(a);
    }

    function _synchronized(
        Action memory a
    ) private view {
        if (
            pyth.parseUniqueCallCount() != a.parses + 1 || pyth.updatePriceFeedsCallCount() != a.writes + 1
                || engine.lastMarkTime() != a.tick || engine.lastMarkPrice() != a.price
        ) {
            revert SynchronizationMismatch();
        }
        for (uint256 i; i < ids.length; ++i) {
            if (
                pyth.getPriceUnsafe(ids[i]).publishTime != a.tick
                    || pyth.getPriceUnsafe(ids[i]).price != int64(uint64(a.rawPrice))
                    || pyth.getPriceUnsafe(ids[i]).conf != 0 || pyth.getPriceUnsafe(ids[i]).expo != -8
            ) {
                revert SynchronizationMismatch();
            }
        }
    }

    function _receipt(
        Action memory a,
        OrderV3Types.ExecutionResult memory result,
        Vm.Log[] memory logs
    ) private view returns (OrderV3Types.OrderReceipt memory receipt) {
        IOrderLifecycleBook book = router.lifecycleBook();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(book) || logs[i].topics.length != 4
                    || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
            ) {
                continue;
            }
            (bytes32 hash, uint64 terminalBlock, uint64 terminalTime, OrderV3Types.OrderReceipt memory candidate) =
                abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
            _check(
                candidate.orderId == a.id && candidate.account == a.trader && uint256(logs[i].topics[1]) == a.id
                    && address(uint160(uint256(logs[i].topics[2]))) == a.trader
                    && logs[i].topics[3] == candidate.clientOrderId,
                "receipt-identity"
            );
            _check(
                book.verifyReceipt(candidate, terminalTime) && hash == result.receiptHash
                    && candidate.status == result.status && candidate.reason == result.terminalReason,
                "receipt-authentication"
            );
            OrderV3Types.TerminalOutcome memory terminal = book.terminalOutcome(a.id);
            _check(
                terminal.receiptHash == hash && terminal.terminalBlock == terminalBlock && terminal.account == a.trader
                    && terminal.status == result.status && terminal.reason == result.terminalReason,
                "durable-receipt"
            );
            receipt = candidate;
            ++found;
        }
        _check(found == 1, "one-authentic-receipt");
    }

    function _settled(
        Action memory a
    ) private view {
        uint256 fee = a.admitted ? (20 * a.price * 4) / 10_000 : 0;
        _check(clearinghouse.balanceUsdc(a.trader) == 2000e6 - a.bounty - fee, "trader-custody");
        _check(clearinghouse.balanceUsdc(address(this)) == a.keeperBefore + a.bounty, "keeper-credit");
        _check(clearinghouse.balanceUsdc(engine.protocolTreasury()) == a.treasuryBefore + fee, "treasury-credit");
        _check(
            usdc.balanceOf(address(engine.pool())) == a.poolCash
                && usdc.balanceOf(address(clearinghouse)) == a.clearingCash,
            "physical-cash"
        );
        _check(
            router.nextExecuteId() == 0 && router.globalTailOrderId() == 0
                && router.lifecycleBook().pendingIntent(a.id).account == address(0),
            "terminal-queue"
        );
        _check(
            clearinghouse.getOrderReservation(a.id).status == IMarginClearinghouse.ReservationStatus.Released
                && clearinghouse.getOrderReservation(a.id).remainingAmountUsdc == 0,
            "released-margin"
        );
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, a.id);
        _check(
            bounty.state == IMarginClearinghouse.BountyReservationState.Settled && bounty.amountUsdc == 0,
            "settled-bounty"
        );
        PositionView memory position =
            abi.decode(_read(address(engine), abi.encodeCall(engine.positions, (a.trader))), (PositionView));
        if (a.admitted) {
            uint256 reserve = (20 * a.price * 10) / 10_000;
            if (reserve < 1e6) {
                reserve = 1e6;
            }
            _check(
                position.size == 2000e18 && position.entryPrice == a.price && position.side == a.side
                    && position.margin == 500e6 - fee - reserve && position.vpi == 0
                    && position.maxProfit == 20 * (a.side == CfdTypes.Side.LONG ? a.price : 2e8 - a.price),
                "executed-position"
            );
        } else {
            _check(position.size == 0, "rejected-position-empty");
        }
        _check(engine.traderClaimBalanceUsdc(a.trader) == 0, "no-orphan-claim");
        (uint256 longMax,,,) = engine.sides(0);
        (uint256 shortMax,,,) = engine.sides(1);
        _check(longMax == ghostLongMaxProfit && shortMax == ghostShortMaxProfit, "independent-liabilities");
    }

    function _admitted(
        CfdTypes.Side side,
        uint256 price,
        uint256 cash
    ) private view returns (bool) {
        uint256 longMax = ghostLongMaxProfit + (side == CfdTypes.Side.LONG ? 20 * price : 0);
        uint256 shortMax = ghostShortMaxProfit + (side == CfdTypes.Side.SHORT ? 20 * (2e8 - price) : 0);
        uint256 liability = longMax > shortMax ? longMax : shortMax;
        return cash >= liability + (liability * 25 + 9999) / 10_000;
    }

    function _payload(
        Action memory a
    ) private view returns (bytes[] memory data) {
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            updates[i] =
                MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(int64(uint64(a.rawPrice)), 0, -8, a.tick, a.commit));
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

    function _checkFixture() private view {
        CfdTypes.RiskParams memory risk =
            abi.decode(_read(address(engine), abi.encodeCall(engine.riskParams, ())), (CfdTypes.RiskParams));
        _check(
            risk.vpiFactor == 0 && risk.bountyBps == 10 && risk.minBountyUsdc == 1e6 && engine.CAP_PRICE() == 2e8
                && engine.executionFeeBps() == 4 && engine.settlementBufferBps() == 25,
            "model-configuration"
        );
        _check(!engine.isFadWindow() && !engine.isOracleFrozen(), "live-calendar-fixture");
        _check(engine.totalTraderClaimBalanceUsdc() == 0 && pyth.mockFee() == 0, "no-external-liabilities");
    }

    function _stateHash(
        address trader,
        uint64 id
    ) private view returns (bytes32) {
        bytes32 oracle = keccak256(
            abi.encode(
                engine.lastMarkPrice(),
                engine.lastMarkTime(),
                pyth.parseUniqueCallCount(),
                pyth.updatePriceFeedsCallCount(),
                _read(address(pyth), abi.encodeCall(pyth.prices, (ids[0]))),
                _read(address(pyth), abi.encodeCall(pyth.prices, (ids[1])))
            )
        );
        bytes32 lifecycle = keccak256(
            abi.encode(
                router.nextCommitId(),
                router.nextExecuteId(),
                router.globalTailOrderId(),
                router.lifecycleBook().pendingIntent(id),
                router.lifecycleBook().terminalOutcome(id),
                clearinghouse.getOrderReservation(id),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)
            )
        );
        bytes32 account = keccak256(
            abi.encode(
                clearinghouse.getAccountUsdcBuckets(trader),
                clearinghouse.getAccountReservationSummary(trader),
                clearinghouse.balanceUsdc(address(this)),
                clearinghouse.balanceUsdc(engine.protocolTreasury()),
                engine.traderClaimBalanceUsdc(trader),
                _read(address(engine), abi.encodeCall(engine.positions, (trader)))
            )
        );
        return keccak256(
            abi.encode(
                oracle,
                lifecycle,
                account,
                usdc.balanceOf(trader),
                usdc.balanceOf(address(router)),
                usdc.balanceOf(address(engine.pool())),
                usdc.balanceOf(address(clearinghouse))
            )
        );
    }

    function _read(
        address target,
        bytes memory input
    ) private view returns (bytes memory output) {
        bool ok;
        (ok, output) = target.staticcall(input);
        _check(ok, "observation-call-failed");
    }

    function _check(
        bool condition,
        bytes32 label
    ) private pure {
        if (!condition) {
            revert HandlerCheckFailed(label);
        }
    }

}

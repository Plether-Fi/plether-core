// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {ITerminalNavBookV2} from "@plether/perps/interfaces/ITerminalNavBookV2.sol";
import {OrderExecutionSettlement} from "@plether/perps/router/OrderExecutionSettlement.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Focused regressions for the Router's persistent emergency risk-off order semantics.
contract OrderRouterRiskOffTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xE0EC);
    address internal constant RESTORED = address(0xC0FFEE);

    uint256 internal constant MARK_PRICE = 1e8;
    uint256 internal constant UNSAFE_BULL_PRICE = 1.98e8;
    uint256 internal constant SATURDAY_NOON = 1_710_021_600;

    bytes32 internal constant CARRY_CHECKPOINTED_TOPIC = keccak256("CarryCheckpointed(address,uint256,uint256)");
    bytes32 internal constant BOUNTY_CREDITED_TOPIC = keccak256("BountyCredited(address,address,uint256)");
    bytes32 internal constant RESERVED_SETTLEMENT_TRANSFERRED_TOPIC =
        keccak256("ReservedSettlementTransferred(address,address,uint256)");
    bytes32 internal constant LIQUIDATION_BATCH_ITEM_TOPIC =
        keccak256("LiquidationBatchItem(uint256,address,uint8,uint256,bytes4)");

    event OrderFailed(uint64 indexed orderId, OrderExecutionSettlement.OrderFailReason reason);

    struct NoCheckpointSnapshot {
        bytes32 positionHash;
        bytes32 carryHash;
        bytes32 bookHash;
        bytes32 curveHash;
        bytes32 bucketsHash;
        uint256 settlementBalanceUsdc;
        uint256 poolUsdc;
        uint256 clearinghouseUsdc;
        uint256 markPrice;
        uint64 markTime;
    }

    function setUp() public override {
        super.setUp();
        _fundTrader(ALICE, 300_000e6);
        _fundTrader(BOB, 300_000e6);
    }

    function test_TargetedNonHeadRefundAndInvalidTargets() public {
        _open(ALICE, CfdTypes.Side.BULL, 20_000e18, 5000e6, MARK_PRICE);

        uint64 headOpenId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint64 nonHeadOpenId = _commitOpen(BOB, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint64 closeId = _commitClose(ALICE, CfdTypes.Side.BULL, 20_000e18);
        uint256 nonHeadRefund = _remainingCommittedMargin(nonHeadOpenId) + _executionBountyReserve(nonHeadOpenId);
        uint256 bobFreeBefore = _freeSettlementUsdc(BOB);
        uint256 keeperBefore = _settlementBalance(KEEPER);

        routerAdmin.pause();
        vm.prank(KEEPER);
        IPerpsKeeper(address(router)).clearRiskOffOrder(nonHeadOpenId);

        assertEq(router.nextExecuteId(), headOpenId, "targeted cleanup must not disturb the global head");
        assertEq(_freeSettlementUsdc(BOB) - bobFreeBefore, nonHeadRefund, "trader receives the exact refund");
        assertEq(_settlementBalance(KEEPER), keeperBefore, "targeted cleaner receives no bounty");
        assertEq(uint256(_orderRecord(nonHeadOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(uint256(_orderRecord(closeId).status), uint256(IOrderRouterAccounting.OrderStatus.Pending));

        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(closeId);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(nonHeadOpenId);

        routerAdmin.unpause();
        uint64 postCutoffOpenId = _commitOpen(BOB, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotRiskOff.selector);
        router.clearRiskOffOrder(postCutoffOpenId);
    }

    function test_RiskOffPrecedesExpiryWithoutOracleOrKeeperBounty() public {
        uint64 orderId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint256 expectedRefund = _remainingCommittedMargin(orderId) + _executionBountyReserve(orderId);
        uint256 traderFreeBefore = _freeSettlementUsdc(ALICE);
        uint256 keeperBefore = _settlementBalance(KEEPER);
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        routerAdmin.pause();
        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup must overlap the FAD close-only window");

        vm.expectEmit(true, false, false, true, address(router));
        emit OrderFailed(orderId, OrderExecutionSettlement.OrderFailReason.RiskOff);
        vm.prank(KEEPER);
        router.executeOrder(orderId, new bytes[](0));

        assertEq(baseMockPyth.updatePriceFeedsCallCount(), pythCallsBefore, "risk-off cleanup must precede oracle work");
        assertEq(_settlementBalance(KEEPER), keeperBefore, "expiry bounty policy must not override risk-off refund");
        assertEq(_freeSettlementUsdc(ALICE) - traderFreeBefore, expectedRefund, "margin and bounty return to trader");
        assertEq(uint256(_orderRecord(orderId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
    }

    function test_Exactly64Of65RiskOffHeadsRefundThenResume() public {
        uint64[] memory orderIds = new uint64[](65);
        for (uint256 i; i < orderIds.length; ++i) {
            address account = address(uint160(0x10000 + i));
            _fundTrader(account, 2000e6);
            orderIds[i] = _commitOpen(account, CfdTypes.Side.BULL, 10_000e18, 1000e6);
        }
        routerAdmin.pause();
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.prank(KEEPER);
        router.executeOrderBatch(orderIds[64], new bytes[](0));

        for (uint256 i; i < 64; ++i) {
            assertEq(
                uint256(_orderRecord(orderIds[i]).status),
                uint256(IOrderRouterAccounting.OrderStatus.Failed),
                "the first call must refund each of the first 64 heads"
            );
        }
        assertEq(
            uint256(_orderRecord(orderIds[64]).status),
            uint256(IOrderRouterAccounting.OrderStatus.Pending),
            "the 65th order must remain resumable"
        );
        assertEq(router.nextExecuteId(), orderIds[64], "cursor must stop exactly at the first unrefunded head");
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), pythCallsBefore, "neither refund pass needs Pyth");

        vm.prank(KEEPER);
        router.executeOrderBatch(orderIds[64], new bytes[](0));
        assertEq(uint256(_orderRecord(orderIds[64]).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(router.nextExecuteId(), 0, "the second call must finish the queue");
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), pythCallsBefore, "resume also remains oracle-independent");
    }

    function test_OldInvalidationSurvivesUnpauseAndNewOpenExecutes() public {
        uint64 oldOrderId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        routerAdmin.pause();
        uint64 cutoff = routerAdmin.riskOffOrderCutoff();
        routerAdmin.unpause();
        uint64 newOrderId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);

        vm.prank(KEEPER);
        router.executeOrder(oldOrderId, new bytes[](0));
        assertEq(uint256(_orderRecord(oldOrderId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(_positionSize(ALICE), 0, "historically invalidated open must never reach the Engine");

        bytes[] memory newOrderUpdate = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(newOrderId, newOrderUpdate);
        assertEq(uint256(_orderRecord(newOrderId).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(_positionSize(ALICE), 10_000e18, "post-cutoff open remains executable");
        assertEq(routerAdmin.riskOffOrderCutoff(), cutoff, "healthy execution must not rewrite incident history");
    }

    function test_OpenCloseOpenProjectionIgnoresBothInvalidatedOpens() public {
        _open(ALICE, CfdTypes.Side.BULL, 20_000e18, 5000e6, MARK_PRICE);
        uint64 firstOpenId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint64 closeId = _commitClose(ALICE, CfdTypes.Side.BULL, 20_000e18);
        uint64 secondOpenId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint256 closeBounty = _executionBountyReserve(closeId);
        uint256 keeperBefore = _settlementBalance(KEEPER);
        routerAdmin.pause();

        vm.prank(ALICE);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoQueuedPosition.selector);
        router.commitOrder(CfdTypes.Side.BULL, 100e18, 0, 0, true);

        bytes[] memory closeUpdate = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrderBatch(secondOpenId, closeUpdate);

        assertEq(uint256(_orderRecord(firstOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(uint256(_orderRecord(closeId).status), uint256(IOrderRouterAccounting.OrderStatus.Executed));
        assertEq(uint256(_orderRecord(secondOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(_positionSize(ALICE), 0, "the valid close must execute through invalid opens");
        assertEq(_settlementBalance(KEEPER) - keeperBefore, closeBounty, "only the live close bounty is paid");
    }

    function test_LivePositionRefundHasNoCheckpointOrNavSideEffects() public {
        _open(ALICE, CfdTypes.Side.BULL, 100_000e18, 5000e6, MARK_PRICE);
        uint64 orderId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        routerAdmin.pause();
        vm.warp(block.timestamp + 30 days);

        IOrderRouterAccounting.AccountReservationView memory reservationBefore = router.getAccountReservations(ALICE);
        IMarginClearinghouse.PnlIsolationBuckets memory bucketsBefore = clearinghouse.getPnlIsolationBuckets(ALICE);
        NoCheckpointSnapshot memory beforeState = _noCheckpointSnapshot(ALICE);
        uint256 keeperBefore = _settlementBalance(KEEPER);

        vm.recordLogs();
        vm.prank(KEEPER);
        router.clearRiskOffOrder(orderId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        NoCheckpointSnapshot memory afterState = _noCheckpointSnapshot(ALICE);
        IMarginClearinghouse.PnlIsolationBuckets memory bucketsAfter = clearinghouse.getPnlIsolationBuckets(ALICE);
        uint256 released = reservationBefore.committedMarginUsdc + reservationBefore.executionBountyUsdc;

        assertEq(afterState.positionHash, beforeState.positionHash, "position state must not mutate");
        assertEq(afterState.carryHash, beforeState.carryHash, "carry state must not checkpoint");
        assertEq(afterState.bookHash, beforeState.bookHash, "Terminal NAV aggregate must not mutate");
        assertEq(afterState.curveHash, beforeState.curveHash, "account curve must not resynchronize");
        assertEq(afterState.markPrice, beforeState.markPrice, "cached mark price must not mutate");
        assertEq(afterState.markTime, beforeState.markTime, "cached mark time must not mutate");
        assertEq(afterState.settlementBalanceUsdc, beforeState.settlementBalanceUsdc, "gross settlement unchanged");
        assertEq(afterState.poolUsdc, beforeState.poolUsdc, "pool custody unchanged");
        assertEq(afterState.clearinghouseUsdc, beforeState.clearinghouseUsdc, "clearinghouse custody unchanged");
        assertEq(_settlementBalance(KEEPER), keeperBefore, "cleaner receives no settlement");

        assertEq(bucketsAfter.settlementBalanceUsdc, bucketsBefore.settlementBalanceUsdc);
        assertEq(bucketsAfter.pnlPledgeUsdc, bucketsBefore.pnlPledgeUsdc);
        assertEq(bucketsAfter.liquidationReserveUsdc, bucketsBefore.liquidationReserveUsdc);
        assertEq(bucketsBefore.orderMarginUsdc - bucketsAfter.orderMarginUsdc, reservationBefore.committedMarginUsdc);
        assertEq(
            bucketsBefore.actionReserveUsdc - bucketsAfter.actionReserveUsdc, reservationBefore.executionBountyUsdc
        );
        assertEq(bucketsAfter.vpiRebateReserveUsdc, bucketsBefore.vpiRebateReserveUsdc);
        assertEq(bucketsBefore.totalLockedUsdc - bucketsAfter.totalLockedUsdc, released);
        assertEq(bucketsAfter.freeSettlementUsdc - bucketsBefore.freeSettlementUsdc, released);
        _assertNoCheckpointLogs(logs);

        uint64 deferredCarryTimestamp = _lastCarryTimestamp(ALICE);
        _fundTrader(ALICE, 1);
        assertGt(
            _lastCarryTimestamp(ALICE),
            deferredCarryTimestamp,
            "a later ordinary settlement mutation must checkpoint the carry deferred by risk-off refund"
        );
    }

    function test_ForcedClearinghouseFailureRollsBackAllRouterEffects() public {
        uint64 orderId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        routerAdmin.pause();

        bytes32 orderHashBefore = keccak256(abi.encode(_orderRecord(orderId)));
        bytes32 reservationHashBefore = keccak256(abi.encode(clearinghouse.getOrderReservation(orderId)));
        bytes32 accountReservationHashBefore = keccak256(abi.encode(router.getAccountReservations(ALICE)));
        uint64 nextExecuteBefore = router.nextExecuteId();
        uint64 globalTailBefore = router.globalTailOrderId();
        uint64 accountHeadBefore = router.accountHeadOrderId(ALICE);

        vm.mockCallRevert(
            address(clearinghouse),
            abi.encodeWithSelector(IMarginClearinghouse.releaseInvalidatedOrderReserves.selector),
            bytes("forced clearinghouse failure")
        );
        vm.expectRevert(bytes("forced clearinghouse failure"));
        router.clearRiskOffOrder(orderId);
        vm.clearMockedCalls();

        assertEq(keccak256(abi.encode(_orderRecord(orderId))), orderHashBefore, "order record must roll back");
        assertEq(
            keccak256(abi.encode(clearinghouse.getOrderReservation(orderId))),
            reservationHashBefore,
            "canonical margin reservation must remain active"
        );
        assertEq(
            keccak256(abi.encode(router.getAccountReservations(ALICE))),
            accountReservationHashBefore,
            "account aggregates must roll back"
        );
        assertEq(router.nextExecuteId(), nextExecuteBefore, "global head must roll back");
        assertEq(router.globalTailOrderId(), globalTailBefore, "global tail must roll back");
        assertEq(router.accountHeadOrderId(ALICE), accountHeadBefore, "account links must roll back");
    }

    function test_CleanupFirstAndEmbeddedSingleLiquidationAreEconomicallyEquivalent() public {
        _open(ALICE, CfdTypes.Side.BULL, 100_000e18, 2000e6, MARK_PRICE);
        uint64 invalidOpenId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        uint64 liveCloseId = _commitClose(ALICE, CfdTypes.Side.BULL, 10_000e18);
        routerAdmin.pause();
        assertTrue(engineLens.isLiquidatableAt(ALICE, UNSAFE_BULL_PRICE, pool.totalAssets()));
        uint256 branch = vm.snapshotState();

        vm.prank(KEEPER);
        router.clearRiskOffOrder(invalidOpenId);
        bytes[] memory cleanupFirstUpdate = _mockPythUpdateData(UNSAFE_BULL_PRICE);
        vm.prank(KEEPER);
        router.executeLiquidation(ALICE, cleanupFirstUpdate);
        bytes32 cleanupFirst = _liquidationOutcomeHash(ALICE, invalidOpenId, liveCloseId);

        vm.revertToState(branch);
        bytes[] memory embeddedUpdate = _mockPythUpdateData(UNSAFE_BULL_PRICE);
        vm.prank(KEEPER);
        router.executeLiquidation(ALICE, embeddedUpdate);
        bytes32 embedded = _liquidationOutcomeHash(ALICE, invalidOpenId, liveCloseId);

        assertEq(embedded, cleanupFirst, "embedded refund must match explicit cleanup then liquidation");
        assertEq(_positionSize(ALICE), 0, "unsafe position must liquidate");
    }

    function test_EmbeddedRefundCanRestoreSolvencyWithoutRollingBackRefund() public {
        _fundTrader(RESTORED, 300e6);
        _open(RESTORED, CfdTypes.Side.BULL, 10_000e18, 250e6, MARK_PRICE);
        uint64 invalidOpenId = _commitOpen(RESTORED, CfdTypes.Side.BULL, 100e18, 49e6);
        routerAdmin.pause();
        vm.warp(block.timestamp + 365 days);

        assertTrue(
            engineLens.isLiquidatableAt(RESTORED, MARK_PRICE, pool.totalAssets()),
            "locked order funds must leave accrued carry delinquent before refund"
        );
        uint256 branch = vm.snapshotState();

        router.clearRiskOffOrder(invalidOpenId);
        assertFalse(
            engineLens.isLiquidatableAt(RESTORED, MARK_PRICE, pool.totalAssets()),
            "risk-off refund must make enough settlement reachable for carry"
        );
        bytes32 cleanupBuckets = _bucketsHash(RESTORED);
        bytes32 cleanupOrder = keccak256(abi.encode(_orderRecord(invalidOpenId)));

        vm.revertToState(branch);
        bytes[] memory restoredUpdate = _freshPythUpdateData(MARK_PRICE);
        vm.prank(KEEPER);
        router.executeLiquidation(RESTORED, restoredUpdate);

        assertGt(_positionSize(RESTORED), 0, "restored-solvency account must not liquidate");
        assertEq(uint256(_orderRecord(invalidOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(_bucketsHash(RESTORED), cleanupBuckets, "embedded path must preserve the exact explicit refund");
        assertEq(
            keccak256(abi.encode(_orderRecord(invalidOpenId))),
            cleanupOrder,
            "embedded refund must retain the same terminal order record"
        );
    }

    function test_BatchLiquidationAppliesRiskOffRefundBeforeLiquidating() public {
        _open(ALICE, CfdTypes.Side.BULL, 100_000e18, 2000e6, MARK_PRICE);
        uint64 invalidOpenId = _commitOpen(ALICE, CfdTypes.Side.BULL, 10_000e18, 2000e6);
        routerAdmin.pause();
        uint256 keeperBefore = _settlementBalance(KEEPER);
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;

        bytes[] memory liquidationUpdate = _mockPythUpdateData(UNSAFE_BULL_PRICE);
        vm.prank(KEEPER);
        uint256 nextIndex = router.executeLiquidationBatch(accounts, liquidationUpdate);

        assertEq(nextIndex, 1, "batch must attempt the account");
        assertEq(_positionSize(ALICE), 0, "unsafe account must liquidate through the sidecar path");
        assertEq(uint256(_orderRecord(invalidOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(
            uint256(clearinghouse.getOrderReservation(invalidOpenId).status),
            uint256(IMarginClearinghouse.ReservationStatus.Released),
            "invalidated order margin must use the refund path"
        );
        assertGe(_settlementBalance(KEEPER), keeperBefore, "batch must never debit the original caller");
    }

    function test_BatchRefundRestoresSolvencyAndEmitsCanonicalSkip() public {
        _fundTrader(RESTORED, 300e6);
        _open(RESTORED, CfdTypes.Side.BULL, 10_000e18, 250e6, MARK_PRICE);
        uint64 invalidOpenId = _commitOpen(RESTORED, CfdTypes.Side.BULL, 100e18, 49e6);
        routerAdmin.pause();
        vm.warp(block.timestamp + 365 days);

        assertTrue(
            engineLens.isLiquidatableAt(RESTORED, MARK_PRICE, pool.totalAssets()),
            "setup must be liquidatable only while the carry-covering order funds remain locked"
        );
        IOrderRouterAccounting.AccountReservationView memory reservationBefore = router.getAccountReservations(RESTORED);
        uint256 freeBefore = _freeSettlementUsdc(RESTORED);
        uint256 keeperBefore = _settlementBalance(KEEPER);
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        address[] memory accounts = new address[](1);
        accounts[0] = RESTORED;
        bytes[] memory updateData = _freshPythUpdateData(MARK_PRICE);

        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 nextIndex = router.executeLiquidationBatch(accounts, updateData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(nextIndex, 1, "solvency-restored item must advance the batch cursor");
        assertGt(_positionSize(RESTORED), 0, "refund-restored position must remain open");
        assertEq(uint256(_orderRecord(invalidOpenId).status), uint256(IOrderRouterAccounting.OrderStatus.Failed));
        assertEq(
            uint256(clearinghouse.getOrderReservation(invalidOpenId).status),
            uint256(IMarginClearinghouse.ReservationStatus.Released),
            "embedded refund must remain committed under delegatecall"
        );
        assertEq(
            _freeSettlementUsdc(RESTORED) - freeBefore,
            reservationBefore.committedMarginUsdc + reservationBefore.executionBountyUsdc,
            "batch skip must preserve the complete risk-off refund"
        );
        assertEq(_settlementBalance(KEEPER), keeperBefore, "solvent skip pays no liquidation bounty");
        assertEq(
            _settlementBalance(engine.protocolTreasury()), treasuryBefore, "solvent skip forfeits no remaining value"
        );
        assertFalse(
            engineLens.isLiquidatableAt(RESTORED, MARK_PRICE, pool.totalAssets()),
            "post-refund account must remain canonically nonliquidatable"
        );
        _assertRestoredSolvencyBatchEvent(logs, RESTORED);
    }

    function _commitOpen(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin
    ) internal returns (uint64 orderId) {
        orderId = router.nextCommitId();
        vm.prank(account);
        router.commitOrder(side, size, margin, MARK_PRICE, false);
    }

    function _freshPythUpdateData(
        uint256 price
    ) internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), int32(-8), block.timestamp);
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _commitClose(
        address account,
        CfdTypes.Side side,
        uint256 size
    ) internal returns (uint64 orderId) {
        orderId = router.nextCommitId();
        vm.prank(account);
        router.commitOrder(side, size, 0, 0, true);
    }

    function _positionSize(
        address account
    ) internal view returns (uint256 size) {
        (size,,,,,,) = engine.positions(account);
    }

    function _positionHash(
        address account
    ) internal view returns (bytes32) {
        bytes32 coreHash;
        {
            (
                uint256 size,
                uint256 margin,
                uint256 entryPrice,
                uint256 maxProfitUsdc,
                CfdTypes.Side side,
                uint64 lastUpdateTime,
                int256 vpiAccrued
            ) = engine.positions(account);
            coreHash = keccak256(abi.encode(size, margin, entryPrice, maxProfitUsdc, side, lastUpdateTime, vpiAccrued));
        }
        return keccak256(abi.encode(coreHash, engine.positionEntryCostUsdcAtoms(account)));
    }

    function _carryHash(
        address account
    ) internal view returns (bytes32) {
        (uint256 borrowBase, uint256 carryIndex, uint64 carryTimestamp) = engine.positionCarryState(account);
        return keccak256(
            abi.encode(
                borrowBase,
                carryIndex,
                carryTimestamp,
                engine.unsettledCarryUsdc(account),
                engine.sideCarryIndex(uint256(CfdTypes.Side.BULL)),
                engine.sideCarryTimestamp(uint256(CfdTypes.Side.BULL)),
                engine.sideCarryIndex(uint256(CfdTypes.Side.BEAR)),
                engine.sideCarryTimestamp(uint256(CfdTypes.Side.BEAR))
            )
        );
    }

    function _bookHash() internal view returns (bytes32) {
        ITerminalNavBookV2.BookState memory state = terminalNavBook.bookState();
        return keccak256(abi.encode(state));
    }

    function _bucketsHash(
        address account
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(clearinghouse.getPnlIsolationBuckets(account)));
    }

    function _noCheckpointSnapshot(
        address account
    ) internal view returns (NoCheckpointSnapshot memory state) {
        state.positionHash = _positionHash(account);
        state.carryHash = _carryHash(account);
        state.bookHash = _bookHash();
        state.curveHash = terminalNavBook.curveHashOf(account);
        state.bucketsHash = _bucketsHash(account);
        state.settlementBalanceUsdc = clearinghouse.balanceUsdc(account);
        state.poolUsdc = usdc.balanceOf(address(pool));
        state.clearinghouseUsdc = usdc.balanceOf(address(clearinghouse));
        state.markPrice = engine.lastMarkPrice();
        state.markTime = engine.lastMarkTime();
    }

    function _assertNoCheckpointLogs(
        Vm.Log[] memory logs
    ) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != CARRY_CHECKPOINTED_TOPIC, "refund must not checkpoint carry");
            assertTrue(topic != BOUNTY_CREDITED_TOPIC, "refund must not route through Engine bounty credit");
            assertTrue(
                topic != RESERVED_SETTLEMENT_TRANSFERRED_TOPIC, "refund must not transfer settlement to an executor"
            );
        }
    }

    function _liquidationOutcomeHash(
        address account,
        uint64 invalidOpenId,
        uint64 liveCloseId
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _positionHash(account),
                _bucketsHash(account),
                _bookHash(),
                terminalNavBook.curveHashOf(account),
                _orderRecord(invalidOpenId),
                _orderRecord(liveCloseId),
                router.getAccountReservations(account),
                router.accountHeadOrderId(account),
                router.pendingOrderCounts(account),
                clearinghouse.balanceUsdc(KEEPER),
                clearinghouse.balanceUsdc(engine.protocolTreasury()),
                usdc.balanceOf(address(pool))
            )
        );
    }

    function _assertRestoredSolvencyBatchEvent(
        Vm.Log[] memory logs,
        address account
    ) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(router) || logs[i].topics.length != 3
                    || logs[i].topics[0] != LIQUIDATION_BATCH_ITEM_TOPIC
            ) {
                continue;
            }
            uint256 index = uint256(logs[i].topics[1]);
            address eventAccount = address(uint160(uint256(logs[i].topics[2])));
            (IOrderRouterErrors.LiquidationBatchResult result, uint256 keeperBountyUsdc, bytes4 errorSelector) =
                abi.decode(logs[i].data, (IOrderRouterErrors.LiquidationBatchResult, uint256, bytes4));
            if (index == 0 && eventAccount == account) {
                assertEq(
                    uint256(result),
                    uint256(IOrderRouterErrors.LiquidationBatchResult.SkippedSolvent),
                    "restored solvency must use the canonical batch classification"
                );
                assertEq(keeperBountyUsdc, 0, "restored-solvency sentinel must not report a bounty");
                assertEq(errorSelector, bytes4(0), "sentinel classification must not report a revert selector");
                return;
            }
        }
        fail("Router must emit the restored-solvency batch item");
    }

}

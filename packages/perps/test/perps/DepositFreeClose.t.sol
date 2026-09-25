// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdClosePreviewTestBase} from "./CfdClosePreviewTestBase.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

contract DepositFreeCloseTest is CfdClosePreviewTestBase {

    struct Balances {
        uint256 custody;
        uint256 margin;
        uint256 keeper;
        uint256 wallet;
    }

    function _request(
        CfdTypes.Side side,
        uint256 size,
        bool callerPaid
    ) internal view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = keccak256(abi.encode("deposit-free", router.nextCommitId()));
        request.side = side;
        request.sizeDelta = size;
        request.targetPrice = side == CfdTypes.Side.LONG ? type(uint256).max : 1;
        request.isClose = true;
        request.closeMode = callerPaid ? OrderV2Types.CloseMode.CallerPaidFullExit : OrderV2Types.CloseMode.Standard;
        request.bounds = _bounds();
        request.bounds.validUntil = uint64(vm.getBlockTimestamp() + router.maxOrderAge());
        request.bounds.expectedConfigHash = router.lifecycleBook().currentExecutionConfigHash();
        if (callerPaid) {
            request.bounds.maxPostPositionSize = 0;
        }
    }

    function _closeAtZeroFree(
        CfdTypes.Side side,
        uint256 size,
        bool callerPaid,
        address executor
    ) internal {
        _openNormally(side, 0);
        OrderV2Types.OrderRequest memory request = _request(side, size, callerPaid);
        Balances memory beforeState = Balances(
            clearinghouse.balanceUsdc(ACCOUNT),
            clearinghouse.pnlPledgeUsdc(ACCOUNT),
            clearinghouse.balanceUsdc(KEEPER),
            usdc.balanceOf(ACCOUNT)
        );
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, executor, PRICE, uint64(vm.getBlockTimestamp()));
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        assertEq(uint8(reservation.state), uint8(IMarginClearinghouse.BountyReservationState.Active));
        assertEq(reservation.freeFundedUsdc, 0);
        assertEq(reservation.pledgeFundedUsdc, callerPaid ? 0 : router.closeOrderExecutionBountyUsdc());
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), beforeState.custody, "reservation does not debit custody");
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), beforeState.margin - reservation.pledgeFundedUsdc);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, 0);
        OrderV2Types.ExecutionAssessment memory assessed =
            policyEvaluator.assessCommittedOrder(address(engine), id, executor, PRICE, uint64(vm.getBlockTimestamp()));
        assertEq(keccak256(abi.encode(preview.assessment)), keccak256(abi.encode(assessed)));
        assertEq(
            assessed.close.safeMarginReleaseUsdc,
            assessed.close.actionChargeFromReleasedMarginUsdc + assessed.close.netReleasedMarginUsdc
        );
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.recordLogs();
        vm.prank(executor);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        _assertReceipt(vm.getRecordedLogs(), id, assessed);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE - size);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), assessed.postSettlementBalanceUsdc);
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, assessed.close.postFreeSettlementUsdc);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(usdc.balanceOf(ACCOUNT), beforeState.wallet, "no wallet funding");
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - beforeState.keeper, executor == KEEPER ? reservation.amountUsdc : 0
        );
        assertEq(router.pendingTerminalExitId(ACCOUNT), 0);
    }

    function test_StandardFullLongZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, false, KEEPER);
    }

    function test_CommitmentSidecarFailureAndMalformedReturnRollBack() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, false);
        address target = address(engine.settlementSidecar());
        bytes memory callData = abi.encodeCall(
            ICfdEngineSettlementSidecar.reserveCloseOrderExecutionBounty,
            (ACCOUNT, SIZE, router.closeOrderExecutionBountyUsdc())
        );
        bytes32 beforeBuckets = keccak256(abi.encode(clearinghouse.getAccountUsdcBuckets(ACCOUNT)));
        bytes memory failure = hex"abcdef0123456789";
        vm.mockCallRevert(target, callData, failure);
        vm.expectRevert(failure);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        vm.clearMockedCalls();
        vm.mockCall(target, callData, new bytes(223));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidRiskParams.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        vm.clearMockedCalls();
        assertEq(beforeBuckets, keccak256(abi.encode(clearinghouse.getAccountUsdcBuckets(ACCOUNT))));
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed), "reentrancy guard is restored");
    }

    function test_StandardFullShortZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE, false, KEEPER);
    }

    function test_StandardPartialLongZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE / 2, false, KEEPER);
    }

    function test_StandardPartialShortSelfZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE / 2, false, ACCOUNT);
    }

    function test_CallerPaidLongZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, true, KEEPER);
    }

    function test_CallerPaidShortZeroFree() public {
        _closeAtZeroFree(CfdTypes.Side.SHORT, SIZE, true, ACCOUNT);
    }

    function test_TerminalLockReplayAndPermissionlessExpiry() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, true);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        assertEq(router.pendingTerminalExitId(ACCOUNT), id);
        vm.prank(ACCOUNT);
        assertEq(router.commitOrder(request), id);
        request.clientOrderId = keccak256("different");
        vm.expectRevert(abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__TerminalExitActive.selector, id));
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        vm.warp(request.bounds.validUntil + 1);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(router.pendingTerminalExitId(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id).state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled)
        );
    }

    function test_CallerPaidRejectsPartialAndPendingOrders() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE / 2, true);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidCloseMode.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        request.closeMode = OrderV2Types.CloseMode.Standard;
        request.bounds.maxPostPositionSize = type(uint256).max;
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        request = _request(CfdTypes.Side.LONG, SIZE, true);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__TerminalExitBusy.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
    }

    function testFuzz_ZeroFreeReductions(
        uint8 lots,
        bool shortSide
    ) public {
        uint256 size = bound(uint256(lots), 20, 99) * 100e18;
        _closeAtZeroFree(shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG, size, false, KEEPER);
    }

    function _maxOpenClose(
        CfdTypes.Side side,
        bool isPartial
    ) private {
        _fundTrader(ACCOUNT, 1000e6);
        uint256 size;
        {
            uint256 margin = 1000e6 - router.maxOpenOrderExecutionBountyUsdc();
            ICfdEngineLens.MaxOpenQuote memory quote =
                engineLens.quoteMaxOpen(ACCOUNT, side, margin, PRICE, uint64(vm.getBlockTimestamp()));
            vm.prank(ACCOUNT);
            uint64 openId = router.commitOrder(side, quote.maxSizeDelta, margin, PRICE, false);
            bytes[] memory update = _mockPythUpdateData(PRICE);
            vm.prank(KEEPER);
            router.executeOrder(openId, update);
            (size,,,,,,) = engine.positions(ACCOUNT);
            assertEq(size, quote.maxSizeDelta);
            uint256 free = clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
            if (free != 0) {
                vm.prank(ACCOUNT);
                clearinghouse.withdraw(ACCOUNT, free);
            }
        }
        uint256 supply = usdc.totalSupply();
        uint256 closeSize = isPartial ? size / 2 / CfdTypes.SIZE_QUANTUM * CfdTypes.SIZE_QUANTUM : size;
        OrderV2Types.OrderRequest memory request = _request(side, closeSize, false);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, size - closeSize);
        assertEq(usdc.totalSupply(), supply, "no assistance mint");
    }

    function test_MaxOpenOrdinaryFullLong() public {
        _maxOpenClose(CfdTypes.Side.LONG, false);
    }

    function test_MaxOpenOrdinaryFullShort() public {
        _maxOpenClose(CfdTypes.Side.SHORT, false);
    }

    function test_MaxOpenOrdinaryPartialLong() public {
        _maxOpenClose(CfdTypes.Side.LONG, true);
    }

    function test_MaxOpenOrdinaryPartialShort() public {
        _maxOpenClose(CfdTypes.Side.SHORT, true);
    }

    function test_CallerPaidAfterRepeatedExpiryExhaustsBountyFunding() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.closeOrderExecutionBountyUsdc = 1e6;
        _setRouterConfig(config);
        _fundTrader(ACCOUNT, 100e6);
        vm.prank(ACCOUNT);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 50e6, PRICE, false);
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        router.executeOrder(openId, update);
        uint256 free = clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc;
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, free);
        uint256 attempts;
        for (; attempts < 60; ++attempts) {
            OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, 1000e18, false);
            vm.prank(ACCOUNT);
            try router.commitOrder(request) returns (uint64 id) {
                vm.warp(request.bounds.validUntil + 1);
                router.expireOrder(id);
            } catch {
                break;
            }
        }
        assertGt(attempts, 1);
        assertLt(attempts, 60, "ordinary bounty backing actually exhausted");
        OrderV2Types.OrderRequest memory terminal = _request(CfdTypes.Side.LONG, 1000e18, true);
        vm.prank(ACCOUNT);
        uint64 closeId = router.commitOrder(terminal);
        update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(closeId, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
    }

    function test_TerminalPositionIdentityChangeFailsWithoutResizing() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, true);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        // Synthetic epoch mismatch; actual position remains unchanged.
        vm.mockCall(
            address(engine),
            abi.encodeWithSignature("positionEpoch(address)", ACCOUNT),
            abi.encode(uint64(engine.positionEpoch(ACCOUNT) + 1))
        );
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.TerminalPositionChanged));
        assertEq(router.pendingTerminalExitId(ACCOUNT), 0);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, SIZE);
    }

    function test_LiquidationWinsAndClearsZeroReservationTerminalLock() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, true);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        bytes[] memory update = _mockPythUpdateData(110_000_000);
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, update);
        assertEq(router.pendingTerminalExitId(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
        assertEq(
            uint8(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id).state),
            uint8(IMarginClearinghouse.BountyReservationState.Settled)
        );
    }

    function test_CloseWinsThenLiquidationHasNoPosition() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, true, ACCOUNT);
        bytes[] memory update = _mockPythUpdateData(110_000_000);
        vm.expectRevert();
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, update);
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
    }

    function _systemValue() private view returns (uint256) {
        return clearinghouse.balanceUsdc(ACCOUNT) + clearinghouse.balanceUsdc(KEEPER)
            + clearinghouse.balanceUsdc(engine.protocolTreasury()) + usdc.balanceOf(address(pool));
    }

    function testFuzz_PartialThenFullConservesSystemValue(
        uint8 lotSeed,
        bool shortSide
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _openNormally(side, 0);
        uint256 initialValue = _systemValue();
        uint256 initialSupply = usdc.totalSupply();
        uint256 first = bound(uint256(lotSeed), 20, 80) * CfdTypes.SIZE_QUANTUM;
        for (uint256 i; i < 2; ++i) {
            uint256 size = i == 0 ? first : SIZE - first;
            OrderV2Types.OrderRequest memory request = _request(side, size, false);
            vm.prank(ACCOUNT);
            uint64 id = router.commitOrder(request);
            bytes[] memory update = _mockPythUpdateData(PRICE);
            vm.prank(KEEPER);
            OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
            assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Executed));
            assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        }
        assertEq(_systemValue(), initialValue, "splitting cannot manufacture settlement or pool cash");
        assertEq(usdc.totalSupply(), initialSupply);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 0, "flat-price splitting cannot manufacture claims");
        (uint256 remaining,,,,,,) = engine.positions(ACCOUNT);
        assertEq(remaining, 0);
    }

    // Synthetic lifecycle-entitlement corruption; custody and the authentic escrow remain untouched.
    function _corruptEntitlement(
        uint64 id,
        uint256 amount
    ) private {
        vm.record();
        router.lifecycleBook().pendingIntent(id);
        (bytes32[] memory slots,) = vm.accesses(address(router.lifecycleBook()));
        // PendingIntent.account begins the mapping value; entitlement is its fourth storage word.
        vm.store(address(router.lifecycleBook()), bytes32(uint256(slots[0]) + 3), bytes32(amount));
        assertEq(router.lifecycleBook().pendingIntent(id).executionBountyUsdc, amount);
    }

    function _mismatchedExpiry(
        bool above
    ) private {
        _openNormally(CfdTypes.Side.SHORT, 0);
        uint256 margin = clearinghouse.pnlPledgeUsdc(ACCOUNT);
        uint256 custody = clearinghouse.balanceUsdc(ACCOUNT);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE, false);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        uint256 backing = router.closeOrderExecutionBountyUsdc();
        _corruptEntitlement(id, above ? backing + 1 : backing - 1);
        bytes32 beforeState = keccak256(
            abi.encode(
                clearinghouse.getAccountUsdcBuckets(ACCOUNT),
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)
            )
        );
        bytes[] memory update = _mockPythUpdateData(PRICE);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(
            beforeState,
            keccak256(
                abi.encode(
                    clearinghouse.getAccountUsdcBuckets(ACCOUNT),
                    clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id)
                )
            ),
            "retry rolls back every classification"
        );
        uint256 keeper = clearinghouse.balanceUsdc(KEEPER);
        vm.warp(request.bounds.validUntil + 1);
        vm.prank(KEEPER);
        result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.ExpiredReservationMismatch));
        assertEq(clearinghouse.balanceUsdc(KEEPER), keeper, "mismatch pays no keeper");
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), custody, "refund creates no custody");
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), margin, "same epoch restores original pledge");
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__OrderNotPending.selector);
        router.expireOrder(id);
    }

    function test_EntitlementAboveBackingRetryAndExpiryRefund() public {
        _mismatchedExpiry(true);
    }

    function test_EntitlementBelowBackingRetryAndExpiryRefund() public {
        _mismatchedExpiry(false);
    }

    function test_ExpiryCanRemoveLaterOrderWithoutExecutingOutOfFifo() public {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE / 2, false);
        vm.prank(ACCOUNT);
        uint64 first = router.commitOrder(request);
        request = _request(CfdTypes.Side.LONG, SIZE / 2, false);
        request.bounds.validUntil -= 1;
        vm.prank(ACCOUNT);
        uint64 second = router.commitOrder(request);
        vm.warp(request.bounds.validUntil + 1);
        router.expireOrder(second);
        assertEq(router.accountHeadOrderId(ACCOUNT), first);
        assertEq(router.pendingOrderCounts(ACCOUNT), 1);
    }

    function test_ZeroBountyStillChecksFullExitAdmission() public {
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, true);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidCloseMode.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
    }

    // Synthetic reservation corruption is deliberately separate from public-lifecycle acceptance fixtures.
    function _reservationAnomaly(
        uint8 kind
    ) private {
        _openNormally(CfdTypes.Side.LONG, 0);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, false);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        vm.record();
        clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        (bytes32[] memory slots,) = vm.accesses(address(clearinghouse));
        if (kind == 0) {
            // An already-settled record; do not invent a second refund.
            vm.prank(address(router));
            clearinghouse.takeBountyReservation(ACCOUNT, IMarginClearinghouse.BountyKind.Order, id);
        } else if (kind == 1) {
            // Foreign ownership must not be overwritten by order cleanup.
            uint256 word = uint256(vm.load(address(clearinghouse), slots[0]));
            vm.store(
                address(clearinghouse),
                slots[0],
                bytes32((word & ~uint256(type(uint160).max)) | uint160(address(0xBAD)))
            );
        } else if (kind == 2) {
            // Invalid provenance sum is quarantined without releasing disputed classifications.
            uint256 word = uint256(vm.load(address(clearinghouse), slots[0]));
            vm.store(address(clearinghouse), slots[0], bytes32(word + (uint256(1) << 160)));
        } else {
            // Missing record with disputed classifications left intact: no fabricated refund.
            for (uint256 i; i < 3; ++i) {
                vm.store(address(clearinghouse), bytes32(uint256(slots[0]) + i), bytes32(0));
            }
        }
        uint256 custody = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 reserve = clearinghouse.actionReserveUsdc(ACCOUNT);
        uint256 keeper = clearinghouse.balanceUsdc(KEEPER);
        vm.warp(request.bounds.validUntil + 1);
        vm.prank(KEEPER);
        OrderV2Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(uint8(result.terminalReason), uint8(OrderV2Types.TerminalReason.ExpiredReservationMismatch));
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), custody);
        assertEq(clearinghouse.actionReserveUsdc(ACCOUNT), reserve);
        assertEq(clearinghouse.balanceUsdc(KEEPER), keeper);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        IMarginClearinghouse.BountyReservation memory afterRecord =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        if (kind == 1) {
            assertEq(afterRecord.account, address(0xBAD));
        }
        if (kind == 2) {
            assertEq(uint8(afterRecord.state), uint8(IMarginClearinghouse.BountyReservationState.Quarantined));
        }
    }

    function test_SettledReservationExpiryMovesNoFunds() public {
        _reservationAnomaly(0);
    }

    function test_WrongOwnerReservationExpiryLeavesForeignRecord() public {
        _reservationAnomaly(1);
    }

    function test_InvalidProvenanceExpiryQuarantinesBacking() public {
        _reservationAnomaly(2);
    }

    function test_MissingReservationExpiryMovesNoFunds() public {
        _reservationAnomaly(3);
    }

    function test_OriginalPositionEpochCannotRefundIntoReopenedPosition() public {
        _closeAtZeroFree(CfdTypes.Side.LONG, SIZE, true, ACCOUNT);
        uint64 originalEpoch = engine.positionEpoch(ACCOUNT);
        _openNormally(CfdTypes.Side.LONG, 0);
        assertEq(engine.positionEpoch(ACCOUNT), originalEpoch + 1);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.LONG, SIZE, false);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        uint256 margin = clearinghouse.pnlPledgeUsdc(ACCOUNT);
        uint256 backing = router.closeOrderExecutionBountyUsdc();
        // Synthetic stale provenance models a recoverable old reservation after a real close/reopen lifecycle.
        vm.record();
        clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
        (bytes32[] memory slots,) = vm.accesses(address(clearinghouse));
        vm.store(address(clearinghouse), bytes32(uint256(slots[0]) + 2), bytes32(uint256(originalEpoch)));
        assertEq(
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id).sourcePositionEpoch,
            originalEpoch
        );
        _corruptEntitlement(id, backing + 1);
        vm.warp(request.bounds.validUntil + 1);
        router.expireOrder(id);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), margin, "old backing cannot change new position pledge");
        assertEq(clearinghouse.getAccountUsdcBuckets(ACCOUNT).freeSettlementUsdc, backing);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
    }

}

contract DepositFreeCarryTest is DepositFreeCloseTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.baseCarryBps = 1000;
    }

    function test_CommitmentCarryIncludedOnceAndBoundedBeforeAdmission() public {
        _openNormally(CfdTypes.Side.SHORT, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE, false);
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, KEEPER, PRICE, uint64(vm.getBlockTimestamp()));
        assertGt(preview.commitment.carryCollectedUsdc, 0);
        assertEq(preview.assessment.carryUsdc, preview.commitment.carryCollectedUsdc);
        uint256 custody = clearinghouse.balanceUsdc(ACCOUNT);
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        assertEq(custody - clearinghouse.balanceUsdc(ACCOUNT), preview.commitment.carryCollectedUsdc);
        OrderV2Types.ExecutionAssessment memory actual =
            policyEvaluator.assessCommittedOrder(address(engine), id, KEEPER, PRICE, uint64(vm.getBlockTimestamp()));
        assertEq(actual.grossAccountDebitUsdc, preview.assessment.grossAccountDebitUsdc);
        assertEq(actual.actionChargeAssessedUsdc, preview.assessment.actionChargeAssessedUsdc);
    }

    function test_CommitmentGrossAndActionBoundsRollBackCarryAndReservation() public {
        _openNormally(CfdTypes.Side.SHORT, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        OrderV2Types.OrderRequest memory request = _request(CfdTypes.Side.SHORT, SIZE, false);
        CfdClosePreview.ClosePreview memory preview =
            previewer.previewClose(address(engine), ACCOUNT, request, KEEPER, PRICE, uint64(vm.getBlockTimestamp()));
        uint256 carry = preview.commitment.carryCollectedUsdc;
        assertGt(carry, 0);
        bytes32 buckets = keccak256(abi.encode(clearinghouse.getAccountUsdcBuckets(ACCOUNT)));
        uint64 nextId = router.nextCommitId();
        for (uint256 i; i < 2; ++i) {
            request.bounds.maxGrossAccountDebitUsdc =
                i == 0 ? carry + preview.executionBountyUsdc - 1 : type(uint256).max;
            request.bounds.maxActionChargeUsdc = i == 1 ? carry - 1 : type(uint256).max;
            vm.expectPartialRevert(IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector);
            vm.prank(ACCOUNT);
            router.commitOrder(request);
            assertEq(keccak256(abi.encode(clearinghouse.getAccountUsdcBuckets(ACCOUNT))), buckets);
            assertEq(router.nextCommitId(), nextId);
            assertEq(router.pendingOrderCounts(ACCOUNT), 0);
            assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        }
    }

}

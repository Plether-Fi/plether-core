// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

contract SourceBoundBountyLifecycleTest is SourceBoundBountyFixture {

    struct RiskOffState {
        uint256 pledge;
        uint256 bounty;
        uint256 free;
        uint256 pledged;
        uint64 head;
        uint256 openBounty;
        uint64 open;
        uint256 price;
        uint256 custody;
        uint256 keeper;
        uint256 treasury;
        uint256 poolCash;
        bytes32 reservation;
    }

    struct FailureState {
        uint256 originalPledge;
        uint256 bounty;
        uint256 pledged;
        uint256 custody;
        uint256 keeperBefore;
        uint64 id;
        address executor;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function testFuzz_FailurePaysOriginalFreeFundingAndRestoresOriginalPledge(
        uint96 freeSeed,
        bool shortSide,
        bool selfExecution,
        bool expiry,
        bool partialClose
    ) public {
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        _checkFailure(bound(freeSeed, 0, bounty), shortSide, selfExecution, expiry, partialClose);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FailureFundingEndpointsBothSidesAndRecipients() public {
        uint256 snap = vm.snapshotState();
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        for (uint256 i; i < 12; ++i) {
            uint256 free = i % 3 == 0 ? 0 : i % 3 == 1 ? bounty : bounty / 2 + 1;
            _checkFailure(free, i / 6 != 0, (i / 3) % 2 != 0, i % 2 != 0, false);
            assertTrue(vm.revertToState(snap));
        }
    }

    function _checkFailure(
        uint256 free,
        bool shortSide,
        bool selfExecution,
        bool expiry,
        bool partialClose
    ) internal {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        FailureState memory state;
        state.originalPledge = _bountyPosition(side);
        state.bounty = router.closeOrderExecutionBountyUsdc();
        state.pledged = state.bounty - free;
        if (free != 0) {
            _fundTrader(BOUNTY_TRADER, free);
        }
        state.custody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        state.keeperBefore = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        OrderV3Types.OrderRequest memory request =
            _bountyRequest(side, true, partialClose ? BOUNTY_SIZE / 2 : BOUNTY_SIZE, 0);
        if (!expiry) {
            request.targetPrice = shortSide ? 2e8 : 1;
        }
        vm.prank(BOUNTY_TRADER);
        state.id = router.commitOrder(request);
        IMarginClearinghouse.BountyReservation memory reservation = _bountyReservation(state.id);
        assertEq(reservation.freeFundedUsdc, free);
        assertEq(reservation.pledgeFundedUsdc, state.pledged);
        assertEq(reservation.sourcePositionEpoch, state.pledged == 0 ? 0 : 1);
        assertEq(router.lifecycleBook().sourcePositionEpoch(state.id), state.pledged == 0 ? 0 : 1);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), state.originalPledge - state.pledged);
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), state.pledged);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), state.custody);
        state.executor = selfExecution ? BOUNTY_TRADER : BOUNTY_KEEPER;
        OrderV3Types.OrderReceipt memory receipt = expiry
            ? _bountyExpire(state.id, state.executor)
            : _bountyExecute(state.id, BOUNTY_PRICE, state.executor, OrderV3Types.LifecycleStatus.Failed);
        if (!expiry) {
            assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Slippage));
        }
        assertEq(receipt.bounty.bountyEntitlementUsdc, state.bounty);
        assertEq(receipt.bounty.bountyPaidUsdc, free);
        assertEq(receipt.bounty.bountyRefundedUsdc, state.pledged);
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(receipt.bounty.bountyRetainedUsdc, 0);
        assertEq(receipt.commitment.bountyFromFreeUsdc, free);
        assertEq(receipt.commitment.bountyFromPledgeUsdc, state.pledged);
        OrderV3Types.BountyDisposition disposition = free == 0
            ? (state.pledged == 0
                    ? OrderV3Types.BountyDisposition.None
                    : OrderV3Types.BountyDisposition.RefundedToAccount)
            : (state.pledged == 0
                    ? OrderV3Types.BountyDisposition.Paid
                    : OrderV3Types.BountyDisposition.PaidAndRefunded);
        assertEq(uint8(receipt.bountyDisposition), uint8(disposition));
        assertEq(receipt.bountyRecipient, free != 0 ? state.executor : state.pledged != 0 ? BOUNTY_TRADER : address(0));
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), state.originalPledge);
        assertEq(engine.positionEpoch(BOUNTY_TRADER), 1, "refund restores its original live generation");
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), state.custody - (selfExecution ? 0 : free));
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), selfExecution ? free : 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), state.keeperBefore + (selfExecution ? 0 : free));
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        assertEq(router.nextExecuteId(), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, BOUNTY_SIZE);
        _assertBountyResolved(state.id);
        uint256 afterCustody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        uint256 afterKeeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        vm.expectRevert(bytes4(keccak256("OrderRouter__OrderNotPending()")));
        vm.prank(state.executor);
        router.expireOrder(state.id);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), afterCustody);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), afterKeeper);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ZeroBountyExpiryTerminatesWithoutCredit() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.closeOrderExecutionBountyUsdc = 0;
        _setRouterConfig(config);
        _checkFailure(0, false, false, true, false);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_TrailingPledgeRejectedAtomicallyAndFreeFundedOverlapReusesAccount() public {
        _checkTrailingPledgeAdmission(true);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FirstPledgeBehindFreeFundedCloseRejectedAtomicallyAndFundedOverlapSucceeds() public {
        _checkTrailingPledgeAdmission(false);
    }

    function _checkTrailingPledgeAdmission(
        bool pledgeFundedHead
    ) internal {
        uint256 originalPledge = _bountyPosition(CfdTypes.Side.LONG);
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        if (!pledgeFundedHead) {
            _fundTrader(BOUNTY_TRADER, bounty);
        }
        uint64 first = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        assertEq(_bountyReservation(first).pledgeFundedUsdc, pledgeFundedHead ? bounty : 0);
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), pledgeFundedHead ? bounty : 0);
        _fundTrader(BOUNTY_TRADER, 100e6 + _quoteOpenOrderExecutionBountyUsdc(1000e18));
        uint64 opening = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, false, 1000e18, 100e6);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), 0);
        bytes32 beforeState = _queuedSequenceDigest(first, opening);
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, 1000e18, 0);
        vm.expectRevert(bytes4(keccak256("OrderRouter__PledgeBountyRequiresEmptyQueue()")));
        vm.prank(BOUNTY_TRADER);
        router.commitOrder(request);
        assertEq(
            _queuedSequenceDigest(first, opening),
            beforeState,
            "rejected commitment must roll back all funding/queue state"
        );
        assertEq(router.lifecycleBook().clientIntent(BOUNTY_TRADER, request.clientOrderId).orderId, 0);
        _fundTrader(BOUNTY_TRADER, bounty);
        vm.prank(BOUNTY_TRADER);
        uint64 trailing = router.commitOrder(request);
        assertEq(_bountyReservation(trailing).pledgeFundedUsdc, 0);
        assertEq(_bountyReservation(trailing).freeFundedUsdc, bounty);
        OrderV3Types.OrderReceipt memory firstReceipt =
            _bountyExecute(first, 120_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(
            firstReceipt.economics.close.pricePnlPledgeConsumedUsdc, originalPledge - (pledgeFundedHead ? bounty : 0)
        );
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), opening);
        _bountyExecute(opening, 120_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(engine.positionEpoch(BOUNTY_TRADER), 2);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), trailing);
        _bountyExecute(trailing, 120_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, 0);
    }

    function _queuedSequenceDigest(
        uint64 first,
        uint64 opening
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _bountyStateDigest(first),
                _bountyStateDigest(opening),
                clearinghouse.getOrderReservation(opening),
                engine.terminalNavSnapshot(),
                _sideState(CfdTypes.Side.LONG),
                engine.sideBorrowBaseUsdc(uint256(CfdTypes.Side.LONG)),
                engine.positionEntryCostUsdcAtoms(BOUNTY_TRADER),
                engine.unsettledCarryUsdc(BOUNTY_TRADER)
            )
        );
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_NonGlobalHeadExpiryRemovesOnlyItsOwnLinks() public {
        _bountyPosition(CfdTypes.Side.LONG);
        _fundTrader(BOUNTY_OTHER, 1000e6);
        uint64 foreign = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.SHORT, false, 1000e18, 100e6);
        uint64 pledged = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        _fundTrader(BOUNTY_TRADER, router.closeOrderExecutionBountyUsdc());
        uint64 later = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        assertEq(router.nextExecuteId(), foreign);
        _bountyExpire(pledged, BOUNTY_KEEPER);
        assertEq(router.nextExecuteId(), foreign);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), later);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 1);
        assertEq(router.pendingOrderCounts(BOUNTY_OTHER), 1);
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        _assertBountyResolved(pledged);
        _bountyExpire(foreign, BOUNTY_KEEPER);
        assertEq(router.nextExecuteId(), later);
        _bountyExpire(later, BOUNTY_KEEPER);
        assertEq(router.nextExecuteId(), 0);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_RepeatedUnderwaterFailuresCannotDrainPositionOrCreditKeeper() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        router.updateMarkPrice(_bountyPriceData(120_000_000));
        uint256 keeperBefore = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        uint256 treasuryBefore = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        int256 nav = engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc;
        for (uint256 i; i < 5; ++i) {
            uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
            assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc, nav);
            _bountyExpire(id, i % 2 == 0 ? BOUNTY_KEEPER : BOUNTY_TRADER);
            assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
            assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), 0);
            assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeperBefore);
            assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), treasuryBefore);
            assertEq(engine.terminalNavSnapshot().terminalLpPriceDeltaUsdc, nav);
            router.updateMarkPrice(_bountyPriceData(120_000_000));
        }
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_LiquidationRestoresPledgeBeforeRecoveringLosses() public {
        _bountyPosition(CfdTypes.Side.LONG);
        uint256 snap = vm.snapshotState();
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        bytes[] memory data = _mockPythUpdateData(120_000_000);
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        uint256 controlPool = usdc.balanceOf(address(pool));
        uint256 controlTreasury = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        assertGt(controlPool, poolBefore);
        assertTrue(vm.revertToState(snap));
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        data = _mockPythUpdateData(120_000_000);
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(id);
        assertEq(usdc.balanceOf(address(pool)), controlPool, "pledge remains available for LP loss recovery");
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), controlTreasury);
        assertEq(controlTreasury, treasuryBefore);
        assertEq(receipt.bounty.bountyRefundedUsdc, router.closeOrderExecutionBountyUsdc());
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(receipt.bounty.bountyPaidUsdc, 0);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        _assertBountyResolved(id);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_PledgeRestorationMakesLiquidationSolventAndRollsBackOnlyAttempt() public {
        uint256 pledge = _bountyPosition(CfdTypes.Side.LONG);
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        // 10,000 tokens: one price atom changes Long equity by 100 USDC atoms
        // and its 100-bps maintenance by one atom. Leave half a bounty of headroom.
        uint256 price = BOUNTY_PRICE + (pledge - 100e6 - bounty / 2) / 101;
        uint256 loss = (price - BOUNTY_PRICE) * 100;
        uint256 maintenance = price;
        assertGt(pledge - loss, maintenance, "independently healthy before reservation");
        assertLt(pledge - bounty - loss, maintenance, "physical pledge alone appears liquidatable");
        uint64 id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        bytes32 beforeState = _bountyStateDigest(id);
        uint256 keeperBefore = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        uint256 treasuryBefore = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        bytes[] memory data = _mockPythUpdateData(price);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        assertEq(_bountyStateDigest(id), beforeState, "healthy liquidation leaves original pledge order pending");
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeperBefore);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), treasuryBefore);
        assertEq(usdc.balanceOf(address(pool)), poolBefore);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(id)), uint8(OrderV3Types.LifecycleStatus.Pending));
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function testFuzz_SuccessStillPaysEntireCommittedBounty(
        bool shortSide,
        bool selfExecution,
        bool partialClose
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _bountyPosition(side);
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        uint256 free = bounty / 3;
        _fundTrader(BOUNTY_TRADER, free);
        uint64 id = _bountyCommit(BOUNTY_TRADER, side, true, partialClose ? BOUNTY_SIZE / 2 : BOUNTY_SIZE, 0);
        uint256 keeperBefore = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        OrderV3Types.OrderReceipt memory receipt = _bountyExecute(
            id, BOUNTY_PRICE, selfExecution ? BOUNTY_TRADER : BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed
        );
        assertEq(receipt.bounty.bountyEntitlementUsdc, bounty);
        assertEq(receipt.bounty.bountyPaidUsdc, bounty);
        assertEq(receipt.bounty.bountyRefundedUsdc, 0);
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeperBefore + (selfExecution ? 0 : bounty));
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, partialClose ? BOUNTY_SIZE / 2 : 0);
        _assertBountyResolved(id);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_RiskOffPeerRefundPersistsWhenInnerPledgeRestorationMakesLiquidationSolvent() public {
        RiskOffState memory state;
        state.pledge = _bountyPosition(CfdTypes.Side.LONG);
        state.bounty = router.closeOrderExecutionBountyUsdc();
        state.free = state.bounty / 4;
        state.pledged = state.bounty - state.free;
        _fundTrader(BOUNTY_TRADER, state.free);
        state.head = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        state.openBounty = _quoteOpenOrderExecutionBountyUsdc(1000e18);
        _fundTrader(BOUNTY_TRADER, 100e6 + state.openBounty);
        state.open = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, false, 1000e18, 100e6);
        routerAdmin.pause();
        state.price = BOUNTY_PRICE + (state.pledge - 100e6 - state.pledged / 2) / 101;
        assertGt(state.pledge - (state.price - BOUNTY_PRICE) * 100, state.price);
        assertLt(state.pledge - state.pledged - (state.price - BOUNTY_PRICE) * 100, state.price);
        state.custody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        state.keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        state.treasury = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        state.poolCash = usdc.balanceOf(address(pool));
        state.reservation = keccak256(abi.encode(_bountyReservation(state.head)));
        bytes[] memory data = _mockPythUpdateData(state.price);
        // This specifically reaches the new inner frame, not only the outer risk-off health shortcut.
        vm.expectCall(address(engine), abi.encodeWithSelector(engine.liquidatePosition.selector, BOUNTY_TRADER));
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        router.executeLiquidation(BOUNTY_TRADER, data);
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(state.open);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.RiskOff));
        assertEq(receipt.bounty.bountyRefundedUsdc, state.openBounty);
        assertEq(receipt.bounty.bountyPaidUsdc, 0);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), 100e6 + state.openBounty);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), state.pledge - state.pledged);
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), state.pledged);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), state.bounty);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), state.custody);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), state.keeper);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), state.treasury);
        assertEq(usdc.balanceOf(address(pool)), state.poolCash);
        assertEq(keccak256(abi.encode(_bountyReservation(state.head))), state.reservation);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 1);
        assertEq(router.nextExecuteId(), state.head);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), state.head);
        (, uint64 next) = router.getPendingOrderView(state.head);
        assertEq(next, 0);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(state.head)), uint8(OrderV3Types.LifecycleStatus.Pending));
        _assertBountyResolved(state.open);
    }

    /// @dev regression; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function testFuzz_FadAndFrozenSlippageFailureRestorePledge(
        bool frozen,
        bool shortSide,
        bool selfExecution
    ) public {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 pledge = _bountyPosition(side);
        vm.warp(frozen ? 1_709_985_600 : 1_709_934_300);
        router.updateMarkPrice(_bountyPriceData(BOUNTY_PRICE));
        assertTrue(engine.isFadWindow());
        assertEq(engine.isOracleFrozen(), frozen);
        uint256 bounty = router.closeOrderExecutionBountyUsdc();
        uint256 free = bounty / 3;
        _fundTrader(BOUNTY_TRADER, free);
        uint256 keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        OrderV3Types.OrderRequest memory request = _bountyRequest(side, true, BOUNTY_SIZE, 0);
        request.targetPrice = shortSide ? 2e8 : 1;
        vm.prank(BOUNTY_TRADER);
        uint64 id = router.commitOrder(request);
        OrderV3Types.OrderReceipt memory receipt = _bountyExecute(
            id, BOUNTY_PRICE, selfExecution ? BOUNTY_TRADER : BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Failed
        );
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Slippage));
        assertEq(
            uint8(receipt.executionMode),
            uint8(frozen ? OrderV3Types.ExecutionMode.Frozen : OrderV3Types.ExecutionMode.Fad)
        );
        assertEq(receipt.bounty.bountyPaidUsdc, free);
        assertEq(receipt.bounty.bountyRefundedUsdc, bounty - free);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), pledge);
        assertEq(clearinghouse.getFreeBuyingPowerUsdc(BOUNTY_TRADER), selfExecution ? free : 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), keeper + (selfExecution ? 0 : free));
        assertEq(clearinghouse.collectibleCloseEscrowUsdc(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        _assertBountyResolved(id);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdClosePreview} from "@plether/perps/CfdClosePreview.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

/// @notice Flat-open floors stay funded until a terminal outcome, using the canonical pending intent only.
contract OrderSettlementFloorTest is SourceBoundBountyFixture {

    uint256 private constant FUNDING = 1000e6;
    uint256 private constant MINIMUM = 700e6;
    uint256 private constant GROSS = 200e6;

    function setUp() public override {
        super.setUp();
        _fundTrader(BOUNTY_TRADER, FUNDING);
    }

    function _request() private view returns (OrderV3Types.OrderRequest memory r) {
        r = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 250e6);
        r.bounds.minPostSettlementBalanceUsdc = MINIMUM;
        r.bounds.maxGrossAccountDebitUsdc = GROSS;
    }

    function _commit(
        OrderV3Types.OrderRequest memory r
    ) private returns (uint64) {
        vm.prank(BOUNTY_TRADER);
        return router.commitOrder(r);
    }

    function _expectFloor(
        uint64 id,
        uint256 amount,
        bool marginApi
    ) private {
        uint256 balance = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        uint256 wallet = usdc.balanceOf(BOUNTY_TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__SettlementFloorWithdrawal.selector, id, balance - amount, MINIMUM, GROSS
            )
        );
        vm.prank(BOUNTY_TRADER);
        if (marginApi) {
            clearinghouse.withdrawMargin(amount);
        } else {
            clearinghouse.withdraw(BOUNTY_TRADER, amount);
        }
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), balance, "provisional debit rolls back");
        assertEq(usdc.balanceOf(BOUNTY_TRADER), wallet);
    }

    function testFuzz_WithdrawalFloorBothApis(
        uint96 extra,
        bool marginApi
    ) public {
        extra = uint96(bound(extra, 0, 100e6));
        _fundTrader(BOUNTY_TRADER, uint256(extra) + 1);
        uint64 id = _commit(_request());
        uint256 surplus = FUNDING + extra + 1 - MINIMUM - GROSS;
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), surplus);
        _expectFloor(id, surplus + 1, marginApi);
        vm.prank(BOUNTY_TRADER);
        if (marginApi) {
            clearinghouse.withdrawMargin(surplus);
        } else {
            clearinghouse.withdraw(BOUNTY_TRADER, surplus);
        }
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), MINIMUM + GROSS);
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), 0);
        _expectFloor(id, 1, !marginApi);
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdrawMargin(0);
    }

    function test_CommitFundingEqualityAndAdjacentAtomsRollbackAllReservations() public {
        for (uint256 offset; offset < 3; ++offset) {
            uint256 snapshot = vm.snapshotState();
            OrderV3Types.OrderRequest memory r = _request();
            r.bounds.minPostSettlementBalanceUsdc = FUNDING - GROSS + offset - 1;
            uint64 expectedId = router.nextCommitId();
            if (offset == 2) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IOrderRouterErrors.OrderRouter__SettlementFloorFunding.selector,
                        expectedId,
                        FUNDING,
                        r.bounds.minPostSettlementBalanceUsdc,
                        GROSS
                    )
                );
                _commit(r);
                assertEq(router.nextCommitId(), expectedId);
                assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
                assertEq(clearinghouse.totalBountyReservationsUsdc(BOUNTY_TRADER), 0);
                assertEq(clearinghouse.getAccountUsdcBuckets(BOUNTY_TRADER).totalLockedMarginUsdc, 0);
            } else {
                uint64 id = _commit(r);
                assertEq(id, expectedId);
                assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 1);
            }
            assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), FUNDING);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_UnboundedGrossPositiveMinimumRejectedAsUnfundable() public {
        OrderV3Types.OrderRequest memory r = _request();
        r.bounds.maxGrossAccountDebitUsdc = type(uint256).max;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__SettlementFloorFunding.selector,
                router.nextCommitId(),
                FUNDING,
                MINIMUM,
                type(uint256).max
            )
        );
        _commit(r);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
    }

    function test_MinimumAboveCustodyRejectsWithoutArithmeticPanic() public {
        OrderV3Types.OrderRequest memory request = _request();
        request.bounds.minPostSettlementBalanceUsdc = type(uint256).max;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderRouterErrors.OrderRouter__SettlementFloorFunding.selector,
                router.nextCommitId(),
                FUNDING,
                type(uint256).max,
                GROSS
            )
        );
        _commit(request);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), FUNDING);
    }

    function test_FloorBlocksLaterOrdersButExactReplayIsIdempotent() public {
        OrderV3Types.OrderRequest memory original = _request();
        uint64 id = _commit(original);
        OrderV3Types.OrderRequest memory later = _request();
        later.bounds.minPostSettlementBalanceUsdc = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__SettlementFloorOrderPending.selector, id)
        );
        _commit(later);
        // Exact replay bypasses fresh timing, flatness, queue and funding checks.
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(_commit(original), id);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 1);
        _bountyExpire(id, BOUNTY_KEEPER);
        assertEq(_commit(original), id);
    }

    function test_PositiveFloorRejectsOverlapIncreaseAndBothCloseSizes() public {
        OrderV3Types.OrderRequest memory ordinary = _request();
        ordinary.bounds.minPostSettlementBalanceUsdc = 0;
        uint64 id = _commit(ordinary);
        OrderV3Types.OrderRequest memory overlapping = _request();
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported.selector);
        _commit(overlapping);
        _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        for (uint8 action; action < 3; ++action) {
            OrderV3Types.OrderRequest memory r = _request();
            if (action != 0) {
                r.isClose = true;
                r.marginDelta = 0;
                r.targetPrice = 2e8;
                r.sizeDelta = action == 1 ? BOUNTY_SIZE / 2 : BOUNTY_SIZE;
            }
            vm.expectRevert(IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported.selector);
            _commit(r);
        }
        // The former zero-floor close API remains admitted.
        OrderV3Types.OrderRequest memory close = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        _commit(close);
    }

    function test_DepositsAndOtherAccountKeeperCreditsIncreaseOnlySurplus() public {
        _fundTrader(BOUNTY_OTHER, FUNDING);
        uint64 other = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.LONG, false, BOUNTY_SIZE, 250e6);
        uint64 id = _commit(_request());
        _fundTrader(BOUNTY_TRADER, 50e6);
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), 150e6);
        uint256 bounty = router.lifecycleBook().pendingIntent(other).executionBountyUsdc;
        _bountyExecute(other, BOUNTY_PRICE, BOUNTY_TRADER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), 150e6 + bounty);
        _expectFloor(id, 150e6 + bounty + 1, false);
    }

    function test_UnrelatedAccountWithdrawalsAreNotConstrained() public {
        _commit(_request());
        _fundTrader(BOUNTY_OTHER, 123e6);
        vm.prank(BOUNTY_OTHER);
        clearinghouse.withdrawMargin(123e6);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_OTHER), 0);
    }

    function test_AttachedProtectionUsesSameFloorAndExecutionReleasesIt() public {
        uint256 price = 95_000_000;
        router.updateMarkPrice(_mockPythUpdateData(price));
        IPositionProtectionActions actions = IPositionProtectionActions(address(router.positionProtectionBook()));
        PositionProtectionTypes.PositionProtectionParams memory params;
        params.takeProfitTriggerPrice = 90_000_000;
        params.stopLossTriggerPrice = 110_000_000;
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max
        });
        OrderV3Types.OrderRequest memory request = _request();
        vm.prank(BOUNTY_TRADER);
        (uint64 id,) = actions.commitOpenOrderWithProtection(request, params);
        _expectFloor(id, 100e6 + 1, true);
        _bountyExecute(id, price, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        assertGt(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), 100e6);
    }

    function testFuzz_SuccessConsumesDeclaredAllowanceAndReleasesFloor(
        bool self
    ) public {
        OrderV3Types.OrderRequest memory request = _request();
        uint64 id = _commit(request);
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdrawMargin(100e6);
        OrderV3Types.OrderReceipt memory receipt = _bountyExecute(
            id, BOUNTY_PRICE, self ? BOUNTY_TRADER : BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed
        );
        assertGe(receipt.economics.postSettlementBalanceUsdc, MINIMUM);
        assertLe(receipt.economics.grossAccountDebitUsdc, GROSS);
        assertEq(_commit(request), id, "terminal replay bypasses new live-position admission");
        _assertBountyResolved(id);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        uint256 available = engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER);
        assertGt(available, 0);
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdrawMargin(available);
    }

    function test_RetryableAndReceiptFailuresPreserveFloorUntilSuccess() public {
        for (uint256 fault; fault < 2; ++fault) {
            uint256 snapshot = vm.snapshotState();
            uint64 id = _commit(_request());
            bytes32 intent = keccak256(abi.encode(router.lifecycleBook().pendingIntent(id)));
            if (fault == 0) {
                vm.mockCallRevert(
                    address(engine),
                    abi.encodeWithSelector(engine.processOrderTyped.selector),
                    abi.encodeWithSignature("Panic(uint256)", 0x11)
                );
            } else {
                vm.mockCallRevert(
                    address(router.lifecycleBook()),
                    abi.encodeWithSelector(IOrderLifecycleBook.finalize.selector),
                    hex"12345678"
                );
            }
            bytes[] memory data = _mockPythUpdateData(BOUNTY_PRICE);
            vm.prank(BOUNTY_KEEPER);
            OrderV3Types.ExecutionResult memory result = router.executeOrder(id, data);
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
            assertEq(
                uint8(result.pendingReason),
                uint8(fault == 0 ? OrderV3Types.PendingReason.EngineFailure : OrderV3Types.PendingReason.ReceiptFailure)
            );
            assertEq(keccak256(abi.encode(router.lifecycleBook().pendingIntent(id))), intent);
            assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), FUNDING);
            _expectFloor(id, 100e6 + 1, false);
            vm.clearMockedCalls();
            _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_AllReachableFailureReasonsReleaseFloorAndReservations() public {
        for (uint8 reason; reason < 7; ++reason) {
            uint256 snapshot = vm.snapshotState();
            OrderV3Types.OrderRequest memory r = _request();
            if (reason == 0) {
                r.targetPrice = 2e8;
            }
            if (reason == 1) {
                r.bounds.maxActionChargeUsdc = 0;
            }
            if (reason == 2) {
                r.bounds.allowedExecutionModes = 2;
            }
            if (reason == 5) {
                IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
                config.maxPendingOrders += 1;
                routerAdmin.proposeRouterConfig(config);
                vm.warp(vm.getBlockTimestamp() + 72 hours + 1);
                r = _request();
            }
            uint64 id = _commit(r);
            OrderV3Types.OrderReceipt memory receipt;
            if (reason == 3) {
                receipt = _bountyExpire(id, BOUNTY_KEEPER);
            } else if (reason == 4) {
                routerAdmin.pause();
                vm.recordLogs();
                router.clearRiskOffOrder(id);
                receipt = _bountyReceipt(id);
            } else {
                if (reason == 5) {
                    routerAdmin.finalizeRouterConfig();
                }
                if (reason == 6) {
                    vm.mockCallRevert(
                        address(engine),
                        abi.encodeWithSelector(engine.processOrderTyped.selector),
                        abi.encodeWithSelector(
                            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, uint8(1), uint8(5), false
                        )
                    );
                }
                receipt = _bountyExecute(id, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Failed);
            }
            OrderV3Types.TerminalReason expected = reason == 0
                ? OrderV3Types.TerminalReason.Slippage
                : reason == 1
                    ? OrderV3Types.TerminalReason.ConstraintViolation
                    : reason == 2
                        ? OrderV3Types.TerminalReason.ExecutionModeDisallowed
                        : reason == 3
                            ? OrderV3Types.TerminalReason.Expired
                            : reason == 4
                                ? OrderV3Types.TerminalReason.RiskOff
                                : reason == 5
                                    ? OrderV3Types.TerminalReason.ConfigMismatch
                                    : OrderV3Types.TerminalReason.PlannerRejected;
            assertEq(uint8(receipt.reason), uint8(expected));
            vm.clearMockedCalls();
            assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
            assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
            _assertBountyResolved(id);
            uint256 balance = clearinghouse.balanceUsdc(BOUNTY_TRADER);
            assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), balance);
            vm.prank(BOUNTY_TRADER);
            clearinghouse.withdrawMargin(balance);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_AdmissionAwareClosePreviewsRejectPositiveMinimum() public {
        CfdClosePreview preview = new CfdClosePreview();
        OrderV3Types.OrderRequest memory r = _request();
        r.isClose = true;
        r.marginDelta = 0;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported.selector);
        preview.previewClose(address(engine), BOUNTY_TRADER, r, BOUNTY_KEEPER, BOUNTY_PRICE);
    }

    function test_GasWithdrawWithoutFloor() public {
        vm.prank(BOUNTY_TRADER);
        uint256 gasBefore = gasleft();
        clearinghouse.withdrawMargin(1e6);
        uint256 measured = gasBefore - gasleft();
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), FUNDING - 1e6);
        emit log_named_uint("withdraw_without_settlement_floor", measured);
    }

    function test_GasWithdrawWithFundedFloor() public {
        _commit(_request());
        vm.prank(BOUNTY_TRADER);
        uint256 gasBefore = gasleft();
        clearinghouse.withdrawMargin(1e6);
        uint256 measured = gasBefore - gasleft();
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), FUNDING - 1e6);
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), 99e6);
        emit log_named_uint("withdraw_with_settlement_floor", measured);
    }

    function assertFloorFundedForTest() external view {
        uint64 id = router.accountHeadOrderId(BOUNTY_TRADER);
        OrderV3Types.ExecutionBounds memory policy = router.lifecycleBook().pendingPolicy(id);
        uint256 balance = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        require(
            balance >= policy.minPostSettlementBalanceUsdc
                && balance - policy.minPostSettlementBalanceUsdc >= policy.maxGrossAccountDebitUsdc,
            "funded floor violated"
        );
    }

    function test_FaultControlBypassedWithdrawalGuardBreaksFundingInvariant() public {
        _commit(_request());
        this.assertFloorFundedForTest();
        vm.mockCall(address(engine), abi.encodeWithSelector(engine.checkWithdraw.selector), bytes(""));
        vm.prank(BOUNTY_TRADER);
        clearinghouse.withdrawMargin(100e6 + 1);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "funded floor violated"));
        this.assertFloorFundedForTest();
        vm.clearMockedCalls();
    }

    function test_FlatClaimCreditIncreasesSurplusWithoutCarryCollection() public {
        uint64 open = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, false, BOUNTY_SIZE, 250e6);
        _bountyExecute(open, BOUNTY_PRICE, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        uint64 close = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        uint256 externalShock = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), externalShock);
        _bountyExecute(close, 90_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
        assertEq(engine.traderClaimBalanceUsdc(BOUNTY_TRADER), 996_400_000);
        usdc.mint(address(pool), externalShock);
        assertFalse(engine.degradedMode(), "flat account leaves no directional liability");
        uint64 id = _commit(_request());
        uint256 beforeBalance = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        uint256 beforeSurplus = engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER);
        vm.prank(BOUNTY_TRADER);
        engine.settleTraderClaim(BOUNTY_TRADER);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), beforeBalance + 996_400_000);
        assertEq(engineAccountLens.getWithdrawableUsdc(BOUNTY_TRADER), beforeSurplus + 996_400_000);
        assertEq(engine.unsettledCarryUsdc(BOUNTY_TRADER), 0);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), id);
        _expectFloor(id, beforeSurplus + 996_400_000 + 1, true);
    }

}

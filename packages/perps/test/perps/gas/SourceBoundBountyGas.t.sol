// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Production-codegen gas selection. Public V3 fixture transitions; zero carry/VPI isolate
///      order processing with unpaid zero-value close records.
///      Request/oracle construction and cold-state preparation precede measurement; all proof checks follow it.
///      Reported gas excludes transaction intrinsic/calldata gas, refunds and external oracle service charges.
contract SourceBoundBountyGasTest is SourceBoundBountyFixture {

    struct BeforeState {
        uint256 pledge;
        uint256 custody;
        uint256 keeper;
        uint256 treasury;
        uint256 poolCash;
        uint256 bounty;
        uint256 free;
        uint256 pledged;
        uint64 id;
    }

    struct LiquidationSetup {
        BeforeState state;
        uint64[] ids;
        uint64 firstOther;
        uint64 lastOther;
        uint256 otherCustody;
        uint256 otherReserve;
    }

    function test_Gas_SourceBoundCommitAllPledge() public {
        BeforeState memory before = _positionState();
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        uint64 expectedId = router.nextCommitId();
        _coolBountyProtocol();
        vm.prank(BOUNTY_TRADER);
        uint256 start = gasleft();
        uint64 id = router.commitOrder(request);
        uint256 used = start - gasleft();

        assertEq(id, expectedId);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(id)), uint8(OrderV3Types.LifecycleStatus.Pending));
        IMarginClearinghouse.BountyReservation memory reserved = _bountyReservation(id);
        assertEq(reserved.amountUsdc, before.bounty);
        assertEq(reserved.freeFundedUsdc, 0);
        assertEq(reserved.amountUsdc, 0);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), before.pledge - before.bounty);

        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), before.bounty);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), before.custody);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), before.keeper);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 1);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), id);
        assertEq(router.nextExecuteId(), id);
        router.lifecycleBook().validateBountyFunding(id);
        emit log_named_uint("source_bound_commit_all_pledge", used);
    }

    function test_Gas_SourceBoundMixedFailure() public {
        BeforeState memory before = _positionState();
        before.free = before.bounty / 3;
        before.pledged = before.bounty - before.free;

        before.custody += before.free;
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        request.targetPrice = 1;
        vm.prank(BOUNTY_TRADER);
        before.id = router.commitOrder(request);
        assertEq(_bountyReservation(before.id).amountUsdc, 0);
        bytes[] memory data = _mockPythUpdateData(BOUNTY_PRICE);
        _coolBountyProtocol();
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        uint256 start = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(before.id, data);
        uint256 used = start - gasleft();

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(before.id);
        assertEq(receipt.orderId, result.orderId);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Slippage));
        _assertFailure(before, receipt);
        emit log_named_uint("source_bound_failure_mixed", used);
    }

    function test_Gas_SourceBoundExpiryAllPledge() public {
        BeforeState memory before = _positionState();
        before.pledged = before.bounty;
        before.id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE, 0);
        assertEq(_bountyReservation(before.id).amountUsdc, 0);
        vm.warp(uint256(router.lifecycleBook().orderTiming(before.id).executionDeadline) + 1);
        _coolBountyProtocol();
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        uint256 start = gasleft();
        OrderV3Types.ExecutionResult memory result = router.expireOrder(before.id);
        uint256 used = start - gasleft();

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(before.id);
        assertEq(receipt.orderId, result.orderId);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Expired));
        _assertFailure(before, receipt);
        emit log_named_uint("source_bound_expiry_all_pledge", used);
    }

    function test_Gas_SourceBoundSuccessfulPartialClose() public {
        _measureSuccess(BOUNTY_SIZE / 2, "source_bound_success_partial_close");
    }

    function test_Gas_SourceBoundSuccessfulFullClose() public {
        _measureSuccess(BOUNTY_SIZE, "source_bound_success_full_close");
    }

    function test_Gas_SourceBoundLiquidationOnePendingFitsDefaultBudget() public {
        _measureLiquidation(1, "source_bound_liquidation_one_pending");
    }

    function test_Gas_SourceBoundLiquidation32PendingFitsDefaultBudgetAndPreservesOtherFifo() public {
        _measureLiquidation(32, "source_bound_liquidation_32_pending");
    }

    function test_Gas_SourceBoundMixedAccountBatchExecutesEveryOrder() public {
        BeforeState memory before = _positionState();
        _fundTrader(BOUNTY_OTHER, 100e6);
        uint64[] memory ids = new uint64[](3);
        ids[0] = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        ids[1] = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.SHORT, false, 1000e18, 50e6);

        ids[2] = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, BOUNTY_SIZE / 2, 0);
        uint256 totalBounty;
        for (uint256 i; i < ids.length; ++i) {
            totalBounty += _bountyReservation(ids[i]).amountUsdc;
        }
        assertEq(_bountyReservation(ids[0]).amountUsdc, 0);
        assertEq(_bountyReservation(ids[2]).amountUsdc, 0);
        bytes[] memory data = _mockPythUpdateData(BOUNTY_PRICE);
        _coolBountyProtocol();
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        uint256 start = gasleft();
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(ids[2], data);
        uint256 used = start - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(result.terminalCount, ids.length, "success denominator is fixed to requested orders");
        assertEq(uint8(result.stopReason), uint8(OrderV3Types.PendingReason.None));
        assertEq(result.nextOrderId, 0);
        assertEq(router.nextExecuteId(), 0);
        for (uint256 i; i < ids.length; ++i) {
            OrderV3Types.OrderReceipt memory receipt = _receiptIn(logs, ids[i]);
            assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
            assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Executed));
            assertEq(receipt.bounty.bountyPaidUsdc, receipt.bounty.bountyEntitlementUsdc);
            assertEq(receipt.bounty.bountyRefundedUsdc, 0);
            assertEq(receipt.bountyRecipient, receipt.bountyUsdc == 0 ? address(0) : BOUNTY_KEEPER);
            _assertBountyResolved(ids[i]);
        }
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), before.keeper + totalBounty);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), before.custody - before.bounty - 4e6);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_OTHER), 100e6 - _quoteOpenOrderExecutionBountyUsdc(1000e18) - 400_000);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), before.treasury + 4_400_000);
        assertEq(engine.traderClaimBalanceUsdc(BOUNTY_TRADER), 0);
        assertEq(engine.traderClaimBalanceUsdc(BOUNTY_OTHER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_OTHER), 0);

        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_OTHER), 0);
        (uint256 traderSize,,,,,,) = engine.positions(BOUNTY_TRADER);
        (uint256 otherSize,,,, CfdTypes.Side otherSide,,) = engine.positions(BOUNTY_OTHER);
        assertEq(traderSize, 0);
        assertEq(otherSize, 1000e18);
        assertEq(uint8(otherSide), uint8(CfdTypes.Side.SHORT));
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_OTHER), 48_600_000);
        assertEq(clearinghouse.liquidationReserveUsdc(BOUNTY_OTHER), 1e6);
        assertEq(usdc.balanceOf(address(pool)), before.poolCash);
        emit log_named_uint("source_bound_mixed_account_batch_total", used);
        emit log_named_uint("source_bound_mixed_account_batch_per_order", used / ids.length);
    }

    function _positionState() private returns (BeforeState memory before) {
        before.pledge = _bountyPosition(CfdTypes.Side.LONG);
        before.bounty = 0;
        before.custody = clearinghouse.balanceUsdc(BOUNTY_TRADER);
        before.keeper = clearinghouse.balanceUsdc(BOUNTY_KEEPER);
        before.treasury = clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT);
        before.poolCash = usdc.balanceOf(address(pool));
        assertEq(before.pledge, 236e6, "250 margin less four fee and ten liquidation reserve");
        assertEq(before.custody, 246e6);
        assertEq(clearinghouse.liquidationReserveUsdc(BOUNTY_TRADER), 10e6);
    }

    function _assertFailure(
        BeforeState memory before,
        OrderV3Types.OrderReceipt memory receipt
    ) private view {
        assertEq(receipt.bounty.bountyEntitlementUsdc, before.bounty);
        assertEq(receipt.bounty.bountyPaidUsdc, before.free);
        assertEq(receipt.bounty.bountyRefundedUsdc, before.pledged);
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(receipt.bountyRecipient, address(0));
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), before.keeper + before.free);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), before.custody - before.free);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), before.pledge);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), before.treasury);
        assertEq(usdc.balanceOf(address(pool)), before.poolCash);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, BOUNTY_SIZE);
        _assertTraderTerminal(before.id);
    }

    function _measureSuccess(
        uint256 size,
        string memory label
    ) private {
        BeforeState memory before = _positionState();
        before.id = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, size, 0);
        assertEq(_bountyReservation(before.id).amountUsdc, 0);
        uint256 fee = (size * BOUNTY_PRICE / 1e20) * 4 / 10_000;
        bytes[] memory data = _mockPythUpdateData(BOUNTY_PRICE);
        _coolBountyProtocol();
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        uint256 start = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(before.id, data);
        uint256 used = start - gasleft();

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        OrderV3Types.OrderReceipt memory receipt = _bountyReceipt(before.id);
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Executed));
        assertEq(receipt.bounty.bountyPaidUsdc, before.bounty);
        assertEq(receipt.bounty.bountyRefundedUsdc, 0);
        assertEq(receipt.bounty.bountyForfeitedUsdc, 0);
        assertEq(receipt.bountyRecipient, receipt.bountyUsdc == 0 ? address(0) : BOUNTY_KEEPER);
        assertEq(receipt.economics.executionFeeUsdc, fee);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), before.custody - before.bounty - fee);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), before.keeper + before.bounty);
        assertEq(clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT), before.treasury + fee);
        assertEq(usdc.balanceOf(address(pool)), before.poolCash);
        (uint256 remaining,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(remaining, BOUNTY_SIZE - size);
        assertEq(
            clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER),
            (before.pledge - before.bounty) * (BOUNTY_SIZE - size) / BOUNTY_SIZE
        );
        assertEq(clearinghouse.liquidationReserveUsdc(BOUNTY_TRADER), (BOUNTY_SIZE - size) / 1e15);
        _assertTraderTerminal(before.id);
        emit log_named_uint(label, used);
    }

    function _assertTraderTerminal(
        uint64 id
    ) private view {
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(engine.traderClaimBalanceUsdc(BOUNTY_TRADER), 0);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        assertEq(router.nextExecuteId(), 0);
        _assertBountyResolved(id);
    }

    function _liquidationSetup(
        uint256 count
    ) private returns (LiquidationSetup memory setup) {
        // Admit 100-token closes through the public risk policy: minimum notional is minBounty / bountyBps.
        // The 10,000-token position still reserves ten USDC, so its independent accounting vectors are unchanged.
        ICfdEngineAdminHost.EngineRiskConfig memory riskConfig = _engineRiskConfig();
        riskConfig.riskParams.minBountyUsdc = 100_000;
        engineAdmin.proposeRiskConfig(riskConfig);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxPendingOrders = 32;
        _setRouterConfig(config);
        engineAdmin.finalizeRiskConfig();
        setup.state = _positionState();
        setup.ids = new uint64[](count);
        setup.ids[0] = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, 100e18, 0);
        assertEq(_bountyReservation(setup.ids[0]).amountUsdc, 0);
        if (count > 1) {
            _fundTrader(BOUNTY_OTHER, 100e6);
            setup.firstOther = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.LONG, false, 100e18, 10e6);
            for (uint256 i = 1; i < count; ++i) {
                setup.ids[i] = _bountyCommit(BOUNTY_TRADER, CfdTypes.Side.LONG, true, 100e18, 0);
                assertEq(_bountyReservation(setup.ids[i]).amountUsdc, 0);
                if (i == count / 2) {
                    setup.lastOther = _bountyCommit(BOUNTY_OTHER, CfdTypes.Side.LONG, false, 100e18, 10e6);
                }
            }
            setup.otherCustody = clearinghouse.balanceUsdc(BOUNTY_OTHER);
            setup.otherReserve = clearinghouse.actionReserveUsdc(BOUNTY_OTHER);
        }
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), count);

        assertEq(router.minEngineGas(), 600_000, "retain configured production Engine allowance");
    }

    function _measureLiquidation(
        uint256 count,
        string memory label
    ) private {
        LiquidationSetup memory setup = _liquidationSetup(count);
        address[] memory accounts = new address[](2);
        accounts[0] = BOUNTY_TRADER;
        accounts[1] = address(0xB0174);
        bytes[] memory data = _mockPythUpdateData(120_000_000);
        _coolBountyProtocol();
        vm.recordLogs();
        vm.prank(BOUNTY_KEEPER);
        uint256 start = gasleft();
        uint256 next = router.executeLiquidationBatch(accounts, data);
        uint256 used = start - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(next, accounts.length, "both items must complete under unchanged per-order gas budget");
        _assertLiquidationBatchEvidence(logs, accounts);
        for (uint256 i; i < count; ++i) {
            OrderV3Types.OrderReceipt memory receipt = _receiptIn(logs, setup.ids[i]);
            assertEq(uint8(receipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
            assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.AccountLiquidated));
            assertEq(receipt.bounty.bountyPaidUsdc, 0);
            assertEq(receipt.bounty.bountyRefundedUsdc, i == 0 ? setup.state.bounty : 0);
            assertEq(receipt.bounty.bountyForfeitedUsdc, i == 0 ? 0 : setup.state.bounty);
            assertEq(receipt.bountyRecipient, address(0));
            _assertBountyResolved(setup.ids[i]);
        }
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_KEEPER), setup.state.keeper + 5e6);
        assertEq(
            clearinghouse.balanceUsdc(PROTOCOL_TREASURY_ACCOUNT),
            setup.state.treasury + (count - 1) * setup.state.bounty
        );
        assertEq(usdc.balanceOf(address(pool)), setup.state.poolCash + setup.state.pledge + 5e6);
        assertEq(clearinghouse.pnlPledgeUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(BOUNTY_TRADER), 0);
        assertEq(clearinghouse.actionReserveUsdc(BOUNTY_TRADER), 0);

        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), 0);
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), 0);
        (uint256 size,,,,,,) = engine.positions(BOUNTY_TRADER);
        assertEq(size, 0);
        if (count == 1) {
            assertEq(router.nextExecuteId(), 0);
        } else {
            assertEq(clearinghouse.balanceUsdc(BOUNTY_OTHER), setup.otherCustody);
            assertEq(clearinghouse.actionReserveUsdc(BOUNTY_OTHER), setup.otherReserve);
            assertEq(router.pendingOrderCounts(BOUNTY_OTHER), 2);
            assertEq(router.accountHeadOrderId(BOUNTY_OTHER), setup.firstOther);
            assertEq(router.nextExecuteId(), setup.firstOther);
            (, uint64 nextOther) = router.getPendingOrderView(setup.firstOther);
            assertEq(nextOther, setup.lastOther);
            assertEq(
                uint8(router.lifecycleBook().lifecycleStatus(setup.firstOther)),
                uint8(OrderV3Types.LifecycleStatus.Pending)
            );
            assertEq(
                uint8(router.lifecycleBook().lifecycleStatus(setup.lastOther)),
                uint8(OrderV3Types.LifecycleStatus.Pending)
            );
            _bountyExecute(setup.firstOther, 120_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            assertEq(router.nextExecuteId(), setup.lastOther, "other-account FIFO order survives account cleanup");
            _bountyExecute(setup.lastOther, 120_000_000, BOUNTY_KEEPER, OrderV3Types.LifecycleStatus.Executed);
            assertEq(router.nextExecuteId(), 0);
        }
        emit log_named_uint(label, used);
    }

    function _assertLiquidationBatchEvidence(
        Vm.Log[] memory logs,
        address[] memory accounts
    ) private view {
        uint256 items;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics.length == 0) {
                continue;
            }
            assertNotEq(
                logs[i].topics[0],
                IOrderRouterErrors.LiquidationBatchStopped.selector,
                "success benchmark cannot silently stop"
            );
            if (logs[i].topics[0] != IOrderRouterErrors.LiquidationBatchItem.selector) {
                continue;
            }
            uint256 index = uint256(logs[i].topics[1]);
            assertLt(index, accounts.length);
            assertEq(index, items, "each submitted item reports exactly once in order");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), accounts[index]);
            (IOrderRouterErrors.LiquidationBatchResult result, uint256 bounty, bytes4 selector) =
                abi.decode(logs[i].data, (IOrderRouterErrors.LiquidationBatchResult, uint256, bytes4));
            assertEq(
                uint8(result),
                uint8(
                    index == 0
                        ? IOrderRouterErrors.LiquidationBatchResult.Liquidated
                        : IOrderRouterErrors.LiquidationBatchResult.SkippedNoPosition
                )
            );
            assertEq(bounty, index == 0 ? 5e6 : 0);
            if (index == 0) {
                assertEq(selector, bytes4(0));
            } else {
                assertEq(selector, bytes4(keccak256("CfdEngine__NoPositionToLiquidate()")));
            }
            ++items;
        }
        assertEq(items, accounts.length);
    }

    function _receiptIn(
        Vm.Log[] memory logs,
        uint64 id
    ) private view returns (OrderV3Types.OrderReceipt memory receipt) {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(router.lifecycleBook()) || logs[i].topics.length != 4
                    || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
                    || uint256(logs[i].topics[1]) != id
            ) {
                continue;
            }
            (bytes32 hash,, uint64 time, OrderV3Types.OrderReceipt memory candidate) =
                abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
            assertEq(candidate.orderId, id);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), candidate.account);
            assertEq(logs[i].topics[3], candidate.clientOrderId);
            assertEq(router.lifecycleBook().terminalOutcome(id).receiptHash, hash);
            assertTrue(router.lifecycleBook().verifyReceipt(candidate, time));
            receipt = candidate;
            ++found;
        }
        assertEq(found, 1, "every requested order has exactly one authenticated terminal receipt");
    }

    function _coolBountyProtocol() private {
        address[] memory accounts = new address[](16);
        accounts[0] = address(router);
        accounts[1] = address(engine);
        accounts[2] = address(clearinghouse);
        accounts[3] = address(pool);
        accounts[4] = address(terminalNavBook);
        accounts[5] = address(pletherOracle);
        accounts[6] = address(baseMockPyth);
        accounts[7] = address(usdc);
        accounts[8] = address(router.lifecycleBook());
        accounts[9] = router.liquidationBatchSidecar();
        accounts[10] = address(orderExecutionSidecar);
        accounts[11] = orderExecutionSidecar.recoverySidecar();
        accounts[12] = address(router.positionProtectionBook());
        accounts[13] = address(policyEvaluator);
        accounts[14] = address(engine.planner());
        accounts[15] = address(engine.settlementSidecar());
        for (uint256 i; i < accounts.length; ++i) {
            vm.cool(accounts[i]);
        }
    }

}

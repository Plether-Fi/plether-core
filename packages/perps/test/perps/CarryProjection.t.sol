// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract CarryProjectionTest is BasePerpTest {

    using stdStorage for StdStorage;

    address private constant ACCOUNT = address(0xCA11);
    address private constant OTHER = address(0xCA12);

    function _fixture(
        bool shortSide
    ) private {
        CfdTypes.Side side = shortSide ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        _fundTrader(ACCOUNT, 6200e6);
        _open(ACCOUNT, side, 100_000e18, 5000e6, 1e8);
        _fundTrader(OTHER, 10_000e6);
        _open(OTHER, shortSide ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT, 100_000e18, 5000e6, 1e8);
        vm.startPrank(address(engine));
        clearinghouse.reserveCommittedOrderMargin(ACCOUNT, type(uint64).max, 200e6);
        clearinghouse.lockReservedSettlement(ACCOUNT, 100e6);
        clearinghouse.lockVpiRebateReserve(ACCOUNT, 50e6);
        vm.stopPrank();
    }

    function _claim(
        uint256 amount
    ) private {
        bytes32 oldHash = terminalNavBook.curveHashOf(ACCOUNT);
        stdstore.target(address(engine)).sig("traderClaimBalanceUsdc(address)").with_key(ACCOUNT).checked_write(amount);
        stdstore.target(address(engine)).sig("totalTraderClaimBalanceUsdc()").checked_write(amount);
        vm.prank(address(engine));
        terminalNavBook.syncFromEngine(ACCOUNT, oldHash);
    }

    function _arrears(
        uint256 amount
    ) private {
        stdstore.target(address(engine)).sig("unsettledCarryUsdc(address)").with_key(ACCOUNT).checked_write(amount);
    }

    function _checkpoint() private {
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(ACCOUNT);
    }

    function _snapshot(
        uint256 depth
    ) private returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.prank(address(engine));
        snap = sidecar.buildRawSnapshot(ACCOUNT, depth);
    }

    /// @dev An opposing open stops immediately after carry projection, before any trade mutation. Internal library
    ///      calls share this memory snapshot, allowing its existing full-context adapter to be compared with live state.
    function _project(
        CfdEnginePlanTypes.RawSnapshot memory snap
    ) private view returns (uint256 pending) {
        CfdTypes.Order memory order;
        order.account = ACCOUNT;
        order.sizeDelta = CfdTypes.SIZE_QUANTUM;
        order.side = snap.position.side == CfdTypes.Side.LONG ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, 1e8, uint64(block.timestamp));
        assertFalse(delta.valid);
        assertEq(
            uint256(delta.revertCode),
            uint256(
                snap.unsettledCarryUsdc > 0
                    ? CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES
                    : CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING
            )
        );
        return delta.pendingCarryUsdc;
    }

    function testFuzz_PlannerProjectionMatchesLiveCollection(
        bool shortSide,
        uint96 arrears,
        uint32 elapsed
    ) public {
        _fixture(shortSide);
        _claim(2000e6);
        _arrears(bound(arrears, 0, 12_000e6));
        vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
        _assertProjectionMatchesCollection();
    }

    function test_ProjectionBoundariesBothSides() public {
        for (uint256 side; side < 2; ++side) {
            uint256 clean = vm.snapshotState();
            _fixture(side == 1);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(ACCOUNT);
            for (uint256 scenario; scenario < 6; ++scenario) {
                uint256 state = vm.snapshotState();
                uint256 due = scenario == 0
                    ? 0
                    : scenario == 1
                        ? buckets.activePositionMarginUsdc
                        : buckets.activePositionMarginUsdc + buckets.freeSettlementUsdc / 2;
                if (scenario >= 3) {
                    due = buckets.activePositionMarginUsdc + buckets.freeSettlementUsdc;
                }
                if (scenario >= 4) {
                    due += 1e6;
                }
                _arrears(due);
                if (scenario == 5) {
                    _checkpoint(); // no available backing, with existing unpaid carry
                }
                _assertProjectionMatchesCollection();
                assertTrue(vm.revertToState(state));
            }
            assertTrue(vm.revertToState(clean));
        }
    }

    function test_ProjectionCollectsArrearsFromPreviouslyCreditedClaimsAndBounties() public {
        for (uint256 scenario; scenario < 4; ++scenario) {
            uint256 state = vm.snapshotState();
            _fixture(scenario >= 2);
            _claim(2000e6);
            _arrears(clearinghouse.pnlPledgeUsdc(ACCOUNT) + _freeSettlementUsdc(ACCOUNT) + 100e6);
            if (scenario % 2 == 0) {
                vm.prank(ACCOUNT);
                engine.settleTraderClaim(ACCOUNT);
                assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 2000e6);
            } else {
                vm.prank(address(router));
                clearinghouse.lockReservedSettlement(OTHER, 2000e6);
                vm.prank(address(router));
                engine.creditBounty(OTHER, ACCOUNT, 2000e6, 1e8, uint64(block.timestamp));
                assertEq(_freeSettlementUsdc(ACCOUNT), 2000e6);
            }
            assertEq(
                engine.unsettledCarryUsdc(ACCOUNT), 100e6, "incoming credit remains intact until a later checkpoint"
            );
            _assertProjectionMatchesCollection();
            assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
            assertTrue(vm.revertToState(state));
        }
    }

    function _assertProjectionMatchesCollection() private {
        uint256 pending = engine.unsettledCarryUsdc(ACCOUNT) + _expectedIndexedCarryUsdc(ACCOUNT);
        CfdEnginePlanTypes.RawSnapshot memory projected = _snapshot(pool.totalAssets());
        bytes32 otherBefore = keccak256(
            abi.encode(projected.position.side == CfdTypes.Side.LONG ? projected.shortSide : projected.longSide)
        );
        assertEq(_project(projected), pending, "assessed carry is retained for financial bounds");
        assertEq(
            keccak256(
                abi.encode(projected.position.side == CfdTypes.Side.LONG ? projected.shortSide : projected.longSide)
            ),
            otherBefore,
            "unselected side must remain unchanged"
        );
        _checkpoint();
        CfdEnginePlanTypes.RawSnapshot memory actual = _snapshot(pool.totalAssets());
        assertEq(keccak256(abi.encode(projected.accountBuckets)), keccak256(abi.encode(actual.accountBuckets)));
        assertEq(keccak256(abi.encode(projected.lockedBuckets)), keccak256(abi.encode(actual.lockedBuckets)));
        assertEq(projected.position.margin, actual.position.margin);
        assertEq(projected.positionBorrowBaseUsdc, actual.positionBorrowBaseUsdc);
        if (pending > 0) {
            assertEq(projected.positionLastCarryIndex, actual.positionLastCarryIndex);
        }
        assertEq(keccak256(abi.encode(projected.longSide)), keccak256(abi.encode(actual.longSide)));
        assertEq(keccak256(abi.encode(projected.shortSide)), keccak256(abi.encode(actual.shortSide)));
        assertEq(projected.poolAssetsUsdc, actual.poolAssetsUsdc);
        assertEq(projected.poolCashUsdc, actual.poolCashUsdc);
        assertEq(projected.unsettledCarryUsdc, actual.unsettledCarryUsdc);
        assertEq(projected.liquidationReserveUsdc, actual.liquidationReserveUsdc);
        assertEq(projected.actionReserveUsdc, actual.actionReserveUsdc);
        assertEq(projected.vpiRebateReserveUsdc, actual.vpiRebateReserveUsdc);
        assertEq(projected.traderClaimBalanceForAccount, actual.traderClaimBalanceForAccount);
        assertEq(projected.totalTraderClaimBalanceUsdc, actual.totalTraderClaimBalanceUsdc);
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(ACCOUNT);
        engine.terminalNavSnapshot();
    }

    function test_HypotheticalTradeDepthDoesNotChangeCarryAccrualDepth() public {
        _fixture(false);
        vm.warp(block.timestamp + 30 days);
        uint256 liveDepth = pool.totalAssets();
        uint256 hypotheticalDepth = liveDepth * 2;
        CfdEnginePlanTypes.RawSnapshot memory live = _snapshot(liveDepth);
        CfdEnginePlanTypes.RawSnapshot memory hypothetical = _snapshot(hypotheticalDepth);
        // Lens simulation supplies hypothetical cash as well as depth. Carry indexes still use the live pool.
        hypothetical.poolCashUsdc = hypotheticalDepth;
        uint256 expectedCarry = _expectedIndexedCarryUsdc(ACCOUNT);
        assertGt(expectedCarry, 0);
        assertEq(_project(live), expectedCarry);
        assertEq(_project(hypothetical), expectedCarry);
        assertEq(keccak256(abi.encode(live.accountBuckets)), keccak256(abi.encode(hypothetical.accountBuckets)));
        assertEq(live.poolAssetsUsdc, liveDepth + expectedCarry);
        assertEq(live.poolCashUsdc, liveDepth + expectedCarry);
        assertEq(hypothetical.poolAssetsUsdc, hypotheticalDepth + expectedCarry);
        assertEq(hypothetical.poolCashUsdc, hypotheticalDepth + expectedCarry);
    }

    function test_WithdrawalAndRiskViewsRetainRawDiagnostics() public {
        _fixture(false);
        _claim(2000e6);
        IMarginClearinghouse.AccountUsdcBuckets memory raw = clearinghouse.getAccountUsdcBuckets(ACCOUNT);
        uint256 terminalCap = engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).terminalPriceCollectibleCapUsdc;
        // Claims preserve price health after the margin is exhausted; half the free settlement remains withdrawable.
        uint256 carry = raw.activePositionMarginUsdc + raw.freeSettlementUsdc / 2;
        _arrears(carry);
        assertEq(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).settlementBalanceUsdc, raw.settlementBalanceUsdc);
        assertEq(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).margin, raw.activePositionMarginUsdc);
        assertEq(
            engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).activePositionMarginUsdc, raw.activePositionMarginUsdc
        );
        assertEq(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).freeSettlementUsdc, raw.freeSettlementUsdc);
        assertEq(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).terminalPriceCollectibleCapUsdc, terminalCap);
        assertEq(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).netEquityUsdc, 2000e6);
        assertFalse(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        uint256 ceiling = engineAccountLens.getWithdrawableUsdc(ACCOUNT);
        assertEq(ceiling, raw.freeSettlementUsdc - raw.freeSettlementUsdc / 2);
        bytes32 bookBefore = keccak256(abi.encode(terminalNavBook.bookState()));
        vm.expectRevert();
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, ceiling + 1);
        assertEq(keccak256(abi.encode(clearinghouse.getAccountUsdcBuckets(ACCOUNT))), keccak256(abi.encode(raw)));
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), carry);
        assertEq(keccak256(abi.encode(terminalNavBook.bookState())), bookBefore);
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, ceiling);
        assertEq(_freeSettlementUsdc(ACCOUNT), 0);
        assertEq(clearinghouse.pnlPledgeUsdc(ACCOUNT), 0);
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 0);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 2000e6);
    }

    function test_ProjectedMaintenanceAndUnpaidCarryAgreeWithLiveHealth() public {
        _fixture(true);
        uint256 margin = clearinghouse.pnlPledgeUsdc(ACCOUNT);
        _arrears(margin - 1000e6 - 1);
        assertFalse(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        assertFalse(engineLens.previewLiquidation(ACCOUNT, 1e8).liquidatable);
        assertEq(engineAccountLens.getWithdrawableUsdc(ACCOUNT), 0, "initial margin remains stricter than maintenance");
        _arrears(margin - 1000e6);
        assertTrue(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        assertTrue(engineLens.previewLiquidation(ACCOUNT, 1e8).liquidatable);
        assertEq(engineAccountLens.getWithdrawableUsdc(ACCOUNT), 0);
        _checkpoint();
        assertTrue(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        _claim(2000e6);
        assertFalse(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
        _arrears(1000e6 + _freeSettlementUsdc(ACCOUNT) + 1);
        assertTrue(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable, "claims cannot fund carry");
        assertTrue(engineLens.previewLiquidation(ACCOUNT, 1e8).liquidatable);
        assertEq(engineAccountLens.getWithdrawableUsdc(ACCOUNT), 0);
        _checkpoint();
        assertEq(engine.unsettledCarryUsdc(ACCOUNT), 1);
        assertTrue(engineAccountLens.getAccountLedgerSnapshot(ACCOUNT).liquidatable);
    }

}

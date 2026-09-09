// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Preserve MockUSDC storage while probing the Engine during its carry revenue transfer.
contract CarryNavProbeToken is MockUSDC {

    address private immutable ENGINE;
    bool private immutable FAIL_AFTER_READ;
    uint256 public blockedReads;

    constructor(
        address engine_,
        bool failAfterRead_
    ) {
        ENGINE = engine_;
        FAIL_AFTER_READ = failAfterRead_;
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (msg.sender == ENGINE) {
            (bool ok, bytes memory data) = ENGINE.staticcall(abi.encodeWithSignature("terminalNavSnapshot()"));
            require(
                !ok && bytes4(data) == ICfdEngineTypes.CfdEngine__AccountingMutationInProgress.selector,
                "transient accounting was readable"
            );
            blockedReads++;
            require(!FAIL_AFTER_READ, "downstream revert");
        }
        return super.transfer(to, amount);
    }

}

contract MarginFirstCarryAllocationTest is Test {

    function test_AllocationBoundaries() public pure {
        _check(0, 0, 0, 0);
        _check(100e6, 100e6, 0, 0);
        _check(120e6, 100e6, 20e6, 0);
        _check(170e6, 100e6, 50e6, 20e6);
    }

    function _check(
        uint256 due,
        uint256 margin,
        uint256 free,
        uint256 unpaid
    ) private pure {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(210e6, 100e6, 10e6, 20e6, 30e6);
        MarginClearinghouseAccountingLib.SettlementConsumption memory c =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, due);
        assertEq(c.activeMarginConsumedUsdc, margin);
        assertEq(c.freeSettlementConsumedUsdc, free);
        assertEq(c.uncoveredUsdc, unpaid);
        assertEq(c.otherLockedMarginConsumedUsdc, 0);
    }

    function testFuzz_AllocationConservesAndProtectsOtherBuckets(
        uint96 margin,
        uint96 free,
        uint96 reserve,
        uint96 due
    ) public pure {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildIsolatedAccountUsdcBuckets(
                uint256(margin) + free + uint256(reserve) * 3, margin, reserve, reserve, reserve
            );
        MarginClearinghouseAccountingLib.SettlementConsumption memory c =
            MarginClearinghouseAccountingLib.planCarryLossConsumption(buckets, due);
        assertEq(c.totalConsumedUsdc + c.uncoveredUsdc, due);
        assertEq(c.totalConsumedUsdc, c.activeMarginConsumedUsdc + c.freeSettlementConsumedUsdc);
        assertLe(c.activeMarginConsumedUsdc, margin);
        assertLe(c.freeSettlementConsumedUsdc, free);
        assertEq(c.otherLockedMarginConsumedUsdc, 0);
        if (c.freeSettlementConsumedUsdc > 0) {
            assertEq(c.activeMarginConsumedUsdc, margin);
        }
        if (c.uncoveredUsdc > 0) {
            assertEq(c.totalConsumedUsdc, uint256(margin) + free);
        }
    }

}

contract MarginFirstCarryTest is BasePerpTest {

    address private constant TRADER = 0x9314586D4068C73B23a64d7406Ca8FfEeCc2cBFc;
    address private constant KEEPER = address(0xB0B);
    bytes32 private constant CARRY_EVENT = keccak256("CarryRealized(address,uint256,uint256,uint256,uint256)");

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 10_000_000e6;
    }

    function _margin(
        address account
    ) private view returns (uint256) {
        return clearinghouse.pnlPledgeUsdc(account);
    }

    function _checkpoint(
        address account
    ) private {
        vm.prank(address(clearinghouse));
        engine.realizeCarryBeforeMarginChange(account);
    }

    function _authenticate(
        address account
    ) private {
        vm.prank(address(engine));
        terminalNavBook.authenticateEngineState(account);
        engine.terminalNavSnapshot();
    }

    function test_ReportedAccount_CarryConsumesMarginAndCloseBountyReserves() public {
        uint256 size = 2_731_400e18;
        // Opening budget includes the fee and liquidation-reserve carve-out; exactly 90,417.68 remains pledged.
        uint256 openingBudget = 90_417_680_000 + 3_823_960_000;
        _fundTrader(TRADER, openingBudget + 400_000);
        _open(TRADER, CfdTypes.Side.LONG, size, openingBudget, 1e8);
        assertEq(_margin(TRADER), 90_417_680_000);
        assertEq(_freeSettlementUsdc(TRADER), 400_000);
        vm.warp(block.timestamp + 1 days);
        uint256 carry = _expectedIndexedCarryUsdc(TRADER);
        assertGe(carry, 3_965_425);
        uint256 beforeMargin = _margin(TRADER);
        uint256 beforePool = pool.totalAssets();
        uint64 version = terminalNavBook.bookState().bookVersion;
        vm.prank(TRADER);
        router.commitOrder(CfdTypes.Side.LONG, size, 0, 0, true);
        assertEq(_margin(TRADER), beforeMargin - carry);
        assertEq(_freeSettlementUsdc(TRADER), 200_000);
        assertEq(clearinghouse.actionReserveUsdc(TRADER), 200_000);
        assertEq(pool.totalAssets(), beforePool + carry);
        assertEq(engine.unsettledCarryUsdc(TRADER), 0);
        assertEq(router.pendingOrderCounts(TRADER), 1);
        assertEq(terminalNavBook.bookState().bookVersion, version + 1, "nested carry syncs only once");
        _authenticate(TRADER);
    }

    function test_BountyShortfallReportsPostCarryAndRollsBackNestedMutation() public {
        _fundTrader(TRADER, 10_000e6 + 100_000);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 1 days);
        uint256 beforeMargin = _margin(TRADER);
        uint256 beforeBalance = clearinghouse.balanceUsdc(TRADER);
        uint256 beforePool = pool.totalAssets();
        bytes32 beforeHash = terminalNavBook.curveHashOf(TRADER);
        bytes32 beforeBook = keccak256(abi.encode(terminalNavBook.bookState()));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector, 200_000, 100_000, 0
            )
        );
        vm.prank(TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        assertEq(_margin(TRADER), beforeMargin);
        assertEq(clearinghouse.balanceUsdc(TRADER), beforeBalance);
        assertEq(pool.totalAssets(), beforePool);
        assertEq(terminalNavBook.curveHashOf(TRADER), beforeHash);
        assertEq(keccak256(abi.encode(terminalNavBook.bookState())), beforeBook);
        _checkpoint(TRADER); // a failed bracket must not suppress authentication/synchronization on retry
        _authenticate(TRADER);
    }

    function test_BountyShortfallReportsCarryUnpaidAfterBothSourcesExhausted() public {
        _fundTrader(TRADER, 3000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        vm.warp(block.timestamp + 500 * 365 days);
        uint256 unpaid = _expectedIndexedCarryUsdc(TRADER) - _margin(TRADER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector, 200_000, 0, unpaid
            )
        );
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 100_000e18, 200_000);
        assertEq(engine.unsettledCarryUsdc(TRADER), 0, "failed funding rolls back collection and arrears");
        _authenticate(TRADER);
    }

    function test_CloseCommitValidationRetainsSpecificFailures() public {
        vm.expectRevert(ICfdEngineTypes.CfdEngine__NoOpenPosition.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 100e18, 200_000);
        _fundTrader(TRADER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__ZeroAmount.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 0, 200_000);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__CloseSizeExceedsPosition.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 100_100e18, 200_000);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__InvalidCloseSizeQuantum.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 1e18, 200_000);
        vm.mockCall(address(engine), abi.encodeWithSelector(engine.lastMarkPrice.selector), abi.encode(uint256(0)));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceStale.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 100_000e18, 200_000);
        vm.clearMockedCalls();
        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PartialCloseUnhealthy.selector);
        vm.prank(address(router));
        engine.reserveCloseOrderExecutionBounty(TRADER, 50_000e18, 200_000);
        _authenticate(TRADER);
    }

    function test_MarginFundedCarryPreservesHealthUntilMarginBreachesMaintenance() public {
        _fundTrader(TRADER, 50_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        vm.warp(block.timestamp + 1 days);
        assertFalse(engineAccountLens.getAccountLedgerSnapshot(TRADER).liquidatable);
        assertFalse(engineLens.previewLiquidation(TRADER, 1e8).liquidatable);
        vm.warp(block.timestamp + 300 * 365 days);
        assertTrue(engineAccountLens.getAccountLedgerSnapshot(TRADER).liquidatable);
        assertTrue(engineLens.previewLiquidation(TRADER, 1e8).liquidatable);
        _checkpoint(TRADER);
        assertEq(_margin(TRADER), 0);
        assertEq(engine.unsettledCarryUsdc(TRADER), 0, "free cash covers remaining carry");
        assertTrue(
            engineAccountLens.getAccountLedgerSnapshot(TRADER).liquidatable, "free cash does not replenish pledge"
        );
        _authenticate(TRADER);
    }

    function test_IncreaseAfterCarryMatchesProjectedMarginAndSideTotals() public {
        _fundTrader(TRADER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.warp(block.timestamp + 30 days);
        uint256 carry = _expectedIndexedCarryUsdc(TRADER);
        uint256 beforeMargin = _margin(TRADER);
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(TRADER, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, uint64(block.timestamp));
        assertTrue(preview.valid);
        _open(TRADER, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);
        assertEq(_margin(TRADER), beforeMargin - carry + 986e6);
        assertEq(_margin(TRADER), preview.postMarginUsdc);
        (,,, uint256 sideMargin) = engine.sides(0);
        assertEq(sideMargin, _margin(TRADER));
        assertEq(engine.sideBorrowBaseUsdc(0), _positionBorrowBaseUsdc(TRADER));
        _authenticate(TRADER);
    }

    function test_FullCloseCollectsCarryAccruedAfterCommitOnce() public {
        _closeAfterCommit(false);
    }

    function test_PartialCloseCollectsCarryAccruedAfterCommitOnce() public {
        _closeAfterCommit(true);
    }

    function _closeAfterCommit(
        bool isPartial
    ) private {
        _fundTrader(TRADER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 1 days);
        vm.prank(TRADER);
        router.commitOrder(CfdTypes.Side.LONG, isPartial ? 50_000e18 : 100_000e18, 0, 0, true);
        uint256 balanceAfterCommit = clearinghouse.balanceUsdc(TRADER);
        uint256 marginAfterCommit = _margin(TRADER);
        vm.warp(block.timestamp + 10);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        uint256 carry = _expectedIndexedCarryUsdc(TRADER);
        uint256 size = isPartial ? 50_000e18 : 100_000e18;
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(TRADER, size, 1e8);
        assertTrue(preview.valid);
        vm.recordLogs();
        router.executeOrder(1, priceData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 realized, uint256 free, uint256 margin) = _carryInLogs(logs, TRADER);
        OrderV2Types.OrderReceipt memory receipt;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4) {
                (,,, receipt) = abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV2Types.OrderReceipt));
            }
        }
        assertEq(uint8(receipt.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        assertEq(receipt.economics.carryUsdc, int256(carry));
        assertEq(receipt.economics.actionChargeCollectedUsdc, carry + (isPartial ? 20e6 : 40e6));
        assertEq(receipt.economics.grossAccountDebitUsdc, carry + (isPartial ? 20e6 : 40e6) + 200_000);
        assertEq(receipt.economics.preSettlementBalanceUsdc, balanceAfterCommit);
        assertEq(receipt.economics.postSettlementBalanceUsdc, clearinghouse.balanceUsdc(TRADER));
        assertEq(realized, carry);
        assertEq(free, 0);
        assertEq(margin, carry);
        assertEq(clearinghouse.balanceUsdc(TRADER), balanceAfterCommit - carry - (isPartial ? 20e6 : 40e6) - 200_000);
        assertEq(_margin(TRADER), preview.remainingMargin);
        assertEq(_margin(TRADER), isPartial ? (marginAfterCommit - carry) - (marginAfterCommit - carry) / 2 : 0);
        assertEq(engine.unsettledCarryUsdc(TRADER), 0);
        _authenticate(TRADER);
    }

    function test_LiquidationCollectsTraderAndKeeperCarryInIndependentBrackets() public {
        _fundTrader(TRADER, 10_000e6);
        _fundTrader(KEEPER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        _open(KEEPER, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 1 days);
        uint256 traderCarry = _expectedIndexedCarryUsdc(TRADER);
        uint256 keeperCarry = _expectedIndexedCarryUsdc(KEEPER);
        uint256 keeperMargin = _margin(KEEPER);
        uint256 traderMargin = _margin(TRADER);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(TRADER, 1.1e8);
        assertTrue(preview.liquidatable);
        uint256 depth = pool.totalAssets();
        vm.recordLogs();
        vm.prank(address(router));
        engine.liquidatePosition(TRADER, 1.1e8, depth, uint64(block.timestamp), KEEPER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 totalCarry;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(engine) && logs[i].topics[0] == CARRY_EVENT) {
                (uint256 realized,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                totalCarry += realized;
            }
        }
        assertEq(totalCarry, traderCarry + keeperCarry);
        assertEq(_margin(TRADER), 0);
        assertEq(_margin(KEEPER), keeperMargin - keeperCarry);
        assertLt(traderCarry, traderMargin);
        assertEq(engine.unsettledCarryUsdc(TRADER), 0);
        _authenticate(TRADER);
        _authenticate(KEEPER);
    }

    function test_TransientNavReadBlockedAndDownstreamRevertRestoresAccounting() public {
        _fundTrader(TRADER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 1 days);
        uint256 marginBefore = _margin(TRADER);
        uint256 balanceBefore = clearinghouse.balanceUsdc(TRADER);
        uint256 poolBefore = pool.totalAssets();
        bytes32 bookBefore = keccak256(abi.encode(terminalNavBook.bookState()));
        CarryNavProbeToken failing = new CarryNavProbeToken(address(engine), true);
        vm.etch(address(usdc), address(failing).code);
        vm.expectRevert(bytes("downstream revert"));
        _checkpoint(TRADER);
        assertEq(_margin(TRADER), marginBefore);
        assertEq(clearinghouse.balanceUsdc(TRADER), balanceBefore);
        assertEq(pool.totalAssets(), poolBefore);
        assertEq(keccak256(abi.encode(terminalNavBook.bookState())), bookBefore);
        CarryNavProbeToken probe = new CarryNavProbeToken(address(engine), false);
        vm.etch(address(usdc), address(probe).code);
        _checkpoint(TRADER);
        assertEq(CarryNavProbeToken(address(usdc)).blockedReads(), 1);
        _authenticate(TRADER);
    }

    function test_TerminalCarryRecoveryAndWaiverConserveWithoutConsumingClaim() public {
        _fundTrader(TRADER, 3100e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        uint256 depth = pool.totalAssets();
        vm.prank(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap = sidecar.buildRawSnapshot(TRADER, depth);
        uint256 directCarry = snap.position.margin + snap.accountBuckets.freeSettlementUsdc;
        snap.unsettledCarryUsdc = directCarry + 123e6;
        snap.executionFeeBps = 0;
        snap.oracleFrozen = false;
        snap.traderClaimBalanceForAccount = 987e6;
        snap.totalTraderClaimBalanceUsdc = 987e6;
        CfdTypes.Order memory order;
        order.account = TRADER;
        order.isClose = true;
        order.sizeDelta = 100_000e18;
        // No gain, a partially covering new gain, and a fully covering new gain.
        for (uint256 i; i < 3; ++i) {
            uint256 price = 1e8 - i * 100_000;
            CfdEnginePlanTypes.CloseDelta memory delta =
                engine.planner().planClose(snap, order, price, uint64(block.timestamp));
            assertTrue(delta.valid);
            assertEq(delta.realizedCarryUsdc, directCarry);
            assertEq(delta.actionChargeAssessedUsdc, 123e6);
            assertEq(
                delta.pendingCarryUsdc,
                delta.realizedCarryUsdc + delta.actionChargeWithheldUsdc + delta.actionChargeCollectedUsdc
                    + delta.actionChargeWaivedUsdc
            );
            assertEq(delta.pricePnlClaimConsumedUsdc, 0);
            assertEq(delta.existingTraderClaimRemainingUsdc, 987e6);
            assertEq(delta.actionChargeWaivedUsdc, i == 0 ? 123e6 : i == 1 ? 23e6 : 0);
        }
        // Liquidation shares the same allocation and terminal waiver, preserving the dedicated bounty reserve.
        CfdEnginePlanTypes.LiquidationDelta memory liquidation =
            engine.planner().planLiquidation(snap, 1e8, uint64(block.timestamp));
        assertTrue(liquidation.liquidatable);
        assertEq(
            liquidation.pendingCarryUsdc,
            liquidation.realizedCarryUsdc + liquidation.actionChargeWithheldUsdc + liquidation.actionChargeCollectedUsdc
                + liquidation.actionChargeWaivedUsdc
        );
        assertEq(liquidation.realizedCarryUsdc, directCarry);
        assertEq(liquidation.pricePnlClaimConsumedUsdc, 0);
        assertEq(liquidation.actionChargeWaivedUsdc, 123e6);
        assertEq(liquidation.liquidationChargeUsdc, snap.liquidationReserveUsdc);
    }

    function testFuzz_CheckpointInterleavingsConserveCarry(
        uint256 seed
    ) public {
        _fundTrader(TRADER, 3100e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 3000e6, 1e8);
        if (seed & 1 != 0) {
            // Start some sequences with real arrears carried forward from an earlier exhausted checkpoint.
            vm.warp(block.timestamp + 125 * 365 days);
            _checkpoint(TRADER);
            assertGt(engine.unsettledCarryUsdc(TRADER), 0);
        }
        uint256 assessed;
        uint256 marginCollected;
        uint256 freeCollected;
        uint256 startingArrears = engine.unsettledCarryUsdc(TRADER);
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % (80 * 365 days)));
            // This helper reports only new indexed accrual, excluding carried-forward arrears.
            assessed += _expectedIndexedCarryUsdc(TRADER);
            vm.recordLogs();
            if (seed & 2 != 0) {
                // Deposits checkpoint the old basis and can collect arrears from newly available free settlement.
                _fundTrader(TRADER, 1 + seed % (500e6));
            }
            _checkpoint(TRADER);
            if (seed & 1 != 0) {
                // A second same-timestamp checkpoint must not reassess existing arrears.
                _checkpoint(TRADER);
            }
            (, uint256 free, uint256 margin) = _carryCollected(TRADER);
            marginCollected += margin;
            freeCollected += free;
            assertEq(startingArrears + assessed, marginCollected + freeCollected + engine.unsettledCarryUsdc(TRADER));
            _authenticate(TRADER);
        }
    }

    function _carryCollected(
        address account
    ) private returns (uint256 realized, uint256 free, uint256 margin) {
        return _carryInLogs(vm.getRecordedLogs(), account);
    }

    function _carryInLogs(
        Vm.Log[] memory logs,
        address account
    ) private view returns (uint256 realized, uint256 free, uint256 margin) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(engine) && logs[i].topics[0] == CARRY_EVENT
                    && logs[i].topics[1] == bytes32(uint256(uint160(account)))
            ) {
                (uint256 r, uint256 f, uint256 m,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                realized += r;
                free += f;
                margin += m;
            }
        }
    }

}

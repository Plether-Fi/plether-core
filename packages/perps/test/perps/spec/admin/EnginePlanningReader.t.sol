// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanningReader} from "@plether/perps/CfdEnginePlanningReader.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEnginePlanner} from "@plether/perps/interfaces/ICfdEnginePlanner.sol";
import {ICfdEngineSettlementSidecar} from "@plether/perps/interfaces/ICfdEngineSettlementSidecar.sol";

import {CfdEngineTestBase} from "../../shared/CfdEngineTestBase.sol";

contract EnginePlanningReaderTest is CfdEngineTestBase {

    address private constant TRADER = address(0xA11CE);
    address private constant OTHER = address(0xB0B);

    function test_PlanningReader_IsCreatedAndBoundBeforeDependencies() public {
        CfdEngine fresh = new CfdEngine(
            address(settlementToken), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        CfdEnginePlanningReader reader = fresh.planningReader();

        assertGt(address(reader).code.length, 0);
        assertEq(address(reader.ENGINE()), address(fresh));
        assertNotEq(address(reader), address(engine.planningReader()));
        assertEq(address(fresh.planner()), address(0));
        assertEq(address(fresh.settlementSidecar()), address(0));

        fresh.transferOwnership(OTHER);
        vm.prank(OTHER);
        fresh.acceptOwnership();
        assertEq(address(fresh.planningReader()), address(reader));
        assertEq(address(reader.ENGINE()), address(fresh));
    }

    function test_PlanningReader_RejectsNonEngineOnEveryEntrypoint() public {
        CfdEnginePlanningReader reader = engine.planningReader();
        CfdTypes.Order memory order = _order(TRADER, false);

        vm.expectRevert(CfdEnginePlanningReader.CfdEnginePlanningReader__OnlyEngine.selector);
        reader.planOpen(order, 1e8, 1_000_000e6);
        vm.expectRevert(CfdEnginePlanningReader.CfdEnginePlanningReader__OnlyEngine.selector);
        reader.planClose(order, 1e8, 1_000_000e6);
        vm.expectRevert(CfdEnginePlanningReader.CfdEnginePlanningReader__OnlyEngine.selector);
        reader.planLiquidation(TRADER, 1e8, 1_000_000e6);
        vm.expectRevert(CfdEnginePlanningReader.CfdEnginePlanningReader__OnlyEngineOrSidecar.selector);
        reader.buildRawSnapshot(TRADER, 1_000_000e6, false);
        vm.expectRevert(CfdEnginePlanningReader.CfdEnginePlanningReader__OnlyEngineOrSidecar.selector);
        vm.prank(OTHER);
        reader.buildRawSnapshot(TRADER, 1_000_000e6, true);
    }

    function test_PlanningReader_CloseCommitSnapshotKeepsReducedReadsAndClearinghousePledge() public {
        _fundTrader(TRADER, 10_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        CfdEnginePlanningReader reader = engine.planningReader();
        CfdEnginePlanTypes.RawSnapshot memory full = _snapshot(TRADER, pool.totalAssets() - 123e6);

        // The position tuple's margin is a derived Engine observation; the clearinghouse remains authoritative.
        vm.mockCall(
            address(engine),
            abi.encodeWithSignature("positions(address)", TRADER),
            abi.encode(
                full.position.size,
                full.position.margin + 1e6,
                full.position.entryPrice,
                full.position.maxProfitAssets,
                full.position.side,
                full.position.lastUpdateTime,
                full.position.vpiAccrued
            )
        );
        bytes memory omittedRead = abi.encodeWithSignature("Error(string)", "execution-only read");
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("sides(uint256)", 1), omittedRead);
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("executionFeeBps()"), omittedRead);
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("settlementBufferBps()"), omittedRead);
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("degradedMode()"), omittedRead);
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("isOracleFrozen()"), omittedRead);
        vm.mockCallRevert(address(engine), abi.encodeWithSignature("frozenCloseSpreadBps()"), omittedRead);
        vm.mockCallRevert(
            address(clearinghouse),
            abi.encodeWithSignature("totalBountyReservationsAssets(address)", TRADER),
            omittedRead
        );

        vm.prank(address(engine.settlementSidecar()));
        CfdEnginePlanTypes.RawSnapshot memory commitment = reader.buildRawSnapshot(TRADER, 1, true);
        assertEq(commitment.position.margin, clearinghouse.pnlPledgeAssets(TRADER));
        assertEq(abi.encode(commitment.longSide), abi.encode(full.longSide));
        assertEq(commitment.shortSide.maxProfitAssets, 0);
        assertEq(commitment.shortSide.openInterest, 0);
        assertEq(commitment.poolAssets, pool.totalAssets(), "commitment must use live cash, not hypothetical depth");
        assertEq(commitment.totalPositiveVpiAccruedAssets, full.totalPositiveVpiAccruedAssets);
        assertEq(commitment.totalNegativeVpiAccruedAssets, full.totalNegativeVpiAccruedAssets);
        assertEq(commitment.vpiRebateReserveAssets, 0);
        assertEq(commitment.protectedExecutionBountyAssets, 0);
        assertEq(commitment.executionFeeBps, 0);
        assertEq(commitment.settlementBufferBps, 0);
    }

    function test_PlanningReader_PreservesConfiguredSidecarSnapshotSource() public {
        _fundTrader(TRADER, 10_000e6);
        CfdTypes.Order memory order = _order(TRADER, false);
        uint256 depth = pool.totalAssets();
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(TRADER, depth);
        snap.poolAssets = 10e6;
        CfdEnginePlanningReader reader = engine.planningReader();
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.mockCall(
            address(sidecar),
            abi.encodeCall(ICfdEngineSettlementSidecar.buildRawSnapshot, (TRADER, depth)),
            abi.encode(snap)
        );
        CfdEnginePlanTypes.OpenDelta memory expected = engine.planner().planOpen(snap, order, 1e8);
        assertFalse(expected.valid, "configured snapshot must control planning");
        vm.expectCall(address(sidecar), abi.encodeCall(ICfdEngineSettlementSidecar.buildRawSnapshot, (TRADER, depth)));
        vm.prank(address(engine));
        CfdEnginePlanTypes.OpenDelta memory actual = reader.planOpen(order, 1e8, depth);
        assertEq(abi.encode(actual), abi.encode(expected));
    }

    function test_PlanningReader_SnapshotReadPermissionDoesNotGrantSettlementAuthority() public {
        CfdEnginePlanningReader reader = engine.planningReader();
        CfdEngineSettlementSidecar sidecar = CfdEngineSettlementSidecar(address(engine.settlementSidecar()));
        uint256 depth = pool.totalAssets() - 123e6;
        CfdEnginePlanTypes.RawSnapshot memory expected = _snapshot(TRADER, depth);

        vm.prank(address(reader));
        CfdEnginePlanTypes.RawSnapshot memory actual = sidecar.buildRawSnapshot(TRADER, depth);
        assertEq(abi.encode(actual), abi.encode(expected));

        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.buildRawSnapshot(TRADER, depth);

        CfdEnginePlanTypes.OpenDelta memory openDelta;
        CfdEnginePlanTypes.CloseDelta memory closeDelta;
        CfdEnginePlanTypes.LiquidationDelta memory liquidationDelta;
        CfdTypes.Position memory position;
        vm.startPrank(address(reader));
        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeOpen(openDelta, position, uint64(block.timestamp));
        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeClose(closeDelta, position, uint64(block.timestamp));
        vm.expectRevert(CfdEngineSettlementSidecar.CfdEngineSettlementSidecar__Unauthorized.selector);
        sidecar.executeLiquidation(liquidationDelta, uint64(block.timestamp), OTHER);
        vm.stopPrank();
    }

    function test_PlanningReader_OpenForwardsOrderPriceAccountAndDepth() public {
        _fundTrader(TRADER, 10_000e6);
        CfdTypes.Order memory order = _order(TRADER, false);
        uint256 price = 112_345_678;
        uint256 depth = pool.totalAssets() - 123e6;
        CfdEnginePlanTypes.OpenDelta memory valid = _assertOpenParity(order, price, depth);

        assertTrue(valid.valid);
        assertEq(valid.account, TRADER);
        assertEq(valid.price, price);
        assertEq(valid.sizeDelta, order.sizeDelta);

        // The supplied hypothetical depth must reach the planner, rather than being replaced with live pool cash.
        CfdEnginePlanTypes.OpenDelta memory shallow = _assertOpenParity(order, price, 10e6);
        assertFalse(shallow.valid);

        // A different account must load its own collateral, even with the same order size and price.
        order.account = OTHER;
        CfdEnginePlanTypes.OpenDelta memory unfunded = _assertOpenParity(order, price, depth);
        assertFalse(unfunded.valid);
    }

    function test_PlanningReader_CloseMatchesDirectPlannerWithPendingCarry() public {
        _fundTrader(TRADER, 10_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.warp(block.timestamp + 1 days);

        CfdTypes.Order memory order = _order(TRADER, true);
        order.sizeDelta = 12_300e18;
        uint256 price = 99_123_456;
        uint256 depth = pool.totalAssets() - 321e6;
        CfdEnginePlanningReader reader = engine.planningReader();
        ICfdEnginePlanner planner = engine.planner();
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(TRADER, depth);
        CfdEnginePlanTypes.CloseDelta memory expected = planner.planClose(snap, order, price);

        vm.expectCall(address(planner), abi.encodeCall(ICfdEnginePlanner.planClose, (snap, order, price)));
        vm.prank(address(engine));
        CfdEnginePlanTypes.CloseDelta memory actual = reader.planClose(order, price, depth);

        assertEq(abi.encode(actual), abi.encode(expected));
        assertTrue(actual.valid);
        assertGt(actual.pendingCarryAssets, 0);
        assertEq(actual.account, TRADER);
        assertEq(actual.price, price);
    }

    function test_PlanningReader_LiquidationMatchesDirectPlannerAndPreservesReadOnlyState() public {
        _fundTrader(TRADER, 10_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        vm.warp(block.timestamp + 1 days);

        uint256 price = 150_123_456;
        uint256 depth = pool.totalAssets() - 456e6;
        CfdEnginePlanningReader reader = engine.planningReader();
        ICfdEnginePlanner planner = engine.planner();
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(TRADER, depth);
        CfdEnginePlanTypes.LiquidationDelta memory expected = planner.planLiquidation(snap, price);

        vm.expectCall(address(planner), abi.encodeCall(ICfdEnginePlanner.planLiquidation, (snap, price)));
        vm.prank(address(engine));
        CfdEnginePlanTypes.LiquidationDelta memory actual = reader.planLiquidation(TRADER, price, depth);

        assertEq(abi.encode(actual), abi.encode(expected));
        assertTrue(actual.liquidatable);
        assertGt(actual.pendingCarryAssets, 0);
        assertEq(actual.account, TRADER);
        assertEq(actual.price, price);
        assertEq(abi.encode(_snapshot(TRADER, depth)), abi.encode(snap), "Planning must not settle or checkpoint");
    }

    function _assertOpenParity(
        CfdTypes.Order memory order,
        uint256 price,
        uint256 depth
    ) private returns (CfdEnginePlanTypes.OpenDelta memory actual) {
        CfdEnginePlanningReader reader = engine.planningReader();
        ICfdEnginePlanner planner = engine.planner();
        CfdEnginePlanTypes.RawSnapshot memory snap = _snapshot(order.account, depth);
        CfdEnginePlanTypes.OpenDelta memory expected = planner.planOpen(snap, order, price);

        vm.expectCall(address(planner), abi.encodeCall(ICfdEnginePlanner.planOpen, (snap, order, price)));
        vm.prank(address(engine));
        actual = reader.planOpen(order, price, depth);
        assertEq(abi.encode(actual), abi.encode(expected));
    }

    function _snapshot(
        address account,
        uint256 depth
    ) private returns (CfdEnginePlanTypes.RawSnapshot memory) {
        ICfdEngineSettlementSidecar sidecar = engine.settlementSidecar();
        vm.prank(address(engine));
        return sidecar.buildRawSnapshot(account, depth);
    }

    function _order(
        address account,
        bool isClose
    ) private view returns (CfdTypes.Order memory) {
        return CfdTypes.Order({
            account: account,
            sizeDelta: 20_000e18,
            marginDelta: isClose ? 0 : 2000e6,
            targetPrice: 109_876_543,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: isClose
        });
    }

}

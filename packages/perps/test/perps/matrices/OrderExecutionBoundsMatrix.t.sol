// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Public V3 enforcement boundaries. Every permissive twin is checked against a $0.80 golden ledger
/// before its receipt is used to probe one bound at equality and either adjacent native unit.
/// @dev Carry and VPI are disabled in this Cartesian matrix to make every economic amount independently known.
contract OrderExecutionBoundsMatrixTest is BasePerpTest {

    address private constant ACCOUNT = address(0xB0A1);
    address private constant KEEPER = address(0xB0A2);
    uint256 private constant MARK = 80_000_000;
    uint256 private constant SIZE = 10_000e18;
    uint256 private constant MARGIN = 2000e6;
    uint256 private constant FUNDING = 20_000e6;
    uint256 private constant NOTIONAL = 8000e6;
    uint256 private constant FEE = 3_200_000;
    uint256 private executionDelay;
    uint256 private constant BEFORE_FAD = 1_729_283_399;

    struct Row {
        uint8 action; // 0 fresh open, 1 increase, 2 partial close, 3 full close
        uint8 regime; // 0 Live, 1 FAD, 2 Frozen
        CfdTypes.Side side;
        bool self;
    }

    struct Attempt {
        bool rejected;
        uint8 kind;
        uint256 actual;
        uint256 price;
        bool simple;
    }

    struct State {
        uint256 settlement;
        uint256 keeper;
        uint256 poolCash;
        uint256 custody;
        uint256 treasury;
        uint256 size;
        uint256 pledge;
        uint256 entryCost;
        uint256 claim;
        bytes32 curve;
        bytes32 economicState;
        bytes32 carryState;
        uint64 nextCommit;
        uint64 nextExecute;
    }

    function setUp() public override {
        super.setUp();
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 1 hours;
        _setRouterConfig(config);
    }

    function test_Open_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(0, 0);
    }

    function test_Increase_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(1, 0);
    }

    function test_PartialCloseLive_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(2, 0);
    }

    function test_FullCloseLive_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(3, 0);
    }

    function test_PartialCloseFad_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(2, 1);
    }

    function test_FullCloseFad_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(3, 1);
    }

    function test_PartialCloseFrozen_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(2, 2);
    }

    function test_FullCloseFrozen_AllNineBounds_BothSidesAndExecutors() public {
        _matrix(3, 2);
    }

    function _matrix(
        uint8 action,
        uint8 regime
    ) private {
        for (uint8 side; side < 2; side++) {
            for (uint8 executor; executor < 2; executor++) {
                uint256 scenario = vm.snapshotState();
                Row memory row = Row(action, regime, CfdTypes.Side(side), executor == 1);
                _prepare(row);
                uint256 startingState = vm.snapshotState();
                OrderV3Types.OrderReceipt memory twin = _execute(row, _request(row), false, 0, 0);
                _assertGolden(row, twin);
                assertTrue(vm.revertToState(startingState));
                for (uint8 kind = 1; kind <= 9; kind++) {
                    if (kind == 7) {
                        _settlementFloorAdmission(row, twin, startingState);
                        continue;
                    }
                    if (action == 3 && kind >= 8) {
                        _fullCloseIgnoresPositionBounds(row, kind);
                        assertTrue(vm.revertToState(startingState));
                        continue;
                    }
                    uint256 actual = _amount(twin, kind);
                    for (uint8 adjacent; adjacent < 3; adjacent++) {
                        // A zero maximum has no tighter representable limit.
                        if (adjacent == 1 && actual == 0 && !_minimum(kind)) {
                            continue;
                        }
                        uint256 limit = adjacent == 0
                            ? actual
                            : adjacent == 1
                                ? (_minimum(kind) ? actual + 1 : actual - 1)
                                : (_minimum(kind) ? actual - 1 : actual + 1);
                        OrderV3Types.OrderRequest memory request = _request(row);
                        _setLimit(request, kind, limit);
                        if (kind == 1 && adjacent == 1) {
                            State memory before_ = _state();
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound.selector,
                                    actual,
                                    limit
                                )
                            );
                            vm.prank(ACCOUNT);
                            router.commitOrder(request);
                            _assertCommitRollback(before_);
                        } else {
                            OrderV3Types.OrderReceipt memory receipt =
                                _execute(row, request, adjacent == 1, kind, actual);
                            if (adjacent != 1) {
                                _assertGolden(row, receipt);
                            }
                        }
                        assertTrue(vm.revertToState(startingState));
                    }
                }
                vm.deleteStateSnapshot(startingState);
                assertTrue(vm.revertToState(scenario));
                vm.deleteStateSnapshot(scenario);
            }
        }
    }

    /// @dev A positive minimum now has an admission boundary: the flat opening must reserve its full
    /// gross allowance. Self-execution remains conservative because its gross debit includes its bounty.
    function _settlementFloorAdmission(
        Row memory row,
        OrderV3Types.OrderReceipt memory twin,
        uint256 startingState
    ) private {
        uint256 gross = twin.economics.grossAccountDebitUsdc;
        uint256 custody = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 boundary = row.action == 0 ? custody - gross : twin.economics.postSettlementBalanceUsdc;
        for (uint8 adjacent; adjacent < 3; adjacent++) {
            OrderV3Types.OrderRequest memory request = _request(row);
            request.bounds.maxGrossAccountDebitUsdc = gross;
            request.bounds.minPostSettlementBalanceUsdc =
                adjacent == 0 ? boundary : adjacent == 1 ? boundary + 1 : boundary - 1;
            State memory before_ = _state();
            if (row.action != 0) {
                vm.expectRevert(IOrderRouterErrors.OrderRouter__SettlementFloorUnsupported.selector);
                vm.prank(ACCOUNT);
                router.commitOrder(request);
                _assertCommitRollback(before_);
            } else if (adjacent == 1) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IOrderRouterErrors.OrderRouter__SettlementFloorFunding.selector,
                        router.nextCommitId(),
                        custody,
                        request.bounds.minPostSettlementBalanceUsdc,
                        gross
                    )
                );
                vm.prank(ACCOUNT);
                router.commitOrder(request);
                _assertCommitRollback(before_);
            } else {
                _assertGolden(row, _execute(row, request, false, 0, 0));
            }
            assertTrue(vm.revertToState(startingState));
        }
    }

    // Timestamp reads must cross the cheatcode boundary: via-IR may reuse block.timestamp across vm.warp.
    function _prepare(
        Row memory row
    ) private {
        _fundTrader(ACCOUNT, FUNDING);
        vm.warp(BEFORE_FAD - 1 hours);
        vm.prank(address(router));
        engine.updateMarkPrice(MARK, uint64(vm.getBlockTimestamp()));
        if (row.action != 0) {
            Row memory seed = Row(0, 0, row.side, false);
            OrderV3Types.OrderRequest memory request = _request(seed);
            if (row.action >= 2) {
                request.sizeDelta = 2 * SIZE;
                request.marginDelta = 2 * MARGIN;
            }
            vm.prank(ACCOUNT);
            uint64 id = router.commitOrder(request);
            bytes[] memory data = _mockPythUpdateData(MARK);
            vm.prank(KEEPER);
            OrderV3Types.ExecutionResult memory result = router.executeOrder(id, data);
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "Public seed must execute");
            (uint256 size,,,,,,) = engine.positions(ACCOUNT);
            assertEq(size, request.sizeDelta);
            assertEq(engine.positionEntryCostUsdcAtoms(ACCOUNT), row.action == 1 ? NOTIONAL : 2 * NOTIONAL);
        }
        if (row.regime != 0) {
            vm.warp(BEFORE_FAD);
        }
        vm.prank(address(router));
        engine.updateMarkPrice(MARK, uint64(vm.getBlockTimestamp()));
    }

    function _request(
        Row memory row
    ) private view returns (OrderV3Types.OrderRequest memory request) {
        request.clientOrderId = bytes32(uint256(router.nextCommitId()) + 0xB000);
        request.side = row.side;
        request.targetPrice = MARK;
        request.sizeDelta = row.action == 3 ? 2 * SIZE : SIZE;
        request.marginDelta = row.action < 2 ? MARGIN : 0;
        request.isClose = row.action >= 2;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(vm.getBlockTimestamp() + 1 hours),
            executionWindowSeconds: 3600,
            allowedExecutionModes: 7,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyUsdc: type(uint256).max,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _execute(
        Row memory row,
        OrderV3Types.OrderRequest memory request,
        bool rejected,
        uint8 kind,
        uint256 actual
    ) private returns (OrderV3Types.OrderReceipt memory receipt) {
        return _run(row, request, Attempt(rejected, kind, actual, MARK, true));
    }

    function _run(
        Row memory row,
        OrderV3Types.OrderRequest memory request,
        Attempt memory attempt
    ) private returns (OrderV3Types.OrderReceipt memory receipt) {
        vm.prank(ACCOUNT);
        uint64 id = router.commitOrder(request);
        // Close commitment can mutate carry: rollback assertions deliberately start AFTER commitment.
        State memory before_ = _state();
        uint256 bounty = router.lifecycleBook().pendingIntent(id).executionBountyUsdc;
        if (executionDelay != 0) {
            vm.warp(vm.getBlockTimestamp() + executionDelay);
        }
        if (row.regime == 2) {
            vm.warp(BEFORE_FAD + 1801);
        } else if (row.regime == 1) {
            vm.warp(BEFORE_FAD + 1);
        }
        bytes[] memory data = _mockPythUpdateData(attempt.price);
        vm.recordLogs();
        vm.prank(row.self ? ACCOUNT : KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, data);
        receipt = _receipt(id, vm.getRecordedLogs());
        assertEq(result.orderId, id);
        assertEq(uint8(receipt.status), uint8(result.status));
        assertEq(uint8(receipt.reason), uint8(result.terminalReason));
        assertEq(receipt.clientOrderId, request.clientOrderId);
        assertEq(receipt.expectedConfigHash, request.bounds.expectedConfigHash);
        assertEq(receipt.observedConfigHash, request.bounds.expectedConfigHash);
        assertEq(
            uint8(result.status),
            uint8(attempt.rejected ? OrderV3Types.LifecycleStatus.Failed : OrderV3Types.LifecycleStatus.Executed)
        );
        assertEq(result.receiptHash, router.lifecycleBook().terminalOutcome(id).receiptHash);
        assertEq(uint8(receipt.executionMode), row.regime + 1);
        assertEq(receipt.executor, row.self ? ACCOUNT : KEEPER);
        assertEq(receipt.bountyRecipient, receipt.bountyUsdc == 0 ? address(0) : row.self ? ACCOUNT : KEEPER);
        assertEq(
            uint8(receipt.bountyDisposition),
            uint8(receipt.bountyUsdc == 0 ? OrderV3Types.BountyDisposition.None : OrderV3Types.BountyDisposition.Paid)
        );
        assertEq(receipt.bountyUsdc, bounty);
        assertEq(clearinghouse.balanceUsdc(KEEPER), before_.keeper + (row.self ? 0 : bounty));
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(router.nextExecuteId(), 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
        IOrderRouterAccounting.AccountReservationView memory reservations = router.getAccountReservations(ACCOUNT);
        assertEq(reservations.committedMarginUsdc, 0);
        assertEq(reservations.executionBountyUsdc, 0);
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(0));
        if (attempt.rejected) {
            _assertFailure(receipt, request, attempt.kind, attempt.actual);
            _assertExecutionRollback(before_, row.self ? 0 : bounty);
            assertEq(receipt.economics.postSettlementBalanceUsdc, clearinghouse.balanceUsdc(ACCOUNT));
            assertEq(receipt.economics.postPositionSize, before_.size);
            assertEq(receipt.economics.postPositionMarginUsdc, before_.pledge);
            assertEq(receipt.economics.postTraderClaimBalanceUsdc, before_.claim);
            assertEq(receipt.economics.executionNotionalUsdc, 0);
            assertEq(receipt.economics.realizedPnlUsdc, 0);
            assertEq(receipt.economics.vpiUsdc, 0);
            assertEq(receipt.economics.executionFeeUsdc, 0);
            assertEq(receipt.economics.frozenSpreadUsdc, 0);
        } else {
            assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.Executed));
            assertEq(clearinghouse.balanceUsdc(ACCOUNT), receipt.economics.postSettlementBalanceUsdc);
            (uint256 size, uint256 margin,,,,,) = engine.positions(ACCOUNT);
            assertEq(size, receipt.economics.postPositionSize);
            assertEq(margin, receipt.economics.postPositionMarginUsdc);
            if (attempt.simple) {
                assertEq(
                    clearinghouse.balanceUsdc(engine.protocolTreasury()),
                    before_.treasury + receipt.economics.executionFeeUsdc
                );
                assertEq(usdc.balanceOf(address(pool)), before_.poolCash + receipt.economics.frozenSpreadUsdc);
                assertEq(usdc.balanceOf(address(clearinghouse)), before_.custody - receipt.economics.frozenSpreadUsdc);
            }
        }
    }

    function _assertFailure(
        OrderV3Types.OrderReceipt memory receipt,
        OrderV3Types.OrderRequest memory request,
        uint8 kind,
        uint256 actual
    ) private pure {
        assertEq(uint8(receipt.reason), uint8(OrderV3Types.TerminalReason.ConstraintViolation));
        assertEq(
            receipt.failure.selector, ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector
        );
        assertEq(uint8(receipt.failure.constraint), kind);
        assertEq(receipt.failure.actual, actual);
        assertEq(receipt.failure.limit, _limit(request, kind));
        assertEq(
            receipt.failure.revertDataHash,
            keccak256(
                abi.encodeWithSelector(
                    ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
                    OrderV3Types.ConstraintKind(kind),
                    actual,
                    _limit(request, kind)
                )
            )
        );
    }

    function _assertGolden(
        Row memory row,
        OrderV3Types.OrderReceipt memory receipt
    ) private view {
        uint256 multiplicity = row.action == 3 ? 2 : 1;
        uint256 fee = FEE * multiplicity;
        uint256 spread = row.regime == 2 ? 40e6 * multiplicity : 0;
        uint256 seedFees = row.action == 0 ? 0 : row.action == 1 ? FEE : 2 * FEE;
        uint256 seedBounty = row.action == 0 ? 0 : 200_000;
        uint256 bounty = row.action < 2 ? 200_000 : 0;
        uint256 remaining = row.action == 3 ? 0 : row.action == 1 ? 2 * SIZE : SIZE;
        uint256 pledge = row.action == 3 ? 0 : row.action == 1 ? 3_977_600_000 : 1_988_800_000;
        assertEq(receipt.executionPrice, MARK);
        assertEq(receipt.bountyUsdc, bounty, "$0.80 golden bounty");
        OrderV3Types.OrderEconomics memory e = receipt.economics;
        assertEq(e.executionNotionalUsdc, multiplicity * NOTIONAL);
        assertEq(e.executionFeeUsdc, fee);
        assertEq(e.frozenSpreadUsdc, spread);
        assertEq(e.grossAccountDebitUsdc, fee + spread + bounty);
        assertEq(e.actionChargeAssessedUsdc, fee + spread);
        assertEq(e.actionChargeCollectedUsdc, fee + spread);
        assertEq(e.postPositionSize, remaining);
        assertEq(e.postPositionMarginUsdc, pledge);
        assertEq(e.postPositionEquityUsdc, int256(pledge));
        assertEq(e.postLeverageBps, row.action == 3 ? 0 : 40_226);
        assertEq(e.postSettlementBalanceUsdc, FUNDING - seedFees - seedBounty - fee - spread - (row.self ? 0 : bounty));
        assertEq(e.realizedPnlUsdc, 0);
        assertEq(e.vpiUsdc, 0);
        assertEq(e.carryUsdc, 0);
        assertEq(e.postTraderClaimBalanceUsdc, 0);
        assertEq(engine.positionEntryCostUsdcAtoms(ACCOUNT), remaining / 1e20 * MARK);
    }

    /// @dev Offline rational potential vectors: C(S)=S²/(100D), D starts at 1,002,000 USDC.
    /// Seed: 80,000-USDC skew costs 63.872255; at D=1,002,063.872255, moving to 88,000 costs
    /// 13.412318 and moving to 72,000 rebates 12.134955. These are constants, not evaluator outputs.
    struct VpiGolden {
        int256 vpi;
        uint256 charge;
        uint256 gross;
        uint256 settlement;
    }

    function test_VpiChargeAndRebate_GrossActionSettlementBounds_SelfAndExternal() public {
        for (uint8 healing; healing < 2; healing++) {
            for (uint8 self; self < 2; self++) {
                uint256 scenario = vm.snapshotState();
                _vpiRow(healing == 1, self == 1);
                assertTrue(vm.revertToState(scenario));
                vm.deleteStateSnapshot(scenario);
            }
        }
    }

    function _vpiRow(
        bool healing,
        bool self
    ) private {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        params.vpiFactor = 0.02e18;
        _setRiskParams(params);
        _fundTrader(address(0xB0A3), 100_000e6);
        _open(address(0xB0A3), CfdTypes.Side.LONG, 100_000e18, 20_000e6, MARK);
        assertEq(usdc.balanceOf(address(pool)), 1_002_063_872_255, "Independent seed potential");
        Row memory row = Row(0, 0, healing ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG, self);
        _prepare(row);
        VpiGolden memory golden;
        golden.vpi = healing ? int256(-12_134_955) : int256(13_412_318);
        golden.charge = healing ? 0 : 16_612_318;
        golden.gross = golden.charge + 200_000;
        golden.settlement = uint256(int256(FUNDING - FEE) - golden.vpi) - (self ? 0 : 200_000);
        _vpiLimit(row, golden, 3);
        _vpiLimit(row, golden, 4);
        _vpiLimit(row, golden, 5);
        _vpiLimit(row, golden, 7);
    }

    function _vpiLimit(
        Row memory row,
        VpiGolden memory golden,
        uint8 kind
    ) private {
        uint256 actual = kind == 3 ? golden.gross : kind == 4 ? golden.charge : kind == 5 ? FEE : FUNDING - golden.gross;
        uint256 startingState = vm.snapshotState();
        for (uint8 adjacent; adjacent < 3; adjacent++) {
            if (actual == 0 && adjacent == 1) {
                continue;
            }
            uint256 limit = adjacent == 0
                ? actual
                : adjacent == 1
                    ? (_minimum(kind) ? actual + 1 : actual - 1)
                    : (_minimum(kind) ? actual - 1 : actual + 1);
            OrderV3Types.OrderRequest memory request = _request(row);
            _setLimit(request, kind, limit);
            if (kind == 7) {
                request.bounds.maxGrossAccountDebitUsdc = golden.gross;
                if (adjacent == 1) {
                    State memory before_ = _state();
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            IOrderRouterErrors.OrderRouter__SettlementFloorFunding.selector,
                            router.nextCommitId(),
                            FUNDING,
                            limit,
                            golden.gross
                        )
                    );
                    vm.prank(ACCOUNT);
                    router.commitOrder(request);
                    _assertCommitRollback(before_);
                    assertTrue(vm.revertToState(startingState));
                    continue;
                }
            }
            if (kind == 3 && limit < 200_000) {
                State memory before_ = _state();
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IOrderRouterErrors.OrderRouter__ExecutionBountyAboveGrossDebit.selector, 200_000, limit
                    )
                );
                vm.prank(ACCOUNT);
                router.commitOrder(request);
                _assertCommitRollback(before_);
                assertTrue(vm.revertToState(startingState));
                continue;
            }
            OrderV3Types.OrderReceipt memory receipt =
                _run(row, request, Attempt(adjacent == 1, kind, actual, MARK, false));
            if (adjacent != 1) {
                assertEq(receipt.economics.vpiUsdc, golden.vpi);
                assertEq(receipt.economics.executionFeeUsdc, FEE);
                assertEq(receipt.economics.grossAccountDebitUsdc, golden.gross);
                assertEq(receipt.economics.actionChargeAssessedUsdc, golden.charge);
                assertEq(receipt.economics.postSettlementBalanceUsdc, golden.settlement);
                assertEq(receipt.economics.postPositionSize, SIZE);
                assertEq(receipt.economics.realizedPnlUsdc, 0);
                assertEq(receipt.economics.carryUsdc, 0);
                assertEq(clearinghouse.vpiRebateReserveUsdc(ACCOUNT), golden.vpi < 0 ? uint256(-golden.vpi) : 0);
            }
            assertTrue(vm.revertToState(startingState));
        }
        vm.deleteStateSnapshot(startingState);
    }

    function test_ClaimConsumptionCountsInGrossDebit_PublicCloseBoundary() public {
        // A real partial close realizes $1,000 profit with no pool cash and leaves a $997.20 same-account claim after its $2.80 fee.
        Row memory row = Row(2, 0, CfdTypes.Side.LONG, false);
        _prepare(row);
        uint256 cashShock = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), cashShock);
        _close(ACCOUNT, CfdTypes.Side.LONG, SIZE, 70_000_000);
        assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 997_200_000);
        usdc.mint(address(pool), cashShock);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(vm.getBlockTimestamp()));
        // The remaining 100 lots lose $1,000 at $0.90: $997.20 claims and $2.80 pledge fund that loss.
        // Gross authority includes both sources, plus the $3.60 fee.
        uint256 startingState = vm.snapshotState();
        row.action = 3;
        for (uint8 adjacent; adjacent < 3; adjacent++) {
            uint256 actual = 1_003_600_000;
            OrderV3Types.OrderRequest memory request = _request(row);
            request.sizeDelta = SIZE;
            request.targetPrice = 90_000_000;
            request.bounds.maxGrossAccountDebitUsdc = adjacent == 0 ? actual : adjacent == 1 ? actual - 1 : actual + 1;
            uint256 settlement = clearinghouse.balanceUsdc(ACCOUNT);
            OrderV3Types.OrderReceipt memory receipt =
                _run(row, request, Attempt(adjacent == 1, 3, actual, 90_000_000, false));
            if (adjacent != 1) {
                assertEq(receipt.economics.realizedPnlUsdc, -1000e6);
                assertEq(receipt.economics.close.pricePnlClaimConsumedUsdc, 997_200_000);
                assertEq(receipt.economics.close.pricePnlPledgeConsumedUsdc, 2_800_000);
                assertEq(receipt.economics.grossAccountDebitUsdc, actual);
                assertEq(receipt.economics.actionChargeAssessedUsdc, 3_600_000);
                assertEq(receipt.economics.postSettlementBalanceUsdc, settlement - 6_400_000);
                assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 0);
                assertEq(receipt.economics.postPositionSize, 0);
            }
            assertTrue(vm.revertToState(startingState));
        }
        vm.deleteStateSnapshot(startingState);
    }

    function test_CommitmentAndDelayedCarry_GrossAndActionAtomBounds_BothSides() public {
        for (uint8 side; side < 2; side++) {
            uint256 scenario = vm.snapshotState();
            CfdTypes.RiskParams memory params = _riskParams();
            params.baseCarryBps = 500;
            _setRiskParams(params);
            Row memory row = Row(2, 0, CfdTypes.Side(side), false);
            _prepare(row);
            vm.warp(vm.getBlockTimestamp() + 1200);
            // Independent integer-rational vectors, with $1,002,000 depth, $3,977.60 pledge and 500 bps:
            // Long borrow12,022.40 / utilization119bps ->272 atoms in1200s, then68 in301s.
            // Short borrow20,022.40 / utilization199bps ->758 atoms, then190. Collection changes basis/depth.
            uint256 commitmentCarry = side == 0 ? 272 : 758;
            uint256 delayedCarry = side == 0 ? 68 : 190;
            executionDelay = 300; // MockPyth update advances one additional second.
            _carryLimits(row, commitmentCarry, delayedCarry);
            assertTrue(vm.revertToState(scenario));
            vm.deleteStateSnapshot(scenario);
        }
    }

    function _carryLimits(
        Row memory row,
        uint256 commitmentCarry,
        uint256 delayedCarry
    ) private {
        uint256 startingState = vm.snapshotState();
        for (uint8 kind = 3; kind <= 5; kind++) {
            if (kind <= 4) {
                // Rejection at commitment must roll back its carry collection as well as reservation allocation.
                OrderV3Types.OrderRequest memory tooSmall = _request(row);
                uint256 commitActual = commitmentCarry;
                _setLimit(tooSmall, kind, commitActual - 1);
                State memory beforeCommit = _state();
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IOrderLifecycleBook.OrderLifecycleBook__CommitmentBoundExceeded.selector,
                        OrderV3Types.ConstraintKind(kind),
                        commitActual,
                        commitActual - 1
                    )
                );
                vm.prank(ACCOUNT);
                router.commitOrder(tooSmall);
                _assertCommitRollback(beforeCommit);
            }
            uint256 actual = kind == 5 ? FEE : commitmentCarry + delayedCarry + FEE;
            for (uint8 adjacent; adjacent < 3; adjacent++) {
                OrderV3Types.OrderRequest memory request = _request(row);
                _setLimit(request, kind, adjacent == 0 ? actual : adjacent == 1 ? actual - 1 : actual + 1);
                State memory before_ = _state();
                OrderV3Types.OrderReceipt memory receipt =
                    _run(row, request, Attempt(adjacent == 1, kind, actual, MARK, false));
                assertEq(
                    receipt.commitment.carryCollectedUsdc, commitmentCarry, "Commitment pays historical carry once"
                );
                if (adjacent != 1) {
                    assertEq(receipt.economics.carryUsdc, int256(commitmentCarry + delayedCarry));
                    assertEq(receipt.economics.actionChargeAssessedUsdc, FEE + commitmentCarry + delayedCarry);
                    assertEq(receipt.economics.grossAccountDebitUsdc, FEE + commitmentCarry + delayedCarry);
                    assertEq(
                        receipt.economics.postSettlementBalanceUsdc,
                        before_.settlement - FEE - commitmentCarry - delayedCarry
                    );
                    assertEq(usdc.balanceOf(address(pool)), before_.poolCash + commitmentCarry + delayedCarry);
                    assertEq(receipt.economics.postPositionSize, SIZE);
                    assertEq(receipt.economics.realizedPnlUsdc, 0);
                    assertEq(receipt.economics.vpiUsdc, 0);
                }
                assertTrue(vm.revertToState(startingState));
            }
        }
        vm.deleteStateSnapshot(startingState);
    }

    function _fullCloseIgnoresPositionBounds(
        Row memory row,
        uint8 kind
    ) private {
        OrderV3Types.OrderRequest memory request = _request(row);
        if (kind == 8) {
            request.bounds.minPostPositionEquityUsdc = type(uint256).max;
        } else {
            request.bounds.maxPostLeverageBps = 1;
        }
        _assertGolden(row, _execute(row, request, false, 0, 0));
    }

    function test_FullCloseStillRejectsZeroLeverageAtCommit() public {
        Row memory row = Row(3, 0, CfdTypes.Side.LONG, false);
        _prepare(row);
        OrderV3Types.OrderRequest memory request = _request(row);
        request.bounds.maxPostLeverageBps = 0;
        State memory before_ = _state();
        vm.expectRevert(IOrderRouterErrors.OrderRouter__ZeroPostLeverageBound.selector);
        vm.prank(ACCOUNT);
        router.commitOrder(request);
        _assertCommitRollback(before_);
    }

    function _receipt(
        uint64 id,
        Vm.Log[] memory logs
    ) private view returns (OrderV3Types.OrderReceipt memory receipt) {
        IOrderLifecycleBook book = IOrderLifecycleBook(address(router.lifecycleBook()));
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter != address(book) || logs[i].topics.length != 4
                    || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
            ) {
                continue;
            }
            (bytes32 hash, uint64 terminalBlock, uint64 terminalTime, OrderV3Types.OrderReceipt memory found) =
                abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
            if (found.orderId != id) {
                continue;
            }
            assertTrue(book.verifyReceipt(found, terminalTime), "Receipt must authenticate");
            assertEq(hash, book.terminalOutcome(id).receiptHash);
            assertEq(terminalBlock, book.terminalOutcome(id).terminalBlock);
            assertEq(found.account, ACCOUNT);
            return found;
        }
        revert("Missing final receipt");
    }

    function _state() private view returns (State memory s) {
        s.settlement = clearinghouse.balanceUsdc(ACCOUNT);
        s.keeper = clearinghouse.balanceUsdc(KEEPER);
        s.poolCash = usdc.balanceOf(address(pool));
        s.custody = usdc.balanceOf(address(clearinghouse));
        s.treasury = clearinghouse.balanceUsdc(engine.protocolTreasury());
        (s.size, s.pledge,,,,,) = engine.positions(ACCOUNT);
        s.entryCost = engine.positionEntryCostUsdcAtoms(ACCOUNT);
        s.claim = engine.traderClaimBalanceUsdc(ACCOUNT);
        s.curve = terminalNavBook.curveHashOf(ACCOUNT);
        (bool ok, bytes memory position) =
            address(engine).staticcall(abi.encodeWithSignature("positions(address)", ACCOUNT));
        assertTrue(ok);
        s.economicState = keccak256(
            abi.encode(
                position,
                engine.unsettledCarryUsdc(ACCOUNT),
                clearinghouse.liquidationReserveUsdc(ACCOUNT),
                clearinghouse.vpiRebateReserveUsdc(ACCOUNT)
            )
        );
        (uint256 borrowBase, uint256 index, uint64 timestamp) = engine.positionCarryState(ACCOUNT);
        s.carryState = keccak256(abi.encode(borrowBase, index, timestamp));
        s.nextCommit = router.nextCommitId();
        s.nextExecute = router.nextExecuteId();
    }

    function _assertCommitRollback(
        State memory before_
    ) private view {
        _assertExecutionRollback(before_, 0);
        assertEq(_state().carryState, before_.carryState);
        assertEq(router.nextCommitId(), before_.nextCommit);
        assertEq(router.nextExecuteId(), before_.nextExecute);
        assertEq(clearinghouse.balanceUsdc(KEEPER), before_.keeper);
        assertEq(router.pendingOrderCounts(ACCOUNT), 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(ACCOUNT), 0);
    }

    function _assertExecutionRollback(
        State memory before_,
        uint256 bountyDebit
    ) private view {
        State memory after_ = _state();
        assertEq(after_.settlement, before_.settlement - bountyDebit);
        assertEq(after_.poolCash, before_.poolCash);
        assertEq(after_.custody, before_.custody);
        assertEq(after_.treasury, before_.treasury);
        assertEq(after_.size, before_.size);
        assertEq(after_.pledge, before_.pledge);
        assertEq(after_.entryCost, before_.entryCost);
        assertEq(after_.claim, before_.claim);
        assertEq(after_.curve, before_.curve);
        assertEq(after_.economicState, before_.economicState);
        if (bountyDebit != 0) {
            assertEq(after_.carryState, before_.carryState);
        }
    }

    function _minimum(
        uint8 kind
    ) private pure returns (bool) {
        return kind == 7 || kind == 8;
    }

    function _amount(
        OrderV3Types.OrderReceipt memory receipt,
        uint8 kind
    ) private pure returns (uint256) {
        OrderV3Types.OrderEconomics memory e = receipt.economics;
        if (kind == 1) {
            return receipt.bountyUsdc;
        }
        if (kind == 2) {
            return e.executionNotionalUsdc;
        }
        if (kind == 3) {
            return e.grossAccountDebitUsdc;
        }
        if (kind == 4) {
            return e.actionChargeAssessedUsdc;
        }
        if (kind == 5) {
            return e.executionFeeUsdc + e.frozenSpreadUsdc;
        }
        if (kind == 6) {
            return e.postPositionSize;
        }
        if (kind == 7) {
            return e.postSettlementBalanceUsdc;
        }
        if (kind == 8) {
            return uint256(e.postPositionEquityUsdc);
        }
        return e.postLeverageBps;
    }

    function _setLimit(
        OrderV3Types.OrderRequest memory r,
        uint8 k,
        uint256 n
    ) private pure {
        if (k == 1) {
            r.bounds.maxExecutionBountyUsdc = n;
        } else if (k == 2) {
            r.bounds.maxExecutionNotionalUsdc = n;
        } else if (k == 3) {
            r.bounds.maxGrossAccountDebitUsdc = n;
        } else if (k == 4) {
            r.bounds.maxActionChargeUsdc = n;
        } else if (k == 5) {
            r.bounds.maxExplicitFeesUsdc = n;
        } else if (k == 6) {
            r.bounds.maxPostPositionSize = n;
        } else if (k == 7) {
            r.bounds.minPostSettlementBalanceUsdc = n;
        } else if (k == 8) {
            r.bounds.minPostPositionEquityUsdc = n;
        } else {
            r.bounds.maxPostLeverageBps = uint32(n);
        }
    }

    function _limit(
        OrderV3Types.OrderRequest memory r,
        uint8 k
    ) private pure returns (uint256) {
        if (k == 1) {
            return r.bounds.maxExecutionBountyUsdc;
        }
        if (k == 2) {
            return r.bounds.maxExecutionNotionalUsdc;
        }
        if (k == 3) {
            return r.bounds.maxGrossAccountDebitUsdc;
        }
        if (k == 4) {
            return r.bounds.maxActionChargeUsdc;
        }
        if (k == 5) {
            return r.bounds.maxExplicitFeesUsdc;
        }
        if (k == 6) {
            return r.bounds.maxPostPositionSize;
        }
        if (k == 7) {
            return r.bounds.minPostSettlementBalanceUsdc;
        }
        if (k == 8) {
            return r.bounds.minPostPositionEquityUsdc;
        }
        return r.bounds.maxPostLeverageBps;
    }

}

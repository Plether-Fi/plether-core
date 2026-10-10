// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

contract OracleRegimeMatrixTest is BasePerpTest {

    address private constant ACCOUNT = address(0xCA10);
    address private constant KEEPER = address(0xCA11);
    address private constant LATCH = address(0xCA12);
    uint256 private constant BEFORE_FAD = 1_729_283_399;

    struct BeforeExecution {
        uint256 trader;
        uint256 keeper;
        uint256 custody;
        uint256 bounty;
        uint256 margin;
        uint256 treasury;
        uint256 poolCash;
    }

    /// @dev One-hour governance-approved deadlines allow a pre-FAD intent to remain unexpired into freeze.
    ///      MockPyth validates plumbing, not authenticity of an external Pyth payload.
    function test_QueuedOpenAndClose_CalendarCrossedWithDegradedMode() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.maxExecutionWindowSeconds = 1 hours;
        _setRouterConfig(config);
        for (uint8 regime; regime < 3; regime++) {
            for (uint8 action; action < 3; action++) {
                for (uint8 state; state < 2; state++) {
                    uint256 snapshot = vm.snapshotState();
                    _executeRow(regime, action, state == 1);
                    assertTrue(vm.revertToState(snapshot));
                    vm.deleteStateSnapshot(snapshot);
                }
            }
        }
    }

    function test_Liquidation_CalendarCrossedWithDegradedMode() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        for (uint8 regime; regime < 3; regime++) {
            for (uint8 state; state < 2; state++) {
                uint256 snapshot = vm.snapshotState();
                _liquidationRow(regime, state == 1, 0);
                assertTrue(vm.revertToState(snapshot));
                vm.deleteStateSnapshot(snapshot);
            }
        }
    }

    function test_Liquidation_OracleFreshnessBoundaryEachCalendarRegime() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        for (uint8 regime; regime < 3; regime++) {
            for (uint8 boundary = 1; boundary <= 3; boundary++) {
                uint256 snapshot = vm.snapshotState();
                _liquidationRow(regime, false, boundary);
                assertTrue(vm.revertToState(snapshot));
                vm.deleteStateSnapshot(snapshot);
            }
        }
    }

    function _liquidationRow(
        uint8 regime,
        bool degraded,
        uint8 boundary
    ) private {
        _fundTrader(ACCOUNT, 300e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);
        if (degraded) {
            _fundTrader(LATCH, 5000e6);
            _open(LATCH, CfdTypes.Side.LONG, 20_000e18, 4000e6, 1e8);
            uint256 cash = usdc.balanceOf(address(pool));
            usdc.burn(address(pool), cash);
            _close(LATCH, CfdTypes.Side.LONG, 10_000e18, 1e8);
            assertTrue(engine.degradedMode());
            usdc.mint(address(pool), cash);
        }
        vm.warp(regime == 0 ? BEFORE_FAD - 1 hours : regime == 1 ? BEFORE_FAD + 1 : BEFORE_FAD + 1801);
        uint256 ageLimit = regime == 2 ? engine.fadMaxStaleness() : pletherOracle.liquidationStalenessLimit();
        uint256 age = boundary == 0 ? 0 : ageLimit + boundary - 2;
        baseMockPyth.setAllPrices(_basePythFeedIds(), 150_000_000, -8, block.timestamp - age);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = ""; // Do not refresh timestamps while exercising age boundaries.
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(ACCOUNT, 150_000_000);
        assertTrue(preview.liquidatable, "Every row starts with an actually liquidatable position");
        uint256 keeperBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 cashBefore = usdc.balanceOf(address(pool));
        if (boundary == 3) {
            vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        }
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, priceData);
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        if (boundary == 3) {
            assertEq(size, 10_000e18);
            assertEq(clearinghouse.balanceUsdc(KEEPER), keeperBefore);
            assertEq(usdc.balanceOf(address(pool)), cashBefore);
            assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore);
        } else {
            assertEq(size, 0);
            assertEq(clearinghouse.balanceUsdc(KEEPER), keeperBefore + preview.keeperBountyUsdc);
            assertEq(usdc.balanceOf(address(pool)) - cashBefore, custodyBefore - usdc.balanceOf(address(clearinghouse)));
            assertEq(engine.traderClaimBalanceUsdc(ACCOUNT), 0);
        }
    }

    function _executeRow(
        uint8 regime,
        uint8 action,
        bool degraded
    ) private {
        bool close = action != 0;
        _fundTrader(ACCOUNT, 20_000e6);
        if (close) {
            _open(ACCOUNT, CfdTypes.Side.LONG, action == 2 ? 20_000e18 : 10_000e18, 2000e6, 1e8);
        }
        if (degraded) {
            _fundTrader(LATCH, 5000e6);
            _open(LATCH, CfdTypes.Side.LONG, 20_000e18, 4000e6, 1e8);
        }
        uint256 commitTime = regime == 0 ? BEFORE_FAD - 1 hours : BEFORE_FAD;
        vm.warp(commitTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.prank(ACCOUNT);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, close ? 0 : 2000e6, 0, close);
        if (degraded) {
            uint256 cash = usdc.balanceOf(address(pool));
            usdc.burn(address(pool), cash);
            _close(LATCH, CfdTypes.Side.LONG, 10_000e18, 1e8);
            assertTrue(engine.degradedMode(), "Executed partial close latches cash insolvency");
            usdc.mint(address(pool), cash);
        }
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(ACCOUNT);
        BeforeExecution memory before_ = BeforeExecution({
            trader: clearinghouse.balanceUsdc(ACCOUNT),
            keeper: clearinghouse.balanceUsdc(KEEPER),
            custody: usdc.balanceOf(address(clearinghouse)),
            bounty: reservation.executionBountyUsdc,
            margin: reservation.committedMarginUsdc,
            treasury: clearinghouse.balanceUsdc(engine.protocolTreasury()),
            poolCash: usdc.balanceOf(address(pool))
        });
        vm.warp(regime == 0 ? commitTime + 1 : regime == 1 ? BEFORE_FAD + 1 : BEFORE_FAD + 1801);
        baseMockPyth.setAllPrices(_basePythFeedIds(), 100_000_000, -8, block.timestamp);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        assertEq(engine.isFadWindow(), regime != 0);
        assertEq(engine.isOracleFrozen(), regime == 2);
        _startRecordingLogs();
        vm.prank(KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, priceData);
        _assertRow(regime, action, degraded, result, before_);
    }

    function _assertRow(
        uint8 regime,
        uint8 action,
        bool degraded,
        OrderV3Types.ExecutionResult memory result,
        BeforeExecution memory before_
    ) private {
        bool close = action != 0;
        IOrderRouterAccounting.AccountReservationView memory after_ = router.getAccountReservations(ACCOUNT);
        if (!close && regime != 0) {
            assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
            assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.CloseOnly));
            assertEq(router.nextExecuteId(), 1);
            assertEq(after_.pendingOrderCount, 1);
            assertEq(after_.committedMarginUsdc, before_.margin);
            assertEq(after_.executionBountyUsdc, before_.bounty);
            assertEq(clearinghouse.balanceUsdc(ACCOUNT), before_.trader);
            assertEq(clearinghouse.balanceUsdc(KEEPER), before_.keeper);
            assertEq(usdc.balanceOf(address(clearinghouse)), before_.custody);
            return;
        }
        bool rejected = !close && degraded;
        assertEq(
            uint8(result.status),
            uint8(rejected ? OrderV3Types.LifecycleStatus.Failed : OrderV3Types.LifecycleStatus.Executed)
        );
        assertEq(
            uint8(result.terminalReason),
            uint8(rejected ? OrderV3Types.TerminalReason.PlannerRejected : OrderV3Types.TerminalReason.Executed)
        );
        assertEq(after_.pendingOrderCount, 0);
        assertEq(after_.committedMarginUsdc, 0);
        assertEq(after_.executionBountyUsdc, 0);
        assertEq(router.nextExecuteId(), 0);
        assertEq(clearinghouse.balanceUsdc(KEEPER), before_.keeper + before_.bounty);
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), 1);
        assertEq(receipt.bountyRecipient, KEEPER);
        assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.Paid));
        assertEq(receipt.bountyUsdc, before_.bounty);
        assertEq(uint8(receipt.executionMode), regime + 1, "Receipt records the actual calendar mode");
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, (action == 1 || rejected) ? 0 : 10_000e18);
        if (rejected) {
            assertEq(clearinghouse.balanceUsdc(ACCOUNT), before_.trader - before_.bounty);
            assertEq(
                usdc.balanceOf(address(clearinghouse)), before_.custody, "Terminal cleanup only reallocates custody"
            );
            assertEq(receipt.failureSelector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
            assertEq(receipt.failureCode, 2, "Live degraded open must fail the DEGRADED_MODE admission rule");
        } else {
            uint256 frozenSpread = close && regime == 2 ? 50e6 : 0;
            assertEq(clearinghouse.balanceUsdc(ACCOUNT), before_.trader - before_.bounty - 4e6 - frozenSpread);
            assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), before_.treasury + 4e6);
            assertEq(usdc.balanceOf(address(clearinghouse)), before_.custody - frozenSpread);
            assertEq(usdc.balanceOf(address(pool)), before_.poolCash + frozenSpread);
        }
    }

}

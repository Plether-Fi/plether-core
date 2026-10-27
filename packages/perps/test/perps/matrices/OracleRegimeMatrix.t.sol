// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

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
            uint256 cash = settlementToken.balanceOf(address(pool));
            settlementToken.burn(address(pool), cash);
            _close(LATCH, CfdTypes.Side.LONG, 10_000e18, 1e8);
            assertTrue(engine.degradedMode());
            settlementToken.mint(address(pool), cash);
        }
        uint256 liquidationTime = regime == 0 ? BEFORE_FAD - 1 hours : regime == 1 ? BEFORE_FAD + 1 : BEFORE_FAD + 1801;
        vm.warp(liquidationTime);
        uint256 ageLimit = regime == 2 ? engine.fadMaxStaleness() : pletherOracle.liquidationStalenessLimit();
        uint256 age = boundary == 0 ? 0 : ageLimit + boundary - 2;
        bytes[] memory priceData;
        if (regime == 2) {
            uint256 precloseTime = boundary == 0 ? BEFORE_FAD : liquidationTime - age;
            vm.warp(precloseTime);
            router.updateMarkPrice(_signedLiveData(150_000_000, uint64(precloseTime)));
            vm.warp(liquidationTime);
            priceData = new bytes[](0);
        } else {
            priceData = _signedLiveData(150_000_000, uint64(liquidationTime - age));
        }
        uint256 executionPrice = regime == 2 ? 150_030_000 : 150_000_000;
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(ACCOUNT, executionPrice);
        assertTrue(preview.liquidatable, "Every row starts with an actually liquidatable position");
        uint256 keeperBefore = clearinghouse.balanceAssets(KEEPER);
        uint256 custodyBefore = settlementToken.balanceOf(address(clearinghouse));
        uint256 cashBefore = settlementToken.balanceOf(address(pool));
        if (boundary == 3) {
            if (regime == 2) {
                vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
            } else {
                vm.expectRevert(bytes("feed not found within range"));
            }
        }
        vm.prank(KEEPER);
        router.executeLiquidation(ACCOUNT, priceData);
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        if (boundary == 3) {
            assertEq(size, 10_000e18);
            assertEq(clearinghouse.balanceAssets(KEEPER), keeperBefore);
            assertEq(settlementToken.balanceOf(address(pool)), cashBefore);
            assertEq(settlementToken.balanceOf(address(clearinghouse)), custodyBefore);
        } else {
            assertEq(size, 0);
            assertEq(clearinghouse.balanceAssets(KEEPER), keeperBefore + preview.keeperBountyAssets);
            assertEq(
                settlementToken.balanceOf(address(pool)) - cashBefore,
                custodyBefore - settlementToken.balanceOf(address(clearinghouse))
            );
            assertEq(engine.traderClaimBalanceAssets(ACCOUNT), 0);
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
            uint256 cash = settlementToken.balanceOf(address(pool));
            settlementToken.burn(address(pool), cash);
            _close(LATCH, CfdTypes.Side.LONG, 10_000e18, 1e8);
            assertTrue(engine.degradedMode(), "Executed partial close latches cash insolvency");
            settlementToken.mint(address(pool), cash);
        }
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(ACCOUNT);
        BeforeExecution memory before_ = BeforeExecution({
            trader: clearinghouse.balanceAssets(ACCOUNT),
            keeper: clearinghouse.balanceAssets(KEEPER),
            custody: settlementToken.balanceOf(address(clearinghouse)),
            bounty: reservation.executionBountyAssets,
            margin: reservation.committedMarginAssets,
            treasury: clearinghouse.balanceAssets(engine.protocolTreasury()),
            poolCash: settlementToken.balanceOf(address(pool))
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
            assertEq(after_.committedMarginAssets, before_.margin);
            assertEq(after_.executionBountyAssets, before_.bounty);
            assertEq(clearinghouse.balanceAssets(ACCOUNT), before_.trader);
            assertEq(clearinghouse.balanceAssets(KEEPER), before_.keeper);
            assertEq(settlementToken.balanceOf(address(clearinghouse)), before_.custody);
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
        assertEq(after_.committedMarginAssets, 0);
        assertEq(after_.executionBountyAssets, 0);
        assertEq(router.nextExecuteId(), 0);
        assertEq(clearinghouse.balanceAssets(KEEPER), before_.keeper + before_.bounty);
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), 1);
        assertEq(receipt.bountyRecipient, receipt.bountyAssets == 0 ? address(0) : KEEPER);
        assertEq(
            uint8(receipt.bountyDisposition),
            uint8(receipt.bountyAssets == 0 ? OrderV3Types.BountyDisposition.None : OrderV3Types.BountyDisposition.Paid)
        );
        assertEq(receipt.bountyAssets, before_.bounty);
        assertEq(uint8(receipt.executionMode), regime + 1, "Receipt records the actual calendar mode");
        (uint256 size,,,,,,) = engine.positions(ACCOUNT);
        assertEq(size, (action == 1 || rejected) ? 0 : 10_000e18);
        if (rejected) {
            assertEq(clearinghouse.balanceAssets(ACCOUNT), before_.trader - before_.bounty);
            assertEq(
                settlementToken.balanceOf(address(clearinghouse)),
                before_.custody,
                "Terminal cleanup only reallocates custody"
            );
            assertEq(receipt.failureSelector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
            assertEq(receipt.failureCode, 2, "Live degraded open must fail the DEGRADED_MODE admission rule");
        } else {
            uint256 frozenSpread = close && regime == 2 ? 50e6 : 0;
            assertEq(clearinghouse.balanceAssets(ACCOUNT), before_.trader - before_.bounty - 4e6 - frozenSpread);
            assertEq(clearinghouse.balanceAssets(engine.protocolTreasury()), before_.treasury + 4e6);
            assertEq(settlementToken.balanceOf(address(clearinghouse)), before_.custody - frozenSpread);
            assertEq(settlementToken.balanceOf(address(pool)), before_.poolCash + frozenSpread);
        }
    }

    function _signedLiveData(
        uint256 price,
        uint64 tick
    ) private pure returns (bytes[] memory data) {
        bytes32[] memory ids = _basePythFeedIds();
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            updates[i] = MockPyth.FeedUpdate(ids[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, tick, 0));
        }
        data = new bytes[](1);
        data[0] = abi.encode(updates);
    }

}

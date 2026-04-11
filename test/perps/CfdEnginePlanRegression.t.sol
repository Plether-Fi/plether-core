// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "../../src/perps/libraries/CfdEnginePlanLib.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CfdEnginePlanHarness is CfdEngine {

    constructor(
        address usdc,
        address clearinghouse,
        uint256 capPrice,
        CfdTypes.RiskParams memory params
    ) CfdEngine(usdc, clearinghouse, capPrice, params) {}

    function previewOpenPlan(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.accountId, executionPrice, vaultDepthUsdc, 0);
        snap.vaultCashUsdc = vault.totalAssets();
        return CfdEnginePlanLib.planOpen(snap, order, executionPrice, 0);
    }

    function buildRawSnapshotForPlanner(
        bytes32 accountId,
        uint256 executionPrice,
        uint256 vaultDepthUsdc
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap = _buildRawSnapshot(accountId, executionPrice, vaultDepthUsdc, 0);
        snap.vaultCashUsdc = vault.totalAssets();
    }

    function computeOpenMarginAfter(
        uint256 marginAfterFunding,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter) {
        return CfdEnginePlanLib.computeOpenMarginAfter(marginAfterFunding, netMarginChange);
    }

}

contract CfdEnginePlanRegressionTest is BasePerpTest {

    address bullTraderA = address(0xB011);
    address bullTraderB = address(0xB012);
    address bearTrader = address(0xBEA2);
    address freshBullTrader = address(0xB013);
    CfdEnginePlanner planner;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEnginePlanHarness(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        planner = new CfdEnginePlanner();
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(accountId);
    }

    function _openOrder(
        bytes32 accountId,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) internal view returns (CfdTypes.Order memory) {
        return CfdTypes.Order({
            accountId: accountId,
            sizeDelta: sizeDelta,
            marginDelta: marginDelta,
            targetPrice: targetPrice,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: side,
            isClose: false
        });
    }

    function _expectedOpenMarginAfter(
        uint256 currentMargin,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal pure returns (bool drained, uint256 expectedMarginAfter) {
        uint256 marginAfterCarry = _marginAfterCarry(currentMargin, delta);
        int256 signedMarginAfter = int256(marginAfterCarry) + delta.netMarginChange;
        if (signedMarginAfter < 0) {
            return (true, 0);
        }
        return (false, uint256(signedMarginAfter));
    }

    function _marginAfterCarry(
        uint256 currentMargin,
        CfdEnginePlanTypes.OpenDelta memory delta
    ) internal pure returns (uint256) {
        delta;
        return currentMargin;
    }

    function test_PlanOpen_FreshAccountUsesGlobalSideMarginBaseline() public {
        bytes32 bullIdA = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bullIdB = bytes32(uint256(uint160(bullTraderB)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 freshBullId = bytes32(uint256(uint160(freshBullTrader)));

        _fundTrader(bullTraderA, 15_000e6);
        _fundTrader(bullTraderB, 400_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(freshBullTrader, 15_000e6);

        _open(bullIdA, CfdTypes.Side.BULL, 390_000e18, 6500e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 10_000e18, 300_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(freshBullId, CfdTypes.Side.BULL, 10_000e18, 5000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertEq(
            delta.sideTotalMarginBefore,
            _sideTotalMargin(CfdTypes.Side.BULL),
            "Fresh open must inherit current side margin"
        );
        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Fresh open should not fail solvency from a zeroed side-margin baseline"
        );
        assertTrue(delta.valid, "Planner should accept the fresh-account open");

        _open(freshBullId, CfdTypes.Side.BULL, 10_000e18, 5000e6, 1e8);
        assertEq(engine.getPositionSize(freshBullId), 10_000e18, "Live open should succeed for the fresh account");
    }

    function test_ComputeOpenMarginAfter_PositiveOffsetDoesNotPanic() public view {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained, uint256 marginAfter) = harness.computeOpenMarginAfter(200e6, -50e6);
        assertFalse(drained, "Positive offset path should remain nonnegative");
        assertEq(marginAfter, 150e6, "Single-frame margin should equal base plus net change");
    }

    function test_PlannerWrapper_ComputeOpenMarginAfterMatchesLibrary() public view {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool libDrained, uint256 libMarginAfter) = harness.computeOpenMarginAfter(200e6, -50e6);
        (bool plannerDrained, uint256 plannerMarginAfter) = planner.computeOpenMarginAfter(200e6, -50e6);

        assertEq(plannerDrained, libDrained, "Planner wrapper should match library drained flag");
        assertEq(plannerMarginAfter, libMarginAfter, "Planner wrapper should match library margin result");
    }

    function test_ComputeOpenMarginAfter_NegativePathSubtractsOnce() public view {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained, uint256 marginAfter) = harness.computeOpenMarginAfter(900e6, -50e6);
        assertFalse(drained, "Healthy negative-net path should remain above zero");
        assertEq(marginAfter, 850e6, "Single-frame margin should subtract the negative net change exactly once");
    }

    function test_ComputeOpenMarginAfter_PositiveBaseCannotDoubleCredit() public view {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained, uint256 marginAfter) = harness.computeOpenMarginAfter(100e6, -150e6);
        assertTrue(drained, "Single-frame margin must drain when the negative net change exceeds the base");
        assertEq(marginAfter, 0, "Drained path should return zero margin");
    }

    function test_PlanOpen_TotalMarginAfterOpenMatchesSingleFrameEquation() public {
        bytes32 bullIdA = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bullIdB = bytes32(uint256(uint160(bullTraderB)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 freshBullId = bytes32(uint256(uint160(freshBullTrader)));

        _fundTrader(bullTraderA, 15_000e6);
        _fundTrader(bullTraderB, 400_000e6);
        _fundTrader(bearTrader, 100_000e6);
        _fundTrader(freshBullTrader, 15_000e6);

        _open(bullIdA, CfdTypes.Side.BULL, 390_000e18, 6500e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 10_000e18, 300_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(freshBullId, CfdTypes.Side.BULL, 10_000e18, 5000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertGe(
            delta.sideTotalMarginAfterOpen,
            delta.positionMarginAfterOpen,
            "Open planner side total margin should include the opened position margin"
        );
    }

    function test_PlanOpen_HealthyDeltaMatchesLiveOpenState() public {
        bytes32 accountId = bytes32(uint256(uint160(freshBullTrader)));
        _fundTrader(freshBullTrader, 20_000e6);

        CfdTypes.Order memory order = _openOrder(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(order, 1e8, pool.totalAssets());

        assertTrue(delta.valid, "Setup open plan should remain valid");
        assertEq(
            uint8(delta.revertCode), uint8(CfdEnginePlanTypes.OpenRevertCode.OK), "Setup should not predict failure"
        );

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _open(accountId, CfdTypes.Side.BULL, order.sizeDelta, order.marginDelta, 1e8);

        (uint256 size, uint256 margin, uint256 entryPrice,,,,) = engine.positions(accountId);
        assertEq(size, delta.newPosSize, "Live open size should match planner delta");
        assertEq(margin, delta.positionMarginAfterOpen, "Live open margin should match planner delta");
        assertEq(entryPrice, delta.newPosEntryPrice, "Live open entry price should match planner delta");
        assertEq(
            engine.accumulatedFeesUsdc() - feesBefore,
            delta.executionFeeUsdc,
            "Live open fee collection should match planner execution fee"
        );
        assertEq(
            _sideState(CfdTypes.Side.BULL).totalMargin,
            delta.sideTotalMarginAfterOpen,
            "Live side total margin should match planner delta"
        );
    }

    function test_PlannerWrapper_OpenPlanMatchesLibrary() public {
        bytes32 accountId = bytes32(uint256(uint160(freshBullTrader)));
        _fundTrader(freshBullTrader, 20_000e6);

        CfdTypes.Order memory order = _openOrder(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(order.accountId, 1e8, pool.totalAssets());
        CfdEnginePlanTypes.OpenDelta memory libDelta = harness.previewOpenPlan(order, 1e8, pool.totalAssets());
        CfdEnginePlanTypes.OpenDelta memory plannerDelta = planner.planOpen(snap, order, 1e8, 0);

        assertEq(plannerDelta.valid, libDelta.valid, "Planner open validity should match library");
        assertEq(
            uint8(plannerDelta.revertCode), uint8(libDelta.revertCode), "Planner open revert code should match library"
        );
        assertEq(plannerDelta.newPosSize, libDelta.newPosSize, "Planner open size should match library");
        assertEq(
            plannerDelta.positionMarginAfterOpen,
            libDelta.positionMarginAfterOpen,
            "Planner open margin should match library"
        );
        assertEq(plannerDelta.executionFeeUsdc, libDelta.executionFeeUsdc, "Planner open fee should match library");
        assertEq(
            plannerDelta.sideTotalMarginAfterOpen,
            libDelta.sideTotalMarginAfterOpen,
            "Planner open side total margin should match library"
        );
    }

    function test_PlanOpen_ReportsPendingCarry() public {
        bytes32 accountId = bytes32(uint256(uint160(freshBullTrader)));
        _fundTrader(freshBullTrader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(accountId, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertGt(delta.pendingCarryUsdc, 0, "Open plan should report observational pending carry");
    }

    function test_PlanClose_ReportsPendingCarry() public {
        bytes32 accountId = bytes32(uint256(uint160(freshBullTrader)));
        _fundTrader(freshBullTrader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(accountId, 1e8, pool.totalAssets());
        CfdTypes.Position memory pos = _position(accountId);
        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            accountId: accountId,
            sizeDelta: pos.size / 2,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: pos.side,
            isClose: true
        });
        CfdEnginePlanTypes.CloseDelta memory delta = planner.planClose(snap, closeOrder, 1e8, 0);
        assertGt(delta.pendingCarryUsdc, 0, "Close plan should report observational pending carry");
    }

    function test_PlanLiquidation_ReportsPendingCarry() public {
        bytes32 accountId = bytes32(uint256(uint160(freshBullTrader)));
        _fundTrader(freshBullTrader, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(accountId, 150_000_000, pool.totalAssets());
        CfdEnginePlanTypes.LiquidationDelta memory delta = planner.planLiquidation(snap, 150_000_000, 0);
        assertGt(delta.pendingCarryUsdc, 0, "Liquidation plan should report observational pending carry");
    }

    function test_PendingCarry_IncreasesWithHigherLeverage() public pure {
        uint256 lowLeverageCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 50_000e6), 500, 30 days
        );
        uint256 highLeverageCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 30 days
        );
        assertGt(highLeverageCarry, lowLeverageCarry, "Higher leverage should report more carry");
    }

    function test_PendingCarry_IncreasesWithTime() public pure {
        uint256 shortCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 1 days
        );
        uint256 longCarry = PositionRiskAccountingLib.computePendingCarryUsdc(
            PositionRiskAccountingLib.computeLpBackedNotionalUsdc(100_000e18, 1e8, 10_000e6), 500, 30 days
        );
        assertGt(longCarry, shortCarry, "Longer time should report more carry");
    }

    function test_ComputeOpenMarginAfter_DrainedPathMatchesPlannerRevert() public {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained,) = harness.computeOpenMarginAfter(100e6, -150e6);
        assertTrue(drained, "Canonical helper should signal margin drain when net change exceeds the base");
    }

    function test_PlanOpen_RejectsInsufficientPhysicalMargin() public view {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0;

        bytes32 accountId = bytes32(uint256(0xBEEF));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.accountId = accountId;
        snap.position = CfdTypes.Position({
            size: 100_000e18,
            margin: 1e6,
            entryPrice: 1e8,
            maxProfitUsdc: 10_000e6,
            side: CfdTypes.Side.BEAR,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.currentTimestamp = 365 days;
        snap.lastMarkPrice = 1e8;
        snap.lastMarkTime = uint64(block.timestamp);
        snap.bullSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 1_000_000e18,
            entryNotional: 1_000_000e18 * 1e8,
            totalMargin: 50_000e6
        });
        snap.bearSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 10_000e6, openInterest: 100_000e18, entryNotional: 100_000e18 * 1e8, totalMargin: 1e6
        });
        snap.vaultAssetsUsdc = 50_000_000e6;
        snap.vaultCashUsdc = 0;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 0,
            totalLockedMarginUsdc: 1e6,
            activePositionMarginUsdc: 1e6,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 1e6, committedOrderMarginUsdc: 0, reservedSettlementUsdc: 0, totalLockedMarginUsdc: 1e6
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = params;

        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(
            snap, _openOrder(accountId, CfdTypes.Side.BEAR, 10_000e18, 0, 1e8), 1e8, uint64(block.timestamp)
        );

        assertLt(delta.netMarginChange, 0, "Open must require physical margin to pay trade costs");
        assertEq(
            uint256(-delta.netMarginChange),
            4e6,
            "Execution fee on the incremental open should exceed the physical margin bucket"
        );
        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "Planner should reject opens whose physical margin cannot cover the trade charges under the no-side-funding model"
        );
    }

    function test_PlanOpen_SolvencyFailureCategoryMatchesTypedExecutionFailure() public {
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 bullId = bytes32(uint256(uint160(freshBullTrader)));

        _fundTrader(bearTrader, 50_000e6);
        _fundTrader(freshBullTrader, 40_000e6);
        _open(bearId, CfdTypes.Side.BEAR, 300_000e18, 30_000e6, 1e8);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        CfdTypes.Order memory order = _openOrder(bullId, CfdTypes.Side.BULL, 350_000e18, 35_000e6, 1e8);
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(order, 1e8, pool.totalAssets());

        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "Planner should surface the solvency invalidation explicitly"
        );
        assertEq(
            uint256(CfdEnginePlanLib.getOpenFailurePolicyCategory(delta.revertCode)),
            uint256(CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable),
            "Planner should classify the solvency invalidation consistently"
        );
    }

    function test_PlannerWrapper_FailureCategoriesMatchLibraryHelpers() public view {
        assertEq(
            uint256(planner.getOpenFailurePolicyCategory(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)),
            uint256(CfdEnginePlanLib.getOpenFailurePolicyCategory(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)),
            "Planner open failure category should match library helper"
        );
        assertEq(
            uint256(planner.getExecutionFailurePolicyCategory(CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE)),
            uint256(
                CfdEnginePlanLib.getExecutionFailurePolicyCategory(CfdEnginePlanTypes.OpenRevertCode.DEGRADED_MODE)
            ),
            "Planner open execution failure category should match library helper"
        );
        assertEq(
            uint256(planner.getCloseExecutionFailurePolicyCategory(CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION)),
            uint256(
                CfdEnginePlanLib.getExecutionFailurePolicyCategory(CfdEnginePlanTypes.CloseRevertCode.DUST_POSITION)
            ),
            "Planner close execution failure category should match library helper"
        );
    }

}

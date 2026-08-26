// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {CfdEngineSettlementLib} from "@plether/perps/libraries/CfdEngineSettlementLib.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract CfdEnginePlanHarness is CfdEngine {

    constructor(
        address usdc,
        address clearinghouse,
        uint256 capPrice,
        CfdTypes.RiskParams memory params,
        uint256 frozenCloseSpreadBps
    ) CfdEngine(usdc, clearinghouse, capPrice, params, frozenCloseSpreadBps) {}

    function previewOpenPlan(
        CfdTypes.Order memory order,
        uint256 executionPrice,
        uint256 poolDepthUsdc
    ) external view returns (CfdEnginePlanTypes.OpenDelta memory delta) {
        CfdEnginePlanTypes.RawSnapshot memory snap = _buildRawSnapshot(order.account, executionPrice, poolDepthUsdc, 0);
        snap.poolCashUsdc = pool.totalAssets();
        return CfdEnginePlanLib.planOpen(snap, order, executionPrice, 0);
    }

    function buildRawSnapshotForPlanner(
        address account,
        uint256 executionPrice,
        uint256 poolDepthUsdc
    ) external view returns (CfdEnginePlanTypes.RawSnapshot memory snap) {
        snap = _buildRawSnapshot(account, executionPrice, poolDepthUsdc, 0);
        snap.poolCashUsdc = pool.totalAssets();
    }

    function computeOpenMarginAfter(
        uint256 marginAfterCarry,
        int256 netMarginChange
    ) external pure returns (bool drained, uint256 marginAfter) {
        return CfdEnginePlanLib.computeOpenMarginAfter(marginAfterCarry, netMarginChange);
    }

}

contract CfdEnginePlanRegressionTest is BasePerpTest {

    address longTraderA = address(0xB011);
    address longTraderB = address(0xB012);
    address shortTrader = address(0xBEA2);
    address freshLongTrader = address(0xB013);
    CfdEnginePlanner planner;
    MockPyth mockPyth;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEnginePlanHarness(
            address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlementSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlementSidecar), address(engineAdmin));
        _syncEngineAdmin();
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));

        mockPyth = new MockPyth();
        mockPyth.setPrice(bytes32(uint256(1)), int64(100_000_000), int32(-8), uint64(block.timestamp));
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(1));
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e18;
        uint256[] memory basePrices = new uint256[](1);
        basePrices[0] = 1e8;

        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, basePrices, new bool[](1)
        );
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(pool));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
    }

    function _position(
        address account
    ) internal view returns (CfdTypes.Position memory pos) {
        (pos.size, pos.margin, pos.entryPrice, pos.maxProfitUsdc, pos.side, pos.lastUpdateTime, pos.vpiAccrued) =
            engine.positions(account);
    }

    function _openOrder(
        address account,
        CfdTypes.Side side,
        uint256 sizeDelta,
        uint256 marginDelta,
        uint256 targetPrice
    ) internal view returns (CfdTypes.Order memory) {
        return CfdTypes.Order({
            account: account,
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

    function _attachFullRateCarry(
        CfdEnginePlanTypes.RawSnapshot memory snap,
        CfdTypes.Side side,
        uint256 borrowBaseUsdc,
        uint256 timeDelta
    ) internal pure {
        uint256 carryIndex =
            PositionRiskAccountingLib.computeCarryIndexIncrement(snap.riskParams.baseCarryBps, timeDelta);
        snap.positionBorrowBaseUsdc = borrowBaseUsdc;
        snap.positionLastCarryIndex = 0;
        if (side == CfdTypes.Side.LONG) {
            snap.longSide.borrowBaseUsdc = borrowBaseUsdc;
            snap.longSide.carryIndex = carryIndex;
        } else {
            snap.shortSide.borrowBaseUsdc = borrowBaseUsdc;
            snap.shortSide.carryIndex = carryIndex;
        }
    }

    function test_CloseSettlementResult_FeeOffsetSeparatesRetainedFee() public pure {
        CfdEngineSettlementLib.CloseSettlementResult memory result =
            CfdEngineSettlementLib.closeSettlementResult(2e6, 2e6, 10e6, 0);

        assertEq(result.seizedUsdc, 2e6, "Covered net close debit should be seized");
        assertEq(result.shortfallUsdc, 0, "Covered net close debit should have no shortfall");
        assertEq(result.collectedExecFeeUsdc, 2e6, "Only seized cash can be cash-collected");
        assertEq(result.retainedExecFeeUsdc, 8e6, "Profit-offset fee should be marked for pool top-up");
        assertEq(result.badDebtUsdc, 0, "Fee offset by retained trader profit is not bad debt");
    }

    function test_CloseSettlementResult_UnderfundedLossKeepsProtocolFeeSenior() public pure {
        CfdEngineSettlementLib.CloseSettlementResult memory result =
            CfdEngineSettlementLib.closeSettlementResult(45e6, 50e6, 10e6, 0);

        assertEq(result.seizedUsdc, 45e6, "Available close collateral should be seized");
        assertEq(result.shortfallUsdc, 5e6, "Uncovered close debit should remain shortfall");
        assertEq(result.collectedExecFeeUsdc, 10e6, "Protocol fee should be senior in seized cash");
        assertEq(result.retainedExecFeeUsdc, 0, "Underfunded losses do not create retained-profit fees");
        assertEq(result.badDebtUsdc, 5e6, "Remaining shortfall should be LP bad debt");
    }

    function test_CloseSettlementResult_DeepShortfallDoesNotTopUpUnpaidFee() public pure {
        CfdEngineSettlementLib.CloseSettlementResult memory result =
            CfdEngineSettlementLib.closeSettlementResult(5e6, 50e6, 10e6, 0);

        assertEq(result.seizedUsdc, 5e6, "Only available close collateral should be seized");
        assertEq(result.shortfallUsdc, 45e6, "Uncovered close debit should remain shortfall");
        assertEq(result.collectedExecFeeUsdc, 5e6, "Cash-collected fee should be bounded by seized cash");
        assertEq(result.retainedExecFeeUsdc, 0, "Missing margin is not retained trader profit");
        assertEq(result.badDebtUsdc, 40e6, "Only the non-fee shortfall should become LP bad debt");
    }

    function test_CloseSettlementResult_FrozenSpreadIsJuniorToFeeAndBaseDebt() public pure {
        CfdEngineSettlementLib.CloseSettlementResult memory result =
            CfdEngineSettlementLib.closeSettlementResult(45e6, 50e6, 10e6, 8e6);

        assertEq(result.seizedUsdc, 45e6, "Available close collateral should be seized");
        assertEq(result.shortfallUsdc, 5e6, "Only the junior frozen spread should remain uncollected");
        assertEq(result.collectedExecFeeUsdc, 10e6, "Protocol fee should be senior");
        assertEq(result.badDebtUsdc, 0, "Base close debt should be paid before the frozen spread");
    }

    function test_CloseSettlementResult_RetainedSpreadConservesAssessment() public pure {
        CfdEngineSettlementLib.CloseSettlementResult memory result =
            CfdEngineSettlementLib.closeSettlementResult(5e6, 5e6, 10e6, 8e6);

        assertEq(result.retainedExecFeeUsdc, 10e6, "Profit offset should retain the full execution fee");
        assertEq(result.seizedUsdc, 5e6, "Net close debit should collect the residual spread");
        assertEq(result.shortfallUsdc, 0, "Retained and cash-collected value should settle the full spread");
        assertEq(result.badDebtUsdc, 0, "Spread accounting should not create base bad debt");
    }

    function test_CloseLoss_FeeOffsetTopUpMatchesRetainedTraderProfit() public {
        address account = address(0xFEE0FF);
        uint256 size = 25_000e18;
        uint256 openPrice = 1e8;
        uint256 closePrice = 99_968_000;
        uint256 profitUsdc = 8e6;

        _fundTrader(account, 2000e6);
        _open(account, CfdTypes.Side.LONG, size, 1000e6, openPrice);

        uint256 closeFeeUsdc = _engineExecutionFeeUsdc(size, closePrice);
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, size, closePrice);

        assertTrue(preview.valid, "Fee-offset close should preview as valid");
        assertEq(preview.realizedPnlUsdc, int256(profitUsdc), "Setup should produce the intended trader profit");
        assertEq(preview.executionFeeUsdc, closeFeeUsdc, "Preview should retain the total collectible fee");
        assertEq(
            preview.seizedCollateralUsdc, 0, "Price collateral should not be seized when the trader has a price gain"
        );
        assertEq(preview.badDebtUsdc, 0, "Retained trader profit should not be bad debt");

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 poolAssetsBefore = pool.totalAssets();
        CloseParitySnapshot memory beforeSnapshot = _captureCloseParitySnapshot(account);
        bool degradedBefore = engine.degradedMode();

        _close(account, CfdTypes.Side.LONG, size, closePrice);

        CloseParityObserved memory observed = _observeCloseParity(account, beforeSnapshot);
        _assertClosePreviewMatchesObserved(preview, observed, degradedBefore);
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            closeFeeUsdc,
            "Treasury should receive seized cash plus retained-profit top-up"
        );
        assertEq(
            poolAssetsBefore - pool.totalAssets(),
            profitUsdc,
            "Pool should pass through the trader profit it retained against the fee"
        );
    }

    function test_OracleFrozenZeroSettlement_CreditsFeeAndRetainsSpreadForLps() public {
        address account = address(0xFEE000);
        uint256 size = 5000e18;
        uint256 openPrice = 100_540_000;
        uint256 closePrice = 100_000_000;

        vm.warp(1_709_985_600);
        _fundTrader(account, 300e6);
        _open(account, CfdTypes.Side.LONG, size, 200e6, openPrice);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, size, closePrice);
        assertTrue(preview.valid, "Exact-zero frozen close should be valid");
        assertEq(preview.realizedPnlUsdc, int256(27e6), "Price profit should exactly offset close charges");
        assertEq(preview.executionFeeUsdc, 2e6, "Close should assess the normal execution fee");
        assertEq(preview.frozenSpreadUsdc, 25e6, "Close should assess the fixed LP-owned spread");
        assertEq(preview.freshTraderPayoutUsdc, 0, "Exact-zero settlement should not create a payout");
        assertEq(preview.seizedCollateralUsdc, 0, "Exact-zero settlement should not seize collateral");

        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 poolAssetsBefore = pool.totalAssets();
        _close(account, CfdTypes.Side.LONG, size, closePrice);

        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - treasuryBefore,
            preview.executionFeeUsdc,
            "Exact-zero settlement should credit the full execution fee to treasury"
        );
        assertEq(
            poolAssetsBefore - pool.totalAssets(),
            preview.executionFeeUsdc,
            "Only the protocol fee should leave LP cash; the frozen spread remains LP-owned"
        );
    }

    function test_PlanOpen_FreshAccountUsesGlobalSideMarginBaseline() public {
        address longIdA = longTraderA;
        address longIdB = longTraderB;
        address shortAccount = shortTrader;
        address freshLongAccount = freshLongTrader;

        _fundTrader(longTraderA, 15_000e6);
        _fundTrader(longTraderB, 400_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _fundTrader(freshLongTrader, 15_000e6);

        _open(longIdA, CfdTypes.Side.LONG, 390_000e18, 6500e6, 1e8);
        _open(longIdB, CfdTypes.Side.LONG, 10_000e18, 300_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(freshLongAccount, CfdTypes.Side.LONG, 10_000e18, 5000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertEq(
            delta.sideTotalMarginBefore,
            _sideTotalMargin(CfdTypes.Side.LONG),
            "Fresh open must inherit current side margin"
        );
        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Fresh open should not fail solvency from a zeroed side-margin baseline"
        );
        assertTrue(delta.valid, "Planner should accept the fresh-account open");

        _open(freshLongAccount, CfdTypes.Side.LONG, 10_000e18, 5000e6, 1e8);
        (uint256 size,,,,,,) = engine.positions(freshLongAccount);
        assertEq(size, 10_000e18, "Live open should succeed for the fresh account");
    }

    function test_ComputeOpenMarginAfter_PositiveOffsetDoesNotPanic() public view {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained, uint256 marginAfter) = harness.computeOpenMarginAfter(200e6, -50e6);
        assertFalse(drained, "Positive offset path should remain nonnegative");
        assertEq(marginAfter, 150e6, "Single-frame margin should equal base plus net change");
    }

    function test_PlannerWrapper_ComputeOpenMarginAfter_UsesExpectedArithmetic() public view {
        (bool healthyDrained, uint256 healthyMarginAfter) = planner.computeOpenMarginAfter(200e6, -50e6);
        assertFalse(healthyDrained, "Planner wrapper should keep healthy offsets above zero");
        assertEq(healthyMarginAfter, 150e6, "Planner wrapper should subtract the negative net change exactly once");

        (bool drained, uint256 drainedMarginAfter) = planner.computeOpenMarginAfter(40e6, -50e6);
        assertTrue(drained, "Planner wrapper should flag margin exhaustion when costs exceed margin");
        assertEq(drainedMarginAfter, 0, "Planner wrapper should floor drained margin at zero");
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
        address longIdA = longTraderA;
        address longIdB = longTraderB;
        address shortAccount = shortTrader;
        address freshLongAccount = freshLongTrader;

        _fundTrader(longTraderA, 15_000e6);
        _fundTrader(longTraderB, 400_000e6);
        _fundTrader(shortTrader, 100_000e6);
        _fundTrader(freshLongTrader, 15_000e6);

        _open(longIdA, CfdTypes.Side.LONG, 390_000e18, 6500e6, 1e8);
        _open(longIdB, CfdTypes.Side.LONG, 10_000e18, 300_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(freshLongAccount, CfdTypes.Side.LONG, 10_000e18, 5000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertGe(
            delta.sideTotalMarginAfterOpen,
            delta.positionMarginAfterOpen,
            "Open planner side total margin should include the opened position margin"
        );
    }

    function test_PlanOpen_HealthyDeltaMatchesLiveOpenState() public {
        address account = freshLongTrader;
        _fundTrader(freshLongTrader, 20_000e6);

        CfdTypes.Order memory order = _openOrder(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(order, 1e8, pool.totalAssets());

        assertTrue(delta.valid, "Setup open plan should remain valid");
        assertEq(
            uint8(delta.revertCode), uint8(CfdEnginePlanTypes.OpenRevertCode.OK), "Setup should not predict failure"
        );

        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        _open(account, CfdTypes.Side.LONG, order.sizeDelta, order.marginDelta, 1e8);

        (uint256 size, uint256 margin, uint256 entryPrice,,,,) = engine.positions(account);
        assertEq(size, delta.newPosSize, "Live open size should match planner delta");
        assertEq(margin, delta.positionMarginAfterOpen, "Live open margin should match planner delta");
        assertEq(entryPrice, delta.newPosEntryPrice, "Live open entry price should match planner delta");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            delta.executionFeeUsdc,
            "Live open fee collection should match planner execution fee"
        );
        assertEq(
            _sideState(CfdTypes.Side.LONG).totalMargin,
            delta.sideTotalMarginAfterOpen,
            "Live side total margin should match planner delta"
        );
    }

    function test_PlannerWrapper_OpenPlanMatchesLibrary() public {
        address account = freshLongTrader;
        _fundTrader(freshLongTrader, 20_000e6);

        CfdTypes.Order memory order = _openOrder(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(order.account, 1e8, pool.totalAssets());
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
        address account = freshLongTrader;
        _fundTrader(freshLongTrader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.OpenDelta memory delta = harness.previewOpenPlan(
            _openOrder(account, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8), 1e8, pool.totalAssets()
        );

        assertGt(delta.pendingCarryUsdc, 0, "Open plan should report observational pending carry");
    }

    function test_PlanOpen_DoesNotDoubleCountRealizedCarryInProjectedRisk() public {
        address account = address(uint160(0xC411));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 100_000e18,
            margin: 2500e6,
            entryPrice: 1e8,
            maxProfitUsdc: 100_000e6,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 1,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = CfdMath.sizeToLots(snap.position.size) * snap.position.entryPrice;
        snap.currentTimestamp = uint64(30 days + 1);
        snap.lastMarkPrice = 1e8;
        snap.lastMarkTime = uint64(block.timestamp);
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e6,
            totalMargin: 2500e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e6,
            totalMargin: 2500e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 2_000_000e6;
        snap.poolCashUsdc = 2_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 3110e6,
            totalLockedMarginUsdc: 2610e6,
            activePositionMarginUsdc: 2500e6,
            otherLockedMarginUsdc: 110e6,
            freeSettlementUsdc: 500e6
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 2500e6,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: 2610e6
        });
        snap.liquidationReserveUsdc = 110e6;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engine.executionFeeBps();
        _attachFullRateCarry(
            snap,
            CfdTypes.Side.LONG,
            PositionRiskAccountingLib.computeBorrowBaseUsdc(snap.position.maxProfitUsdc, snap.position.margin),
            30 days
        );
        uint256 freeSettlementBeforeCarry = snap.accountBuckets.freeSettlementUsdc;
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(
            snap, _openOrder(account, CfdTypes.Side.LONG, 5000e18, 0, 1e8), 1e8, uint64(block.timestamp)
        );

        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.OK),
            "Planner should accept opens once the carry-realized snapshot still clears IMR"
        );
        assertTrue(delta.valid, "An OK carry-realized plan should be valid");
        assertGt(delta.pendingCarryUsdc, 0, "Setup must accrue pending carry");
        assertGe(
            freeSettlementBeforeCarry - delta.pendingCarryUsdc,
            uint256(delta.tradeCostUsdc),
            "Free settlement should fund both carry and the incremental action charge"
        );
        assertEq(
            delta.positionMarginAfterOpen,
            snap.position.margin,
            "Free-funded carry must not erode the exact price-PnL pledge"
        );
    }

    function test_PlanOpen_CreditsNegativeTradeCostIntoReachableCollateralWithVpiLiability() public view {
        CfdTypes.RiskParams memory params = _riskParams();
        params.vpiFactor = 0.05e18;

        address account = address(uint160(0xB0B0));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 0,
            margin: 0,
            entryPrice: 0,
            maxProfitUsdc: 0,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = CfdMath.sizeToLots(snap.position.size) * snap.position.entryPrice;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 0,
            openInterest: 300_000e18,
            entryNotional: 300_000e6,
            totalMargin: 50_000e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 0, openInterest: 0, entryNotional: 0, totalMargin: 0, borrowBaseUsdc: 0, carryIndex: 0
        });
        snap.poolAssetsUsdc = 2_000_000e6;
        snap.poolCashUsdc = 2_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 4920e6,
            totalLockedMarginUsdc: 0,
            activePositionMarginUsdc: 0,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 4920e6
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = params;
        snap.executionFeeBps = engine.executionFeeBps();
        CfdTypes.Order memory order = CfdTypes.Order({
            account: account,
            sizeDelta: 300_000e18,
            marginDelta: 4920e6,
            targetPrice: 1e8,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: CfdTypes.Side.SHORT,
            isClose: false
        });

        CfdEnginePlanTypes.OpenDelta memory delta = planner.planOpen(snap, order, 1e8, 0);

        assertLt(delta.tradeCostUsdc, 0, "Setup must produce a skew-reducing rebate");
        assertEq(delta.vpiRebateReserveAfterUsdc, 1125e6, "Reserve must back the gross negative VPI");
        assertEq(delta.poolRebatePayoutUsdc, 1005e6, "Pool cash rebate is net of the execution fee");
        assertEq(
            delta.vpiRebateReserveFromPledgeUsdc,
            120e6,
            "New pledge must fill the gap between gross VPI backing and the net cash rebate"
        );
        assertEq(
            delta.positionMarginAfterOpen,
            delta.openState.initialMarginRequirementUsdc,
            "IMR must be rechecked after both mandatory reserves are carved out"
        );
        assertEq(uint8(delta.revertCode), 0, "Rebate-backed reachable collateral should keep the open valid");
        assertTrue(delta.valid, "Planner should accept opens whose live equity remains at IMR after rebate clawback");
    }

    function test_PlanOpen_RejectsWhenCarryLeavesFreeSettlementBelowMarginDelta() public view {
        address account = address(uint160(0xCA2201));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 10_000e18,
            margin: 100e6,
            entryPrice: 1e8,
            maxProfitUsdc: 100_000e6,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 1,
            vpiAccrued: 0
        });
        snap.currentTimestamp = uint64(30 days + 1);
        snap.lastMarkPrice = 1e8;
        snap.lastMarkTime = uint64(block.timestamp);
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 10_000e18,
            entryNotional: 10_000e18 * 1e8,
            totalMargin: 100e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 10_000e18,
            entryNotional: 10_000e18 * 1e8,
            totalMargin: 100e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 50_000_000e6;
        snap.poolCashUsdc = 50_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 200e6,
            totalLockedMarginUsdc: 100e6,
            activePositionMarginUsdc: 100e6,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 100e6
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 100e6,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: 100e6
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engine.executionFeeBps();
        _attachFullRateCarry(
            snap,
            CfdTypes.Side.LONG,
            PositionRiskAccountingLib.computeBorrowBaseUsdc(snap.position.maxProfitUsdc, snap.position.margin),
            30 days
        );
        CfdTypes.Order memory order = _openOrder(account, CfdTypes.Side.LONG, 10_000e18, 100e6, 1e8);
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(snap, order, 1e8, uint64(block.timestamp));
        uint256 freeSettlementAfterCarry = delta.pendingCarryUsdc >= snap.accountBuckets.freeSettlementUsdc
            ? 0
            : snap.accountBuckets.freeSettlementUsdc - delta.pendingCarryUsdc;

        assertGt(delta.pendingCarryUsdc, 0, "Setup must accrue pending carry");
        assertLt(
            freeSettlementAfterCarry,
            order.marginDelta,
            "Carry should leave too little free settlement to re-lock the requested margin"
        );
        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "Planner should surface the typed fee-drained failure before clearinghouse execution"
        );
        assertFalse(
            delta.valid, "Planner should reject opens whose carry-drained free settlement cannot cover marginDelta"
        );
    }

    function test_PlanClose_ReportsPendingCarry() public {
        address account = freshLongTrader;
        _fundTrader(freshLongTrader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(account, 1e8, pool.totalAssets());
        CfdTypes.Position memory pos = _position(account);
        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
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

    function test_PlanClose_LossConsumptionExcludesReservedSettlementBounty() public pure {
        address account = address(uint160(0xB007));
        uint256 positionMarginUsdc = 1000e6;
        uint256 reservedBountyUsdc = 200_000;
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 100_000e18,
            margin: positionMarginUsdc,
            entryPrice: 1e8,
            maxProfitUsdc: 100_000e6,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = CfdMath.sizeToLots(snap.position.size) * snap.position.entryPrice;
        snap.lastMarkPrice = 150_000_000;
        snap.lastMarkTime = 1;
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e18 * 1e8,
            totalMargin: positionMarginUsdc,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 2_000_000e6;
        snap.poolCashUsdc = 2_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: positionMarginUsdc + reservedBountyUsdc,
            totalLockedMarginUsdc: positionMarginUsdc + reservedBountyUsdc,
            activePositionMarginUsdc: positionMarginUsdc,
            otherLockedMarginUsdc: reservedBountyUsdc,
            freeSettlementUsdc: 0
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: positionMarginUsdc,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: reservedBountyUsdc,
            totalLockedMarginUsdc: positionMarginUsdc + reservedBountyUsdc
        });
        snap.actionReserveUsdc = reservedBountyUsdc;
        snap.protectedExecutionBountyUsdc = reservedBountyUsdc;
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams();
        snap.executionFeeBps = 4;
        CfdTypes.Order memory closeOrder = CfdTypes.Order({
            account: account,
            sizeDelta: snap.position.size,
            marginDelta: 0,
            targetPrice: 0,
            commitTime: 0,
            commitBlock: 0,
            orderId: 0,
            side: snap.position.side,
            isClose: true
        });

        CfdEnginePlanTypes.CloseDelta memory delta = CfdEnginePlanLib.planClose(snap, closeOrder, 150_000_000, 0);

        assertTrue(delta.valid, "Underwater full close should remain executable");
        assertEq(
            delta.pricePnlPledgeConsumedUsdc,
            positionMarginUsdc,
            "Close price loss should consume only the dedicated PnL pledge"
        );
        assertEq(
            delta.actionReserveConsumedUsdc, 0, "Reserved execution bounty must stay isolated from terminal close loss"
        );
        assertGe(
            delta.priceLossWrittenOffUsdc,
            reservedBountyUsdc,
            "Reserved bounty should remain outside reachable collateral even when loss has shortfall"
        );
    }

    function test_PlanLiquidation_ReportsPendingCarry() public {
        address account = freshLongTrader;
        _fundTrader(freshLongTrader, 20_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.warp(block.timestamp + 7 days);

        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        CfdEnginePlanTypes.RawSnapshot memory snap =
            harness.buildRawSnapshotForPlanner(account, 150_000_000, pool.totalAssets());
        CfdEnginePlanTypes.LiquidationDelta memory delta = planner.planLiquidation(snap, 150_000_000, 0);
        assertGt(delta.pendingCarryUsdc, 0, "Liquidation plan should report observational pending carry");
    }

    function test_PendingCarry_IncreasesWithHigherLeverage() public pure {
        uint256 carryIndexDelta = PositionRiskAccountingLib.computeCarryIndexIncrement(500, 30 days);
        uint256 lowLeverageCarry = PositionRiskAccountingLib.computeIndexedCarryUsdc(
            PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 50_000e6), carryIndexDelta
        );
        uint256 highLeverageCarry = PositionRiskAccountingLib.computeIndexedCarryUsdc(
            PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 10_000e6), carryIndexDelta
        );
        assertGt(highLeverageCarry, lowLeverageCarry, "Higher leverage should report more carry");
    }

    function test_PendingCarry_IncreasesWithTime() public pure {
        uint256 borrowBaseUsdc = PositionRiskAccountingLib.computeBorrowBaseUsdc(100_000e6, 10_000e6);
        uint256 shortCarry = PositionRiskAccountingLib.computeIndexedCarryUsdc(
            borrowBaseUsdc, PositionRiskAccountingLib.computeCarryIndexIncrement(500, 1 days)
        );
        uint256 longCarry = PositionRiskAccountingLib.computeIndexedCarryUsdc(
            borrowBaseUsdc, PositionRiskAccountingLib.computeCarryIndexIncrement(500, 30 days)
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

        address account = address(uint160(0xBEEF));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 100_000e18,
            margin: 1e6,
            entryPrice: 1e8,
            maxProfitUsdc: 10_000e6,
            side: CfdTypes.Side.SHORT,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        snap.positionEntryCostUsdcAtoms = CfdMath.sizeToLots(snap.position.size) * snap.position.entryPrice;
        snap.currentTimestamp = 365 days;
        snap.lastMarkPrice = 1e8;
        snap.lastMarkTime = uint64(block.timestamp);
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 1_000_000e18,
            entryNotional: 1_000_000e18 * 1e8,
            totalMargin: 50_000e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 10_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e18 * 1e8,
            totalMargin: 1e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 50_000_000e6;
        snap.poolCashUsdc = 0;
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
        snap.executionFeeBps = engine.executionFeeBps();
        CfdEnginePlanTypes.OpenDelta memory delta = CfdEnginePlanLib.planOpen(
            snap, _openOrder(account, CfdTypes.Side.SHORT, 10_000e18, 0, 1e8), 1e8, uint64(block.timestamp)
        );

        assertEq(
            uint256(delta.tradeCostUsdc),
            4e6,
            "Execution fee on the incremental open should exceed eligible free settlement"
        );
        assertEq(
            uint8(delta.revertCode),
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "Planner should reject opens whose action charge cannot be funded without touching the PnL pledge"
        );
    }

    function test_PlanOpen_CarryBasisExcludesQueuedReservations() public view {
        address account = address(uint160(0xC0A771));
        CfdEnginePlanTypes.RawSnapshot memory snap;
        snap.account = account;
        snap.position = CfdTypes.Position({
            size: 100_000e18,
            margin: 2000e6,
            entryPrice: 1e8,
            maxProfitUsdc: 100_000e6,
            side: CfdTypes.Side.LONG,
            lastUpdateTime: 0,
            lastCarryTimestamp: 1,
            vpiAccrued: 0
        });
        snap.currentTimestamp = uint64(30 days + 1);
        snap.lastMarkPrice = 1e8;
        snap.lastMarkTime = uint64(block.timestamp);
        snap.longSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e18 * 1e8,
            totalMargin: 2000e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.shortSide = CfdEnginePlanTypes.SideSnapshot({
            maxProfitUsdc: 100_000e6,
            openInterest: 100_000e18,
            entryNotional: 100_000e18 * 1e8,
            totalMargin: 2000e6,
            borrowBaseUsdc: 0,
            carryIndex: 0
        });
        snap.poolAssetsUsdc = 50_000_000e6;
        snap.poolCashUsdc = 50_000_000e6;
        snap.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 5000e6,
            totalLockedMarginUsdc: 4000e6,
            activePositionMarginUsdc: 2000e6,
            otherLockedMarginUsdc: 2000e6,
            freeSettlementUsdc: 1000e6
        });
        snap.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 2000e6,
            committedOrderMarginUsdc: 2000e6,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: 4000e6
        });
        snap.capPrice = CAP_PRICE;
        snap.riskParams = _riskParams();
        snap.executionFeeBps = engine.executionFeeBps();
        uint256 borrowBaseUsdc =
            PositionRiskAccountingLib.computeBorrowBaseUsdc(snap.position.maxProfitUsdc, snap.position.margin);
        _attachFullRateCarry(snap, CfdTypes.Side.LONG, borrowBaseUsdc, 30 days);

        CfdEnginePlanTypes.OpenDelta memory delta =
            CfdEnginePlanLib.planOpen(snap, _openOrder(account, CfdTypes.Side.LONG, 10_000e18, 0, 1e8), 1e8, 0);
        CfdEnginePlanTypes.RawSnapshot memory withoutQueuedReservations = snap;
        withoutQueuedReservations.accountBuckets = IMarginClearinghouse.AccountUsdcBuckets({
            settlementBalanceUsdc: 5000e6,
            totalLockedMarginUsdc: 2000e6,
            activePositionMarginUsdc: 2000e6,
            otherLockedMarginUsdc: 0,
            freeSettlementUsdc: 3000e6
        });
        withoutQueuedReservations.lockedBuckets = IMarginClearinghouse.LockedMarginBuckets({
            positionMarginUsdc: 2000e6,
            committedOrderMarginUsdc: 0,
            reservedSettlementUsdc: 0,
            totalLockedMarginUsdc: 2000e6
        });
        CfdEnginePlanTypes.OpenDelta memory noQueueDelta = CfdEnginePlanLib.planOpen(
            withoutQueuedReservations, _openOrder(account, CfdTypes.Side.LONG, 10_000e18, 0, 1e8), 1e8, 0
        );

        assertGt(delta.pendingCarryUsdc, 0, "Setup must accrue indexed carry");
        assertEq(
            delta.pendingCarryUsdc,
            noQueueDelta.pendingCarryUsdc,
            "Queued reservations must not change historical indexed carry"
        );
    }

    function test_PlanOpen_SolvencyFailureCategoryMatchesTypedExecutionFailure() public {
        address shortAccount = shortTrader;
        address longAccount = freshLongTrader;

        _fundTrader(shortTrader, 50_000e6);
        _fundTrader(freshLongTrader, 40_000e6);
        _open(shortAccount, CfdTypes.Side.SHORT, 300_000e18, 30_000e6, 1e8);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        CfdTypes.Order memory order = _openOrder(longAccount, CfdTypes.Side.LONG, 350_000e18, 35_000e6, 1e8);
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

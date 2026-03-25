// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {CfdEnginePlanLib} from "../../src/perps/libraries/CfdEnginePlanLib.sol";
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

    function computeOpenMarginAfter(uint256 marginAfterFunding, int256 netMarginChange)
        external
        pure
        returns (bool drained, uint256 marginAfter)
    {
        return CfdEnginePlanLib.computeOpenMarginAfter(marginAfterFunding, netMarginChange);
    }

}

contract CfdEnginePlanRegressionTest is BasePerpTest {

    address bullTraderA = address(0xB011);
    address bullTraderB = address(0xB012);
    address bearTrader = address(0xBEA2);
    address freshBullTrader = address(0xB013);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 1e18,
            maxApy: 5e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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
    }

    function _position(
        bytes32 accountId
    ) internal view returns (CfdTypes.Position memory pos) {
        (
            pos.size,
            pos.margin,
            pos.entryPrice,
            pos.maxProfitUsdc,
            pos.entryFundingIndex,
            pos.side,
            pos.lastUpdateTime,
            pos.vpiAccrued
        ) = engine.positions(accountId);
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
        uint256 marginAfterFunding = _marginAfterFunding(currentMargin, delta);
        int256 signedMarginAfter = int256(marginAfterFunding) + delta.netMarginChange;
        if (signedMarginAfter < 0) {
            return (true, 0);
        }
        return (false, uint256(signedMarginAfter));
    }

    function _marginAfterFunding(uint256 currentMargin, CfdEnginePlanTypes.OpenDelta memory delta)
        internal
        pure
        returns (uint256)
    {
        uint256 marginAfterFunding = currentMargin + delta.funding.posMarginIncrease - delta.funding.posMarginDecrease;
        if (
            delta.funding.pendingFundingUsdc > 0
                && delta.funding.payoutType != CfdEnginePlanTypes.FundingPayoutType.MARGIN_CREDIT
        ) {
            marginAfterFunding += uint256(delta.funding.pendingFundingUsdc);
        }
        return marginAfterFunding;
    }

    function test_PreviewClose_UncoveredFundingMatchesLiveFeeAndSolvencyState() public {
        bytes32 bullId = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _fundTrader(bullTraderA, 20_000e6);
        _fundTrader(bearTrader, 100_000e6);

        _open(bullId, CfdTypes.Side.BULL, 400_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdTypes.Position memory bullPos = _position(bullId);
        int256 bullFunding = engine.getPendingFunding(bullPos);
        assertLt(bullFunding, -int256(bullPos.margin), "Setup must produce uncovered funding loss on full close");

        CfdEngine.ClosePreview memory preview = engine.previewClose(bullId, bullPos.size, 1e8);
        assertTrue(preview.valid, "Full close preview must remain executable");

        uint256 feesBefore = engine.accumulatedFeesUsdc();
        _close(bullId, CfdTypes.Side.BULL, bullPos.size, 1e8);

        uint256 liveFeeDelta = engine.accumulatedFeesUsdc() - feesBefore;
        uint256 liveEffectiveAssets = engine.getProtocolAccountingSnapshot().effectiveSolvencyAssetsUsdc;

        assertEq(preview.executionFeeUsdc, liveFeeDelta, "Close preview fee must match live collectible fee");
        assertEq(
            preview.effectiveAssetsAfterUsdc,
            liveEffectiveAssets,
            "Close preview effective assets must match live state after uncovered funding settlement"
        );
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
            delta.totalMarginBefore, _sideTotalMargin(CfdTypes.Side.BULL), "Fresh open must inherit current side margin"
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

        uint256 marginAfterFunding = _marginAfterFunding(0, delta);
        assertEq(
            delta.totalMarginAfterOpen,
            delta.totalMarginAfterFunding + delta.posMarginAfter - marginAfterFunding,
            "Open planner totalMarginAfterOpen must stay consistent with the single-frame margin delta equation"
        );
    }

    function test_ComputeOpenMarginAfter_DrainedPathMatchesPlannerRevert() public {
        CfdEnginePlanHarness harness = CfdEnginePlanHarness(address(engine));
        (bool drained,) = harness.computeOpenMarginAfter(100e6, -150e6);
        assertTrue(drained, "Canonical helper should signal margin drain when net change exceeds the base");
    }

}

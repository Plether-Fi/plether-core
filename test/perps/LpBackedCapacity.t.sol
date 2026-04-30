// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {PositionRiskAccountingLib} from "../../src/perps/libraries/PositionRiskAccountingLib.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract LpBackedCapacityTest is BasePerpTest {

    address internal trader = address(0xCA9A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            carryKinkUtilizationBps: 7000,
            carrySlope1Bps: 300,
            carrySlope2Bps: 3000,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_SolvencyCapacityUsesGrossMaxProfitNotLpBackedRisk() public {
        _fundTrader(trader, 300_000e6);
        _shrinkPoolTo(400_000e6);

        _open(trader, CfdTypes.Side.BEAR, 200_000e18, 220_000e6, 0.5e8);

        uint256 grossBearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 selfFundedMargin = _sideTotalMargin(CfdTypes.Side.BEAR);
        uint256 lpBackedRisk = _sideLpBackedRisk(CfdTypes.Side.BEAR);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(grossBearMaxProfit, 300_000e6, "setup should create gross max profit above pool assets");
        assertEq(selfFundedMargin, 219_960e6, "execution fee should reduce trader self-funded margin");
        assertEq(lpBackedRisk, grossBearMaxProfit - selfFundedMargin, "LP-backed risk still nets local margin");
        assertEq(
            snapshot.maxLiabilityUsdc,
            grossBearMaxProfit,
            "hard solvency reserve must use settlement gross max-profit liability"
        );
        assertGt(snapshot.maxLiabilityUsdc, lpBackedRisk, "pricing risk must not replace solvency liability");
    }

    function test_GrossReservePlannerRejectsTradeEvenWhenLpBackedRiskWouldFit() public {
        _fundTrader(trader, 300_000e6);
        _shrinkPoolTo(50_000e6);

        uint8 revertCode = engineLens.previewOpenRevertCode(
            trader, CfdTypes.Side.BEAR, 200_000e18, 220_000e6, 0.5e8, uint64(block.timestamp)
        );
        assertEq(
            revertCode,
            uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
            "planner should reject gross liability even when LP-backed risk would have fit"
        );
    }

    function test_PositionLocalLpBackedRiskDoesNotCrossSubsidizeSameSidePricingSignal() public {
        address overcollateralizedTrader = address(0xA11CE);
        address thinTrader = address(0xB0B);
        _fundTrader(overcollateralizedTrader, 120_000e6);
        _fundTrader(thinTrader, 30_000e6);

        _open(overcollateralizedTrader, CfdTypes.Side.BEAR, 10_000e18, 100_000e6, 0.5e8);
        assertEq(_sideLpBackedRisk(CfdTypes.Side.BEAR), 0, "excess margin should zero this position's LP risk");

        _open(thinTrader, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 0.5e8);

        uint256 positionLocalRisk = _sideLpBackedRisk(CfdTypes.Side.BEAR);
        uint256 pooledSideMarginRisk = (15_000e6 + 150_000e6) - _sideTotalMargin(CfdTypes.Side.BEAR);
        assertGt(
            positionLocalRisk,
            pooledSideMarginRisk,
            "overcollateralized same-side margin should not offset another trader's LP-backed pricing risk"
        );
    }

    function test_AddMarginReducesPositionLocalLpBackedRisk() public {
        _fundTrader(trader, 300_000e6);
        _open(trader, CfdTypes.Side.BEAR, 200_000e18, 100_000e6, 0.5e8);

        uint256 riskBefore = _sideLpBackedRisk(CfdTypes.Side.BEAR);
        assertEq(riskBefore, 200_040e6, "setup should leave LP-backed risk after execution fee");

        vm.prank(trader);
        engine.addMargin(trader, 50_000e6);

        assertEq(
            _sideLpBackedRisk(CfdTypes.Side.BEAR),
            riskBefore - 50_000e6,
            "added margin should reduce only this position's LP-backed risk"
        );
    }

    function test_VariableCarryChargesMoreWhenSideLpBackedUtilizationIsHigher() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 lowUtilCarryUsdc, uint256 lowUtilizationBps) = _measureRealizedCarryAtUtilization(false);

        vm.revertToState(snapshot);
        (uint256 highUtilCarryUsdc, uint256 highUtilizationBps) = _measureRealizedCarryAtUtilization(true);

        assertGt(highUtilizationBps, lowUtilizationBps, "setup should increase same-side LP-backed utilization");
        assertGt(highUtilizationBps, _riskParams().carryKinkUtilizationBps, "setup should cross the carry kink");

        assertGt(
            highUtilCarryUsdc,
            lowUtilCarryUsdc,
            "same position should realize more carry when same-side LP-backed utilization is higher"
        );
    }

    function _measureRealizedCarryAtUtilization(
        bool buildExtraUtilization
    ) internal returns (uint256 realizedCarryUsdc, uint256 utilizationBps) {
        address subjectTrader = address(0xC41101);
        address utilizationBuilder = address(0xC41102);

        _fundTrader(subjectTrader, 30_000e6);
        _open(subjectTrader, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        if (buildExtraUtilization) {
            _fundTrader(utilizationBuilder, 120_000e6);
            _open(utilizationBuilder, CfdTypes.Side.BULL, 700_000e18, 70_000e6, 1e8);
        }

        utilizationBps = _sideLpBackedUtilizationBps(CfdTypes.Side.BULL);
        vm.warp(block.timestamp + 30 days);
        _refreshMark(1e8);
        realizedCarryUsdc = _realizedCarryOnAddMargin(subjectTrader, 1e6);
    }

    function _realizedCarryOnAddMargin(
        address account,
        uint256 addMarginUsdc
    ) internal returns (uint256 realizedCarryUsdc) {
        uint256 settlementBefore = clearinghouse.balanceUsdc(account);

        vm.prank(account);
        engine.addMargin(account, addMarginUsdc);

        uint256 settlementAfter = clearinghouse.balanceUsdc(account);
        realizedCarryUsdc = settlementBefore - settlementAfter - addMarginUsdc;
    }

    function _sideLpBackedUtilizationBps(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        return PositionRiskAccountingLib.computeLpBackedUtilizationBps(_sideLpBackedRisk(side), pool.totalAssets());
    }

    function _refreshMark(
        uint256 price
    ) internal {
        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(block.timestamp));
    }

    function _shrinkPoolTo(
        uint256 targetAssetsUsdc
    ) internal {
        uint256 assets = pool.totalAssets();
        require(assets > targetAssetsUsdc, "target must be below current pool assets");
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), assets - targetAssetsUsdc);
        assertEq(pool.totalAssets(), targetAssetsUsdc, "pool shrink setup failed");
    }

}

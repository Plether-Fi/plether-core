// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
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
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_CapacitySubtractsSideMarginFromLiability() public {
        _fundTrader(trader, 300_000e6);
        _shrinkPoolTo(100_000e6);

        _open(trader, CfdTypes.Side.BEAR, 200_000e18, 220_000e6, 0.5e8);

        uint256 grossBearMaxProfit = _sideMaxProfit(CfdTypes.Side.BEAR);
        uint256 selfFundedMargin = _sideTotalMargin(CfdTypes.Side.BEAR);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(grossBearMaxProfit, 300_000e6, "setup should create gross max profit above pool assets");
        assertEq(selfFundedMargin, 219_960e6, "execution fee should reduce trader self-funded margin");
        assertEq(
            snapshot.maxLiabilityUsdc,
            grossBearMaxProfit - selfFundedMargin,
            "single-position capacity should reserve only LP-backed risk"
        );
        assertLt(
            snapshot.maxLiabilityUsdc, pool.totalAssets(), "LP-backed risk should fit inside reduced pool capacity"
        );
    }

    function test_PositionLocalCapacityDoesNotCrossSubsidizeSameSideRisk() public {
        address overcollateralizedTrader = address(0xA11CE);
        address thinTrader = address(0xB0B);
        _fundTrader(overcollateralizedTrader, 120_000e6);
        _fundTrader(thinTrader, 30_000e6);

        _open(overcollateralizedTrader, CfdTypes.Side.BEAR, 10_000e18, 100_000e6, 0.5e8);
        assertEq(_sideLpBackedRisk(CfdTypes.Side.BEAR), 0, "excess margin should zero this position's LP risk");

        _shrinkPoolTo(100_000e6);

        uint256 sideLevelPostRisk = (15_000e6 + 150_000e6) - (_sideTotalMargin(CfdTypes.Side.BEAR) + 9980e6);
        assertLt(sideLevelPostRisk, pool.totalAssets(), "side-level pooled margin would admit this trade");

        uint256 depth = pool.totalAssets();
        vm.expectRevert();
        _open(thinTrader, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 0.5e8, depth);
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

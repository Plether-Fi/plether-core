// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract SolvencySnapshotRegressionTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev Regression: planLiquidation must use post-liquidation side snapshots (OI and totalMargin).
    ///      for solvency computation. Now also uses previewPostOpSolvency with physicalAssetsDelta
    ///      to account for seized collateral flowing into the pool.
    function test_PreviewLiquidation_SolvencyUsesPostLiquidationCarryState() public {
        address longTrader = address(0xDD01);
        address shortTrader = address(0xDD02);
        address longAccount = longTrader;
        address shortAccount = shortTrader;

        CfdTypes.RiskParams memory params = _riskParams();
        _setRiskParams(params);

        _fundTrader(longTrader, 30_000e6);
        _fundTrader(shortTrader, 100_000e6);

        _open(longAccount, CfdTypes.Side.LONG, 999_000e18, 20_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        uint256 currentDay = ((block.timestamp / 1 days) + 4) % 7;
        uint256 startOfDay = block.timestamp - (block.timestamp % 1 days);
        uint256 saturdayNoon = startOfDay + (6 - currentDay) * 1 days + 12 hours;
        if (saturdayNoon <= block.timestamp) {
            saturdayNoon += 7 days;
        }
        vm.warp(saturdayNoon);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 hours);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(longAccount, 1e8);
        assertTrue(preview.liquidatable, "LONG majority must be liquidatable after carry drain");

        address keeper = address(0x999);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(longAccount, keeper);
        vm.prank(keeper);
        bytes[] memory liquidationPriceData = new bytes[](1);
        liquidationPriceData[0] = abi.encode(uint256(1e8));
        router.executeLiquidation(longAccount, liquidationPriceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(longAccount, keeper, beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
    }

    /// @dev Regression: _computeCloseSolvency did not reduce openInterest before computing
    ///      stale side-state math previously overstated solvency after close.
    function test_PreviewClose_SolvencyUsesPostCloseOiForCarry() public {
        address longTraderA = address(0xDD03);
        address longTraderB = address(0xDD04);
        address shortTrader = address(0xDD05);
        address longIdA = longTraderA;
        address longIdB = longTraderB;
        address shortAccount = shortTrader;

        _fundTrader(longTraderA, 50_000e6);
        _fundTrader(longTraderB, 50_000e6);
        _fundTrader(shortTrader, 100_000e6);

        _open(longIdA, CfdTypes.Side.LONG, 400_000e18, 20_000e6, 1e8);
        _open(longIdB, CfdTypes.Side.LONG, 400_000e18, 20_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 10_000e6, 1e8);

        vm.warp(block.timestamp + 5 days);

        (uint256 sizeA,,,,,,) = engine.positions(longIdA);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(longIdA, sizeA, 1e8);
        assertTrue(preview.valid, "Close preview must be valid");

        _close(longIdA, CfdTypes.Side.LONG, sizeA, 1e8);
    }

}

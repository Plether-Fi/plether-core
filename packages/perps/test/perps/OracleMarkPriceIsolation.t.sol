// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract OracleMarkPriceIsolationTest is BasePerpTest {

    address trader = address(0xA11CE);

    function test_OrderExecutionUsesAdverseFillButStoresNeutralMark() public {
        _fundTrader(trader, 10_000e6);
        vm.deal(trader, 1 ether);

        uint64 commitTime = uint64(block.timestamp);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 0, false);

        uint64 publishTime = commitTime + 1;
        vm.warp(publishTime);
        vm.roll(block.number + 1);
        baseMockPyth.setAllUniquePrices(
            _basePythFeedIds(), int64(100_000_000), 100_000, int32(-8), publishTime, commitTime
        );

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder(1, updateData);

        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(trader);
        assertEq(size, 10_000e18, "order should execute");
        assertEq(entryPrice, 99_980_000, "position should use adverse execution price");
        assertEq(engine.lastMarkPrice(), 100_000_000, "global mark should stay neutral");
        assertEq(engine.lastMarkTime(), publishTime, "global mark should use oracle publish time");
    }

    function test_LiquidationUsesAdversePriceButStoresNeutralMark() public {
        _fundTrader(trader, 700e6);
        _open(trader, CfdTypes.Side.BULL, 10_000e18, 500e6, 100_000_000);

        uint64 publishTime = uint64(block.timestamp + 1);
        vm.warp(publishTime);
        vm.roll(block.number + 1);
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(110_000_000), 100_000, int32(-8), publishTime);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeLiquidation(trader, updateData);

        (uint256 size,,,,,,) = engine.positions(trader);
        assertEq(size, 0, "position should liquidate at adverse liquidation price");
        assertEq(engine.lastMarkPrice(), 110_000_000, "global mark should stay neutral");
        assertEq(engine.lastMarkTime(), publishTime, "global mark should use oracle publish time");
    }

}

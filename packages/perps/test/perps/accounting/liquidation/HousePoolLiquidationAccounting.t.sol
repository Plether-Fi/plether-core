// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolLiquidationAccountingTest is HousePoolTestBase {

    function test_LiquidationClearsPositionCollateralAndTerminalExposure() public {
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 1e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 100_000 * 1e6);
        _open(carol, CfdTypes.Side.LONG, 500_000 * 1e18, 50_000 * 1e6, 1e8);

        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 500_000e18, "position is live before liquidation");

        vm.warp(block.timestamp + 60 days);

        address carolAccount = carol;
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.95e8);

        router.executeLiquidation(carolAccount, pythData);

        (uint256 sizeAfter, uint256 marginAfter,, uint256 maxProfitAfter,,,) = engine.positions(carolAccount);
        assertEq(sizeAfter, 0, "liquidation clears the position size");
        assertEq(marginAfter, 0, "liquidation clears the position pledge");
        assertEq(maxProfitAfter, 0, "liquidation releases the position's maximum-profit liability");
        assertEq(clearinghouse.getLockedMarginBuckets(carolAccount).positionMarginUsdc, 0);
        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 0);
        assertEq(_sideMaxProfit(CfdTypes.Side.LONG), 0);
        assertEq(_terminalLpPriceDelta(), 0, "no terminal price exposure remains after the only position closes");
    }

}

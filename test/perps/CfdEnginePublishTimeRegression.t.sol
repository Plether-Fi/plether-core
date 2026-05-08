// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract CfdEnginePublishTimeRegression is BasePerpTest {

    uint64 internal constant SATURDAY_NOON = 1_710_021_600;

    function test_FrozenWindow_RepeatedClosesCanReuseSamePublishTime() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 25_000e6);
        _fundTrader(bob, 25_000e6);

        _open(aliceAccount, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);
        _open(bobAccount, CfdTypes.Side.BEAR, 100_000e18, 10_000e6, 1e8);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        uint64 fridayPublishTime = SATURDAY_NOON - 18 hours;
        uint256 depth = pool.totalAssets();

        _closeAt(aliceAccount, CfdTypes.Side.BEAR, 100_000e18, 1e8, depth, fridayPublishTime);
        assertEq(engine.lastMarkTime(), fridayPublishTime, "close should store oracle publish time");

        _closeAt(bobAccount, CfdTypes.Side.BEAR, 100_000e18, 1e8, depth, fridayPublishTime);
        assertEq(engine.lastMarkTime(), fridayPublishTime, "repeated frozen close should keep the same publish time");

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        (uint256 bobSize,,,,,,) = engine.positions(bobAccount);
        assertEq(aliceSize, 0, "first frozen-window close should succeed");
        assertEq(bobSize, 0, "second frozen-window close should succeed with the same publish time");
    }

    function test_FrozenWindow_RepeatedLiquidationsCanReuseSamePublishTime() public {
        address alice = address(0xCAFE);
        address bob = address(0xBEEF);
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 2000e6);
        _fundTrader(bob, 2000e6);

        _open(aliceAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);
        _open(bobAccount, CfdTypes.Side.BULL, 100_000e18, 2000e6, 1e8);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        uint64 fridayPublishTime = SATURDAY_NOON - 18 hours;
        uint256 depth = pool.totalAssets();

        vm.prank(address(router));
        engine.liquidatePosition(aliceAccount, 1.2e8, depth, fridayPublishTime, address(this));
        assertEq(engine.lastMarkTime(), fridayPublishTime, "liquidation should store oracle publish time");

        vm.prank(address(router));
        engine.liquidatePosition(bobAccount, 1.2e8, depth, fridayPublishTime, address(this));
        assertEq(
            engine.lastMarkTime(), fridayPublishTime, "repeated frozen liquidation should keep the same publish time"
        );

        (uint256 aliceSize,,,,,,) = engine.positions(aliceAccount);
        (uint256 bobSize,,,,,,) = engine.positions(bobAccount);
        assertEq(aliceSize, 0, "first frozen-window liquidation should succeed");
        assertEq(bobSize, 0, "second frozen-window liquidation should succeed with the same publish time");
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {OrderRouterPythTestBase} from "../../shared/OrderRouterTestBase.sol";

contract OrderRouterLiquidationFreshnessTest is OrderRouterPythTestBase {

    using stdStorage for StdStorage;

    function test_LiquidationStaleness_IsStricterThanOrderExecution() public {
        _startRecordingLogs();
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 60;
        config.liquidationStalenessLimit = 15;
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2040);
        vm.warp(2050);
        router.updateMarkPrice(empty);

        vm.warp(2056);
        vm.roll(block.number + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeLiquidation(account, empty);
    }

    function test_LiquidationStaleness_UsesRouterLiquidationLimit_NotPoolMarkLimit() public {
        _startRecordingLogs();
        IHousePool.PoolConfig memory poolConfig = _currentPoolConfig();
        poolConfig.markStalenessLimit = 300;
        pool.proposePoolConfig(poolConfig);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizePoolConfig();

        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1006);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty = _pythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        address account = alice;

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2000);

        vm.warp(2061);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeLiquidation(account, empty);

        IOrderRouterAdminHost.RouterConfig memory routerConfig = _routerConfig();
        routerConfig.liquidationStalenessLimit = 61;
        routerAdmin.proposeRouterConfig(routerConfig);
        vm.warp(2061 + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.warp(2061);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, empty);
    }

}

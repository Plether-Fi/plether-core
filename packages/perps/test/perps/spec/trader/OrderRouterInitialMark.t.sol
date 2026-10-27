// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

contract OrderRouterInitialMarkTest is BasePerpTest {

    address private constant TRADER = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_FirstOpenRequiresRealMarkThenUsesItForNotionalAndBounty() public {
        assertTrue(pool.isTradingActive());
        assertEq(engine.lastMarkPrice(), 0);

        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.minOpenNotionalAssets = 1000e6;
        _setRouterConfig(config);
        _fundTrader(TRADER, 500e6);

        uint64 nextOrderId = router.nextCommitId();
        vm.prank(TRADER);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__MarkPriceUnavailable.selector);
        router.commitOrder(CfdTypes.Side.LONG, 7 * CfdTypes.SIZE_QUANTUM, 200e6, 1e8, false);
        assertEq(router.nextCommitId(), nextOrderId);
        assertEq(router.pendingOrderCounts(TRADER), 0);

        router.updateMarkPrice(_mockPythUpdateData(160_000_000));
        assertEq(engine.lastMarkPrice(), 160_000_000);

        vm.prank(TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 7 * CfdTypes.SIZE_QUANTUM, 200e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(nextOrderId);
        assertEq(pending.orderId, nextOrderId);
        assertEq(pending.executionBountyAssets, 112_000);
    }

}

contract OrderRouterPreActivationMarkTest is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function test_PermissionlessOracleRefreshInitializesMarkBeforeTradingActivation() public {
        assertTrue(pool.isSeedLifecycleComplete());
        assertFalse(pool.isTradingActive());
        assertEq(engine.lastMarkPrice(), 0);

        router.updateMarkPrice(_mockPythUpdateData(160_000_000));
        assertEq(engine.lastMarkPrice(), 160_000_000);

        pool.activateTrading();
        assertTrue(pool.isTradingActive());
    }

}

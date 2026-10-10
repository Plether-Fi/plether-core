// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract WithdrawalFirewallMatrixTest is BasePerpTest {

    address private constant ACCOUNT = address(0xF170);
    address private constant LOSS_TRIGGER = address(0xF171);

    /// @notice Calendar and degraded state are independent axes. Every row executes a real withdrawal.
    /// @dev Pool cash is synthetically drained then restored to latch degraded mode through a real close.
    function test_WithdrawalFirewall_AllCalendarDegradedPositionAndFreshnessRows() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        for (uint8 regime; regime < 3; regime++) {
            for (uint8 flags; flags < 8; flags++) {
                uint256 snapshot = vm.snapshotState();
                _withdrawalRow(regime, flags & 1 != 0, flags & 2 != 0, flags & 4 != 0);
                assertTrue(vm.revertToState(snapshot));
                vm.deleteStateSnapshot(snapshot);
            }
        }
    }

    function _withdrawalRow(
        uint8 regime,
        bool hasPosition,
        bool degraded,
        bool tooOld
    ) private {
        _fundTrader(ACCOUNT, 20_000e6);
        if (hasPosition) {
            _open(ACCOUNT, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        }
        if (degraded) {
            _fundTrader(address(0xF172), 2000e6);
            _open(address(0xF172), CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);
            _fundTrader(LOSS_TRIGGER, 2000e6);
            _open(LOSS_TRIGGER, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8);
            uint256 cash = usdc.balanceOf(address(pool));
            usdc.burn(address(pool), cash);
            _close(LOSS_TRIGGER, CfdTypes.Side.LONG, 10_000e18, 90_000_000);
            assertTrue(engine.degradedMode(), "Real unaffordable settlement must latch degraded mode");
            usdc.mint(address(pool), cash);
        }
        // Friday 2024-10-18: 20:29:59 live, 20:30:00 FAD-only, 21:00:00 frozen.
        uint256 now_ = regime == 0 ? 1_729_283_399 : regime == 1 ? 1_729_283_400 : 1_729_285_200;
        vm.warp(now_);
        assertEq(engine.isFadWindow(), regime != 0);
        assertEq(engine.isOracleFrozen(), regime == 2);
        uint256 ageLimit = regime == 2 ? engine.fadMaxStaleness() : engine.engineMarkStalenessLimit();
        if (regime != 2 && pool.markStalenessLimit() < ageLimit) {
            ageLimit = pool.markStalenessLimit();
        }
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(now_ - ageLimit - (tooOld ? 1 : 0)));

        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 walletBefore = usdc.balanceOf(ACCOUNT);
        bytes32 curveBefore = terminalNavBook.curveHashOf(ACCOUNT);
        bool blocked = hasPosition && (degraded || tooOld);
        if (blocked) {
            vm.expectRevert(
                degraded
                    ? ICfdEngineTypes.CfdEngine__DegradedMode.selector
                    : ICfdEngineTypes.CfdEngine__MarkPriceStale.selector
            );
        }
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, 1e6);
        uint256 paid = blocked ? 0 : 1e6;
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), settlementBefore - paid);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore - paid);
        assertEq(usdc.balanceOf(ACCOUNT), walletBefore + paid);
        assertEq(terminalNavBook.curveHashOf(ACCOUNT), curveBefore, "Free cash withdrawal cannot change price-risk cap");
    }

}

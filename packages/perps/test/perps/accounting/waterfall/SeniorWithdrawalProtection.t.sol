// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract SeniorWithdrawalProtectionTest is HousePoolTestBase {

    function test_FrozenExitRetainedFeeRecoversBeforeJuniorRevenue() public {
        _assertWithdrawalRecovery(25);
    }

    function test_FeeFreeExitRecoversBeforeJuniorRevenue() public {
        _assertWithdrawalRecovery(0);
    }

    function _assertWithdrawalRecovery(
        uint256 exitFeeBps
    ) internal {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        config.seniorFrozenLpFeeBps = exitFeeBps;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMarkForAsyncSettlement();
        pool.finalizePoolConfig();

        _fundSenior(alice, 1_000_000e6);
        _fundJunior(bob, 1_000_000e6);
        _enterFrozenWindow();
        uint256 principalBefore = pool.seniorPrincipal();
        uint256 requestId = _requestAsyncRedeem(seniorVault, alice, seniorVault.balanceOf(alice) / 10);
        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(requestId, true);
        assertApproxEqAbs(result.seniorFundedAssets, 100_000e6 * (10_000 - exitFeeBps) / 10_000, 1);
        uint256 protectedPrincipal = pool.seniorPrincipal();
        assertEq(protectedPrincipal, principalBefore - result.seniorFundedAssets);

        // Realize a loss before any positive-revenue reconciliation can repair an understated HWM.
        uint256 seniorLoss = 10_000e6;
        uint256 payout = pool.juniorPrincipal() + seniorLoss;
        vm.prank(address(engine));
        pool.payOut(carol, payout);
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), protectedPrincipal - seniorLoss);
        assertEq(pool.juniorPrincipal(), 0);

        _mintAndAccountPoolExcess(seniorLoss);
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), protectedPrincipal, "all remaining Senior principal must recover first");
        assertEq(pool.juniorPrincipal(), 0, "recovery must not leak retained Senior fees to Junior");
        assertEq(pool.seniorHighWaterMark(), protectedPrincipal);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {HousePoolTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolAdministrationTest is HousePoolTestBase {

    using stdStorage for StdStorage;

    // ==========================================
    // SENIOR RATE CHANGE
    // ==========================================

    function test_SeniorRateChange() public {
        _fundSenior(alice, 1_000_000 * 1e6);
        _fundJunior(bob, 1_000_000 * 1e6);
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();

        // Generate some revenue
        _mintAndAccountPoolExcess(200_000 * 1e6);

        vm.warp(block.timestamp + 365 days - 48 hours - 1);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1200;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        uint256 expectedCoupon =
            (seniorBefore * 800 * (block.timestamp - couponCheckpoint)) / (10_000 * uint256(365 days));
        pool.finalizePoolConfig();

        assertEq(pool.seniorPrincipal(), seniorBefore + expectedCoupon, "Senior got 8% before rate change");
        assertEq(pool.juniorPrincipal(), juniorBefore + 200_000 * 1e6 - expectedCoupon, "Junior got residual surplus");
    }

    function test_FinalizeSeniorRate_StaleMarkRevertsUntilMarkIsFresh() public {
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 200_000e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);

        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 800, "Senior rate should remain unchanged until a fresh mark is available");
    }

    function test_FinalizeSeniorRate_StaleMarkSucceedsAfterFreshMarkUpdate() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);

        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 1600, "Senior rate should update once freshness returns");
    }

    function test_FinalizeSeniorRate_FreshCheckpointAccruesOldRateBeforeChange() public {
        _fundSenior(alice, 200_000e6);
        _fundJunior(bob, 200_000e6);
        _mintAndAccountPoolExcess(50_000e6);

        uint256 seniorBefore = pool.seniorPrincipal();
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        assertGt(
            pool.seniorPrincipal(), seniorBefore, "Fresh finalization should checkpoint accrued coupon at the old rate"
        );
        assertEq(pool.seniorRateBps(), 1600, "Senior rate should update after the fresh checkpoint");
    }

    function test_FinalizeSeniorRate_NoCarrySyncNeededBeforeReconcile() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        uint256 activationTime = pool.poolConfigActivationTime();
        assertGt(activationTime, block.timestamp, "The proposal must be staged behind its timelock");
        assertEq(pool.seniorRateBps(), 800, "The proposal must not apply the new rate early");
        vm.warp(activationTime + 1);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        pool.finalizePoolConfig();
        assertEq(pool.seniorRateBps(), 1600, "Finalization must install the proposed senior rate");
        assertEq(pool.poolConfigActivationTime(), 0, "Finalization must consume the pending proposal");
        (uint256 pendingSeniorRate,,,,,) = pool.pendingPoolConfig();
        assertEq(pendingSeniorRate, 0, "Finalization must clear the pending rate");
        vm.expectRevert(IHousePool.HousePool__NoProposal.selector);
        pool.finalizePoolConfig();
        assertEq(pool.seniorRateBps(), 1600, "Repeated finalization must preserve the installed rate");
    }

    function test_ProposeSeniorRate_RevertsAbove100PercentApr() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 10_001;
        vm.expectRevert(IHousePool.HousePool__InvalidSeniorRate.selector);
        pool.proposePoolConfig(config);
    }

    function test_RecordClaimantRevenue_OnlyEngineCanAccountRawExcess() public {
        _fundJunior(bob, 500_000e6);
        usdc.mint(address(pool), 25_000e6);

        vm.prank(alice);
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.recordClaimantInflow(
            25_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(engine));
        pool.recordClaimantInflow(
            25_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertEq(
            pool.totalAssets(),
            SEEDED_SENIOR + SEEDED_JUNIOR + 525_000e6,
            "Engine-accounted inflow should become canonical immediately"
        );
        assertEq(pool.excessAssets(), 0, "Engine-accounted inflow should not remain quarantined as excess");
    }

    function test_RecordClaimantRevenue_OrderRouterCannotAccountRawExcess() public {
        _fundJunior(bob, 500_000e6);
        usdc.mint(address(pool), 25_000e6);

        vm.prank(address(router));
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.recordClaimantInflow(
            25_000e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertEq(pool.excessAssets(), 25_000e6, "Router-originated raw excess should remain quarantined");
    }

    function test_SetSeniorVault_Twice_Reverts() public {
        vm.expectRevert(IHousePool.HousePool__SeniorVaultAlreadySet.selector);
        pool.setSeniorVault(address(0x999));
    }

    function test_SetJuniorVault_Twice_Reverts() public {
        vm.expectRevert(IHousePool.HousePool__JuniorVaultAlreadySet.selector);
        pool.setJuniorVault(address(0x999));
    }

    function test_PayOut_Unauthorized_Reverts() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.payOut(alice, 1000 * 1e6);
    }

}


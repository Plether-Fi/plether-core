// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolSeedLifecycleGateTest is HousePoolAsyncTestBase {

    address alice = address(0x111);

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_OpenCommit_RevertsDuringPartialSeedLifecycle() public {
        uint256 juniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed);
        usdc.approve(address(pool), juniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        _fundTrader(alice, 10_000e6);
        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NotInSeedLifecycle.selector);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_OpenCommit_RevertsBeforeSeedLifecycleStarts() public {
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NotInSeedLifecycle.selector);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_OpenCommit_RevertsWhenSeedsCompleteButTradingNotActivated() public {
        uint256 juniorSeed = 1000e6;
        uint256 seniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed + seniorSeed);
        usdc.approve(address(pool), juniorSeed + seniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));
        pool.initializeSeedPosition(true, seniorSeed, address(this));

        _fundTrader(alice, 11_000e6);
        vm.prank(alice);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__VaultRiskBlocked.selector);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        pool.activateTrading();

        _fundJunior(address(0x222), 1_000_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
    }

    function test_InitializeJuniorSeed_CheckpointsPreExistingSeniorCouponWithoutChargingSeed() public {
        uint256 seniorSeed = 100_000e6;
        uint256 juniorSeed = 50_000e6;

        // A small assigned junior position supplies the ratio backing required to exercise a senior-first bootstrap
        // without setting the junior seed flag. Its full value is consumed by the pre-seed coupon backlog below.
        uint256 juniorCapacityBacking = 11e6;
        usdc.mint(address(pool), juniorCapacityBacking);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        pool.assignUnassignedAssets(false, address(this));

        usdc.mint(address(this), seniorSeed);
        usdc.approve(address(pool), seniorSeed);
        pool.initializeSeedPosition(true, seniorSeed, address(this));

        vm.warp(block.timestamp + 30 days);
        uint256 juniorSeedTime = block.timestamp;
        usdc.mint(address(this), juniorSeed);
        usdc.approve(address(pool), juniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        uint256 seniorBeforeJuniorSeed = seniorSeed + juniorCapacityBacking;
        assertEq(
            pool.seniorPrincipal(), seniorBeforeJuniorSeed, "Junior seed should not pay pre-existing senior coupon time"
        );
        assertEq(pool.juniorPrincipal(), juniorSeed, "Junior seed should enter at face value");
        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            juniorSeedTime,
            "Junior seed should become the new senior coupon checkpoint"
        );

        vm.warp(juniorSeedTime + 1 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 expectedCoupon = (seniorBeforeJuniorSeed * 800 * uint256(1 days)) / (10_000 * uint256(365 days));
        assertEq(
            pool.seniorPrincipal(),
            seniorBeforeJuniorSeed + expectedCoupon,
            "Only post-junior-seed coupon should be paid"
        );
        assertEq(pool.juniorPrincipal(), juniorSeed - expectedCoupon, "Junior should only fund post-entry coupon time");
    }

    function test_OrdinaryDeposit_RevertsWhenSeedLifecycleStartedButTradingInactive() public {
        uint256 juniorSeed = 1000e6;
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), juniorSeed + depositAmount);
        usdc.approve(address(pool), juniorSeed + depositAmount);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        usdc.approve(address(juniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.requestDeposit(depositAmount, address(this), address(this));
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should reflect lifecycle gating");
    }

    function test_OrdinaryDeposit_RevertsBeforeSeedLifecycleStarts() public {
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), depositAmount);
        usdc.approve(address(juniorVault), depositAmount);

        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.requestDeposit(depositAmount, address(this), address(this));
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should be zero before bootstrap");
    }

    function test_InitializeSeedPosition_UsesSeedFlagsInsteadOfExistingSupply() public {
        vm.prank(address(pool));
        juniorVault.bootstrapMint(1e18, address(this));

        uint256 juniorSeed = 1000e6;
        usdc.mint(address(this), juniorSeed);
        usdc.approve(address(pool), juniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));

        assertTrue(
            pool.hasSeedLifecycleStarted(), "Seed initialization should succeed even with preexisting tranche supply"
        );
        assertEq(juniorVault.seedReceiver(), address(this), "Seed receiver should still be configured canonically");
    }

    function test_OrdinaryDeposit_RevertsWhenSeedsCompleteButTradingInactive() public {
        uint256 juniorSeed = 1000e6;
        uint256 seniorSeed = 1000e6;
        uint256 depositAmount = 5000e6;

        usdc.mint(address(this), juniorSeed + seniorSeed + depositAmount);
        usdc.approve(address(pool), juniorSeed + seniorSeed);
        pool.initializeSeedPosition(false, juniorSeed, address(this));
        pool.initializeSeedPosition(true, seniorSeed, address(this));

        usdc.approve(address(juniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__TradingNotActive.selector);
        juniorVault.requestDeposit(depositAmount, address(this), address(this));
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should be zero before activation");

        pool.activateTrading();
        assertGt(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should reopen after activation");
        uint256 requestId = juniorVault.requestDeposit(depositAmount, address(this), address(this));
        _settleAsyncRequest(requestId, true);
        uint256 shares = _claimAsyncDeposit(juniorVault, requestId, address(this));
        assertGt(shares, 0, "activated request should settle into claimable shares");
    }

    function test_MaxDeposit_ZeroWhilePoolPaused() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        assertTrue(pool.canAcceptTrancheDeposits(false), "Setup should allow junior deposits before pause");
        pool.pause();

        assertFalse(pool.canAcceptTrancheDeposits(false), "Paused pool should report deposits blocked");
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should be zero while paused");
    }

    function test_MaxDeposit_ZeroWhileMarkStale() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        _fundJunior(address(0x445), 1_000_000e6);
        address trader = address(0x444);
        _fundTrader(trader, 300e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.warp(block.timestamp + 2 hours);

        assertFalse(pool.canAcceptTrancheDeposits(false), "Stale mark should report deposits blocked");
        assertEq(juniorVault.maxRequestDeposit(address(this)), 0, "request capacity should be zero while mark is stale");
    }

    function test_MaxDeposit_ZeroWhenFreshReconcileWouldCreateUnassignedAssets() public {
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        usdc.mint(address(pool), 500e6);
        pool.accountExcess();
        vm.store(address(juniorVault), bytes32(uint256(2)), bytes32(uint256(0)));

        assertFalse(
            pool.canAcceptTrancheDeposits(false),
            "Projected unassigned assets should block deposits before reconcile mutates storage"
        );
        assertEq(
            juniorVault.maxRequestDeposit(address(this)),
            0,
            "request capacity should account for projected unassigned assets"
        );

        vm.expectRevert();
        juniorVault.requestDeposit(1e6, address(this), address(this));
    }

}

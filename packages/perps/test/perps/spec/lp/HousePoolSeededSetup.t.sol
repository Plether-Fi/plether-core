// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

contract HousePoolSeededBaseSetupTest is HousePoolAsyncTestBase {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 25_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 10_000e6;
    }

    function test_BasePerpTest_CanBootstrapSeededSetup() public view {
        assertEq(pool.juniorPrincipal(), 25_000e6, "Shared setup should initialize the junior seed");
        assertEq(pool.seniorPrincipal(), 10_000e6, "Shared setup should initialize the senior seed");
        assertEq(
            juniorVault.seedShareFloor(), juniorVault.balanceOf(address(this)), "Junior seed floor should be registered"
        );
        assertEq(
            seniorVault.seedShareFloor(), seniorVault.balanceOf(address(this)), "Senior seed floor should be registered"
        );
    }

    function test_MaxDepositAndMaxMint_ZeroWhenSeniorImpaired() public {
        address alice = address(0x111);
        address bob = address(0x222);

        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 120_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        address dave = address(0x444);
        assertGt(pool.seniorHighWaterMark() - pool.seniorPrincipal(), 0, "Senior deficit exists");
        assertEq(seniorVault.maxRequestDeposit(dave), 0, "senior request capacity is zero while impaired");
        assertEq(juniorVault.maxRequestDeposit(dave), 0, "junior request capacity is zero while senior is impaired");
        assertFalse(pool.canAcceptTrancheDeposits(true), "Pool should block ordinary senior deposits while impaired");
        assertFalse(pool.canAcceptTrancheDeposits(false), "Pool should block ordinary junior deposits while impaired");
    }

    function test_MaxDepositAndMaxMint_ReopenForPendingSeniorRecapAfterWipeout() public {
        uint256 rawAssetsBefore = pool.rawAssets();
        assertGt(rawAssetsBefore, 0, "Setup should leave real USDC in the pool before wipeout");
        usdc.burn(address(pool), rawAssetsBefore);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Senior principal should be wiped out before recap");
        assertGt(pool.seniorHighWaterMark(), 0, "Stored HWM should remain stale until reconcile applies the recap");

        uint256 recapAmount = 500e6;
        usdc.mint(address(pool), recapAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertFalse(
            pool.isSeniorImpairedAfterPendingDepositReconcile(),
            "Pending recap should fully clear projected senior impairment"
        );

        address dave = address(0x444);
        assertEq(pool.getSeniorDepositCapacity(), 0, "Senior capacity should remain zero without junior backing");
        assertEq(seniorVault.maxRequestDeposit(dave), 0, "Senior request capacity remains zero without backing");

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorBacking = 1e6;
        usdc.mint(address(pool), juniorBacking);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            juniorBacking, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), juniorBacking, "Junior revenue should supply ratio backing");
        assertTrue(pool.canAcceptTrancheDeposits(true), "Senior deposits should reopen with junior backing");

        uint256 totalBeforeDeposit = pool.totalAssets();
        usdc.mint(dave, 1000e6);
        vm.startPrank(dave);
        usdc.approve(address(seniorVault), 1000e6);
        assertGe(seniorVault.maxRequestDeposit(dave), 1000e6, "request capacity should include supported depth");
        uint256 requestId = seniorVault.requestDeposit(1000e6, dave, dave);
        vm.stopPrank();
        _settleAsyncRequest(requestId, true);
        uint256 shares = _claimAsyncDeposit(seniorVault, requestId, dave);

        assertGt(shares, 0, "Senior deposit should succeed after reconcile consumes the pending recap");
        assertEq(
            pool.totalAssets(), totalBeforeDeposit + 1000e6, "Live state should include the recap plus the new deposit"
        );
    }

}

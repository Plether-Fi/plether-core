// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

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

    function test_LastSeniorExitReleasesJuniorInSameSettlementAndStopsCoupon() public {
        address seniorLp = address(0x111);
        address juniorLp = address(0x222);
        _fundSenior(seniorLp, 10_000e6);
        _fundJunior(juniorLp, 10_000e6);
        _setSeniorCapacity(100_000e6, 2500);
        assertEq(pool.getMaxJuniorWithdraw(), 0, "redeemable Senior still requires backing");

        uint256 seniorShares = seniorVault.balanceOf(seniorLp);
        uint256 juniorShares = juniorVault.balanceOf(juniorLp);
        uint256 seniorEpoch = _requestAsyncRedeem(seniorVault, seniorLp, seniorShares);
        uint256 juniorEpoch = _requestAsyncRedeem(juniorVault, juniorLp, juniorShares);
        assertEq(seniorEpoch, juniorEpoch, "exercise both redemptions in the same settlement");

        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(juniorEpoch, true);
        assertEq(result.seniorFundedShares, seniorShares);
        assertEq(seniorVault.totalSupply(), seniorVault.seedShareFloor());
        assertEq(result.juniorFundedShares, juniorShares, "Junior can fully exit after Senior shares are burned");

        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 juniorAfter = pool.juniorPrincipal();
        _warpForward(1 weeks);
        _refreshMarkForAsyncSettlement();
        (uint256 pendingSenior, uint256 pendingJunior,, uint256 pendingJuniorCap) = pool.getPendingTrancheState();
        assertEq(pendingSenior, seniorAfter);
        assertEq(pendingJunior, juniorAfter, "preview must omit the seed-only coupon");
        assertEq(pendingJuniorCap, juniorAfter);
        assertEq(pool.getMaxJuniorWithdraw(), juniorAfter);

        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), seniorAfter);
        assertEq(pool.juniorPrincipal(), juniorAfter, "reconcile must omit the seed-only coupon");
        assertEq(pool.lastSeniorCouponCheckpointTime(), vm.getBlockTimestamp());
    }

    function test_DustSeniorSharesAboveSeedFloorCannotPinJuniorOrKeepCouponsRunning() public {
        address seniorLp = address(0x111);
        address juniorLp = address(0x222);
        _fundSenior(seniorLp, 10_000e6);
        _fundJunior(juniorLp, 10_000e6);
        _setSeniorCapacity(100_000e6, 2500);
        assertEq(pool.getMaxJuniorWithdraw(), 0, "external Senior capital still enforces ratio backing");

        // Leave 999 unburnable dust shares (< 1 USDG atom) stranded at a burn address while redeeming the rest.
        vm.prank(seniorLp);
        seniorVault.transfer(address(0xDEAD), 999);
        uint256 remainingSeniorShares = seniorVault.balanceOf(seniorLp);
        uint256 juniorShares = juniorVault.balanceOf(juniorLp);
        uint256 seniorEpoch = _requestAsyncRedeem(seniorVault, seniorLp, remainingSeniorShares);
        uint256 juniorEpoch = _requestAsyncRedeem(juniorVault, juniorLp, juniorShares);

        IHousePool.LpEpochSettlementResult memory result =
            _settleAsyncRequest(seniorEpoch > juniorEpoch ? seniorEpoch : juniorEpoch, true);
        assertEq(seniorVault.totalSupply(), seniorVault.seedShareFloor() + 999, "dust shares remain above floor");
        assertEq(result.juniorFundedShares, juniorShares, "dust shares must not pin Junior withdrawals");

        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 juniorAfter = pool.juniorPrincipal();
        _warpForward(1 weeks);
        _refreshMarkForAsyncSettlement();
        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertEq(pendingSenior, seniorAfter, "dust shares must not keep Senior seed coupon running");
        assertEq(pendingJunior, juniorAfter);

        // A legitimate minimum-sized external Senior deposit still re-enables ratio backing and coupons.
        _setSeniorCapacity(100_000e6, 5000);
        while (engine.isOracleFrozen()) {
            _warpForward(1 days);
        }
        _refreshMarkForAsyncSettlement();
        _fundSenior(seniorLp, pool.MIN_TRANCHE_DEPOSIT_ASSETS());
        _warpForward(1 weeks);
        _refreshMarkForAsyncSettlement();
        (uint256 activePendingSenior,,,) = pool.getPendingTrancheState();
        assertGt(activePendingSenior, pool.seniorPrincipal(), "minimum external Senior deposit must resume coupon");
    }

    function test_SeedOnlySeniorKeepsBackingForActivationOfCommittedDeposit() public {
        address seniorLp = address(0x111);
        address juniorLp = address(0x222);
        _fundJunior(juniorLp, 20_000e6);
        _setSeniorCapacity(100_000e6, 5000);
        assertEq(pool.getMaxJuniorWithdraw(), 45_000e6);

        uint256 depositEpoch = _requestAsyncDeposit(seniorVault, seniorLp, 20_000e6);
        assertEq(pool.getMaxJuniorWithdraw(), 15_000e6, "back the balance that the accepted deposit will activate");
        uint256 redeemEpoch = _requestAsyncRedeem(juniorVault, juniorLp, juniorVault.balanceOf(juniorLp));
        IHousePool.LpEpochSettlementResult memory result =
            _settleAsyncRequest(depositEpoch > redeemEpoch ? depositEpoch : redeemEpoch, true);
        assertEq(result.seniorDepositAssets, 20_000e6, "release the reservation through deposit activation");
        assertGt(result.juniorFundedAssets, 14_999e6);
        assertLe(result.juniorFundedAssets, 15_000e6);
        assertEq(pool.seniorPrincipal(), 30_000e6, "activation must not backfill interest for the seed-only interval");
        assertGe(pool.juniorPrincipal(), 30_000e6, "the now-active Senior balance must be backed");

        _warpForward(1 weeks);
        _refreshMarkForAsyncSettlement();
        (uint256 pendingSenior,,,) = pool.getPendingTrancheState();
        assertGt(pendingSenior, 30_000e6, "coupon resumes when the deposit shares activate");
    }

    function test_MaxDepositAndMaxMint_ZeroWhenSeniorImpaired() public {
        address alice = address(0x111);
        address bob = address(0x222);

        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 50_000e6);

        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), 120_000e6);

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
        assertGt(rawAssetsBefore, 0, "Setup should leave real settlementToken in the pool before wipeout");
        settlementToken.burn(address(pool), rawAssetsBefore);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 0, "Senior principal should be wiped out before recap");
        assertGt(pool.seniorHighWaterMark(), 0, "Stored HWM should remain stale until reconcile applies the recap");

        uint256 recapAmount = pool.seniorHighWaterMark();
        settlementToken.mint(address(pool), recapAmount);
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

        uint256 juniorBacking = 100e6;
        settlementToken.mint(address(pool), juniorBacking);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            juniorBacking, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), juniorBacking, "Junior revenue should supply ratio backing");
        assertGe(pool.getSeniorDepositCapacity(), 1000e6, "Restored backing should support the requested depth");
        assertTrue(pool.canAcceptTrancheDeposits(true), "Senior deposits should reopen with restored backing");

        uint256 totalBeforeDeposit = pool.totalAssets();
        settlementToken.mint(dave, 1000e6);
        vm.startPrank(dave);
        settlementToken.approve(address(seniorVault), 1000e6);
        assertGe(seniorVault.maxRequestDeposit(dave), 1000e6, "request capacity should include supported depth");
        uint256 requestId = seniorVault.requestDeposit(1000e6, dave, dave);
        vm.stopPrank();
        _settleAsyncRequest(requestId, true);
        uint256 shares = _claimAsyncDeposit(seniorVault, requestId, dave);

        assertGt(shares, 0, "Senior deposit should succeed after reconcile consumes the pending recap");
        assertEq(pool.pendingRecapitalizationAssets(), 0, "Recap should settle into existing claimant value");
        assertEq(
            pool.totalAssets(), totalBeforeDeposit + 1000e6, "Live state should include the recap plus the new deposit"
        );
    }

}

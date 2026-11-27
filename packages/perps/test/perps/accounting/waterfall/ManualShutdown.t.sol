// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

/// @dev accounting; source: ACCOUNTING_SPEC.md#manual-shutdown.
contract ManualShutdownTest is HousePoolAsyncTestBase {

    address private constant LP = address(0x7111);
    address private constant SENIOR_DEPOSITOR = address(0x7112);
    address private constant JUNIOR_DEPOSITOR = address(0x7113);
    address private constant TRADER = address(0x7114);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _pauseEntry() private {
        routerAdmin.pause();
        pool.pause();
        assertFalse(pool.lpEpochSettlementPaused(), "entry shutdown must keep redemption funding available");
    }

    function _recapitalize(
        uint256 amount
    ) private {
        settlementToken.mint(address(this), amount);
        settlementToken.approve(address(engine), amount);
        engine.recapitalizePool(amount);
    }

    function test_ShutdownRequiresExplicitEntryPauses() public {
        uint256 hwm = pool.seniorHighWaterMark();
        settlementToken.burn(address(pool), pool.totalAssets());
        _refreshMarkForAsyncSettlement();
        assertFalse(routerAdmin.paused(), "a loss does not automatically pause trading");
        assertFalse(pool.paused(), "a loss does not automatically pause LP entry");

        _pauseEntry();
        _recapitalize(10_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorHighWaterMark(), hwm, "funding cannot reset Senior entitlement");
        assertTrue(routerAdmin.paused(), "funding does not lift the operator's pause");
        assertTrue(pool.paused());
        assertFalse(pool.canAcceptTrancheDeposits(true));
        assertFalse(pool.canAcceptTrancheDeposits(false));
        _fundTrader(TRADER, 20_000e6);
        vm.expectRevert();
        vm.prank(TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 1000e6, 1e8, false);
    }

    function test_MaturedDepositsRefundDuringEntryPauseAfterRecovery() public {
        uint256 seniorId = _requestAsyncDeposit(seniorVault, SENIOR_DEPOSITOR, 10_000e6);
        uint256 juniorId = _requestAsyncDeposit(juniorVault, JUNIOR_DEPOSITOR, 20_000e6);
        vm.warp(pool.lpEpochStart(seniorId > juniorId ? seniorId : juniorId));
        settlementToken.burn(address(pool), pool.totalAssets());
        _pauseEntry();
        _recapitalize(10_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();
        settlementToken.mint(address(pool), 5000e6);
        pool.accountExcess();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertGt(seniorVault.totalAssets(), 0);
        assertGt(juniorVault.totalAssets(), 0);
        assertFalse(pool.isSeniorImpairedAfterPendingDepositReconcile());

        vm.expectRevert();
        vm.prank(address(0xBAD));
        juniorVault.cancelPendingDeposit(juniorId, address(0xBAD), JUNIOR_DEPOSITOR);
        assertEq(juniorVault.pendingDepositAssets(JUNIOR_DEPOSITOR, juniorId), 20_000e6);

        vm.prank(SENIOR_DEPOSITOR);
        assertEq(seniorVault.cancelPendingDeposit(seniorId), 10_000e6);
        vm.prank(JUNIOR_DEPOSITOR);
        assertEq(juniorVault.cancelPendingDeposit(juniorId), 20_000e6);
        assertEq(settlementToken.balanceOf(SENIOR_DEPOSITOR), 10_000e6);
        assertEq(settlementToken.balanceOf(JUNIOR_DEPOSITOR), 20_000e6);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertEq(seniorVault.pendingDepositEscrowAssets(), 0);
        assertEq(juniorVault.pendingDepositEscrowAssets(), 0);
    }

    function test_HealthyDepositsRemainCommittedWithoutEntryPause() public {
        uint256 seniorId = _requestAsyncDeposit(seniorVault, SENIOR_DEPOSITOR, 10_000e6);
        uint256 juniorId = _requestAsyncDeposit(juniorVault, JUNIOR_DEPOSITOR, 20_000e6);
        vm.warp(pool.lpEpochStart(seniorId > juniorId ? seniorId : juniorId));
        _refreshMarkForAsyncSettlement();
        vm.expectRevert(TrancheVault.TrancheVault__SeniorDepositCommitted.selector);
        vm.prank(SENIOR_DEPOSITOR);
        seniorVault.cancelPendingDeposit(seniorId);
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochAlreadyActive.selector);
        vm.prank(JUNIOR_DEPOSITOR);
        juniorVault.cancelPendingDeposit(juniorId);
        assertEq(pool.reservedSeniorDepositAssets(), 10_000e6);
    }

    function test_FinalizedDepositCanClaimButCannotCancelDuringPause() public {
        uint256 id = _requestAsyncDeposit(juniorVault, JUNIOR_DEPOSITOR, 10_000e6);
        _settleAsyncRequest(id, true);
        _pauseEntry();
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochFinalized.selector);
        vm.prank(JUNIOR_DEPOSITOR);
        juniorVault.cancelPendingDeposit(id);
        assertGt(_claimAsyncDeposit(juniorVault, id, JUNIOR_DEPOSITOR), 0);
        assertEq(juniorVault.pendingDepositEscrowAssets(), 0);
    }

    function test_RedemptionCanBeFundedAndClaimedDuringEntryPause() public {
        _fundJunior(LP, 10_000e6);
        _finishAsyncCooldown(juniorVault, LP);
        uint256 id = _requestAsyncRedeem(juniorVault, LP, juniorVault.balanceOf(LP));
        _pauseEntry();
        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(id, true);
        assertGt(result.juniorFundedAssets, 0);
        (, uint256 paid) = _claimAsyncRedeem(juniorVault, id, LP);
        assertEq(paid, result.juniorFundedAssets);
        assertEq(settlementToken.balanceOf(LP), paid);
        assertTrue(pool.paused());
    }

    function test_AlreadyFundedRedemptionSurvivesPoolLossAndPause() public {
        _fundJunior(LP, 10_000e6);
        _finishAsyncCooldown(juniorVault, LP);
        uint256 id = _requestAsyncRedeem(juniorVault, LP, juniorVault.balanceOf(LP));
        IHousePool.LpEpochSettlementResult memory result = _settleAsyncRequest(id, true);
        settlementToken.burn(address(pool), pool.totalAssets());
        _pauseEntry();
        (, uint256 paid) = _claimAsyncRedeem(juniorVault, id, LP);
        assertEq(paid, result.juniorFundedAssets);
        assertGt(paid, 0);
    }

    function test_ExistingPositionClosesAndTraderClaimPaysDuringPause() public {
        _fundJunior(LP, 100_000e6);
        _fundTrader(TRADER, 20_000e6);
        _open(TRADER, CfdTypes.Side.LONG, 10_000e18, 10_000e6, 1e8);
        settlementToken.burn(address(pool), pool.totalAssets());
        _pauseEntry();
        vm.warp(vm.getBlockTimestamp() + 1);
        _close(TRADER, CfdTypes.Side.LONG, 10_000e18, 80_000_000);
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0);
        uint256 claim = engine.traderClaimBalanceAssets(TRADER);
        assertGt(claim, 0);
        _recapitalize(claim);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        vm.prank(TRADER);
        engine.settleTraderClaim(TRADER);
        assertEq(engine.traderClaimBalanceAssets(TRADER), 0);
        assertEq(clearinghouse.balanceAssets(TRADER), beforeBalance + claim);
    }

    function test_ExistingPositionLiquidatesDuringPause() public {
        _fundJunior(LP, 100_000e6);
        _fundTrader(TRADER, 1000e6);
        _open(TRADER, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);
        _pauseEntry();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(TRADER, 110_000_000, depth, uint64(vm.getBlockTimestamp()), address(0x7115));
        (uint256 size,,,,,,) = engine.positions(TRADER);
        assertEq(size, 0);
    }

    function test_QueuedOpenRefundsMarginAndBountyDuringPause() public {
        _fundJunior(LP, 100_000e6);
        _fundTrader(TRADER, 20_000e6);
        vm.prank(TRADER);
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, 1000e18, 1000e6, 1e8, false);
        IOrderRouterAccounting.AccountReservationView memory beforeReservations = router.getAccountReservations(TRADER);
        assertGt(beforeReservations.committedMarginAssets, 0);
        assertGt(beforeReservations.executionBountyAssets, 0);
        uint256 beforeBalance = clearinghouse.balanceAssets(TRADER);
        _pauseEntry();
        address keeper = address(0x7116);
        vm.prank(keeper);
        router.clearRiskOffOrder(id);
        IOrderRouterAccounting.AccountReservationView memory afterReservations = router.getAccountReservations(TRADER);
        assertEq(afterReservations.pendingOrderCount, 0);
        assertEq(afterReservations.committedMarginAssets, 0);
        assertEq(afterReservations.executionBountyAssets, 0);
        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(TRADER);
        assertEq(buckets.freeSettlementAssets, beforeBalance);
        assertEq(clearinghouse.balanceAssets(TRADER), beforeBalance);
        assertEq(clearinghouse.balanceAssets(keeper), 0);
    }

}

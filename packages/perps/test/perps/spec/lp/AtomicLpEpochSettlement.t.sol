// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Caller used to prove that the Router's final ETH refund cannot reenter LP settlement.
import {
    AtomicLpEpochSettlementTestFixture,
    LpEpochRefundReenterer
} from "../../shared/AtomicLpEpochSettlementFixture.sol";

contract AtomicLpEpochSettlementTest is AtomicLpEpochSettlementTestFixture {

    using stdStorage for StdStorage;

    function test_NoPosition_CachedSettlementRemainsPermissionless() public {
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);

        uint64 markTimeBefore = engine.lastMarkTime();
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);

        assertEq(result.juniorDepositAssets, assets);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertEq(engine.lastMarkTime(), markTimeBefore, "no-position fallback must not manufacture a mark");
    }

    function test_LivePosition_DirectCachedSettlementRejectsEvenAfterSeparateRefresh() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);

        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(0, 0);

        _setBasket(110_000_000, 0, block.timestamp);
        router.updateMarkPrice(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), block.timestamp, "separate refresh must install a fresh cached mark");

        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(0, 0);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets, "bypass attempt must not consume work");
    }

    function test_AtomicSettlement_UsesValidatedMarkForMarkSensitivePosition() public {
        _seedJuniorLp(ALICE, 100_000e6);
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(BOB, assets);
        _warpToEpoch(requestId);

        uint256 markPrice = 120_000_000;
        _setBasket(markPrice, 0, block.timestamp);
        uint256 branchPoint = vm.snapshotState();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice, uint64(block.timestamp));
        uint256 expectedShares = juniorVault.estimateDepositShares(assets);
        vm.revertToState(branchPoint);

        router.settleLpEpoch(_emptyUpdateData());

        assertEq(engine.lastMarkPrice(), markPrice);
        assertEq(engine.lastMarkTime(), block.timestamp);
        assertEq(juniorVault.pendingDepositRequest(requestId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, BOB), assets);

        uint256 shares = _claimJuniorDeposit(requestId, BOB);
        assertEq(shares, expectedShares, "atomic settlement must price the deposit from the validated mark snapshot");
    }

    function test_AtomicSettlement_ProcessesMaturedRedemptionAndDepositFromOneMark() public {
        uint256 aliceShares = _seedJuniorLp(ALICE, 100_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _openMarkSensitivePosition();

        uint256 redeemId = _requestJuniorRedeem(ALICE, aliceShares / 5);
        uint256 depositAssets = 10_000e6;
        uint256 depositId = _requestJuniorDeposit(BOB, depositAssets);
        assertEq(depositId, redeemId, "same-window deposit and redemption must share one request id");
        _warpToEpoch(depositId);

        _setBasket(110_000_000, 0, block.timestamp);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0);
        assertGt(juniorVault.claimableRedeemRequest(redeemId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(depositId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), depositAssets);
    }

    function test_AtomicSettlement_RejectsFreshPreBoundaryMarkThenAcceptsBoundaryMark() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary + 30);

        uint64 markTimeBefore = engine.lastMarkTime();
        _setBasket(110_000_000, 0, boundary - 1);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(engine.lastMarkTime(), markTimeBefore, "rejected boundary mark must roll back Engine state");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);

        _setBasket(110_000_000, 0, boundary);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertEq(engine.lastMarkTime(), boundary, "the exact epoch boundary must be accepted");
    }

    function test_AtomicSettlement_PreBoundaryNoProgressPreservesImminentAndRolledWork() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 imminentId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(imminentId, BOB, assets);
        uint256 boundary = pool.lpEpochStart(imminentId);
        vm.warp(boundary - 1);

        assertLt(pool.currentLpEpoch(), imminentId, "the imminent request must not mature before its boundary");
        assertEq(juniorVault.depositQueueHead(), imminentId);
        assertEq(juniorVault.depositQueueTail(), rolledId);

        _setBasket(110_000_000, 0, block.timestamp);
        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        uint256 reconcileBefore = pool.lastReconcileTime();
        uint256 couponBefore = pool.lastSeniorCouponCheckpointTime();
        uint256 accountedBefore = pool.accountedAssets();

        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "failed call must roll back Pyth");
        assertEq(engine.lastMarkPrice(), markPriceBefore, "failed call must roll back the Engine price");
        assertEq(engine.lastMarkTime(), markTimeBefore, "failed call must roll back the Engine timestamp");
        assertEq(pool.lastReconcileTime(), reconcileBefore, "failed call must roll back pool reconciliation");
        assertEq(pool.lastSeniorCouponCheckpointTime(), couponBefore, "failed call must roll back coupon state");
        assertEq(pool.accountedAssets(), accountedBefore, "failed call must roll back pool accounting");
        assertEq(juniorVault.pendingDepositRequest(imminentId, ALICE), assets);
        assertEq(juniorVault.claimableDepositRequest(imminentId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
        assertEq(juniorVault.claimableDepositRequest(rolledId, BOB), 0);
        assertEq(juniorVault.depositQueueHead(), imminentId, "imminent queue head must survive atomic rollback");
        assertEq(juniorVault.depositQueueTail(), rolledId, "rolled queue tail must survive atomic rollback");
    }

    function test_AtomicSettlement_FailedBoundaryAttemptCannotAdmitMaturedBatchAndRetrySettlesOnlyImminent() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 imminentId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(imminentId, BOB, assets);
        uint256 boundary = pool.lpEpochStart(imminentId);
        vm.warp(boundary);

        uint64 markTimeBefore = engine.lastMarkTime();
        _setBasket(110_000_000, 0, boundary - 1);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(engine.lastMarkTime(), markTimeBefore, "failed boundary attempt must roll back the Engine mark");
        assertEq(juniorVault.pendingDepositRequest(imminentId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);

        _setBasket(110_000_000, 0, boundary);
        router.updateMarkPrice(_emptyUpdateData());
        uint256 retryWindowId = _requestJuniorDeposit(CAROL, assets);
        assertEq(retryWindowId, rolledId, "post-failure request must not join the already-matured epoch");

        router.settleLpEpoch(_emptyUpdateData());

        assertEq(juniorVault.claimableDepositRequest(imminentId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
        assertEq(juniorVault.pendingDepositRequest(retryWindowId, CAROL), assets);
        assertEq(juniorVault.depositQueueHead(), rolledId, "rolled epoch must remain at the queue head");
        assertEq(juniorVault.depositQueueTail(), rolledId, "rolled epoch must remain the only queued epoch");

        uint256 nextCutoff = pool.lpEpochStart(rolledId) - juniorVault.LP_REQUEST_CUTOFF_DURATION();
        vm.warp(nextCutoff);
        _setBasket(110_000_000, 0, nextCutoff);
        router.updateMarkPrice(_emptyUpdateData());
        uint256 laterId = _requestJuniorDeposit(DAVE, assets);
        assertEq(laterId, rolledId + 1, "exact next cutoff must route requests beyond the rolled epoch");
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, CAROL), assets);
        assertEq(juniorVault.pendingDepositRequest(laterId, DAVE), assets);
    }

    function test_AtomicSettlement_FullyCancelledImminentBatchRollsBackAndPreservesRolledQueue() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 imminentId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(imminentId, BOB, assets);

        vm.prank(ALICE);
        assertEq(juniorVault.cancelPendingDeposit(imminentId), assets);
        assertEq(juniorVault.depositQueueHead(), rolledId);
        assertEq(juniorVault.depositQueueTail(), rolledId);

        vm.warp(pool.lpEpochStart(imminentId));
        _setBasket(110_000_000, 0, block.timestamp);
        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        uint256 reconcileBefore = pool.lastReconcileTime();
        uint256 couponBefore = pool.lastSeniorCouponCheckpointTime();
        uint256 accountedBefore = pool.accountedAssets();

        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "failed call must roll back Pyth");
        assertEq(engine.lastMarkPrice(), markPriceBefore, "failed call must roll back the Engine price");
        assertEq(engine.lastMarkTime(), markTimeBefore, "failed call must roll back the Engine timestamp");
        assertEq(pool.lastReconcileTime(), reconcileBefore, "failed call must roll back pool reconciliation");
        assertEq(pool.lastSeniorCouponCheckpointTime(), couponBefore, "failed call must roll back coupon state");
        assertEq(pool.accountedAssets(), accountedBefore, "failed call must roll back pool accounting");
        assertEq(juniorVault.pendingDepositRequest(imminentId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
        assertEq(juniorVault.depositQueueHead(), rolledId, "rolled queue head must survive atomic rollback");
        assertEq(juniorVault.depositQueueTail(), rolledId, "rolled queue tail must survive atomic rollback");
    }

    function test_AtomicSettlement_PartialImminentCancellationSettlesOnlyRemainingController() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 imminentId = _requestJuniorDeposit(ALICE, assets);
        assertEq(_requestJuniorDeposit(BOB, assets), imminentId, "pre-cutoff requests must batch together");
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(imminentId, CAROL, assets);

        vm.prank(ALICE);
        assertEq(juniorVault.cancelPendingDeposit(imminentId), assets);

        vm.warp(pool.lpEpochStart(imminentId));
        _setBasket(110_000_000, 0, block.timestamp);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(juniorVault.pendingDepositRequest(imminentId, ALICE), 0);
        assertEq(juniorVault.claimableDepositRequest(imminentId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(imminentId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(imminentId, BOB), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, CAROL), assets);
        assertEq(juniorVault.depositQueueHead(), rolledId);
        assertEq(juniorVault.depositQueueTail(), rolledId);
    }

    function test_AtomicSettlement_OracleConfidenceAndStalenessFailuresLeaveQueueUntouched() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(requestId, BOB, assets);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary);

        uint64 markTimeBefore = engine.lastMarkTime();
        _setBasket(100_000_000, 200_000, boundary);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), markTimeBefore);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);

        vm.warp(boundary + 61);
        _setBasket(100_000_000, 0, boundary);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), markTimeBefore);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);

        _setBasket(100_000_000, 0, block.timestamp);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(
            juniorVault.claimableDepositRequest(requestId, ALICE),
            assets,
            "valid replacement tick must settle preserved work"
        );
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets, "rolled work must remain queued");
    }

    function test_AtomicSettlement_InsufficientPythFeeRollsBackWithoutTouchingQueueOrMark() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);
        _setBasket(110_000_000, 0, block.timestamp);
        baseMockPyth.setFee(1 ether);

        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        vm.deal(address(this), 1 ether);

        vm.expectPartialRevert(IPletherOracle.PletherOracle__InsufficientFee.selector);
        router.settleLpEpoch{value: 1 ether - 1}(_emptyUpdateData());

        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "underpayment must not call Pyth");
        assertEq(engine.lastMarkPrice(), markPriceBefore, "underpayment must not update the Engine price");
        assertEq(engine.lastMarkTime(), markTimeBefore, "underpayment must not update the Engine timestamp");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets, "underpayment must preserve work");
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), 0);
    }

    function test_AtomicSettlement_FutureAndOutOfOrderTicksRollBackThenCurrentTickSettles() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(requestId, BOB, assets);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary);

        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint64 markTimeBefore = engine.lastMarkTime();
        _setBasket(110_000_000, 0, boundary + 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "future update must roll back Pyth call");
        assertEq(engine.lastMarkTime(), markTimeBefore, "future update must roll back Engine state");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);

        _setBasket(110_000_000, 0, boundary);
        router.updateMarkPrice(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), boundary, "setup refresh must establish the ordering floor");

        updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        _setBasket(110_000_000, 0, boundary - 1);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__PriceOutOfOrder.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "out-of-order update must roll back Pyth call"
        );
        assertEq(engine.lastMarkTime(), boundary, "out-of-order update must preserve the cached mark");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);

        _setBasket(110_000_000, 0, boundary);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
    }

    function test_AtomicSettlement_ComponentPublishTimeDivergenceRollsBack() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 10;
        _setRouterConfig(config);

        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        uint256 rolledId = _requestRolledJuniorDepositForLivePosition(requestId, BOB, assets);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary + 11);

        baseMockPyth.setPrice(BASE_PYTH_FEED_A, int64(100_000_000), int32(-8), boundary);
        baseMockPyth.setPrice(BASE_PYTH_FEED_B, int64(100_000_000), int32(-8), boundary + 11);
        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint64 markTimeBefore = engine.lastMarkTime();

        vm.expectPartialRevert(IPletherOracle.PletherOracle__PublishTimeDivergence.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "divergent update must roll back Pyth call"
        );
        assertEq(engine.lastMarkTime(), markTimeBefore, "divergent update must not install a partial basket");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(rolledId, BOB), assets);
    }

    function test_AtomicSettlement_DegradedModeRejectsAndRollsBackOracleAndMark() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);
        _setBasket(110_000_000, 0, block.timestamp);

        stdstore.target(address(engine)).sig("degradedMode()").checked_write(true);
        assertTrue(engine.degradedMode(), "fixture must latch degraded mode");
        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();

        vm.expectRevert(IHousePool.HousePool__DegradedMode.selector);
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "degraded revert must roll back Pyth");
        assertEq(engine.lastMarkPrice(), markPriceBefore, "degraded revert must roll back Engine price");
        assertEq(engine.lastMarkTime(), markTimeBefore, "degraded revert must roll back Engine timestamp");
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), 0);
    }

    function test_AtomicSettlement_RemainsCallableWhileRouterAdminPaused() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);
        _setBasket(110_000_000, 0, block.timestamp);

        routerAdmin.pause();
        assertTrue(routerAdmin.paused(), "fixture must pause user order routing");
        router.settleLpEpoch(_emptyUpdateData());

        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
    }

    function test_AtomicSettlement_HousePoolPauseFundsExitAndDefersEntry() public {
        uint256 aliceShares = _seedJuniorLp(ALICE, 100_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _openMarkSensitivePosition();

        uint256 redeemId = _requestJuniorRedeem(ALICE, aliceShares / 5);
        uint256 depositAssets = 10_000e6;
        uint256 depositId = _requestJuniorDeposit(BOB, depositAssets);
        assertEq(depositId, redeemId, "same-window deposit and redemption must share one request id");
        _warpToEpoch(depositId);
        _setBasket(110_000_000, 0, block.timestamp);
        pool.pause();

        router.settleLpEpoch(_emptyUpdateData());

        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0, "paused pool must still fund matured exit");
        assertGt(juniorVault.claimableRedeemRequest(redeemId, ALICE), 0);
        assertEq(
            juniorVault.pendingDepositRequest(depositId, BOB), depositAssets, "paused pool must defer matured entry"
        );
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), 0);
    }

    function test_CachedSettlement_SettlementHoldPreservesBacklogUntilGovernanceRelease() public {
        uint256 aliceShares = _seedJuniorLp(ALICE, 100_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());

        uint256 redeemId = _requestJuniorRedeem(ALICE, aliceShares / 5);
        uint256 depositAssets = 10_000e6;
        uint256 depositId = _requestJuniorDeposit(BOB, depositAssets);
        assertEq(depositId, redeemId, "entry and exit must share the held epoch");
        _warpToEpoch(depositId);

        pool.pauseLpEpochSettlement();
        assertTrue(pool.lpEpochSettlementPaused());

        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        pool.settleLpEpoch(0, 0);

        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), aliceShares / 5);
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), 0);
        assertEq(juniorVault.pendingDepositRequest(depositId, BOB), depositAssets);
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), 0);

        pool.unpauseLpEpochSettlement();
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);

        assertGt(result.juniorFundedAssets, 0, "release must fund the preserved exit");
        assertEq(result.juniorFundedShares, aliceShares / 5);
        assertEq(result.juniorDepositAssets, depositAssets, "release must activate the preserved entry");
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), aliceShares / 5);
        assertEq(juniorVault.pendingDepositRequest(depositId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), depositAssets);

        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);
        assertEq(
            juniorVault.claimableRedeemRequest(redeemId, ALICE),
            aliceShares / 5,
            "the released backlog must not fund twice"
        );
        assertEq(
            juniorVault.claimableDepositRequest(depositId, BOB),
            depositAssets,
            "the released backlog must not activate twice"
        );
    }

    function test_SettlementHold_AllowsSeniorReservationAndCancellation() public {
        uint256 assets = 10_000e6;
        uint256 reservedBefore = pool.reservedSeniorDepositAssetsUsdc();

        pool.pauseLpEpochSettlement();
        usdc.mint(ALICE, assets);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), assets);
        uint256 requestId = seniorVault.requestDeposit(assets, ALICE, ALICE);
        vm.stopPrank();

        assertTrue(pool.lpEpochSettlementPaused());
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), reservedBefore + assets);
        assertEq(seniorVault.pendingDepositRequest(requestId, ALICE), assets);

        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(requestId), assets);

        assertTrue(pool.lpEpochSettlementPaused(), "cancellation must not release the settlement hold");
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), reservedBefore);
        assertEq(seniorVault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(usdc.balanceOf(ALICE), assets, "cancellation must return the Senior deposit escrow");
    }

    function test_SettlementHold_DoesNotMakeHealthyMaturedDepositCancellable() public {
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);

        pool.pauseLpEpochSettlement();

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__DepositEpochAlreadyActive.selector);
        juniorVault.cancelPendingDeposit(requestId);

        assertTrue(pool.lpEpochSettlementPaused());
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), 0);
    }

    function test_SettlementHold_AllowsAuthorizedRecapitalizationAndDirectReconcile() public {
        uint256 targetSeniorPrincipal = pool.seniorPrincipal();
        uint256 retainedAssets = targetSeniorPrincipal / 2;
        uint256 rawAssets = pool.rawAssets();
        assertGt(rawAssets, retainedAssets, "fixture must have enough pool cash to impair Senior");

        pool.pauseLpEpochSettlement();
        usdc.burn(address(pool), rawAssets - retainedAssets);

        vm.prank(address(seniorVault));
        pool.reconcile();

        assertTrue(pool.lpEpochSettlementPaused());
        assertEq(pool.juniorPrincipal(), 0, "direct reconcile must apply the loss while held");
        assertEq(pool.seniorPrincipal(), retainedAssets, "direct reconcile must impair Senior while held");

        uint256 recapitalization = targetSeniorPrincipal - retainedAssets;
        usdc.mint(address(pool), recapitalization);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapitalization,
            IHousePool.ClaimantInflowKind.Recapitalization,
            IHousePool.ClaimantInflowCashMode.CashArrived
        );

        assertEq(pool.pendingRecapitalizationUsdc(), recapitalization);
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertTrue(pool.lpEpochSettlementPaused(), "recovery accounting must not release the settlement hold");
        assertEq(pool.pendingRecapitalizationUsdc(), 0);
        assertEq(pool.seniorPrincipal(), targetSeniorPrincipal, "recapitalization must restore Senior while held");
        assertEq(pool.seniorHighWaterMark(), targetSeniorPrincipal);
    }

    function test_AtomicSettlement_SettlementHoldRollsBackThenReleaseSettlesSameBacklog() public {
        uint256 aliceShares = _seedJuniorLp(ALICE, 100_000e6);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _openMarkSensitivePosition();

        uint256 redeemId = _requestJuniorRedeem(ALICE, aliceShares / 5);
        uint256 depositAssets = 10_000e6;
        uint256 depositId = _requestJuniorDeposit(BOB, depositAssets);
        assertEq(depositId, redeemId, "entry and exit must share the held epoch");
        _warpToEpoch(depositId);

        _setBasket(100_000_000, 0, block.timestamp);
        baseMockPyth.setFee(1 ether);
        address caller = address(0xC011E2);
        vm.deal(caller, 2 ether);
        pool.pauseLpEpochSettlement();

        SettlementHoldRollbackSnapshot memory beforeState = _settlementHoldSnapshot(caller, depositId, redeemId);

        vm.prank(caller);
        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(120_000_000));

        _assertSettlementHoldSnapshot(beforeState, caller, depositId, redeemId);

        pool.unpauseLpEpochSettlement();
        vm.prank(caller);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(120_000_000));

        assertFalse(pool.lpEpochSettlementPaused());
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), beforeState.pythUpdateCalls + 1);
        assertEq(engine.lastMarkPrice(), 120_000_000);
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), aliceShares / 5);
        assertEq(juniorVault.pendingDepositRequest(depositId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), depositAssets);

        uint256 updateCallsAfterSettlement = baseMockPyth.updatePriceFeedsCallCount();
        vm.prank(caller);
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(120_000_000));
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(),
            updateCallsAfterSettlement,
            "the released backlog must not settle or update the oracle twice"
        );
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), aliceShares / 5);
        assertEq(juniorVault.claimableDepositRequest(depositId, BOB), depositAssets);
    }

    function test_AtomicSettlement_MaintenanceFeeAccruesDuringHoldAndMaterializesOnceAfterRelease() public {
        MaintenanceFeeSettlementFixture memory fixture = _prepareHeldMaintenanceFeeSettlement();
        SettlementHoldRollbackSnapshot memory beforeState =
            _settlementHoldSnapshot(fixture.caller, fixture.depositId, fixture.redeemId);

        vm.prank(fixture.caller);
        vm.expectRevert(IHousePool.HousePool__LpEpochSettlementPaused.selector);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));

        _assertSettlementHoldSnapshot(beforeState, fixture.caller, fixture.depositId, fixture.redeemId);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), fixture.feeShares, "held attempt must preserve accrued fee");

        pool.unpauseLpEpochSettlement();
        assertEq(juniorVault.totalSupply(), fixture.rawSupplyBefore, "release cannot mint fee shares");
        assertEq(
            juniorVault.maintenanceFeeCheckpointBoundary(),
            fixture.feeBoundaryBefore,
            "release cannot advance fee checkpoint"
        );
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), 0, "release cannot credit the recipient");

        vm.prank(fixture.caller);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));

        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT),
            fixture.feeShares,
            "recovery must mint the accrued fee once"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0, "successful settlement must consume accrued fee");
        assertGt(
            juniorVault.maintenanceFeeCheckpointBoundary(),
            fixture.feeBoundaryBefore,
            "successful settlement advances checkpoint"
        );
        assertEq(juniorVault.pendingRedeemRequest(fixture.redeemId, ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(fixture.redeemId, ALICE), fixture.redeemShares);
        assertEq(juniorVault.pendingDepositRequest(fixture.depositId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(fixture.depositId, BOB), fixture.depositAssets);

        uint256 checkpointAfterSettlement = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.prank(fixture.caller);
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), fixture.feeShares, "fee must not mint twice");
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointAfterSettlement);
    }

    function test_AtomicSettlement_DownstreamFailureRollsBackMaterializedMaintenanceFee() public {
        MaintenanceFeeSettlementFixture memory fixture = _prepareFailingMaintenanceFeeSettlement();
        SettlementHoldRollbackSnapshot memory beforeState =
            _settlementHoldSnapshot(fixture.caller, fixture.depositId, fixture.redeemId);

        vm.prank(fixture.caller);
        vm.expectRevert(fixture.injectedFailure);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));

        _assertSettlementHoldSnapshot(beforeState, fixture.caller, fixture.depositId, fixture.redeemId);
        assertEq(
            juniorVault.pendingMaintenanceFeeShares(), fixture.feeShares, "failed settlement must preserve accrued fee"
        );
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), 0, "transient fee mint must roll back completely");

        vm.clearMockedCalls();
        vm.prank(fixture.caller);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));

        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT),
            fixture.feeShares,
            "recovered settlement must mint fee once"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(juniorVault.pendingRedeemRequest(fixture.redeemId, ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(fixture.redeemId, ALICE), fixture.redeemShares);
        assertEq(juniorVault.pendingDepositRequest(fixture.depositId, BOB), 0);
        assertEq(juniorVault.claimableDepositRequest(fixture.depositId, BOB), fixture.depositAssets);

        uint256 checkpointAfterSettlement = juniorVault.maintenanceFeeCheckpointBoundary();
        vm.prank(fixture.caller);
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch{value: 1 ether}(_encodedUpdateData(100_000_000));
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), fixture.feeShares, "fee must remain single-shot");
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointAfterSettlement);
    }

    function test_AtomicSettlement_NoProgressRollsBackOracleEngineCarryAndPoolState() public {
        _seedJuniorLp(ALICE, 100_000e6);
        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 6 hours);
        _openMarkSensitivePosition();
        _warpToEpoch(pool.currentLpEpoch() + 1);
        _setBasket(100_000_000, 0, block.timestamp);

        assertGt(juniorVault.pendingMaintenanceFeeShares(), 0, "fixture must have an outstanding maintenance fee");
        bytes32 maintenanceFeeStateBefore = _maintenanceFeeStateDigest();
        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        PythStructs.Price memory pythBefore = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        uint256 longCarryBefore = engine.sideCarryIndex(uint256(CfdTypes.Side.LONG));
        uint256 shortCarryBefore = engine.sideCarryIndex(uint256(CfdTypes.Side.SHORT));
        uint256 reconcileBefore = pool.lastReconcileTime();
        uint256 couponBefore = pool.lastSeniorCouponCheckpointTime();
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 accountedBefore = pool.accountedAssets();

        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        router.settleLpEpoch(_encodedUpdateData(120_000_000));

        PythStructs.Price memory pythAfter = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), updateCallsBefore, "Pyth update must roll back");
        assertEq(pythAfter.price, pythBefore.price, "Pyth price must roll back");
        assertEq(pythAfter.publishTime, pythBefore.publishTime, "Pyth timestamp must roll back");
        assertEq(engine.lastMarkPrice(), markPriceBefore, "Engine price must roll back");
        assertEq(engine.lastMarkTime(), markTimeBefore, "Engine timestamp must roll back");
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.LONG)), longCarryBefore, "long carry must roll back");
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.SHORT)), shortCarryBefore, "short carry must roll back");
        assertEq(pool.lastReconcileTime(), reconcileBefore, "reconcile checkpoint must roll back");
        assertEq(pool.lastSeniorCouponCheckpointTime(), couponBefore, "coupon checkpoint must roll back");
        assertEq(pool.seniorPrincipal(), seniorBefore);
        assertEq(pool.juniorPrincipal(), juniorBefore);
        assertEq(pool.accountedAssets(), accountedBefore);
        assertEq(
            _maintenanceFeeStateDigest(),
            maintenanceFeeStateBefore,
            "no-progress settlement cannot mint, credit, checkpoint, or forgive the outstanding fee"
        );
    }

    function test_HousePoolAtomicCallback_RejectsWrongCallerAndMismatchedBinding() public {
        _openMarkSensitivePosition();
        uint256 requestId = _requestJuniorDeposit(ALICE, 10_000e6);
        _warpToEpoch(requestId);

        uint256 markPrice = 110_000_000;
        uint64 publishTime = uint64(block.timestamp);
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice, publishTime);

        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(markPrice, publishTime);

        vm.prank(address(router));
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(markPrice + 1, publishTime);

        vm.prank(address(router));
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(markPrice, publishTime - 1);
    }

    function test_FadOnlyPosition_StillRequiresAtomicSettlement() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        vm.warp(FRIDAY_FAD_ONLY);
        assertGe(pool.currentLpEpoch(), requestId, "queued entry must be mature");
        assertTrue(engine.isFadWindow(), "fixture must be in FAD-only mode");
        assertFalse(engine.isOracleFrozen(), "FAD-only mode must retain live oracle policy");

        _setBasket(110_000_000, 0, block.timestamp);
        router.updateMarkPrice(_emptyUpdateData());
        vm.expectRevert(IHousePool.HousePool__Unauthorized.selector);
        pool.settleLpEpoch(0, 0);

        router.settleLpEpoch(_emptyUpdateData());
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
    }

    function test_FrozenPosition_CachedSettlementRetainsExitLivenessWithRelaxedAge() public {
        uint256 depositId = _requestJuniorDeposit(ALICE, 10_000e6);
        _warpToEpoch(depositId);
        pool.settleLpEpoch(0, 0);
        uint256 shares = _claimJuniorDeposit(depositId, ALICE);

        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _openMarkSensitivePosition();
        uint256 redeemId = _requestJuniorRedeem(ALICE, shares / 2);

        vm.warp(SATURDAY_FROZEN);
        assertGe(pool.currentLpEpoch(), redeemId, "queued exit must be mature");
        assertTrue(engine.isOracleFrozen(), "fixture must use frozen-oracle policy");
        _setBasket(100_000_000, 0, block.timestamp);
        router.updateMarkPrice(_emptyUpdateData());

        vm.warp(block.timestamp + 2 hours);
        assertTrue(engine.isOracleFrozen(), "two-hour age must remain inside the frozen window");
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);

        assertGt(result.juniorFundedAssets, 0);
        assertEq(result.juniorFundedShares, shares / 2);
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0);
    }

    function test_FrozenPosition_CachedSettlementRejectsBeyondFadAgeThenAtomicRefreshRecovers() public {
        uint256 depositId = _requestJuniorDeposit(ALICE, 10_000e6);
        _warpToEpoch(depositId);
        pool.settleLpEpoch(0, 0);
        uint256 shares = _claimJuniorDeposit(depositId, ALICE);

        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _openMarkSensitivePosition();
        uint256 redeemId = _requestJuniorRedeem(ALICE, shares / 2);

        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen(), "fixture must use frozen-oracle policy");
        assertGt(block.timestamp, engine.lastMarkTime() + engine.fadMaxStaleness(), "cached mark must exceed FAD age");

        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.settleLpEpoch(0, 0);
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), shares / 2);

        _setBasket(100_000_000, 0, block.timestamp);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(juniorVault.pendingRedeemRequest(redeemId, ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(redeemId, ALICE), shares / 2);
    }

    function test_AtomicSettlement_RefundOccursAfterSettlementAndCannotReenter() public {
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        _warpToEpoch(requestId);
        _setBasket(100_000_000, 0, block.timestamp);
        baseMockPyth.setFee(1 ether);

        LpEpochRefundReenterer receiver = new LpEpochRefundReenterer(router);
        vm.deal(address(this), 2 ether);
        vm.recordLogs();
        receiver.settle{value: 2 ether}(_emptyUpdateData());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 settlementTopic = keccak256("LpEpochSettled(uint256,uint256,uint256,uint256,uint256,bool,bool,bool)");
        bytes32 refundTopic = keccak256("RefundCallback(bool,bytes4)");
        uint256 settlementLogPosition;
        uint256 refundLogPosition;
        bool reentered;
        bytes4 reentryRevertSelector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) {
                continue;
            }
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == settlementTopic) {
                settlementLogPosition = i + 1;
            } else if (logs[i].emitter == address(receiver) && logs[i].topics[0] == refundTopic) {
                refundLogPosition = i + 1;
                (reentered, reentryRevertSelector) = abi.decode(logs[i].data, (bool, bytes4));
            }
        }

        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertGt(settlementLogPosition, 0, "LP settlement event must be present");
        assertGt(refundLogPosition, settlementLogPosition, "the refund callback must occur after LP settlement");
        assertFalse(reentered, "Router transient guard must reject refund reentry");
        assertEq(
            reentryRevertSelector,
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "refund callback must fail at the nonreentrant boundary"
        );
        assertEq(address(receiver).balance, 1 ether, "only excess ETH must be returned");
        assertEq(routerAdmin.claimableEth(address(receiver)), 0, "the bounded callback must not require deferral");
        assertEq(address(baseMockPyth).balance, 1 ether, "Pyth must receive exactly its quoted fee");
    }

}

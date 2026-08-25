// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Caller used to prove that the Router's final ETH refund cannot reenter LP settlement.
contract LpEpochRefundReenterer {

    OrderRouter internal immutable ROUTER;

    event RefundCallback(bool reentered, bytes4 revertSelector);

    constructor(
        OrderRouter router
    ) {
        ROUTER = router;
    }

    function settle(
        bytes[] calldata updateData
    ) external payable {
        ROUTER.settleLpEpoch{value: msg.value}(updateData);
    }

    receive() external payable {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        (bool ok, bytes memory revertData) =
            address(ROUTER).call(abi.encodeCall(OrderRouter.settleLpEpoch, (updateData)));
        bytes4 revertSelector;
        if (revertData.length >= 4) {
            assembly ("memory-safe") {
                revertSelector := mload(add(revertData, 0x20))
            }
        }
        emit RefundCallback(ok, revertSelector);
    }

}

/// @notice Deterministic security regressions for atomic mark refresh plus synchronized LP epoch settlement.
contract AtomicLpEpochSettlementTest is BasePerpTest {

    using stdStorage for StdStorage;

    struct SettlementHoldRollbackSnapshot {
        uint256 pythUpdateCalls;
        int64 pythPrice;
        uint256 pythPublishTime;
        uint256 callerEth;
        uint256 pythEth;
        uint256 markPrice;
        uint64 markTime;
        uint256 bullCarryIndex;
        uint256 bearCarryIndex;
        uint256 lastReconcileTime;
        uint256 lastSeniorCouponCheckpointTime;
        uint256 seniorPrincipal;
        uint256 juniorPrincipal;
        uint256 seniorHighWaterMark;
        uint256 accountedAssets;
        uint256 poolUsdc;
        uint256 vaultUsdc;
        uint256 juniorSupply;
        uint256 depositQueueHead;
        uint256 depositQueueTail;
        uint256 redeemQueueHead;
        uint256 redeemQueueTail;
        uint256 pendingDepositAssets;
        uint256 claimableDepositAssets;
        uint256 pendingRedeemShares;
        uint256 claimableRedeemShares;
    }

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant HOUSE_POOL_RUNTIME_TARGET = 24_529;
    uint256 internal constant REDEMPTION_MATH_SIDECAR_RUNTIME_LIMIT = 1200;
    uint256 internal constant CFD_ENGINE_RUNTIME_BASELINE = 24_429;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant TRADER = address(0x7A0E2);

    uint256 internal constant FRIDAY_FAD_ONLY = 1_709_934_300;
    uint256 internal constant SATURDAY_FROZEN = 1_709_985_600;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_AtomicLpEpoch_RuntimeFitsEip170() public view {
        assertLe(
            address(engine).code.length,
            CFD_ENGINE_RUNTIME_BASELINE,
            "terminal NAV synchronization must not grow CfdEngine runtime"
        );
        assertLe(
            address(pool).code.length,
            HOUSE_POOL_RUNTIME_TARGET,
            "atomic LP settlement must keep HousePool within its measured runtime target"
        );
        assertLt(address(pool).code.length, EIP170_RUNTIME_CODE_LIMIT, "HousePool must remain EIP-170 deployable");
        assertLt(
            address(housePoolRedemptionMathSidecar).code.length,
            REDEMPTION_MATH_SIDECAR_RUNTIME_LIMIT,
            "redemption math sidecar must remain below its runtime limit"
        );
        assertLe(
            vm.getDeployedCode("OrderRouter.sol:OrderRouter").length,
            EIP170_RUNTIME_CODE_LIMIT,
            "atomic LP settlement must keep production OrderRouter deployable"
        );
    }

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

    function test_AtomicSettlement_NoProgressRollsBackOracleEngineCarryAndPoolState() public {
        _openMarkSensitivePosition();
        _warpToEpoch(pool.currentLpEpoch() + 1);
        _setBasket(100_000_000, 0, block.timestamp);

        uint256 updateCallsBefore = baseMockPyth.updatePriceFeedsCallCount();
        PythStructs.Price memory pythBefore = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        uint256 markPriceBefore = engine.lastMarkPrice();
        uint64 markTimeBefore = engine.lastMarkTime();
        uint256 bullCarryBefore = engine.sideCarryIndex(uint256(CfdTypes.Side.BULL));
        uint256 bearCarryBefore = engine.sideCarryIndex(uint256(CfdTypes.Side.BEAR));
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
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.BULL)), bullCarryBefore, "bull carry must roll back");
        assertEq(engine.sideCarryIndex(uint256(CfdTypes.Side.BEAR)), bearCarryBefore, "bear carry must roll back");
        assertEq(pool.lastReconcileTime(), reconcileBefore, "reconcile checkpoint must roll back");
        assertEq(pool.lastSeniorCouponCheckpointTime(), couponBefore, "coupon checkpoint must roll back");
        assertEq(pool.seniorPrincipal(), seniorBefore);
        assertEq(pool.juniorPrincipal(), juniorBefore);
        assertEq(pool.accountedAssets(), accountedBefore);
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

    function _openMarkSensitivePosition() internal {
        _fundTrader(TRADER, 200e6);
        _open(TRADER, CfdTypes.Side.BULL, 1000e18, 100e6, 100_000_000);
    }

    function _seedJuniorLp(
        address owner,
        uint256 assets
    ) internal returns (uint256 shares) {
        uint256 requestId = _requestJuniorDeposit(owner, assets);
        _warpToEpoch(requestId);
        pool.settleLpEpoch(0, 0);
        shares = _claimJuniorDeposit(requestId, owner);
    }

    function _requestJuniorDeposit(
        address owner,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(owner, assets);
        vm.startPrank(owner);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, owner, owner);
        vm.stopPrank();
    }

    function _claimJuniorDeposit(
        uint256 requestId,
        address controller
    ) internal returns (uint256 shares) {
        uint256 assets = juniorVault.claimableDepositRequest(requestId, controller);
        assertGt(assets, 0);
        vm.prank(controller);
        shares = juniorVault.claimDeposit(requestId, assets, controller, controller);
    }

    function _requestJuniorRedeem(
        address owner,
        uint256 shares
    ) internal returns (uint256 requestId) {
        vm.prank(owner);
        requestId = juniorVault.requestRedeem(shares, owner, owner);
    }

    function _requestRolledJuniorDepositForLivePosition(
        uint256 imminentId,
        address owner,
        uint256 assets
    ) internal returns (uint256 rolledId) {
        uint256 cutoff = pool.lpEpochStart(imminentId) - juniorVault.LP_REQUEST_CUTOFF_DURATION();
        assertLt(block.timestamp, cutoff, "fixture must begin before the imminent request cutoff");
        vm.warp(cutoff);
        uint256 markPrice = engine.lastMarkPrice();
        _setBasket(markPrice == 0 ? 100_000_000 : markPrice, 0, cutoff);
        router.updateMarkPrice(_emptyUpdateData());
        rolledId = _requestJuniorDeposit(owner, assets);
        assertEq(rolledId, imminentId + 1, "exact cutoff must roll the request forward one epoch");
    }

    function _warpToEpoch(
        uint256 epochId
    ) internal {
        uint256 timestamp = pool.lpEpochStart(epochId);
        if (block.timestamp < timestamp) {
            vm.warp(timestamp);
        }
    }

    function _setBasket(
        uint256 price,
        uint64 confidence,
        uint256 publishTime
    ) internal {
        baseMockPyth.setAllPrices(_basePythFeedIds(), int64(uint64(price)), confidence, int32(-8), publishTime);
    }

    function _emptyUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _encodedUpdateData(
        uint256 price
    ) internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _settlementHoldSnapshot(
        address caller,
        uint256 depositId,
        uint256 redeemId
    ) internal view returns (SettlementHoldRollbackSnapshot memory snapshot) {
        PythStructs.Price memory pythPrice = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        snapshot.pythUpdateCalls = baseMockPyth.updatePriceFeedsCallCount();
        snapshot.pythPrice = pythPrice.price;
        snapshot.pythPublishTime = pythPrice.publishTime;
        snapshot.callerEth = caller.balance;
        snapshot.pythEth = address(baseMockPyth).balance;
        snapshot.markPrice = engine.lastMarkPrice();
        snapshot.markTime = engine.lastMarkTime();
        snapshot.bullCarryIndex = engine.sideCarryIndex(uint256(CfdTypes.Side.BULL));
        snapshot.bearCarryIndex = engine.sideCarryIndex(uint256(CfdTypes.Side.BEAR));
        snapshot.lastReconcileTime = pool.lastReconcileTime();
        snapshot.lastSeniorCouponCheckpointTime = pool.lastSeniorCouponCheckpointTime();
        snapshot.seniorPrincipal = pool.seniorPrincipal();
        snapshot.juniorPrincipal = pool.juniorPrincipal();
        snapshot.seniorHighWaterMark = pool.seniorHighWaterMark();
        snapshot.accountedAssets = pool.accountedAssets();
        snapshot.poolUsdc = usdc.balanceOf(address(pool));
        snapshot.vaultUsdc = usdc.balanceOf(address(juniorVault));
        snapshot.juniorSupply = juniorVault.totalSupply();
        snapshot.depositQueueHead = juniorVault.depositQueueHead();
        snapshot.depositQueueTail = juniorVault.depositQueueTail();
        snapshot.redeemQueueHead = juniorVault.redeemQueueHead();
        snapshot.redeemQueueTail = juniorVault.redeemQueueTail();
        snapshot.pendingDepositAssets = juniorVault.pendingDepositRequest(depositId, BOB);
        snapshot.claimableDepositAssets = juniorVault.claimableDepositRequest(depositId, BOB);
        snapshot.pendingRedeemShares = juniorVault.pendingRedeemRequest(redeemId, ALICE);
        snapshot.claimableRedeemShares = juniorVault.claimableRedeemRequest(redeemId, ALICE);
    }

    function _assertSettlementHoldSnapshot(
        SettlementHoldRollbackSnapshot memory expected,
        address caller,
        uint256 depositId,
        uint256 redeemId
    ) internal view {
        PythStructs.Price memory pythPrice = baseMockPyth.getPriceUnsafe(BASE_PYTH_FEED_A);
        assertEq(baseMockPyth.updatePriceFeedsCallCount(), expected.pythUpdateCalls, "Pyth update count must roll back");
        assertEq(pythPrice.price, expected.pythPrice, "Pyth price must roll back");
        assertEq(pythPrice.publishTime, expected.pythPublishTime, "Pyth publish time must roll back");
        assertEq(caller.balance, expected.callerEth, "caller ETH must roll back");
        assertEq(address(baseMockPyth).balance, expected.pythEth, "Pyth ETH must roll back");
        assertEq(engine.lastMarkPrice(), expected.markPrice, "Engine price must roll back");
        assertEq(engine.lastMarkTime(), expected.markTime, "Engine timestamp must roll back");
        assertEq(
            engine.sideCarryIndex(uint256(CfdTypes.Side.BULL)), expected.bullCarryIndex, "bull carry must roll back"
        );
        assertEq(
            engine.sideCarryIndex(uint256(CfdTypes.Side.BEAR)), expected.bearCarryIndex, "bear carry must roll back"
        );
        assertEq(pool.lastReconcileTime(), expected.lastReconcileTime, "reconcile checkpoint must roll back");
        assertEq(
            pool.lastSeniorCouponCheckpointTime(),
            expected.lastSeniorCouponCheckpointTime,
            "coupon checkpoint must roll back"
        );
        assertEq(pool.seniorPrincipal(), expected.seniorPrincipal, "Senior principal must roll back");
        assertEq(pool.juniorPrincipal(), expected.juniorPrincipal, "Junior principal must roll back");
        assertEq(pool.seniorHighWaterMark(), expected.seniorHighWaterMark, "Senior HWM must roll back");
        assertEq(pool.accountedAssets(), expected.accountedAssets, "accounted assets must roll back");
        assertEq(usdc.balanceOf(address(pool)), expected.poolUsdc, "pool USDC must roll back");
        assertEq(usdc.balanceOf(address(juniorVault)), expected.vaultUsdc, "vault USDC must roll back");
        assertEq(juniorVault.totalSupply(), expected.juniorSupply, "vault supply must roll back");
        assertEq(juniorVault.depositQueueHead(), expected.depositQueueHead, "deposit head must roll back");
        assertEq(juniorVault.depositQueueTail(), expected.depositQueueTail, "deposit tail must roll back");
        assertEq(juniorVault.redeemQueueHead(), expected.redeemQueueHead, "redeem head must roll back");
        assertEq(juniorVault.redeemQueueTail(), expected.redeemQueueTail, "redeem tail must roll back");
        assertEq(
            juniorVault.pendingDepositRequest(depositId, BOB),
            expected.pendingDepositAssets,
            "pending deposit must roll back"
        );
        assertEq(
            juniorVault.claimableDepositRequest(depositId, BOB),
            expected.claimableDepositAssets,
            "claimable deposit must roll back"
        );
        assertEq(
            juniorVault.pendingRedeemRequest(redeemId, ALICE),
            expected.pendingRedeemShares,
            "pending redemption must roll back"
        );
        assertEq(
            juniorVault.claimableRedeemRequest(redeemId, ALICE),
            expected.claimableRedeemShares,
            "claimable redemption must roll back"
        );
    }

}

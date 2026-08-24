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

/// @notice Caller used to prove that the Router's final ETH refund cannot reenter LP settlement.
contract LpEpochRefundReenterer {

    OrderRouter internal immutable ROUTER;
    IHousePool internal immutable POOL;

    bool public attempted;
    bool public reentered;
    bytes4 public revertSelector;
    bool public directAttempted;
    bool public directSettled;
    bytes4 public directRevertSelector;

    constructor(
        OrderRouter router,
        IHousePool pool
    ) {
        ROUTER = router;
        POOL = pool;
    }

    function settle(
        bytes[] calldata updateData
    ) external payable {
        ROUTER.settleLpEpoch{value: msg.value}(updateData);
    }

    receive() external payable {
        attempted = true;
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        (bool ok, bytes memory revertData) =
            address(ROUTER).call(abi.encodeCall(OrderRouter.settleLpEpoch, (updateData)));
        reentered = ok;
        if (revertData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(revertData, 0x20))
            }
            revertSelector = selector;
        }

        directAttempted = true;
        (ok, revertData) = address(POOL).call(abi.encodeCall(IHousePool.settleLpEpoch, (0, 0)));
        directSettled = ok;
        if (revertData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(revertData, 0x20))
            }
            directRevertSelector = selector;
        }
    }

}

/// @notice Deterministic security regressions for atomic mark refresh plus synchronized LP epoch settlement.
contract AtomicLpEpochSettlementTest is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;
    uint256 internal constant CFD_ENGINE_RUNTIME_BASELINE = 24_429;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
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
            address(pool).code.length, EIP170_RUNTIME_CODE_LIMIT, "atomic LP settlement must keep HousePool deployable"
        );
        assertLe(
            address(router).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "atomic LP settlement must keep OrderRouter deployable"
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
        _warpToEpoch(depositId > redeemId ? depositId : redeemId);

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

    function test_AtomicSettlement_OracleConfidenceAndStalenessFailuresLeaveQueueUntouched() public {
        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary);

        uint64 markTimeBefore = engine.lastMarkTime();
        _setBasket(100_000_000, 200_000, boundary);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__BasketConfidenceTooWide.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), markTimeBefore);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);

        vm.warp(boundary + 61);
        _setBasket(100_000_000, 0, boundary);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(engine.lastMarkTime(), markTimeBefore);
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), assets);

        _setBasket(100_000_000, 0, block.timestamp);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(
            juniorVault.claimableDepositRequest(requestId, ALICE),
            assets,
            "valid replacement tick must settle preserved work"
        );
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

        _setBasket(110_000_000, 0, boundary);
        router.settleLpEpoch(_emptyUpdateData());
        assertEq(juniorVault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
    }

    function test_AtomicSettlement_ComponentPublishTimeDivergenceRollsBack() public {
        IOrderRouterAdminHost.RouterConfig memory config = _routerConfig();
        config.orderExecutionStalenessLimit = 10;
        _setRouterConfig(config);

        _openMarkSensitivePosition();
        uint256 assets = 10_000e6;
        uint256 requestId = _requestJuniorDeposit(ALICE, assets);
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
        _warpToEpoch(depositId > redeemId ? depositId : redeemId);
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

        LpEpochRefundReenterer receiver = new LpEpochRefundReenterer(router, IHousePool(address(pool)));
        vm.deal(address(this), 2 ether);
        receiver.settle{value: 2 ether}(_emptyUpdateData());

        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertTrue(receiver.attempted(), "the final excess-fee refund must reach the caller");
        assertFalse(receiver.reentered(), "Router transient guard must reject refund reentry");
        assertEq(
            receiver.revertSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "refund callback must fail at the nonreentrant boundary"
        );
        assertTrue(receiver.directAttempted(), "refund callback must observe the settled HousePool state");
        assertFalse(receiver.directSettled(), "the already-consumed batch must not settle twice");
        assertEq(
            receiver.directRevertSelector(),
            IHousePool.HousePool__NoLpEpochProgress.selector,
            "direct callback proves the first settlement consumed all matured work"
        );
        assertEq(address(receiver).balance, 1 ether, "only excess ETH must be returned");
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

}

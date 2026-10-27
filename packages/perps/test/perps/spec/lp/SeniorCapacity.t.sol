// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {HousePoolSeniorCapacityLib} from "@plether/perps/libraries/HousePoolSeniorCapacityLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract SeniorCapacityTest is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600 + 7 days;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public override {
        super.setUp();
        // Start on Tuesday so successive 72-hour proposals mature on Friday and Monday.
        vm.warp(block.timestamp + 1 days);
        _refreshMark();
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _refreshMark() internal {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function _configureAndReconcile(
        uint256 maxExposureAssets,
        uint256 maxShareBps
    ) internal {
        _setSeniorCapacity(maxExposureAssets, maxShareBps);
        _refreshMark();
        vm.prank(address(seniorVault));
        pool.reconcile();
    }

    function _protectedSenior() internal view returns (uint256) {
        uint256 principal = pool.seniorPrincipal();
        uint256 highWaterMark = pool.seniorHighWaterMark();
        return principal > highWaterMark ? principal : highWaterMark;
    }

    function _requestSenior(
        address lp,
        uint256 assets
    ) internal returns (uint256 epochId) {
        settlementToken.mint(lp, assets);
        vm.startPrank(lp);
        settlementToken.approve(address(seniorVault), assets);
        epochId = seniorVault.requestDeposit(assets, lp);
        vm.stopPrank();
    }

    function _requestRedeem(
        TrancheVault vault,
        address lp,
        uint256 shares
    ) internal returns (uint256 epochId) {
        vm.prank(lp);
        epochId = vault.requestRedeem(shares, lp, lp);
    }

    function _settleAt(
        uint256 epochId
    ) internal returns (IHousePool.LpEpochSettlementResult memory result) {
        _warpToEpoch(epochId);
        _refreshMark();
        result = _settleLpEpochForTest();
    }

    function _warpToEpoch(
        uint256 epochId
    ) internal {
        uint256 activationTime = pool.lpEpochStart(epochId);
        if (block.timestamp < activationTime) {
            vm.warp(activationTime);
        }
    }

    /// @dev Exact-boundary cases neutralize carry because asynchronous epoch settlement reprices capacity over time.
    function _disableSeniorCoupon() internal {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMark();
        pool.finalizePoolConfig();
        vm.prank(address(seniorVault));
        pool.reconcile();
    }

    function _assertSeniorHooksReject(
        address caller
    ) internal {
        uint256 amount = pool.minTrancheDepositAssets();
        vm.startPrank(caller);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.reserveSeniorDeposit(amount);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.releaseSeniorDepositReservation(amount);
        vm.stopPrank();
    }

    function test_CapacityMathUsesRatioFloorAndReservationExactly() public pure {
        uint256 capacityWithoutReservation =
            HousePoolSeniorCapacityLib.depositCapacity(2, 2, 7, 0, type(uint256).max, 3333);
        uint256 capacityWithReservation =
            HousePoolSeniorCapacityLib.depositCapacity(2, 2, 7, 1, type(uint256).max, 3333);

        assertEq(capacityWithoutReservation, 1, "floor(7 * 3333 / 6667) leaves one unit above E=2");
        assertEq(capacityWithReservation, 0, "the one-unit reservation must consume the rounded headroom");
    }

    function test_CapacityMathHandlesNeutralZeroAndOverflowBranches() public pure {
        assertEq(
            HousePoolSeniorCapacityLib.depositCapacity(7, 9, 0, 4, 100, 10_000),
            87,
            "neutral share cap must leave only absolute headroom"
        );
        assertEq(
            HousePoolSeniorCapacityLib.depositCapacity(0, 0, type(uint256).max, 0, type(uint256).max, 9999),
            type(uint256).max,
            "overflowing ratio ceiling must saturate"
        );
        assertEq(
            HousePoolSeniorCapacityLib.depositCapacity(0, 0, type(uint256).max, 0, type(uint256).max, 0),
            0,
            "zero share cap must close senior admission"
        );
        assertEq(
            HousePoolSeniorCapacityLib.depositCapacity(0, 0, 0, 0, 100, 5000),
            0,
            "finite ratio must provide no senior headroom without junior capital"
        );
    }

    function test_JuniorWithdrawalMathRoundsRequiredBackingUp() public pure {
        assertEq(
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(5, 5, 12, 0, 3333),
            1,
            "ceil(5 * 6667 / 3333) must retain eleven junior units"
        );
        assertEq(
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(0, 0, 12, 0, 0),
            12,
            "zero share cap must not restrict junior when protected exposure is zero"
        );
        assertEq(
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(5, 5, 12, 1, 3333),
            0,
            "a one-unit commitment consumes the last withdrawal unit"
        );
        assertEq(
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(5, 5, 12, type(uint256).max, 3333),
            0,
            "overflowing committed exposure cannot reopen junior withdrawal capacity"
        );
    }

    function test_AbsoluteCap_ExactBoundarySucceedsAndNextDollarIsRejected() public {
        uint256 absoluteCap = 2000e6;
        _configureAndReconcile(absoluteCap, 9999);
        _disableSeniorCoupon();

        uint256 capacity = pool.getSeniorDepositCapacity();
        assertEq(capacity, absoluteCap - _protectedSenior());
        assertEq(seniorVault.maxDeposit(ALICE), 0, "maxDeposit is claim capacity before an async request settles");
        assertEq(seniorVault.maxRequestDeposit(ALICE), capacity);

        uint256 epochId = _requestSenior(ALICE, capacity);

        assertEq(pool.getSeniorDepositCapacity(), 0);
        settlementToken.mint(BOB, 1e6);
        vm.startPrank(BOB);
        settlementToken.approve(address(seniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(1e6, BOB);
        vm.stopPrank();

        IHousePool.LpEpochSettlementResult memory result = _settleAt(epochId);
        assertEq(result.seniorDepositAssets, capacity);
        uint256 claimableAssets = seniorVault.claimableDepositRequest(epochId, ALICE);
        vm.prank(ALICE);
        assertGt(seniorVault.claimDeposit(epochId, claimableAssets, ALICE, ALICE), 0);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_CouponDriftCannotRefundOrBlockExactCapacityCommitment() public {
        _configureAndReconcile(2000e6, 9999);
        uint256 reservedAssets = pool.getSeniorDepositCapacity();
        assertGt(reservedAssets, 0);
        uint256 epochId = _requestSenior(ALICE, reservedAssets);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits());

        vm.warp(block.timestamp + 1);
        assertFalse(pool.areSeniorDepositReservationsWithinLimits(), "one second of coupon exceeds an exact cap");
        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__SeniorDepositCommitted.selector);
        seniorVault.cancelPendingDeposit(epochId);

        _warpToEpoch(epochId);
        _refreshMark();
        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__SeniorDepositCommitted.selector);
        seniorVault.cancelPendingDeposit(epochId);

        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);
        assertEq(result.seniorDepositAssets, reservedAssets);
        assertEq(seniorVault.claimableDepositRequest(epochId, ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_RateChangeFreshnessCannotDisplaceFirmSeniorReservation() public {
        _fundJunior(BOB, 200_000e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.maxSeniorExposureAssets = 2000e6;
        config.maxSeniorShareBps = 9999;
        config.markStalenessLimit = 300;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();
        _refreshMark();
        vm.prank(address(seniorVault));
        pool.reconcile();

        _fundTrader(CAROL, 50_000e6);
        _refreshMark();
        _open(CAROL, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        uint256 reservedAssets = pool.getSeniorDepositCapacity();
        assertGt(reservedAssets, 0);
        uint256 epochId = _requestSenior(ALICE, reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), reservedAssets);

        config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        uint256 activationTime = pool.poolConfigActivationTime();
        uint256 markTime = activationTime - 120;
        vm.warp(markTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(markTime));
        vm.warp(activationTime);

        uint256 principalBefore = pool.seniorPrincipal();
        uint256 couponCheckpoint = pool.lastSeniorCouponCheckpointTime();
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();
        assertEq(pool.seniorRateBps(), 800);
        assertEq(pool.seniorPrincipal(), principalBefore);
        assertEq(pool.lastSeniorCouponCheckpointTime(), couponCheckpoint);
        assertEq(pool.reservedSeniorDepositAssets(), reservedAssets);
        assertEq(seniorVault.pendingDepositRequest(epochId, ALICE), reservedAssets);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(activationTime));
        pool.finalizePoolConfig();
        assertEq(pool.seniorRateBps(), 1600);
        assertEq(pool.reservedSeniorDepositAssets(), reservedAssets);
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());
        assertEq(pool.getSeniorDepositCapacity(), 0);

        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();
        assertEq(result.seniorDepositAssets, reservedAssets);
        assertEq(seniorVault.claimableDepositRequest(epochId, ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
    }

    function test_RatioCap_ExactBoundaryUsesJuniorCapital() public {
        _fundJunior(ALICE, 2000e6);
        _configureAndReconcile(10_000e6, 5000);
        _disableSeniorCoupon();

        uint256 protectedSeniorBefore = _protectedSenior();
        uint256 juniorBefore = pool.juniorPrincipal();
        uint256 capacity = pool.getSeniorDepositCapacity();
        assertEq(capacity, juniorBefore - protectedSeniorBefore, "50% cap should enforce senior <= junior");

        _fundSenior(BOB, capacity);

        uint256 protectedSeniorAfter = _protectedSenior();
        uint256 juniorAfter = pool.juniorPrincipal();
        assertEq(protectedSeniorAfter, juniorAfter, "exact admission should land on the 50% boundary");
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_ZeroShareClosesSeniorAndTenThousandBpsCannotBeGoverned() public {
        _setSeniorCapacity(2000e6, 0);

        assertEq(pool.maxSeniorShareBps(), 0);
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.maxDeposit(ALICE), 0);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.maxSeniorShareBps = 10_000;
        vm.expectRevert(IHousePool.HousePool__InvalidMaxSeniorShareBps.selector);
        pool.proposePoolConfig(config);
    }

    function test_UnboundedExposureSentinelCannotBeGoverned() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.maxSeniorExposureAssets = type(uint256).max;
        vm.expectRevert(IHousePool.HousePool__InvalidMaxSeniorExposure.selector);
        pool.proposePoolConfig(config);
    }

    function test_ConstructorSentinelsCannotActivateTrading() public {
        HousePool neutralPool =
            new HousePool(address(settlementToken), address(engine), address(new HousePoolRedemptionMathSidecar()));
        TrancheVault neutralSenior = new TrancheVault(
            IERC20(address(settlementToken)),
            address(neutralPool),
            true,
            "Neutral Senior LP",
            "neutralSeniorAssets",
            0,
            address(0)
        );
        TrancheVault neutralJunior = new TrancheVault(
            IERC20(address(settlementToken)),
            address(neutralPool),
            false,
            "Neutral Junior LP",
            "neutralJuniorAssets",
            0,
            address(0)
        );
        neutralPool.setSeniorVault(address(neutralSenior));
        neutralPool.setJuniorVault(address(neutralJunior));

        assertEq(neutralPool.maxSeniorExposureAssets(), type(uint256).max);
        assertEq(neutralPool.maxSeniorShareBps(), 10_000);

        settlementToken.mint(address(this), 2000e6);
        settlementToken.approve(address(neutralPool), 2000e6);
        neutralPool.initializeSeedPosition(false, 1000e6, address(this));
        neutralPool.initializeSeedPosition(true, 1000e6, address(this));

        vm.expectRevert(IHousePool.HousePool__SeniorCapacityNotConfigured.selector);
        neutralPool.activateTrading();
    }

    function test_CapUsesHighWaterMarkInsteadOfLowerPrincipal() public {
        _configureAndReconcile(1200e6, 9999);

        uint256 desiredAssets = 2800e6;
        settlementToken.mint(address(pool), desiredAssets - pool.totalAssets());
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(800e6));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(uint256(2000e6));
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(uint256(1000e6));
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);

        assertEq(pool.getSeniorDepositCapacity(), 200e6, "capacity must subtract protected HWM exposure");
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0, "impaired senior remains closed despite residual capacity");
    }

    function test_ReservationConsumesCapacityAndOnlySettlementHoldPermitsHealthyRefund() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 initialCapacity = pool.getSeniorDepositCapacity();
        uint256 reservedAssets = 50e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        assertEq(pool.reservedSeniorDepositAssets(), reservedAssets);
        assertEq(pool.getSeniorDepositCapacity(), initialCapacity - reservedAssets);
        uint256 directCapacity = seniorVault.maxRequestDeposit(BOB);

        settlementToken.mint(BOB, directCapacity + 1);
        vm.startPrank(BOB);
        settlementToken.approve(address(seniorVault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrancheVault.TrancheVault__ExceededMaxRequestDeposit.selector, BOB, directCapacity + 1, directCapacity
            )
        );
        seniorVault.requestDeposit(directCapacity + 1, BOB);
        vm.stopPrank();

        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__SeniorDepositCommitted.selector);
        seniorVault.cancelPendingDeposit(epochId);
        assertEq(pool.reservedSeniorDepositAssets(), reservedAssets);

        pool.pauseLpEpochSettlement();
        assertEq(seniorVault.maxRequestDeposit(BOB), 0, "held settlement must close new Senior admission");
        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(epochId), reservedAssets);
        assertEq(settlementToken.balanceOf(ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertEq(pool.getSeniorDepositCapacity(), initialCapacity);
    }

    function test_OversizedSeniorRequestUsesDedicatedMaxRequestError() public {
        _configureAndReconcile(1200e6, 9999);
        uint256 capacity = seniorVault.maxRequestDeposit(ALICE);
        uint256 requestedAssets = capacity + 1;

        settlementToken.mint(ALICE, requestedAssets);
        vm.startPrank(ALICE);
        settlementToken.approve(address(seniorVault), requestedAssets);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrancheVault.TrancheVault__ExceededMaxRequestDeposit.selector, ALICE, requestedAssets, capacity
            )
        );
        seniorVault.requestDeposit(requestedAssets, ALICE);
        vm.stopPrank();
    }

    function test_SeniorPoolHooksRejectEoaAndJuniorVault() public {
        _assertSeniorHooksReject(ALICE);
        _assertSeniorHooksReject(address(juniorVault));
    }

    function test_AggregateReservationsTrackPartialCancellationFinalizationAndClaims() public {
        _configureAndReconcile(1500e6, 9999);
        uint256 aliceAssets = 20e6;
        uint256 bobAssets = 30e6;
        uint256 carolAssets = 50e6;
        uint256 epochId = _requestSenior(ALICE, aliceAssets);
        assertEq(_requestSenior(BOB, bobAssets), epochId);
        assertEq(_requestSenior(CAROL, carolAssets), epochId);

        assertEq(pool.reservedSeniorDepositAssets(), aliceAssets + bobAssets + carolAssets);
        (uint256 epochAssets,,,,) = seniorVault.depositEpochs(epochId);
        assertEq(epochAssets, aliceAssets + bobAssets + carolAssets);

        pool.pauseLpEpochSettlement();
        vm.prank(ALICE);
        seniorVault.cancelPendingDeposit(epochId);
        pool.unpauseLpEpochSettlement();
        assertEq(pool.reservedSeniorDepositAssets(), bobAssets + carolAssets);
        (epochAssets,,,,) = seniorVault.depositEpochs(epochId);
        assertEq(epochAssets, bobAssets + carolAssets);

        IHousePool.LpEpochSettlementResult memory result = _settleAt(epochId);
        assertEq(result.seniorDepositAssets, bobAssets + carolAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);

        vm.prank(BOB);
        seniorVault.claimDepositShares(epochId);
        assertEq(pool.reservedSeniorDepositAssets(), 0, "claim must not release reservation twice");
        vm.prank(CAROL);
        seniorVault.claimDepositShares(epochId);
        assertEq(pool.reservedSeniorDepositAssets(), 0, "last claim must not change reservation accounting");
    }

    function test_DoubleCancellationCannotReleaseReservationTwice() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 epochId = _requestSenior(ALICE, 10e6);

        pool.pauseLpEpochSettlement();
        vm.startPrank(ALICE);
        seniorVault.cancelPendingDeposit(epochId);
        vm.expectRevert(TrancheVault.TrancheVault__NoPendingDeposit.selector);
        seniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();

        assertEq(pool.reservedSeniorDepositAssets(), 0);

        vm.startPrank(address(seniorVault));
        vm.expectRevert(IHousePool.HousePool__InsufficientSeniorDepositReservation.selector);
        pool.releaseSeniorDepositReservation(1);
        vm.stopPrank();
    }

    function test_CompetingRequestCannotStealCapacityAndSharedSettlementSucceeds() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 reservedAssets = 50e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        uint256 directCapacity = pool.getSeniorDepositCapacity();
        _fundSenior(BOB, directCapacity - 2e6);

        (uint256 epochAssets, uint256 finalizedShares,,, bool finalized) = seniorVault.depositEpochs(epochId);

        assertGt(finalizedShares, 0);
        assertEq(epochAssets, reservedAssets + directCapacity - 2e6);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertTrue(finalized);
    }

    function test_GovernanceDecreaseClosesNewAdmissionButHonorsExistingReservation() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 reservedAssets = 100e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        _setSeniorCapacity(1050e6, 9999);
        assertGe(block.timestamp, seniorVault.depositEpochStart(epochId));
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());

        assertEq(pool.getSeniorDepositCapacity(), 0);
        vm.prank(ALICE);
        vm.expectRevert(TrancheVault.TrancheVault__SeniorDepositCommitted.selector);
        seniorVault.cancelPendingDeposit(epochId);

        _refreshMark();
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);
        assertEq(result.seniorDepositAssets, reservedAssets);
        assertEq(seniorVault.claimableDepositRequest(epochId, ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertGt(_protectedSenior(), pool.maxSeniorExposureAssets());
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_GovernanceShareReductionCannotVetoAcceptedReservation() public {
        _configureAndReconcile(10_000e6, 6000);
        uint256 epochId = _requestSenior(ALICE, 100e6);

        _setSeniorCapacity(10_000e6, 5000);
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());

        _refreshMark();
        IHousePool.LpEpochSettlementResult memory result = pool.settleLpEpoch(0, 0);
        assertEq(result.seniorDepositAssets, 100e6);

        (, uint256 finalizedShares,,, bool finalized) = seniorVault.depositEpochs(epochId);
        assertTrue(finalized, "request-time admission must survive a later governance cap cut");
        assertGt(finalizedShares, 0);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_LossAndHighWaterMarkInvalidateReservationAndAllowCancellation() public {
        _configureAndReconcile(3000e6, 7500);
        uint256 reservedAssets = 100e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        uint256 loss = pool.juniorPrincipal() + 50e6;
        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), loss);
        _refreshMark();
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertGt(pool.seniorHighWaterMark(), pool.seniorPrincipal());
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());

        _warpToEpoch(epochId);
        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);
        assertEq(seniorVault.pendingDepositRequest(epochId, ALICE), reservedAssets);

        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(epochId), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssets(), 0);
    }

    function test_JuniorWithdrawalPreservesBackingForPendingSeniorCommitment() public {
        _fundJunior(ALICE, 2000e6);
        _configureAndReconcile(10_000e6, 5000);
        uint256 juniorCapBeforeRequest = pool.getMaxJuniorWithdraw();
        uint256 seniorEpochId = _requestSenior(BOB, 500e6);

        uint256 aliceShares = juniorVault.balanceOf(ALICE);
        uint256 ownerAssets = juniorVault.estimateRedeemAssets(aliceShares);
        uint256 maxJuniorWithdraw = pool.getMaxJuniorWithdraw();
        assertGt(maxJuniorWithdraw, 0);
        assertLt(maxJuniorWithdraw, ownerAssets, "ratio covenant must retain backing for active and pending Senior");
        assertEq(juniorCapBeforeRequest - maxJuniorWithdraw, 500e6, "reservation must reduce Junior headroom");

        uint256 redeemEpochId = _requestRedeem(juniorVault, ALICE, aliceShares);
        IHousePool.LpEpochSettlementResult memory result = _settleAt(redeemEpochId);
        uint256 claimableShares = juniorVault.claimableRedeemRequest(redeemEpochId, ALICE);
        uint256 claimableAssets = juniorVault.claimableRedeemAssets(redeemEpochId, ALICE);
        assertGt(claimableShares, 0);
        assertGt(claimableAssets, 0);
        assertLe(result.juniorFundedAssets, maxJuniorWithdraw);

        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxRedeem.selector, ALICE, claimableShares + 1, claimableShares
            )
        );
        juniorVault.claimRedeem(redeemEpochId, claimableShares + 1, ALICE, ALICE);
        assertEq(juniorVault.claimRedeem(redeemEpochId, claimableShares, ALICE, ALICE), claimableAssets);
        vm.stopPrank();

        assertEq(result.seniorDepositAssets, 500e6, "Junior funding cannot displace committed Senior entry");
        assertEq(seniorVault.claimableDepositRequest(seniorEpochId, BOB), 500e6);
        assertLe(_protectedSenior(), pool.juniorPrincipal(), "committed 50% covenant must remain intact");
        assertEq(pool.reservedSeniorDepositAssets(), 0);
    }

    function test_JuniorWithdrawalRatioUsesHighWaterMarkWhenSeniorIsImpaired() public {
        _configureAndReconcile(10_000e6, 5000);
        _disableSeniorCoupon();

        _fundJunior(ALICE, 2000e6);

        uint256 desiredAssets = 2800e6;
        uint256 rawAssetsBefore = pool.rawAssets();
        if (rawAssetsBefore > desiredAssets) {
            settlementToken.burn(address(pool), rawAssetsBefore - desiredAssets);
        } else {
            settlementToken.mint(address(pool), desiredAssets - rawAssetsBefore);
        }
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(800e6));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(uint256(2000e6));
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(uint256(1000e6));
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);
        vm.warp(juniorVault.lastDepositTime(ALICE) + juniorVault.DEPOSIT_COOLDOWN());
        _refreshMark();

        assertEq(pool.getMaxJuniorWithdraw(), 1000e6, "ratio must retain junior backing for H rather than lower S");
        uint256 redeemEpochId = _requestRedeem(juniorVault, ALICE, juniorVault.balanceOf(ALICE));
        IHousePool.LpEpochSettlementResult memory result = _settleAt(redeemEpochId);
        assertLe(result.juniorFundedAssets, 1000e6);
        assertGe(result.juniorFundedAssets, 1000e6 - 1, "inverse budget math should reach the HWM boundary");

        uint256 claimableShares = juniorVault.claimableRedeemRequest(redeemEpochId, ALICE);
        vm.prank(ALICE);
        uint256 claimedAssets = juniorVault.claimRedeem(redeemEpochId, claimableShares, ALICE, ALICE);
        assertEq(claimedAssets, result.juniorFundedAssets);

        assertEq(pool.juniorPrincipal(), 2000e6 - result.juniorFundedAssets);
        assertEq(pool.seniorHighWaterMark(), 1000e6);
    }

    function test_ZeroShareJuniorWithdrawalIsClosedWhileSeniorExposureExists() public {
        _fundJunior(ALICE, 100e6);
        _setSeniorCapacity(10_000e6, 0);
        _refreshMark();

        assertGt(_protectedSenior(), 0);
        uint256 aliceShares = juniorVault.balanceOf(ALICE);
        uint256 redeemEpochId = _requestRedeem(juniorVault, ALICE, aliceShares);
        _warpToEpoch(redeemEpochId);
        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);

        assertEq(juniorVault.maxWithdraw(ALICE), 0);
        assertEq(juniorVault.claimableRedeemRequest(redeemEpochId, ALICE), 0);
        assertEq(juniorVault.pendingRedeemRequest(redeemEpochId, ALICE), aliceShares);
    }

    function test_PassiveCouponOverageDoesNotRevertAccountingAndClosesNewSeniorEntry() public {
        uint256 absoluteCap = 1050e6;
        _configureAndReconcile(absoluteCap, 9999);
        assertLt(_protectedSenior(), absoluteCap);

        vm.warp(block.timestamp + 365 days);
        _refreshMark();
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertGt(_protectedSenior(), absoluteCap, "coupon should passively move active exposure over the cap");
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0);
    }

    function test_LossOverageDoesNotBlockRevenueRestorationOrMintShares() public {
        _configureAndReconcile(2000e6, 6000);
        uint256 seniorSupplyBefore = seniorVault.totalSupply();
        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 highWaterMarkBefore = pool.seniorHighWaterMark();
        uint256 loss = pool.juniorPrincipal() + 100e6;

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), loss);
        _refreshMark();
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.seniorPrincipal(), seniorBefore - 100e6);
        assertEq(pool.seniorHighWaterMark(), highWaterMarkBefore);
        assertEq(pool.getSeniorDepositCapacity(), 0, "loss of junior backing must close admission");

        settlementToken.mint(address(pool), 50e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50e6, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(
            pool.seniorPrincipal(), seniorBefore - 50e6, "revenue must continue restoring impaired senior principal"
        );
        assertEq(pool.seniorHighWaterMark(), highWaterMarkBefore);
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.totalSupply(), seniorSupplyBefore, "revenue restoration must not mint senior shares");
    }

    function test_PrivilegedRecapitalizationMayRestoreAboveAbsoluteLimitWithoutMintingShares() public {
        _configureAndReconcile(1100e6, 9999);
        uint256 seniorSupplyBefore = seniorVault.totalSupply();

        settlementToken.burn(address(pool), pool.rawAssets());
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);

        settlementToken.mint(address(pool), 1200e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            1200e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 1200e6);
        assertEq(pool.seniorHighWaterMark(), 1200e6);
        assertGt(_protectedSenior(), pool.maxSeniorExposureAssets());
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.totalSupply(), seniorSupplyBefore, "recapitalization must not mint senior LP shares");
    }

    function test_GovernanceCanReduceCapBelowExistingExposureAndClosesNewEntry() public {
        _configureAndReconcile(2000e6, 9999);
        uint256 reducedCap = _protectedSenior() - 1e6;

        _setSeniorCapacity(reducedCap, 9999);

        assertEq(pool.maxSeniorExposureAssets(), reducedCap);
        assertGt(_protectedSenior(), reducedCap);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_SubMinimumResidualSeniorCapacityReportsZero() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        config.maxSeniorExposureAssets = 10_000e6;
        config.maxSeniorShareBps = 9999;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMark();
        pool.finalizePoolConfig();
        vm.prank(address(seniorVault));
        pool.reconcile();

        uint256 protectedSenior = _protectedSenior();
        uint256 residualCapacity = pool.minTrancheDepositAssets() - 1;
        _setSeniorCapacity(protectedSenior + residualCapacity, 9999);
        _refreshMark();

        assertEq(pool.maxSeniorExposureAssets() - _protectedSenior(), residualCapacity);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits());
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0);
    }

    function test_MaxMintIsExactAtNormalCapacityBoundary() public {
        _configureAndReconcile(1200e6, 9999);
        _disableSeniorCoupon();
        uint256 capacity = pool.getSeniorDepositCapacity();
        uint256 estimatedShares = seniorVault.estimateDepositShares(capacity);
        uint256 quotedAssets = seniorVault.estimateMintAssets(estimatedShares);

        assertEq(seniorVault.maxMint(ALICE), 0, "maxMint is zero until an async request becomes claimable");
        assertGt(estimatedShares, 0);
        assertLe(quotedAssets, capacity);
        assertGt(seniorVault.estimateMintAssets(estimatedShares + 1), capacity);

        uint256 epochId = _requestSenior(ALICE, capacity);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0, "the accepted request reserves all new-entry capacity");
        assertEq(
            seniorVault.estimateDepositShares(capacity), estimatedShares, "reserved entry still has a valid estimate"
        );
        assertEq(publicLens.getLpRequestState(true, epochId, ALICE).pendingDepositSharesEstimate, estimatedShares);
        IHousePool.LpEpochSettlementResult memory result = _settleAt(epochId);
        assertEq(result.seniorDepositAssets, capacity);
        uint256 maxShares = seniorVault.maxMint(ALICE);
        assertEq(maxShares, seniorVault.claimableDepositShares(epochId, ALICE));

        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, ALICE, maxShares + 1, maxShares)
        );
        seniorVault.mint(maxShares + 1, ALICE);
        assertEq(seniorVault.mint(maxShares, ALICE), capacity);
        vm.stopPrank();
    }

    function test_FrozenAdmissionReportsZeroDespiteGrossSeniorCapacity() public {
        _configureAndReconcile(1200e6, 9999);
        _disableSeniorCoupon();
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));

        uint256 capacity = pool.getSeniorDepositCapacity();
        uint256 estimatedShares = seniorVault.estimateDepositShares(capacity);
        uint256 quotedAssets = seniorVault.estimateMintAssets(estimatedShares);

        assertGt(capacity, 0, "economic senior capacity remains available after the oracle reopens");
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0, "frozen-oracle admission must be closed");
        assertEq(seniorVault.maxDeposit(ALICE), 0, "claim limit remains zero before settlement");
        assertEq(seniorVault.maxMint(ALICE), 0, "no frozen-oracle request can become claimable");
        assertGt(estimatedShares, 0);
        assertLe(quotedAssets, capacity);
    }

    function test_FrozenDepositRejectsBeforeApplyingGrossSeniorCapacity() public {
        _configureAndReconcile(1200e6, 9999);
        vm.warp(SATURDAY_FROZEN);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));

        uint256 capacity = pool.getSeniorDepositCapacity();
        uint256 oversizedAssets = capacity + 1;
        assertGt(capacity, 0);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0);
        settlementToken.mint(ALICE, oversizedAssets);
        vm.startPrank(ALICE);
        settlementToken.approve(address(seniorVault), oversizedAssets);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(oversizedAssets, ALICE);
        vm.stopPrank();
    }

    function test_MaxMintReturnsZeroWhenCoarseSharesCannotMeetMinimum() public {
        _disableSeniorCoupon();
        uint256 adjustedShares = seniorVault.totalSupply() + 1000;
        uint256 targetSeniorPrincipal = (adjustedShares * 3) / 2 - 1;
        uint256 capacity = 1e6;
        _configureAndReconcile(targetSeniorPrincipal + capacity, 9999);

        uint256 juniorPrincipal = pool.juniorPrincipal();
        uint256 desiredAssets = targetSeniorPrincipal + juniorPrincipal;
        settlementToken.mint(address(pool), desiredAssets - pool.totalAssets());
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(targetSeniorPrincipal);
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(targetSeniorPrincipal);
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);

        uint256 rawCapacityShares = seniorVault.convertToShares(capacity);
        assertGt(rawCapacityShares, 0);
        assertLt(seniorVault.estimateMintAssets(rawCapacityShares), pool.minTrancheDepositAssets());
        assertGt(seniorVault.estimateMintAssets(rawCapacityShares + 1), capacity);
        assertEq(seniorVault.maxRequestDeposit(ALICE), capacity);
        assertEq(seniorVault.maxMint(ALICE), 0, "maxMint is a claim limit, not an admission quote");

        uint256 epochId = _requestSenior(ALICE, capacity);
        IHousePool.LpEpochSettlementResult memory result = _settleAt(epochId);
        assertEq(result.seniorDepositAssets, capacity, "asset-denominated async request remains executable");
        uint256 claimableAssets = seniorVault.claimableDepositRequest(epochId, ALICE);
        vm.prank(ALICE);
        assertGt(seniorVault.claimDeposit(epochId, claimableAssets, ALICE, ALICE), 0);
    }

}

contract SeniorCapacityBootstrapTest is BasePerpTest {

    address internal constant SEED_RECEIVER = address(0x5EED);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _autoActivateTrading() internal pure override returns (bool) {
        return false;
    }

    function _refreshMark() internal {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function _seedJunior(
        uint256 assets
    ) internal {
        settlementToken.mint(address(this), assets);
        settlementToken.approve(address(pool), assets);
        pool.initializeSeedPosition(false, assets, SEED_RECEIVER);
    }

    function test_ZeroShareDoesNotConstrainJuniorWithdrawalWithoutSeniorExposure() public {
        _seedJunior(1000e6);
        _setSeniorCapacity(10_000e6, 0);
        _refreshMark();

        assertEq(pool.seniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), 0);
        assertEq(pool.getMaxJuniorWithdraw(), pool.juniorPrincipal(), "p=0 must not constrain junior when E=0");
    }

    function test_SeniorSeedHonorsExactAbsoluteBoundary() public {
        _seedJunior(2000e6);
        _setSeniorCapacity(1000e6, 5000);

        settlementToken.mint(address(this), 1000e6);
        settlementToken.approve(address(pool), 1000e6);
        pool.initializeSeedPosition(true, 1000e6, SEED_RECEIVER);

        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_SeniorSeedAboveBoundaryReverts() public {
        _seedJunior(2000e6);
        _setSeniorCapacity(1000e6, 5000);

        settlementToken.mint(address(this), 1000e6 + 1);
        settlementToken.approve(address(pool), 1000e6 + 1);
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.initializeSeedPosition(true, 1000e6 + 1, SEED_RECEIVER);
    }

    function test_SeniorUnassignedAssignmentHonorsExactBoundary() public {
        uint256 assignmentAssets = 1000e6;
        settlementToken.mint(address(pool), assignmentAssets);
        pool.accountExcess();
        _refreshMark();
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.unassignedAssets(), assignmentAssets);

        _seedJunior(2000e6);
        _setSeniorCapacity(assignmentAssets, 5000);
        _refreshMark();
        pool.assignUnassignedAssets(true, SEED_RECEIVER);

        assertEq(pool.unassignedAssets(), 0);
        assertEq(pool.seniorPrincipal(), assignmentAssets);
        assertGt(seniorVault.balanceOf(SEED_RECEIVER), 0);
    }

    function test_SeniorUnassignedAssignmentAboveBoundaryReverts() public {
        uint256 assignmentAssets = 1000e6 + 1;
        settlementToken.mint(address(pool), assignmentAssets);
        pool.accountExcess();
        _refreshMark();
        vm.prank(address(juniorVault));
        pool.reconcile();

        _seedJunior(2000e6);
        _setSeniorCapacity(1000e6, 5000);
        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.assignUnassignedAssets(true, SEED_RECEIVER);
    }

    function test_ActivationRejectsSeededExposureThatGovernanceMadeNoncompliant() public {
        _seedJunior(2000e6);
        settlementToken.mint(address(this), 1000e6);
        settlementToken.approve(address(pool), 1000e6);
        pool.initializeSeedPosition(true, 1000e6, SEED_RECEIVER);

        _setSeniorCapacity(10_000e6, 3000);
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.activateTrading();
    }

    function test_SeniorSeedUsesPostReconcileJuniorPrincipalAfterPayout() public {
        _seedJunior(1000e6);
        _setSeniorCapacity(2000e6, 5000);

        vm.prank(address(engine));
        pool.payOut(address(0xDEAD), 900e6);
        _refreshMark();

        assertEq(pool.getSeniorDepositCapacity(), 100e6, "projected junior loss must reduce seed capacity");

        settlementToken.mint(address(this), 500e6);
        settlementToken.approve(address(pool), 500e6);
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.initializeSeedPosition(true, 500e6, SEED_RECEIVER);
    }

}

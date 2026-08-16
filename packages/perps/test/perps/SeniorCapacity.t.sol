// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {HousePoolSeniorCapacityLib} from "@plether/perps/libraries/HousePoolSeniorCapacityLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

contract SeniorCapacityPricingPoolMock {

    uint256 internal seniorPricingAssets;

    function setSeniorPricingAssets(
        uint256 assets
    ) external {
        seniorPricingAssets = assets;
    }

    function getPendingDepositTrancheState() external view returns (uint256, uint256) {
        return (seniorPricingAssets, 0);
    }

}

contract SeniorCapacityVaultMathHarness is TrancheVault {

    constructor(
        IERC20 usdc,
        address pool
    ) TrancheVault(usdc, pool, true, "Senior Capacity Math Harness", "scMath") {}

    function setShareSupply(
        uint256 shares
    ) external {
        _mint(address(this), shares);
    }

    function exposedMaxMintSharesForAssetCapacity(
        uint256 capacity,
        uint256 feeBps
    ) external view returns (uint256) {
        return _maxMintSharesForAssetCapacity(capacity, feeBps);
    }

    function exposedPreviewFrozenMintAssets(
        uint256 shares,
        uint256 feeBps
    ) external view returns (uint256) {
        return _previewFrozenMintAssets(shares, feeBps);
    }

}

contract SeniorCapacityTest is BasePerpTest {

    using stdStorage for StdStorage;

    uint256 internal constant SATURDAY_FROZEN = 1_710_021_600;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _refreshMark() internal {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function _configureAndReconcile(
        uint256 maxExposureUsdc,
        uint256 maxShareBps
    ) internal {
        _setSeniorCapacity(maxExposureUsdc, maxShareBps);
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
        usdc.mint(lp, assets);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), assets);
        epochId = seniorVault.requestDeposit(assets, lp);
        vm.stopPrank();
    }

    function _assertSeniorHooksReject(
        address caller
    ) internal {
        uint256 amount = pool.minTrancheDepositUsdc();
        vm.startPrank(caller);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.depositSenior(amount);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.reserveSeniorDeposit(amount);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.releaseSeniorDepositReservation(amount);
        vm.expectRevert(IHousePool.HousePool__NotSeniorVault.selector);
        pool.depositReservedSenior(amount);
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
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(5, 5, 12, 3333),
            1,
            "ceil(5 * 6667 / 3333) must retain eleven junior units"
        );
        assertEq(
            HousePoolSeniorCapacityLib.juniorWithdrawalRatioCap(0, 0, 12, 0),
            12,
            "zero share cap must not restrict junior when protected exposure is zero"
        );
    }

    function test_AbsoluteCap_ExactBoundarySucceedsAndNextDollarIsRejected() public {
        uint256 absoluteCap = 2000e6;
        _configureAndReconcile(absoluteCap, 9999);

        uint256 capacity = pool.getSeniorDepositCapacity();
        assertEq(capacity, absoluteCap - _protectedSenior());
        assertEq(seniorVault.maxDeposit(ALICE), capacity);
        assertEq(seniorVault.maxRequestDeposit(ALICE), capacity);

        usdc.mint(ALICE, capacity + 1e6);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(capacity, ALICE);

        assertEq(pool.getSeniorDepositCapacity(), 0);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, ALICE, 1e6, uint256(0)));
        seniorVault.deposit(1e6, ALICE);
        vm.stopPrank();
    }

    function test_RatioCap_ExactBoundaryUsesJuniorCapital() public {
        _fundJunior(ALICE, 2000e6);
        _configureAndReconcile(10_000e6, 5000);

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
        config.maxSeniorExposureUsdc = type(uint256).max;
        vm.expectRevert(IHousePool.HousePool__InvalidMaxSeniorExposure.selector);
        pool.proposePoolConfig(config);
    }

    function test_ConstructorSentinelsCannotActivateTrading() public {
        HousePool neutralPool = new HousePool(address(usdc), address(engine));
        TrancheVault neutralSenior = new TrancheVault(
            IERC20(address(usdc)), address(neutralPool), true, "Neutral Senior LP", "neutralSeniorUSDC"
        );
        TrancheVault neutralJunior = new TrancheVault(
            IERC20(address(usdc)), address(neutralPool), false, "Neutral Junior LP", "neutralJuniorUSDC"
        );
        neutralPool.setSeniorVault(address(neutralSenior));
        neutralPool.setJuniorVault(address(neutralJunior));

        assertEq(neutralPool.maxSeniorExposureUsdc(), type(uint256).max);
        assertEq(neutralPool.maxSeniorShareBps(), 10_000);

        usdc.mint(address(this), 2000e6);
        usdc.approve(address(neutralPool), 2000e6);
        neutralPool.initializeSeedPosition(false, 1000e6, address(this));
        neutralPool.initializeSeedPosition(true, 1000e6, address(this));

        vm.expectRevert(IHousePool.HousePool__SeniorCapacityNotConfigured.selector);
        neutralPool.activateTrading();
    }

    function test_CapUsesHighWaterMarkInsteadOfLowerPrincipal() public {
        _configureAndReconcile(1200e6, 9999);

        uint256 desiredAssets = 2800e6;
        usdc.mint(address(pool), desiredAssets - pool.totalAssets());
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(800e6));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(uint256(2000e6));
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(uint256(1000e6));
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);

        assertEq(pool.getSeniorDepositCapacity(), 200e6, "capacity must subtract protected HWM exposure");
        assertEq(seniorVault.maxDeposit(ALICE), 0, "impaired senior remains closed despite residual capacity");
    }

    function test_ReservationConsumesCapacityAndCancellationRestoresRefundAndCapacity() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 initialCapacity = pool.getSeniorDepositCapacity();
        uint256 reservedAssets = 50e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        assertEq(pool.reservedSeniorDepositAssetsUsdc(), reservedAssets);
        assertEq(pool.getSeniorDepositCapacity(), initialCapacity - reservedAssets);
        uint256 directCapacity = seniorVault.maxDeposit(BOB);

        usdc.mint(BOB, directCapacity + 1);
        vm.startPrank(BOB);
        usdc.approve(address(seniorVault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, BOB, directCapacity + 1, directCapacity)
        );
        seniorVault.deposit(directCapacity + 1, BOB);
        vm.stopPrank();

        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(epochId), reservedAssets);
        assertEq(usdc.balanceOf(ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
        assertEq(pool.getSeniorDepositCapacity(), initialCapacity);
    }

    function test_OversizedSeniorRequestUsesDedicatedMaxRequestError() public {
        _configureAndReconcile(1200e6, 9999);
        uint256 capacity = seniorVault.maxRequestDeposit(ALICE);
        uint256 requestedAssets = capacity + 1;

        usdc.mint(ALICE, requestedAssets);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), requestedAssets);
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

        assertEq(pool.reservedSeniorDepositAssetsUsdc(), aliceAssets + bobAssets + carolAssets);
        (uint256 epochAssets,,,,) = seniorVault.depositEpochs(epochId);
        assertEq(epochAssets, aliceAssets + bobAssets + carolAssets);

        vm.prank(ALICE);
        seniorVault.cancelPendingDeposit(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), bobAssets + carolAssets);
        (epochAssets,,,,) = seniorVault.depositEpochs(epochId);
        assertEq(epochAssets, bobAssets + carolAssets);

        vm.warp(seniorVault.depositEpochStart(epochId));
        _refreshMark();
        seniorVault.finalizeDepositEpoch(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);

        vm.prank(BOB);
        seniorVault.claimDepositShares(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0, "claim must not release reservation twice");
        vm.prank(CAROL);
        seniorVault.claimDepositShares(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0, "last claim must not change reservation accounting");
    }

    function test_DoubleCancellationCannotReleaseReservationTwice() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 epochId = _requestSenior(ALICE, 10e6);

        vm.startPrank(ALICE);
        seniorVault.cancelPendingDeposit(epochId);
        vm.expectRevert(TrancheVault.TrancheVault__NoPendingDeposit.selector);
        seniorVault.cancelPendingDeposit(epochId);
        vm.stopPrank();

        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);

        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        vm.startPrank(address(seniorVault));
        vm.expectRevert(IHousePool.HousePool__InsufficientSeniorDepositReservation.selector);
        pool.releaseSeniorDepositReservation(1);
        vm.expectRevert(IHousePool.HousePool__InsufficientSeniorDepositReservation.selector);
        pool.depositReservedSenior(minimumDeposit);
        vm.stopPrank();
    }

    function test_DirectDepositCannotStealCapacityFromReservationAndReservedFinalizationSucceeds() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 reservedAssets = 50e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        uint256 directCapacity = pool.getSeniorDepositCapacity();
        _fundSenior(BOB, directCapacity - 2e6);

        vm.warp(seniorVault.depositEpochStart(epochId));
        _refreshMark();
        uint256 finalizedShares = seniorVault.finalizeDepositEpoch(epochId);

        assertGt(finalizedShares, 0);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
        (,,,, bool finalized) = seniorVault.depositEpochs(epochId);
        assertTrue(finalized);
    }

    function test_GovernanceDecreaseInvalidatesReservationAndOpensActiveCancellation() public {
        _configureAndReconcile(1300e6, 9999);
        uint256 reservedAssets = 100e6;
        uint256 epochId = _requestSenior(ALICE, reservedAssets);

        _setSeniorCapacity(1050e6, 9999);
        assertGe(block.timestamp, seniorVault.depositEpochStart(epochId));
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());

        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__SeniorDepositReservationsExceedLimits.selector);
        seniorVault.finalizeDepositEpoch(epochId);

        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(epochId), reservedAssets);
        assertEq(usdc.balanceOf(ALICE), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits());
    }

    function test_JuniorDepositRestoresInvalidReservationAndAllowsFinalization() public {
        _configureAndReconcile(10_000e6, 6000);
        uint256 epochId = _requestSenior(ALICE, 100e6);

        _setSeniorCapacity(10_000e6, 5000);
        assertFalse(pool.areSeniorDepositReservationsWithinLimits());

        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__SeniorDepositReservationsExceedLimits.selector);
        seniorVault.finalizeDepositEpoch(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 100e6);

        _fundJunior(BOB, 200e6);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits());

        uint256 finalizedShares = seniorVault.finalizeDepositEpoch(epochId);
        assertGt(finalizedShares, 0);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
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

        vm.warp(seniorVault.depositEpochStart(epochId));
        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__SeniorImpaired.selector);
        seniorVault.finalizeDepositEpoch(epochId);

        vm.prank(ALICE);
        assertEq(seniorVault.cancelPendingDeposit(epochId), reservedAssets);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
    }

    function test_JuniorCanWithdrawToActiveRatioBoundaryAndInvalidateReservation() public {
        _fundJunior(ALICE, 2000e6);
        _configureAndReconcile(10_000e6, 5000);
        uint256 epochId = _requestSenior(BOB, 1000e6);

        uint256 ownerAssets = juniorVault.previewRedeem(juniorVault.balanceOf(ALICE));
        uint256 maxJuniorWithdraw = juniorVault.maxWithdraw(ALICE);
        assertGt(maxJuniorWithdraw, 0);
        assertLt(maxJuniorWithdraw, ownerAssets, "ratio covenant should retain junior subordination");

        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector, ALICE, maxJuniorWithdraw + 1, maxJuniorWithdraw
            )
        );
        juniorVault.withdraw(maxJuniorWithdraw + 1, ALICE, ALICE);
        juniorVault.withdraw(maxJuniorWithdraw, ALICE, ALICE);
        vm.stopPrank();

        assertLe(_protectedSenior(), pool.juniorPrincipal() + 1, "active 50% covenant must remain intact");
        assertFalse(
            pool.areSeniorDepositReservationsWithinLimits(),
            "provisional reservation may become invalid after a covenant-safe junior withdrawal"
        );

        vm.warp(seniorVault.depositEpochStart(epochId));
        _refreshMark();
        vm.expectRevert(IHousePool.HousePool__SeniorDepositReservationsExceedLimits.selector);
        seniorVault.finalizeDepositEpoch(epochId);

        vm.prank(BOB);
        seniorVault.cancelPendingDeposit(epochId);
        assertEq(pool.reservedSeniorDepositAssetsUsdc(), 0);
    }

    function test_JuniorWithdrawalRatioUsesHighWaterMarkWhenSeniorIsImpaired() public {
        _configureAndReconcile(10_000e6, 5000);

        uint256 desiredAssets = 2800e6;
        usdc.mint(address(pool), desiredAssets - pool.totalAssets());
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(uint256(800e6));
        stdstore.target(address(pool)).sig("juniorPrincipal()").checked_write(uint256(2000e6));
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(uint256(1000e6));
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);
        _refreshMark();

        assertEq(pool.getMaxJuniorWithdraw(), 1000e6, "ratio must retain junior backing for H rather than lower S");
        vm.startPrank(address(juniorVault));
        vm.expectRevert(IHousePool.HousePool__ExceedsMaxJuniorWithdraw.selector);
        pool.withdrawJunior(1000e6 + 1, BOB);
        pool.withdrawJunior(1000e6, BOB);
        vm.stopPrank();

        assertEq(pool.juniorPrincipal(), 1000e6);
        assertEq(pool.seniorHighWaterMark(), 1000e6);
    }

    function test_ZeroShareJuniorWithdrawalIsClosedWhileSeniorExposureExists() public {
        _fundJunior(ALICE, 100e6);
        _setSeniorCapacity(10_000e6, 0);
        _refreshMark();

        assertGt(_protectedSenior(), 0);
        assertEq(juniorVault.maxWithdraw(ALICE), 0, "p=0 must retain all junior capital while E>0");
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, ALICE, uint256(1e6), uint256(0))
        );
        juniorVault.withdraw(1e6, ALICE, ALICE);
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
        assertEq(seniorVault.maxDeposit(ALICE), 0);
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

        usdc.mint(address(pool), 50e6);
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

        usdc.burn(address(pool), pool.rawAssets());
        vm.prank(address(seniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), 0);

        usdc.mint(address(pool), 1200e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            1200e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(seniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 1200e6);
        assertEq(pool.seniorHighWaterMark(), 1200e6);
        assertGt(_protectedSenior(), pool.maxSeniorExposureUsdc());
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.totalSupply(), seniorSupplyBefore, "recapitalization must not mint senior LP shares");
    }

    function test_GovernanceCanReduceCapBelowExistingExposureAndClosesNewEntry() public {
        _configureAndReconcile(2000e6, 9999);
        uint256 reducedCap = _protectedSenior() - 1e6;

        _setSeniorCapacity(reducedCap, 9999);

        assertEq(pool.maxSeniorExposureUsdc(), reducedCap);
        assertGt(_protectedSenior(), reducedCap);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_SubMinimumResidualSeniorCapacityReportsZero() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        config.maxSeniorExposureUsdc = 10_000e6;
        config.maxSeniorShareBps = 9999;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        _refreshMark();
        pool.finalizePoolConfig();
        vm.prank(address(seniorVault));
        pool.reconcile();

        uint256 protectedSenior = _protectedSenior();
        uint256 residualCapacity = pool.minTrancheDepositUsdc() - 1;
        _setSeniorCapacity(protectedSenior + residualCapacity, 9999);
        _refreshMark();

        assertEq(pool.maxSeniorExposureUsdc() - _protectedSenior(), residualCapacity);
        assertTrue(pool.areSeniorDepositReservationsWithinLimits());
        assertEq(pool.getSeniorDepositCapacity(), 0);
        assertEq(seniorVault.maxRequestDeposit(ALICE), 0);
    }

    function test_MaxMintIsExactAtNormalCapacityBoundary() public {
        _configureAndReconcile(1200e6, 9999);
        uint256 capacity = pool.getSeniorDepositCapacity();
        uint256 maxShares = seniorVault.maxMint(ALICE);
        uint256 quotedAssets = seniorVault.previewMint(maxShares);

        assertGt(maxShares, 0);
        assertLe(quotedAssets, capacity);
        assertGt(seniorVault.previewMint(maxShares + 1), capacity);

        usdc.mint(ALICE, quotedAssets);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), quotedAssets);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, ALICE, maxShares + 1, maxShares)
        );
        seniorVault.mint(maxShares + 1, ALICE);
        assertEq(seniorVault.mint(maxShares, ALICE), quotedAssets);
        vm.stopPrank();
    }

    function test_MaxMintIsExactAtFrozenGrossCapacityBoundary() public {
        _configureAndReconcile(1200e6, 9999);
        vm.warp(SATURDAY_FROZEN);
        assertTrue(engine.isOracleFrozen());
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));

        uint256 capacity = pool.getSeniorDepositCapacity();
        uint256 maxShares = seniorVault.maxMint(ALICE);
        uint256 quotedAssets = seniorVault.previewMint(maxShares);

        assertEq(seniorVault.maxDeposit(ALICE), capacity, "frozen maxDeposit should expose gross capacity");
        assertGt(maxShares, 0);
        assertLe(quotedAssets, capacity);
        assertGt(seniorVault.previewMint(maxShares + 1), capacity);

        usdc.mint(ALICE, quotedAssets);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), quotedAssets);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, ALICE, maxShares + 1, maxShares)
        );
        seniorVault.mint(maxShares + 1, ALICE);
        assertEq(seniorVault.mint(maxShares, ALICE), quotedAssets);
        vm.stopPrank();
    }

    function test_FrozenDepositRejectsGrossAssetsAboveSeniorCapacity() public {
        _configureAndReconcile(1200e6, 9999);
        vm.warp(SATURDAY_FROZEN);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_FROZEN - 3 hours));

        uint256 capacity = seniorVault.maxDeposit(ALICE);
        uint256 oversizedAssets = capacity + 1;
        usdc.mint(ALICE, oversizedAssets);
        vm.startPrank(ALICE);
        usdc.approve(address(seniorVault), oversizedAssets);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, ALICE, oversizedAssets, capacity)
        );
        seniorVault.deposit(oversizedAssets, ALICE);
        vm.stopPrank();
    }

    function test_WideFrozenMaxMintFallbackPreservesExactBoundary() public {
        SeniorCapacityPricingPoolMock pricingPool = new SeniorCapacityPricingPoolMock();
        SeniorCapacityVaultMathHarness vault =
            new SeniorCapacityVaultMathHarness(IERC20(address(usdc)), address(pricingPool));

        uint256 adjustedAssets = type(uint256).max / 9000 + 1;
        pricingPool.setSeniorPricingAssets(adjustedAssets - 1);
        vault.setShareSupply(adjustedAssets - 1000);

        assertGt(adjustedAssets, type(uint256).max / 10_000, "scaled denominator must require wide math");
        assertGt(adjustedAssets, type(uint256).max / 9975, "scaled preview must require wide math");

        uint256 capacity = 2e6;
        uint256 maxShares = vault.exposedMaxMintSharesForAssetCapacity(capacity, 25);
        assertEq(maxShares, 1_994_999);
        assertEq(vault.exposedPreviewFrozenMintAssets(maxShares, 25), capacity - 1);
        assertEq(vault.exposedPreviewFrozenMintAssets(maxShares + 1, 25), capacity + 1);
    }

    function test_MaxMintReturnsZeroWhenCoarseSharesCannotMeetMinimum() public {
        uint256 adjustedShares = seniorVault.totalSupply() + 1000;
        uint256 targetSeniorPrincipal = (adjustedShares * 3) / 2 - 1;
        uint256 capacity = 1e6;
        _configureAndReconcile(targetSeniorPrincipal + capacity, 9999);

        uint256 juniorPrincipal = pool.juniorPrincipal();
        uint256 desiredAssets = targetSeniorPrincipal + juniorPrincipal;
        usdc.mint(address(pool), desiredAssets - pool.totalAssets());
        stdstore.target(address(pool)).sig("seniorPrincipal()").checked_write(targetSeniorPrincipal);
        stdstore.target(address(pool)).sig("seniorHighWaterMark()").checked_write(targetSeniorPrincipal);
        stdstore.target(address(pool)).sig("accountedAssets()").checked_write(desiredAssets);

        uint256 rawCapacityShares = seniorVault.convertToShares(capacity);
        assertGt(rawCapacityShares, 0);
        assertLt(seniorVault.previewMint(rawCapacityShares), pool.minTrancheDepositUsdc());
        assertGt(seniorVault.previewMint(rawCapacityShares + 1), capacity);
        assertEq(seniorVault.maxDeposit(ALICE), capacity);
        assertEq(seniorVault.maxMint(ALICE), 0, "maxMint must not quote an unexecutable sub-minimum mint");
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
        usdc.mint(address(this), assets);
        usdc.approve(address(pool), assets);
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

        usdc.mint(address(this), 1000e6);
        usdc.approve(address(pool), 1000e6);
        pool.initializeSeedPosition(true, 1000e6, SEED_RECEIVER);

        assertEq(pool.seniorPrincipal(), 1000e6);
        assertEq(pool.getSeniorDepositCapacity(), 0);
    }

    function test_SeniorSeedAboveBoundaryReverts() public {
        _seedJunior(2000e6);
        _setSeniorCapacity(1000e6, 5000);

        usdc.mint(address(this), 1000e6 + 1);
        usdc.approve(address(pool), 1000e6 + 1);
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.initializeSeedPosition(true, 1000e6 + 1, SEED_RECEIVER);
    }

    function test_SeniorUnassignedAssignmentHonorsExactBoundary() public {
        uint256 assignmentAssets = 1000e6;
        usdc.mint(address(pool), assignmentAssets);
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
        usdc.mint(address(pool), assignmentAssets);
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
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(pool), 1000e6);
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

        usdc.mint(address(this), 500e6);
        usdc.approve(address(pool), 500e6);
        vm.expectRevert(IHousePool.HousePool__ExceedsSeniorDepositCapacity.selector);
        pool.initializeSeedPosition(true, 500e6, SEED_RECEIVER);
    }

}

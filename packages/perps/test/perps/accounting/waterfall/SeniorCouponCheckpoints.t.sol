// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/SECURITY.md#senior-coupon-model

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract StaleRateFinalizationTest is BasePerpTest {

    address seniorLp = address(0xA11CE);
    address juniorLp = address(0xB0B);

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FinalizeSeniorRate_StaleMarkMustNotApplyRateChange() public {
        address trader = address(0x3333);
        address traderAccount = trader;

        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 800, "Rejected stale finalization should leave the prior coupon rate in place");
    }

}

contract StaleLpSettlementCouponTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_StaleReconcileDoesNotCreateUnpaidDebt() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 800; // 8% annualized target coupon
        pool.proposePoolConfig(config);
        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        _fundTrader(address(0xBBB), 10_000 * 1e6);
        address traderAccount = address(0xBBB);
        _open(traderAccount, CfdTypes.Side.LONG, 50_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorBeforeStale = pool.seniorPrincipal();
        uint256 reconcileBeforeStale = pool.lastReconcileTime();

        // Make the mark stale while remaining before Friday's New York-time FAD shoulder.
        _warpForward(2 days);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfterStale = pool.seniorPrincipal();
        assertEq(
            pool.lastReconcileTime(), reconcileBeforeStale, "Stale reconcile should skip mark-dependent accounting"
        );
        assertGt(seniorAfterStale, seniorBeforeStale, "Coupon can checkpoint as a junior-funded NAV transfer");

        // Refresh mark
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();
    }

}

contract SeniorRedemptionHighWaterTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_SeniorCouponCreditsPrincipalAndRedemptionScalesHighWaterMark() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundSenior(bob, 500_000 * 1e6);
        _fundJunior(address(this), 2_000_000 * 1e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 800; // 8% annualized target coupon
        pool.proposePoolConfig(config);
        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        _warpForward(90 days);
        vm.prank(address(seniorVault));
        pool.reconcile();

        uint256 seniorPrincipalBefore = pool.seniorPrincipal();
        uint256 hwmBefore = pool.seniorHighWaterMark();
        assertGt(seniorPrincipalBefore, 1_000_000 * 1e6, "Coupon should be paid directly into senior principal");

        uint256 redeemShares = seniorVault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 requestId = seniorVault.requestRedeem(redeemShares, alice, alice);

        vm.warp(seniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        _settleLpEpochForTest();

        uint256 seniorPrincipalAfter = pool.seniorPrincipal();
        uint256 expectedHwm = (hwmBefore * seniorPrincipalAfter) / seniorPrincipalBefore;

        assertEq(pool.seniorHighWaterMark(), expectedHwm, "Senior HWM should scale with the withdrawn principal");

        uint256 claimableShares = seniorVault.claimableRedeemRequest(requestId, alice);
        vm.prank(alice);
        seniorVault.claimRedeem(requestId, claimableShares, alice, alice);
    }

}

contract StaleRateCheckpointTest is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);
    address trader = address(0x3333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FinalizedSeniorRateMustNotBackApplyAcrossStalePeriod() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 800, "Rejected stale finalization should leave the prior senior rate in place");
    }

}

contract StaleReconcileClockTest is BasePerpTest {

    address seniorLp = address(0x4444);
    address juniorLp = address(0x5555);
    address trader = address(0x6666);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_StaleReconcileMustPreserveClock() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 before = pool.lastReconcileTime();

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            pool.lastReconcileTime(),
            before,
            "Stale reconcile should preserve the clock so stale-window yield is not destroyed"
        );
    }

}

contract StaleConfigurationCouponTest is BasePerpTest {

    address seniorLp = address(0x1111);
    address juniorLp = address(0x2222);
    address trader = address(0x3333);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FinalizeSeniorRateMustNotEraseCouponCheckpointDuringStaleMarkPeriod() public {
        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);

        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        uint256 before = pool.lastReconcileTime();

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(
            pool.lastReconcileTime(), before, "Rejected stale finalization should leave the accrual clock untouched"
        );
    }

}

contract StaleSeniorMutationTest is BasePerpTest {

    address seniorLp = address(0x44441);
    address juniorLp = address(0x55551);
    address trader = address(0x66661);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_StaleSeniorMutationMustPreserveCouponValue() public {
        _fundSenior(seniorLp, 100_000e6);
        _fundJunior(juniorLp, 100_000e6);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 150_000e6);
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), 52_000e6, "Setup should impair senior before stale recapitalization");

        _fundTrader(trader, 50_000e6);
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8);

        uint256 staleStart = block.timestamp;
        uint256 staleMutationTime = staleStart + 30 days;
        vm.warp(staleMutationTime);

        usdc.mint(address(pool), 50_000e6);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            50_000e6, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 freshTime = staleMutationTime + 2 days;
        vm.warp(freshTime);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTime));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorPrincipal(), 52_000e6, "Stale senior recapitalization should preserve senior coupon value");
    }

}

contract CarryAndMarginCheckpointCouponTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FreshReconcileIncludesCouponAccruedAcrossStaleInterval() public {
        _fundSenior(alice, 200_000 * 1e6);
        _fundJunior(bob, 200_000 * 1e6);

        address account = address(0x3333);
        _fundTrader(address(0x3333), 50_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        uint256 seniorBefore = pool.seniorPrincipal();

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorPrincipal(), seniorBefore, "Stale-mark downtime should checkpoint senior coupon value");
    }

}

contract FrozenCouponCheckpointTest is BasePerpTest {

    address alice = address(0xA11CE);

    function refreshMarkPrice() external {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FrozenWindowReconcile_DoesNotDestroySeniorCouponCheckpointing() public {
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1000;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        uint256 seniorBefore = pool.seniorPrincipal();

        // Capture the runtime timestamp after asynchronous setup has advanced the shared LP clock.
        uint256 baseTs = block.timestamp;

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(baseTs));

        // Warp past staleness limit, then reconcile repeatedly with stale mark.
        // Use absolute timestamps to avoid optimizer caching timestamp().
        uint256 staleStart = baseTs + 200;
        for (uint256 i = 0; i < 48; i++) {
            vm.warp(staleStart + i * 1 hours);
            vm.prank(address(juniorVault));
            pool.reconcile();
        }

        // Refresh mark at end of stale period
        uint256 freshTs = staleStart + 48 hours;
        vm.warp(freshTs);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(freshTs));

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfter = pool.seniorPrincipal();
        assertGe(seniorAfter, seniorBefore, "Frozen-window reconcile should not destroy senior coupon value");
    }

}

contract FrozenFreshnessCouponTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev Friday 2024-03-08 21:30 UTC — 30min before oracle freeze
    uint256 constant FRIDAY_BEFORE_FREEZE = 1_709_934_600;
    /// @dev Saturday 2024-03-09 12:00 UTC — mid-weekend
    uint256 constant SATURDAY_NOON = 1_709_985_600;
    /// @dev Monday 2024-03-11 06:00 UTC — markets reopen
    uint256 constant MONDAY_MORNING = 1_710_136_800;

    function refreshMarkPrice() external {
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
    }

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
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FrozenFreshMarkAdvancesReconcileClock() public {
        _fundSenior(address(this), 500_000e6);
        _fundJunior(address(this), 500_000e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1000; // 10% annualized target coupon
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        // Set fresh mark on Friday before freeze
        vm.warp(FRIDAY_BEFORE_FREEZE);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(FRIDAY_BEFORE_FREEZE));

        // Reconcile while mark is fresh — sets lastReconcileTime
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 lastReconcileFriday = pool.lastReconcileTime();

        // On frozen Saturday, the mark exceeds the live age limit but remains inside fadMaxStaleness.
        vm.warp(SATURDAY_NOON);

        // Reconciliation uses the frozen-mode age limit and advances lastReconcileTime.
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 lastReconcileSaturday = pool.lastReconcileTime();

        assertGt(lastReconcileSaturday, lastReconcileFriday, "Frozen-mode fresh reconciliation advances the clock");
    }

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_FrozenFreshMarkCheckpointsSeniorCoupon() public {
        _fundSenior(address(this), 500_000e6);
        _fundJunior(address(this), 500_000e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1000; // 10% annualized target coupon
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        pool.finalizePoolConfig();

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        // Fresh mark on Friday
        vm.warp(FRIDAY_BEFORE_FREEZE);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(FRIDAY_BEFORE_FREEZE));
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 seniorFriday = pool.seniorPrincipal();
        uint256 lastReconcileFriday = pool.lastReconcileTime();

        // On frozen Saturday the mark is about 14.5 hours old, within fadMaxStaleness.
        // Reconciliation shares that policy and checkpoints the coupon and waterfall.
        vm.warp(SATURDAY_NOON);
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 seniorSaturday = pool.seniorPrincipal();
        uint256 lastReconcileSaturday = pool.lastReconcileTime();

        assertGt(lastReconcileSaturday, lastReconcileFriday, "_reconcile must run during the FAD-fresh window");
        assertGt(seniorSaturday, seniorFriday, "senior coupon should checkpoint during the FAD-fresh window");
    }

}

contract ReservedSettlementBehaviorCouponTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev accounting; source: SECURITY.md#senior-coupon-model.
    function test_StaleReconcileMustNotAdvanceClock() public {
        _fundSenior(address(0x666), 200_000 * 1e6);
        _fundJunior(address(0x777), 200_000 * 1e6);
        _fundTrader(trader, 50_000 * 1e6);

        address account = trader;
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 10_000 * 1e6, 1e8);

        uint256 beforeTime = pool.lastReconcileTime();
        vm.warp(block.timestamp + 121);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.lastReconcileTime(), beforeTime, "Stale reconcile should preserve the accrual clock");
    }

}

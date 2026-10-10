// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Historical audit identifiers and test names are retained for traceability.
// The assertions below exercise current behavior; legacy names do not describe unfixed vulnerabilities.

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

// ═══════════════════════════════════════════════════════════════════
// C-01 regression: expired pre-weekend opens are cleaned up, allowing frozen-market closes.
// These fixtures cross the default order lifetime before execution; they do not prove
// that an unexpired close-only open is terminally failed.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_C01_FIFODeadlockTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    /// @dev Thursday 2024-03-07 12:00 UTC
    uint256 constant THURSDAY_NOON = 1_709_812_800;
    /// @dev Saturday 2024-03-09 12:00 UTC (oracle frozen)
    uint256 constant SATURDAY_NOON = 1_709_985_600;

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

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "sUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "jUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
        vm.deal(keeper, 10 ether);

        vm.warp(THURSDAY_NOON);
    }

    function test_C01_OpenOrderHardRevertsInsteadOfSoftFailing() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // The Thursday order has expired before Saturday, so pre-oracle cleanup drains it.
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        (bool ok,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        assertTrue(ok, "C-01: open orders must soft-fail during frozen weekend, not hard revert");
        assertEq(
            router.nextExecuteId(),
            0,
            "C-01: soft-failed frozen-weekend open should drain the queue to the zero sentinel"
        );
    }

    function test_C01_CloseOrderBlockedByOpenInFrozenQueue() public {
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        // Bob commits an OPEN order on Thursday (before FAD window)
        address bob = address(0xB0B);
        _fundTrader(bob, 50_000e6);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a CLOSE order → behind Bob (order 2)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        // Keeper clears expired order 1, then executes the fresh frozen-market close in order 2.
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(keeper, 2 ether);

        vm.prank(keeper);
        (bool ok1,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        vm.prank(keeper);
        (bool ok2,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(2), priceData)
        );

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "C-01: close order must not be blocked by open order in frozen queue");
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-03 regression: frozen-mode freshness is shared by reconciliation and withdrawal gates.
// A mark inside fadMaxStaleness permits weekend reconciliation and coupon checkpointing;
// FAD-only live-market shoulders still use the normal live limit.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_C03_AsymmetricStalenessTest is BasePerpTest {

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

    function test_C03_ReconcileEarlyReturnDoesNotAdvanceLastReconcileTime() public {
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

        assertGt(
            lastReconcileSaturday,
            lastReconcileFriday,
            "C-03: _reconcile must advance lastReconcileTime even on stale early return"
        );
    }

    function test_C03_ReconcileRunsDuringFADWhenMarkIsFreshEnough() public {
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

        assertGt(lastReconcileSaturday, lastReconcileFriday, "C-03: _reconcile must run during the FAD-fresh window");
        assertGt(seniorSaturday, seniorFriday, "C-03: senior coupon should checkpoint during the FAD-fresh window");
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-01 regression: execution bounties do not transfer ETH or USDC directly to keeper wallets.
// Bounty settlement uses internal clearinghouse balances, which these wallet-only assertions
// do not measure; they are not evidence that an expired ordinary order pays no bounty.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_H01_KeeperFeeTheftTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_H01_KeeperReceivesFullFeeOnExpiredOrder() public {
        // Set maxExecutionWindowSeconds so orders can expire
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxExecutionWindowSeconds: 60,
            orderExecutionStalenessLimit: router.pletherOracle().orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.pletherOracle().liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: router.pletherOracle().basketMaxConfidenceRatioBps(),
            orderSettlementWindow: router.pletherOracle().orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.pletherOracle().maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.pletherOracle().adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            positionProtectionTriggerBountyUsdc: router.positionProtectionTriggerBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        // Alice commits without ETH; the execution bounty is reserved from internal USDC.
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        // Warp past maxExecutionWindowSeconds — order expires
        _warpForward(61);

        // Keeper terminally cleans the expired order without an ETH payment.
        vm.deal(keeper, 0);
        vm.prank(keeper);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        assertEq(keeper.balance, 0, "H-01: keeper should not be paid for failed order execution");
        assertEq(alice.balance, 1 ether, "H-01: failed-order execution should not route any ETH refund to the user");
    }

    function test_H01_FinalizeExecutionSuccessParamIsDeadCode() public {
        // Check that neither successful execution nor expiry sends USDC directly to the keeper wallet.
        // Internal bounty credits are outside this test's assertions.
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxExecutionWindowSeconds: 60,
            orderExecutionStalenessLimit: router.pletherOracle().orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.pletherOracle().liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: router.pletherOracle().basketMaxConfidenceRatioBps(),
            orderSettlementWindow: router.pletherOracle().orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.pletherOracle().maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.pletherOracle().adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            positionProtectionTriggerBountyUsdc: router.positionProtectionTriggerBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        _fundTrader(alice, 100_000e6);
        vm.deal(alice, 2 ether);

        // Order 1: will succeed (execute immediately)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);

        usdc.burn(keeper, usdc.balanceOf(keeper));
        vm.prank(keeper);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);
        uint256 keeperPayoutSuccess = usdc.balanceOf(keeper);

        // Order 2: will expire
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);

        _warpForward(61);
        bytes[] memory expiredData = _mockPythUpdateData();

        usdc.burn(keeper, usdc.balanceOf(keeper));
        vm.prank(keeper);
        router.executeOrder(2, expiredData);
        uint256 keeperPayoutFailed = usdc.balanceOf(keeper);

        assertEq(
            keeperPayoutSuccess, 0, "H-01: successful execution should not pay keeper via direct wallet USDC transfer"
        );
        assertEq(
            keeperPayoutFailed,
            0,
            "H-01: failed binding open execution should not pay keeper via direct wallet USDC transfer"
        );
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-02 regression: surviving shares at zero Junior NAV block ordinary deposit requests,
// preventing a small new deposit from taking over the wiped tranche.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_H02_JuniorWipeoutDilutionTest is BasePerpTest {

    address lp = address(0xB0B);
    address attacker = address(0xBAD);
    address trader = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
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

    function test_H02_OneDollarDepositCannotRecapWipedTranche() public {
        // Senior absorbs last-loss; junior absorbs first-loss.
        // With senior + junior, a trading loss that exceeds junior wipes it to exactly 0.
        _fundSenior(address(this), 10_000e6);
        _fundJunior(lp, 40_000e6);
        uint256 lpShares = juniorVault.balanceOf(lp);
        assertGt(lpShares, 0, "LP should have shares");

        // Trader opens a LONG with $50K maximum profit, exceeding Junior capital.
        _fundTrader(trader, 50_000e6);
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8);

        // LONG profits when oracle drops. Close at 0 for exact max payout.
        _close(traderAccount, CfdTypes.Side.LONG, 50_000e18, 0);

        // Reconcile: loss exceeds juniorPrincipal → junior wiped to exactly 0.
        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorPrincipalAfterWipe = pool.juniorPrincipal();
        uint256 totalSupplyAfterWipe = juniorVault.totalSupply();

        assertEq(juniorPrincipalAfterWipe, 0, "junior must be fully wiped");
        assertGt(totalSupplyAfterWipe, 0, "shares must survive the wipeout");

        // A new LP cannot recapitalize the wiped tranche through an ordinary deposit request.
        usdc.mint(attacker, 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1e6);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        juniorVault.requestDeposit(1e6, attacker);
        vm.stopPrank();
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-01 regression: a single-order call with insufficient gas reverts and preserves its order.
// The low-level call below checks failure and queue retention, not the precise internal
// gas remaining or the revert selector.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_M01_MissingGasFloorTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_M01_ExecuteOrderHasGasFloor() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        // Supply 450K gas, below the configured execution floor, and require rollback with queue retention.
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        (bool ok,) = address(router).call{gas: 450_000}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        assertFalse(ok, "M-01: executeOrder must revert when gas is below MIN_ENGINE_GAS");
        uint64 nextExec = router.nextExecuteId();
        assertEq(nextExec, 1, "M-01: order must survive the gas-floor revert");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-02: historical legacy-spread note retained as a non-test helper (obsolete_ prefix).
// The current carry model uses side indexes. This helper checks only that a mark update
// succeeds after time advances; it makes no assertion about carry realization.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_M02_CarryDesyncTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function obsolete_M02_UpdateMarkPriceDoesNotRealizeCarry() public {
        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        _open(aliceAccount, CfdTypes.Side.LONG, 200_000e18, 10_000e6, 1e8);

        // Warp forward 1 hour in the carry model
        _warpForward(3600);

        vm.prank(address(router));
        engine.updateMarkPrice(1.05e8, uint64(block.timestamp));

        assertEq(engine.lastMarkPrice(), 1.05e8, "mark update should still succeed in the carry model");
    }

}

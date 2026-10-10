// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Persistent waterfall reference campaign using real Engine, clearinghouse, pool, and tranche vaults.
/// @dev Router authorization and the recapitalization source are explicit test boundaries: orders are submitted as
///      the configured Router and recap cash is injected at the engine-only claimant-inflow API. This does not test
///      Router/Pyth admission or a public recapitalization transaction. Both tranches retain their seed owners;
///      no share issuance/redemption, open-position carry, VPI, deferred claims, or raw-cash shortage is modeled.
///      Trading rounds forward to Monday 10:00 UTC to keep frozen spread outside this waterfall-only model;
///      the additional elapsed time still accrues coupon in the independent reference.
///      The reference ledger advances only from initial funding and action inputs, never production previews or
///      post-operation balance deltas. Every successful action leaves economic state for the following action.
contract PerpWaterfallReferenceHandler is Test {

    MockUSDC public immutable usdc;
    CfdEngine public immutable engine;
    MarginClearinghouse public immutable clearinghouse;
    HousePool public immutable pool;
    address public immutable router;
    address public immutable juniorVault;
    address public constant TRADER = address(0xA119);

    uint256 public expectedSenior = 500_000e6;
    uint256 public expectedJunior = 100_000e6;
    uint256 public expectedHwm = 500_000e6;
    uint256 public expectedCash = 600_000e6;
    uint256 public expectedUnassigned;
    uint256 public expectedCheckpoint;
    uint256 public unexpectedReverts;
    uint256 public mismatches;
    uint256 public tradeAttempts;
    uint256 public completedTrades;
    uint256 public completedRecapitalizations;
    uint256 public completedCoupons;
    uint256 public juniorLosses;
    uint256 public seniorLosses;
    uint256 public seniorRestorations;
    uint256 public couponRatchets;
    uint256 public quarantinedRecapSurplus;

    constructor(
        MockUSDC usdc_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        address router_,
        address juniorVault_
    ) {
        usdc = usdc_;
        engine = engine_;
        clearinghouse = clearinghouse_;
        pool = pool_;
        router = router_;
        juniorVault = juniorVault_;
        expectedCheckpoint = block.timestamp;
        _compare();
    }

    function trade(
        bool traderProfit,
        uint256 lotsFuzz,
        uint256 moveFuzz
    ) external {
        tradeAttempts++;
        // Reserve unassigned assets and keep entry notional below the skew and endpoint-liability ceilings.
        uint256 maxLots = (expectedCash - expectedUnassigned) / (5 * 100e6);
        if (maxLots < 10) {
            return;
        }
        uint256 lots = bound(lotsFuzz, 10, maxLots > 10_000 ? 10_000 : maxLots);
        uint256 priceMove = bound(moveFuzz, 1, 50_000_000);
        uint256 monday = 1_709_532_000;
        uint256 elapsedWeeks = (block.timestamp - monday + 7 days - 1) / 7 days;
        vm.warp(monday + elapsedWeeks * 7 days);
        try this.executeRoundTrip(traderProfit, lots, priceMove) {
            uint256 pnl = lots * priceMove;
            expectedCash = traderProfit ? expectedCash - pnl : expectedCash + pnl;
            _reconcileReference();
            completedTrades++;
            _compare();
        } catch {
            unexpectedReverts++;
        }
    }

    /// @dev Self-call makes an unexpected failed close roll back its open and funding as one atomic action.
    function executeRoundTrip(
        bool traderProfit,
        uint256 lots,
        uint256 priceMove
    ) external {
        require(msg.sender == address(this), "handler only");
        uint256 margin = lots * 100e6;
        usdc.mint(TRADER, margin + 1000e6);
        vm.startPrank(TRADER);
        usdc.approve(address(clearinghouse), margin + 1000e6);
        clearinghouse.deposit(TRADER, margin + 1000e6);
        vm.stopPrank();

        CfdTypes.Order memory order = CfdTypes.Order({
            account: TRADER,
            sizeDelta: lots * 100e18,
            marginDelta: margin,
            targetPrice: 1e8,
            commitTime: uint64(block.timestamp),
            commitBlock: uint64(block.number),
            orderId: 0,
            side: CfdTypes.Side.LONG,
            isClose: false
        });
        vm.prank(router);
        engine.processOrderTyped(order, 1e8, expectedCash, uint64(block.timestamp));
        order.isClose = true;
        order.marginDelta = 0;
        order.targetPrice = 0;
        vm.prank(router);
        engine.processOrderTyped(
            order, traderProfit ? 1e8 - priceMove : 1e8 + priceMove, expectedCash, uint64(block.timestamp)
        );
        vm.prank(juniorVault);
        pool.reconcile();
    }

    function accrueCoupon(
        uint256 elapsedFuzz
    ) external {
        uint256 elapsed = bound(elapsedFuzz, 1, 7 days);
        vm.warp(block.timestamp + elapsed);
        try this.executeReconcile() {
            _reconcileReference();
            completedCoupons++;
            _compare();
        } catch {
            unexpectedReverts++;
        }
    }

    function executeReconcile() external {
        require(msg.sender == address(this), "handler only");
        vm.prank(juniorVault);
        pool.reconcile();
    }

    function recapitalize(
        uint256 amountFuzz
    ) external {
        uint256 amount = bound(amountFuzz, 1, 100_000e6);
        try this.executeRecapitalization(amount) {
            // Existing cash is reconciled first; the new recapitalization bucket is excluded from revenue.
            _reconcileReference();
            uint256 restored;
            if (expectedSenior + expectedJunior == 0) {
                // Seed shares survive a claimant wipe. An explicit recap then establishes a new Senior basis.
                restored = amount;
                expectedHwm = amount;
            } else {
                uint256 gap = expectedHwm - expectedSenior;
                restored = amount < gap ? amount : gap;
            }
            expectedSenior += restored;
            expectedUnassigned += amount - restored;
            expectedCash += amount;
            if (restored != 0) {
                seniorRestorations++;
            }
            if (amount > restored) {
                quarantinedRecapSurplus++;
            }
            completedRecapitalizations++;
            _compare();
        } catch {
            unexpectedReverts++;
        }
    }

    function executeRecapitalization(
        uint256 amount
    ) external {
        require(msg.sender == address(this), "handler only");
        usdc.mint(address(pool), amount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            amount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(juniorVault);
        pool.reconcile();
    }

    function _reconcileReference() private {
        uint256 coupon = expectedSenior * 800 * (block.timestamp - expectedCheckpoint) / (10_000 * 365 days);
        uint256 paid = coupon < expectedJunior ? coupon : expectedJunior;
        expectedSenior += paid;
        expectedJunior -= paid;
        if (expectedSenior > expectedHwm) {
            expectedHwm = expectedSenior;
            couponRatchets++;
        }
        expectedCheckpoint = block.timestamp;

        // Allocate the independently known cash by priority. Loss preserves Senior's last recognized principal;
        // revenue instead restores the unimpaired entitlement before any residual reaches Junior.
        if (expectedUnassigned > expectedCash) {
            expectedUnassigned = expectedCash;
        }
        uint256 distributable = expectedCash - expectedUnassigned;
        uint256 priorSenior = expectedSenior;
        uint256 priorJunior = expectedJunior;
        uint256 seniorTarget = distributable >= expectedSenior + expectedJunior ? expectedHwm : expectedSenior;
        expectedSenior = distributable < seniorTarget ? distributable : seniorTarget;
        expectedJunior = distributable - expectedSenior;
        if (expectedSenior < priorSenior) {
            seniorLosses++;
        }
        if (expectedSenior > priorSenior) {
            seniorRestorations++;
        }
        if (expectedJunior < priorJunior) {
            juniorLosses++;
        }
    }

    function _compare() private {
        if (
            pool.seniorPrincipal() != expectedSenior || pool.juniorPrincipal() != expectedJunior
                || pool.seniorHighWaterMark() != expectedHwm || pool.accountedAssets() != expectedCash
                || usdc.balanceOf(address(pool)) != expectedCash || pool.unassignedAssets() != expectedUnassigned
                || pool.lastSeniorCouponCheckpointTime() != expectedCheckpoint
                || pool.pendingRecapitalizationUsdc() != 0 || pool.pendingTradingRevenueUsdc() != 0
                || engine.totalTraderClaimBalanceUsdc() != 0
        ) {
            mismatches++;
        }
    }

}

contract PerpWaterfallReferenceInvariantTest is BasePerpTest {

    PerpWaterfallReferenceHandler internal handler;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 100_000e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();
        handler =
            new PerpWaterfallReferenceHandler(usdc, engine, clearinghouse, pool, address(router), address(juniorVault));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.accrueCoupon.selector;
        selectors[2] = handler.recapitalize.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_PersistentWaterfallMatchesIndependentCashLedger() public view {
        assertEq(handler.unexpectedReverts(), 0, "bounded modeled actions must execute");
        assertEq(handler.mismatches(), 0, "waterfall must match the independent input-derived ledger");
        assertEq(
            handler.expectedSenior() + handler.expectedJunior() + handler.expectedUnassigned(),
            handler.expectedCash(),
            "reference ownership must conserve physical pool cash"
        );
    }

    function test_Reachability_JuniorLossSeniorImpairmentRevenueRestorationAndCouponRatchet() public {
        handler.trade(true, 1200, 50_000_000);
        assertEq(pool.seniorPrincipal(), 500_000e6);
        assertEq(pool.juniorPrincipal(), 40_000e6);
        handler.trade(true, 1080, 50_000_000);
        assertEq(pool.seniorPrincipal(), 486_000e6);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.seniorHighWaterMark(), 500_000e6);

        handler.trade(false, 400, 50_000_000);
        assertEq(pool.seniorPrincipal(), 500_000e6);
        assertEq(pool.juniorPrincipal(), 6000e6);
        handler.accrueCoupon(7 days);
        assertGt(pool.seniorHighWaterMark(), 500_000e6);
        assertEq(pool.seniorPrincipal(), pool.seniorHighWaterMark());
        assertGt(handler.juniorLosses(), 0);
        assertGt(handler.seniorLosses(), 0);
        assertGt(handler.seniorRestorations(), 0);
        assertGt(handler.couponRatchets(), 0);
        assertEq(handler.completedTrades(), 3);
        invariant_PersistentWaterfallMatchesIndependentCashLedger();
    }

    function test_Reachability_RecapitalizationRestoresSeniorAndReservesSurplusBeforeNewRevenue() public {
        handler.trade(true, 1200, 50_000_000);
        handler.trade(true, 1080, 50_000_000);
        handler.recapitalize(20_000e6);
        assertEq(pool.seniorPrincipal(), 500_000e6);
        assertEq(pool.juniorPrincipal(), 0);
        assertEq(pool.unassignedAssets(), 6000e6);
        handler.trade(false, 500, 50_000_000);
        assertEq(pool.juniorPrincipal(), 25_000e6);
        assertEq(pool.unassignedAssets(), 6000e6, "recap surplus remains reserved through later trading revenue");
        assertEq(handler.completedRecapitalizations(), 1);
        assertEq(handler.quarantinedRecapSurplus(), 1);
        invariant_PersistentWaterfallMatchesIndependentCashLedger();
    }

    function test_Reachability_TradingAfterCouponTimeKeepsLiveCalendarScope() public {
        handler.accrueCoupon(5 days);
        handler.accrueCoupon(1 days);
        handler.trade(true, 500, 365);
        assertEq(block.timestamp, SETUP_TIMESTAMP + 7 days);
        assertEq(handler.expectedCash(), 600_000e6 - 500 * 365);
        assertEq(handler.completedTrades(), 1);
        invariant_PersistentWaterfallMatchesIndependentCashLedger();
    }

    function test_ReferenceOracleDetectsUnmodeledPoolCashPerturbation() public {
        // Negative control for the test oracle: an out-of-model cash atom must not be absorbed by ghost resync.
        usdc.mint(address(pool), 1);
        handler.accrueCoupon(1);
        assertEq(handler.expectedCash(), 600_000e6);
        assertEq(usdc.balanceOf(address(pool)), 600_000e6 + 1);
        assertEq(handler.mismatches(), 1);
        assertEq(handler.unexpectedReverts(), 0);
    }

}

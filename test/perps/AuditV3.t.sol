// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ═══════════════════════════════════════════════════════════════════
// C-01: OracleFrozen hard revert deadlocks the FIFO queue
//       over weekends. Liquidations use fadMaxStaleness but
//       close orders hit an unconditional revert.
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior", "sUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior", "jUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
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
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        uint64 execIdBefore = router.nextExecuteId();

        // executeOrder should soft-fail the open order (like batch does at line 416),
        // advancing the queue. Bug: hard reverts with OracleFrozen, queue stuck.
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        (bool ok,) = address(router).call{value: 0.01 ether}(
            abi.encodeWithSelector(router.executeOrder.selector, uint64(1), priceData)
        );

        uint64 execIdAfter = router.nextExecuteId();
        assertGt(execIdAfter, execIdBefore, "C-01: open orders must soft-fail during frozen weekend, not hard revert");
    }

    function test_C01_CloseOrderBlockedByOpenInFrozenQueue() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        // Bob commits an OPEN order on Thursday (before FAD window)
        address bob = address(0xB0B);
        _fundTrader(bob, 50_000e6);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8, false);

        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a CLOSE order → behind Bob (order 2)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        // Keeper processes both: order 1 soft-fails, order 2 closes Alice's position.
        // Bug: order 1 hard reverts, blocking order 2 entirely (FIFO deadlock).
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

        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "C-01: close order must not be blocked by open order in frozen queue");
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-03: Asymmetric staleness in HousePool
//       _requireFreshMark uses fadMaxStaleness during FAD,
//       _reconcile uses hardcoded markStalenessLimit.
//       The stale early return doesn't update lastReconcileTime,
//       so 48h of yield accrues retroactively on Monday.
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function test_C03_ReconcileEarlyReturnDoesNotAdvanceLastReconcileTime() public {
        _fundSenior(address(this), 500_000e6);
        _fundJunior(address(this), 500_000e6);

        pool.proposeSeniorRate(1000); // 10% APY
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeSeniorRate();

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        // Set fresh mark on Friday before freeze
        vm.warp(FRIDAY_BEFORE_FREEZE);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(FRIDAY_BEFORE_FREEZE));

        // Reconcile while mark is fresh — sets lastReconcileTime
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 lastReconcileFriday = pool.lastReconcileTime();

        // Warp to Saturday — mark is now stale (>120s)
        vm.warp(SATURDAY_NOON);

        // _reconcile should return early because mark is stale (using markStalenessLimit=120s).
        // Bug: lastReconcileTime is NOT updated on early return.
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

        pool.proposeSeniorRate(1000); // 10% APY
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeSeniorRate();

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        // Fresh mark on Friday
        vm.warp(FRIDAY_BEFORE_FREEZE);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(FRIDAY_BEFORE_FREEZE));
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 yieldFriday = pool.unpaidSeniorYield();

        // Saturday during FAD: mark is 14h old.
        // _requireFreshMark uses fadMaxStaleness (3 days) → fresh enough.
        // Bug: _reconcile uses markStalenessLimit (120s) → stale → early return, no yield.
        // Fix: _reconcile uses fadMaxStaleness during FAD → consistent, yield accrues.
        vm.warp(SATURDAY_NOON);
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 yieldSaturday = pool.unpaidSeniorYield();

        assertGt(
            yieldSaturday, yieldFriday, "C-03: _reconcile must accrue yield when mark is fresh enough for FAD window"
        );
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-01: Keepers get 100% of user's ETH fee on failed orders.
//       _finalizeExecution has dead `success` param — both branches
//       are byte-identical, sending everything to msg.sender.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_H01_KeeperFeeTheftTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_H01_KeeperReceivesFullFeeOnExpiredOrder() public {
        // Set maxOrderAge so orders can expire
        router.proposeMaxOrderAge(60);
        vm.warp(block.timestamp + 48 hours + 1);
        router.finalizeMaxOrderAge();

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        // Alice commits order with 0.01 ETH keeper fee
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        // Warp past maxOrderAge — order expires
        _warpForward(61);

        // Keeper executes the expired order — it fails softly (OrderFailed "Order expired")
        vm.deal(keeper, 0);
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(keeper.balance, 0, "H-01: keeper should not be paid for failed order execution");
        assertEq(alice.balance, 1 ether, "H-01: failed-order fee should be refunded to the user");
    }

    function test_H01_FinalizeExecutionSuccessParamIsDeadCode() public {
        // Demonstrate that both successful and failed processing pay the keeper
        // from the order's reserved USDC fee.
        router.proposeMaxOrderAge(60);
        vm.warp(block.timestamp + 48 hours + 1);
        router.finalizeMaxOrderAge();

        _fundTrader(alice, 100_000e6);
        vm.deal(alice, 2 ether);

        // Order 1: will succeed (execute immediately)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8, false);

        usdc.burn(keeper, usdc.balanceOf(keeper));
        vm.prank(keeper);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        uint256 keeperPayoutSuccess = usdc.balanceOf(keeper);

        // Order 2: will expire
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8, false);

        _warpForward(61);

        usdc.burn(keeper, usdc.balanceOf(keeper));
        vm.prank(keeper);
        router.executeOrder(2, empty);
        uint256 keeperPayoutFailed = usdc.balanceOf(keeper);

        assertEq(keeperPayoutSuccess, 1e6, "H-01: successful execution should pay the keeper in USDC");
        assertEq(
            keeperPayoutFailed, 1e6, "H-01: failed binding open execution should still pay the reserved keeper fee"
        );
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-02: Junior tranche ERC4626 wipeout hyper-dilution.
//       When _absorbLoss wipes juniorPrincipal to 0, shares survive.
//       A $1 deposit captures >99% ownership of the tranche.
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function test_H02_OneDollarDepositCanRecapWipedTranche() public {
        // Senior absorbs last-loss; junior absorbs first-loss.
        // With senior + junior, a trading loss that exceeds junior wipes it to exactly 0.
        _fundSenior(address(this), 10_000e6);
        _fundJunior(lp, 40_000e6);
        uint256 lpShares = juniorVault.balanceOf(lp);
        assertGt(lpShares, 0, "LP should have shares");

        // Trader opens a BULL position. Max profit = $50K = pool total.
        _fundTrader(trader, 50_000e6);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 50_000e18, 10_000e6, 1e8);

        // BULL profits when oracle drops. Close at 0 for exact max payout.
        _close(traderId, CfdTypes.Side.BULL, 50_000e18, 0);

        // Reconcile: loss exceeds juniorPrincipal → junior wiped to exactly 0.
        vm.prank(address(router));
        engine.updateMarkPrice(0, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 juniorPrincipalAfterWipe = pool.juniorPrincipal();
        uint256 totalSupplyAfterWipe = juniorVault.totalSupply();

        assertEq(juniorPrincipalAfterWipe, 0, "junior must be fully wiped");
        assertGt(totalSupplyAfterWipe, 0, "shares must survive the wipeout");

        // A new LP can recapitalize the wiped tranche.
        usdc.mint(attacker, 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1e6);
        juniorVault.deposit(1e6, attacker);
        vm.stopPrank();

        assertEq(pool.juniorPrincipal(), 1e6, "Recapitalization should restore junior principal from zero");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-01: executeOrder lacks the MIN_ENGINE_GAS check that
//       executeOrderBatch has (line 434). A malicious keeper can
//       supply gas below 500K, causing processOrder to OOG inside
//       try/catch. The catch silently cancels the user's valid order.
//
//       Exact gas calibration is fragile across compilers, so this
//       test verifies the prerequisite: executeOrder's try/catch
//       catches ALL reverts (including OOG), permanently deleting
//       the order. The gas guard is verified by code inspection:
//       - executeOrderBatch:434 — if (gasleft() < MIN_ENGINE_GAS) revert
//       - executeOrder — no equivalent check exists before line 303
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
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        // 450K gas: outer frame uses ~30K in mock mode, leaving ~420K at gas floor check.
        // Before fix: no gas floor, 420K is plenty for processOrder → order silently executed.
        // After fix: gas floor triggers (420K < 500K MIN_ENGINE_GAS) → clean revert, order preserved.
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
// M-02: updateMarkPrice doesn't call _updateFunding.
//       Funding indices desync from lastMarkPrice, causing the next
//       processOrder to compute funding over the wrong time×price.
// ═══════════════════════════════════════════════════════════════════

contract AuditV3_M02_FundingDesyncTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_M02_UpdateMarkPriceDoesNotAccrueFunding() public {
        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        uint64 fundingTimeBefore = engine.lastFundingTime();

        // Warp forward 1 hour — funding should accrue over this delta
        _warpForward(3600);

        // updateMarkPrice updates lastMarkPrice and lastMarkTime but NOT lastFundingTime.
        // The 1-hour funding delta is "forgotten" — it will be attributed to the NEXT
        // processOrder call at a potentially different price, distorting the indices.
        vm.prank(address(router));
        engine.updateMarkPrice(1.05e8, uint64(block.timestamp));

        uint64 fundingTimeAfter = engine.lastFundingTime();

        assertGt(
            fundingTimeAfter, fundingTimeBefore, "M-02: updateMarkPrice must accrue funding before updating the mark"
        );
    }

}

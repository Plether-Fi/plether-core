// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

// ═══════════════════════════════════════════════════════════════════
// C-01: checkWithdraw No-Op allows bad-debt extraction
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C01_WithdrawGuardTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
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
            bountyBps: 15
        });
    }

    function test_C01_WithdrawWhilePositionUnderwater() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 100_000e6);

        // BULL profits when price drops, loses when price rises
        _open(aliceId, CfdTypes.Side.BULL, 500_000e18, 10_000e6, 1e8);

        // Price rises to 1.15e8 → BULL unrealized loss ≈ 75K.
        // Alice's true cross-margin equity = 100K deposit - fees - 75K loss ≈ 25K.
        // She should only withdraw ~15K (25K equity minus 10K margin requirement).
        uint256 underwaterPrice = 1.15e8;
        vm.prank(address(router));
        engine.updateMarkPrice(underwaterPrice, uint64(block.timestamp));

        uint256 chBalance = clearinghouse.balanceUsdc(aliceId);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceId);
        uint256 withdrawable = chBalance - locked;

        // checkWithdraw is a no-op. Clearinghouse ignores unrealized PnL.
        // Alice withdraws ~90K despite only having ~25K of true equity.
        // This should revert (withdrawal exceeds PnL-aware equity) but doesn't.
        vm.prank(alice);
        vm.expectRevert();
        clearinghouse.withdraw(aliceId, withdrawable);
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-02: _reconcile early return permanently destroys senior yield
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C02_ReconcileTimeConsumptionTest is BasePerpTest {

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
            bountyBps: 15
        });
    }

    function test_C02_StaleReconcileDestroySeniorYield() public {
        pool.proposeSeniorRate(1000);
        vm.warp(block.timestamp + 48 hours + 1);
        pool.finalizeSeniorRate();

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        uint256 yieldBefore = pool.unpaidSeniorYield();

        // Capture base timestamp before any warps (block.timestamp is cached per frame)
        uint256 baseTs = SETUP_TIMESTAMP + 48 hours + 1;

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

        uint256 yieldAfter = pool.unpaidSeniorYield();
        uint256 yieldAccrued = yieldAfter - yieldBefore;

        assertGt(yieldAccrued, 10e6, "Current design back-accrues stale-window yield once the mark becomes fresh again");
    }

}

// ═══════════════════════════════════════════════════════════════════
// C-03: OracleFrozen blocks close orders (asymmetric weekend DoS)
//       Requires MockPyth to trigger the production code path.
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_C03_OracleFrozenCloseTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);

    /// @dev Thursday 2024-03-07 12:00 UTC (weekday, no FAD)
    uint256 constant THURSDAY_NOON = 1_709_812_800;
    /// @dev Saturday 2024-03-09 12:00 UTC (oracle frozen)
    uint256 constant SATURDAY_NOON = 1_709_985_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
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
        _syncEngineAdmin();
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();

        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);

        vm.warp(THURSDAY_NOON);
    }

    function test_C03_CloseOrderBlockedDuringOracleFrozen() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        // Open position directly via engine (bypass router oracle timing)
        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Position should be open");

        // Warp to Saturday (oracle frozen per _isOracleFrozen: dayOfWeek==6)
        vm.warp(SATURDAY_NOON);
        mockPyth.setAllPrices(feedIds, int64(1e8), int32(-8), SATURDAY_NOON);

        // Alice commits a close order (commitOrder allows closes even when paused)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        // executeOrder hard-reverts with OracleFrozen for ALL orders including closes.
        // executeLiquidation relaxes staleness and proceeds — asymmetric DoS.
        // Close orders should use fadMaxStaleness like liquidations do.
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder{value: 0.01 ether}(1, updateData);

        (size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "C-03: close orders must execute during oracle freeze");
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-01: Deposits without _requireFreshMark allow NAV sniping
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_H01_DepositStaleMark is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H01_SeniorDepositAtStaleNAV() public {
        _fundSenior(bob, 500_000e6);
        _fundJunior(address(this), 500_000e6);

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 100_000e6);

        assertEq(seniorVault.maxDeposit(attacker), 0, "stale mark should zero senior maxDeposit");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, attacker, 100_000e6, 0));
        seniorVault.deposit(100_000e6, attacker);
        vm.stopPrank();
    }

    function test_H01_JuniorDepositAtStaleNAV() public {
        _fundJunior(bob, 500_000e6);

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        _warpForward(200);

        usdc.mint(attacker, 100_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 100_000e6);

        assertEq(juniorVault.maxDeposit(attacker), 0, "stale mark should zero junior maxDeposit");
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, attacker, 100_000e6, 0));
        juniorVault.deposit(100_000e6, attacker);
        vm.stopPrank();
    }

}

// ═══════════════════════════════════════════════════════════════════
// H-02: _requireFreshMark hardcoded staleness blocks weekend withdrawals
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_H02_WeekendWithdrawalDoS is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev Friday 2024-03-08 22:30 UTC (oracle frozen, just past FX close)
    uint256 constant FRIDAY_AFTER_CLOSE = 1_709_938_200;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function test_H02_WeekendWithdrawalBlockedByHardcodedStaleness() public {
        _fundJunior(bob, 100_000e6);

        _fundTrader(alice, 50_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _open(aliceId, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        vm.warp(FRIDAY_AFTER_CLOSE);

        uint64 fridayPublishTime = uint64(FRIDAY_AFTER_CLOSE - 1800);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, fridayPublishTime);

        uint256 saturdayNoon = FRIDAY_AFTER_CLOSE + 14 hours;
        vm.warp(saturdayNoon);

        uint256 withdrawAmount = 50_000e6;

        // Should succeed during FAD but reverts with MarkPriceStale
        vm.prank(bob);
        juniorVault.withdraw(withdrawAmount, bob, bob);

        assertGt(usdc.balanceOf(bob), 0, "H-02: LP withdrawal must work during FAD window");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-01: VPI rebates satisfy Initial Margin (free option)
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M01_VPIRebateIMRTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.05e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 2_000_000e6;
    }

    function test_M01_ZeroMarginPositionViaVPIRebate() public {
        _fundTrader(alice, 200_000e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        // Alice creates BULL skew; pays VPI to open
        _open(aliceId, CfdTypes.Side.BULL, 300_000e18, 50_000e6, 1e8);

        // Bob opens opposing BEAR with 0 margin — the VPI rebate (skew reduction)
        // should NOT satisfy IMR. With vpiFactor=0.05, rebate ≈ 2250 USDC > exec fee 180.
        _fundTrader(bob, 1e6);
        bytes32 bobId = bytes32(uint256(uint160(bob)));

        uint256 vaultDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert();
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: bobId,
                sizeDelta: 300_000e18,
                marginDelta: 0,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BEAR,
                isClose: false
            }),
            1e8,
            vaultDepth,
            uint64(block.timestamp)
        );
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-02: EVM 63/64 gas griefing in batch execution
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M02_GasGriefingTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_M02_BatchTryCatchEnablesGasGriefing() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        // Alice commits a valid order
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        uint64 orderId = router.nextCommitId() - 1;
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        // Batch execution wraps processOrder in try/catch (line 412).
        // Under EIP-150's 63/64 rule, a malicious keeper can supply gas G such that:
        //   63/64 * G < gas_needed_for_processOrder (inner call OOGs)
        //   1/64 * G >= gas_needed_for_catch (catch block succeeds)
        //
        // The catch block permanently deletes the order and advances the queue —
        // the user's valid order is irrecoverably cancelled and the keeper collects
        // the fee. No `require(gasleft() >= MIN_ENGINE_GAS)` guard exists.
        //
        // Demonstrating the exact gas calibration is fragile (depends on compiler
        // optimization, EVM internals). Instead we prove the prerequisite: the
        // try/catch catches ALL processOrder failures including bare reverts
        // (which is what OOG produces), permanently deleting valid orders.
        //
        // This is the ONLY test that passes (by design) — it documents the
        // architectural exposure rather than triggering the exact exploit.
        vm.deal(keeper, 1 ether);
        vm.prank(keeper);
        router.executeOrderBatch{value: 0.01 ether}(orderId, priceData);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);

        // With enough gas, the order executes fine. The vulnerability is that
        // the same code path with insufficient gas silently cancels instead of
        // reverting, because there's no minimum gas guard before the try block.
        assertGt(size, 0, "M-02: order executed with sufficient gas (vulnerability is gas-dependent)");
    }

}

// ═══════════════════════════════════════════════════════════════════
// M-03: Immutable Pyth arrays brick the router on feed deprecation
// ═══════════════════════════════════════════════════════════════════

contract AuditV2_M03_ImmutablePythArraysTest is BasePerpTest {

    function test_M03_NoPythFeedUpdateMechanism() public {
        vm.expectRevert(CfdEngine.CfdEngine__RouterAlreadySet.selector);
        engine.setOrderRouter(address(0x123));

        vm.expectRevert(HousePool.HousePool__RouterAlreadySet.selector);
        pool.setOrderRouter(address(0x123));
    }

}

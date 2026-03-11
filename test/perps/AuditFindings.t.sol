// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// ============================================================
// C-01: Multiplicative HWM Scaling Inflates Phantom Debt
// ============================================================

contract AuditC01_HwmInflation is BasePerpTest {

    address alice = address(0x111);
    address attacker = address(0x666);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C01_DepositInflatesDeficit() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(alice, 50_000 * 1e6);

        assertEq(pool.seniorHighWaterMark(), 100_000 * 1e6);

        // Open a BEAR position. BEAR profits when oracle price rises.
        // 100k tokens at $1.00, max profit = 100k * ($2 - $1) = $100k
        // Vault has $150k, so solvency check passes.
        _fundTrader(address(0xAAA), 5000 * 1e6);
        bytes32 traderId = bytes32(uint256(uint160(address(0xAAA))));
        _open(traderId, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1e8);

        // Price rises to $1.80 → BEAR unrealized PnL = 100k * 0.8 = $80k
        // Reconcile: distributable ≈ cash - mtm, loss ≈ $80k
        // Junior absorbs $50k, senior absorbs $30k → senior = $70k, HWM = $100k
        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 hwmBefore = pool.seniorHighWaterMark();
        uint256 deficitBefore = hwmBefore - seniorBefore;
        assertGt(deficitBefore, 0, "Deficit must exist after crash");

        // Attacker deposits $1M into senior tranche
        _fundSenior(attacker, 1_000_000 * 1e6);

        uint256 hwmAfter = pool.seniorHighWaterMark();
        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 deficitAfter = hwmAfter > seniorAfter ? hwmAfter - seniorAfter : 0;

        // C-01 BUG: multiplicative scaling inflates the deficit.
        // Fresh deposit should add to both principal and HWM equally → deficit unchanged.
        // Instead: HWM = 100k * (70k + 1M) / 70k ≈ $1.53M. Deficit balloons from ~$30k to ~$460k.
        assertLe(deficitAfter, deficitBefore, "C-01: deposit must not inflate deficit");
    }

}

// ============================================================
// C-02: 100% Keeper Fee Refund Enables FIFO Queue Deadlock
// ============================================================

contract AuditC02_KeeperFeeRefund is BasePerpTest {

    address spammer = address(0x666);
    address keeper = address(0x777);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function setUp() public override {
        super.setUp();
        vm.deal(spammer, 10 ether);
        vm.deal(keeper, 10 ether);
    }

    function test_C02_FailedOrderRefunds100Percent() public {
        // Spammer commits with impossible slippage (targetPrice=1 for BULL open = always fails)
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1, false);

        uint256 spammerClaimableBefore = router.claimableEth(spammer);

        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder{value: 0}(1, empty);

        uint256 refund = router.claimableEth(spammer) - spammerClaimableBefore;

        // C-02 BUG: 100% refund. Keeper spent gas but earned nothing.
        assertLt(refund, 0.01 ether, "C-02: failed order must not refund 100% of keeper fee");
    }

}

// ============================================================
// C-03: Delta Margin Check Allows Under-Margined Positions
// ============================================================

contract AuditC03_MarginCheck is BasePerpTest {

    address alice = address(0x111);

    function test_C03_PostFeeMarginBelowImr() public {
        _fundTrader(alice, 100_000 * 1e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        // Open 200k BULL tokens at $1.00
        // Notional = 200k * 1e8 / 1e20 = $200,000
        // MMR = 1% * $200k = $2000, IMR = 1.5x = $3000
        // marginDelta = $3100 → passes IMR check ($3100 >= $3000)
        // execFee = 6bps * $200k = $120, tradeCost = $120 (vpiFactor=0)
        // pos.margin = $3100 - $120 = $2980 (BELOW the $3000 IMR!)
        _open(aliceId, CfdTypes.Side.BULL, 200_000 * 1e18, 3100 * 1e6, 1e8);

        (, uint256 posMargin,,,,,,) = engine.positions(aliceId);
        uint256 totalMmr = engine.getMaintenanceMarginUsdc(200_000 * 1e18, 1e8);
        uint256 totalImr = (totalMmr * 150) / 100;

        // C-03 BUG: The IMR check uses order.marginDelta ($3100) not pos.margin ($2980).
        // After exec fee deduction, the position is under-margined from inception.
        assertGe(posMargin, totalImr, "C-03: pos.margin after fees must meet IMR for total size");
    }

}

// ============================================================
// C-04: Stale Oracle Early Return Bypasses MTM
// ============================================================

contract AuditC04_StaleOracleMtmBypass is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C04_JuniorWithdrawsAtStaleNAV() public {
        _fundJunior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Open a position so staleness path triggers (bullMax+bearMax > 0)
        address trader = address(0xAAA);
        _fundTrader(trader, 50_000 * 1e6);
        bytes32 traderId = bytes32(uint256(uint160(trader)));
        _open(traderId, CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        // Crash: BULL loses when oracle rises
        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Make mark stale (120s limit)
        _warpForward(130);

        uint256 aliceMaxWithdraw = juniorVault.maxWithdraw(alice);
        if (aliceMaxWithdraw > 0) {
            _warpForward(1 hours); // pass cooldown

            // C-04 BUG: withdrawal succeeds during stale period.
            // _reconcile early-returns, skipping MTM. Alice escapes at pre-crash NAV.
            vm.prank(alice);
            vm.expectRevert();
            juniorVault.withdraw(aliceMaxWithdraw, alice, alice);
        }
    }

    function test_C04_YieldAccruesWithoutMtm() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        pool.proposeSeniorRate(800); // 8% APY
        _warpForward(48 hours + 1);
        pool.finalizeSeniorRate();

        _fundTrader(address(0xBBB), 10_000 * 1e6);
        bytes32 traderId = bytes32(uint256(uint160(address(0xBBB))));
        _open(traderId, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 yieldBefore = pool.unpaidSeniorYield();

        // Make mark stale, wait 3 days
        _warpForward(3 days);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 yieldAfterStale = pool.unpaidSeniorYield();

        // Refresh mark
        vm.prank(address(router));
        engine.updateMarkPrice(1e8);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // C-04 BUG: yield accrued during stale period (line 304 runs before staleness check
        // at line 310), but MTM distribution was skipped. This is a phantom liability.
        // Yield should NOT accrue when the mark is stale — if MTM can't be evaluated,
        // yield shouldn't be counted either. They must be atomic.
        assertEq(yieldAfterStale, yieldBefore, "C-04: yield must not accrue when mark is stale and MTM is skipped");
    }

}

// ============================================================
// C-05: Deposits Allowed When Senior Tranche Is Impaired
// ============================================================

contract AuditC05_ImpairedDeposit is BasePerpTest {

    address alice = address(0x111);
    address attacker = address(0x666);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C05_DepositAllowedWhenImpaired() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(address(this), 50_000 * 1e6);

        // Create a deficit: BEAR trader profits, wiping junior and dipping into senior
        _fundTrader(address(0xAAA), 5000 * 1e6);
        bytes32 traderId = bytes32(uint256(uint160(address(0xAAA))));
        _open(traderId, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorPrincipal = pool.seniorPrincipal();
        uint256 hwm = pool.seniorHighWaterMark();
        assertLt(seniorPrincipal, hwm, "Senior tranche is impaired");

        // C-05 BUG: attacker can deposit into an impaired tranche.
        // With multiplicative HWM scaling (C-01), this fabricates phantom debt.
        // Deposits should be blocked when seniorPrincipal < seniorHighWaterMark.
        usdc.mint(attacker, 1000 * 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 1000 * 1e6);
        vm.expectRevert();
        seniorVault.deposit(1000 * 1e6, attacker);
        vm.stopPrank();
    }

}

// ============================================================
// H-01: Pyth VAA Lookback Option via block.timestamp
// ============================================================

contract AuditH01_MarkTimeLookback is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function test_H01_UpdateMarkUsesBlockTimestamp() public {
        _fundTrader(address(0xAAA), 10_000 * 1e6);
        bytes32 traderId = bytes32(uint256(uint160(address(0xAAA))));
        _open(traderId, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8);

        _warpForward(50);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(0.8e8);
        router.updateMarkPrice(priceData);

        // H-01 BUG: lastMarkTime = block.timestamp (now), not the VAA's publish time.
        // In production, a 50-second-old VAA makes HousePool think mark is fresh.
        uint64 markTime = engine.lastMarkTime();
        assertEq(markTime, uint64(block.timestamp), "lastMarkTime uses block.timestamp, not VAA time");
    }

}

// ============================================================
// H-02: Overly Restrictive withdrawGuard
// ============================================================

contract AuditH02_WithdrawBlocked is BasePerpTest {

    address alice = address(0x111);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function test_H02_WithdrawBlockedWithAnyPosition() public {
        _fundTrader(alice, 100_000 * 1e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        // Open a small position: 50k tokens, $1000 margin (well above IMR)
        // Notional = $50k, IMR = max(1.5% * $50k, $5) = $750
        _open(aliceId, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0);

        uint256 balance = clearinghouse.balances(aliceId, address(usdc));
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceId);
        uint256 freeBalance = balance - locked;
        assertGt(freeBalance, 90_000 * 1e6, "Alice has ~$99k free but can't touch it");

        // H-02 BUG: Alice should be able to withdraw $1 from her $99k+ free balance.
        // Instead, checkWithdraw reverts for ANY size > 0, trapping all excess collateral.
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(aliceId, address(usdc), 1e6);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + 1e6, "H-02: should withdraw $1 of free equity");
    }

}

// ============================================================
// H-03: Partial Close Creates Unliquidatable Dust
// ============================================================

contract AuditH03_DustPosition is BasePerpTest {

    address alice = address(0x111);

    function test_H03_PartialCloseCreatesDustMargin() public {
        _fundTrader(alice, 50_000 * 1e6);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        // Open 50k tokens at $1.00: notional = $50k
        // IMR = max(1.5% * $50k, $5) = $750. Use $800 margin.
        // execFee = 6bps * $50k = $30. pos.margin = $800 - $30 = $770
        uint256 posSize = 50_000 * 1e18;
        _open(aliceId, CfdTypes.Side.BULL, posSize, 800 * 1e6, 1e8);

        (, uint256 marginBefore,,,,,,) = engine.positions(aliceId);

        // Close 99.5%: keep 250 tokens (0.5%)
        // marginToFree = $770 * 49750 / 50000 = $766.15
        // remaining margin = $770 - $766.15 = $3.85
        uint256 closeSize = (posSize * 995) / 1000;
        _close(aliceId, CfdTypes.Side.BULL, closeSize, 1e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,,) = engine.positions(aliceId);
        assertGt(sizeAfter, 0, "Dust position remains");

        // H-03 BUG: remaining margin ($3.85) is below minBountyUsdc ($5).
        // Keeper bounty = max(0.15% * notional, $5) = max($0.375, $5) = $5.
        // But bounty is capped at pos.margin = $3.85 < $5. No keeper will liquidate.
        (,,,,,,, uint256 minBountyUsdc,) = engine.riskParams();
        assertGe(marginAfter, minBountyUsdc, "H-03: remaining margin after partial close must cover min bounty");
    }

}

// ============================================================
// H-04: Unpaid Senior Yield Not Scaled on Withdrawal
// ============================================================

contract AuditH04_UnpaidYieldNotScaled is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H04_UnpaidYieldNotReduced() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundSenior(bob, 500_000 * 1e6);
        _fundJunior(address(this), 2_000_000 * 1e6);

        pool.proposeSeniorRate(800); // 8% APY
        _warpForward(48 hours + 1);
        pool.finalizeSeniorRate();

        _warpForward(90 days);
        vm.prank(address(seniorVault));
        pool.reconcile();

        uint256 unpaidBefore = pool.unpaidSeniorYield();
        assertGt(unpaidBefore, 0, "Yield should have accrued");

        uint256 seniorPrincipalBefore = pool.seniorPrincipal();

        uint256 withdrawAmount = seniorVault.maxWithdraw(alice) / 2;
        if (withdrawAmount == 0) {
            return;
        }

        _warpForward(1 hours);
        vm.prank(alice);
        seniorVault.withdraw(withdrawAmount, alice, alice);

        uint256 unpaidAfter = pool.unpaidSeniorYield();
        uint256 seniorPrincipalAfter = pool.seniorPrincipal();

        // H-04 BUG: unpaidSeniorYield unchanged after ~50% capital withdrawal.
        uint256 principalRatio = (seniorPrincipalAfter * 1e18) / seniorPrincipalBefore;
        uint256 expectedUnpaid = (unpaidBefore * principalRatio) / 1e18;

        assertLe(
            unpaidAfter,
            expectedUnpaid + (expectedUnpaid / 100),
            "H-04: unpaidSeniorYield must scale down proportionally on withdrawal"
        );
    }

}


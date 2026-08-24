// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngine} from "@plether/perps/interfaces/ICfdEngine.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

// ============================================================
// C-01: Multiplicative HWM Scaling Inflates Phantom Debt
// ============================================================

contract AuditC01_HwmInflation is BasePerpTest {

    address alice = address(0x111);
    address attacker = address(0x666);

    uint256 constant SEEDED_SENIOR = 1000e6;

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

    function test_C01_DepositInflatesDeficit() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(alice, 50_000 * 1e6);

        assertEq(
            pool.seniorHighWaterMark(),
            pool.seniorPrincipal(),
            "new senior principal and async-epoch coupon accrual must remain at the HWM"
        );
        assertGt(pool.seniorHighWaterMark(), SEEDED_SENIOR + 100_000 * 1e6);

        // Open a BEAR position. BEAR profits when oracle price rises.
        // 100k tokens at $1.00, max profit = 100k * ($2 - $1) = $100k
        // Pool has $150k, so solvency check passes.
        _fundTrader(address(0xAAA), 5000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1e8);

        // Price rises to $1.80 → BEAR unrealized PnL = 100k * 0.8 = $80k
        // Reconcile: distributable ≈ cash - mtm, loss ≈ $80k
        // Junior absorbs $50k, senior absorbs $30k → senior = $70k, HWM = $100k
        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLt(pool.seniorPrincipal(), pool.seniorHighWaterMark(), "Deficit must exist after crash");

        // C-01/C-05 FIX: deposit into impaired tranche is now blocked
        usdc.mint(attacker, 1_000_000 * 1e6);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), 1_000_000 * 1e6);
        assertEq(seniorVault.maxRequestDeposit(attacker), 0, "impaired senior should zero request capacity");
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(1_000_000 * 1e6, attacker);
        vm.stopPrank();
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
        _fundTrader(spammer, 10_000 * 1e6);

        // Spammer commits with impossible slippage (targetPrice=1 for BULL open = always fails)
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1, false);

        uint256 keeperBefore = keeper.balance;

        bytes[] memory empty = _mockPythUpdateData();
        vm.prank(keeper);
        router.executeOrder{value: 0}(1, empty);

        assertEq(keeper.balance - keeperBefore, 0, "Keeper should not receive failed-order fee");
        assertEq(spammer.balance, 10 ether, "Failed-order keeper fee should restore the user's ETH balance");
    }

}

// ============================================================
// C-03: Delta Margin Check Allows Under-Margined Positions
// ============================================================

contract AuditC03_MarginCheck is BasePerpTest {

    address alice = address(0x111);

    function test_C03_PostFeeMarginBelowImr() public {
        _fundTrader(alice, 100_000 * 1e6);
        address aliceAccount = alice;

        // Open 200k BULL tokens at $1.00
        // Notional = $200k, MMR = 1% = $2000, explicit IMR = 1.5% = $3000
        // marginDelta = $3070 → pre-fee passes IMR ($3070 >= $3000)
        // execFee = 4bps * $200k = $80 → pos.margin = $2990 < $3000
        // C-03 FIX: IMR check now uses pos.margin, so this correctly reverts
        uint256 depth = pool.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector, 1, 6, false));
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: aliceAccount,
                sizeDelta: 200_000 * 1e18,
                marginDelta: 3070 * 1e6,
                targetPrice: 1e8,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );
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
        address traderAccount = trader;
        _open(traderAccount, CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8);

        // Crash: BULL loses when oracle rises
        vm.prank(address(router));
        engine.updateMarkPrice(1.5e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 redeemShares = juniorVault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 requestId = juniorVault.requestRedeem(redeemShares, alice, alice);

        // The request must mature, but settlement must not price it from a stale live-market mark.
        vm.warp(juniorVault.depositEpochStart(requestId));
        uint256 staleMarkPrice = engine.lastMarkPrice();
        uint256 staleMarkTime = engine.lastMarkTime();
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        vm.prank(address(router));
        pool.settleLpEpoch(staleMarkPrice, staleMarkTime);
    }

    function test_C04_StaleReconcileDoesNotCreateUnpaidDebt() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 800; // 8% APY
        pool.proposePoolConfig(config);
        _warpForward(48 hours + 1);
        pool.finalizePoolConfig();

        _fundTrader(address(0xBBB), 10_000 * 1e6);
        address traderAccount = address(0xBBB);
        _open(traderAccount, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8);

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

    function test_C05_DepositAllowedWhenImpaired() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(address(this), 50_000 * 1e6);

        // Create a deficit: BEAR trader profits, wiping junior and dipping into senior
        _fundTrader(address(0xAAA), 5000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.BEAR, 100_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.8e8, uint64(block.timestamp));
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorPrincipal = pool.seniorPrincipal();
        uint256 hwm = pool.seniorHighWaterMark();
        assertLt(seniorPrincipal, hwm, "Senior tranche is impaired");

        // C-05 BUG: attacker can deposit into an impaired tranche.
        // With multiplicative HWM scaling (C-01), this fabricates phantom debt.
        // Deposits should be blocked when seniorPrincipal < seniorHighWaterMark.
        uint256 depositAmount = pool.minTrancheDepositUsdc();
        usdc.mint(attacker, depositAmount);
        vm.startPrank(attacker);
        usdc.approve(address(seniorVault), depositAmount);
        vm.expectRevert(TrancheVault.TrancheVault__DepositsUnavailable.selector);
        seniorVault.requestDeposit(depositAmount, attacker);
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

    function test_H01_UpdateMarkUsesPublishTime() public {
        _fundTrader(address(0xAAA), 10_000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.BULL, 50_000 * 1e18, 5000 * 1e6, 1e8);

        _warpForward(50);

        // H-01 FIX: engine.updateMarkPrice now uses publishTime, not block.timestamp
        uint64 vaaTime = uint64(block.timestamp) - 30;
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector);
        engine.updateMarkPrice(0.8e8, vaaTime);
    }

}

// ============================================================
// H-02: Overly Restrictive Withdrawal Firewall
// ============================================================

contract AuditH02_WithdrawBlocked is BasePerpTest {

    address alice = address(0x111);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function test_H02_WithdrawBlockedWithAnyPosition() public {
        _fundTrader(alice, 100_000 * 1e6);
        address aliceAccount = alice;

        // Open a small position: 50k tokens, $1000 margin (well above IMR)
        // Notional = $50k, IMR = max(1.5% * $50k, $5) = $750
        _open(aliceAccount, CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0);

        uint256 balance = clearinghouse.balanceUsdc(aliceAccount);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceAccount);
        uint256 freeBalance = balance - locked;
        assertGt(freeBalance, 90_000 * 1e6, "Alice has ~$99k free but can't touch it");

        // H-02 BUG: Alice should be able to withdraw $1 from her $99k+ free balance.
        // Instead, checkWithdraw reverts for ANY size > 0, trapping all excess collateral.
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(aliceAccount, 1e6);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + 1e6, "H-02: should withdraw $1 of free equity");
    }

}

// ============================================================
// H-03: Partial Close Creates Unliquidatable Dust
// ============================================================

contract AuditH03_DustPosition is BasePerpTest {

    address alice = address(0x111);

    function test_H03_PartialCloseLeavesLiquidatableExactWholeLotResidual() public {
        _fundTrader(alice, 50_000 * 1e6);
        address aliceAccount = alice;

        // Open 50k tokens at $1.00: notional = $50k
        // IMR = max(1.5% * $50k, $5) = $750. The supplied margin also funds the
        // dedicated $50 liquidation reserve and the $20 execution fee.
        uint256 posSize = 50_000 * 1e18;
        _open(aliceAccount, CfdTypes.Side.BULL, posSize, 825 * 1e6, 1e8);

        // Closing every lot but one is quantum-valid. V2 permits the exact residual and
        // preserves its dedicated liquidation reserve so it can still be liquidated.
        uint256 closeSize = posSize - CfdTypes.SIZE_QUANTUM;
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: aliceAccount,
                sizeDelta: closeSize,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: true
            }),
            1e8,
            depth,
            uint64(block.timestamp)
        );

        (uint256 remainingSize, uint256 remainingMargin,,,,,) = engine.positions(aliceAccount);
        assertEq(remainingSize, CfdTypes.SIZE_QUANTUM, "Partial close must leave one canonical whole lot");
        assertLt(remainingMargin, 5e6, "Fixture must retain a small but exact residual pledge");
        assertEq(
            clearinghouse.liquidationReserveUsdc(aliceAccount),
            _riskParams().minBountyUsdc,
            "Residual lot must retain the configured minimum liquidation reserve"
        );
        _assertTerminalCurveMatchesEngine(aliceAccount);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(aliceAccount, 101_000_000);
        assertTrue(preview.liquidatable, "An adverse exact price must make the residual lot liquidatable");

        depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(aliceAccount, 101_000_000, depth, uint64(block.timestamp), address(this));
        (remainingSize,,,,,,) = engine.positions(aliceAccount);
        assertEq(remainingSize, 0, "Liquidation must clear the exact residual lot");
        _assertTerminalCurveMatchesEngine(aliceAccount);
    }

}

// ============================================================
// N-01: Share Transfer Bypasses Deposit Cooldown
// ============================================================

contract AuditN01_TransferBypassesCooldown is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_N01_TransferRecipientBypassesCooldown() public {
        _fundJunior(alice, 100_000 * 1e6);
        uint256 aliceDepositTime = juniorVault.lastDepositTime(alice);

        // Wait for Alice's cooldown to expire
        vm.warp(aliceDepositTime + juniorVault.DEPOSIT_COOLDOWN());

        // Alice transfers to bob (fresh address, lastDepositTime=0)
        uint256 shares = juniorVault.balanceOf(alice);
        vm.prank(alice);
        juniorVault.transfer(bob, shares);

        // Fix: Bob inherits Alice's deposit time instead of keeping zero default.
        // Since sender cooldown is already expired when transfers are allowed,
        // this is defense-in-depth — it ensures lastDepositTime is never 0 for
        // an address holding shares, which matters if cooldown logic evolves.
        assertEq(juniorVault.lastDepositTime(bob), aliceDepositTime, "Bob inherits Alice's deposit time");
        assertGt(juniorVault.lastDepositTime(bob), 0, "Zero default is eliminated");
    }

}

// ============================================================
// H-04: Senior coupon accounting on withdrawal
// ============================================================

contract AuditH04_SeniorCouponWithdrawalAccounting is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_H04_UnpaidYieldDebtRemovedAndHwmScales() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundSenior(bob, 500_000 * 1e6);
        _fundJunior(address(this), 2_000_000 * 1e6);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 800; // 8% APY
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

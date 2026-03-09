// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract HousePoolTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    receive() external payable {}

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine), address(pool), address(0), new bytes32[](0), new uint256[](0), new uint256[](0)
        );

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));
    }

    function _fundSenior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(seniorVault), amount);
        seniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    // ==========================================
    // DEPOSIT & PRINCIPAL TRACKING
    // ==========================================

    function test_SeniorJuniorDeposit() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        assertEq(pool.seniorPrincipal(), 500_000 * 1e6);
        assertEq(pool.juniorPrincipal(), 300_000 * 1e6);
        assertEq(pool.totalAssets(), 800_000 * 1e6);
        assertEq(seniorVault.totalAssets(), 500_000 * 1e6);
        assertEq(juniorVault.totalAssets(), 300_000 * 1e6);
    }

    // ==========================================
    // REVENUE WATERFALL
    // ==========================================

    function test_RevenueDistribution() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Simulate trader loss: mint USDC directly to pool (trader margin seized)
        usdc.mint(address(pool), 100_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield = 500k * 8% * 1 year = 40k (capped at revenue=100k, so 40k)
        // Junior surplus = 100k - 40k = 60k
        assertEq(pool.seniorPrincipal(), 540_000 * 1e6, "Senior gets 8% APY yield");
        assertEq(pool.juniorPrincipal(), 560_000 * 1e6, "Junior gets surplus");
    }

    function test_RevenueDistribution_SeniorCapped() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        // Small revenue: only 10k
        usdc.mint(address(pool), 10_000 * 1e6);

        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Senior yield would be 40k but capped at 10k revenue
        assertEq(pool.seniorPrincipal(), 510_000 * 1e6, "Senior capped at available revenue");
        assertEq(pool.juniorPrincipal(), 500_000 * 1e6, "Junior gets nothing when revenue < senior yield");
    }

    // ==========================================
    // LOSS WATERFALL
    // ==========================================

    function test_LossWaterfall_JuniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 300_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.50 → BULL profits $100k
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.5e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertLe(pool.juniorPrincipal(), 300_000 * 1e6, "Junior absorbed loss");
        assertEq(pool.seniorPrincipal(), 500_000 * 1e6, "Senior untouched when junior covers");
    }

    function test_JuniorWipeout_SeniorAbsorbs() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 50_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 20_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.50 → BULL profits $100k, exceeding junior's $50k
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.5e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 200_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 0, "Junior wiped out");
        assertLt(pool.seniorPrincipal(), 500_000 * 1e6, "Senior absorbs remaining loss");
    }

    // ==========================================
    // WITHDRAWAL PRIORITY
    // ==========================================

    function test_WithdrawalPriority() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 800_000 * 1e18, 40_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Max liability = 800k (BULL at $1, cap $2 → max profit = entry*size = $800k)
        // Free USDC = totalAssets - maxLiability
        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 seniorMax = pool.getMaxSeniorWithdraw();
        uint256 juniorMax = pool.getMaxJuniorWithdraw();

        // Senior has first claim on freeUSDC
        assertEq(seniorMax, freeUsdc < 500_000 * 1e6 ? freeUsdc : 500_000 * 1e6);
        // Junior only gets what's left after senior's claim
        uint256 expectedJuniorMax = freeUsdc > 500_000 * 1e6 ? freeUsdc - 500_000 * 1e6 : 0;
        if (expectedJuniorMax > 500_000 * 1e6) {
            expectedJuniorMax = 500_000 * 1e6;
        }
        assertEq(juniorMax, expectedJuniorMax);
    }

    function test_SeniorCanWithdrawWhenJuniorCannot() public {
        _fundSenior(alice, 200_000 * 1e6);
        _fundJunior(bob, 200_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 250_000 * 1e18, 25_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // freeUSDC ≈ 400k - 250k + exec_fees. Senior principal = 200k.
        // Senior max = min(200k, freeUSDC) < 200k
        // Junior max = max(0, freeUSDC - 200k) = 0 since freeUSDC < 200k
        uint256 seniorMax = pool.getMaxSeniorWithdraw();
        assertGt(seniorMax, 0, "Senior can withdraw");
        assertLt(seniorMax, 200_000 * 1e6, "Senior capped below principal");
        assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior fully subordinated");
    }

    // ==========================================
    // RECONCILE EXCLUDES PROTOCOL FEES
    // ==========================================

    function test_ReconcileExcludesProtocolFees() public {
        _fundJunior(bob, 1_000_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        uint256 fees = engine.accumulatedFeesUsdc();
        assertTrue(fees > 0, "Fees should exist after trade");

        // Pool balance includes the seized margin (exec fee goes to pool as part of seize)
        // But reconcile should NOT treat fees as LP revenue
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Junior principal should NOT include protocol fees
        // Total pool balance = initial 1M + seized margin from trader
        // Distributable = balance - fees
        // If distributable > juniorPrincipal, surplus is revenue
        // The fee portion stays as unaccounted balance (owned by protocol)
        uint256 totalBalance = pool.totalAssets();
        uint256 claimedEquity = pool.juniorPrincipal();
        assertLe(claimedEquity, totalBalance - fees, "Claimed equity excludes pending protocol fees");
    }

    // ==========================================
    // FULL INTEGRATION
    // ==========================================

    function test_FullIntegration() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        _fundTrader(carol, 50_000 * 1e6);

        // Trader opens BULL $100k at $1.00
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // Price drops to $0.80 → BULL profits $20k (paid from pool)
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(0.8e8);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0, true);
        router.executeOrder{value: 0}(2, pythData);

        vm.warp(block.timestamp + 30 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Pool paid out ~$20k profit to trader. Junior absorbs first.
        assertLt(pool.juniorPrincipal(), 500_000 * 1e6, "Junior absorbed trader profit payout");
        assertEq(pool.seniorPrincipal(), 500_000 * 1e6, "Senior untouched");
    }

    // ==========================================
    // SENIOR RATE CHANGE
    // ==========================================

    function test_SeniorRateChange() public {
        _fundSenior(alice, 1_000_000 * 1e6);
        _fundJunior(bob, 1_000_000 * 1e6);

        // Generate some revenue
        usdc.mint(address(pool), 200_000 * 1e6);

        vm.warp(block.timestamp + 365 days);

        // Change rate — this triggers reconcile first
        pool.setSeniorRate(1200); // 12% APY

        // Senior should have received 8% for the first year
        assertEq(pool.seniorPrincipal(), 1_080_000 * 1e6, "Senior got 8% before rate change");
        assertEq(pool.juniorPrincipal(), 1_120_000 * 1e6, "Junior got surplus");
    }

    // ==========================================
    // ERC4626 SHARE ACCOUNTING
    // ==========================================

    function test_ShareAccounting_AfterRevenue() public {
        _fundSenior(alice, 100_000 * 1e6);
        _fundJunior(bob, 100_000 * 1e6);

        uint256 seniorPriceBefore = seniorVault.convertToAssets(1e9);
        uint256 juniorPriceBefore = juniorVault.convertToAssets(1e9);

        usdc.mint(address(pool), 20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorPriceAfter = seniorVault.convertToAssets(1e9);
        uint256 juniorPriceAfter = juniorVault.convertToAssets(1e9);

        assertTrue(seniorPriceAfter > seniorPriceBefore, "Senior share price should increase");
        assertTrue(juniorPriceAfter > juniorPriceBefore, "Junior share price should increase");
    }

    function test_SharePrice_NoFreeDilution() public {
        _fundJunior(alice, 100_000 * 1e6);
        uint256 aliceShares = juniorVault.balanceOf(alice);

        usdc.mint(address(pool), 20_000 * 1e6);
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        _fundJunior(bob, 100_000 * 1e6);
        uint256 bobShares = juniorVault.balanceOf(bob);

        assertGt(aliceShares, bobShares, "Late depositor should receive fewer shares");

        uint256 aliceAssets = juniorVault.convertToAssets(aliceShares);
        uint256 bobAssets = juniorVault.convertToAssets(bobShares);
        assertGt(aliceAssets, bobAssets, "Early depositor's shares should be worth more");
    }

    function test_SetOrderRouter_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__RouterAlreadySet.selector);
        pool.setOrderRouter(address(0x999));
    }

    function test_SetSeniorVault_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__SeniorVaultAlreadySet.selector);
        pool.setSeniorVault(address(0x999));
    }

    function test_SetJuniorVault_Twice_Reverts() public {
        vm.expectRevert(HousePool.HousePool__JuniorVaultAlreadySet.selector);
        pool.setJuniorVault(address(0x999));
    }

    function test_PayOut_Unauthorized_Reverts() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.prank(alice);
        vm.expectRevert(HousePool.HousePool__Unauthorized.selector);
        pool.payOut(alice, 1000 * 1e6);
    }

    function test_H6_ReconcileSpam_DoesNotEraseSeniorYield() public {
        _fundSenior(alice, 500_000 * 1e6);
        _fundJunior(bob, 500_000 * 1e6);

        usdc.mint(address(pool), 100_000 * 1e6);

        // Use absolute timestamps to avoid block.timestamp caching in test call frame
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= 365; i++) {
            vm.warp(t0 + i * 1 days);
            vm.prank(address(juniorVault));
            pool.reconcile();
        }

        // Senior's total claim = seniorPrincipal + unpaidSeniorYield
        // Should be ~$540k (8% * $500k = $40k yield) regardless of reconcile frequency.
        uint256 totalSeniorClaim = pool.seniorPrincipal() + pool.unpaidSeniorYield();
        // Integer division across 365 daily reconciles loses ≤ $1 cumulative
        assertGe(totalSeniorClaim, 540_000 * 1e6 - 1e6, "Senior total claim must reflect 8% APY");

        // Inject fresh revenue to pay unpaid yield
        usdc.mint(address(pool), 50_000 * 1e6);
        vm.warp(t0 + 366 days);
        vm.prank(address(juniorVault));
        pool.reconcile();

        // Now unpaidSeniorYield should be mostly paid from fresh revenue
        assertGe(pool.seniorPrincipal(), 540_000 * 1e6 - 1e6, "Senior principal catches up when revenue arrives");
    }

    function test_M12_GetFreeUSDC_ReservesFees() public {
        _fundJunior(bob, 500_000 * 1e6);

        address trader = address(0x444);
        usdc.mint(trader, 50_000 * 1e6);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 50_000 * 1e6);
        clearinghouse.deposit(bytes32(uint256(uint160(trader))), address(usdc), 50_000 * 1e6);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 5000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        // 100k BULL at $1.00: execFee = $100k * 6bps = $60
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 60_000_000, "Exec fee = 6bps of $100k notional");

        uint256 freeUSDC = pool.getFreeUSDC();
        uint256 vaultBal = usdc.balanceOf(address(pool));
        uint256 maxLiability = engine.globalBullMaxProfit();

        assertTrue(freeUSDC <= vaultBal - maxLiability - fees, "Free USDC must exclude pending fees");
    }

    function test_M10_JitLP_BlockedByCooldown() public {
        _fundJunior(bob, 500_000 * 1e6);

        _fundJunior(carol, 500_000 * 1e6);

        usdc.mint(address(pool), 50_000 * 1e6);

        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(carol);
        juniorVault.withdraw(500_000 * 1e6, carol, carol);
    }

    function test_DustDepositGriefing_DoesNotResetCooldown() public {
        _fundJunior(alice, 100_000 * 1e6);

        vm.warp(block.timestamp + 50 minutes);

        // Attacker deposits 1 wei on behalf of alice to grief her cooldown
        address attacker = address(0xBAD);
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1);
        juniorVault.deposit(1, alice);
        vm.stopPrank();

        // Alice's cooldown should still be mostly elapsed (weighted average),
        // not fully reset. She can withdraw after the remaining ~10 minutes.
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100_000 * 1e6);
    }

    function test_C3_DepositCooldown_BlocksFlashWithdraw() public {
        _fundJunior(alice, 100_000 * 1e6);

        // Alice deposits and tries to withdraw in the same block
        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);

        // After cooldown passes, withdrawal succeeds
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        juniorVault.withdraw(100_000 * 1e6, alice, alice);
        assertEq(usdc.balanceOf(alice), 100_000 * 1e6, "Withdrawal after cooldown succeeds");
    }

}

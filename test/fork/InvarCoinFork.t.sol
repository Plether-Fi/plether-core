// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ICurveTwocrypto, InvarCoin} from "../../src/InvarCoin.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BaseForkTest, ICurvePoolExtended} from "./BaseForkTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvarCoinForkTest is BaseForkTest {

    InvarCoin ic;
    StakedToken sInvar;

    address treasury;
    address alice;
    address bob;
    address whale;
    address keeper;
    address rewardDist;
    address attacker;

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        whale = makeAddr("whale");
        keeper = makeAddr("keeper");
        rewardDist = makeAddr("rewardDist");
        attacker = makeAddr("attacker");

        deal(USDC, address(this), 40_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);

        ic = new InvarCoin(USDC, bearToken, curvePool, curvePool, address(basketOracle), address(0), address(0));

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        deal(USDC, alice, 2_000_000e6);
        deal(USDC, bob, 100_000e6);
        deal(USDC, whale, 2_000_000e6);
        deal(USDC, attacker, 50_000_000e6);

        vm.prank(alice);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        vm.prank(whale);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        vm.prank(attacker);
        IERC20(USDC).approve(address(ic), type(uint256).max);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _warpAndRefreshOracle(
        uint256 duration
    ) internal {
        vm.warp(block.timestamp + duration);
        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        vm.mockCall(
            CL_EUR,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), clPrice, uint256(0), block.timestamp, uint80(1))
        );
    }

    function _depositAs(
        address user,
        uint256 usdcAmount
    ) internal returns (uint256 shares) {
        vm.prank(user);
        shares = ic.deposit(usdcAmount, user, 0);
    }

    function _generateCurveFees(
        uint256 swapAmount,
        uint256 rounds
    ) internal {
        deal(USDC, address(this), swapAmount * 2);
        deal(bearToken, address(this), swapAmount * 1e12 * 2);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        IERC20(bearToken).approve(curvePool, type(uint256).max);

        for (uint256 i = 0; i < rounds; i++) {
            // USDC -> BEAR
            (bool s1,) = curvePool.call(
                abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, swapAmount, 0)
            );
            require(s1, "swap USDC->BEAR failed");
            // BEAR -> USDC
            uint256 bearBal = IERC20(bearToken).balanceOf(address(this));
            (bool s2,) = curvePool.call(
                abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, bearBal / 2, 0)
            );
            require(s2, "swap BEAR->USDC failed");
        }
    }

    // ==========================================
    // PHASE 1: RETAIL OPERATIONS
    // ==========================================

    function test_deposit_gasEfficiency() public {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        uint256 shares = ic.deposit(10_000e6, alice, 0);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 500_000, "Deposit gas too high");
        assertGt(shares, 0, "Should receive shares");
    }

    function test_withdraw_seamless() public {
        uint256 shares = _depositAs(alice, 10_000e6);

        _warpAndRefreshOracle(1 days);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        ic.withdraw(shares, alice, 0);
        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);

        assertGe(aliceUsdcAfter - aliceUsdcBefore, 9999e6, "Should recover nearly all USDC");
        assertEq(ic.balanceOf(alice), 0, "Should have no INVAR left");
    }

    function test_withdraw_jitLpBurn() public {
        _depositAs(alice, 1_000_000e6);

        ic.deployToCurve(0);

        uint256 aliceShares = ic.balanceOf(alice);
        uint256 bigWithdrawShares = (aliceShares * 30) / 100;

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bigWithdrawShares, alice, 0);

        assertGt(usdcOut, 250_000e6, "Should receive substantial USDC via JIT LP burn");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcOut, "Transfer should match return value");
    }

    // ==========================================
    // PHASE 2: LP WITHDRAWAL & CONVEXITY
    // ==========================================

    function test_lpWithdraw_slippageAbsorption() public {
        address[5] memory retailers = [makeAddr("r1"), makeAddr("r2"), makeAddr("r3"), makeAddr("r4"), makeAddr("r5")];
        for (uint256 i = 0; i < 5; i++) {
            deal(USDC, retailers[i], 100_000e6);
            vm.prank(retailers[i]);
            IERC20(USDC).approve(address(ic), type(uint256).max);
            _depositAs(retailers[i], 100_000e6);
        }
        ic.deployToCurve(0);

        uint256 whaleShares = _depositAs(whale, 1_000_000e6);

        uint256 whaleUsdcBefore = IERC20(USDC).balanceOf(whale);
        uint256 whaleBearBefore = IERC20(bearToken).balanceOf(whale);

        vm.prank(whale);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(whaleShares, 0, 0);

        uint256 usdcFromWhale = IERC20(USDC).balanceOf(whale) - whaleUsdcBefore;
        uint256 bearFromWhale = IERC20(bearToken).balanceOf(whale) - whaleBearBefore;
        assertEq(usdcFromWhale, usdcReturned, "USDC transfer mismatch");
        assertEq(bearFromWhale, bearReturned, "BEAR transfer mismatch");

        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        uint256 bearPrice8 = uint256(clPrice);
        uint256 bearValueUsdc = (bearReturned * bearPrice8) / 1e20;
        uint256 totalValue = usdcReturned + bearValueUsdc;

        assertApproxEqRel(totalValue, 1_000_000e6, 0.03e18, "Whale value should approximate deposit");
        assertGt(totalValue, 950_000e6, "Whale loss should be bounded");
    }

    function test_lpWithdraw_navIsolation() public {
        address[5] memory retailers = [makeAddr("r1"), makeAddr("r2"), makeAddr("r3"), makeAddr("r4"), makeAddr("r5")];
        for (uint256 i = 0; i < 5; i++) {
            deal(USDC, retailers[i], 100_000e6);
            vm.prank(retailers[i]);
            IERC20(USDC).approve(address(ic), type(uint256).max);
            _depositAs(retailers[i], 100_000e6);
        }
        ic.deployToCurve(0);

        uint256 navBefore = (ic.totalAssets() * 1e18) / ic.totalSupply();

        vm.warp(block.timestamp + 1800);

        _depositAs(whale, 500_000e6);
        ic.deployToCurve(0);

        uint256 whaleShares = ic.balanceOf(whale);
        vm.prank(whale);
        ic.lpWithdraw(whaleShares, 0, 0);

        uint256 navAfter = (ic.totalAssets() * 1e18) / ic.totalSupply();

        assertGe(navAfter, navBefore * 98 / 100, "LP withdraw must not significantly reduce retail NAV");
    }

    function test_lpWithdraw_mevProtection() public {
        _depositAs(whale, 1_000_000e6);
        ic.deployToCurve(0);
        uint256 whaleShares = ic.balanceOf(whale);

        vm.prank(attacker);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        vm.prank(attacker);
        ICurveTwocrypto(curvePool).add_liquidity([uint256(10_000_000e6), 0], 0);

        vm.prank(whale);
        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        ic.lpWithdraw(whaleShares, 990_000e6, 0);
    }

    // ==========================================
    // PHASE 3: KEEPER & YIELD
    // ==========================================

    function test_deployToCurve_batchRetailDeposits() public {
        address[5] memory actors = [makeAddr("d1"), makeAddr("d2"), makeAddr("d3"), makeAddr("d4"), makeAddr("d5")];
        for (uint256 i = 0; i < 5; i++) {
            deal(USDC, actors[i], 100_000e6);
            vm.prank(actors[i]);
            IERC20(USDC).approve(address(ic), type(uint256).max);
            _depositAs(actors[i], 100_000e6);
        }

        vm.prank(keeper);
        ic.deployToCurve(0);

        assertGt(IERC20(curvePool).balanceOf(address(ic)), 0, "Should hold LP tokens");

        uint256 localUsdc = IERC20(USDC).balanceOf(address(ic));
        assertApproxEqRel(localUsdc, ic.totalAssets() / 50, 0.05e18, "Buffer ~2% of totalAssets");

        assertApproxEqRel(ic.totalAssets(), 500_000e6, 0.02e18, "No value leaked during deploy");
    }

    function test_deployToCurve_singleSidedUsdc() public {
        _depositAs(alice, 100_000e6);

        uint256 lpBefore = IERC20(curvePool).balanceOf(address(ic));
        ic.deployToCurve(0);

        assertGt(IERC20(curvePool).balanceOf(address(ic)), lpBefore, "Should mint LP with USDC-only deposit");
    }

    function test_harvestYield_curveFeeGrowth() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve(0);

        uint256 assetsBefore = ic.totalAssets();

        _generateCurveFees(50_000e6, 10);

        uint256 assetsAfter = ic.totalAssets();
        assertGt(assetsAfter, assetsBefore, "Curve fee growth should increase totalAssets via virtual_price");
    }

    function test_replenishBuffer() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);

        // Flush pending Curve admin fees: add_liquidity updates xcp_profit via
        // _tweak_price, but calc_withdraw_one_coin (view) doesn't call
        // _claim_admin_fees while remove_liquidity_one_coin (mutable) does.
        // A tiny LP burn triggers the claim so both see the same state.
        // (exchange() doesn't work — it uses _tweak_price which has stricter
        // claiming conditions than the direct _claim_admin_fees path.)
        IERC20(curvePool).approve(curvePool, 1e18);
        ICurveTwocrypto(curvePool).remove_liquidity_one_coin(1e18, 0, 0);

        // Simulate buffer drain below 2% target
        uint256 localUsdc = IERC20(USDC).balanceOf(address(ic));
        deal(USDC, address(ic), localUsdc / 10);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(ic));

        ic.replenishBuffer(0);

        assertGt(IERC20(USDC).balanceOf(address(ic)), usdcBefore, "Local USDC buffer should increase");
    }

    function test_harvest_curveFeeYield() public {
        _depositAs(alice, 500_000e6);

        uint256 aliceShares = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        _generateCurveFees(50_000e6, 10);
        _warpAndRefreshOracle(1 days);

        uint256 sInvarAssetsBefore = ic.balanceOf(address(sInvar));
        uint256 supplyBefore = ic.totalSupply();

        vm.prank(keeper);
        ic.harvest();

        assertGt(ic.totalSupply(), supplyBefore, "New shares should be minted");
        assertGt(ic.balanceOf(address(sInvar)), sInvarAssetsBefore, "sINVAR should receive Curve fee yield");
    }

    // ==========================================
    // PHASE 4: ADVERSARIAL
    // ==========================================

    function test_flashLoanNavExploit() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);

        uint256 navBefore = ic.totalAssets();

        vm.startPrank(attacker);
        IERC20(USDC).approve(curvePool, type(uint256).max);
        ICurveTwocrypto(curvePool).add_liquidity([uint256(50_000_000e6), 0], 0);
        vm.stopPrank();

        uint256 navDuring = ic.totalAssets();
        assertApproxEqRel(navDuring, navBefore, 0.01e18, "virtual_price should be immune to reserve manipulation");

        uint256 attackerLp = IERC20(curvePool).balanceOf(attacker);
        vm.startPrank(attacker);
        ICurveTwocrypto(curvePool).remove_liquidity_one_coin(attackerLp, 0, 0);
        vm.stopPrank();

        assertApproxEqRel(ic.totalAssets(), navBefore, 0.01e18, "NAV should be restored after manipulation");
    }

    function test_replenishBuffer_sandwichProtection() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve(0);

        // Simulate buffer drain so replenishBuffer is callable
        deal(USDC, address(ic), 0);

        deal(bearToken, attacker, 5_000_000e18);
        vm.startPrank(attacker);
        IERC20(bearToken).approve(curvePool, type(uint256).max);
        (bool s,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, 5_000_000e18, 0));
        require(s, "attacker swap failed");
        vm.stopPrank();

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.replenishBuffer(0);
    }

    function test_deployToCurve_sandwichProtection() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve(0);

        // New deposit creates deployable buffer
        _depositAs(whale, 1_000_000e6);

        // Attacker pumps BEAR (sells USDC) → pool becomes USDC-heavy → deployToCurve gets fewer LP
        vm.startPrank(attacker);
        IERC20(USDC).approve(curvePool, 40_000_000e6);
        (bool s,) =
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, 40_000_000e6, 0));
        require(s, "attacker swap failed");
        vm.stopPrank();

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.deployToCurve(0);
    }

    // ==========================================
    // PHASE 5: FULL LIFECYCLE
    // ==========================================

    function test_fullLifecycle_depositToWithdrawal() public {
        uint256 aliceDeposit = 500_000e6;
        uint256 bobDeposit = 100_000e6;
        uint256 totalDeposit = aliceDeposit + bobDeposit;

        // 1. Deposits: Alice 500k, Bob 100k USDC
        uint256 aliceShares = _depositAs(alice, aliceDeposit);
        uint256 bobShares = _depositAs(bob, bobDeposit);

        assertApproxEqRel(ic.totalAssets(), totalDeposit, 0.01e18, "totalAssets should reflect deposits");
        assertApproxEqRel(
            aliceShares * bobDeposit, bobShares * aliceDeposit, 0.001e18, "Share ratio matches deposit ratio"
        );

        // 2. Keeper deploys excess USDC to Curve LP (98% deployed, 2% buffer)
        vm.prank(keeper);
        ic.deployToCurve(0);

        uint256 bufferAfterDeploy = IERC20(USDC).balanceOf(address(ic));
        uint256 expectedBuffer = ic.totalAssets() * 200 / 10_000;
        assertApproxEqRel(bufferAfterDeploy, expectedBuffer, 0.1e18, "Buffer ~2% of NAV");
        assertApproxEqRel(ic.totalAssets(), totalDeposit, 0.02e18, "No value leaked during deploy");

        // 3. Alice stakes all INVAR → sINVAR (1000x decimal offset)
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        uint256 sInvarShares = sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        assertEq(sInvarShares, aliceShares * 1000, "1000x decimal offset on initial stake");

        // 4. Curve trading generates fees (virtual price growth)
        uint256 vpBefore = ICurveTwocrypto(curvePool).get_virtual_price();
        _generateCurveFees(50_000e6, 10);
        uint256 vpAfter = ICurveTwocrypto(curvePool).get_virtual_price();
        assertGt(vpAfter, vpBefore, "Trading fees grow virtual price");

        _warpAndRefreshOracle(1 days);

        // 5. Harvest: mints new INVAR from fee yield, donates to sINVAR stakers
        uint256 supplyBeforeHarvest = ic.totalSupply();
        uint256 sInvarBalBefore = ic.balanceOf(address(sInvar));

        vm.prank(keeper);
        ic.harvest();

        uint256 newInvarMinted = ic.totalSupply() - supplyBeforeHarvest;
        uint256 yieldDonated = ic.balanceOf(address(sInvar)) - sInvarBalBefore;
        assertEq(newInvarMinted, yieldDonated, "All minted yield goes to sINVAR");

        // 6. Wait for full yield stream vesting (1 hour)
        _warpAndRefreshOracle(1 hours);

        uint256 aliceRedeemable = sInvar.previewRedeem(sInvarShares);
        assertGt(aliceRedeemable, aliceShares, "Staked position grew from vested yield");

        // 7. Alice unstakes sINVAR → INVAR (yield increased her position)
        vm.startPrank(alice);
        uint256 invarRedeemed = sInvar.redeem(sInvarShares, alice, alice);
        vm.stopPrank();

        assertGt(invarRedeemed, aliceShares, "Staking yield grew alice's INVAR balance");

        // 8. Alice does balanced exit via lpWithdraw (USDC + BEAR)
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 aliceBearBefore = IERC20(bearToken).balanceOf(alice);
        vm.prank(alice);
        (uint256 aliceUsdc, uint256 aliceBear) = ic.lpWithdraw(invarRedeemed, 0, 0);

        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, aliceUsdc, "Alice USDC transfer matches");
        assertEq(IERC20(bearToken).balanceOf(alice) - aliceBearBefore, aliceBear, "Alice BEAR transfer matches");

        (, int256 bearPrice8,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        uint256 aliceTotalValue = aliceUsdc + (aliceBear * uint256(bearPrice8)) / 1e20;
        assertGt(aliceTotalValue, aliceDeposit * 99 / 100, "Alice recovers >99% (balanced exit, minimal slippage)");

        // 9. Bob does single-sided withdraw (USDC only via buffer + JIT LP burn)
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 bobUsdcOut = ic.withdraw(bobShares, bob, 0);

        assertEq(IERC20(USDC).balanceOf(bob) - bobUsdcBefore, bobUsdcOut, "Bob USDC transfer matches");
        assertGt(bobUsdcOut, bobDeposit * 99 / 100, "Bob recovers >99% (small position, low slippage)");

        // 10. Vault fully drained
        assertLe(ic.totalSupply(), 1, "At most 1 wei rounding dust remains");
    }

}

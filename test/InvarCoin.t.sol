// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// ==========================================
// MOCKS
// ==========================================

contract MockUSDC6 is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockBEAR is ERC20 {

    constructor() ERC20("Mock plDXY-BEAR", "plDXY-BEAR") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockCurveLpToken is ERC20 {

    constructor() ERC20("Mock Curve LP", "crvLP") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

}

contract MockCurvePool {

    IERC20 public usdc;
    IERC20 public bear;
    MockCurveLpToken public lpToken;

    uint256 public usdcBalance;
    uint256 public bearBalance;
    uint256 public virtualPrice = 1e18;
    uint256 public priceMultiplier = 1e18;
    uint256 public swapFeeBps;
    uint256 public spotDiscountBps;

    constructor(
        address _usdc,
        address _bear,
        address _lpToken
    ) {
        usdc = IERC20(_usdc);
        bear = IERC20(_bear);
        lpToken = MockCurveLpToken(_lpToken);
    }

    function setSwapFeeBps(
        uint256 _feeBps
    ) external {
        swapFeeBps = _feeBps;
    }

    function setSpotDiscountBps(
        uint256 _discountBps
    ) external {
        spotDiscountBps = _discountBps;
    }

    function setBearBalance(
        uint256 _bearBalance
    ) external {
        bearBalance = _bearBalance;
    }

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256
    ) external returns (uint256) {
        if (amounts[0] > 0) {
            usdc.transferFrom(msg.sender, address(this), amounts[0]);
        }
        if (amounts[1] > 0) {
            bear.transferFrom(msg.sender, address(this), amounts[1]);
        }

        usdcBalance += amounts[0];
        bearBalance += amounts[1];

        uint256 bearAsUsdc = amounts[1] / 1e12;
        uint256 lpMinted = (amounts[0] + bearAsUsdc) * 1e12 / 2;
        lpToken.mint(msg.sender, lpMinted);

        return lpMinted;
    }

    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256
    ) external returns (uint256) {
        uint256 totalLp = lpToken.totalSupply();
        uint256 shareRatio = (token_amount * 1e18) / totalLp;

        uint256 usdcOut;
        if (i == 0) {
            uint256 usdcShare = (usdcBalance * shareRatio) / 1e18;
            uint256 bearShare = (bearBalance * shareRatio) / 1e18;
            uint256 bearAsUsdc = bearShare / 1e12;
            if (swapFeeBps > 0 && bearAsUsdc > 0) {
                bearAsUsdc -= (bearAsUsdc * swapFeeBps) / 10_000;
            }
            usdcOut = usdcShare + bearAsUsdc;

            usdcBalance -= usdcShare;
            bearBalance -= bearShare;

            if (bearAsUsdc > 0) {
                MockUSDC6(address(usdc)).mint(address(this), bearAsUsdc);
            }
        }

        lpToken.burn(msg.sender, token_amount);
        usdc.transfer(msg.sender, usdcOut);
        return usdcOut;
    }

    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata
    ) external returns (uint256[2] memory) {
        uint256 totalLp = lpToken.totalSupply();
        uint256 shareRatio = (amount * 1e18) / totalLp;

        uint256 usdcOut = (usdcBalance * shareRatio) / 1e18;
        uint256 bearOut = (bearBalance * shareRatio) / 1e18;

        usdcBalance -= usdcOut;
        bearBalance -= bearOut;

        lpToken.burn(msg.sender, amount);

        usdc.transfer(msg.sender, usdcOut);
        bear.transfer(msg.sender, bearOut);

        return [usdcOut, bearOut];
    }

    function get_virtual_price() external view returns (uint256) {
        return virtualPrice;
    }

    function lp_price() external view returns (uint256) {
        return 2 * virtualPrice * priceMultiplier / 1e18;
    }

    function calc_token_amount(
        uint256[2] calldata amounts,
        bool
    ) external view returns (uint256) {
        uint256 bearAsUsdc = amounts[1] / 1e12;
        uint256 lp = (amounts[0] + bearAsUsdc) * 1e12 / 2;
        if (spotDiscountBps > 0) {
            lp = lp * (10_000 - spotDiscountBps) / 10_000;
        }
        return lp;
    }

    function calc_withdraw_one_coin(
        uint256 token_amount,
        uint256 i
    ) external view returns (uint256) {
        uint256 totalLp = lpToken.totalSupply();
        uint256 shareRatio = (token_amount * 1e18) / totalLp;
        if (i == 0) {
            uint256 usdcShare = (usdcBalance * shareRatio) / 1e18;
            uint256 bearShare = (bearBalance * shareRatio) / 1e18;
            uint256 bearAsUsdc = bearShare / 1e12;
            if (swapFeeBps > 0 && bearAsUsdc > 0) {
                bearAsUsdc -= (bearAsUsdc * swapFeeBps) / 10_000;
            }
            uint256 out = usdcShare + bearAsUsdc;
            if (spotDiscountBps > 0) {
                out = out * (10_000 - spotDiscountBps) / 10_000;
            }
            return out;
        }
        return 0;
    }

    function setVirtualPrice(
        uint256 _vp
    ) external {
        virtualPrice = _vp;
    }

    function setPriceMultiplier(
        uint256 _pm
    ) external {
        priceMultiplier = _pm;
    }

}

// ==========================================
// TEST SUITE
// ==========================================

contract InvarCoinTest is Test {

    InvarCoin public ic;
    StakedToken public sInvar;
    MockUSDC6 public usdc;
    MockBEAR public bearToken;
    MockCurvePool public curve;
    MockCurveLpToken public curveLp;
    MockOracle public oracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeper = makeAddr("keeper");
    address public rewardDist = makeAddr("rewardDist");

    uint256 constant ORACLE_PRICE = 120_000_000;

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC6();
        oracle = new MockOracle(int256(ORACLE_PRICE), "plDXY Basket");
        bearToken = new MockBEAR();
        curveLp = new MockCurveLpToken();
        curve = new MockCurvePool(address(usdc), address(bearToken), address(curveLp));

        ic = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0)
        );

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(keeper, 100e6);

        vm.prank(alice);
        usdc.approve(address(ic), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(ic), type(uint256).max);
    }

    // ==========================================
    // DEPOSIT TESTS
    // ==========================================

    function test_Deposit_FirstDepositor() public {
        vm.prank(alice);
        uint256 minted = ic.deposit(1000e6, alice);

        assertGt(minted, 0);
        assertEq(ic.balanceOf(alice), minted);
        assertEq(ic.totalAssets(), 1000e6);
    }

    function test_Deposit_SecondDepositorFairShare() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        vm.prank(bob);
        uint256 minted = ic.deposit(1000e6, bob);

        uint256 aliceBal = ic.balanceOf(alice);
        uint256 bobBal = ic.balanceOf(bob);
        assertApproxEqRel(aliceBal, bobBal, 0.01e18);
    }

    function test_Deposit_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.deposit(0, alice);
    }

    function test_Deposit_RevertsWhenPaused() public {
        ic.pause();

        vm.expectRevert();
        vm.prank(alice);
        ic.deposit(100e6, alice);
    }

    function test_Deposit_ReceiveToDifferentAddress() public {
        vm.prank(alice);
        uint256 minted = ic.deposit(500e6, bob);

        assertEq(ic.balanceOf(alice), 0);
        assertEq(ic.balanceOf(bob), minted);
    }

    // ==========================================
    // WITHDRAW TESTS
    // ==========================================

    function test_Withdraw_BufferOnly() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        uint256 bal = ic.balanceOf(alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);

        assertApproxEqRel(usdcOut, 1000e6, 0.01e18);
        assertEq(ic.balanceOf(alice), 0);
    }

    function test_Withdraw_JIT_BurnsLPWhenBufferInsufficient() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 aliceShares = ic.balanceOf(alice);
        uint256 bigWithdraw = (aliceShares * 30) / 100;

        uint256 lpBefore = curveLp.totalSupply();

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bigWithdraw, alice, 0);

        assertGt(usdcOut, 0, "Should receive USDC via JIT LP burn");
        assertLt(curveLp.totalSupply(), lpBefore, "LP should be burned");
    }

    function test_Withdraw_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.withdraw(0, alice, 0);
    }

    function test_Withdraw_RevertsAfterEmergency() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);
        ic.deployToCurve();

        ic.emergencyWithdrawFromCurve();
        ic.unpause();

        assertTrue(ic.emergencyActive());

        uint256 bal = ic.balanceOf(alice);
        vm.expectRevert(InvarCoin.InvarCoin__UseLpWithdraw.selector);
        vm.prank(alice);
        ic.withdraw(bal, alice, 0);
    }

    function test_Withdraw_WorksAfterEmergencyCleared() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);
        ic.deployToCurve();

        // Seed pool with BEAR so remove_liquidity returns both tokens
        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        ic.emergencyWithdrawFromCurve();
        assertTrue(ic.emergencyActive());
        assertGt(bearToken.balanceOf(address(ic)), 0, "IC should hold BEAR after emergency");

        ic.unpause();

        ic.redeployToCurve(0);
        assertFalse(ic.emergencyActive());

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);
        assertGt(usdcOut, 0);
    }

    function test_RedeployToCurve_DeploysBothTokens() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);
        ic.deployToCurve();

        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        ic.emergencyWithdrawFromCurve();
        ic.unpause();

        uint256 bearBefore = bearToken.balanceOf(address(ic));
        uint256 lpBefore = curveLp.balanceOf(address(ic));
        uint256 assetsBefore = ic.totalAssets();

        ic.redeployToCurve(0);

        assertEq(bearToken.balanceOf(address(ic)), 0, "All BEAR should be deployed");
        assertGt(curveLp.balanceOf(address(ic)), lpBefore, "Should hold LP tokens");
        assertFalse(ic.emergencyActive(), "Emergency flag should be cleared");
        assertApproxEqRel(ic.totalAssets(), assetsBefore, 0.1e18, "Total assets should be preserved");
    }

    function test_RedeployToCurve_RevertsWithoutBear() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        vm.expectRevert(InvarCoin.InvarCoin__NothingToDeploy.selector);
        ic.redeployToCurve(0);
    }

    function test_RedeployToCurve_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ic.redeployToCurve(0);
    }

    function test_EmergencyLpWithdraw_WorksDuringEmergency() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);
        ic.deployToCurve();

        ic.emergencyWithdrawFromCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.emergencyLpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0, "Should receive USDC during emergency");
    }

    function test_EmergencyLpWithdraw_RevertsWhenNotEmergency() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        uint256 bal = ic.balanceOf(alice);
        vm.expectRevert(InvarCoin.InvarCoin__NotEmergency.selector);
        vm.prank(alice);
        ic.emergencyLpWithdraw(bal, 0, 0);
    }

    function test_Withdraw_RevertsWhenPaused() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        ic.pause();

        uint256 bal = ic.balanceOf(alice);
        vm.expectRevert();
        vm.prank(alice);
        ic.withdraw(bal, alice, 0);
    }

    function test_LpWithdraw_AllowedWhenPaused() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);
        ic.deployToCurve();

        ic.pause();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut + bearOut, 0);
    }

    function test_Withdraw_SlippageProtection() public {
        vm.prank(alice);
        ic.deposit(100e6, alice);

        uint256 bal = ic.balanceOf(alice);

        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        vm.prank(alice);
        ic.withdraw(bal, alice, type(uint256).max);
    }

    // ==========================================
    // LP WITHDRAWAL
    // ==========================================

    function test_LpWithdraw_ProRata() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcReturned, 0);
    }

    function test_LpWithdraw_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.lpWithdraw(0, 0, 0);
    }

    function test_LpWithdraw_SlippageProtection() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        vm.prank(alice);
        ic.lpWithdraw(bal, type(uint256).max, 0);
    }

    // ==========================================
    // DEPLOY TO CURVE
    // ==========================================

    function test_DeployToCurve_Basic() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 lpMinted = ic.deployToCurve();

        assertGt(lpMinted, 0);
        assertGt(curveLp.balanceOf(address(ic)), 0);
    }

    function test_DeployToCurve_RevertsWhenBelowThreshold() public {
        vm.prank(alice);
        ic.deposit(500e6, alice);

        vm.expectRevert(InvarCoin.InvarCoin__NothingToDeploy.selector);
        ic.deployToCurve();
    }

    function test_DeployToCurve_RevertsWhenPaused() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.pause();

        vm.expectRevert();
        ic.deployToCurve();
    }

    function test_DeployToCurve_RevertsOnSpotManipulation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        curve.setSpotDiscountBps(600);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.deployToCurve();
    }

    function test_DeployToCurve_AllowsNormalSpotDrift() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        curve.setSpotDiscountBps(100);

        ic.deployToCurve();
    }

    // ==========================================
    // HARVEST
    // ==========================================

    function test_Harvest_RevertsWithNoYield() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_Harvest_CurveYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        curve.setVirtualPrice(1.05e18);

        uint256 sInvarAssetsBefore = ic.balanceOf(address(sInvar));
        uint256 donated = ic.harvest();

        assertGt(donated, 0);
        assertGt(ic.balanceOf(address(sInvar)), sInvarAssetsBefore);
    }

    function test_Harvest_CurveYieldDonated() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        curve.setVirtualPrice(1.02e18);

        uint256 donated = ic.harvest();
        assertGt(donated, 0);
    }

    function test_Harvest_IgnoresPriceAppreciation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        // BEAR price rises 20% — lp_price goes up but virtual_price unchanged
        curve.setPriceMultiplier(1.2e18);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_Harvest_CapturesFeeYieldOnly() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        // 5% fee yield (VP up) + 20% price appreciation (multiplier up)
        curve.setVirtualPrice(1.05e18);
        curve.setPriceMultiplier(1.2e18);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 fullLpUsdc = (lpBal * curve.lp_price()) / 1e30;

        uint256 donated = ic.harvest();

        // Yield minted should reflect ~5% fee fraction of LP value, not the full 26% (1.05*1.2)
        uint256 supply = ic.totalSupply();
        uint256 assets = ic.totalAssets();
        uint256 yieldValue = (donated * assets) / supply;

        // Fee-only yield ≈ 5/105 of LP value. Allow 10% tolerance (mock linear math introduces ~8.7% deviation).
        uint256 expectedFeeYield = (fullLpUsdc * 5) / 105;
        assertApproxEqRel(yieldValue, expectedFeeYield, 0.1e18, "Yield should reflect fees only, not price moves");
    }

    // ==========================================
    // REPLENISH BUFFER
    // ==========================================

    function test_ReplenishBuffer_Basic() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        // Simulate buffer drain (e.g., external event that depletes USDC)
        uint256 localUsdc = usdc.balanceOf(address(ic));
        deal(address(usdc), address(ic), localUsdc / 10);

        uint256 usdcBefore = usdc.balanceOf(address(ic));
        ic.replenishBuffer();

        assertGt(usdc.balanceOf(address(ic)), usdcBefore);
    }

    function test_ReplenishBuffer_RevertsOnSpotManipulation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        deal(address(usdc), address(ic), 0);

        curve.setSpotDiscountBps(600);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.replenishBuffer();
    }

    // ==========================================
    // NAV: totalAssets
    // ==========================================

    function test_TotalAssets_LocalUsdcOnly() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        assertEq(ic.totalAssets(), 1000e6);
    }

    function test_TotalAssets_WithCurveAndLocalUsdc() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 total = ic.totalAssets();
        assertApproxEqRel(total, 20_000e6, 0.02e18);
    }

    // ==========================================
    // INFLATION ATTACK PROTECTION
    // ==========================================

    function test_InflationAttack_FirstDepositorCannotSteal() public {
        vm.prank(alice);
        uint256 aliceMinted = ic.deposit(1e6, alice);

        vm.prank(bob);
        uint256 bobMinted = ic.deposit(1000e6, bob);

        uint256 bobShareOfAssets = (ic.totalAssets() * bobMinted) / ic.totalSupply();

        assertGt(bobShareOfAssets, 990e6);
    }

    // ==========================================
    // EMERGENCY
    // ==========================================

    function test_EmergencyWithdrawFromCurve() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        ic.emergencyWithdrawFromCurve();

        assertTrue(ic.paused());
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_EmergencyWithdrawFromCurve_NAVPreserved() public {
        uint256 usdcIn = 10_000e6;
        uint256 bearIn = 10_000e18;
        usdc.mint(alice, usdcIn);
        bearToken.mint(alice, bearIn);

        vm.startPrank(alice);
        bearToken.approve(address(ic), bearIn);
        ic.lpDeposit(usdcIn, bearIn, alice, 0);
        vm.stopPrank();

        uint256 navBefore = ic.totalAssets();

        ic.emergencyWithdrawFromCurve();

        uint256 navAfter = ic.totalAssets();
        // Mock Curve values BEAR at 1:1 with USDC, but oracle prices at $0.80.
        // The important property: BEAR is counted, NAV doesn't collapse.
        assertApproxEqRel(navAfter, navBefore, 0.15e18, "NAV should be preserved after emergency");
    }

    function test_EmergencyWithdrawFromCurve_LpWithdrawReturnsBear() public {
        uint256 usdcIn = 10_000e6;
        uint256 bearIn = 10_000e18;
        usdc.mint(alice, usdcIn);
        bearToken.mint(alice, bearIn);

        vm.startPrank(alice);
        bearToken.approve(address(ic), bearIn);
        ic.lpDeposit(usdcIn, bearIn, alice, 0);
        vm.stopPrank();

        ic.emergencyWithdrawFromCurve();
        ic.unpause();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.emergencyLpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0, "Should return USDC");
        assertGt(bearOut, 0, "Should return raw BEAR post-emergency");
    }

    function test_EmergencyWithdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ic.emergencyWithdrawFromCurve();
    }

    // ==========================================
    // RESCUE TOKEN
    // ==========================================

    function test_RescueToken_CannotRescueCore() public {
        vm.expectRevert(InvarCoin.InvarCoin__CannotRescueCoreAsset.selector);
        ic.rescueToken(address(usdc), alice);
    }

    function test_RescueToken_CannotRescueCurveLp() public {
        vm.expectRevert(InvarCoin.InvarCoin__CannotRescueCoreAsset.selector);
        ic.rescueToken(address(curveLp), alice);
    }

    function test_RescueToken_CannotRescueBear() public {
        vm.expectRevert(InvarCoin.InvarCoin__CannotRescueCoreAsset.selector);
        ic.rescueToken(address(bearToken), alice);
    }

    function test_RescueToken_CanRescueRandom() public {
        MockUSDC6 randomToken = new MockUSDC6();
        randomToken.mint(address(ic), 100e6);

        ic.rescueToken(address(randomToken), alice);
        assertEq(randomToken.balanceOf(alice), 100e6);
    }

    // ==========================================
    // SET INTEGRATIONS
    // ==========================================

    function test_SetStakedInvarCoin_RevertsOnSecondCall() public {
        vm.expectRevert(InvarCoin.InvarCoin__AlreadySet.selector);
        ic.setStakedInvarCoin(makeAddr("newSInvar"));
    }

    function test_SetStakedInvarCoin_RevertsOnZeroAddress() public {
        InvarCoin fresh = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0)
        );
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAddress.selector);
        fresh.setStakedInvarCoin(address(0));
    }

    // ==========================================
    // ORACLE PRICE != $1.00
    // ==========================================

    function test_OracleAt080_CurvePositionValuation() public {
        oracle.updatePrice(80_000_000);

        vm.prank(alice);
        ic.deposit(20_000e6, alice);
        ic.deployToCurve();

        uint256 total = ic.totalAssets();
        assertGt(total, 0);
    }

    function test_TotalAssets_PessimisticLpPrice() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 navAtDefault = ic.totalAssets();

        // Crash oracle to $0.50 while Curve EMA stays stale-high
        oracle.updatePrice(50_000_000);

        uint256 navAfterCrash = ic.totalAssets();
        assertLt(navAfterCrash, navAtDefault, "Pessimistic LP price should lower NAV");
    }

    function test_Withdraw_ProRataDistribution() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        vm.prank(bob);
        ic.deposit(20_000e6, bob);

        ic.deployToCurve();

        uint256 aliceBal = ic.balanceOf(alice);
        uint256 bobBal = ic.balanceOf(bob);

        vm.prank(alice);
        uint256 aliceUsdc = ic.withdraw(aliceBal, alice, 0);

        vm.prank(bob);
        uint256 bobUsdc = ic.withdraw(bobBal, bob, 0);

        assertApproxEqRel(aliceUsdc, bobUsdc, 0.01e18, "Equal depositors should get equal withdrawals");
        assertApproxEqRel(aliceUsdc + bobUsdc, 40_000e6, 0.02e18, "Total withdrawn should approximate total deposited");
    }

    function test_Deposit_OptimisticLpPrice_PreventsDilution() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        // Pump oracle to $2.00 while Curve EMA stays stale-low
        oracle.updatePrice(200_000_000);

        uint256 supplyBefore = ic.totalSupply();

        // Bob deposits during stale EMA — optimistic NAV should give fewer shares
        vm.prank(bob);
        uint256 sharesMinted = ic.deposit(10_000e6, bob);

        // If NAV used stale-low EMA, bob gets ~1/3 of supply (10k of 30k)
        // With optimistic NAV (oracle-high), bob gets fewer shares
        uint256 bobFraction = (sharesMinted * 1e18) / (supplyBefore + sharesMinted);
        assertLt(bobFraction, 0.33e18, "Optimistic NAV should prevent deposit dilution");
    }

    // ==========================================
    // FULL LIFECYCLE
    // ==========================================

    function test_FullCycle_DepositDeployHarvestLpWithdraw() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice) / 2;
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        curve.setVirtualPrice(1.05e18);

        ic.harvest();

        assertGt(ic.balanceOf(address(sInvar)), stakeAmount);

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut,) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0);
    }

    function test_FullCycle_LpWithdrawAfterDeploy() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut,) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0);
        assertEq(ic.balanceOf(alice), 0);
    }

    // ==========================================
    // LP DEPOSIT
    // ==========================================

    function test_LpDeposit_Basic() public {
        uint256 usdcIn = 10_000e6;
        uint256 bearIn = 10_000e18;

        usdc.mint(alice, usdcIn);
        bearToken.mint(alice, bearIn);

        vm.startPrank(alice);
        bearToken.approve(address(ic), bearIn);
        uint256 minted = ic.lpDeposit(usdcIn, bearIn, alice, 0);
        vm.stopPrank();

        assertGt(minted, 0);
        assertEq(ic.balanceOf(alice), minted);
        assertGt(curveLp.balanceOf(address(ic)), 0);
    }

    function test_LpDeposit_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.lpDeposit(0, 0, alice, 0);
    }

    function test_LpDeposit_SlippageProtection() public {
        usdc.mint(alice, 10_000e6);
        bearToken.mint(alice, 10_000e18);

        vm.startPrank(alice);
        bearToken.approve(address(ic), 10_000e18);
        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        ic.lpDeposit(10_000e6, 10_000e18, alice, type(uint256).max);
        vm.stopPrank();
    }

    function test_LpDeposit_TracksCostBasis() public {
        assertEq(ic.curveLpCostVp(), 0);

        usdc.mint(alice, 10_000e6);
        bearToken.mint(alice, 10_000e18);

        vm.startPrank(alice);
        bearToken.approve(address(ic), 10_000e18);
        ic.lpDeposit(10_000e6, 10_000e18, alice, 0);
        vm.stopPrank();

        assertGt(ic.curveLpCostVp(), 0);
    }

    function test_LpDeposit_RevertsWhenPaused() public {
        ic.pause();

        vm.expectRevert();
        vm.prank(alice);
        ic.lpDeposit(1000e6, 0, alice, 0);
    }

    function test_LpDeposit_PessimisticPricing_BlocksArbitrage() public {
        // Alice seeds the vault with USDC (all stays as local buffer)
        vm.prank(alice);
        ic.deposit(100_000e6, alice);

        // Oracle crashes to $0.50 while Curve EMA stays stale-high
        // pessimistic LP price = min(oracle, EMA) = oracle ≈ 1.414 * vp
        // optimistic LP price  = max(oracle, EMA) = EMA = 2 * vp
        oracle.updatePrice(50_000_000);

        uint256 bobUsdc = 10_000e6;
        uint256 bobBear = 10_000e18;
        usdc.mint(bob, bobUsdc);
        bearToken.mint(bob, bobBear);

        vm.startPrank(bob);
        bearToken.approve(address(ic), bobBear);
        ic.lpDeposit(bobUsdc, bobBear, bob, 0);

        uint256 bobShares = ic.balanceOf(bob);
        uint256 usdcOut = ic.withdraw(bobShares, bob, 0);
        vm.stopPrank();

        // At $0.50, 10k BEAR ≈ $5k. Total input ≈ $15k.
        // With pessimistic incoming LP pricing, Bob must not profit.
        assertLe(usdcOut, bobUsdc + 10_000e6 / 2, "lpDeposit must not enable risk-free arbitrage");
    }

    // ==========================================
    // CONSTRUCTOR VALIDATION
    // ==========================================

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAddress.selector);
        new InvarCoin(address(0), address(bearToken), address(curveLp), address(curve), address(oracle), address(0));
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_DepositWithdrawRoundTrip(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 500_000e6);

        vm.prank(alice);
        uint256 minted = ic.deposit(amount, alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(minted, alice, 0);

        assertGe(usdcOut, amount - 1, "Round trip lost more than 1 wei");
    }

    function testFuzz_EqualDepositsEqualShares(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 100_000e6);

        vm.prank(alice);
        uint256 aliceShares = ic.deposit(amount, alice);

        vm.prank(bob);
        uint256 bobShares = ic.deposit(amount, bob);

        assertApproxEqRel(aliceShares, bobShares, 0.01e18, "Equal deposits should get equal shares");
    }

    function testFuzz_LpWithdrawProRata(
        uint256 depositAmount
    ) public {
        depositAmount = bound(depositAmount, 20_000e6, 500_000e6);

        vm.prank(alice);
        ic.deposit(depositAmount, alice);

        ic.deployToCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(bal, 0, 0);

        uint256 bearValueUsdc = (bearReturned * ORACLE_PRICE) / 1e20;
        uint256 totalValueReturned = usdcReturned + bearValueUsdc;

        assertGe(totalValueReturned, depositAmount * 99 / 100, "Whale exit returned less than 99%");
    }

    function testFuzz_DeployToCurve_PreservesNAV(
        uint256 amount
    ) public {
        amount = bound(amount, 20_000e6, 500_000e6);

        vm.prank(alice);
        ic.deposit(amount, alice);

        uint256 navBefore = ic.totalAssets();
        ic.deployToCurve();
        uint256 navAfter = ic.totalAssets();

        assertApproxEqRel(navAfter, navBefore, 0.01e18, "Deploy should preserve NAV within 1%");
    }

    function testFuzz_DepositProducesPositiveShares(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 1_000_000e6);

        vm.prank(alice);
        uint256 shares = ic.deposit(amount, alice);

        assertGt(shares, 0, "Deposit should produce positive shares");
    }

    function testFuzz_WithdrawNeverExceedsTotalAssets(
        uint256 fraction
    ) public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice);

        fraction = bound(fraction, 1, 1e18);
        uint256 bal = ic.balanceOf(alice);
        uint256 toWithdraw = (bal * fraction) / 1e18;
        if (toWithdraw == 0) {
            return;
        }

        uint256 totalAssetsBefore = ic.totalAssets();

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(toWithdraw, alice, 0);

        assertLe(usdcOut, totalAssetsBefore, "Withdraw should never exceed total assets");
    }

    // ==========================================
    // COST BASIS TRACKING
    // ==========================================

    function test_DeployToCurve_TracksCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        assertEq(ic.curveLpCostVp(), 0);

        ic.deployToCurve();

        assertGt(ic.curveLpCostVp(), 0);
    }

    function test_ReplenishBuffer_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        deal(address(usdc), address(ic), 0);

        uint256 costBefore = ic.curveLpCostVp();
        ic.replenishBuffer();

        assertLt(ic.curveLpCostVp(), costBefore);
    }

    function test_LpWithdraw_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 costBefore = ic.curveLpCostVp();
        assertGt(costBefore, 0);

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        ic.lpWithdraw(bal, 0, 0);

        assertEq(ic.curveLpCostVp(), 0);
    }

    function test_EmergencyWithdrawFromCurve_ResetsCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();
        assertGt(ic.curveLpCostVp(), 0);

        ic.emergencyWithdrawFromCurve();

        assertEq(ic.curveLpCostVp(), 0);
    }

    function test_ReplenishBuffer_PreservesCurveYield() public {
        vm.startPrank(bob);
        ic.deposit(1000e6, bob);
        ic.approve(address(sInvar), ic.balanceOf(bob));
        sInvar.deposit(ic.balanceOf(bob), bob);
        vm.stopPrank();

        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();
        curve.setVirtualPrice(1.01e18);

        uint256 toWithdraw = ic.balanceOf(alice) / 50;

        uint256 snap = vm.snapshot();
        uint256 yieldStandalone = ic.harvest();
        vm.revertTo(snap);

        uint256 sInvarBal = ic.balanceOf(address(sInvar));
        vm.prank(alice);
        ic.withdraw(toWithdraw, alice, 0);
        ic.replenishBuffer();
        try ic.harvest() {}
        catch (bytes memory reason) {
            require(bytes4(reason) == InvarCoin.InvarCoin__NoYield.selector, "Unexpected harvest error");
        }
        uint256 totalCaptured = ic.balanceOf(address(sInvar)) - sInvarBal;

        assertGe(totalCaptured, yieldStandalone, "yield must not be lost across withdraw + replenish");
    }

    function test_LpWithdraw_SurvivesStaleOracle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);
        ic.deployToCurve();

        oracle.setUpdatedAt(block.timestamp - 25 hours);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(shares, 0, 0);

        assertGt(usdcOut + bearOut, 0, "lpWithdraw should succeed despite stale oracle");
    }

    function test_Withdraw_RevertsOnStaleOracle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);
        ic.deployToCurve();

        curve.setVirtualPrice(1.05e18);
        oracle.setUpdatedAt(block.timestamp - 25 hours);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        ic.withdraw(shares, alice, 0);
    }

    function test_Harvest_RevertsOnStaleOracle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        curve.setVirtualPrice(1.05e18);

        oracle.setUpdatedAt(block.timestamp - 25 hours);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        ic.harvest();
    }

}

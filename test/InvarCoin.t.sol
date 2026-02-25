// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    uint256 public spotPremiumBps;

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

    function setSpotPremiumBps(
        uint256 _premiumBps
    ) external {
        spotPremiumBps = _premiumBps;
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

        uint256 bearAsUsdc = amounts[1] * priceMultiplier / 1e30;
        uint256 totalUsdc = amounts[0] + bearAsUsdc;
        uint256 lpMinted = totalUsdc * 1e30 / _lpPrice();
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
            uint256 bearAsUsdc = bearShare * priceMultiplier / 1e30;
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

    function _lpPrice() internal view returns (uint256) {
        return 2 * virtualPrice * Math.sqrt(priceMultiplier * 1e18) / 1e18;
    }

    function lp_price() external view returns (uint256) {
        return _lpPrice();
    }

    function calc_token_amount(
        uint256[2] calldata amounts,
        bool
    ) external view returns (uint256) {
        uint256 bearAsUsdc = amounts[1] * priceMultiplier / 1e30;
        uint256 totalUsdc = amounts[0] + bearAsUsdc;
        uint256 lp = totalUsdc * 1e30 / _lpPrice();
        if (spotDiscountBps > 0) {
            lp = lp * (10_000 - spotDiscountBps) / 10_000;
        }
        if (spotPremiumBps > 0) {
            lp = lp * (10_000 + spotPremiumBps) / 10_000;
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
            uint256 bearAsUsdc = bearShare * priceMultiplier / 1e30;
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

contract MockCurveGauge {

    IERC20 public lpToken;
    mapping(address => uint256) public balanceOf;

    constructor(
        address _lpToken
    ) {
        lpToken = IERC20(_lpToken);
    }

    function deposit(
        uint256 amount
    ) external {
        lpToken.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(
        uint256 amount
    ) external {
        balanceOf[msg.sender] -= amount;
        lpToken.transfer(msg.sender, amount);
    }

    function claim_rewards() external {}

}

contract MockCrvMinter {

    address public lastGauge;
    uint256 public mintCallCount;

    function mint(
        address gauge
    ) external {
        lastGauge = gauge;
        mintCallCount++;
    }

}

contract MockBrickedGauge {

    IERC20 public lpToken;
    mapping(address => uint256) public balanceOf;
    bool public bricked;

    constructor(
        address _lpToken
    ) {
        lpToken = IERC20(_lpToken);
    }

    function deposit(
        uint256 amount
    ) external {
        require(!bricked, "gauge bricked");
        lpToken.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(
        uint256 amount
    ) external {
        require(!bricked, "gauge bricked");
        balanceOf[msg.sender] -= amount;
        lpToken.transfer(msg.sender, amount);
    }

    function setBricked(
        bool _bricked
    ) external {
        bricked = _bricked;
    }

    function claim_rewards() external {}

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

        curve.setPriceMultiplier(1.2e18);

        ic = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
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
        uint256 minted = ic.deposit(1000e6, alice, 0);

        assertGt(minted, 0);
        assertEq(ic.balanceOf(alice), minted);
        assertEq(ic.totalAssets(), 1000e6);
    }

    function test_Deposit_SecondDepositorFairShare() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice, 0);

        vm.prank(bob);
        uint256 minted = ic.deposit(1000e6, bob, 0);

        uint256 aliceBal = ic.balanceOf(alice);
        uint256 bobBal = ic.balanceOf(bob);
        assertApproxEqRel(aliceBal, bobBal, 0.01e18);
    }

    function test_Deposit_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.deposit(0, alice, 0);
    }

    function test_Deposit_RevertsWhenPaused() public {
        ic.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        ic.deposit(100e6, alice, 0);
    }

    function test_Deposit_ReceiveToDifferentAddress() public {
        vm.prank(alice);
        uint256 minted = ic.deposit(500e6, bob, 0);

        assertEq(ic.balanceOf(alice), 0);
        assertEq(ic.balanceOf(bob), minted);
    }

    // ==========================================
    // WITHDRAW TESTS
    // ==========================================

    function test_Withdraw_BufferOnly() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice, 0);

        uint256 bal = ic.balanceOf(alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);

        assertApproxEqRel(usdcOut, 1000e6, 0.01e18);
        assertEq(ic.balanceOf(alice), 0);
    }

    function test_Withdraw_JIT_BurnsLPWhenBufferInsufficient() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

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
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

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
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

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
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

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
        ic.deposit(10_000e6, alice, 0);

        vm.expectRevert(InvarCoin.InvarCoin__NothingToDeploy.selector);
        ic.redeployToCurve(0);
    }

    function test_RedeployToCurve_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.redeployToCurve(0);
    }

    function test_LpWithdraw_WorksDuringEmergency() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

        ic.emergencyWithdrawFromCurve();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0, "Should receive USDC during emergency");
    }

    function test_Withdraw_RevertsWhenPaused() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice, 0);

        ic.pause();

        uint256 bal = ic.balanceOf(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        ic.withdraw(bal, alice, 0);
    }

    function test_LpWithdraw_AllowedWhenPaused() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

        ic.pause();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut + bearOut, 0);
    }

    function test_Withdraw_SlippageProtection() public {
        vm.prank(alice);
        ic.deposit(100e6, alice, 0);

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
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

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
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

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
        ic.deposit(20_000e6, alice, 0);

        uint256 lpMinted = ic.deployToCurve(0);

        assertGt(lpMinted, 0);
        assertGt(curveLp.balanceOf(address(ic)), 0);
    }

    function test_DeployToCurve_RevertsWhenBelowThreshold() public {
        vm.prank(alice);
        ic.deposit(500e6, alice, 0);

        vm.expectRevert(InvarCoin.InvarCoin__NothingToDeploy.selector);
        ic.deployToCurve(0);
    }

    function test_DeployToCurve_RevertsWhenPaused() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        ic.deployToCurve(0);
    }

    function test_DeployToCurve_RevertsOnSpotManipulation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        curve.setSpotDiscountBps(600);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.deployToCurve(0);
    }

    function test_DeployToCurve_AllowsNormalSpotDrift() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        curve.setSpotDiscountBps(30);

        ic.deployToCurve(0);
    }

    // ==========================================
    // HARVEST
    // ==========================================

    function test_Harvest_RevertsWithNoYield() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice, 0);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_Harvest_CurveYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);

        uint256 sInvarAssetsBefore = ic.balanceOf(address(sInvar));
        uint256 donated = ic.harvest();

        assertGt(donated, 0);
        assertGt(ic.balanceOf(address(sInvar)), sInvarAssetsBefore);
    }

    function test_Harvest_CurveYieldDonated() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        curve.setVirtualPrice(1.02e18);

        uint256 donated = ic.harvest();
        assertGt(donated, 0);
    }

    function test_Harvest_IgnoresPriceAppreciation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        // BEAR price rises 20% — lp_price goes up but virtual_price unchanged
        curve.setPriceMultiplier(1.2e18);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_Harvest_CapturesFeeYieldOnly() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

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

    function test_Harvest_IgnoresDonatedLpTokens() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        uint256 sInvarBefore = ic.balanceOf(address(sInvar));

        // Attacker donates LP tokens directly to InvarCoin
        curveLp.mint(address(ic), 5000e18);

        // harvest should see no yield — VP hasn't changed, only balanceOf increased
        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();

        assertEq(ic.balanceOf(address(sInvar)), sInvarBefore, "No INVAR should be minted from donation");
    }

    function test_Harvest_DonationDoesNotAmplifyRealYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        // Record legitimate yield with no donation
        curve.setVirtualPrice(1.05e18);
        uint256 yieldWithout = ic.harvest();

        // Reset: re-deposit and deploy fresh
        curve.setVirtualPrice(1e18);
        vm.prank(bob);
        ic.deposit(20_000e6, bob, 0);
        ic.deployToCurve(0);

        // Donate LP then trigger same VP growth
        curveLp.mint(address(ic), 50_000e18);
        curve.setVirtualPrice(1.05e18);
        uint256 yieldWith = ic.harvest();

        // Yield should be based on tracked LP, not inflated balanceOf
        // The second harvest covers more tracked LP (bob's deposit added more),
        // but the donated 50k LP should not contribute
        assertLt(yieldWith, yieldWithout * 3, "Donated LP must not amplify yield disproportionately");
    }

    function test_Harvest_DonationAttackNotProfitable() public {
        // Setup: Alice deposits and stakes, buffer deployed to Curve
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        // Attacker (bob) deposits a small amount and stakes to capture yield
        vm.prank(bob);
        uint256 bobShares = ic.deposit(1000e6, bob, 0);
        vm.startPrank(bob);
        ic.approve(address(sInvar), bobShares);
        sInvar.deposit(bobShares, bob);
        vm.stopPrank();

        uint256 bobStakedBefore = sInvar.balanceOf(bob);

        // Attacker donates LP tokens (simulating buying cheap at spot)
        curveLp.mint(address(ic), 10_000e18);

        // Even with VP unchanged, attacker tries to harvest
        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();

        // Bob's staked position should be unchanged
        assertEq(sInvar.balanceOf(bob), bobStakedBefore, "Attacker should not gain from donation");
    }

    function test_TrackedLpBalance_TracksCorrectly() public {
        assertEq(ic.trackedLpBalance(), 0);

        // Deploy adds to tracked balance
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);
        uint256 tracked = ic.trackedLpBalance();
        assertEq(tracked, curveLp.balanceOf(address(ic)), "Tracked should match actual after deploy");

        // Donation increases balanceOf but NOT tracked
        curveLp.mint(address(ic), 1000e18);
        assertEq(ic.trackedLpBalance(), tracked, "Tracked should NOT increase from donation");
        assertGt(curveLp.balanceOf(address(ic)), tracked, "balanceOf should exceed tracked");

        // Emergency withdraw resets tracked to 0
        ic.emergencyWithdrawFromCurve();
        assertEq(ic.trackedLpBalance(), 0, "Tracked should be zero after emergency");
    }

    function test_TrackedLpBalance_ProportionalReductionOnWithdraw() public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 trackedBefore = ic.trackedLpBalance();
        uint256 costBefore = ic.curveLpCostVp();

        // Donate LP to create divergence between balanceOf and trackedLpBalance
        curveLp.mint(address(ic), trackedBefore);
        assertEq(curveLp.balanceOf(address(ic)), trackedBefore * 2);

        // Alice withdraws 50% of her shares
        uint256 aliceShares = ic.balanceOf(alice);
        vm.prank(alice);
        ic.withdraw(aliceShares / 2, alice, 0);

        uint256 trackedAfter = ic.trackedLpBalance();
        uint256 costAfter = ic.curveLpCostVp();

        // Both should decrease by the same proportion (lpShare / lpBal)
        // lpBal was 2x tracked, lpShare ~50% of lpBal, so reduction ~50% of each
        assertGt(trackedAfter, 0, "Tracked balance must not be wiped to zero");
        assertApproxEqRel(
            trackedAfter * 1e18 / trackedBefore,
            costAfter * 1e18 / costBefore,
            0.01e18,
            "Tracked and cost basis must decrease proportionally"
        );
    }

    function test_TrackedLpBalance_HarvestSurvivesDonationPlusWithdraw() public {
        // Setup: Alice and Bob deposit, deploy to Curve, stake for yield
        vm.prank(alice);
        ic.deposit(50_000e6, alice, 0);
        vm.prank(bob);
        ic.deposit(50_000e6, bob, 0);
        ic.deployToCurve(0);

        uint256 stakeAmount = ic.balanceOf(bob);
        vm.startPrank(bob);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, bob);
        vm.stopPrank();

        // Donate LP equal to tracked balance
        uint256 trackedBefore = ic.trackedLpBalance();
        curveLp.mint(address(ic), trackedBefore);

        // Alice withdraws all her shares (50% of supply)
        uint256 aliceShares = ic.balanceOf(alice);
        vm.prank(alice);
        ic.withdraw(aliceShares, alice, 0);

        // trackedLpBalance must remain > 0 for harvest to work
        assertGt(ic.trackedLpBalance(), 0, "Tracked LP must survive donation + withdraw");

        // VP growth should still produce harvestable yield for remaining stakers
        curve.setVirtualPrice(1.05e18);
        uint256 harvested = ic.harvest();
        assertGt(harvested, 0, "Harvest must still work after donation + withdraw");
    }

    function test_TrackedLpBalance_ProportionalReductionOnReplenish() public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 trackedBefore = ic.trackedLpBalance();
        uint256 costBefore = ic.curveLpCostVp();

        // Donate LP via real add_liquidity so pool reserves stay consistent
        address donor = makeAddr("donor");
        usdc.mint(donor, 10_000e6);
        vm.startPrank(donor);
        usdc.approve(address(curve), type(uint256).max);
        uint256 donatedLp = curve.add_liquidity([uint256(10_000e6), 0], 0);
        curveLp.transfer(address(ic), donatedLp);
        vm.stopPrank();

        // Drain buffer to trigger replenish
        uint256 localUsdc = usdc.balanceOf(address(ic));
        deal(address(usdc), address(ic), localUsdc / 10);
        ic.replenishBuffer(0);

        uint256 trackedAfter = ic.trackedLpBalance();
        uint256 costAfter = ic.curveLpCostVp();

        // Both must decrease by the same proportion
        assertGt(trackedAfter, 0, "Tracked balance must not be wiped to zero");
        assertApproxEqRel(
            trackedAfter * 1e18 / trackedBefore,
            costAfter * 1e18 / costBefore,
            0.01e18,
            "Replenish must reduce tracked and cost basis proportionally"
        );
    }

    function test_TrackedLpBalance_ProportionalReductionOnLpWithdraw() public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);
        vm.prank(bob);
        ic.deposit(100_000e6, bob, 0);
        ic.deployToCurve(0);

        uint256 trackedBefore = ic.trackedLpBalance();
        uint256 costBefore = ic.curveLpCostVp();

        // Donate LP
        curveLp.mint(address(ic), trackedBefore);

        // Alice uses lpWithdraw for 50% of supply
        uint256 aliceShares = ic.balanceOf(alice);
        vm.prank(alice);
        ic.lpWithdraw(aliceShares, 0, 0);

        uint256 trackedAfter = ic.trackedLpBalance();
        uint256 costAfter = ic.curveLpCostVp();

        assertGt(trackedAfter, 0, "Tracked balance must not be wiped to zero");
        assertApproxEqRel(
            trackedAfter * 1e18 / trackedBefore,
            costAfter * 1e18 / costBefore,
            0.01e18,
            "lpWithdraw must reduce tracked and cost basis proportionally"
        );
    }

    // ==========================================
    // REPLENISH BUFFER
    // ==========================================

    function test_ReplenishBuffer_Basic() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        // Simulate buffer drain (e.g., external event that depletes USDC)
        uint256 localUsdc = usdc.balanceOf(address(ic));
        deal(address(usdc), address(ic), localUsdc / 10);

        uint256 usdcBefore = usdc.balanceOf(address(ic));
        ic.replenishBuffer(0);

        assertGt(usdc.balanceOf(address(ic)), usdcBefore);
    }

    function test_ReplenishBuffer_RevertsOnSpotManipulation() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        deal(address(usdc), address(ic), 0);

        curve.setSpotDiscountBps(600);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.replenishBuffer(0);
    }

    // ==========================================
    // NAV: totalAssets
    // ==========================================

    function test_TotalAssets_LocalUsdcOnly() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice, 0);

        assertEq(ic.totalAssets(), 1000e6);
    }

    function test_TotalAssets_WithCurveAndLocalUsdc() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        uint256 total = ic.totalAssets();
        assertApproxEqRel(total, 20_000e6, 0.02e18);
    }

    // ==========================================
    // INFLATION ATTACK PROTECTION
    // ==========================================

    function test_InflationAttack_FirstDepositorCannotSteal() public {
        vm.prank(alice);
        uint256 aliceMinted = ic.deposit(1e6, alice, 0);

        vm.prank(bob);
        uint256 bobMinted = ic.deposit(1000e6, bob, 0);

        uint256 bobShareOfAssets = (ic.totalAssets() * bobMinted) / ic.totalSupply();

        assertGt(bobShareOfAssets, 990e6);
    }

    // ==========================================
    // EMERGENCY
    // ==========================================

    function test_EmergencyWithdrawFromCurve() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

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
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(bal, 0, 0);

        assertGt(usdcOut, 0, "Should return USDC");
        assertGt(bearOut, 0, "Should return raw BEAR post-emergency");
    }

    function test_EmergencyWithdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.emergencyWithdrawFromCurve();
    }

    function test_EmergencyWithdrawFromCurve_WorksWhenAlreadyPaused() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        ic.pause();
        assertTrue(ic.paused());

        ic.emergencyWithdrawFromCurve();

        assertTrue(ic.paused());
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_RedeployToCurve_WorksWhenPaused() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        ic.emergencyWithdrawFromCurve();

        assertTrue(ic.paused());
        ic.redeployToCurve(0);
        assertFalse(ic.emergencyActive());
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
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
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
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 total = ic.totalAssets();
        assertGt(total, 0);
    }

    function test_TotalAssets_PessimisticLpPrice() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        uint256 navAtDefault = ic.totalAssets();

        // Crash oracle to $0.50 while Curve EMA stays stale-high
        oracle.updatePrice(50_000_000);

        uint256 navAfterCrash = ic.totalAssets();
        assertLt(navAfterCrash, navAtDefault, "Pessimistic LP price should lower NAV");
    }

    function test_Withdraw_ProRataDistribution() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        vm.prank(bob);
        ic.deposit(20_000e6, bob, 0);

        ic.deployToCurve(0);

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
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        // Pump oracle to $2.00 while Curve EMA stays stale-low
        oracle.updatePrice(200_000_000);

        uint256 supplyBefore = ic.totalSupply();

        // Bob deposits during stale EMA — optimistic NAV should give fewer shares
        vm.prank(bob);
        uint256 sharesMinted = ic.deposit(10_000e6, bob, 0);

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
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice) / 2;
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

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
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

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

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        ic.lpDeposit(1000e6, 0, alice, 0);
    }

    function test_LpDeposit_PessimisticPricing_BlocksArbitrage() public {
        // Alice seeds the vault with USDC (all stays as local buffer)
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);

        // Oracle crashes to $0.50, pool spot follows
        // pessimistic LP price = min(oracle, EMA) ≈ 1.414 * vp
        oracle.updatePrice(50_000_000);
        curve.setPriceMultiplier(0.5e18);

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
        new InvarCoin(
            address(0), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
        );
    }

    // ==========================================
    // FUZZ TESTS
    // ==========================================

    function testFuzz_DepositWithdrawRoundTrip(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 500_000e6);

        vm.prank(alice);
        uint256 minted = ic.deposit(amount, alice, 0);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(minted, alice, 0);

        assertGe(usdcOut, amount - 1, "Round trip lost more than 1 wei");
    }

    function testFuzz_EqualDepositsEqualShares(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 100_000e6);

        vm.prank(alice);
        uint256 aliceShares = ic.deposit(amount, alice, 0);

        vm.prank(bob);
        uint256 bobShares = ic.deposit(amount, bob, 0);

        assertApproxEqRel(aliceShares, bobShares, 0.01e18, "Equal deposits should get equal shares");
    }

    function testFuzz_LpWithdrawProRata(
        uint256 depositAmount
    ) public {
        depositAmount = bound(depositAmount, 20_000e6, 500_000e6);

        vm.prank(alice);
        ic.deposit(depositAmount, alice, 0);

        ic.deployToCurve(0);

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
        ic.deposit(amount, alice, 0);

        uint256 navBefore = ic.totalAssets();
        ic.deployToCurve(0);
        uint256 navAfter = ic.totalAssets();

        assertApproxEqRel(navAfter, navBefore, 0.01e18, "Deploy should preserve NAV within 1%");
    }

    function testFuzz_DepositProducesPositiveShares(
        uint256 amount
    ) public {
        amount = bound(amount, 1e6, 1_000_000e6);

        vm.prank(alice);
        uint256 shares = ic.deposit(amount, alice, 0);

        assertGt(shares, 0, "Deposit should produce positive shares");
    }

    function testFuzz_WithdrawNeverExceedsTotalAssets(
        uint256 fraction
    ) public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);

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
        ic.deposit(20_000e6, alice, 0);

        assertEq(ic.curveLpCostVp(), 0);

        ic.deployToCurve(0);

        assertGt(ic.curveLpCostVp(), 0);
    }

    function test_ReplenishBuffer_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        deal(address(usdc), address(ic), 0);

        uint256 costBefore = ic.curveLpCostVp();
        ic.replenishBuffer(0);

        assertLt(ic.curveLpCostVp(), costBefore);
    }

    function test_LpWithdraw_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);

        uint256 costBefore = ic.curveLpCostVp();
        assertGt(costBefore, 0);

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        ic.lpWithdraw(bal, 0, 0);

        assertEq(ic.curveLpCostVp(), 0);
    }

    function test_EmergencyWithdrawFromCurve_ResetsCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);
        assertGt(ic.curveLpCostVp(), 0);

        ic.emergencyWithdrawFromCurve();

        assertEq(ic.curveLpCostVp(), 0);
    }

    function test_ReplenishBuffer_PreservesCurveYield() public {
        vm.startPrank(bob);
        ic.deposit(1000e6, bob, 0);
        ic.approve(address(sInvar), ic.balanceOf(bob));
        sInvar.deposit(ic.balanceOf(bob), bob);
        vm.stopPrank();

        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        ic.deployToCurve(0);
        curve.setVirtualPrice(1.004e18);

        uint256 toWithdraw = ic.balanceOf(alice) / 50;

        uint256 snap = vm.snapshot();
        uint256 yieldStandalone = ic.harvest();
        vm.revertTo(snap);

        uint256 sInvarBal = ic.balanceOf(address(sInvar));
        vm.prank(alice);
        ic.withdraw(toWithdraw, alice, 0);
        ic.replenishBuffer(0);
        try ic.harvest() {}
        catch (bytes memory reason) {
            require(bytes4(reason) == InvarCoin.InvarCoin__NoYield.selector, "Unexpected harvest error");
        }
        uint256 totalCaptured = ic.balanceOf(address(sInvar)) - sInvarBal;

        assertLe(
            yieldStandalone - totalCaptured,
            yieldStandalone / 50 + 1,
            "yield leakage bounded by withdrawn share fraction"
        );
    }

    function test_LpWithdraw_SurvivesStaleOracleWithPendingYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);
        oracle.setUpdatedAt(block.timestamp - 25 hours);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(shares, 0, 0);

        assertGt(usdcOut + bearOut, 0, "lpWithdraw should succeed despite stale oracle + pending yield");
    }

    function test_Withdraw_SucceedsWithStaleOracleAndPendingYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);
        oracle.setUpdatedAt(block.timestamp - 25 hours);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);

        assertGt(usdcOut, 0, "withdraw should succeed despite stale oracle + pending yield");
    }

    function test_DeployToCurve_SucceedsWithStaleOracle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        oracle.setUpdatedAt(block.timestamp - 25 hours);

        ic.deployToCurve(0);
        assertGt(curveLp.balanceOf(address(ic)), 0, "deployToCurve should succeed with stale oracle");
    }

    function test_Harvest_RevertsOnStaleOracle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);

        oracle.setUpdatedAt(block.timestamp - 25 hours);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        ic.harvest();
    }

    // ==========================================
    // DECIMAL PRECISION TESTS
    // Uses prices with exact integer square roots
    // to verify conversion constants (1e20, 1e28, 1e30)
    // ==========================================

    function test_Precision_BearToUsdc_AtPointEightyOne() public {
        // 1000 BEAR at $0.81 each = exactly $810
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        bearToken.mint(address(ic), 1000e18);

        assertEq(ic.totalAssets(), 810e6, "1000 BEAR @ $0.81 = $810");
    }

    function test_Precision_BearToUsdc_AtOneFortyFour() public {
        // 500 BEAR at $1.44 each = exactly $720
        oracle.updatePrice(144_000_000);
        curve.setPriceMultiplier(1.44e18);
        bearToken.mint(address(ic), 500e18);

        assertEq(ic.totalAssets(), 720e6, "500 BEAR @ $1.44 = $720");
    }

    function test_Precision_BearToUsdc_DustRoundsToZero() public {
        // 1 wei BEAR at $1.20: 1 * 120_000_000 / 1e20 = 0
        bearToken.mint(address(ic), 1);

        assertEq(ic.totalAssets(), 0, "1 wei BEAR rounds to 0 USDC");
    }

    function test_Precision_BearToUsdc_MinimumNonZero() public {
        // At $1.20: bearBal * 120_000_000 / 1e20 >= 1
        // Threshold: ceil(1e20 / 1.2e8) = 833_333_333_334 wei
        bearToken.mint(address(ic), 833_333_333_333);
        assertEq(ic.totalAssets(), 0, "Below threshold = 0");

        bearToken.mint(address(ic), 1);
        assertEq(ic.totalAssets(), 1, "At threshold = 1 USDC wei");
    }

    function test_Precision_OracleLpPrice_ExactSqrt() public {
        // $0.81: sqrt(81_000_000 * 1e28) = sqrt(81e34) = 9e17
        // oracleLpPrice = 2 * 1e18 * 9e17 / 1e18 = 1.8e18
        // 1000 LP at $1.80 = $1800
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        curveLp.mint(address(ic), 1000e18);

        assertEq(ic.totalAssets(), 1800e6, "1000 LP @ $1.80 = $1800");
    }

    function test_Precision_OracleLpPrice_WithVpGrowth() public {
        // $0.81 with vp=1.05: lpPrice = 2 * 1.05 * 0.9 = $1.89
        // 1000 LP at $1.89 = $1890
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        curve.setVirtualPrice(1.05e18);
        curveLp.mint(address(ic), 1000e18);

        assertEq(ic.totalAssets(), 1890e6, "1000 LP @ vp=1.05, price=$0.81 = $1890");
    }

    function test_Precision_OracleLpPrice_HigherPrice() public {
        // $1.44: sqrt(144_000_000 * 1e28) = sqrt(144e34) = 12e17 = 1.2e18
        // oracleLpPrice = 2 * 1e18 * 1.2e18 / 1e18 = 2.4e18
        // 500 LP at $2.40 = $1200
        oracle.updatePrice(144_000_000);
        curve.setPriceMultiplier(1.44e18);
        curveLp.mint(address(ic), 500e18);

        assertEq(ic.totalAssets(), 1200e6, "500 LP @ $2.40 = $1200");
    }

    function test_Precision_LpToUsdc_DustRoundsToZero() public {
        // 1 wei LP at $1.80: 1 * 1.8e18 / 1e30 = 0
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        curveLp.mint(address(ic), 1);

        assertEq(ic.totalAssets(), 0, "1 wei LP rounds to 0 USDC");
    }

    function test_Precision_MixedAssets() public {
        // 500 USDC + 1000 BEAR @ $0.81 + 500 LP @ $1.80
        // = 500 + 810 + 900 = $2210
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        usdc.mint(address(ic), 500e6);
        bearToken.mint(address(ic), 1000e18);
        curveLp.mint(address(ic), 500e18);

        assertEq(ic.totalAssets(), 2210e6, "Mixed USDC+BEAR+LP = $2210");
    }

    function test_Precision_LpDeposit_FullDecimalChain() public {
        // lpDeposit 1000 BEAR at $0.81, no USDC
        // BEAR→USDC: 1000e18 * 81_000_000 / 1e20 = 810e6
        // LP minted: 810e6 * 1e30 / 1.8e18 = 450e18
        // LP value (pessimistic): 450e18 * 1.8e18 / 1e30 = 810e6
        // Shares (first deposit): 810e6 * (0 + 1e18) / (0 + 1e6) = 810e18
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        bearToken.mint(alice, 1000e18);
        vm.startPrank(alice);
        bearToken.approve(address(ic), 1000e18);
        uint256 shares = ic.lpDeposit(0, 1000e18, alice, 0);
        vm.stopPrank();

        assertEq(shares, 810e18, "lpDeposit 1000 BEAR @ $0.81 = 810e18 shares");
    }

    function test_Precision_LpDeposit_MixedInputs() public {
        // lpDeposit 500 USDC + 500 BEAR at $1.44
        // BEAR→USDC: 500e18 * 144_000_000 / 1e20 = 720e6
        // Total USDC value: 500e6 + 720e6 = 1220e6
        // lpPrice = 2 * sqrt(1.44) = 2 * 1.2 = 2.4e18
        // LP minted: 1220e6 * 1e30 / 2.4e18 = 508_333_333_333_333_333_333 (~508.33e18)
        // LP value: 508.33e18 * 2.4e18 / 1e30 = 1219_999_999 (1220e6 - 1 from rounding)
        // Shares: 1219_999_999 * 1e18 / 1e6 = 1_219_999_999e12
        oracle.updatePrice(144_000_000);
        curve.setPriceMultiplier(1.44e18);

        usdc.mint(alice, 500e6);
        bearToken.mint(alice, 500e18);
        vm.startPrank(alice);
        usdc.approve(address(ic), 500e6);
        bearToken.approve(address(ic), 500e18);
        uint256 shares = ic.lpDeposit(500e6, 500e18, alice, 0);
        vm.stopPrank();

        // 1220e6 round-trips through LP pricing with 1 wei rounding loss
        assertApproxEqAbs(shares, 1220e18, 1e18, "lpDeposit 500 USDC + 500 BEAR @ $1.44");
        assertLe(shares, 1220e18, "Rounding must favor protocol");
    }

    // ==========================================
    // FINDING 1: YIELD THEFT VIA WITHDRAW
    // ==========================================

    function test_WithdrawHarvestsYieldBeforeBurn() public {
        // Alice deposits and stakes into sINVAR (she should receive yield)
        vm.prank(alice);
        uint256 aliceShares = ic.deposit(500_000e6, alice, 0);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        // Bob deposits
        vm.prank(bob);
        uint256 bobShares = ic.deposit(500_000e6, bob, 0);

        // Deploy to Curve
        ic.deployToCurve(0);

        // Simulate Curve fee yield: VP grows 5%
        uint256 vpBefore = curve.virtualPrice();
        curve.setVirtualPrice(vpBefore * 105 / 100);

        uint256 sInvarBefore = ic.balanceOf(address(sInvar));

        // Bob withdraws — _harvestSafe() runs automatically, capturing yield BEFORE burn
        vm.prank(bob);
        ic.withdraw(bobShares, bob, 0);

        uint256 sInvarAfter = ic.balanceOf(address(sInvar));

        // sINVAR received yield from the full LP (before Bob's share was burned)
        assertGt(sInvarAfter, sInvarBefore, "sINVAR should receive yield during withdraw");

        // Explicit harvest should now find no yield (already captured)
        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_WithdrawLivenessOnStaleOracle() public {
        vm.prank(alice);
        uint256 aliceShares = ic.deposit(100_000e6, alice, 0);

        ic.deployToCurve(0);

        // Simulate VP growth so _harvestSafe() has yield to try capturing
        curve.setVirtualPrice(curve.virtualPrice() * 105 / 100);

        // Make oracle stale (older than ORACLE_TIMEOUT = 24 hours)
        oracle.setUpdatedAt(block.timestamp - 25 hours);

        // withdraw should still work — _harvestSafe() skips gracefully
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(aliceShares, alice, 0);
        assertGt(usdcOut, 0, "Withdrawal should succeed with stale oracle");
    }

    function test_MicroHarvestPreservesCostBasis() public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 costVpBefore = ic.curveLpCostVp();

        // Tiny VP growth — so small that totalYieldUsdc rounds to 0
        uint256 vpBefore = curve.virtualPrice();
        curve.setVirtualPrice(vpBefore + 1);

        // Trigger harvest (via deposit since it calls _harvest)
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(ic), 1e6);
        ic.deposit(1e6, bob, 0);
        vm.stopPrank();

        uint256 costVpAfter = ic.curveLpCostVp();

        // FIX: curveLpCostVp should NOT be stepped up when yield rounds to 0
        assertEq(costVpAfter, costVpBefore, "Cost basis unchanged when yield rounds to zero");
    }

    function test_LpWithdrawHarvestsYieldBeforeBurn() public {
        vm.prank(alice);
        uint256 aliceShares = ic.deposit(500_000e6, alice, 0);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        vm.prank(bob);
        uint256 bobShares = ic.deposit(500_000e6, bob, 0);

        ic.deployToCurve(0);

        uint256 vpBefore = curve.virtualPrice();
        curve.setVirtualPrice(vpBefore * 105 / 100);

        uint256 sInvarBefore = ic.balanceOf(address(sInvar));

        // lpWithdraw should also harvest first
        vm.prank(bob);
        ic.lpWithdraw(bobShares, 0, 0);

        uint256 sInvarAfter = ic.balanceOf(address(sInvar));
        assertGt(sInvarAfter, sInvarBefore, "sINVAR should receive yield during lpWithdraw");
    }

    // ==========================================
    // CURVE FAILURE TESTS (M-01, M-02)
    // ==========================================

    function test_WithdrawLiveness_CurveGetVirtualPriceReverts() public {
        vm.prank(alice);
        uint256 shares = ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(curve.virtualPrice() * 105 / 100);

        vm.mockCallRevert(address(curve), abi.encodeWithSignature("get_virtual_price()"), "Curve bricked");

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);
        assertGt(usdcOut, 0, "withdraw must succeed when get_virtual_price reverts");
    }

    function test_LpWithdrawLiveness_CurveGetVirtualPriceReverts() public {
        vm.prank(alice);
        uint256 shares = ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(curve.virtualPrice() * 105 / 100);

        vm.mockCallRevert(address(curve), abi.encodeWithSignature("get_virtual_price()"), "Curve bricked");

        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(shares, 0, 0);
        assertGt(usdcOut + bearOut, 0, "lpWithdraw must succeed when get_virtual_price reverts");
    }

    function test_WithdrawLiveness_CurveLpPriceReverts() public {
        vm.prank(alice);
        uint256 shares = ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(curve.virtualPrice() * 105 / 100);

        vm.mockCallRevert(address(curve), abi.encodeWithSignature("lp_price()"), "Curve bricked");

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);
        assertGt(usdcOut, 0, "withdraw must succeed when lp_price reverts");
    }

    function test_SetEmergencyMode_BrickedCurve_WithdrawViaLpWithdraw() public {
        vm.prank(alice);
        uint256 shares = ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        vm.mockCallRevert(
            address(curve), abi.encodeWithSignature("remove_liquidity(uint256,uint256[2])"), "Curve bricked"
        );
        vm.mockCallRevert(
            address(curve),
            abi.encodeWithSignature("remove_liquidity_one_coin(uint256,uint256,uint256)"),
            "Curve bricked"
        );

        ic.setEmergencyMode();

        assertTrue(ic.paused(), "should be paused");
        assertTrue(ic.emergencyActive(), "should be emergency");
        assertEq(ic.trackedLpBalance(), 0, "trackedLpBalance reset");
        assertEq(ic.curveLpCostVp(), 0, "curveLpCostVp reset");

        vm.prank(alice);
        (uint256 usdcOut,) = ic.lpWithdraw(shares, 0, 0);
        assertGt(usdcOut, 0, "user gets USDC from buffer even with bricked Curve");
    }

    function test_EmergencyWithdrawFromCurve_RevertsWhenCurveBricked() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        vm.mockCallRevert(
            address(curve), abi.encodeWithSignature("remove_liquidity(uint256,uint256[2])"), "Curve bricked"
        );

        vm.expectRevert("Curve bricked");
        ic.emergencyWithdrawFromCurve();

        assertFalse(ic.emergencyActive(), "state rolled back - emergency NOT active");
        assertGt(ic.trackedLpBalance(), 0, "state rolled back - trackedLpBalance unchanged");
    }

    function test_SetEmergencyMode_ThenEmergencyWithdrawAfterCurveRecovers() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBefore = curveLp.balanceOf(address(ic));
        assertGt(lpBefore, 0);

        ic.setEmergencyMode();

        assertTrue(ic.emergencyActive());
        assertEq(ic.trackedLpBalance(), 0);

        ic.emergencyWithdrawFromCurve();

        assertEq(curveLp.balanceOf(address(ic)), 0, "LP tokens recovered from Curve");
    }

    function test_SetEmergencyMode_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.setEmergencyMode();
    }

    function test_HarvestSafeExternal_RejectsDirectCalls() public {
        vm.prank(alice);
        vm.expectRevert(InvarCoin.InvarCoin__Unauthorized.selector);
        ic.harvestSafeExternal(1000);
    }

    // ==========================================
    // GROUP 1: WITHDRAW() LP BURN PATH
    // ==========================================

    function test_Withdraw_JIT_ExactUsdcFromLpBurn() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 buffer = usdc.balanceOf(address(ic));
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice) / 2;

        uint256 bufferShare = Math.mulDiv(buffer, shares, supply);
        uint256 lpShare = Math.mulDiv(lpBal, shares, supply);

        uint256 totalLp = curveLp.totalSupply();
        uint256 shareRatio = (lpShare * 1e18) / totalLp;
        uint256 curveUsdcOut = (curve.usdcBalance() * shareRatio) / 1e18;

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);

        assertEq(usdcOut, bufferShare + curveUsdcOut, "Exact USDC from buffer + LP burn");
    }

    function test_Withdraw_JIT_EmaFloorViaExpectCall() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice);

        uint256 lpShare = Math.mulDiv(lpBal, shares, supply);
        uint256 lpPrice = curve.lp_price();
        uint256 emaMin = (lpShare * lpPrice) / 1e30 * 9950 / 10_000;

        vm.expectCall(address(curve), abi.encodeCall(curve.remove_liquidity_one_coin, (lpShare, 0, emaMin)));

        vm.prank(alice);
        ic.withdraw(shares, alice, 0);
    }

    function test_Withdraw_JIT_CostBasisExactValues() public {
        vm.prank(alice);
        ic.deposit(100_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 trackedBefore = ic.trackedLpBalance();
        uint256 costBefore = ic.curveLpCostVp();
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice) / 4;

        uint256 lpShare = Math.mulDiv(lpBal, shares, supply);
        uint256 expectedTracked = trackedBefore - Math.mulDiv(trackedBefore, lpShare, lpBal);
        uint256 expectedCost = costBefore - Math.mulDiv(costBefore, lpShare, lpBal);

        vm.prank(alice);
        ic.withdraw(shares, alice, 0);

        assertEq(ic.trackedLpBalance(), expectedTracked);
        assertEq(ic.curveLpCostVp(), expectedCost);
    }

    function test_Withdraw_JIT_MinCurveOutFromUserSlippage() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 buffer = usdc.balanceOf(address(ic));
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice);

        uint256 bufferShare = Math.mulDiv(buffer, shares, supply);
        uint256 lpShare = Math.mulDiv(lpBal, shares, supply);

        uint256 lpPrice = curve.lp_price();
        uint256 emaMin = (lpShare * lpPrice) / 1e30 * 9950 / 10_000;
        uint256 minUsdcOut = bufferShare + emaMin + 1;

        vm.expectCall(address(curve), abi.encodeCall(curve.remove_liquidity_one_coin, (lpShare, 0, emaMin + 1)));

        vm.prank(alice);
        ic.withdraw(shares, alice, minUsdcOut);
    }

    // ==========================================
    // GROUP 2: LP WITHDRAW
    // ==========================================

    function test_LpWithdraw_RawBearDistribution() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        ic.emergencyWithdrawFromCurve();
        ic.unpause();

        uint256 bearInContract = bearToken.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice) / 2;

        uint256 expectedBear = Math.mulDiv(bearInContract, shares, supply);

        vm.prank(alice);
        (, uint256 bearReturned) = ic.lpWithdraw(shares, 0, 0);

        assertEq(bearReturned, expectedBear);
        assertGt(bearReturned, 0);
    }

    function test_LpWithdraw_BearFromCurveRemoval() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        uint256 shares = ic.balanceOf(alice);
        uint256 supply = ic.totalSupply();
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 lpToBurn = Math.mulDiv(lpBal, shares, supply);

        uint256 totalLp = curveLp.totalSupply();
        uint256 shareRatio = (lpToBurn * 1e18) / totalLp;
        uint256 expectedBearFromCurve = (curve.bearBalance() * shareRatio) / 1e18;

        vm.prank(alice);
        (, uint256 bearReturned) = ic.lpWithdraw(shares, 0, 0);

        assertEq(bearReturned, expectedBearFromCurve);
        assertGt(bearReturned, 0);
    }

    function test_LpWithdraw_TransfersTokensToUser() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setBearBalance(5000e18);
        bearToken.mint(address(curve), 5000e18);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 bearBefore = bearToken.balanceOf(alice);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(shares, 0, 0);

        assertEq(usdc.balanceOf(alice) - usdcBefore, usdcReturned);
        assertEq(bearToken.balanceOf(alice) - bearBefore, bearReturned);
        assertGt(usdcReturned, 0);
        assertGt(bearReturned, 0);
    }

    function test_LpWithdraw_CostBasisExact() public {
        vm.prank(alice);
        ic.deposit(50_000e6, alice, 0);
        vm.prank(bob);
        ic.deposit(50_000e6, bob, 0);
        ic.deployToCurve(0);

        uint256 trackedBefore = ic.trackedLpBalance();
        uint256 costBefore = ic.curveLpCostVp();
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 supply = ic.totalSupply();
        uint256 shares = ic.balanceOf(alice);

        uint256 lpToBurn = Math.mulDiv(lpBal, shares, supply);
        uint256 expectedTracked = trackedBefore - Math.mulDiv(trackedBefore, lpToBurn, lpBal);
        uint256 expectedCost = costBefore - Math.mulDiv(costBefore, lpToBurn, lpBal);

        vm.prank(alice);
        ic.lpWithdraw(shares, 0, 0);

        assertEq(ic.trackedLpBalance(), expectedTracked);
        assertEq(ic.curveLpCostVp(), expectedCost);
    }

    // ==========================================
    // GROUP 3: LP DEPOSIT
    // ==========================================

    function test_LpDeposit_HarvestBeforeAction() public {
        vm.prank(alice);
        uint256 aliceShares = ic.deposit(100_000e6, alice, 0);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        ic.deployToCurve(0);
        curve.setVirtualPrice(1.05e18);

        uint256 sInvarBefore = ic.balanceOf(address(sInvar));

        bearToken.mint(bob, 10_000e18);
        vm.startPrank(bob);
        bearToken.approve(address(ic), 10_000e18);
        ic.lpDeposit(10_000e6, 10_000e18, bob, 0);
        vm.stopPrank();

        assertGt(ic.balanceOf(address(sInvar)), sInvarBefore);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    function test_LpDeposit_SpotDeviationRevert() public {
        vm.startPrank(alice);

        curve.setSpotDiscountBps(51);
        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.lpDeposit(10_000e6, 0, alice, 0);

        curve.setSpotDiscountBps(0);
        ic.lpDeposit(10_000e6, 0, alice, 0);

        vm.stopPrank();
    }

    function test_LpDeposit_SpotPremiumReverts() public {
        vm.startPrank(alice);

        curve.setSpotPremiumBps(51);
        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.lpDeposit(10_000e6, 0, alice, 0);

        curve.setSpotPremiumBps(0);
        ic.lpDeposit(10_000e6, 0, alice, 0);

        vm.stopPrank();
    }

    function test_LpDeposit_BearOnlyValuation() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        bearToken.mint(alice, 1000e18);
        vm.startPrank(alice);
        bearToken.approve(address(ic), 1000e18);
        ic.lpDeposit(0, 1000e18, alice, 0);
        vm.stopPrank();

        assertEq(ic.trackedLpBalance(), 450e18);
    }

    function test_LpDeposit_CostVpExactIncrease() public {
        curve.setVirtualPrice(1.05e18);

        vm.startPrank(alice);

        ic.lpDeposit(10_000e6, 0, alice, 0);
        uint256 lp1 = ic.trackedLpBalance();
        uint256 expectedCost1 = (lp1 * 1.05e18) / 1e18;
        assertEq(ic.curveLpCostVp(), expectedCost1);

        ic.lpDeposit(5000e6, 0, alice, 0);
        uint256 lp2 = ic.trackedLpBalance() - lp1;
        uint256 expectedCost2 = expectedCost1 + (lp2 * 1.05e18) / 1e18;
        assertEq(ic.curveLpCostVp(), expectedCost2);

        vm.stopPrank();
    }

    function test_LpDeposit_TrackedLpBalanceExact() public {
        vm.startPrank(alice);

        ic.lpDeposit(10_000e6, 0, alice, 0);
        uint256 lp1 = ic.trackedLpBalance();
        assertGt(lp1, 0);
        assertEq(ic.trackedLpBalance(), curveLp.balanceOf(address(ic)));

        ic.lpDeposit(5000e6, 0, alice, 0);
        uint256 lp2 = ic.trackedLpBalance();
        assertEq(lp2, curveLp.balanceOf(address(ic)));
        assertGt(lp2, lp1);

        vm.stopPrank();
    }

    // ==========================================
    // GROUP 4: _totalAssetsOptimistic()
    // ==========================================

    function test_TotalAssets_IncludesRawBear() public {
        vm.prank(bob);
        ic.deposit(10_000e6, bob, 0);

        bearToken.mint(address(ic), 10_000e18);

        assertEq(ic.totalAssets(), 10_000e6 + 12_000e6);
    }

    function test_TotalAssets_OracleZeroFallsBackToEma() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 buffer = usdc.balanceOf(address(ic));
        uint256 lpBal = curveLp.balanceOf(address(ic));
        uint256 lpPrice = curve.lp_price();

        oracle.updatePrice(0);

        uint256 total = ic.totalAssets();
        uint256 expected = buffer + (lpBal * lpPrice) / 1e30;

        assertEq(total, expected);
        assertGt(total, 0);
    }

    // ==========================================
    // GROUP 6: HARVEST BEFORE DEPOSIT
    // ==========================================

    function test_Deposit_HarvestsYieldBeforeAction() public {
        vm.prank(alice);
        uint256 aliceShares = ic.deposit(100_000e6, alice, 0);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        ic.deployToCurve(0);
        curve.setVirtualPrice(1.05e18);

        uint256 sInvarBefore = ic.balanceOf(address(sInvar));

        vm.prank(bob);
        ic.deposit(10_000e6, bob, 0);

        assertGt(ic.balanceOf(address(sInvar)), sInvarBefore);

        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
    }

    // ==========================================
    // WAVE 2: MUTANT-KILLING TESTS
    // ==========================================

    function test_Deposit_SucceedsWithoutStakedInvarCoin() public {
        InvarCoin freshIc = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
        );

        vm.prank(alice);
        usdc.approve(address(freshIc), type(uint256).max);
        vm.prank(alice);
        freshIc.deposit(20_000e6, alice, 0);
        freshIc.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);

        vm.prank(bob);
        usdc.approve(address(freshIc), type(uint256).max);
        vm.prank(bob);
        uint256 shares = freshIc.deposit(10_000e6, bob, 0);

        assertGt(shares, 0);
    }

    function test_Harvest_ExactDonatedAmount() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);

        curve.setVirtualPrice(2.5e18);

        uint256 donated = ic.harvest();
        assertGt(donated, 26_000e18);
        assertLt(donated, 26_500e18);
    }

    function test_DeployToCurve_ExactBufferRemaining() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        assertEq(usdc.balanceOf(address(ic)), 360e6);
    }

    function test_DeployToCurve_MaxUsdcCapsDeployment() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(5000e6);

        assertEq(usdc.balanceOf(address(ic)), 13_000e6);
    }

    function test_DeployToCurve_SlippageGuardExactMinMint() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);

        uint256 deploy = 17_640e6;
        uint256 calcLp = deploy * 1e30 / curve.lp_price();

        vm.expectCall(address(curve), abi.encodeCall(curve.add_liquidity, ([deploy, uint256(0)], calcLp - 1)));
        ic.deployToCurve(0);
    }

    function test_ReplenishBuffer_RevertsWhenBufferSufficient() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        vm.expectRevert(InvarCoin.InvarCoin__NothingToDeploy.selector);
        ic.replenishBuffer(0);
    }

    function test_ReplenishBuffer_ExactLpBurned() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        deal(address(usdc), address(ic), 180e6);

        uint256 assets = ic.totalAssets();
        uint256 bufferTarget = (assets * 200) / 10_000;
        uint256 maxReplenish = bufferTarget - 180e6;
        uint256 expectedLpBurned = (maxReplenish * 1e30) / curve.lp_price();

        uint256 lpBefore = curveLp.balanceOf(address(ic));
        ic.replenishBuffer(0);
        uint256 lpBurned = lpBefore - curveLp.balanceOf(address(ic));

        assertEq(lpBurned, expectedLpBurned);
    }

    function test_ReplenishBuffer_ClampsLpToBurn() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        bearToken.mint(address(ic), 2_000_000e18);
        deal(address(usdc), address(ic), 0);

        uint256 lpBefore = curveLp.balanceOf(address(ic));
        ic.replenishBuffer(0);
        uint256 lpBurned = lpBefore - curveLp.balanceOf(address(ic));

        assertEq(lpBurned, lpBefore);
    }

    // ==========================================
    // WAVE 3: replenishBuffer + redeployToCurve
    // ==========================================

    function test_ReplenishBuffer_SlippageFloorExactMinAmount() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        deal(address(usdc), address(ic), 180e6);

        uint256 assets = ic.totalAssets();
        uint256 bufferTarget = (assets * 200) / 10_000;
        uint256 maxReplenish = bufferTarget - 180e6;
        uint256 lpToBurn = (maxReplenish * 1e30) / curve.lp_price();
        uint256 calcOut = curve.calc_withdraw_one_coin(lpToBurn, 0);
        uint256 minAmount = calcOut * (10_000 - 5) / 10_000;

        vm.expectCall(address(curve), abi.encodeCall(curve.remove_liquidity_one_coin, (lpToBurn, 0, minAmount)));
        ic.replenishBuffer(0);
    }

    function test_ReplenishBuffer_EmitsExactRecoveredAmount() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        ic.deployToCurve(0);

        deal(address(usdc), address(ic), 180e6);

        uint256 assets = ic.totalAssets();
        uint256 bufferTarget = (assets * 200) / 10_000;
        uint256 maxReplenish = bufferTarget - 180e6;
        uint256 lpToBurn = (maxReplenish * 1e30) / curve.lp_price();
        uint256 calcOut = curve.calc_withdraw_one_coin(lpToBurn, 0);

        vm.expectEmit(true, true, true, true);
        emit InvarCoin.BufferReplenished(lpToBurn, calcOut);
        ic.replenishBuffer(0);
    }

    function test_RedeployToCurve_ExactAmountsAndBuffer() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);

        vm.prank(alice);
        ic.deposit(18_000e6, alice, 0);
        bearToken.mint(address(ic), 10_000e18);

        // assets = 18_000e6 + 8_100e6 = 26_100e6
        // bufferTarget = 26_100e6 * 200 / 10_000 = 522e6
        // usdcToDeploy = 18_000e6 - 522e6 = 17_478e6
        vm.expectCall(address(curve), abi.encodeCall(curve.add_liquidity, ([uint256(17_478e6), uint256(10_000e18)], 0)));
        ic.redeployToCurve(0);

        assertEq(usdc.balanceOf(address(ic)), 522e6);
    }

    function test_RedeployToCurve_NoExcessUsdcExactTracking() public {
        oracle.updatePrice(81_000_000);
        curve.setPriceMultiplier(0.81e18);
        curve.setVirtualPrice(1.5e18);

        vm.prank(alice);
        ic.deposit(100e6, alice, 0);
        bearToken.mint(address(ic), 10_000e18);

        // assets = 100e6 + 8_100e6 = 8_200e6
        // bufferTarget = 8_200e6 * 200 / 10_000 = 164e6
        // localUsdc = 100e6 < 164e6 → usdcToDeploy = 0
        // lpPrice = 2 * 1.5e18 * sqrt(0.81e18 * 1e18) / 1e18 = 2 * 1.5e18 * 0.9e18 / 1e18 = 2.7e18
        // lpMinted = (0 + 8_100e6) * 1e30 / 2.7e18 = 3_000e18
        // curveLpCostVp = 3_000e18 * 1.5e18 / 1e18 = 4_500e18
        ic.redeployToCurve(0);

        assertEq(usdc.balanceOf(address(ic)), 100e6);
        assertEq(ic.trackedLpBalance(), 3000e18);
        assertEq(ic.curveLpCostVp(), 4500e18);
    }

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    function test_GetBufferMetrics_AfterDeposit() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        (uint256 currentBuffer, uint256 targetBuffer, uint256 deployable, uint256 replenishable) = ic.getBufferMetrics();

        assertEq(currentBuffer, 20_000e6);
        assertEq(targetBuffer, (ic.totalAssets() * 200) / 10_000);
        assertGt(deployable, 0);
        assertEq(replenishable, 0);
    }

    function test_GetBufferMetrics_AfterDeploy() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        (uint256 currentBuffer, uint256 targetBuffer, uint256 deployable, uint256 replenishable) = ic.getBufferMetrics();

        assertEq(deployable, 0);
        assertEq(replenishable, 0);
        assertApproxEqRel(currentBuffer, targetBuffer, 0.05e18);
    }

    function test_GetBufferMetrics_NeedsReplenish() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        deal(address(usdc), address(ic), usdc.balanceOf(address(ic)) / 10);

        (,, uint256 deployable, uint256 replenishable) = ic.getBufferMetrics();

        assertEq(deployable, 0);
        assertGt(replenishable, 0);
    }

    function test_GetHarvestableYield_NoYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        assertEq(ic.getHarvestableYield(), 0);
    }

    function test_GetHarvestableYield_WithYield() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        curve.setVirtualPrice(1.05e18);

        assertGt(ic.getHarvestableYield(), 0);
    }

    function test_GetSpotDeviation_Normal() public {
        assertEq(ic.getSpotDeviation(), 0);
    }

    function test_GetSpotDeviation_Manipulated() public {
        curve.setSpotDiscountBps(100);

        assertGt(ic.getSpotDeviation(), 0);
    }

    function test_ReplenishBuffer_ReturnsUsdcRecovered() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        deal(address(usdc), address(ic), usdc.balanceOf(address(ic)) / 10);

        uint256 usdcBefore = usdc.balanceOf(address(ic));
        uint256 recovered = ic.replenishBuffer(0);

        assertEq(recovered, usdc.balanceOf(address(ic)) - usdcBefore);
        assertGt(recovered, 0);
    }

}

// ==========================================
// GAUGE TEST SUITE
// ==========================================

contract InvarCoinGaugeTest is Test {

    InvarCoin public ic;
    StakedToken public sInvar;
    MockUSDC6 public usdc;
    MockBEAR public bearToken;
    MockCurvePool public curve;
    MockCurveLpToken public curveLp;
    MockOracle public oracle;
    MockCurveGauge public gauge;

    address public alice = makeAddr("alice");

    uint256 constant ORACLE_PRICE = 120_000_000;

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC6();
        oracle = new MockOracle(int256(ORACLE_PRICE), "plDXY Basket");
        bearToken = new MockBEAR();
        curveLp = new MockCurveLpToken();
        curve = new MockCurvePool(address(usdc), address(bearToken), address(curveLp));
        curve.setPriceMultiplier(1.2e18);

        ic = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
        );

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        gauge = new MockCurveGauge(address(curveLp));

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(ic), type(uint256).max);
    }

    function _setupGauge() internal {
        ic.proposeGauge(address(gauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();
    }

    // ==========================================
    // GAUGE GOVERNANCE
    // ==========================================

    function test_ProposeGauge_SetsTimelockParams() public {
        ic.proposeGauge(address(gauge));

        assertEq(ic.pendingGauge(), address(gauge));
        assertEq(ic.gaugeActivationTime(), block.timestamp + 7 days);
    }

    function test_ProposeGauge_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.proposeGauge(address(gauge));
    }

    function test_ProposeGauge_RevertsIfSameAsCurrent() public {
        _setupGauge();

        vm.expectRevert(InvarCoin.InvarCoin__InvalidProposal.selector);
        ic.proposeGauge(address(gauge));
    }

    function test_FinalizeGauge_RevertsBeforeTimelock() public {
        ic.proposeGauge(address(gauge));

        vm.expectRevert(InvarCoin.InvarCoin__GaugeTimelockActive.selector);
        ic.finalizeGauge();
    }

    function test_FinalizeGauge_SetsGaugeAfterTimelock() public {
        _setupGauge();

        assertEq(address(ic.curveGauge()), address(gauge));
        assertEq(ic.pendingGauge(), address(0));
        assertEq(ic.gaugeActivationTime(), 0);
    }

    function test_FinalizeGauge_OnlyOwner() public {
        ic.proposeGauge(address(gauge));
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.finalizeGauge();
    }

    function test_FinalizeGauge_UnstakesFromOldGauge() public {
        _setupGauge();

        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 stakedInGauge = gauge.balanceOf(address(ic));
        assertGt(stakedInGauge, 0);

        MockCurveGauge newGauge = new MockCurveGauge(address(curveLp));
        ic.proposeGauge(address(newGauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        assertEq(gauge.balanceOf(address(ic)), 0);
        assertEq(newGauge.balanceOf(address(ic)), stakedInGauge);
        assertEq(address(ic.curveGauge()), address(newGauge));
    }

    function test_FinalizeGauge_RemoveGauge() public {
        _setupGauge();

        ic.proposeGauge(address(0));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        assertEq(address(ic.curveGauge()), address(0));
    }

    function test_FinalizeGauge_RevertsWithNoPendingProposal() public {
        vm.expectRevert(InvarCoin.InvarCoin__GaugeTimelockActive.selector);
        ic.finalizeGauge();
    }

    function test_FinalizeGauge_RevertsIfOldGaugeBricked() public {
        MockBrickedGauge brickedGauge = new MockBrickedGauge(address(curveLp));

        ic.proposeGauge(address(brickedGauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 totalAssetsBefore = ic.totalAssets();

        brickedGauge.setBricked(true);

        MockCurveGauge newGauge = new MockCurveGauge(address(curveLp));
        ic.proposeGauge(address(newGauge));
        vm.warp(block.timestamp + 14 days);
        oracle.setUpdatedAt(block.timestamp);

        vm.expectRevert("gauge bricked");
        ic.finalizeGauge();

        assertEq(ic.totalAssets(), totalAssetsBefore, "NAV must not change");
        assertEq(address(ic.curveGauge()), address(brickedGauge), "Gauge must not change");
    }

    // ==========================================
    // STAKE / UNSTAKE
    // ==========================================

    function test_StakeToGauge_StakesAllWhenZero() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        assertGt(lpBal, 0);

        _setupGauge();

        assertEq(gauge.balanceOf(address(ic)), lpBal);
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_StakeToGauge_StakesExactAmount() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));

        _setupGauge();

        ic.unstakeFromGauge(lpBal / 2);
        ic.stakeToGauge(lpBal / 2);
        assertEq(gauge.balanceOf(address(ic)), lpBal);
    }

    function test_StakeToGauge_RevertsWithNoGauge() public {
        vm.expectRevert(InvarCoin.InvarCoin__NoGauge.selector);
        ic.stakeToGauge(0);
    }

    function test_StakeToGauge_OnlyOwner() public {
        _setupGauge();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.stakeToGauge(0);
    }

    function test_UnstakeFromGauge_UnstakesAllWhenZero() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        uint256 stakedBal = gauge.balanceOf(address(ic));
        assertGt(stakedBal, 0);

        ic.unstakeFromGauge(0);
        assertEq(gauge.balanceOf(address(ic)), 0);
        assertEq(curveLp.balanceOf(address(ic)), stakedBal);
    }

    function test_UnstakeFromGauge_RevertsWithNoGauge() public {
        vm.expectRevert(InvarCoin.InvarCoin__NoGauge.selector);
        ic.unstakeFromGauge(0);
    }

    function test_UnstakeFromGauge_OnlyOwner() public {
        _setupGauge();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.unstakeFromGauge(0);
    }

    // ==========================================
    // CLAIM REWARDS
    // ==========================================

    function test_ClaimGaugeRewards_Succeeds() public {
        _setupGauge();
        ic.claimGaugeRewards();
    }

    function test_ClaimGaugeRewards_RevertsWithNoGauge() public {
        vm.expectRevert(InvarCoin.InvarCoin__NoGauge.selector);
        ic.claimGaugeRewards();
    }

    function test_ClaimGaugeRewards_OnlyOwner() public {
        _setupGauge();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ic.claimGaugeRewards();
    }

    // ==========================================
    // JIT UNSTAKE ON WITHDRAWALS
    // ==========================================

    function test_Withdraw_JitUnstakesFromGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        assertGt(gauge.balanceOf(address(ic)), 0);
        assertEq(curveLp.balanceOf(address(ic)), 0);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);

        assertGt(usdcOut, 0);
        assertEq(gauge.balanceOf(address(ic)), 0);
    }

    function test_LpWithdraw_JitUnstakesFromGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 bearOut) = ic.lpWithdraw(shares, 0, 0);

        assertGt(usdcOut, 0);
        assertEq(gauge.balanceOf(address(ic)), 0);
    }

    function test_ReplenishBuffer_JitUnstakesFromGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        deal(address(usdc), address(ic), 0);

        uint256 gaugeBefore = gauge.balanceOf(address(ic));
        ic.replenishBuffer(0);

        assertLt(gauge.balanceOf(address(ic)), gaugeBefore);
    }

    function test_EmergencyWithdraw_JitUnstakesFromGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        assertGt(gauge.balanceOf(address(ic)), 0);

        ic.emergencyWithdrawFromCurve();

        assertEq(gauge.balanceOf(address(ic)), 0);
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_PartialWithdraw_OnlyUnstakesNeeded() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        ic.withdraw(shares / 4, alice, 0);

        assertGt(gauge.balanceOf(address(ic)), 0, "Remaining LP should stay staked");
    }

    // ==========================================
    // BACKWARD COMPAT: NO GAUGE
    // ==========================================

    // ==========================================
    // EVENTS
    // ==========================================

    function test_ProposeGauge_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit InvarCoin.GaugeProposed(address(gauge), block.timestamp + 7 days);
        ic.proposeGauge(address(gauge));
    }

    function test_FinalizeGauge_EmitsEvent() public {
        ic.proposeGauge(address(gauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit InvarCoin.GaugeUpdated(address(0), address(gauge));
        ic.finalizeGauge();
    }

    function test_StakeToGauge_EmitsEvent() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();

        ic.unstakeFromGauge(0);

        vm.expectEmit(true, true, true, true);
        emit InvarCoin.GaugeStaked(lpBal);
        ic.stakeToGauge(0);
    }

    function test_UnstakeFromGauge_EmitsEvent() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);
        _setupGauge();

        uint256 stakedBal = gauge.balanceOf(address(ic));

        vm.expectEmit(true, true, true, true);
        emit InvarCoin.GaugeUnstaked(stakedBal);
        ic.unstakeFromGauge(0);
    }

    function test_ClaimGaugeRewards_EmitsEvent() public {
        _setupGauge();

        vm.expectEmit(true, true, true, true);
        emit InvarCoin.GaugeRewardsClaimed();
        ic.claimGaugeRewards();
    }

    // ==========================================
    // CRV MINTER (L1 vs L2)
    // ==========================================

    function test_ClaimGaugeRewards_CallsMinterOnL1() public {
        MockCrvMinter minter = new MockCrvMinter();

        InvarCoin icL1 = new InvarCoin(
            address(usdc),
            address(bearToken),
            address(curveLp),
            address(curve),
            address(oracle),
            address(0),
            address(minter)
        );
        StakedToken sL1 = new StakedToken(IERC20(address(icL1)), "sINVAR-L1", "sINVAR-L1");
        icL1.setStakedInvarCoin(address(sL1));

        icL1.proposeGauge(address(gauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        icL1.finalizeGauge();

        icL1.claimGaugeRewards();

        assertEq(minter.mintCallCount(), 1, "Minter.mint should be called once");
        assertEq(minter.lastGauge(), address(gauge), "Minter.mint should target the gauge");
    }

    function test_ClaimGaugeRewards_SkipsMinterOnL2() public {
        assertEq(address(ic.CRV_MINTER()), address(0), "L2 minter should be zero");

        _setupGauge();
        ic.claimGaugeRewards();
    }

    // ==========================================
    // RESCUE TOKEN: GAUGE BLACKLIST
    // ==========================================

    function test_RescueToken_CannotRescueGaugeToken() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        _setupGauge();

        vm.expectRevert(InvarCoin.InvarCoin__CannotRescueCoreAsset.selector);
        ic.rescueToken(address(gauge), alice);
    }

    // ==========================================
    // PROPOSE GAUGE: OVERWRITE PENDING
    // ==========================================

    function test_ProposeGauge_OverwritesPendingProposal() public {
        ic.proposeGauge(address(gauge));

        MockCurveGauge gauge2 = new MockCurveGauge(address(curveLp));
        ic.proposeGauge(address(gauge2));

        assertEq(ic.pendingGauge(), address(gauge2));
    }

    function test_ProposeGauge_CanProposeZeroToRemove() public {
        _setupGauge();

        ic.proposeGauge(address(0));
        assertEq(ic.pendingGauge(), address(0));
        assertGt(ic.gaugeActivationTime(), block.timestamp);
    }

    // ==========================================
    // FINALIZE GAUGE: EDGE CASES
    // ==========================================

    function test_FinalizeGauge_ExactTimelockBoundary() public {
        ic.proposeGauge(address(gauge));
        uint256 activationTime = ic.gaugeActivationTime();

        vm.warp(activationTime - 1);
        oracle.setUpdatedAt(block.timestamp);
        vm.expectRevert(InvarCoin.InvarCoin__GaugeTimelockActive.selector);
        ic.finalizeGauge();

        vm.warp(activationTime);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();
        assertEq(address(ic.curveGauge()), address(gauge));
    }

    function test_FinalizeGauge_NoStakedLpInOldGauge() public {
        _setupGauge();

        MockCurveGauge newGauge = new MockCurveGauge(address(curveLp));
        ic.proposeGauge(address(newGauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        assertEq(address(ic.curveGauge()), address(newGauge));
    }

    function test_FinalizeGauge_RevokesOldApproval() public {
        _setupGauge();
        address oldGaugeAddr = address(gauge);

        ic.proposeGauge(address(0));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        assertEq(curveLp.allowance(address(ic), oldGaugeAddr), 0);
    }

    function test_FinalizeGauge_SetsMaxApprovalOnNew() public {
        _setupGauge();
        assertEq(curveLp.allowance(address(ic), address(gauge)), type(uint256).max);
    }

    // ==========================================
    // UNSTAKE: EXACT AMOUNT
    // ==========================================

    function test_UnstakeFromGauge_ExactAmount() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();

        uint256 half = lpBal / 2;
        ic.unstakeFromGauge(half);

        assertEq(gauge.balanceOf(address(ic)), lpBal - half);
        assertEq(curveLp.balanceOf(address(ic)), half);
    }

    // ==========================================
    // _lpBalance: MIXED LOCAL + STAKED
    // ==========================================

    function test_TotalAssets_MixedLocalAndStakedLp() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();

        ic.unstakeFromGauge(lpBal / 2);

        uint256 localLp = curveLp.balanceOf(address(ic));
        uint256 stakedLp = gauge.balanceOf(address(ic));
        assertGt(localLp, 0);
        assertGt(stakedLp, 0);

        uint256 nav = ic.totalAssets();
        assertApproxEqRel(nav, 20_000e6, 0.02e18);
    }

    function test_TotalAssets_PreservedAfterStakeUnstakeCycle() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 navBefore = ic.totalAssets();

        _setupGauge();
        uint256 navStaked = ic.totalAssets();

        ic.unstakeFromGauge(0);
        uint256 navUnstaked = ic.totalAssets();

        assertEq(navStaked, navBefore);
        assertEq(navUnstaked, navBefore);
    }

    // ==========================================
    // _ensureUnstakedLp: MIXED BALANCE
    // ==========================================

    function test_Withdraw_MixedLocalAndStakedLp() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();
        ic.unstakeFromGauge(lpBal / 2);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);

        assertApproxEqRel(usdcOut, 20_000e6, 0.02e18);
        assertEq(gauge.balanceOf(address(ic)), 0);
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_Withdraw_LocalSufficientSkipsGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();
        ic.unstakeFromGauge(lpBal * 3 / 4);

        uint256 gaugeBalBefore = gauge.balanceOf(address(ic));

        uint256 shares = ic.balanceOf(alice) / 10;
        vm.prank(alice);
        ic.withdraw(shares, alice, 0);

        assertEq(gauge.balanceOf(address(ic)), gaugeBalBefore, "Gauge untouched when local LP suffices");
    }

    function test_LpWithdraw_MixedLocalAndStakedLp() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 lpBal = curveLp.balanceOf(address(ic));
        _setupGauge();
        ic.unstakeFromGauge(lpBal / 2);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut,) = ic.lpWithdraw(shares, 0, 0);

        assertGt(usdcOut, 0);
        assertEq(gauge.balanceOf(address(ic)), 0);
    }

    // ==========================================
    // HARVEST WITH STAKED LP
    // ==========================================

    function test_Harvest_WorksWithGaugeStakedLp() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);
        _setupGauge();

        curve.setVirtualPrice(1.05e18);

        uint256 donated = ic.harvest();
        assertGt(donated, 0);
    }

    // ==========================================
    // DEPOSIT/DEPLOY WITH ACTIVE GAUGE
    // ==========================================

    function test_Deposit_WorksWithActiveGauge() public {
        _setupGauge();

        vm.prank(alice);
        uint256 shares = ic.deposit(20_000e6, alice, 0);
        assertGt(shares, 0);
    }

    function test_DeployToCurve_AutoStakesToGauge() public {
        _setupGauge();

        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        uint256 lpMinted = ic.deployToCurve(0);

        assertEq(curveLp.balanceOf(address(ic)), 0);
        assertEq(gauge.balanceOf(address(ic)), lpMinted);
    }

    function test_DeployToCurve_SkipsStakeWithoutGauge() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        uint256 lpMinted = ic.deployToCurve(0);

        assertEq(curveLp.balanceOf(address(ic)), lpMinted);
    }

    function test_DeployToCurve_RevertsIfGaugeBricked() public {
        MockBrickedGauge brickedGauge = new MockBrickedGauge(address(curveLp));
        ic.proposeGauge(address(brickedGauge));
        vm.warp(block.timestamp + 7 days);
        oracle.setUpdatedAt(block.timestamp);
        ic.finalizeGauge();

        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        brickedGauge.setBricked(true);

        vm.expectRevert("gauge bricked");
        ic.deployToCurve(0);
    }

    // ==========================================
    // FULL LIFECYCLE
    // ==========================================

    function test_FullCycle_DepositDeployStakeHarvestWithdraw() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);

        uint256 stakeAmount = ic.balanceOf(alice) / 2;
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve(0);
        _setupGauge();

        curve.setVirtualPrice(1.05e18);
        ic.harvest();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);

        assertGt(usdcOut, 0);
        assertEq(ic.balanceOf(alice), 0);
    }

    // ==========================================
    // BACKWARD COMPAT: NO GAUGE
    // ==========================================

    function test_NoGauge_WithdrawWorksNormally() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(shares, alice, 0);

        assertGt(usdcOut, 0);
    }

    function test_NoGauge_LpWithdrawWorksNormally() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice, 0);
        ic.deployToCurve(0);

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut,) = ic.lpWithdraw(shares, 0, 0);

        assertGt(usdcOut, 0);
    }

}

// ==========================================
// PERMIT TEST SUITE
// ==========================================

contract MockUSDCPermit is ERC20, ERC20Permit {

    constructor() ERC20("Mock USDC", "USDC") ERC20Permit("Mock USDC") {}

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

contract InvarCoinPermitTest is Test {

    InvarCoin public ic;
    StakedToken public sInvar;
    MockUSDCPermit public usdc;
    MockBEAR public bearToken;
    MockCurvePool public curve;
    MockCurveLpToken public curveLp;
    MockOracle public oracle;

    uint256 constant ORACLE_PRICE = 120_000_000;
    uint256 constant SIGNER_KEY = 0x1234;
    address public signer;

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDCPermit();
        oracle = new MockOracle(int256(ORACLE_PRICE), "plDXY Basket");
        bearToken = new MockBEAR();
        curveLp = new MockCurveLpToken();
        curve = new MockCurvePool(address(usdc), address(bearToken), address(curveLp));
        curve.setPriceMultiplier(1.2e18);

        ic = new InvarCoin(
            address(usdc), address(bearToken), address(curveLp), address(curve), address(oracle), address(0), address(0)
        );

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        signer = vm.addr(SIGNER_KEY);
        usdc.mint(signer, 1_000_000e6);
    }

    function _signPermit(
        uint256 amount,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        address(ic),
                        amount,
                        usdc.nonces(signer),
                        deadline
                    )
                )
            )
        );
        return vm.sign(SIGNER_KEY, permitHash);
    }

    function test_DepositWithPermit_HappyPath() public {
        uint256 amount = 1000e6;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(amount, deadline);

        vm.prank(signer);
        uint256 shares = ic.depositWithPermit(amount, signer, 0, deadline, v, r, s);

        assertGt(shares, 0);
        assertEq(ic.balanceOf(signer), shares);
        assertEq(usdc.balanceOf(signer), 1_000_000e6 - amount);
    }

    function test_DepositWithPermit_ExpiredDeadline() public {
        uint256 amount = 1000e6;
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(amount, deadline);

        vm.prank(signer);
        vm.expectRevert(InvarCoin.InvarCoin__PermitFailed.selector);
        ic.depositWithPermit(amount, signer, 0, deadline, v, r, s);
    }

    function test_DepositWithPermit_FallbackOnAllowance() public {
        uint256 amount = 1000e6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(signer);
        usdc.approve(address(ic), amount);

        vm.prank(signer);
        uint256 shares = ic.depositWithPermit(amount, signer, 0, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));

        assertGt(shares, 0);
    }

    function test_DepositWithPermit_NoAllowanceReverts() public {
        uint256 amount = 1000e6;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(signer);
        vm.expectRevert(InvarCoin.InvarCoin__PermitFailed.selector);
        ic.depositWithPermit(amount, signer, 0, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }

}

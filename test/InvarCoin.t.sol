// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {InvarCoin} from "../src/InvarCoin.sol";
import {StakedToken} from "../src/StakedToken.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

contract MockMorphoVault is ERC4626 {

    using SafeERC20 for IERC20;

    constructor(
        IERC20 _asset
    ) ERC4626(_asset) ERC20("Mock Morpho Vault", "mvUSDC") {}

    function simulateYield(
        uint256 amount
    ) external {
        MockUSDC6(asset()).mint(address(this), amount);
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
    uint256 public swapFeeBps;

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
        return 2 * virtualPrice;
    }

    function setVirtualPrice(
        uint256 _vp
    ) external {
        virtualPrice = _vp;
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
    MockMorphoVault public morpho;
    MockCurvePool public curve;
    MockCurveLpToken public curveLp;
    MockOracle public oracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public keeper = makeAddr("keeper");
    address public rewardDist = makeAddr("rewardDist");

    uint256 constant ORACLE_PRICE = 80_000_000;

    function setUp() public {
        vm.warp(100_000);

        usdc = new MockUSDC6();
        oracle = new MockOracle(int256(ORACLE_PRICE), "plDXY Basket");
        bearToken = new MockBEAR();
        curveLp = new MockCurveLpToken();
        curve = new MockCurvePool(address(usdc), address(bearToken), address(curveLp));
        morpho = new MockMorphoVault(IERC20(address(usdc)));

        ic = new InvarCoin(
            address(usdc),
            address(bearToken),
            address(curveLp),
            address(morpho),
            address(curve),
            address(oracle),
            address(0)
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

    function test_Withdraw_FullFromMorphoBuffer() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        uint256 bal = ic.balanceOf(alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);

        assertApproxEqRel(usdcOut, 1000e6, 0.01e18);
        assertEq(ic.balanceOf(alice), 0);
    }

    function test_Withdraw_RevertsOnZero() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAmount.selector);
        vm.prank(alice);
        ic.withdraw(0, alice, 0);
    }

    function test_Withdraw_AllowedWhenPaused() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        ic.pause();

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(bal, alice, 0);

        assertGt(usdcOut, 0);
    }

    function test_Withdraw_SlippageProtection() public {
        vm.prank(alice);
        ic.deposit(100e6, alice);

        uint256 bal = ic.balanceOf(alice);

        vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
        vm.prank(alice);
        ic.withdraw(bal, alice, type(uint256).max);
    }

    function test_Withdraw_MorphoPrincipalUnchangedWhenServedFromDust() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        uint256 principalBefore = ic.morphoPrincipal();

        // Send dust USDC directly to contract
        usdc.mint(address(ic), 100e6);

        // Withdraw a small amount — should be served entirely from dust
        uint256 sharesToWithdraw = ic.balanceOf(alice) / 200; // ~50 USDC worth
        vm.prank(alice);
        ic.withdraw(sharesToWithdraw, alice, 0);

        assertEq(ic.morphoPrincipal(), principalBefore, "morphoPrincipal should not change when served from dust");
    }

    function test_Harvest_NoPhantomYieldFromDust() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice) / 2;
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        // Send dust and withdraw from it
        usdc.mint(address(ic), 100e6);
        uint256 sharesToWithdraw = ic.balanceOf(alice) / 200;
        vm.prank(alice);
        ic.withdraw(sharesToWithdraw, alice, 0);

        // No real yield exists — harvest should revert
        vm.expectRevert(InvarCoin.InvarCoin__NoYield.selector);
        ic.harvest();
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

    // ==========================================
    // HARVEST
    // ==========================================

    function test_Harvest_MorphoYield() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        morpho.simulateYield(100e6);

        uint256 sInvarAssetsBefore = ic.balanceOf(address(sInvar));
        uint256 donated = ic.harvest();

        assertGt(donated, 0);
        assertGt(ic.balanceOf(address(sInvar)), sInvarAssetsBefore);
    }

    function test_Harvest_CallerGetsReward() public {
        vm.prank(alice);
        ic.deposit(10_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        morpho.simulateYield(100e6);

        uint256 keeperBalBefore = ic.balanceOf(keeper);

        vm.prank(keeper);
        ic.harvest();

        uint256 keeperReward = ic.balanceOf(keeper) - keeperBalBefore;
        assertGt(keeperReward, 0);
    }

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

    function test_Harvest_CombinedMorphoAndCurve() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        uint256 stakeAmount = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), stakeAmount);
        sInvar.deposit(stakeAmount, alice);
        vm.stopPrank();

        ic.deployToCurve();

        morpho.simulateYield(50e6);
        curve.setVirtualPrice(1.02e18);

        uint256 donated = ic.harvest();
        assertGt(donated, 0);
    }

    // ==========================================
    // REPLENISH BUFFER
    // ==========================================

    function test_ReplenishBuffer_Basic() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 toWithdraw = ic.balanceOf(alice) / 10;
        vm.prank(alice);
        ic.withdraw(toWithdraw, alice, 0);

        uint256 morphoPrincipalBefore = ic.morphoPrincipal();
        ic.replenishBuffer();

        assertGt(ic.morphoPrincipal(), morphoPrincipalBefore);
    }

    // ==========================================
    // NAV: totalAssets
    // ==========================================

    function test_TotalAssets_MorphoOnly() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        assertEq(ic.totalAssets(), 1000e6);
    }

    function test_TotalAssets_WithCurveAndMorpho() public {
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

    function test_EmergencyWithdrawFromMorpho() public {
        vm.prank(alice);
        ic.deposit(1000e6, alice);

        ic.emergencyWithdrawFromMorpho();

        assertTrue(ic.paused());
        assertEq(ic.morphoPrincipal(), 0);
    }

    function test_EmergencyWithdrawFromCurve() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        ic.emergencyWithdrawFromCurve();

        assertTrue(ic.paused());
        assertEq(curveLp.balanceOf(address(ic)), 0);
    }

    function test_EmergencyWithdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ic.emergencyWithdrawFromMorpho();
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

    function test_RescueToken_CanRescueRandom() public {
        MockUSDC6 randomToken = new MockUSDC6();
        randomToken.mint(address(ic), 100e6);

        ic.rescueToken(address(randomToken), alice);
        assertEq(randomToken.balanceOf(alice), 100e6);
    }

    // ==========================================
    // SET INTEGRATIONS
    // ==========================================

    function test_SetStakedInvarCoin() public {
        address newSInvar = makeAddr("newSInvar");
        ic.setStakedInvarCoin(newSInvar);
        assertEq(address(ic.stakedInvarCoin()), newSInvar);
    }

    // ==========================================
    // ORACLE PRICE != $1.00
    // ==========================================

    function test_OracleAt120_CurvePositionValuation() public {
        oracle.updatePrice(120_000_000);

        vm.prank(alice);
        ic.deposit(20_000e6, alice);
        ic.deployToCurve();

        uint256 total = ic.totalAssets();
        assertGt(total, 0);
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

        morpho.simulateYield(50e6);

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
        assertEq(ic.curveLpCostUsdc(), 0);

        usdc.mint(alice, 10_000e6);
        bearToken.mint(alice, 10_000e18);

        vm.startPrank(alice);
        bearToken.approve(address(ic), 10_000e18);
        ic.lpDeposit(10_000e6, 10_000e18, alice, 0);
        vm.stopPrank();

        assertGt(ic.curveLpCostUsdc(), 0);
    }

    function test_LpDeposit_RevertsWhenPaused() public {
        ic.pause();

        vm.expectRevert();
        vm.prank(alice);
        ic.lpDeposit(1000e6, 0, alice, 0);
    }

    // ==========================================
    // CONSTRUCTOR VALIDATION
    // ==========================================

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(InvarCoin.InvarCoin__ZeroAddress.selector);
        new InvarCoin(
            address(0),
            address(bearToken),
            address(curveLp),
            address(morpho),
            address(curve),
            address(oracle),
            address(0)
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
        uint256 minted = ic.deposit(amount, alice);

        vm.prank(alice);
        uint256 usdcOut = ic.withdraw(minted, alice, 0);

        assertGe(usdcOut, amount * 99 / 100, "Round trip lost more than 1%");
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

        assertGe(totalValueReturned, depositAmount * 95 / 100, "Whale exit returned less than 95%");
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

        assertEq(ic.curveLpCostUsdc(), 0);

        ic.deployToCurve();

        assertGt(ic.curveLpCostUsdc(), 0);
    }

    function test_ReplenishBuffer_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 toWithdraw = ic.balanceOf(alice) / 10;
        vm.prank(alice);
        ic.withdraw(toWithdraw, alice, 0);

        uint256 costBefore = ic.curveLpCostUsdc();
        ic.replenishBuffer();

        assertLt(ic.curveLpCostUsdc(), costBefore);
    }

    function test_LpWithdraw_ReducesCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();

        uint256 costBefore = ic.curveLpCostUsdc();
        assertGt(costBefore, 0);

        uint256 bal = ic.balanceOf(alice);
        vm.prank(alice);
        ic.lpWithdraw(bal, 0, 0);

        assertEq(ic.curveLpCostUsdc(), 0);
    }

    function test_EmergencyWithdrawFromCurve_ResetsCostBasis() public {
        vm.prank(alice);
        ic.deposit(20_000e6, alice);

        ic.deployToCurve();
        assertGt(ic.curveLpCostUsdc(), 0);

        ic.emergencyWithdrawFromCurve();

        assertEq(ic.curveLpCostUsdc(), 0);
    }

}

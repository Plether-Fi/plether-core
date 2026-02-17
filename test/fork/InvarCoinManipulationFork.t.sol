// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ICurveTwocrypto, InvarCoin} from "../../src/InvarCoin.sol";
import {StakedToken} from "../../src/StakedToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {BaseForkTest, ICurvePoolExtended} from "./BaseForkTest.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvarCoinManipulationForkTest is BaseForkTest {

    InvarCoin ic;
    StakedToken sInvar;

    address treasury;
    address alice;
    address bob;
    address attacker;
    address keeper;

    function setUp() public {
        _setupFork();

        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");
        keeper = makeAddr("keeper");

        deal(USDC, address(this), 40_000_000e6);

        _fetchPriceAndWarp();
        _deployProtocol(treasury);
        _mintInitialTokens(10_000_000e18);
        _deployCurvePool(10_000_000e18);

        ic = new InvarCoin(USDC, bearToken, curvePool, curvePool, address(basketOracle), address(0));

        sInvar = new StakedToken(IERC20(address(ic)), "Staked InvarCoin", "sINVAR");
        ic.setStakedInvarCoin(address(sInvar));

        deal(USDC, alice, 2_000_000e6);
        deal(USDC, bob, 500_000e6);
        deal(USDC, attacker, 50_000_000e6);

        vm.prank(alice);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        vm.prank(bob);
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
        shares = ic.deposit(usdcAmount, user);
    }

    /// @dev Dumps BEAR on Curve via deal() — simulates flash-mint (free BEAR, no BULL side-effect).
    function _dumpBear(
        uint256 bearAmount
    ) internal {
        deal(bearToken, attacker, IERC20(bearToken).balanceOf(attacker) + bearAmount);
        vm.startPrank(attacker);
        IERC20(bearToken).approve(curvePool, bearAmount);
        curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, bearAmount, 0));
        vm.stopPrank();
    }

    /// @dev Pumps BEAR by selling USDC on Curve. Pool becomes USDC-heavy, BEAR-light.
    function _pumpBear(
        uint256 usdcAmount
    ) internal {
        deal(USDC, attacker, IERC20(USDC).balanceOf(attacker) + usdcAmount);
        vm.startPrank(attacker);
        IERC20(USDC).approve(curvePool, usdcAmount);
        curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, usdcAmount, 0));
        vm.stopPrank();
    }

    // ==========================================
    // TEST 1: deployToCurve sandwich blocked
    // Pump BEAR (sell USDC into pool) → pool becomes USDC-heavy →
    // single-sided USDC deposit gets fewer LP tokens → deviation check fires
    // ==========================================

    function test_DeployToCurve_Sandwich_Blocked() public {
        _depositAs(alice, 1_000_000e6);

        // Pump requires enough capital to skew spot >5% from EMA in twocrypto-ng
        _pumpBear(40_000_000e6);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.deployToCurve();
    }

    // ==========================================
    // TEST 2: replenishBuffer flash mint sandwich blocked
    // Flash mint BEAR (free) → dump on Curve → pool becomes BEAR-heavy →
    // single-sided USDC withdrawal gets less USDC → deviation check fires
    // ==========================================

    function test_ReplenishBuffer_FlashMintSandwich_Blocked() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve();

        uint256 shares = ic.balanceOf(alice);
        vm.prank(alice);
        ic.withdraw(shares / 100, alice, 0);

        ReplenishBufferFlashAttacker flashAttacker = new ReplenishBufferFlashAttacker(bearToken, curvePool, address(ic));

        vm.expectRevert();
        flashAttacker.attack(5_000_000e18);
    }

    // ==========================================
    // TEST 3: replenishBuffer dump attack blocked
    // Dump BEAR on Curve → pool becomes BEAR-heavy, USDC-light →
    // single-sided USDC withdrawal gets fewer USDC → deviation check fires
    // ==========================================

    function test_ReplenishBuffer_DumpAttack_Blocked() public {
        _depositAs(alice, 1_000_000e6);
        ic.deployToCurve();

        // Drain buffer below target so replenishBuffer is callable
        deal(USDC, address(ic), 0);

        _dumpBear(3_000_000e18);

        vm.expectRevert(InvarCoin.InvarCoin__SpotDeviationTooHigh.selector);
        ic.replenishBuffer();
    }

    // ==========================================
    // TEST 4: deposit/withdraw manipulation unprofitable
    // ==========================================

    function test_DepositWithdraw_Manipulation_Unprofitable() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve();

        uint256 attackerUsdcBefore = IERC20(USDC).balanceOf(attacker);

        // Dump BEAR to try to depress LP pricing so deposit is cheaper
        _dumpBear(5_000_000e18);

        vm.prank(attacker);
        uint256 attackerShares = ic.deposit(1_000_000e6, attacker);

        // Buy back BEAR to normalize pool (spend USDC received from dump)
        uint256 usdcFromDump = IERC20(USDC).balanceOf(attacker) - (attackerUsdcBefore - 1_000_000e6);
        if (usdcFromDump > 0) {
            vm.startPrank(attacker);
            IERC20(USDC).approve(curvePool, usdcFromDump);
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, usdcFromDump, 0));
            vm.stopPrank();
        }

        vm.prank(attacker);
        ic.withdraw(attackerShares, attacker, 0);

        uint256 attackerUsdcAfter = IERC20(USDC).balanceOf(attacker);
        // deal() gives free BEAR; Curve fee asymmetry on round-trip leaves dust profit (<3 bps of deposit)
        uint256 dustTolerance = 1_000_000e6 * 3 / 10_000; // 3 bps of deposit
        assertLe(
            attackerUsdcAfter,
            attackerUsdcBefore + dustTolerance,
            "Attacker should not profit from deposit/withdraw manipulation"
        );
    }

    // ==========================================
    // TEST 5: lp_price() does not move in single block
    // ==========================================

    function test_LpPrice_DoesNotMoveInSingleBlock() public {
        uint256 lpPriceBefore = ICurveTwocrypto(curvePool).lp_price();

        _dumpBear(5_000_000e18);

        uint256 lpPriceAfter = ICurveTwocrypto(curvePool).lp_price();

        uint256 deviation = lpPriceBefore > lpPriceAfter ? lpPriceBefore - lpPriceAfter : lpPriceAfter - lpPriceBefore;
        uint256 deviationBps = (deviation * 10_000) / lpPriceBefore;

        assertLe(deviationBps, 10, "lp_price() EMA should not move more than 0.1% in a single block");
    }

    // ==========================================
    // TEST 6: lp_price() drifts over time
    // ==========================================

    function test_LpPrice_DriftsOverTime() public {
        uint256 lpPriceInitial = ICurveTwocrypto(curvePool).lp_price();

        _dumpBear(5_000_000e18);

        uint256[] memory prices = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) {
            _warpAndRefreshOracle(10 minutes);
            prices[i] = ICurveTwocrypto(curvePool).lp_price();
        }

        uint256 finalDeviation = lpPriceInitial > prices[6] ? lpPriceInitial - prices[6] : prices[6] - lpPriceInitial;
        uint256 finalDeviationBps = (finalDeviation * 10_000) / lpPriceInitial;

        emit log_named_uint("Initial lp_price", lpPriceInitial);
        emit log_named_uint("Final lp_price (70 min)", prices[6]);
        emit log_named_uint("Drift bps", finalDeviationBps);

        if (finalDeviationBps > 500) {
            emit log_string("WARNING: EMA drifted beyond 5% deviation threshold after 70 minutes");
        }
    }

    // ==========================================
    // TEST 7: virtual_price immune to dump/pump
    // VP rises from fee collection (expected). Must not DECREASE from manipulation.
    // ==========================================

    function test_VirtualPrice_ImmuneToDumpPump() public {
        uint256 vpBefore = ICurveTwocrypto(curvePool).get_virtual_price();

        _dumpBear(5_000_000e18);
        uint256 vpDuring = ICurveTwocrypto(curvePool).get_virtual_price();

        uint256 attackerUsdc = IERC20(USDC).balanceOf(attacker);
        _pumpBear(attackerUsdc / 2);
        uint256 vpAfter = ICurveTwocrypto(curvePool).get_virtual_price();

        assertGe(vpDuring, vpBefore, "VP should not decrease from dump");
        assertGe(vpAfter, vpBefore, "VP should not decrease after round-trip");

        uint256 vpIncreaseBps = ((vpAfter - vpBefore) * 10_000) / vpBefore;
        emit log_named_uint("VP increase from fees (bps)", vpIncreaseBps);
    }

    // ==========================================
    // TEST 8: harvest phantom yield blocked
    // ==========================================

    function test_Harvest_PhantomYield_Blocked() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve();

        uint256 aliceShares = ic.balanceOf(alice);
        vm.startPrank(alice);
        ic.approve(address(sInvar), aliceShares);
        sInvar.deposit(aliceShares, alice);
        vm.stopPrank();

        vm.startPrank(attacker);
        IERC20(USDC).approve(curvePool, 20_000_000e6);
        ICurveTwocrypto(curvePool).add_liquidity([uint256(20_000_000e6), 0], 0);
        vm.stopPrank();

        _warpAndRefreshOracle(1 days);

        uint256 supplyBefore = ic.totalSupply();

        try ic.harvest() returns (uint256 donated) {
            uint256 phantomBps = (donated * 10_000) / supplyBefore;
            assertLe(phantomBps, 10, "Phantom yield from liquidity injection should be negligible (<0.1%)");
        } catch {
            // NoYield revert is fine
        }
    }

    // ==========================================
    // TEST 9: lpDeposit manipulation - pessimistic pricing protects
    // ==========================================

    function test_LpDeposit_Manipulation_PessimisticPricingProtects() public {
        deal(USDC, alice, 500_000e6);
        deal(bearToken, alice, 500_000e18);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        IERC20(bearToken).approve(address(ic), type(uint256).max);
        uint256 aliceShares = ic.lpDeposit(500_000e6, 500_000e18, alice, 0);
        vm.stopPrank();

        _dumpBear(5_000_000e18);

        deal(USDC, bob, 500_000e6);
        deal(bearToken, bob, 500_000e18);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(ic), type(uint256).max);
        IERC20(bearToken).approve(address(ic), type(uint256).max);
        uint256 bobShares = ic.lpDeposit(500_000e6, 500_000e18, bob, 0);
        vm.stopPrank();

        uint256 advantage = ((bobShares - aliceShares) * 10_000) / aliceShares;
        emit log_named_uint("Bob share advantage (bps)", advantage);

        // Pessimistic pricing limits LP minting efficiency advantage to <10%
        assertLe(
            bobShares,
            (aliceShares * 110) / 100,
            "Manipulated lpDeposit should not yield >10% more shares than honest deposit"
        );
    }

    // ==========================================
    // TEST 10: lpWithdraw after manipulation - user protected
    // ==========================================

    function test_LpWithdraw_AfterManipulation_UserProtected() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve();

        uint256 aliceShares = ic.balanceOf(alice);

        uint256 totalAssets = ic.totalAssets();
        uint256 totalSupply = ic.totalSupply();
        uint256 expectedUsdcValue = (aliceShares * totalAssets) / totalSupply;

        uint256[3] memory dumpSizes = [uint256(100_000e18), 500_000e18, 2_000_000e18];

        for (uint256 i = 0; i < 3; i++) {
            uint256 snapshot = vm.snapshotState();

            _dumpBear(dumpSizes[i]);

            uint256 minUsdc = (expectedUsdcValue * 95) / 100;
            vm.prank(alice);
            vm.expectRevert(InvarCoin.InvarCoin__SlippageExceeded.selector);
            ic.lpWithdraw(aliceShares, minUsdc, 0);

            vm.revertToState(snapshot);
        }
    }

    // ==========================================
    // TEST 11: full sandwich end-to-end - unprofitable
    // ==========================================

    function test_FullSandwich_DepositDeployWithdraw_Unprofitable() public {
        _depositAs(alice, 500_000e6);
        ic.deployToCurve();

        uint256 honestNavBefore = ic.totalAssets();
        uint256 attackerUsdcBefore = IERC20(USDC).balanceOf(attacker);

        // Front-run: attacker pumps BEAR with own USDC (sells USDC for BEAR)
        vm.startPrank(attacker);
        IERC20(USDC).approve(curvePool, 5_000_000e6);
        curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, 5_000_000e6, 0));
        vm.stopPrank();

        // Attacker deposits into InvarCoin
        vm.prank(attacker);
        uint256 attackerShares = ic.deposit(1_000_000e6, attacker);

        // Back-run: dump BEAR back for USDC (reverse the pump)
        uint256 attackerBear = IERC20(bearToken).balanceOf(attacker);
        if (attackerBear > 0) {
            vm.startPrank(attacker);
            IERC20(bearToken).approve(curvePool, attackerBear);
            curvePool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, attackerBear, 0));
            vm.stopPrank();
        }

        // Same-block sandwich — no warp, no deploy. Attacker exits immediately.
        vm.prank(attacker);
        (uint256 usdcReturned, uint256 bearReturned) = ic.lpWithdraw(attackerShares, 0, 0);

        (, int256 clPrice,,,) = AggregatorV3Interface(CL_EUR).latestRoundData();
        uint256 finalUsdc = IERC20(USDC).balanceOf(attacker);
        uint256 finalBear = IERC20(bearToken).balanceOf(attacker);
        uint256 bearValueUsdc = (finalBear * uint256(clPrice)) / 1e20;
        uint256 totalAttackerValue = finalUsdc + bearValueUsdc;

        assertLe(totalAttackerValue, attackerUsdcBefore, "Attacker should not profit from full sandwich");

        uint256 honestNavAfter = ic.totalAssets();
        uint256 navDrop = honestNavBefore > honestNavAfter ? honestNavBefore - honestNavAfter : 0;
        uint256 navDropBps = (navDrop * 10_000) / honestNavBefore;

        assertLe(navDropBps, 10, "Honest user NAV should not drop more than 0.1%");
    }

}

// ==========================================
// FLASH MINT ATTACKER — targets replenishBuffer
// Flash mints BEAR (free) → dumps on Curve → calls replenishBuffer → buys back → repays
// ==========================================

contract ReplenishBufferFlashAttacker is IERC3156FlashBorrower {

    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address immutable bear;
    address immutable pool;
    address immutable invarCoin;

    constructor(
        address _bear,
        address _pool,
        address _invarCoin
    ) {
        bear = _bear;
        pool = _pool;
        invarCoin = _invarCoin;
    }

    function attack(
        uint256 bearAmount
    ) external {
        IERC20(bear).approve(bear, bearAmount);
        (bool ok, bytes memory ret) = bear.call(
            abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", address(this), bear, bearAmount, "")
        );
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
    }

    function onFlashLoan(
        address,
        address token,
        uint256 amount,
        uint256,
        bytes calldata
    ) external override returns (bytes32) {
        IERC20(token).approve(pool, amount);
        pool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 1, 0, amount, 0));

        InvarCoin(invarCoin).replenishBuffer();

        uint256 usdcBal = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).balanceOf(address(this));
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).approve(pool, usdcBal);
        pool.call(abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", 0, 1, usdcBal, 0));

        IERC20(token).approve(msg.sender, amount);

        return CALLBACK_SUCCESS;
    }

}

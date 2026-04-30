// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract LiquidationTest is BasePerpTest {

    address alice = address(0x111);
    address keeper = address(0x999);

    uint256 constant WEDNESDAY_NOON = 1_729_080_000;
    uint256 constant FRIDAY_EVENING = 1_729_281_600;

    function setUp() public override {
        super.setUp();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(alice, 10_000 * 1e6);
        vm.stopPrank();
    }

    function _withdrawFreeUsdc(
        address trader,
        uint256 reserveUsdc
    ) internal {
        address account = trader;
        uint256 balance = clearinghouse.balanceUsdc(account);
        uint256 locked = clearinghouse.lockedMarginUsdc(account);
        uint256 withdrawable = balance > locked + reserveUsdc ? balance - locked - reserveUsdc : 0;
        if (withdrawable > 0) {
            vm.prank(trader);
            clearinghouse.withdraw(account, withdrawable);
        }
    }

    function test_FridayAutoDeleverage() public {
        vm.warp(WEDNESDAY_NOON);
        assertEq(_maintenanceMarginUsdc(100_000 * 1e18, 1e8), 1000 * 1e6, "MMR should be 1.0% ($1k) on Wednesday");

        // Alice opens 50x BULL (Size $100k, Margin $2k)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        // Keeper tries to liquidate immediately. Should REVERT.
        vm.startPrank(keeper);
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, empty);
        vm.stopPrank();

        // FAD Window activates
        vm.warp(FRIDAY_EVENING);
        assertEq(
            _maintenanceMarginUsdc(100_000 * 1e18, 1e8), 3000 * 1e6, "MMR should jump to 3.0% ($3k) on Friday evening"
        );

        // Keeper liquidates. $3k required but only ~$2k margin → liquidatable.
        uint256 keeperSettlementBefore = _settlementBalance(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(account, empty);
        vm.stopPrank();

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be wiped");

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        assertEq(bounty, 100 * 1e6, "Keeper should receive $100 USDC bounty (0.10% of $100k)");

        // Ethical: Alice keeps surplus equity after the keeper bounty and the carry accrued between open and FAD liquidation.
        uint256 chBalance = clearinghouse.balanceUsdc(account);
        assertApproxEqAbs(chBalance, 1_828_663_014, 1, "Alice keeps surplus equity after ethical liquidation");
    }

    function test_LiquidationOnPriceDrop() public {
        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        // BULL loses when price rises. Price rises to $1.015
        // PnL = -$0.015 * 100k = -$1500. Equity = $2000 - $1500 = $500
        // Required margin = 1% of $101.5k = $1015. $500 < $1015 → liquidatable
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        uint256 keeperSettlementBefore = _settlementBalance(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(account, pythData);
        vm.stopPrank();

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        assertTrue(bounty > 0, "Keeper should get bounty");

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be wiped");

        // Ethical: user should retain equity - bounty
        // PnL = -$1500, Margin = $1960 (after 4 bps fee), Equity = $460
        // Bounty ~ 0.10% * $101.5k = $101.50, above the $5 floor.
        // Residual = $460 - $101.50 = $358.50
        uint256 chBalance = clearinghouse.balanceUsdc(account);
        assertApproxEqAbs(chBalance, 358_500_000, 1, "Alice retains equity net of keeper bounty");
    }

    function test_SolventPosition_RevertsLiquidation() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, empty);
    }

    function test_KeeperBounty_CappedAtEquity() public {
        vm.warp(WEDNESDAY_NOON);

        // 6000 tokens at $1 = $6000 notional (above the $5000 minimum)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 6000 * 1e18, 200 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;
        (, uint256 posMargin,,,,,) = engine.positions(account);

        // BULL loses when price rises. At $1.06:
        // PnL = 6000 * $0.06 = -$360. equity = posMargin - $360 < 0 → liquidatable.
        // Bounty capped at posMargin (vault never pays more than it recovers).
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.06e8);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        vm.prank(keeper);
        router.executeLiquidation(account, pythData);
        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;

        // Proportional bounty (0.10% of ~$6360 = ~$6.36) stays below posMargin, so the cap does not bind.
        assertGt(bounty, 0, "Keeper still incentivized on negative-equity liquidation");
        assertLe(bounty, posMargin, "Bounty never exceeds margin vault can seize");
        assertGe(usdc.balanceOf(address(pool)), poolBefore, "Vault never pays more than it seizes");
    }

    function obsolete_LiquidationEquity_IncludesLegacySpread() public {
        // Enable nonzero carry (setUp has baseCarryBps=0)
        _setRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                maintMarginBps: 100,
                initMarginBps: ((100) * 15) / 10,
                fadMarginBps: 300,
                baseCarryBps: 500,
                carryKinkUtilizationBps: 7000,
                carrySlope1Bps: 0,
                carrySlope2Bps: 0,
                minBountyUsdc: 1 * 1e6,
                bountyBps: 10
            })
        );

        vm.warp(WEDNESDAY_NOON);

        // Alice opens a lone BULL — will accumulate legacy negative spread
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        // Without legacy-spread, $3k margin at same price is solvent (MMR = 1% of $100k = $1k)
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, empty);

        // Warp 180 days — massive negative carry drains equity below MMR
        vm.warp(WEDNESDAY_NOON + 180 days);

        // Now liquidatable due to carry erosion (no price change needed)
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        vm.prank(keeper);
        router.executeLiquidation(account, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position liquidated by carry drain alone");
        // Carry drain pushes equity negative -> bounty capped at remaining margin
        assertGe(_settlementBalance(keeper), keeperSettlementBefore, "Keeper gets bounty from remaining margin");
    }

    function test_KeeperBounty_PaidFromVault() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        address account = alice;
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 chBefore = clearinghouse.balanceUsdc(account);
        uint256 keeperSettlementBefore = _settlementBalance(keeper);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        vm.prank(keeper);
        router.executeLiquidation(account, pythData);

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        uint256 chAfter = clearinghouse.balanceUsdc(account);
        uint256 poolAfter = usdc.balanceOf(address(pool));

        uint256 userSeized = chBefore - chAfter;
        assertEq(
            poolAfter, poolBefore + userSeized - bounty, "Vault intermediates: receives seized margin, pays bounty"
        );
    }

    function test_FadWindow_ExactBoundaries() public {
        // Friday 18:59:59 UTC → NOT FAD
        vm.warp(1_729_277_999);
        assertFalse(engine.isFadWindow(), "Friday 18:59 is not FAD");

        // Friday 19:00:00 UTC → FAD begins
        vm.warp(1_729_278_000);
        assertTrue(engine.isFadWindow(), "Friday 19:00 is FAD");

        // Saturday midday → FAD (all Saturday is FAD)
        vm.warp(1_729_278_000 + 17 hours);
        assertTrue(engine.isFadWindow(), "Saturday is FAD");

        // Sunday 21:59:59 UTC → still FAD
        vm.warp(1_729_461_599);
        assertTrue(engine.isFadWindow(), "Sunday 21:59 is FAD");

        // Sunday 22:00:00 UTC → FAD ends
        vm.warp(1_729_461_600);
        assertFalse(engine.isFadWindow(), "Sunday 22:00 is not FAD");
    }

}

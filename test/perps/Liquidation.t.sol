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
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), 10_000 * 1e6);
        vm.stopPrank();
    }

    function _withdrawFreeUsdc(
        address trader,
        uint256 reserveUsdc
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        uint256 balance = clearinghouse.balanceUsdc(accountId);
        uint256 locked = clearinghouse.lockedMarginUsdc(accountId);
        uint256 withdrawable = balance > locked + reserveUsdc ? balance - locked - reserveUsdc : 0;
        if (withdrawable > 0) {
            vm.prank(trader);
            clearinghouse.withdraw(accountId, withdrawable);
        }
    }

    function test_FridayAutoDeleverage() public {
        vm.warp(WEDNESDAY_NOON);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8), 1000 * 1e6, "MMR should be 1.0% ($1k) on Wednesday"
        );

        // Alice opens 50x BULL (Size $100k, Margin $2k)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Keeper tries to liquidate immediately. Should REVERT.
        vm.startPrank(keeper);
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        // FAD Window activates
        vm.warp(FRIDAY_EVENING);
        assertEq(
            engine.getMaintenanceMarginUsdc(100_000 * 1e18, 1e8),
            3000 * 1e6,
            "MMR should jump to 3.0% ($3k) on Friday evening"
        );

        // Keeper liquidates. $3k required but only ~$2k margin → liquidatable.
        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, empty);
        vm.stopPrank();

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertEq(bounty, 150 * 1e6, "Keeper should receive $150 USDC bounty (0.15% of $100k)");

        // Ethical: Alice keeps surplus equity
        // Opening: exec fee = 4 bps of $100k = $40. pos.margin = $2000 - $40 = $1960.
        // Clearinghouse after open and withdrawing free USDC: locked margin remains $1960.
        // Liquidation: equity = $1960 + $0 (PnL) = $1960. Bounty = $150.
        // residual = $1960 - $150 = $1810. toSeize = $1960 - $1810 = $150.
        uint256 chBalance = clearinghouse.balanceUsdc(accountId);
        assertEq(chBalance, 1810 * 1e6, "Alice keeps surplus equity after ethical liquidation");
    }

    function test_LiquidationOnPriceDrop() public {
        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // BULL loses when price rises. Price rises to $1.015
        // PnL = -$0.015 * 100k = -$1500. Equity = $2000 - $1500 = $500
        // Required margin = 1% of $101.5k = $1015. $500 < $1015 → liquidatable
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        uint256 keeperBalBefore = usdc.balanceOf(keeper);

        vm.startPrank(keeper);
        router.executeLiquidation(accountId, pythData);
        vm.stopPrank();

        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;
        assertTrue(bounty > 0, "Keeper should get bounty");

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be wiped");

        // Ethical: user should retain equity - bounty
        // PnL = -$1500, Margin = $1960 (after 4 bps fee), Equity = $460
        // Bounty ~ 0.15% * $101.5k = $152.25, but min $5 → $152.25
        // Residual = $460 - $152.25 = $307.75
        uint256 chBalance = clearinghouse.balanceUsdc(accountId);
        assertApproxEqAbs(chBalance, 307_750_000, 1, "Alice retains equity net of keeper bounty");
    }

    function test_SolventPosition_RevertsLiquidation() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
    }

    function test_KeeperBounty_CappedAtEquity() public {
        vm.warp(WEDNESDAY_NOON);

        // 4000 tokens at $1 = $4000 notional (above $3,333 minimum)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 4000 * 1e18, 200 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (, uint256 posMargin,,,,,,) = engine.positions(accountId);

        // BULL loses when price rises. At $1.06:
        // PnL = 4000 * $0.06 = -$240. equity = posMargin - $240 < 0 → liquidatable.
        // Bounty capped at posMargin (vault never pays more than it recovers).
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.06e8);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 keeperBalBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        router.executeLiquidation(accountId, pythData);
        uint256 bounty = usdc.balanceOf(keeper) - keeperBalBefore;

        // Proportional bounty (0.15% of ~$4240 = ~$6.36) is below posMargin, so cap doesn't bind
        assertGt(bounty, 0, "Keeper still incentivized on negative-equity liquidation");
        assertLe(bounty, posMargin, "Bounty never exceeds margin vault can seize");
        assertGe(usdc.balanceOf(address(pool)), poolBefore, "Vault never pays more than it seizes");
    }

    function test_LiquidationEquity_IncludesFunding() public {
        // Enable funding (setUp has baseApy=0)
        engine.proposeRiskParams(
            CfdTypes.RiskParams({
                vpiFactor: 0,
                maxSkewRatio: 0.4e18,
                kinkSkewRatio: 0.25e18,
                baseApy: 0.15e18,
                maxApy: 3.0e18,
                maintMarginBps: 100,
                fadMarginBps: 300,
                minBountyUsdc: 5 * 1e6,
                bountyBps: 15
            })
        );
        vm.warp(block.timestamp + 48 hours + 1);
        engine.finalizeRiskParams();

        vm.warp(WEDNESDAY_NOON);

        // Alice opens a lone BULL — will accumulate negative funding
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        // Without funding, $3k margin at same price is solvent (MMR = 1% of $100k = $1k)
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);

        // Warp 180 days — massive negative funding drains equity below MMR
        vm.warp(WEDNESDAY_NOON + 180 days);

        // Now liquidatable due to funding erosion (no price change needed)
        uint256 keeperBal = usdc.balanceOf(keeper);
        vm.prank(keeper);
        router.executeLiquidation(accountId, empty);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position liquidated by funding drain alone");
        // Funding drain pushes equity negative → bounty capped at remaining margin
        assertGe(usdc.balanceOf(keeper), keeperBal, "Keeper gets bounty from remaining margin");
    }

    function test_KeeperBounty_PaidFromVault() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);
        _withdrawFreeUsdc(alice, 0);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (, uint256 posMargin,,,,,,) = engine.positions(accountId);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 chBefore = clearinghouse.balanceUsdc(accountId);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        vm.prank(keeper);
        router.executeLiquidation(accountId, pythData);

        uint256 bounty = usdc.balanceOf(keeper);
        uint256 chAfter = clearinghouse.balanceUsdc(accountId);
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

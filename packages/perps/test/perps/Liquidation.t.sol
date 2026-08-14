// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

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

        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        // Keeper tries to liquidate immediately. Should REVERT.
        bytes[] memory solventPriceData = _mockPythUpdateData();
        vm.startPrank(keeper);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, solventPriceData);
        vm.stopPrank();

        // FAD Window activates
        vm.warp(FRIDAY_EVENING);
        assertEq(
            _maintenanceMarginUsdc(100_000 * 1e18, 1e8), 3000 * 1e6, "MMR should jump to 3.0% ($3k) on Friday evening"
        );

        // Keeper liquidates. $3k required but only ~$2k margin → liquidatable.
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        uint256 protocolTreasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1e8);

        vm.startPrank(keeper);
        router.executeLiquidation(account, _mockPythUpdateData());
        vm.stopPrank();

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position should be wiped");

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        assertEq(preview.liquidationChargeUsdc, 100 * 1e6, "Liquidation should retain the 10 bps total charge");
        assertEq(bounty, 50 * 1e6, "Keeper should receive 5 bps of the $100k notional");
        assertEq(preview.protocolLiquidationFeeUsdc, 0, "Protocol liquidation fee should default to zero");
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            protocolTreasuryBefore,
            "Default liquidation should not credit the protocol treasury"
        );
        assertEq(preview.lpLiquidationFeeUsdc, 50 * 1e6, "LPs should receive the other 5 bps");

        // Ethical: Alice keeps surplus equity after the total charge and carry accrued between open and FAD liquidation.
        uint256 chBalance = clearinghouse.balanceUsdc(account);
        assertApproxEqAbs(chBalance, 1_856_935_243, 1, "Alice keeps surplus equity after ethical liquidation");
    }

    function test_LiquidationOnPriceDrop() public {
        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());
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

        // Ethical: user should retain equity minus the total liquidation charge.
        // PnL = -$1500, Margin = $1960 (after 4 bps fee), Equity = $460
        // Total charge ~ 0.10% * $101.5k = $101.50, above the $5 floor.
        // Residual = $460 - $101.50 = $358.50
        uint256 chBalance = clearinghouse.balanceUsdc(account);
        assertApproxEqAbs(chBalance, 358_500_000, 1, "Alice retains equity net of the total liquidation charge");
    }

    function test_SolventPosition_RevertsLiquidation() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 2000 * 1e6, 1e8, false);

        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        bytes[] memory solventPriceData = _mockPythUpdateData();
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, solventPriceData);
    }

    function test_KeeperBounty_CappedAtEquity() public {
        vm.warp(WEDNESDAY_NOON);

        // 6000 tokens at $1 = $6000 notional (above the $5000 minimum)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 6000 * 1e18, 200 * 1e6, 1e8, false);

        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;
        (, uint256 posMargin,,,,,) = engine.positions(account);

        // BULL loses when price rises. At $1.06:
        // PnL = 6000 * $0.06 = -$360. equity = posMargin - $360 < 0 → liquidatable.
        // Total charge is capped at reachable collateral (the pool never pays more than it recovers).
        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.06e8);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        vm.prank(keeper);
        router.executeLiquidation(account, pythData);
        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;

        // Proportional charge (0.10% of ~$6360 = ~$6.36) stays below posMargin, so the cap does not bind.
        assertGt(bounty, 0, "Keeper still incentivized on negative-equity liquidation");
        assertLe(bounty, posMargin, "Bounty never exceeds margin pool can seize");
        assertGe(usdc.balanceOf(address(pool)), poolBefore, "Pool never pays more than it seizes");
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
                minBountyUsdc: 1 * 1e6,
                bountyBps: 10,
                keeperShareBps: 5000,
                protocolShareBps: 0
            })
        );

        vm.warp(WEDNESDAY_NOON);

        // Alice opens a lone BULL — will accumulate legacy negative spread
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 3000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;

        // Without legacy-spread, $3k margin at same price is solvent (MMR = 1% of $100k = $1k)
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(account, _mockPythUpdateData());

        // Warp 180 days — massive negative carry drains equity below MMR
        vm.warp(WEDNESDAY_NOON + 180 days);

        // Now liquidatable due to carry erosion (no price change needed)
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        vm.prank(keeper);
        router.executeLiquidation(account, _mockPythUpdateData());

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Position liquidated by carry drain alone");
        // Carry drain pushes equity negative -> bounty capped at remaining margin
        assertGe(_settlementBalance(keeper), keeperSettlementBefore, "Keeper gets bounty from remaining margin");
    }

    function test_LiquidationCharge_SplitsEquallyBetweenKeeperAndLps() public {
        vm.warp(WEDNESDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 chBefore = clearinghouse.balanceUsdc(account);
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        uint256 protocolTreasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.015e8);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);

        vm.prank(keeper);
        router.executeLiquidation(account, pythData);

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        uint256 chAfter = clearinghouse.balanceUsdc(account);
        uint256 poolAfter = usdc.balanceOf(address(pool));
        uint256 protocolFee = clearinghouse.balanceUsdc(engine.protocolTreasury()) - protocolTreasuryBefore;

        uint256 userSeized = chBefore - chAfter;
        assertEq(bounty, preview.keeperBountyUsdc, "Keeper should receive the previewed half of the charge");
        assertEq(protocolFee, 0, "Protocol liquidation fee should default to zero");
        assertEq(
            preview.keeperBountyUsdc,
            preview.lpLiquidationFeeUsdc,
            "Even-micro liquidation charge should split exactly 50/50"
        );
        assertEq(
            preview.liquidationChargeUsdc,
            preview.keeperBountyUsdc + preview.protocolLiquidationFeeUsdc + preview.lpLiquidationFeeUsdc,
            "Keeper, protocol, and LP shares should conserve the total charge"
        );
        assertEq(
            poolAfter,
            poolBefore + userSeized - bounty - protocolFee,
            "Pool should receive every account debit except keeper and protocol allocations"
        );
    }

    function test_LiquidationCharge_UsesConfiguredKeeperAndProtocolShares() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.keeperShareBps = 2500;
        params.protocolShareBps = 2500;
        _setRiskParams(params);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 2000 * 1e6, 1e8, false);
        router.executeOrder(1, _mockPythUpdateData());
        _withdrawFreeUsdc(alice, 0);

        address account = alice;
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 chBefore = clearinghouse.balanceUsdc(account);
        uint256 keeperSettlementBefore = _settlementBalance(keeper);
        uint256 protocolTreasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.015e8);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(1.015e8);
        vm.prank(keeper);
        router.executeLiquidation(account, pythData);

        uint256 bounty = _settlementBalance(keeper) - keeperSettlementBefore;
        uint256 chAfter = clearinghouse.balanceUsdc(account);
        uint256 poolAfter = usdc.balanceOf(address(pool));
        uint256 userSeized = chBefore - chAfter;
        uint256 protocolFee = clearinghouse.balanceUsdc(engine.protocolTreasury()) - protocolTreasuryBefore;

        assertEq(preview.liquidationChargeUsdc, 101_500_000, "Total charge should remain 10 bps");
        assertEq(preview.keeperBountyUsdc, 25_375_000, "Keeper should receive 25% of the charge");
        assertEq(preview.protocolLiquidationFeeUsdc, 25_375_000, "Protocol should receive 25% of the charge");
        assertEq(preview.lpLiquidationFeeUsdc, 50_750_000, "LPs should receive 50% of the charge");
        assertEq(bounty, preview.keeperBountyUsdc, "Live keeper credit should match the configured preview share");
        assertEq(protocolFee, preview.protocolLiquidationFeeUsdc, "Live treasury credit should match the preview");
        assertEq(
            preview.liquidationChargeUsdc,
            preview.keeperBountyUsdc + preview.protocolLiquidationFeeUsdc + preview.lpLiquidationFeeUsdc,
            "Configured allocations should conserve the total charge"
        );
        assertEq(
            poolAfter,
            poolBefore + userSeized - bounty - protocolFee,
            "Pool should receive every account debit except configured keeper and protocol shares"
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

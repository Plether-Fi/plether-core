// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract AuditRemainingCoverageFindingsFailing_EscrowShielding is BasePerpTest {

    address trader = address(0xC10A);

    function test_C1_FullCloseMustNotTreatQueuedCommittedMarginAsLossShield() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 7_900e6, type(uint256).max, false);

        _close(accountId, CfdTypes.Side.BULL, 100_000e18, 103_000_000);

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            0,
            "Queued committed margin should be unwound or counted before socializing a full-close shortfall"
        );
    }

    function test_H1_LiquidationMustUseSameReachableCollateralModelAsSettlement() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 10_000e6);

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 2_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 7_900e6, type(uint256).max, false);

        bytes[] memory empty;
        vm.startPrank(address(router));
        engine.liquidatePosition(accountId, 105_000_000, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(
            engine.accumulatedBadDebtUsdc(),
            0,
            "Liquidation should not record bad debt when queued settlement collateral is still fully seizable"
        );
    }

}

contract AuditRemainingCoverageFindingsFailing_LiquidationBounty is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 10,
            fadMarginBps: 1000,
            minBountyUsdc: 1e6,
            bountyBps: 1000
        });
    }

    function test_H2_PositiveEquityLiquidationBountyMustCapAtRemainingEquity() public {
        address trader = address(0xA201);
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        _fundTrader(trader, 100e6);
        _open(accountId, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(accountId, address(usdc), 94e6);

        vm.startPrank(address(router));
        vm.warp(1_709_971_200);
        uint256 bounty = engine.liquidatePosition(accountId, 101_000_000, pool.totalAssets(), uint64(block.timestamp));
        vm.stopPrank();

        assertEq(bounty, 7_000_000, "Keeper bounty should not exceed the trader's remaining positive equity");
    }

}

contract AuditRemainingCoverageFindingsFailing_DustQueueEconomics is BasePerpTest {

    address trader = address(0xD057);

    function test_H3_DustOrdersMustNotQueueWithoutKeeperReserve() public {
        _fundTrader(trader, 1e6);

        vm.prank(trader);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 1, 0, 0, false);
    }

}

contract AuditRemainingCoverageFindingsFailing_TrancheCooldownDocs is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_M1_FivePercentThirdPartyTopUpMustNotResetExistingHolderCooldown() public {
        _fundJunior(alice, 100_000e6);
        uint256 initialCooldown = juniorVault.lastDepositTime(alice);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 5_000e6);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 5_000e6);
        juniorVault.deposit(5_000e6, alice);
        vm.stopPrank();

        assertEq(
            juniorVault.lastDepositTime(alice),
            initialCooldown,
            "Third-party top-ups should not reset an existing holder cooldown"
        );

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(105_000e6, alice, alice);
    }

}

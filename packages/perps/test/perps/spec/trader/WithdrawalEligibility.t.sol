// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#4-trader-reachability--terminal-settlement-view

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract OpenPositionWithdrawalTest is BasePerpTest {

    address alice = address(0x111);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#4-trader-reachability--terminal-settlement-view.
    function test_HealthyOpenPositionAllowsFreeSettlementWithdrawal() public {
        _fundTrader(alice, 100_000 * 1e6);
        address aliceAccount = alice;

        // Open a small position: 50k tokens, $1000 margin (well above IMR)
        // Notional = $50k; the 1.5% initial-margin requirement is $750.
        _open(aliceAccount, CfdTypes.Side.LONG, 50_000 * 1e18, 1000 * 1e6, 1e8);

        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0);

        uint256 balance = clearinghouse.balanceUsdc(aliceAccount);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceAccount);
        uint256 freeBalance = balance - locked;
        assertGt(freeBalance, 90_000 * 1e6, "Fixture must retain substantial free settlement");

        // The healthy position allows a $1 withdrawal from Alice's free settlement.
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(aliceAccount, 1e6);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + 1e6, "should withdraw $1 of free equity");
    }

}

contract CarryAndMarginCheckpointWithdrawTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xBEEF);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#4-trader-reachability--terminal-settlement-view.
    function test_WithdrawScenarioNowBlocksOnOpenPosition() public {
        address account = alice;
        _fundTrader(alice, 10_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 5000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(103_800_000, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(account, 5000 * 1e6);
    }

}

contract UnderwaterWithdrawalGuardTest is BasePerpTest {

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#4-trader-reachability--terminal-settlement-view.
    function test_UnderwaterPositionBlocksWithdrawal() public {
        address aliceAccount = alice;
        _fundTrader(alice, 100_000e6);

        // LONG profits when price drops, loses when price rises
        _open(aliceAccount, CfdTypes.Side.LONG, 500_000e18, 10_000e6, 1e8);

        // Price rises to 1.15e8 → LONG unrealized loss ≈ 75K.
        // The loss exceeds its isolated PnL pledge. Free settlement does not back price-risk equity,
        // so the account cannot withdraw merely because clearinghouse funds are unencumbered.
        uint256 underwaterPrice = 1.15e8;
        vm.prank(address(router));
        engine.updateMarkPrice(underwaterPrice, uint64(block.timestamp));

        uint256 chBalance = clearinghouse.balanceUsdc(aliceAccount);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceAccount);
        uint256 withdrawable = chBalance - locked;

        // Attempting to withdraw all locally free settlement must fail the Engine health guard.
        vm.prank(alice);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(aliceAccount, withdrawable);
    }

}

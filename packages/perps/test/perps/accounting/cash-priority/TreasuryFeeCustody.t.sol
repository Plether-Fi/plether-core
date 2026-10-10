// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#treasury-fee-withdrawals

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

contract AccountPriceCollateralFeesTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
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

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#treasury-fee-withdrawals.
    function test_ExecutionFeesAccrueToProtocolNotLpEquity() public {
        address aliceAccount = alice;
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertGe(
            equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP distributable equity"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            80e6,
            "Open and close execution fees should both accrue as protocol revenue"
        );
    }

}

contract LiquidationBountyForfeitureTest is BasePerpTest {

    address trader = address(0xA202);
    address counterparty = address(0xA203);
    address keeper = address(0xA204);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#treasury-fee-withdrawals.
    function test_LiquidationForfeitedOrderBountyMustAccrueProtocolFees() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 100_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);

        uint256 forfeitedBounty = _executionBountyReserve(1);
        uint256 feesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(196_000_000));

        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - feesBefore,
            forfeitedBounty,
            "Forfeited queued order bounties should accrue to protocol fees"
        );
    }

}

contract MarginAndReservationAdmissionFeesTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#treasury-fee-withdrawals.
    function test_ExecutionFeesAreProtocolRevenue() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertGe(equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP equity");
        assertLe(
            equityAfter - equityBefore, 1000, "LP equity delta should be limited to incidental one-second senior yield"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            80e6,
            "Open and close execution fees should both accrue as protocol revenue"
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {BasePerpTest} from "./BasePerpTest.sol";

contract ArchitectureRegression_EscrowShielding is BasePerpTest {

    address internal alice = address(0xA11CE);

    function test_GetSettlementReachableUsdc_ExcludesReservedSettlement() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 10_000e6);

        vm.prank(address(engine));
        clearinghouse.lockMargin(accountId, 2_000e6);

        vm.prank(address(router));
        clearinghouse.reserveSettlementUsdc(accountId, 300e6);

        uint256 reachable = clearinghouse.getSettlementReachableUsdc(accountId, 2_000e6);
        assertEq(reachable, 7_700e6, "reachable settlement must exclude reserved keeper escrow");
    }

    function test_SeizeAsset_CannotConsumeReservedSettlement() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 10_000e6);

        vm.prank(address(router));
        clearinghouse.reserveSettlementUsdc(accountId, 300e6);

        vm.prank(address(engine));
        vm.expectRevert();
        clearinghouse.seizeAsset(accountId, address(usdc), 9_800e6, address(engine));
    }

    function test_LiquidationSolvency_MustIgnoreLockedMarginInReachableEquity() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        router.executeLiquidation(accountId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "locked position margin must not be counted as free liquidation equity");
    }
}

contract ArchitectureRegression_SolvencyViews is BasePerpTest {

    address internal alice = address(0xA11CE);
    address internal keeper = address(0xBEEF);

    function test_WithdrawFees_MustHonorDeferredKeeperLiabilities() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.recordDeferredLiquidationBounty(keeper, 950_001e6);

        vm.expectRevert(CfdEngine.CfdEngine__PostOpSolvencyBreach.selector);
        engine.withdrawFees(address(this));
    }

    function test_Reconcile_MustSubtractDeferredLiquidationBounties() public {
        vm.prank(address(router));
        engine.recordDeferredLiquidationBounty(keeper, 100_000e6);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.juniorPrincipal(), 900_000e6, "deferred keeper rewards must reduce LP distributable equity");
    }
}

contract ArchitectureRegression_QueueEconomics is BasePerpTest {

    address internal alice = address(0xA11CE);

    function test_InvalidCloseMustBeRejectedAtCommit() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 20_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BEAR, 100_001e18, 0, 0, true);
    }
}

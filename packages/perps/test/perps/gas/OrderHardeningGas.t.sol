// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {SourceBoundBountyFixture} from "../shared/SourceBoundBountyFixture.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

/// @dev Production-codegen measurements of the boundaries added by bounded order hardening.
contract OrderHardeningGasTest is SourceBoundBountyFixture {

    function test_Gas_HardeningFreshCommit() public {
        _measureCommit(false);
    }

    function test_Gas_HardeningStaleCommit() public {
        _measureCommit(true);
    }

    function _measureCommit(
        bool stale
    ) private {
        _fundTrader(BOUNTY_TRADER, 1000e6);
        vm.prank(address(router));
        engine.updateMarkPrice(BOUNTY_PRICE, uint64(block.timestamp));
        if (stale) {
            vm.warp(block.timestamp + pletherOracle.orderExecutionStalenessLimit() + 1);
        }
        OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 250e6);
        vm.prank(BOUNTY_TRADER);
        uint256 start = gasleft();
        uint64 id = router.commitOrder(request);
        uint256 used = start - gasleft();
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(id)), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(router.accountHeadOrderId(BOUNTY_TRADER), id);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), 1000e6);
        assertGt(_bountyReservation(id).freeFundedUsdc, 0);
        emit log_named_uint(stale ? "hardening_commit_stale" : "hardening_commit_fresh", used);
    }

    function test_Gas_HardeningWithdrawWithoutFloor() public {
        _measureWithdrawal(false);
    }

    function test_Gas_HardeningWithdrawWithFloor() public {
        _measureWithdrawal(true);
    }

    function _measureWithdrawal(
        bool floor
    ) private {
        _fundTrader(BOUNTY_TRADER, 1000e6);
        if (floor) {
            OrderV3Types.OrderRequest memory request = _bountyRequest(CfdTypes.Side.LONG, false, BOUNTY_SIZE, 250e6);
            request.bounds.minPostSettlementBalanceUsdc = 700e6;
            request.bounds.maxGrossAccountDebitUsdc = 200e6;
            vm.prank(BOUNTY_TRADER);
            router.commitOrder(request);
        }
        uint256 wallet = usdc.balanceOf(BOUNTY_TRADER);
        vm.prank(BOUNTY_TRADER);
        uint256 start = gasleft();
        clearinghouse.withdraw(BOUNTY_TRADER, 100e6);
        uint256 used = start - gasleft();
        assertEq(usdc.balanceOf(BOUNTY_TRADER), wallet + 100e6);
        assertEq(clearinghouse.balanceUsdc(BOUNTY_TRADER), 900e6);
        assertEq(router.pendingOrderCounts(BOUNTY_TRADER), floor ? 1 : 0);
        emit log_named_uint(floor ? "hardening_withdraw_floor" : "hardening_withdraw_no_floor", used);
    }

    function test_Gas_HardeningOracleRotation() public {
        bytes32[] memory feeds = new bytes32[](1);
        uint256[] memory weights = new uint256[](1);
        uint256[] memory bases = new uint256[](1);
        feeds[0] = bytes32(uint256(1));
        weights[0] = 1e18;
        bases[0] = 1e8;
        PletherOracle candidate = new PletherOracle(
            address(engine), address(pool), address(baseMockPyth), feeds, weights, bases, new bool[](1)
        );
        routerAdmin.proposeOracleConfig(IOrderRouterAdminHost.OracleConfig(address(candidate)));
        vm.warp(routerAdmin.oracleConfigActivationTime());
        uint64 version = routerAdmin.activeConfigVersion();
        uint256 start = gasleft();
        routerAdmin.finalizeOracleConfig();
        uint256 used = start - gasleft();
        assertEq(address(router.pletherOracle()), address(candidate));
        assertEq(routerAdmin.activeConfigVersion(), version + 1);
        assertEq(routerAdmin.oracleConfigActivationTime(), 0);
        assertEq(candidate.orderExecutionStalenessLimit(), pletherOracle.orderExecutionStalenessLimit());
        assertEq(candidate.liquidationStalenessLimit(), pletherOracle.liquidationStalenessLimit());
        assertEq(candidate.basketMaxConfidenceRatioBps(), pletherOracle.basketMaxConfidenceRatioBps());
        assertEq(candidate.orderSettlementWindow(), pletherOracle.orderSettlementWindow());
        assertEq(candidate.maxComponentPublishTimeDivergence(), pletherOracle.maxComponentPublishTimeDivergence());
        assertEq(candidate.adverseConfidenceMultiplierBps(), pletherOracle.adverseConfidenceMultiplierBps());
        emit log_named_uint("hardening_oracle_rotation", used);
    }

}

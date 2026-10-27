// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

contract TreasuryCustodyIsolationTest is BasePerpTest {

    function testFuzz_TreasuryDepositAndWithdrawalLeavePoolSnapshotUnchanged(
        uint96 deposit,
        uint96 withdrawal
    ) public {
        uint256 amount = bound(uint256(deposit), 1, 2_000_000e6);
        uint256 withdrawn = bound(uint256(withdrawal), 1, amount);
        address treasury = engine.protocolTreasury();
        uint256 backingBefore = pool.totalAssets();
        uint256 poolCashBefore = settlementToken.balanceOf(address(pool));
        uint256 accountedBefore = pool.accountedAssets();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        bytes32 houseBefore = keccak256(abi.encode(engineProtocolLens.getHousePoolInputSnapshot(60)));

        _fundTrader(treasury, amount);
        _assertPoolBacking(backingBefore);
        assertEq(clearinghouse.balanceAssets(treasury), amount);

        vm.prank(treasury);
        clearinghouse.withdraw(treasury, withdrawn);
        _assertPoolBacking(backingBefore);
        assertEq(clearinghouse.balanceAssets(treasury), amount - withdrawn);
        assertEq(settlementToken.balanceOf(treasury), withdrawn);
        assertEq(settlementToken.balanceOf(address(pool)), poolCashBefore, "Treasury transfers never touched pool cash");
        assertEq(pool.accountedAssets(), accountedBefore, "Treasury transfers never changed pool accounting");
        assertEq(keccak256(abi.encode(engineProtocolLens.getHousePoolInputSnapshot(60))), houseBefore);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        assertEq(afterSnapshot.protocolTreasuryBalanceAssets, amount - withdrawn);
        afterSnapshot.protocolTreasuryBalanceAssets = beforeSnapshot.protocolTreasuryBalanceAssets;
        assertEq(keccak256(abi.encode(afterSnapshot)), keccak256(abi.encode(beforeSnapshot)), "Only treasury changed");
    }

    function test_PoolFundedFeeReducesBackingOnceAndTreasuryWithdrawalDoesNotRestoreIt() public {
        address trader = address(0x7171);
        address treasury = engine.protocolTreasury();
        uint256 backingBefore = pool.totalAssets();
        _fundTrader(trader, 11_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);
        assertEq(clearinghouse.balanceAssets(treasury), 40e6, "Opening fee stays in clearinghouse custody");
        _assertPoolBacking(backingBefore);

        _close(trader, CfdTypes.Side.LONG, 100_000e18, 80_000_000);
        assertEq(clearinghouse.balanceAssets(treasury), 72e6, "Closing fee adds $32 from the pool");
        assertEq(
            settlementToken.balanceOf(address(pool)),
            backingBefore - 20_000e6,
            "$19,968 trader cash plus $32 fee left pool"
        );
        _assertPoolBacking(backingBefore - 20_000e6);

        vm.prank(treasury);
        clearinghouse.withdraw(treasury, 72e6);
        assertEq(clearinghouse.balanceAssets(treasury), 0);
        _assertPoolBacking(backingBefore - 20_000e6);
    }

    function test_TreasuryLargerThanPoolCannotEraseRemainingBacking() public {
        _fundTrader(engine.protocolTreasury(), 2_000_000e6);
        settlementToken.burn(address(pool), settlementToken.balanceOf(address(pool)) - 10e6);
        assertGt(pool.accountedAssets(), 10e6, "Raw custody, not the ledger, limits backing here");
        _assertPoolBacking(10e6);
    }

    function _assertPoolBacking(
        uint256 expected
    ) private view {
        assertEq(pool.totalAssets(), expected, "Expected backing follows actual custody movements");
        assertEq(engineProtocolLens.getProtocolAccountingSnapshot().netPhysicalAssets, expected);
        assertEq(engineProtocolLens.getHousePoolInputSnapshot(60).netPhysicalAssets, expected);
    }

}

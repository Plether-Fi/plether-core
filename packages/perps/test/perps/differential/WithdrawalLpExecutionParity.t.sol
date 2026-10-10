// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

/// @notice Same-state production-view/execution comparisons, supplemented with physical-custody assertions.
contract WithdrawalLpExecutionParityTest is BasePerpTest {

    address private constant ACCOUNT = address(0xD170);
    address private constant LP = address(0xD171);

    function test_PublicWithdrawableExecutesAtSameMarkWithHealthyPosition() public {
        _fundTrader(ACCOUNT, 20_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8);
        uint256 timeBefore = block.timestamp;
        uint256 markBefore = engine.lastMarkPrice();
        PerpsViewTypes.TraderAccountView memory preview = publicLens.getTraderAccount(ACCOUNT);
        assertGt(preview.withdrawableUsdc, 0);
        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 walletBefore = usdc.balanceOf(ACCOUNT);
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, preview.withdrawableUsdc);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), settlementBefore - preview.withdrawableUsdc);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore - preview.withdrawableUsdc);
        assertEq(usdc.balanceOf(ACCOUNT), walletBefore + preview.withdrawableUsdc);
        assertEq(publicLens.getTraderAccount(ACCOUNT).withdrawableUsdc, 0);
        assertEq(block.timestamp, timeBefore);
        assertEq(engine.lastMarkPrice(), markBefore);
    }

    function test_JuniorRedemptionEstimateMatchesSameStateFundingAndClaim() public {
        _fundJunior(LP, 20_000e6);
        vm.warp(juniorVault.lastDepositTime(LP) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 shares = juniorVault.balanceOf(LP);
        vm.prank(LP);
        uint256 requestId = juniorVault.requestRedeem(shares, LP, LP);
        vm.warp(pool.lpEpochStart(requestId));
        uint256 expectedAssets = juniorVault.estimateRedeemAssets(shares);
        (,,, uint256 pendingCapacity) = pool.getPendingTrancheState();
        assertGt(expectedAssets, 0);
        assertGe(pendingCapacity, expectedAssets, "Fixture must have enough cash for the full request");
        uint256 cashBefore = usdc.balanceOf(address(pool));
        uint256 escrowBefore = usdc.balanceOf(address(juniorVault));
        IHousePool.LpEpochSettlementResult memory actual = _settleLpEpochForTest();
        assertEq(actual.juniorFundedShares, shares);
        assertEq(actual.juniorFundedAssets, expectedAssets, "Pending NAV quote must match same-state funding");
        assertEq(usdc.balanceOf(address(pool)), cashBefore - expectedAssets);
        assertEq(usdc.balanceOf(address(juniorVault)), escrowBefore + expectedAssets);
        assertEq(juniorVault.claimableRedeemRequest(requestId, LP), shares);
        uint256 walletBefore = usdc.balanceOf(LP);
        vm.prank(LP);
        uint256 paid = juniorVault.claimRedeem(requestId, shares, LP, LP);
        assertEq(paid, expectedAssets);
        assertEq(usdc.balanceOf(LP), walletBefore + expectedAssets);
        assertEq(usdc.balanceOf(address(juniorVault)), escrowBefore);
        assertEq(juniorVault.claimableRedeemRequest(requestId, LP), 0);
    }

    function test_WithdrawalQuoteIsNotPromiseAfterMarkChanges() public {
        _fundTrader(ACCOUNT, 20_000e6);
        _open(ACCOUNT, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);
        assertGt(publicLens.getTraderAccount(ACCOUNT).withdrawableUsdc, 0);
        vm.prank(address(router));
        engine.updateMarkPrice(110_000_000, uint64(block.timestamp));
        assertEq(publicLens.getTraderAccount(ACCOUNT).withdrawableUsdc, 0, "Adverse mark invalidates prior quote");
        uint256 settlementBefore = clearinghouse.balanceUsdc(ACCOUNT);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        vm.prank(ACCOUNT);
        clearinghouse.withdraw(ACCOUNT, 1);
        assertEq(clearinghouse.balanceUsdc(ACCOUNT), settlementBefore);
    }

}

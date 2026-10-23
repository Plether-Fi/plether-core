// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";

/// @notice Controller-only share delivery, including aliases, operators and unsolicited dust.
contract TrancheShareReceiverTest is HousePoolAsyncTestBase {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OPERATOR = address(0x0F3A4702);
    address internal constant RECEIVER = address(0xCA401);
    bytes4 internal constant RECEIVER_ERROR = bytes4(keccak256("TrancheVault__ReceiverNotController()"));

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_DepositAndMintAliasesRejectThirdPartyReceiverButAllowOperatorSelfDelivery() public {
        uint256 assets = 100e6;
        uint256 requestId = _requestAsyncDeposit(juniorVault, ALICE, assets);
        _settleAsyncRequest(requestId, true);
        uint256 shares = juniorVault.claimableDepositShares(requestId, ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.claimDeposit(requestId, assets, RECEIVER, ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.deposit(assets, RECEIVER);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.deposit(assets, RECEIVER, ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.mint(shares, RECEIVER);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.mint(shares, RECEIVER, ALICE);
        juniorVault.setOperator(OPERATOR, true);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.claimDeposit(requestId, assets, OPERATOR, ALICE);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        assertEq(juniorVault.claimableDepositShares(requestId, ALICE), shares);
        assertEq(juniorVault.depositClaimEscrowShares(), shares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), shares);
        assertEq(juniorVault.balanceOf(RECEIVER), 0);
        assertEq(juniorVault.lastDepositTime(RECEIVER), 0);

        vm.prank(OPERATOR);
        assertEq(juniorVault.mint(shares, ALICE, ALICE), assets);
        assertEq(juniorVault.balanceOf(ALICE), shares);
        assertEq(juniorVault.balanceOf(OPERATOR), 0);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.lastDepositTime(ALICE), juniorVault.depositEpochActivationTime(requestId));
    }

    function test_ControllerClaimSurvivesUnsolicitedShareDust() public {
        _fundJunior(BOB, 1e6);
        _finishAsyncCooldown(juniorVault, BOB);
        uint256 assets = 100e6;
        uint256 requestId = _requestAsyncDeposit(juniorVault, ALICE, assets);
        _settleAsyncRequest(requestId, true);
        uint256 shares = juniorVault.maxMint(ALICE);
        assertEq(juniorVault.balanceOf(ALICE), 0);

        vm.prank(BOB);
        juniorVault.transfer(ALICE, 1);
        assertEq(juniorVault.maxDeposit(ALICE), assets);
        assertEq(juniorVault.maxMint(ALICE), shares);
        vm.prank(ALICE);
        assertEq(juniorVault.deposit(assets, ALICE), shares);
        assertEq(juniorVault.balanceOf(ALICE), shares + 1);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
    }

    function test_ZeroShareDepositAcknowledgementRequiresControllerReceiver() public {
        uint256 assets = 1e6;
        uint256 requestId = _requestAsyncDeposit(juniorVault, ALICE, assets);
        assertEq(_requestAsyncDeposit(juniorVault, BOB, assets), requestId);
        vm.warp(pool.lpEpochStart(requestId));
        // Isolate allocation rounding through the pool-only finalization hook: both entitlements round to zero.
        vm.prank(address(pool));
        juniorVault.finalizeDepositEpochFromPool(requestId, 1);
        assertEq(juniorVault.claimableDepositShares(requestId, ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.claimDeposit(requestId, assets, RECEIVER, ALICE);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), assets);
        vm.prank(ALICE);
        assertEq(juniorVault.claimDeposit(requestId, assets, ALICE, ALICE), 0);
        vm.prank(BOB);
        assertEq(juniorVault.claimDeposit(requestId, assets, BOB, BOB), 0);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0);
    }

    function test_FundedUsdcClaimCanStillUseAnotherReceiver() public {
        (, uint256 shares) = _depositAsync(juniorVault, ALICE, 100e6);
        _finishAsyncCooldown(juniorVault, ALICE);
        uint256 requestId = _requestAsyncRedeem(juniorVault, ALICE, shares);
        _settleAsyncRequest(requestId, true);
        uint256 assets = juniorVault.claimableRedeemAssets(requestId, ALICE);
        uint256 fundedShares = juniorVault.claimableRedeemRequest(requestId, ALICE);
        assertGt(assets, 0);
        vm.prank(ALICE);
        assertEq(juniorVault.claimRedeem(requestId, fundedShares, RECEIVER, ALICE), assets);
        assertEq(usdc.balanceOf(RECEIVER), assets);
        assertEq(juniorVault.balanceOf(RECEIVER), 0);
        assertEq(juniorVault.lastDepositTime(RECEIVER), 0);
    }

    function test_RedeemCancellationRequiresControllerReceiverIncludingOperator() public {
        (, uint256 shares) = _depositAsync(juniorVault, ALICE, 100e6);
        _finishAsyncCooldown(juniorVault, ALICE);
        uint256 requestId = _requestAsyncRedeem(juniorVault, ALICE, shares);
        uint256 cooldownBefore = juniorVault.lastDepositTime(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.cancelRedeemRequest(requestId, RECEIVER);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.cancelRedeemRequest(requestId, RECEIVER, ALICE);
        juniorVault.setOperator(OPERATOR, true);
        vm.stopPrank();
        vm.prank(OPERATOR);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.cancelRedeemRequest(requestId, OPERATOR, ALICE);

        assertEq(juniorVault.pendingRedeemRequest(requestId, ALICE), shares);
        assertEq(juniorVault.pendingRedeemEscrowShares(), shares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), shares);
        assertEq(juniorVault.controllerRedeemHead(ALICE), requestId);
        assertEq(juniorVault.lastDepositTime(ALICE), cooldownBefore);
        assertEq(juniorVault.lastDepositTime(RECEIVER), 0);
        assertEq(juniorVault.balanceOf(RECEIVER), 0);

        vm.prank(OPERATOR);
        assertEq(juniorVault.cancelRedeemRequest(requestId, ALICE, ALICE), shares);
        assertEq(juniorVault.balanceOf(ALICE), shares);
        assertEq(juniorVault.lastDepositTime(ALICE), block.timestamp);
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0);
        assertEq(juniorVault.controllerRedeemHead(ALICE), 0);
    }

    function test_RedeemRefundRequiresControllerReceiverIncludingOperator() public {
        (, uint256 shares) = _depositAsync(juniorVault, ALICE, 1e6);
        _finishAsyncCooldown(juniorVault, ALICE);
        vm.prank(ALICE);
        juniorVault.transfer(BOB, shares - 1);
        // The full-wallet dust exception admits one share, whose actual settlement quote is zero.
        uint256 requestId = _requestAsyncRedeem(juniorVault, ALICE, 1);
        _settleAsyncRequest(requestId, true);
        assertEq(juniorVault.refundableRedeemRequest(requestId, ALICE), 1);
        uint256 cooldownBefore = juniorVault.lastDepositTime(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.claimRedeemRefund(requestId, RECEIVER, ALICE);
        juniorVault.setOperator(OPERATOR, true);
        vm.stopPrank();
        vm.prank(OPERATOR);
        vm.expectRevert(RECEIVER_ERROR);
        juniorVault.claimRedeemRefund(requestId, OPERATOR, ALICE);

        assertEq(juniorVault.refundableRedeemRequest(requestId, ALICE), 1);
        assertTrue(juniorVault.redeemRefundPending(requestId, ALICE));
        assertEq(juniorVault.pendingRedeemEscrowShares(), 1);
        assertEq(juniorVault.balanceOf(address(juniorVault)), 1);
        assertEq(juniorVault.lastDepositTime(ALICE), cooldownBefore);
        assertEq(juniorVault.lastDepositTime(RECEIVER), 0);
        assertEq(juniorVault.balanceOf(RECEIVER), 0);

        vm.prank(OPERATOR);
        assertEq(juniorVault.claimRedeemRefund(requestId, ALICE, ALICE), 1);
        assertEq(juniorVault.balanceOf(ALICE), 1);
        assertEq(juniorVault.lastDepositTime(ALICE), block.timestamp);
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0);
        assertFalse(juniorVault.redeemRefundPending(requestId, ALICE));
        assertEq(juniorVault.controllerRedeemHead(ALICE), 0);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";

/// @notice Multi-controller conservation coverage for asynchronous tranche epoch allocation.
contract AsyncTrancheVaultAllocationTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MAINTENANCE_FEE_RECIPIENT = address(0xFEE70003);

    uint256 internal constant USER_ASSETS = 10_000e6;
    uint256 internal constant USER_SHARES = 10_000e9;
    uint256 internal constant MAINTENANCE_FEE_APR_BPS = 1000;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: 150,
            fadMarginBps: 300,
            baseCarryBps: 0,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_DepositAllocationBurnsAggregateShareDust() public {
        uint256 aliceAssets = 1e6;
        uint256 bobAssets = 1e6;
        uint256 requestId = _requestDeposit(ALICE, aliceAssets);
        assertEq(_requestDeposit(BOB, bobAssets), requestId);

        uint256 epochAssets = aliceAssets + bobAssets;
        uint256 epochShares = epochAssets - 1;
        _warpToEpoch(requestId);
        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(requestId, epochShares), epochAssets);

        uint256 aliceShares = Math.mulDiv(aliceAssets, epochShares, epochAssets, Math.Rounding.Floor);
        uint256 bobShares = Math.mulDiv(bobAssets, epochShares, epochAssets, Math.Rounding.Floor);
        uint256 shareDust = epochShares - aliceShares - bobShares;
        assertGt(shareDust, 0, "fixture must create aggregate share dust");

        uint256 supplyBeforeClaims = juniorVault.totalSupply();
        vm.prank(ALICE);
        assertEq(_async().claimDeposit(requestId, aliceAssets, ALICE, ALICE), aliceShares);
        vm.prank(BOB);
        assertEq(_async().claimDeposit(requestId, bobAssets, BOB, BOB), bobShares);

        assertEq(juniorVault.balanceOf(ALICE), aliceShares);
        assertEq(juniorVault.balanceOf(BOB), bobShares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "claim escrow must be empty");
        assertEq(juniorVault.depositClaimEscrowShares(), 0, "claim escrow accounting must be empty");
        assertEq(juniorVault.totalSupply(), supplyBeforeClaims - shareDust, "aggregate dust must be burned");
        assertEq(juniorVault.controllerDepositHead(ALICE), 0);
        assertEq(juniorVault.controllerDepositHead(BOB), 0);

        (uint256 assets, uint256 shares, uint256 claimedAssets, uint256 claimedShares, bool finalized) =
            juniorVault.depositEpochs(requestId);
        assertTrue(finalized);
        assertEq(assets, epochAssets);
        assertEq(shares, epochShares);
        assertEq(claimedAssets, epochAssets);
        assertEq(claimedShares, epochShares, "burned dust must be included in terminal epoch accounting");
    }

    function test_DepositAllocationDustBurnMaterializesMaintenanceFeeExactlyOnce() public {
        uint256 aliceAssets = 1e6;
        uint256 bobAssets = 1e6;
        uint256 requestId = _requestDeposit(ALICE, aliceAssets);
        assertEq(_requestDeposit(BOB, bobAssets), requestId);

        uint256 epochAssets = aliceAssets + bobAssets;
        uint256 epochShares = epochAssets - 1;
        _warpToEpoch(requestId);
        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(requestId, epochShares), epochAssets);

        uint256 aliceShares = Math.mulDiv(aliceAssets, epochShares, epochAssets, Math.Rounding.Floor);
        uint256 bobShares = Math.mulDiv(bobAssets, epochShares, epochAssets, Math.Rounding.Floor);
        uint256 shareDust = epochShares - aliceShares - bobShares;
        assertGt(shareDust, 0, "fixture must create nonzero claim-escrow dust");

        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        uint256 rawSupplyBeforeClaims = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 recipientSharesBefore = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        uint256 checkpointBefore = juniorVault.maintenanceFeeCheckpointBoundary();
        assertGt(pendingFeeShares, 0, "fixture must have a materializable maintenance fee");

        vm.prank(ALICE);
        assertEq(_async().claimDeposit(requestId, aliceAssets, ALICE, ALICE), aliceShares);
        assertEq(juniorVault.totalSupply(), rawSupplyBeforeClaims, "nonterminal claim cannot mutate supply");
        assertEq(juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT), recipientSharesBefore);
        assertEq(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBefore);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), pendingFeeShares);

        vm.prank(BOB);
        assertEq(_async().claimDeposit(requestId, bobAssets, BOB, BOB), bobShares);

        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT) - recipientSharesBefore,
            pendingFeeShares,
            "terminal dust burn must checkpoint the accrued fee once"
        );
        assertEq(
            juniorVault.totalSupply(),
            rawSupplyBeforeClaims + pendingFeeShares - shareDust,
            "fee mint and claim-escrow dust burn must compose exactly"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertGt(juniorVault.maintenanceFeeCheckpointBoundary(), checkpointBefore);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0);
    }

    function test_PartialMintPlateauRevertsWithoutCorruptingControllerFifo() public {
        uint256 firstAssets = 1e6;
        uint256 firstShares = 1e9;
        uint256 firstRequestId = _requestDeposit(ALICE, firstAssets);

        (, uint256 requestCutoffTime) = juniorVault.getRequestEpochWindow();
        vm.warp(requestCutoffTime);
        uint256 secondRequestId = _requestDeposit(ALICE, 1e6);
        assertEq(secondRequestId, firstRequestId + 1, "crossing the cutoff must create the next FIFO epoch");

        _warpToEpoch(firstRequestId);
        vm.prank(address(pool));
        juniorVault.finalizeDepositEpochFromPool(firstRequestId, firstShares);

        assertEq(juniorVault.controllerDepositHead(ALICE), firstRequestId);
        assertEq(juniorVault.controllerDepositTail(ALICE), secondRequestId);
        assertEq(_async().claimableDepositRequest(firstRequestId, ALICE), firstAssets);
        assertEq(_async().pendingDepositRequest(secondRequestId, ALICE), 1e6);

        vm.expectRevert();
        vm.prank(ALICE);
        juniorVault.mint(firstShares - 1, ALICE);

        assertEq(juniorVault.controllerDepositHead(ALICE), firstRequestId, "failed mint must retain the FIFO head");
        assertEq(juniorVault.controllerDepositTail(ALICE), secondRequestId, "failed mint must retain the FIFO tail");
        assertEq(_async().claimableDepositRequest(firstRequestId, ALICE), firstAssets);
        assertEq(_async().claimableDepositShares(firstRequestId, ALICE), firstShares);
        assertEq(_async().pendingDepositRequest(secondRequestId, ALICE), 1e6);

        vm.prank(ALICE);
        assertEq(juniorVault.mint(firstShares, ALICE), firstAssets);
        assertEq(juniorVault.controllerDepositHead(ALICE), secondRequestId, "full claim must advance the FIFO head");
        assertEq(juniorVault.controllerDepositTail(ALICE), secondRequestId);
    }

    function test_RedeemAllocationReturnsAggregateAssetDustToPool() public {
        uint256 requestId = _prepareTwoControllerRedeem();
        uint256 fundedAssets = USER_ASSETS;
        usdc.mint(address(juniorVault), fundedAssets);

        _warpToEpoch(requestId);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(requestId, USER_SHARES, fundedAssets);

        uint256 aliceShares = USER_SHARES - 1;
        uint256 aliceAssets = Math.mulDiv(aliceShares, fundedAssets, USER_SHARES, Math.Rounding.Floor);
        uint256 bobAssets = Math.mulDiv(1, fundedAssets, USER_SHARES, Math.Rounding.Floor);
        uint256 assetDust = fundedAssets - aliceAssets - bobAssets;
        assertGt(assetDust, 0, "fixture must create aggregate asset dust");
        assertEq(_async().claimableRedeemAssets(requestId, BOB), 0, "one-share controller must round to zero assets");

        uint256 poolBalanceBeforeClaims = usdc.balanceOf(address(pool));
        vm.prank(BOB);
        assertEq(_async().claimRedeem(requestId, 1, BOB, BOB), bobAssets);
        vm.prank(ALICE);
        assertEq(_async().claimRedeem(requestId, aliceShares, ALICE, ALICE), aliceAssets);

        assertEq(usdc.balanceOf(ALICE), aliceAssets);
        assertEq(usdc.balanceOf(BOB), bobAssets);
        assertEq(usdc.balanceOf(address(pool)), poolBalanceBeforeClaims + assetDust, "asset dust must return to Pool");
        assertEq(juniorVault.withdrawalEscrowAssets(), 0, "withdrawal escrow accounting must be empty");
        assertEq(usdc.balanceOf(address(juniorVault)), 0, "withdrawal escrow custody must be empty");
        assertEq(juniorVault.controllerRedeemHead(ALICE), 0);
        assertEq(juniorVault.controllerRedeemHead(BOB), 0);
        _assertRedeemEpochFullyBooked(requestId);
    }

    function test_PartialWithdrawPlateauRevertsWithoutCorruptingControllerFifo() public {
        uint256 depositAssets = 4e6;
        uint256 totalUserShares = 4e9;
        uint256 firstRedeemShares = totalUserShares / 2;
        uint256 depositId = _requestDeposit(ALICE, depositAssets);
        _warpToEpoch(depositId);
        vm.prank(address(pool));
        juniorVault.finalizeDepositEpochFromPool(depositId, totalUserShares);
        vm.prank(ALICE);
        assertEq(_async().claimDeposit(depositId, depositAssets, ALICE, ALICE), totalUserShares);
        _finishCooldown(ALICE);

        vm.prank(ALICE);
        uint256 firstRequestId = _async().requestRedeem(firstRedeemShares, ALICE, ALICE);
        _warpToEpoch(firstRequestId);
        vm.prank(ALICE);
        uint256 secondRequestId = _async().requestRedeem(firstRedeemShares, ALICE, ALICE);
        assertGt(secondRequestId, firstRequestId, "fixture needs two FIFO epochs");

        uint256 fundedAssets = firstRedeemShares + 1;
        usdc.mint(address(juniorVault), fundedAssets);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(firstRequestId, firstRedeemShares, fundedAssets);

        assertEq(juniorVault.controllerRedeemHead(ALICE), firstRequestId);
        assertEq(juniorVault.controllerRedeemTail(ALICE), secondRequestId);
        assertEq(_async().claimableRedeemRequest(firstRequestId, ALICE), firstRedeemShares);
        assertEq(_async().claimableRedeemAssets(firstRequestId, ALICE), fundedAssets);
        assertEq(_async().pendingRedeemRequest(secondRequestId, ALICE), firstRedeemShares);

        vm.expectRevert();
        vm.prank(ALICE);
        juniorVault.withdraw(fundedAssets - 1, ALICE, ALICE);

        assertEq(juniorVault.controllerRedeemHead(ALICE), firstRequestId, "failed withdraw must retain FIFO head");
        assertEq(juniorVault.controllerRedeemTail(ALICE), secondRequestId, "failed withdraw must retain FIFO tail");
        assertEq(_async().claimableRedeemRequest(firstRequestId, ALICE), firstRedeemShares);
        assertEq(_async().claimableRedeemAssets(firstRequestId, ALICE), fundedAssets);
        assertEq(_async().pendingRedeemRequest(secondRequestId, ALICE), firstRedeemShares);

        vm.prank(ALICE);
        assertEq(juniorVault.withdraw(fundedAssets, ALICE, ALICE), firstRedeemShares);
        assertEq(juniorVault.controllerRedeemHead(ALICE), secondRequestId, "full claim must advance the FIFO head");
        assertEq(juniorVault.controllerRedeemTail(ALICE), secondRequestId);
    }

    function test_RefundAllocationSweepsShareDustAndSupportsZeroEntitlements() public {
        uint256 requestId = _prepareTwoControllerRedeem();
        uint256 fundedShares = USER_SHARES - 1;
        uint256 fundedAssets = USER_ASSETS - 1;
        usdc.mint(address(juniorVault), fundedAssets);

        _warpToEpoch(requestId);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(requestId, fundedShares, fundedAssets);
        vm.prank(address(pool));
        assertEq(juniorVault.refundRedeemEpochRemainder(requestId, 1), 1);

        assertTrue(_async().redeemRefundPending(requestId, ALICE));
        assertTrue(_async().redeemRefundPending(requestId, BOB));
        assertEq(_async().refundableRedeemRequest(requestId, ALICE), 0);
        assertEq(_async().refundableRedeemRequest(requestId, BOB), 0);

        address seedReceiver = juniorVault.seedReceiver();
        uint256 seedBalanceBefore = juniorVault.balanceOf(seedReceiver);
        uint256 seedCooldownBefore = juniorVault.lastDepositTime(seedReceiver);

        vm.prank(BOB);
        assertEq(_async().claimRedeemRefund(requestId, BOB, BOB), 0);
        assertFalse(_async().redeemRefundPending(requestId, BOB));
        vm.prank(ALICE);
        assertEq(_async().claimRedeemRefund(requestId, ALICE, ALICE), 0);

        assertFalse(_async().redeemRefundPending(requestId, ALICE));
        assertEq(juniorVault.balanceOf(seedReceiver), seedBalanceBefore + 1, "refund share dust must go to seed");
        assertEq(
            juniorVault.lastDepositTime(seedReceiver),
            seedCooldownBefore,
            "protocol dust sweep must not restart the seed cooldown"
        );
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0, "redeem share escrow accounting must be empty");
        assertEq(juniorVault.balanceOf(address(juniorVault)), 0, "redeem share escrow custody must be empty");

        uint256 aliceFundedShares = Math.mulDiv(USER_SHARES - 1, fundedShares, USER_SHARES, Math.Rounding.Floor);
        uint256 aliceFundedAssets = Math.mulDiv(USER_SHARES - 1, fundedAssets, USER_SHARES, Math.Rounding.Floor);
        uint256 assetDust = fundedAssets - aliceFundedAssets;
        uint256 poolBalanceBeforeClaim = usdc.balanceOf(address(pool));
        assertEq(_async().claimableRedeemRequest(requestId, BOB), 0);
        assertEq(_async().claimableRedeemRequest(requestId, ALICE), aliceFundedShares);

        vm.prank(ALICE);
        assertEq(_async().claimRedeem(requestId, aliceFundedShares, ALICE, ALICE), aliceFundedAssets);

        assertEq(
            usdc.balanceOf(address(pool)), poolBalanceBeforeClaim + assetDust, "funding asset dust must return to Pool"
        );
        assertEq(juniorVault.withdrawalEscrowAssets(), 0);
        assertEq(usdc.balanceOf(address(juniorVault)), 0);
        assertEq(juniorVault.controllerRedeemHead(ALICE), 0);
        assertEq(juniorVault.controllerRedeemHead(BOB), 0);
        _assertRedeemEpochFullyBooked(requestId);
    }

    function _prepareTwoControllerRedeem() internal returns (uint256 requestId) {
        uint256 depositId = _requestDeposit(ALICE, USER_ASSETS);
        _warpToEpoch(depositId);
        vm.prank(address(pool));
        juniorVault.finalizeDepositEpochFromPool(depositId, USER_SHARES);
        vm.prank(ALICE);
        assertEq(_async().claimDeposit(depositId, USER_ASSETS, ALICE, ALICE), USER_SHARES);

        _finishCooldown(ALICE);
        vm.prank(ALICE);
        juniorVault.transfer(BOB, 1);

        vm.prank(ALICE);
        requestId = _async().requestRedeem(USER_SHARES - 1, ALICE, ALICE);
        vm.prank(BOB);
        assertEq(_async().requestRedeem(1, BOB, BOB), requestId);
    }

    function _finishCooldown(
        address controller
    ) internal {
        uint256 cooldownEnd = juniorVault.lastDepositTime(controller) + juniorVault.DEPOSIT_COOLDOWN();
        if (block.timestamp < cooldownEnd) {
            vm.warp(cooldownEnd);
        }
    }

    function _assertRedeemEpochFullyBooked(
        uint256 requestId
    ) internal view {
        (, uint256 fundedShares, uint256 fundedAssets, uint256 claimedShares, uint256 claimedAssets,,,,,) =
            juniorVault.redeemEpochs(requestId);
        assertEq(claimedShares, fundedShares, "terminal epoch must book every funded share");
        assertEq(claimedAssets, fundedAssets, "terminal epoch must book every funded asset");
    }

    function _requestDeposit(
        address controller,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(controller, assets);
        vm.startPrank(controller);
        usdc.approve(address(juniorVault), assets);
        requestId = _async().requestDeposit(assets, controller, controller);
        vm.stopPrank();
    }

    function _warpToEpoch(
        uint256 epochId
    ) internal {
        uint256 timestamp = pool.lpEpochStart(epochId);
        if (block.timestamp < timestamp) {
            vm.warp(timestamp);
        }
    }

    function _enableJuniorMaintenanceFee() internal {
        juniorVault.proposeMaintenanceFeeConfig(MAINTENANCE_FEE_APR_BPS, MAINTENANCE_FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
    }

    function _async() internal view returns (IAsyncTrancheVault) {
        return IAsyncTrancheVault(address(juniorVault));
    }

}

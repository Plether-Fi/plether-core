// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Focused coverage for settlement-aged cooldowns and direct deposit-escrow redemption.
contract ClaimableDepositRedeemTest is BasePerpTest {

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant OPERATOR = address(0x0F3A4702);
    address internal constant MAINTENANCE_FEE_RECIPIENT = address(0xFEE70004);

    uint256 internal constant MAINTENANCE_FEE_APR_BPS = 1000;

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_ActivationUsesActualFinalizationTimeAndClaimInheritsIt() public {
        uint256 assets = 20_000e6;
        uint256 shares = 20_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);

        assertEq(juniorVault.depositEpochActivationTime(requestId), 0, "pending epoch must not be activated");

        uint256 scheduledActivation = pool.lpEpochStart(requestId);
        uint256 actualActivation = scheduledActivation + 2 hours + 17 minutes;
        _finalizeDepositAt(requestId, shares, actualActivation);

        assertEq(
            juniorVault.depositEpochActivationTime(requestId),
            actualActivation,
            "activation must use successful finalization time"
        );

        vm.warp(actualActivation + 37 minutes);
        vm.prank(ALICE);
        assertEq(juniorVault.claimDeposit(requestId, assets, ALICE, ALICE), shares);

        assertEq(
            juniorVault.lastDepositTime(ALICE),
            actualActivation,
            "an administrative claim must inherit the epoch activation time"
        );
        assertEq(juniorVault.balanceOf(ALICE), shares);
        assertEq(juniorVault.maxRequestRedeem(ALICE), 0, "the activation-aged cooldown must still be running");

        vm.warp(actualActivation + juniorVault.DEPOSIT_COOLDOWN());
        assertEq(juniorVault.maxRequestRedeem(ALICE), shares, "claiming early must not restart cooldown at claim time");
    }

    function test_OlderClaimCannotShortenNewerWalletCooldown() public {
        uint256 assets = 20_000e6;
        uint256 firstRequestId = _requestDeposit(ALICE, assets);
        uint256 firstActivation = pool.lpEpochStart(firstRequestId);
        _finalizeDepositAt(firstRequestId, 20_000e9, firstActivation);

        uint256 secondRequestId = _requestDeposit(ALICE, assets);
        assertGt(secondRequestId, firstRequestId);
        uint256 secondActivation = pool.lpEpochStart(secondRequestId);
        _finalizeDepositAt(secondRequestId, 20_000e9, secondActivation);

        vm.prank(ALICE);
        juniorVault.claimDeposit(secondRequestId, assets, ALICE, ALICE);
        assertEq(juniorVault.lastDepositTime(ALICE), secondActivation);

        vm.prank(ALICE);
        juniorVault.claimDeposit(firstRequestId, assets, ALICE, ALICE);
        assertEq(
            juniorVault.lastDepositTime(ALICE),
            secondActivation,
            "claiming an older activated lot must not shorten the wallet's newer cooldown"
        );
    }

    function test_DirectRouteRejectsBeforeCooldownAndSucceedsAtExactBoundary() public {
        uint256 assets = 25_000e6;
        uint256 shares = 25_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId) + 11 minutes;
        _finalizeDepositAt(requestId, shares, activationTime);

        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN() - 1);
        assertEq(
            juniorVault.maxRequestRedeemFromClaimableDeposit(requestId, ALICE),
            0,
            "claim escrow must remain locked before the exact boundary"
        );
        vm.expectRevert(TrancheVault.TrancheVault__DepositCooldown.selector);
        vm.prank(ALICE);
        juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());
        assertEq(
            juniorVault.maxRequestRedeemFromClaimableDeposit(requestId, ALICE),
            shares,
            "the complete entitlement must unlock at the exact boundary"
        );

        vm.prank(ALICE);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        assertEq(juniorVault.claimableDepositShares(requestId, ALICE), 0);
        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, ALICE), shares);
    }

    function test_DirectRouteRequiresControllerOrApprovedOperator() public {
        uint256 assets = 15_000e6;
        uint256 shares = 15_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId);
        _finalizeDepositAt(requestId, shares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());

        vm.expectRevert(TrancheVault.TrancheVault__NotControllerOrOperator.selector);
        vm.prank(OPERATOR);
        juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        vm.prank(ALICE);
        assertTrue(juniorVault.setOperator(OPERATOR, true));

        vm.prank(OPERATOR);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, ALICE), shares);
        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, OPERATOR), 0);
        assertEq(juniorVault.balanceOf(OPERATOR), 0, "an operator must never take custody of routed shares");
    }

    function test_DirectRouteEmitsOnlyDedicatedRequestEvent() public {
        uint256 assets = 25_000e6;
        uint256 shares = 25_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId);
        _finalizeDepositAt(requestId, shares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());
        (uint256 expectedRedeemRequestId,) = juniorVault.getRequestEpochWindow();

        vm.recordLogs();
        vm.prank(ALICE);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 dedicatedTopic =
            keccak256("ClaimableDepositRedeemRequest(address,uint256,uint256,address,uint256,uint256)");
        bytes32 canonicalTopic = keccak256("RedeemRequest(address,address,uint256,address,uint256)");
        bool foundDedicated;
        bool foundCanonical;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(juniorVault) || logs[i].topics.length == 0) {
                continue;
            }
            if (logs[i].topics[0] == canonicalTopic) {
                foundCanonical = true;
            } else if (logs[i].topics[0] == dedicatedTopic) {
                foundDedicated = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(ALICE))));
                assertEq(logs[i].topics[2], bytes32(requestId));
                assertEq(logs[i].topics[3], bytes32(redeemRequestId));
                (address sender, uint256 eventAssets, uint256 eventShares) =
                    abi.decode(logs[i].data, (address, uint256, uint256));
                assertEq(sender, ALICE);
                assertEq(eventAssets, assets);
                assertEq(eventShares, shares);
            }
        }

        assertEq(redeemRequestId, expectedRedeemRequestId);
        assertTrue(foundDedicated, "the escrow-sourced request needs its dedicated event");
        assertFalse(foundCanonical, "the escrow-sourced path must not impersonate a wallet-funded request");
    }

    function test_CancellingDirectRouteRestartsWalletCooldown() public {
        uint256 assets = 25_000e6;
        uint256 shares = 25_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId);
        _finalizeDepositAt(requestId, shares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());

        vm.prank(ALICE);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        uint256 returnTime = block.timestamp + 17 minutes;
        vm.warp(returnTime);
        vm.prank(ALICE);
        assertEq(juniorVault.cancelRedeemRequest(redeemRequestId, ALICE), shares);

        assertEq(juniorVault.balanceOf(ALICE), shares);
        assertEq(juniorVault.lastDepositTime(ALICE), returnTime);
        assertEq(juniorVault.maxRequestRedeem(ALICE), 0, "returned shares must begin a fresh wallet cooldown");

        vm.warp(returnTime + juniorVault.DEPOSIT_COOLDOWN());
        assertEq(juniorVault.maxRequestRedeem(ALICE), shares);
    }

    function test_DirectRoutePartiallyThenFullyReclassifiesEscrowWithCeilingBasis() public {
        uint256 assets = 30_000e6;
        uint256 epochShares = 20_000e9 - 1;
        uint256 partialShares = 10_000e9;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId) + 3 minutes;
        _finalizeDepositAt(requestId, epochShares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());

        uint256 vaultBalanceBefore = juniorVault.balanceOf(address(juniorVault));
        uint256 supplyBefore = juniorVault.totalSupply();
        uint256 expectedPartialAssets = Math.mulDiv(partialShares, assets, epochShares, Math.Rounding.Ceil);

        vm.prank(ALICE);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, partialShares, ALICE);

        (, uint256 claimedAssets, uint256 claimedShares,,,) = juniorVault.depositRequests(ALICE, requestId);
        assertEq(claimedAssets, expectedPartialAssets, "partial routing must consume contribution basis with ceil");
        assertEq(claimedShares, partialShares);
        assertEq(juniorVault.depositClaimEscrowShares(), epochShares - partialShares);
        assertEq(juniorVault.pendingRedeemEscrowShares(), partialShares);
        assertEq(juniorVault.balanceOf(address(juniorVault)), vaultBalanceBefore);
        assertEq(juniorVault.totalSupply(), supplyBefore);

        uint256 remainingShares = juniorVault.claimableDepositShares(requestId, ALICE);
        vm.prank(ALICE);
        uint256 aggregatedRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, remainingShares, ALICE);

        assertEq(aggregatedRequestId, redeemRequestId, "same-window routes must aggregate");
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.pendingRedeemEscrowShares(), epochShares);
        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, ALICE), epochShares);
        assertEq(juniorVault.claimableDepositRequest(requestId, ALICE), 0);
        assertEq(juniorVault.claimableDepositShares(requestId, ALICE), 0);
        assertEq(juniorVault.balanceOf(address(juniorVault)), vaultBalanceBefore);
        assertEq(juniorVault.totalSupply(), supplyBefore);

        (uint256 epochAssets,, uint256 epochClaimedAssets, uint256 epochClaimedShares, bool finalized) =
            juniorVault.depositEpochs(requestId);
        assertTrue(finalized);
        assertEq(epochClaimedAssets, epochAssets, "full routing must consume all remaining contribution basis");
        assertEq(epochClaimedShares, epochShares);
    }

    function test_DirectRouteCanBeFundedAndClaimedWithoutWalletShareCustody() public {
        uint256 assets = 25_000e6;
        uint256 shares = 25_000e9;
        uint256 fundedAssets = 24_500e6;
        uint256 requestId = _requestDeposit(ALICE, assets);
        uint256 activationTime = pool.lpEpochStart(requestId) + 7 minutes;
        _finalizeDepositAt(requestId, shares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());

        uint256 supplyBeforeRoute = juniorVault.totalSupply();
        vm.prank(ALICE);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, shares, ALICE);

        assertEq(juniorVault.balanceOf(ALICE), 0, "direct routing must skip wallet share custody");
        assertEq(juniorVault.totalSupply(), supplyBeforeRoute, "routing must not mint or burn shares");

        _warpToEpoch(redeemRequestId);
        usdc.mint(address(juniorVault), fundedAssets);
        vm.prank(address(pool));
        juniorVault.fundRedeemEpoch(redeemRequestId, shares, fundedAssets);

        assertEq(juniorVault.claimableRedeemRequest(redeemRequestId, ALICE), shares);
        assertEq(juniorVault.claimableRedeemAssets(redeemRequestId, ALICE), fundedAssets);
        vm.prank(ALICE);
        assertEq(juniorVault.claimRedeem(redeemRequestId, shares, ALICE, ALICE), fundedAssets);

        assertEq(usdc.balanceOf(ALICE), fundedAssets);
        assertEq(juniorVault.pendingRedeemEscrowShares(), 0);
        assertEq(juniorVault.withdrawalEscrowAssets(), 0);
    }

    function test_MixedDirectRouteAndWalletClaimSweepsTerminalShareDust() public {
        uint256 controllerAssets = 10_000e6;
        uint256 epochShares = 20_000e9 - 1;
        uint256 requestId = _requestDeposit(ALICE, controllerAssets);
        assertEq(_requestDeposit(BOB, controllerAssets), requestId);

        uint256 activationTime = pool.lpEpochStart(requestId) + 5 minutes;
        _finalizeDepositAt(requestId, epochShares, activationTime);
        vm.warp(activationTime + juniorVault.DEPOSIT_COOLDOWN());

        uint256 aliceShares = juniorVault.claimableDepositShares(requestId, ALICE);
        uint256 bobShares = juniorVault.claimableDepositShares(requestId, BOB);
        uint256 shareDust = epochShares - aliceShares - bobShares;
        assertEq(shareDust, 1, "fixture must create one unit of aggregate share dust");

        vm.prank(ALICE);
        assertEq(juniorVault.claimDeposit(requestId, controllerAssets, ALICE, ALICE), aliceShares);
        uint256 supplyBeforeTerminalRoute = juniorVault.totalSupply();

        vm.prank(BOB);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, bobShares, BOB);

        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, BOB), bobShares);
        assertEq(juniorVault.balanceOf(ALICE), aliceShares);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(
            juniorVault.totalSupply(),
            supplyBeforeTerminalRoute - shareDust,
            "a terminal direct route must burn aggregate share dust"
        );
        assertEq(
            juniorVault.balanceOf(address(juniorVault)),
            juniorVault.pendingRedeemEscrowShares(),
            "vault custody must equal the remaining redemption escrow"
        );

        (, uint256 settledShares, uint256 claimedAssets, uint256 claimedShares, bool finalized) =
            juniorVault.depositEpochs(requestId);
        assertTrue(finalized);
        assertEq(settledShares, epochShares);
        assertEq(claimedAssets, controllerAssets * 2);
        assertEq(claimedShares, epochShares, "terminal dust burn must fully book the deposit epoch");
    }

    function test_TerminalDirectRouteComposesShareDustBurnWithMaintenanceFeeCheckpoint() public {
        uint256 controllerAssets = 1e6;
        uint256 epochAssets = controllerAssets * 2;
        uint256 epochShares = epochAssets - 1;
        uint256 requestId = _requestDeposit(ALICE, controllerAssets);
        assertEq(_requestDeposit(BOB, controllerAssets), requestId);

        uint256 activationTime = pool.lpEpochStart(requestId);
        _finalizeDepositAt(requestId, epochShares, activationTime);
        uint256 aliceShares = juniorVault.claimableDepositShares(requestId, ALICE);
        uint256 bobShares = juniorVault.claimableDepositShares(requestId, BOB);
        uint256 shareDust = epochShares - aliceShares - bobShares;
        assertEq(shareDust, 1, "fixture must create one unit of aggregate share dust");

        _enableJuniorMaintenanceFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        uint256 rawSupplyBefore = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 recipientSharesBefore = juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT);
        assertGt(pendingFeeShares, 0, "fixture must accrue a materializable maintenance fee");

        vm.prank(ALICE);
        assertEq(juniorVault.claimDeposit(requestId, controllerAssets, ALICE, ALICE), aliceShares);
        assertEq(juniorVault.totalSupply(), rawSupplyBefore, "nonterminal delivery must not checkpoint the fee");
        assertEq(juniorVault.pendingMaintenanceFeeShares(), pendingFeeShares);

        vm.prank(BOB);
        uint256 redeemRequestId = juniorVault.requestRedeemFromClaimableDeposit(requestId, bobShares, BOB);

        assertEq(
            juniorVault.balanceOf(MAINTENANCE_FEE_RECIPIENT) - recipientSharesBefore,
            pendingFeeShares,
            "terminal direct routing must materialize the accrued fee exactly once"
        );
        assertEq(
            juniorVault.totalSupply(),
            rawSupplyBefore + pendingFeeShares - shareDust,
            "fee mint and terminal claim-escrow dust burn must compose exactly"
        );
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 0);
        assertEq(juniorVault.depositClaimEscrowShares(), 0);
        assertEq(juniorVault.pendingRedeemRequest(redeemRequestId, BOB), bobShares);
        assertEq(
            juniorVault.balanceOf(address(juniorVault)),
            juniorVault.pendingRedeemEscrowShares(),
            "vault custody must equal redemption escrow after the terminal route"
        );
    }

    function _requestDeposit(
        address controller,
        uint256 assets
    ) internal returns (uint256 requestId) {
        usdc.mint(controller, assets);
        vm.startPrank(controller);
        usdc.approve(address(juniorVault), assets);
        requestId = juniorVault.requestDeposit(assets, controller, controller);
        vm.stopPrank();
    }

    function _finalizeDepositAt(
        uint256 requestId,
        uint256 shares,
        uint256 timestamp
    ) internal {
        vm.warp(timestamp);
        vm.prank(address(pool));
        juniorVault.finalizeDepositEpochFromPool(requestId, shares);
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

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

contract ZeroVaultHousePoolStub {

    function seniorVault() external pure returns (address) {
        return address(0);
    }

    function juniorVault() external pure returns (address) {
        return address(0);
    }

}

contract PerpsPublicLensDepositCooldownTest is BasePerpTest {

    address internal constant DEPOSITOR = address(0xC001D0);

    function test_GetLpDepositCooldownState_ReturnsMetadataWhenHousePoolIsZero() public {
        PerpsPublicLens lens = new PerpsPublicLens(address(0), address(0), address(0), address(0));
        uint256 requestId = 17;

        PerpsViewTypes.LpDepositCooldownStateView memory viewData =
            lens.getLpDepositCooldownState(false, requestId, DEPOSITOR);

        assertEq(viewData.vault, address(0));
        assertEq(viewData.requestId, requestId);
        assertEq(viewData.controller, DEPOSITOR);
        assertEq(viewData.activationTime, 0);
        assertEq(viewData.cooldownEnd, 0);
        assertEq(viewData.remainingClaimableShares, 0);
        assertEq(viewData.directRedeemableShares, 0);
    }

    function test_GetLpDepositCooldownState_ReturnsMetadataWhenSelectedVaultIsZero() public {
        ZeroVaultHousePoolStub housePool = new ZeroVaultHousePoolStub();
        PerpsPublicLens lens = new PerpsPublicLens(address(0), address(0), address(0), address(housePool));
        uint256 requestId = 23;

        PerpsViewTypes.LpDepositCooldownStateView memory viewData =
            lens.getLpDepositCooldownState(true, requestId, DEPOSITOR);

        assertEq(viewData.vault, address(0));
        assertEq(viewData.requestId, requestId);
        assertEq(viewData.controller, DEPOSITOR);
        assertEq(viewData.activationTime, 0);
        assertEq(viewData.cooldownEnd, 0);
        assertEq(viewData.remainingClaimableShares, 0);
        assertEq(viewData.directRedeemableShares, 0);
    }

    function test_GetLpDepositCooldownState_TracksActivationAndEligibility() public {
        uint256 assets = 25_000e6;
        usdc.mint(DEPOSITOR, assets);
        vm.startPrank(DEPOSITOR);
        usdc.approve(address(juniorVault), assets);
        uint256 requestId = juniorVault.requestDeposit(assets, DEPOSITOR, DEPOSITOR);
        vm.stopPrank();

        PerpsViewTypes.LpDepositCooldownStateView memory pending =
            publicLens.getLpDepositCooldownState(false, requestId, DEPOSITOR);
        assertEq(pending.vault, address(juniorVault));
        assertEq(pending.requestId, requestId);
        assertEq(pending.controller, DEPOSITOR);
        assertEq(pending.activationTime, 0);
        assertEq(pending.cooldownEnd, 0, "unactivated requests must not expose a synthetic epoch-zero cooldown");
        assertEq(pending.remainingClaimableShares, 0);
        assertEq(pending.directRedeemableShares, 0);

        vm.warp(juniorVault.depositEpochStart(requestId));
        _settleLpEpochForTest();

        PerpsViewTypes.LpDepositCooldownStateView memory cooling =
            publicLens.getLpDepositCooldownState(false, requestId, DEPOSITOR);
        assertEq(cooling.activationTime, block.timestamp, "lens must expose actual successful settlement time");
        assertEq(cooling.cooldownEnd, cooling.activationTime + juniorVault.DEPOSIT_COOLDOWN());
        assertEq(
            cooling.remainingClaimableShares,
            juniorVault.claimableDepositShares(requestId, DEPOSITOR),
            "lens must expose the full unconsumed entitlement"
        );
        assertGt(cooling.remainingClaimableShares, 0);
        assertEq(cooling.directRedeemableShares, 0, "direct routing must remain unavailable during cooldown");

        vm.warp(cooling.cooldownEnd);
        PerpsViewTypes.LpDepositCooldownStateView memory eligible =
            publicLens.getLpDepositCooldownState(false, requestId, DEPOSITOR);
        assertEq(eligible.activationTime, cooling.activationTime);
        assertEq(eligible.cooldownEnd, cooling.cooldownEnd);
        assertEq(eligible.remainingClaimableShares, cooling.remainingClaimableShares);
        assertEq(
            eligible.directRedeemableShares,
            juniorVault.maxRequestRedeemFromClaimableDeposit(requestId, DEPOSITOR),
            "lens must delegate live direct-redemption eligibility to the vault"
        );
        assertEq(eligible.directRedeemableShares, eligible.remainingClaimableShares);
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";

contract DepositEstimateTest is HousePoolAsyncTestBase {

    address internal constant ALICE = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_JuniorWipeSuppressesEstimateAndPreservesPendingRefund() public {
        _assertWipedDepositEstimate(false);
    }

    function test_SeniorWipeSuppressesEstimateAndPreservesPendingRefund() public {
        _assertWipedDepositEstimate(true);
    }

    function _assertWipedDepositEstimate(
        bool isSenior
    ) internal {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        uint256 assets = 100e6;
        uint256 requestId = _requestAsyncDeposit(vault, ALICE, assets);
        assertGt(vault.estimateDepositShares(assets), 0);
        vm.warp(pool.lpEpochStart(requestId));
        _refreshMarkForAsyncSettlement();

        // Model a pool loss without consuming the pending deposit's separate vault escrow.
        uint256 poolAssetsBefore = usdc.balanceOf(address(pool));
        usdc.burn(address(pool), poolAssetsBefore);
        assertGt(isSenior ? pool.seniorPrincipal() : pool.juniorPrincipal(), 0, "stored principal is still stale");
        assertGt(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.estimateDepositShares(assets), 0, "projected wipe must suppress the estimate before reconcile");

        PerpsViewTypes.LpRequestStateView memory state = publicLens.getLpRequestState(isSenior, requestId, ALICE);
        assertEq(state.pendingDepositAssets, assets, "the pending USDC must remain visible");
        assertEq(state.pendingDepositSharesEstimate, 0);
        assertEq(state.claimableDepositAssets, 0);
        assertEq(state.claimableDepositShares, 0);

        vm.prank(address(vault));
        pool.reconcile();
        assertEq(isSenior ? pool.seniorPrincipal() : pool.juniorPrincipal(), 0);
        assertEq(vault.estimateDepositShares(assets), 0, "reconciled wipe must also suppress the estimate");
        assertFalse(pool.canSettleDepositEntries());
        vm.expectRevert(IHousePool.HousePool__NoLpEpochProgress.selector);
        pool.settleLpEpoch(0, 0);

        vm.prank(ALICE);
        assertEq(vault.cancelPendingDeposit(requestId, ALICE, ALICE), assets);
        assertEq(usdc.balanceOf(ALICE), assets, "terminal wipe must retain the full cancellation refund");
        assertEq(vault.pendingDepositRequest(requestId, ALICE), 0);
        assertEq(vault.pendingDepositEscrowAssets(), 0);

        // Restoring real backing must reopen indicative pricing for the surviving shares.
        usdc.mint(address(pool), poolAssetsBefore);
        vm.prank(address(vault));
        pool.reconcile();
        assertGt(vault.estimateDepositShares(assets), 0);
    }

}

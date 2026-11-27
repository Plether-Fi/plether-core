// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {HousePoolAsyncTestBase} from "../../shared/HousePoolTestBase.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract JuniorDepositSafetyTest is HousePoolAsyncTestBase {

    uint256 internal constant VIRTUAL_SHARES = 1000;
    uint256 internal constant SUPPLY_CEILING = type(uint256).max - VIRTUAL_SHARES;
    bytes4 internal constant SUPPLY_LIMIT_ERROR = bytes4(keccak256("TrancheVault__ShareSupplyLimitExceeded()"));

    address internal constant ALICE = address(0xA11CE);
    address internal constant SENIOR_LP = address(0x5E1110);
    address internal constant FEE_RECIPIENT = address(0xFEE1);

    function test_JuniorPriceFloorUsesWholeShareUnitsAndPreservesSeniorPricing() public view {
        // One asset atom per whole (1e9 raw-unit) share, including the existing virtual offsets.
        uint256 supply = 1e18 - VIRTUAL_SHARES;
        uint256 floorAssets = 1e9 - 1;

        assertEq(juniorVault.quoteDepositFromState(1e6, floorAssets - 1, supply, 0), 0);
        assertEq(juniorVault.quoteDepositFromState(1e6, floorAssets, supply, 0), 1e15);
        assertGt(juniorVault.quoteDepositFromState(1e6, floorAssets + 1, supply, 0), 0);
        assertGt(seniorVault.quoteDepositFromState(1e6, floorAssets - 1, supply, 0), 0);
        assertEq(juniorVault.quoteDepositFromState(1e6, 0, 0, 0), 1e9, "initial seed pricing remains available");
        assertGt(
            juniorVault.quoteDepositFromState(100e6, 500e6, 1000e9, 0),
            100e9,
            "ordinary discounted entry above the floor must remain available"
        );
    }

    function test_SupplyHeadroomQuotesAllowExactFitAndRejectCumulativeExcess() public view {
        uint256 supply = SUPPLY_CEILING - 2e6;
        uint256 assets = supply + VIRTUAL_SHARES - 1;

        assertEq(juniorVault.quoteDepositFromState(1e6, assets, supply, 0), 1e6);
        assertEq(juniorVault.quoteDepositFromState(2e6, assets, supply, 0), 2e6);
        assertEq(juniorVault.quoteDepositFromState(2e6 + 1, assets, supply, 0), 0);
        assertEq(juniorVault.quoteDepositFromState(1e6, assets, SUPPLY_CEILING + 1, 0), 0);
    }

    function test_UnrepresentableDepositQuoteReturnsZero() public view {
        uint256 supply = SUPPLY_CEILING - 100;
        uint256 assets = SUPPLY_CEILING / 1e9 + 1;

        assertEq(juniorVault.quoteDepositFromState(type(uint256).max, assets, supply, 0), 0);
        assertEq(juniorVault.quoteDepositFromState(type(uint256).max, assets, supply, 10_000), 0);
    }

    function test_BootstrapMintReservesVirtualSharesAndCannotCrossCeiling() public {
        _poolMint(SUPPLY_CEILING - juniorVault.totalSupply());
        assertEq(juniorVault.totalSupply(), SUPPLY_CEILING);

        vm.expectRevert(SUPPLY_LIMIT_ERROR);
        _poolMint(1);

        assertEq(juniorVault.totalSupply(), SUPPLY_CEILING);
    }

    function test_BootstrapMintChecksHeadroomAfterMaintenanceFeeCheckpoint() public {
        uint256 rawSupply = SUPPLY_CEILING - 100;
        _poolMint(rawSupply - juniorVault.totalSupply());
        _enableFee();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 100);

        vm.expectRevert(SUPPLY_LIMIT_ERROR);
        _poolMint(1);

        assertEq(juniorVault.totalSupply(), rawSupply, "failed outer mint must also roll back its fee checkpoint");
        assertEq(juniorVault.balanceOf(FEE_RECIPIENT), 0);
        assertEq(juniorVault.pendingMaintenanceFeeShares(), 100);
    }

    function test_PendingFeesCloseJuniorAdmissionAndQuotesAtTheFloor() public {
        _enableFee();
        uint256 pricingAssets = _juniorPricingAssets();
        uint256 rawSupply = (pricingAssets + 1) * 1e9 - VIRTUAL_SHARES;
        _poolMint(rawSupply - juniorVault.totalSupply());
        assertGt(juniorVault.quoteDepositFromState(1e6, pricingAssets, rawSupply, 0), 0);
        assertGt(juniorVault.maxRequestDeposit(ALICE), 0);

        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 1 hours);
        uint256 effectiveSupply = juniorVault.accruedTotalSupply();

        assertGt(effectiveSupply, rawSupply);
        assertEq(juniorVault.quoteDepositFromState(1e6, pricingAssets, effectiveSupply, 0), 0);
        assertEq(juniorVault.maxRequestDeposit(ALICE), 0);
        assertEq(juniorVault.estimateDepositShares(1e6), 0);
        assertGt(juniorVault.quoteBootstrapDeposit(1e6), 0, "explicit owner bootstrap may restore distressed backing");
    }

    function test_CouponTimedDustDepositIsRefundedWhileSeniorExitClears() public {
        _fundSenior(SENIOR_LP, 750_000e6);

        // Model the report's honest Junior loss with real cash removal. The pump attempt itself uses public LP APIs.
        settlementToken.burn(address(pool), pool.juniorPrincipal() - 22_540_000);
        vm.prank(address(juniorVault));
        pool.reconcile();
        assertEq(pool.seniorPrincipal(), pool.seniorHighWaterMark());
        assertGt(pool.juniorPrincipal(), 0);

        _finishAsyncCooldown(seniorVault, SENIOR_LP);
        _refreshMarkForAsyncSettlement();
        uint256 depositId = _requestAsyncDeposit(juniorVault, ALICE, 1e6);
        uint256 seniorShares = seniorVault.balanceOf(SENIOR_LP) / 10;
        uint256 redeemId = _requestAsyncRedeem(seniorVault, SENIOR_LP, seniorShares);

        // Time the deposit activation so coupon leaves positive Junior dust, exactly as in the supply pump.
        uint256 elapsed =
            ((pool.juniorPrincipal() - 500_000) * 10_000 * 365 days) / (pool.seniorPrincipal() * pool.seniorRateBps());
        uint256 settlementTime = pool.lastSeniorCouponCheckpointTime() + elapsed;
        assertGe(settlementTime, pool.lpEpochStart(depositId));
        vm.warp(settlementTime);
        _refreshMarkForAsyncSettlement();
        assertGt(_juniorPricingAssets(), 0, "the regression must exercise dust NAV, not a zero-NAV wipe");
        assertLt(_juniorPricingAssets(), 1e6);
        assertEq(juniorVault.estimateDepositShares(1e6), 0);

        _settleAndAssertRefund(depositId, redeemId, seniorShares, 1e6);
    }

    function test_OversizedDepositCannotRollBackSeniorExit() public {
        _fundSenior(SENIOR_LP, 100_000e6);
        _finishAsyncCooldown(seniorVault, SENIOR_LP);
        _refreshMarkForAsyncSettlement();

        // A healthy price can still produce a quote larger than uint256 for a sufficiently large escrow.
        uint256 depositAssets = type(uint256).max / 100;
        uint256 depositId = _requestAsyncDeposit(juniorVault, ALICE, depositAssets);
        uint256 seniorShares = seniorVault.balanceOf(SENIOR_LP) / 10;
        uint256 redeemId = _requestAsyncRedeem(seniorVault, SENIOR_LP, seniorShares);
        vm.warp(pool.lpEpochStart(depositId));
        _refreshMarkForAsyncSettlement();

        assertEq(juniorVault.estimateDepositShares(depositAssets), 0);
        _settleAndAssertRefund(depositId, redeemId, seniorShares, depositAssets);
    }

    function _settleAndAssertRefund(
        uint256 depositId,
        uint256 redeemId,
        uint256 seniorShares,
        uint256 depositAssets
    ) internal {
        uint256 juniorSupplyBefore = juniorVault.totalSupply();
        IHousePool.LpEpochSettlementResult memory result = _settleLpEpochForTest();

        assertEq(result.juniorDepositAssets, 0);
        assertEq(result.juniorDepositShares, 0);
        assertEq(juniorVault.totalSupply(), juniorSupplyBefore, "rejected pump must not multiply Junior supply");
        assertEq(juniorVault.pendingDepositEscrowAssets(), depositAssets);
        assertEq(juniorVault.claimableDepositRequest(depositId, ALICE), 0);
        (,,, bool rejected) = juniorVault.depositEpochQueueState(depositId);
        assertTrue(rejected);

        vm.prank(ALICE);
        assertEq(juniorVault.cancelPendingDeposit(depositId, ALICE, ALICE), depositAssets);
        assertEq(settlementToken.balanceOf(ALICE), depositAssets);
        assertEq(juniorVault.pendingDepositEscrowAssets(), 0);

        assertEq(result.seniorFundedShares, seniorShares);
        assertGt(result.seniorFundedAssets, 0);
        vm.prank(SENIOR_LP);
        uint256 claimedAssets = seniorVault.claimRedeem(redeemId, seniorShares, SENIOR_LP, SENIOR_LP);
        assertEq(claimedAssets, result.seniorFundedAssets);
        assertEq(settlementToken.balanceOf(SENIOR_LP), claimedAssets, "Senior exit must actually reach its owner");
    }

    function _enableFee() internal {
        juniorVault.proposeMaintenanceFeeConfig(1000, FEE_RECIPIENT);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
    }

    function _poolMint(
        uint256 shares
    ) internal {
        vm.prank(address(pool));
        juniorVault.bootstrapMint(shares, ALICE);
    }

    function _juniorPricingAssets() internal view returns (uint256 assets) {
        (, assets) = pool.getPendingDepositTrancheState();
    }

}

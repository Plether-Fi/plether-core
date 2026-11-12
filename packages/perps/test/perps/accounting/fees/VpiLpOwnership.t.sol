// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";

/// @notice VPI pricing must conserve wealth across accounts controlled by the same trader and LP.
contract VpiLpOwnershipTest is BasePerpTest {

    address internal constant ATTACKER_LP = address(0xA11CE);
    address internal constant ATTACKER_TRADER = address(0xA11CF);
    address internal constant OTHER_LP = address(0xB0B);
    address internal constant OTHER_TRADER = address(0xB0C);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.01e18;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialJuniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 1e6;
    }

    function test_CombinedTraderLp_PrequeuedRedeemCannotCaptureRefundableVpi() public {
        _assertPositiveVpiRoundTrip(1e8, ATTACKER_TRADER, false);
    }

    function test_CombinedTraderLp_NonUnitMarkCannotCaptureRefundableVpi() public {
        _assertPositiveVpiRoundTrip(0.8e8, ATTACKER_TRADER, false);
    }

    function test_CombinedTraderLp_SameAccountCannotCaptureRefundableVpi() public {
        _assertPositiveVpiRoundTrip(1e8, ATTACKER_LP, false);
    }

    function test_CombinedTraderLp_CloseBeforeFundingPreservesOrdinaryRedemption() public {
        _assertPositiveVpiRoundTrip(1e8, ATTACKER_TRADER, true);
    }

    function test_CombinedTraderLp_NegativeVpiDepositCannotCaptureLaterClawback() public {
        uint256 lpCapital = 1_000_000e6;
        uint256 traderCapital = 50_000e6;
        uint256 price = 1e8;
        uint256 size = 400_000e18;
        _fundJunior(OTHER_LP, lpCapital);
        _fundTrader(OTHER_TRADER, traderCapital);
        _fundTrader(ATTACKER_TRADER, traderCapital);

        // The other trader creates skew; the controlled trader receives a negative
        // lifetime VPI accrual by opening the opposing position.
        _openThroughRouter(OTHER_TRADER, CfdTypes.Side.SHORT, size, 20_000e6, price);
        _openThroughRouter(ATTACKER_TRADER, CfdTypes.Side.LONG, size, 20_000e6, price);
        (,,,,,, int256 accrued) = engine.positions(ATTACKER_TRADER);
        assertLt(accrued, 0, "fixture must have a reserve-backed negative VPI accrual");
        assertEq(clearinghouse.vpiRebateReserveAssets(ATTACKER_TRADER), uint256(-accrued));

        // Activate the controlled Junior deposit while that receivable is outstanding.
        settlementToken.mint(ATTACKER_LP, lpCapital);
        vm.startPrank(ATTACKER_LP);
        settlementToken.approve(address(juniorVault), lpCapital);
        uint256 depositId = juniorVault.requestDeposit(lpCapital, ATTACKER_LP, ATTACKER_LP);
        vm.stopPrank();
        vm.warp(juniorVault.depositEpochStart(depositId));
        router.settleLpEpoch(_mockPythUpdateData(price));
        uint256 claimableDeposit = juniorVault.claimableDepositRequest(depositId, ATTACKER_LP);
        assertEq(claimableDeposit, lpCapital);
        vm.prank(ATTACKER_LP);
        uint256 shares = juniorVault.claimDeposit(depositId, claimableDeposit, ATTACKER_LP, ATTACKER_LP);
        assertGt(shares, 0);

        _closeThroughRouter(ATTACKER_TRADER, size, price);
        assertEq(clearinghouse.vpiRebateReserveAssets(ATTACKER_TRADER), 0, "close must collect the backing");
        vm.warp(juniorVault.lastDepositTime(ATTACKER_LP) + juniorVault.DEPOSIT_COOLDOWN());
        vm.prank(ATTACKER_LP);
        uint256 redeemId = juniorVault.requestRedeem(shares, ATTACKER_LP, ATTACKER_LP);
        vm.warp(pool.lpEpochStart(redeemId));
        router.settleLpEpoch(_mockPythUpdateData(price));
        uint256 fundedShares = juniorVault.claimableRedeemRequest(redeemId, ATTACKER_LP);
        assertEq(fundedShares, shares, "fixture must fully exit after clawback");
        vm.prank(ATTACKER_LP);
        juniorVault.claimRedeem(redeemId, fundedShares, ATTACKER_LP, ATTACKER_LP);
        assertEq(juniorVault.balanceOf(ATTACKER_LP), 0);
        assertEq(engine.traderClaimBalanceAssets(ATTACKER_TRADER), 0);

        uint256 finalWealth = settlementToken.balanceOf(ATTACKER_LP) + clearinghouse.balanceAssets(ATTACKER_TRADER);
        assertLe(finalWealth, lpCapital + traderCapital, "negative VPI entry must not raise combined wealth");
    }

    function _assertPositiveVpiRoundTrip(
        uint256 price,
        address trader,
        bool closeBeforeFunding
    ) private {
        uint256 lpCapital = 500_000e6;
        uint256 traderCapital = 50_000e6;
        _fundJunior(OTHER_LP, lpCapital);
        _fundJunior(ATTACKER_LP, lpCapital);
        _fundTrader(trader, traderCapital);
        vm.warp(juniorVault.lastDepositTime(ATTACKER_LP) + juniorVault.DEPOSIT_COOLDOWN());

        uint256 shares = juniorVault.maxRequestRedeem(ATTACKER_LP);
        assertEq(shares, juniorVault.balanceOf(ATTACKER_LP));
        vm.prank(ATTACKER_LP);
        uint256 requestId = juniorVault.requestRedeem(shares, ATTACKER_LP, ATTACKER_LP);
        uint256 boundary = pool.lpEpochStart(requestId);
        vm.warp(boundary - 3);

        // Both marks give 400,000 settlement units of skew and LONG endpoint liability.
        uint256 size = price == 1e8 ? 400_000e18 : 500_000e18;
        vm.prank(trader);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, size, 20_000e6, price, false);
        router.executeOrder(openId, _mockPythUpdateData(price));
        (uint256 openedSize,,,,,, int256 paidVpi) = engine.positions(trader);
        assertEq(openedSize, size, "opening order must execute before LP funding");
        assertGt(paidVpi, 0, "fixture must pay positive VPI");

        if (closeBeforeFunding) {
            _closeThroughRouter(trader, size, price);
        }
        vm.warp(boundary);
        router.settleLpEpoch(_mockPythUpdateData(price));
        uint256 fundedShares = juniorVault.claimableRedeemRequest(requestId, ATTACKER_LP);
        assertEq(fundedShares, shares, "reserve must permit the full requested redemption");
        vm.prank(ATTACKER_LP);
        juniorVault.claimRedeem(requestId, fundedShares, ATTACKER_LP, ATTACKER_LP);

        if (!closeBeforeFunding) {
            _closeThroughRouter(trader, size, price);
        }
        (uint256 remainingSize,,,,,,) = engine.positions(trader);
        assertEq(remainingSize, 0, "close must execute");
        assertEq(juniorVault.balanceOf(ATTACKER_LP), 0, "all attacker LP shares must be redeemed");
        assertEq(juniorVault.pendingRedeemRequest(requestId, ATTACKER_LP), 0);
        assertEq(juniorVault.claimableRedeemAssets(requestId, ATTACKER_LP), 0);
        assertEq(engine.traderClaimBalanceAssets(trader), 0, "fixture must settle without deferred trader claims");

        // The terminal comparison uses actual wallet and clearinghouse cash, never a vault pricing view.
        uint256 finalWealth = settlementToken.balanceOf(ATTACKER_LP) + clearinghouse.balanceAssets(trader);
        if (trader != ATTACKER_LP) {
            finalWealth += settlementToken.balanceOf(trader);
        }
        assertLe(finalWealth, lpCapital + traderCapital, "combined trader and LP must not profit from temporary VPI");
    }

    function _closeThroughRouter(
        address trader,
        uint256 size,
        uint256 price
    ) private {
        vm.prank(trader);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, size, 0, 0, true);
        router.executeOrder(closeId, _mockPythUpdateData(price));
        (uint256 remainingSize,,,,,,) = engine.positions(trader);
        assertEq(remainingSize, 0, "closing order must execute");
    }

    function _openThroughRouter(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) private {
        vm.prank(trader);
        uint64 id = router.commitOrder(side, size, margin, price, false);
        router.executeOrder(id, _mockPythUpdateData(price));
        (uint256 openedSize,,,,,,) = engine.positions(trader);
        assertEq(openedSize, size, "opening order must execute");
    }

}

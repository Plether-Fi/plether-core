// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @dev Trading revenue may restore wiped LPs only from cash earned after the wipe, preserving quarantined reserves.
contract PendingRevenueReserveTest is BasePerpTest {

    address private constant HOLDER = address(0xA11CE);
    address private constant INCUMBENT = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    address private constant SENIOR_LP = address(0x5E1102);
    address private constant WIPE_TRADER = address(0x711E);
    address private constant LONG_TRADER = address(0x10116);
    address private constant SHORT_TRADER = address(0x511027);

    struct RecoveryCheckpoint {
        uint256 reserve;
        uint256 poolCash;
        uint256 holderShares;
        uint256 seniorSupply;
        uint256 juniorSupply;
        uint256 seniorHighWaterMark;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: 20,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_PendingRevenuePreservesUnassignedReserveWhenWinnerClosesFirst() public {
        _assertPendingRevenuePreservesReserve(true);
    }

    function test_PendingRevenuePreservesUnassignedReserveWhenLoserClosesFirst() public {
        _assertPendingRevenuePreservesReserve(false);
    }

    function test_PoolRejectsRedemptionOnlySidecar() public {
        vm.mockCall(
            address(housePoolRedemptionMathSidecar),
            abi.encodeWithSelector(housePoolRedemptionMathSidecar.implementationId.selector),
            abi.encode(keccak256("Plether.HousePoolRedemptionMathSidecar.v1"))
        );
        vm.expectRevert(IHousePool.HousePool__InvalidRedemptionMathSidecar.selector);
        new HousePool(address(settlementToken), address(engine), address(housePoolRedemptionMathSidecar));
    }

    function _assertPendingRevenuePreservesReserve(
        bool winnerFirst
    ) private {
        RecoveryCheckpoint memory checkpoint = _prepareWipedTranches();
        _fundTrader(LONG_TRADER, 100_000e6);
        _fundTrader(SHORT_TRADER, 100_000e6);

        // Leave every inflow pending: no LP settlement or reconciliation occurs between these matched cycles.
        for (uint256 i; i < 10; ++i) {
            uint256 entryPrice = i % 2 == 0 ? 100_000_000 : 95_000_000;
            uint256 exitPrice = i % 2 == 0 ? 95_000_000 : 100_000_000;
            _trade(LONG_TRADER, CfdTypes.Side.LONG, 300_000e18, 20_000e6, entryPrice, false);
            _trade(SHORT_TRADER, CfdTypes.Side.SHORT, 300_000e18, 20_000e6, entryPrice, false);

            bool longClosesFirst = winnerFirst == (exitPrice < entryPrice);
            if (longClosesFirst) {
                _trade(LONG_TRADER, CfdTypes.Side.LONG, 300_000e18, 0, exitPrice, true);
                _trade(SHORT_TRADER, CfdTypes.Side.SHORT, 300_000e18, 0, exitPrice, true);
            } else {
                _trade(SHORT_TRADER, CfdTypes.Side.SHORT, 300_000e18, 0, exitPrice, true);
                _trade(LONG_TRADER, CfdTypes.Side.LONG, 300_000e18, 0, exitPrice, true);
            }

            _assertFlat(LONG_TRADER);
            _assertFlat(SHORT_TRADER);
            assertEq(pool.unassignedAssets(), checkpoint.reserve, "trading must preserve the parked reserve");
            assertEq(pool.seniorPrincipal(), 0, "Senior recovery must remain pending until LP settlement");
            assertEq(pool.juniorPrincipal(), 0, "Junior recovery must remain pending until LP settlement");
        }

        assertGt(pool.pendingTradingRevenueAssets(), 0, "matched trading must accumulate pending revenue");
        assertEq(engine.totalTraderClaimBalanceAssets(), 0, "flat trades must leave no unpaid trader claims");
        assertFalse(engine.terminalNavSnapshot().hasOpenPositions, "settlement checkpoint must be flat");

        uint256 cashAfterTrading = settlementToken.balanceOf(address(pool));
        assertGt(cashAfterTrading, checkpoint.poolCash, "matched trading must earn net pool cash");
        uint256 netCashGain = cashAfterTrading - checkpoint.poolCash;
        assertLt(netCashGain, checkpoint.seniorHighWaterMark, "new cash must fit entirely inside Senior impairment");

        uint256 requestId = _requestJuniorRedeem(HOLDER, checkpoint.holderShares);
        vm.warp(pool.lpEpochStart(requestId));
        bytes[] memory updateData = _mockPythUpdateData(100_000_000);
        (uint256 pendingSenior, uint256 pendingJunior,,) = pool.getPendingTrancheState();
        assertGt(pendingSenior, pool.seniorPrincipal(), "preview must project pending Senior restoration");
        assertEq(pendingJunior, 0, "Senior impairment must be restored before Junior receives revenue");
        assertLe(pendingSenior + pendingJunior, netCashGain, "preview must not credit the parked reserve");

        router.settleLpEpoch(updateData);

        assertEq(pool.unassignedAssets(), checkpoint.reserve, "settlement must preserve the parked reserve");
        assertEq(pool.seniorPrincipal(), pendingSenior, "live Senior principal must match its pending preview");
        assertEq(pool.juniorPrincipal(), pendingJunior, "live Junior principal must match its pending preview");
        assertGt(pool.seniorPrincipal(), 0, "Senior must receive the new cash first");
        assertEq(pool.juniorPrincipal(), 0, "Junior must remain wiped while Senior is impaired");
        assertEq(pool.seniorHighWaterMark(), checkpoint.seniorHighWaterMark, "revenue must preserve Senior's target");
        assertEq(pool.pendingTradingRevenueAssets(), 0, "settlement must clear pending trading revenue");
        assertEq(pool.pendingRecapitalizationAssets(), 0, "recapitalization must already be fully accounted");
        uint256 holderAssets = juniorVault.claimableRedeemAssets(requestId, HOLDER);
        assertEq(holderAssets, 0, "a wiped Junior redemption must receive no reserve cash");
        assertLe(
            pool.seniorPrincipal() + pool.juniorPrincipal() + holderAssets,
            netCashGain,
            "all LP value credited by settlement must be backed by net new cash"
        );
        assertEq(settlementToken.balanceOf(address(pool)), cashAfterTrading, "zero-value exit must not spend cash");
        assertEq(seniorVault.totalSupply(), checkpoint.seniorSupply, "Senior shares must survive restoration");
        assertEq(juniorVault.totalSupply(), checkpoint.juniorSupply, "zero-value exit must preserve Junior shares");
        _claimZeroValueRefund(requestId, HOLDER, checkpoint.holderShares);
    }

    function _prepareWipedTranches() private returns (RecoveryCheckpoint memory checkpoint) {
        _setSeniorCapacity(40_000_000e6, 8000);
        _fundPublicTranche(juniorVault, HOLDER, 5000e6);
        _fundPublicTranche(juniorVault, INCUMBENT, 4000e6);
        _fundPublicTranche(juniorVault, CAROL, 1000e6);
        _fundPublicTranche(seniorVault, SENIOR_LP, 9000e6);
        assertEq(
            pool.seniorPrincipal(), pool.seniorHighWaterMark(), "recapitalization must start with unimpaired Senior"
        );

        settlementToken.mint(address(this), 980_000e6);
        settlementToken.approve(address(engine), 980_000e6);
        engine.recapitalizePool(980_000e6);

        uint256 carolShares = juniorVault.balanceOf(CAROL);
        uint256 carolRequest = _requestJuniorRedeem(CAROL, carolShares);
        vm.warp(pool.lpEpochStart(carolRequest));
        router.settleLpEpoch(_mockPythUpdateData(100_000_000));
        assertEq(juniorVault.claimableRedeemRequest(carolRequest, CAROL), carolShares);
        vm.prank(CAROL);
        uint256 carolAssets = juniorVault.claimRedeem(carolRequest, carolShares, CAROL, CAROL);
        assertGt(carolAssets, 0, "Carol must exit before the wipe");
        assertEq(pool.unassignedAssets(), 980_000e6, "unneeded recapitalization must remain quarantined");

        _fundTrader(WIPE_TRADER, 100_000e6);
        _trade(WIPE_TRADER, CfdTypes.Side.LONG, 400_000e18, 40_000e6, 100_000_000, false);
        _trade(WIPE_TRADER, CfdTypes.Side.LONG, 400_000e18, 0, 94_000_000, true);
        _assertFlat(WIPE_TRADER);

        uint256 incumbentShares = juniorVault.balanceOf(INCUMBENT);
        uint256 incumbentRequest = _requestJuniorRedeem(INCUMBENT, incumbentShares);
        vm.warp(pool.lpEpochStart(incumbentRequest));
        router.settleLpEpoch(_mockPythUpdateData(94_000_000));
        assertEq(pool.seniorPrincipal(), 0, "realized trader profit must wipe Senior");
        assertEq(pool.juniorPrincipal(), 0, "realized trader profit must wipe Junior");
        assertGt(seniorVault.totalSupply(), 0, "wiped Senior shares must survive");
        assertGt(juniorVault.totalSupply(), 0, "wiped Junior shares must survive");
        _claimZeroValueRefund(incumbentRequest, INCUMBENT, incumbentShares);
        assertEq(pool.pendingTradingRevenueAssets(), 0, "wipe checkpoint must precede new pending revenue");

        checkpoint.reserve = pool.unassignedAssets();
        assertApproxEqAbs(checkpoint.reserve, 976_000e6, 1000e6, "wipe must leave the intended large reserve");
        checkpoint.poolCash = settlementToken.balanceOf(address(pool));
        checkpoint.holderShares = juniorVault.balanceOf(HOLDER);
        checkpoint.seniorSupply = seniorVault.totalSupply();
        checkpoint.juniorSupply = juniorVault.totalSupply();
        checkpoint.seniorHighWaterMark = pool.seniorHighWaterMark();
        assertGt(checkpoint.holderShares, 0, "holder must retain shares through the wipe");
        assertGt(checkpoint.seniorHighWaterMark, 0, "Senior recovery entitlement must survive the wipe");
    }

    function _fundPublicTranche(
        TrancheVault vault,
        address lp,
        uint256 assets
    ) private {
        settlementToken.mint(lp, assets);
        vm.startPrank(lp);
        settlementToken.approve(address(vault), assets);
        uint256 requestId = vault.requestDeposit(assets, lp, lp);
        vm.stopPrank();
        vm.warp(pool.lpEpochStart(requestId));
        router.settleLpEpoch(_mockPythUpdateData(100_000_000));
        assertEq(vault.claimableDepositRequest(requestId, lp), assets, "public deposit must activate fully");
        vm.prank(lp);
        assertGt(vault.claimDeposit(requestId, assets, lp, lp), 0, "public deposit must mint LP shares");
    }

    function _requestJuniorRedeem(
        address lp,
        uint256 shares
    ) private returns (uint256 requestId) {
        uint256 redeemAfter = juniorVault.lastDepositTime(lp) + juniorVault.DEPOSIT_COOLDOWN();
        if (vm.getBlockTimestamp() < redeemAfter) {
            vm.warp(redeemAfter);
        }
        vm.prank(lp);
        requestId = juniorVault.requestRedeem(shares, lp, lp);
    }

    function _claimZeroValueRefund(
        uint256 requestId,
        address lp,
        uint256 shares
    ) private {
        assertEq(juniorVault.claimableRedeemRequest(requestId, lp), 0, "zero-value exit must not burn shares");
        assertEq(juniorVault.refundableRedeemRequest(requestId, lp), shares, "zero-value exit must refund every share");
        uint256 sharesBefore = juniorVault.balanceOf(lp);
        vm.prank(lp);
        assertEq(juniorVault.claimRedeemRefund(requestId, lp, lp), shares, "refund must return the complete request");
        assertEq(juniorVault.balanceOf(lp), sharesBefore + shares, "refunded shares must return to their holder");
    }

    function _trade(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        bool isClose
    ) private {
        vm.prank(trader);
        uint64 orderId = router.commitOrder(side, size, margin, 0, isClose);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, _mockPythUpdateData(price));
        assertEq(result.orderId, orderId, "public execution must consume the committed order");
        assertEq(uint256(result.status), uint256(OrderV3Types.LifecycleStatus.Executed), "public trade must execute");
    }

    function _assertFlat(
        address trader
    ) private view {
        (uint256 size,,,,,,) = engine.positions(trader);
        assertEq(size, 0, "every complete cycle must leave the trader flat");
    }

}

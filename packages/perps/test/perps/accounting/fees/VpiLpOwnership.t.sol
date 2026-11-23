// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

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
        vm.prank(address(router));
        engine.updateMarkPrice(price, uint64(vm.getBlockTimestamp()));
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

/// @notice Flat-price round trips must lose only fees, even when LP ownership changes before VPI settles.
/// @dev Zero carry and coupon isolate VPI ownership. External fees and bounties use actual recipient cash; the close
///      fee retained in the pool uses outside share ownership. Equality cannot hide a VPI gain below execution costs.
contract VpiLpOwnershipFuzzTest is BasePerpTest {

    address internal constant LP = address(0xA11CE);
    address internal constant TRADER = address(0xA11CF);
    address internal constant OTHER_LP = address(0xB0B);
    address internal constant OTHER_TRADER = address(0xB0C);
    uint256 internal constant CAPITAL = 1_000_000e6;
    uint256 internal constant TRADER_CAPITAL = 50_000e6;

    struct PositiveCase {
        uint256 lpCapital;
        uint256 price;
        uint256 size;
        uint256 ownershipShares;
        uint256 requestedShares;
        uint256 epoch;
        uint256 externalCashBefore;
        uint256 retainedFeeCost;
        address trader;
    }

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.01e18;
        params.baseCarryBps = 0;
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

    function setUp() public override {
        super.setUp();
        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 0;
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        router.updateMarkPrice(_mockPythUpdateData(1e8));
        pool.finalizePoolConfig();
    }

    function testFuzz_CombinedTraderLp_PositiveVpiWealthIsNeutralAcrossStagedRedemption(
        uint256 ownershipSeed,
        uint256 notionalSeed,
        uint256 priceSeed,
        uint256 redemptionSeed,
        bool partialFunding,
        bool sameAccount
    ) public {
        PositiveCase memory c;
        // The disjoint ranges guarantee that both full and cash-constrained partial funding are exercised.
        uint256 ownershipBps = partialFunding ? bound(ownershipSeed, 8500, 9500) : bound(ownershipSeed, 1000, 6500);
        uint256 redemptionBps =
            partialFunding ? bound(redemptionSeed, 9000, 10_000) : bound(redemptionSeed, 1000, 10_000);
        c.lpCapital = CAPITAL * ownershipBps / 10_000;
        c.price = bound(priceSeed, 80_000, 120_000) * 1000;
        c.size = _sizeForNotional(
            partialFunding ? bound(notionalSeed, 250_000e6, 390_000e6) : bound(notionalSeed, 100_000e6, 300_000e6),
            c.price
        );
        c.trader = sameAccount ? LP : TRADER;
        _fundJunior(OTHER_LP, CAPITAL - c.lpCapital);
        _fundJunior(LP, c.lpCapital);
        _fundTrader(c.trader, TRADER_CAPITAL);
        vm.warp(juniorVault.lastDepositTime(LP) + juniorVault.DEPOSIT_COOLDOWN());
        c.ownershipShares = juniorVault.balanceOf(LP);
        c.requestedShares = c.ownershipShares * redemptionBps / 10_000;
        vm.prank(LP);
        c.epoch = juniorVault.requestRedeem(c.requestedShares, LP, LP);
        vm.warp(pool.lpEpochStart(c.epoch) - 3);
        c.externalCashBefore = _externalCash();
        _openOrder(c.trader, CfdTypes.Side.LONG, c.size, c.price);
        (,,,,,, int256 accrued) = engine.positions(c.trader);
        assertGt(accrued, 0, "fuzz position must pay refundable VPI");

        vm.warp(pool.lpEpochStart(c.epoch));
        router.settleLpEpoch(_mockPythUpdateData(c.price));
        uint256 funded = juniorVault.claimableRedeemRequest(c.epoch, LP);
        assertGt(funded, 0, "first epoch must pay real cash while VPI remains outstanding");
        if (partialFunding) {
            assertLt(funded, c.requestedShares, "fixture must genuinely constrain epoch funding");
            assertGt(juniorVault.pendingRedeemRequest(c.epoch, LP), 0);
        } else {
            assertEq(funded, c.requestedShares, "unconstrained request must fund fully");
        }
        _claimFunded(c.epoch);
        // Close fee offset against the VPI refund is paid to protocol treasury (PR #165), so it is already
        // accounted for in external cash rather than retained in the pool.
        c.retainedFeeCost = 0;
        _closeOrder(c.trader, c.size, c.price);
        _exitAllShares(c.epoch, c.price);
        _assertTerminalWealth(c.trader, c.lpCapital + TRADER_CAPITAL, c.externalCashBefore, c.retainedFeeCost);
    }

    function testFuzz_CombinedTraderLp_NegativeVpiWealthIsNeutralAcrossEntryAndStagedExit(
        uint256 capitalSeed,
        uint256 notionalSeed,
        uint256 priceSeed,
        uint256 redemptionSeed
    ) public {
        uint256 lpCapital = bound(capitalSeed, 100_000e6, 4_000_000e6);
        uint256 price = bound(priceSeed, 80_000, 120_000) * 1000;
        uint256 size = _sizeForNotional(bound(notionalSeed, 100_000e6, 300_000e6), price);
        _fundJunior(OTHER_LP, CAPITAL);
        _fundTrader(OTHER_TRADER, TRADER_CAPITAL);
        _fundTrader(TRADER, TRADER_CAPITAL);
        // Every controlled asset is funded before either trading or LP entry begins.
        settlementToken.mint(LP, lpCapital);
        _openOrder(OTHER_TRADER, CfdTypes.Side.SHORT, size, price);
        uint256 externalCashBefore = _externalCash();
        _openOrder(TRADER, CfdTypes.Side.LONG, size, price);
        (,,,,,, int256 accrued) = engine.positions(TRADER);
        assertLt(accrued, 0, "fuzz position must receive reserve-backed negative VPI");
        assertEq(clearinghouse.vpiRebateReserveAssets(TRADER), uint256(-accrued));

        vm.startPrank(LP);
        settlementToken.approve(address(juniorVault), lpCapital);
        uint256 depositEpoch = juniorVault.requestDeposit(lpCapital, LP, LP);
        vm.stopPrank();
        vm.warp(juniorVault.depositEpochStart(depositEpoch));
        router.settleLpEpoch(_mockPythUpdateData(price));
        assertEq(juniorVault.claimableDepositRequest(depositEpoch, LP), lpCapital);
        vm.prank(LP);
        uint256 shares = juniorVault.claimDeposit(depositEpoch, lpCapital, LP, LP);
        assertGt(shares, 0);
        _closeOrder(TRADER, size, price);
        assertEq(clearinghouse.vpiRebateReserveAssets(TRADER), 0, "close must collect the entire VPI backing");

        vm.warp(juniorVault.lastDepositTime(LP) + juniorVault.DEPOSIT_COOLDOWN());
        uint256 firstShares = shares * bound(redemptionSeed, 1000, 9000) / 10_000;
        vm.prank(LP);
        uint256 redeemEpoch = juniorVault.requestRedeem(firstShares, LP, LP);
        vm.warp(pool.lpEpochStart(redeemEpoch));
        router.settleLpEpoch(_mockPythUpdateData(price));
        assertEq(juniorVault.claimableRedeemRequest(redeemEpoch, LP), firstShares);
        _claimFunded(redeemEpoch);
        _exitAllShares(redeemEpoch, price);
        _assertTerminalWealth(TRADER, lpCapital + TRADER_CAPITAL, externalCashBefore, 0);
    }

    function _sizeForNotional(
        uint256 notional,
        uint256 price
    ) private pure returns (uint256) {
        return (notional * 1e20 / price) / CfdTypes.SIZE_QUANTUM * CfdTypes.SIZE_QUANTUM;
    }

    function _openOrder(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) private {
        if (engine.lastMarkPrice() != price) {
            if (vm.getBlockTimestamp() <= engine.lastMarkTime()) {
                vm.warp(engine.lastMarkTime() + 1);
            }
            vm.prank(address(router));
            engine.updateMarkPrice(price, uint64(vm.getBlockTimestamp()));
        }
        vm.prank(trader);
        uint64 order = router.commitOrder(side, size, 20_000e6, price, false);
        router.executeOrder(order, _mockPythUpdateData(price));
        (uint256 liveSize,,,,,,) = engine.positions(trader);
        assertEq(liveSize, size, "fuzz opening order must execute");
    }

    function _closeOrder(
        address trader,
        uint256 size,
        uint256 price
    ) private {
        vm.prank(trader);
        uint64 order = router.commitOrder(CfdTypes.Side.LONG, size, 0, 0, true);
        router.executeOrder(order, _mockPythUpdateData(price));
        (uint256 liveSize,,,,,,) = engine.positions(trader);
        assertEq(liveSize, 0, "fuzz closing order must execute");
    }

    function _claimFunded(
        uint256 epoch
    ) private {
        uint256 shares = juniorVault.claimableRedeemRequest(epoch, LP);
        if (shares > 0) {
            vm.prank(LP);
            juniorVault.claimRedeem(epoch, shares, LP, LP);
        }
        assertEq(juniorVault.claimableRedeemRequest(epoch, LP), 0);
        assertEq(juniorVault.claimableRedeemAssets(epoch, LP), 0);
    }

    function _exitAllShares(
        uint256 priorEpoch,
        uint256 price
    ) private {
        if (juniorVault.pendingRedeemRequest(priorEpoch, LP) > 0) {
            vm.warp(pool.lpEpochStart(priorEpoch + 1));
            router.settleLpEpoch(_mockPythUpdateData(price));
            _claimFunded(priorEpoch);
        }
        assertEq(juniorVault.pendingRedeemRequest(priorEpoch, LP), 0, "close must release enough cash for the backlog");
        uint256 shares = juniorVault.balanceOf(LP);
        if (shares > 0) {
            vm.prank(LP);
            uint256 epoch = juniorVault.requestRedeem(shares, LP, LP);
            vm.warp(pool.lpEpochStart(epoch));
            router.settleLpEpoch(_mockPythUpdateData(price));
            assertEq(juniorVault.claimableRedeemRequest(epoch, LP), shares, "remaining ownership must fully exit");
            _claimFunded(epoch);
            assertEq(juniorVault.pendingRedeemRequest(epoch, LP), 0);
        }
        assertEq(juniorVault.balanceOf(LP), 0, "cash comparison must leave no unpriced residual LP shares");
    }

    function _externalCash() private view returns (uint256) {
        return clearinghouse.balanceAssets(address(this)) + clearinghouse.balanceAssets(PROTOCOL_TREASURY_ACCOUNT);
    }

    function _assertTerminalWealth(
        address trader,
        uint256 initialWealth,
        uint256 externalCashBefore,
        uint256 retainedFeeCost
    ) private view {
        assertEq(engine.traderClaimBalanceAssets(trader), 0, "cash comparison must leave no unpaid trader claim");
        uint256 wealth = settlementToken.balanceOf(LP) + clearinghouse.balanceAssets(trader);
        if (trader != LP) {
            wealth += settlementToken.balanceOf(trader);
        }
        uint256 executionCosts = _externalCash() - externalCashBefore;
        // Each floor costs less than one settlement atom at this fixture's sub-unit share price: one controlled
        // mint, at most three funding quotes and three claim allocations, plus the outside-fee split total eight.
        assertApproxEqAbs(
            wealth + executionCosts + retainedFeeCost,
            initialWealth,
            8,
            "VPI timing must preserve combined cash before fees"
        );
    }

}

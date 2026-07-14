// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

contract AuditValueConservationInvariant_FullCloseBounty is BasePerpTest {

    address trader = address(0xA11CE);
    address counterparty = address(0xB0B);
    address keeper = address(0xC0FFEE);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_Invariant_FailedFullCloseCannotExtractActiveMarginAsKeeperBounty() public {
        _fundTrader(trader, 5000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(trader, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterparty, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.96e8, uint64(block.timestamp));

        (, uint256 marginBefore,,,,,) = engine.positions(trader);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);

        vm.prank(trader);
        (bool committed,) =
            address(router).call(abi.encodeCall(router.commitOrder, (CfdTypes.Side.BULL, 100_000e18, 0, 1.95e8, true)));
        if (!committed) {
            return;
        }

        bytes[] memory priceData = _mockPythUpdateData(1.96e8);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(trader);
        assertEq(sizeAfter, 100_000e18, "The slippage-failed full close leaves the position open");
        assertEq(
            clearinghouse.balanceUsdc(keeper),
            keeperSettlementBefore,
            "Failed closes must not convert active position margin into keeper-owned settlement"
        );
        assertEq(marginAfter, marginBefore, "Failed closes must not reduce active position margin");
    }

}

contract AuditValueConservationInvariant_MtmDepositPricing is BasePerpTest {

    address bullTrader = address(0xB011);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_Invariant_DeltaNeutralZeroPnlCannotDiscountNewJuniorDeposits() public {
        uint256 depositAssets = 100_000e6;
        uint256 baselineShares = juniorVault.previewDeposit(depositAssets);

        _fundTrader(bullTrader, 25_000e6);
        _fundTrader(bearTrader, 25_000e6);
        _open(bullTrader, CfdTypes.Side.BULL, 200_000e18, 10_000e6, 1e8);
        _open(bearTrader, CfdTypes.Side.BEAR, 200_000e18, 10_000e6, 1e8);

        assertEq(_unrealizedTraderPnl(), 0, "Equal and opposite positions opened at the mark have zero current PnL");

        uint256 sharesAfterNeutralOpen = juniorVault.previewDeposit(depositAssets);
        assertLe(
            sharesAfterNeutralOpen,
            baselineShares,
            "Zero-PnL delta-neutral exposure must not let new LPs mint discounted junior shares"
        );
    }

}

contract AuditValueConservationInvariant_CarryTiming is BasePerpTest {

    address trader = address(0xCA22A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });
    }

    function test_Invariant_CarryCheckpointCannotForgiveHistoricalLpBackedTime() public {
        _fundTrader(trader, 150_000e6);
        _open(trader, CfdTypes.Side.BULL, 200_000e18, 100_000e6, 1e8);

        uint256 balanceBeforeCheckpoint = clearinghouse.balanceUsdc(trader);
        uint256 elapsed = 30 days;
        uint256 entryPriceLpBackedNotionalUsdc = 9000e6;
        uint256 minimumHistoricalCarryUsdc =
            (entryPriceLpBackedNotionalUsdc * 500 * elapsed) / (CfdMath.SECONDS_PER_YEAR * 10_000);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(0.5e8, uint64(block.timestamp));

        usdc.mint(trader, 1);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), 1);
        clearinghouse.deposit(trader, 1);
        vm.stopPrank();

        uint256 balanceAfterCheckpoint = clearinghouse.balanceUsdc(trader);
        assertLe(
            balanceAfterCheckpoint,
            balanceBeforeCheckpoint + 1 - minimumHistoricalCarryUsdc,
            "A favorable checkpoint price must not erase carry owed for historical LP-backed exposure"
        );
    }

}

contract AuditValueConservationInvariant_PendingRevenue is BasePerpTest {

    function test_Invariant_PendingRevenueCannotDisappearDuringRecapitalization() public {
        usdc.burn(address(pool), pool.rawAssets());

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), 0, "Setup must fully wipe claimant principal");

        uint256 recapitalizationUsdc = 1000e6;
        uint256 revenueUsdc = 1000e6;
        usdc.mint(address(pool), recapitalizationUsdc + revenueUsdc);

        vm.startPrank(address(engine));
        pool.recordClaimantInflow(
            recapitalizationUsdc,
            IHousePool.ClaimantInflowKind.Recapitalization,
            IHousePool.ClaimantInflowCashMode.CashArrived
        );
        pool.recordClaimantInflow(
            revenueUsdc, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.stopPrank();

        uint256 claimantLedgerBefore = _claimantLedgerUsdc();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(
            _claimantLedgerUsdc(),
            claimantLedgerBefore,
            "Settled pending revenue must be credited to principal or unassigned assets before its bucket is decremented"
        );
    }

    function _claimantLedgerUsdc() internal view returns (uint256) {
        return pool.seniorPrincipal() + pool.juniorPrincipal() + pool.unassignedAssets()
            + pool.pendingRecapitalizationUsdc() + pool.pendingTradingRevenueUsdc();
    }

}

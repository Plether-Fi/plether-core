// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: accounting. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#liquidation-settlement

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

contract ReservedBountyEquityTest is BasePerpTest {

    address trader = address(0xA11CE);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_FreeFundedCloseBountyPreservesPriceRiskEquity() public {
        address account = trader;
        _fundTrader(trader, 200e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 175e6, 1e8);

        uint256 pledgeBefore = clearinghouse.pnlPledgeUsdc(account);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        assertEq(
            clearinghouse.pnlPledgeUsdc(account),
            pledgeBefore,
            "Close execution bounty must not be carved from price-risk pledge"
        );
        assertEq(
            clearinghouse.liquidationReserveUsdc(account),
            liquidationReserveBefore,
            "Close execution bounty must not be carved from the liquidation reserve"
        );
        assertEq(_executionBountyReserve(1), 200_000, "Close execution bounty must remain separately reserved");

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 100_530_000);
        assertFalse(preview.liquidatable, "Separately reserved close bounty must not make price risk liquidatable");
        assertEq(preview.equityUsdc, int256(108e6), "Preview must use only the unchanged PnL pledge plus price PnL");

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(account, 100_530_000, poolDepth, uint64(block.timestamp), address(this));
    }

}

contract PositiveResidualChargeCapTest is BasePerpTest {

    address internal constant ACCOUNT_ID = address(uint160(1234));

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 1000,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 1000,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_PositiveEquityKeeperBountyUsesDedicatedReserve() public {
        address trader = ACCOUNT_ID;
        _fundTrader(trader, 100e6);

        _open(ACCOUNT_ID, CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM, 12e6, 1e8);

        uint256 freeSettlementUsdc = _freeSettlementUsdc(ACCOUNT_ID);
        vm.prank(trader);
        clearinghouse.withdraw(ACCOUNT_ID, freeSettlementUsdc);

        vm.warp(1_709_971_200); // Saturday during FAD
        uint256 depth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(ACCOUNT_ID, 1.01e8);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(ACCOUNT_ID);
        assertTrue(preview.liquidatable, "FAD maintenance must make the positive-equity fixture liquidatable");
        assertEq(
            preview.liquidationChargeUsdc,
            liquidationReserveBefore,
            "Liquidation charge must be capped by the dedicated reserve"
        );

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(ACCOUNT_ID, 1.01e8, depth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Keeper bounty must match the dedicated-reserve preview");
        assertEq(
            bounty,
            (liquidationReserveBefore * _riskParams().keeperShareBps) / 10_000,
            "Keeper must receive only its configured share of the funded liquidation reserve"
        );
    }

}

contract DedicatedReserveChargeTest is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 1000,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 1000,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_PositiveEquityLiquidationUsesDedicatedReserve() public {
        address trader = address(0xA201);
        address account = trader;

        _fundTrader(trader, 100e6);

        _open(account, CfdTypes.Side.LONG, CfdTypes.SIZE_QUANTUM, 12e6, 1e8);

        uint256 freeSettlementUsdc = _freeSettlementUsdc(account);
        vm.prank(trader);
        clearinghouse.withdraw(account, freeSettlementUsdc);

        vm.warp(1_709_971_200);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);
        assertTrue(preview.liquidatable, "FAD maintenance must make the positive-equity fixture liquidatable");

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bounty =
            engine.liquidatePosition(account, 101_000_000, poolDepth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Execution must match the dedicated-reserve preview");
        assertEq(
            bounty,
            (liquidationReserveBefore * _riskParams().keeperShareBps) / 10_000,
            "Keeper must receive its configured share of the dedicated liquidation reserve"
        );
    }

}

contract LiquidationSettlementResidualTest is BasePerpTest {

    address trader = address(0xA11CE);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_LiveLiquidationResidualMatchesPreview() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.09e8);

        vm.startPrank(address(router));
        engine.liquidatePosition(account, 1.09e8, pool.totalAssets(), uint64(block.timestamp), address(this));
        vm.stopPrank();

        assertEq(
            clearinghouse.balanceUsdc(account),
            preview.settlementRetainedUsdc,
            "Liquidation should leave exactly the previewed residual settlement after consuming free USDC"
        );
    }

}

contract PriceAndActionReservePriorityLiquidationTest is BasePerpTest {

    address trader = address(0xC10A);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_LiquidationMustConsumeQueuedCommittedMarginBeforeWaivingActionCharge() public {
        address account = trader;
        _fundTrader(trader, 10_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint64 queuedOrderId = router.nextCommitId();
        uint256 committedMarginUsdc = _freeSettlementUsdc(account) - 200_000;
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, committedMarginUsdc, type(uint256).max, false);

        uint256 committedBefore = router.getAccountReservations(account).committedMarginUsdc;
        assertEq(_freeSettlementUsdc(account), 0, "Setup must shelter all non-bounty free settlement in the queue");
        vm.warp(block.timestamp + 10 * 365 days);
        uint256 depth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1e8);
        assertTrue(preview.liquidatable, "Accrued carry should make the position liquidatable");
        assertEq(preview.pnlUsdc, 0, "Setup must isolate liquidation action charges from price PnL");
        assertEq(preview.badDebtUsdc, 0, "Liquidation action-charge collection must never create protocol debt");

        vm.prank(address(router));
        engine.liquidatePosition(account, 1e8, depth, uint64(block.timestamp), address(this));

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still clear the live insolvent position");
        assertEq(_executionBountyReserve(queuedOrderId), 200_000, "Queued execution bounty should remain reserved");
        assertLt(
            router.getAccountReservations(account).committedMarginUsdc,
            committedBefore,
            "Liquidation should consume queued committed margin before waiving terminal carry"
        );
    }

}

contract MarginAndReservationAdmissionLiquidationTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_FreeSettlementDoesNotIncreasePriceRiskEquity() public {
        address account = alice;
        _fundTrader(alice, 1000e6);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 330e6, 1e8);
        assertEq(clearinghouse.pnlPledgeUsdc(account), 302e6, "Fixture must fund the exact protected price pledge");
        assertEq(
            clearinghouse.liquidationReserveUsdc(account), 20e6, "Fixture must separately fund the liquidation reserve"
        );
        assertEq(_freeSettlementUsdc(account), 670e6, "Fixture must retain free settlement outside price collateral");

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 100_500_000);
        assertFalse(preview.liquidatable, "Exact P+C price equity must remain just above maintenance");
        assertEq(preview.equityUsdc, int256(202e6), "Free settlement must not be folded into exact price equity");
        uint256 poolDepth = pool.totalAssets();

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(account, 100_500_000, poolDepth, uint64(block.timestamp), address(this));
    }

}

contract ReservedSettlementBehaviorLiquidationTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev accounting; source: ACCOUNTING_SPEC.md#liquidation-settlement.
    function test_LiquidationBountyShouldNotIncreaseAfterCrossingZeroEquity() public {
        address traderPositive = address(0xA201);
        address traderNegative = address(0xA202);
        address positiveAccount = traderPositive;
        address negativeAccount = traderNegative;

        _fundTrader(traderPositive, 10_000 * 1e6);
        _fundTrader(traderNegative, 10_000 * 1e6);

        // Each open funds a $100 dedicated liquidation reserve in addition to execution
        // fees and the exact PnL pledge used for price health.
        _open(positiveAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 1700 * 1e6, 1e8);
        _open(negativeAccount, CfdTypes.Side.LONG, 100_000 * 1e18, 1700 * 1e6, 1e8);

        uint256 positiveFreeSettlementUsdc = _freeSettlementUsdc(positiveAccount);
        uint256 negativeFreeSettlementUsdc = _freeSettlementUsdc(negativeAccount);
        vm.prank(traderPositive);
        clearinghouse.withdraw(positiveAccount, positiveFreeSettlementUsdc);
        vm.prank(traderNegative);
        clearinghouse.withdraw(negativeAccount, negativeFreeSettlementUsdc);

        uint256 pledgeUsdc = clearinghouse.pnlPledgeUsdc(positiveAccount);
        assertEq(pledgeUsdc, 1560e6, "Fixture must retain the exact post-fee, post-reserve PnL pledge");
        assertEq(
            clearinghouse.liquidationReserveUsdc(positiveAccount),
            100e6,
            "Fixture must independently fund the liquidation charge"
        );

        // With 1,000 whole lots, these prices place exact P+C equity $5 above and
        // below zero. Both bounties are funded by the same protected reserve.
        uint256 positiveEquityPrice = 101_555_000;
        uint256 negativeEquityPrice = 101_565_000;
        ICfdEngineTypes.LiquidationPreview memory positivePreview =
            engineLens.previewLiquidation(positiveAccount, positiveEquityPrice);
        ICfdEngineTypes.LiquidationPreview memory negativePreview =
            engineLens.previewLiquidation(negativeAccount, negativeEquityPrice);
        assertEq(positivePreview.equityUsdc, int256(5e6), "Positive fixture must sit five USDC above zero");
        assertEq(negativePreview.equityUsdc, -int256(5e6), "Negative fixture must sit five USDC below zero");
        assertEq(
            positivePreview.keeperBountyUsdc,
            negativePreview.keeperBountyUsdc,
            "Dedicated reserve must remove any bounty discontinuity around zero price equity"
        );

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtPositiveEquity = engine.liquidatePosition(
            positiveAccount, positiveEquityPrice, depth, uint64(block.timestamp), address(this)
        );

        depth = pool.totalAssets();
        vm.prank(address(router));
        uint256 bountyAtNegativeEquity = engine.liquidatePosition(
            negativeAccount, negativeEquityPrice, depth, uint64(block.timestamp), address(this)
        );

        assertEq(bountyAtPositiveEquity, positivePreview.keeperBountyUsdc, "Positive execution must match preview");
        assertEq(bountyAtNegativeEquity, negativePreview.keeperBountyUsdc, "Negative execution must match preview");
        assertEq(bountyAtPositiveEquity, bountyAtNegativeEquity, "Bounty must remain continuous across zero equity");
    }

}

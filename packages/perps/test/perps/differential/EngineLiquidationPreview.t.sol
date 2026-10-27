// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineLiquidationPreviewTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_PreviewLiquidation_ReturnsChargeSplitAndLiquidatableFlag() public {
        address trader = address(0xAB14);
        address account = trader;
        _fundTrader(trader, 300e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 200e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(account, 100e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 101_000_000);
        assertTrue(preview.liquidatable);
        assertEq(preview.liquidationChargeAssets, 10_000_000, "Charge must cap at the entry-time liquidation reserve");
        assertEq(preview.keeperBountyAssets, 5_000_000, "Keeper should receive exactly half the reserved charge");
        assertEq(preview.protocolLiquidationFeeAssets, 0, "Protocol fee should default to zero");
        assertEq(preview.lpLiquidationFeeAssets, 5_000_000, "LPs should receive exactly half the reserved charge");
        assertEq(
            preview.keeperBountyAssets + preview.protocolLiquidationFeeAssets + preview.lpLiquidationFeeAssets,
            preview.liquidationChargeAssets,
            "Liquidation charge allocation should conserve value"
        );
        assertLe(preview.liquidationChargeAssets, uint256(preview.equityAssets));
    }

    function test_PreviewLiquidation_PreservesExistingTraderClaimOnPositivePhysicalResidual() public {
        _assertLiquidationRetainedSettlement(false);
    }

    function test_PreviewLiquidation_RetainedSettlementIncludesImmediatePayout() public {
        _assertLiquidationRetainedSettlement(true);
    }

    function _assertLiquidationRetainedSettlement(
        bool liquid
    ) private {
        address trader = address(0xAB14002);
        address account = trader;
        address keeper = address(0xAB14003);
        CfdTypes.RiskParams memory params = _riskParams();
        params.baseCarryBps = 0;
        _setRiskParams(params);
        _fundTrader(trader, 200e6);
        _open(account, CfdTypes.Side.SHORT, 10_000e18, 200e6, 99_700_000);

        _seedAuthenticatedTraderClaim(account, 10e6);
        params.maintMarginBps = 500;
        params.initMarginBps = 750;
        params.fadMarginBps = 750;
        _setRiskParams(params);

        if (!liquid) {
            uint256 poolAssets = pool.totalAssets();
            vm.prank(address(pool));
            settlementToken.transfer(address(0xDEAD), poolAssets - 30e6);
        }

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 100_000_000);

        assertTrue(preview.liquidatable, "Preview should not revert for positive physical residual");
        assertGt(preview.keeperBountyAssets, 0, "Dedicated liquidation reserve should fund a keeper bounty");
        assertGt(preview.settlementRetainedAssets, 0, "Unused PnL pledge should remain as terminal settlement");
        assertEq(preview.freshTraderPayoutAssets, 30e6, "Preview should surface the exact positive price PnL");
        assertEq(
            preview.existingTraderClaimConsumedAssets,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            preview.existingTraderClaimRemainingAssets, 10e6, "Preview should keep the legacy trader claim outstanding"
        );
        assertEq(
            preview.immediatePayoutAssets,
            liquid ? 30e6 : 0,
            "Liquid cash pays the gain now; insufficient cash defers it behind the existing claim"
        );
        assertEq(
            preview.traderClaimBalanceAssets,
            liquid ? 10e6 : 40e6,
            "Claims include the old $10 plus the new $30 only when deferred"
        );

        uint256 settlementBefore = clearinghouse.balanceAssets(account);
        assertEq(
            preview.settlementRetainedAssets,
            settlementBefore - preview.liquidationChargeAssets + (liquid ? 30e6 : 0),
            "Retained settlement includes the $30 cash gain exactly once, after liquidation charges"
        );

        vm.prank(keeper);
        bytes[] memory liquidationPriceData = new bytes[](1);
        liquidationPriceData[0] = abi.encode(uint256(100_000_000));
        router.executeLiquidation(account, liquidationPriceData);

        uint256 liveEffective = pool.totalAssets();
        uint256 traderClaimTotal = engine.totalTraderClaimBalanceAssets();
        liveEffective = liveEffective > traderClaimTotal ? liveEffective - traderClaimTotal : 0;

        assertEq(
            clearinghouse.balanceAssets(account),
            preview.settlementRetainedAssets,
            "Live settlement must equal the retained total, which already includes any immediate payout"
        );
        assertEq(
            engine.traderClaimBalanceAssets(account),
            liquid ? 10e6 : 40e6,
            "Live claims must exclude a fresh payout already paid in cash"
        );
        assertEq(
            preview.effectiveAssetsAfterAssets,
            liveEffective,
            "Preview solvency should use net trader claim liabilities after consumption"
        );
    }

    function test_PreviewLiquidation_StagesForfeitureLikeLiveLiquidation() public {
        address trader = address(0xAB1405);
        address keeper = address(0xAB1406);
        address account = trader;

        _fundTrader(trader, 900e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 100e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservationBefore = router.getAccountReservations(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 195_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, keeper);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));
        _ensureLaterOracleTime();
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertGe(
            observed.protocolLiquidationFeeAssets,
            reservationBefore.executionBountyAssets,
            "Treasury inflow should include the forfeited execution reservation"
        );
        observed.protocolLiquidationFeeAssets -= reservationBefore.executionBountyAssets;
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.traderClaimBalanceAssets(account),
            preview.traderClaimBalanceAssets,
            "Preview trader claim should match live liquidation after staged forfeiture"
        );
        assertEq(
            afterSnapshot.protocolTreasuryBalanceAssets - beforeSnapshot.protocol.protocolTreasuryBalanceAssets,
            reservationBefore.executionBountyAssets + preview.protocolLiquidationFeeAssets,
            "Live liquidation should book forfeited reservations and the configured protocol liquidation fee"
        );
        assertEq(
            observed.effectiveAssetsAfterAssets,
            preview.effectiveAssetsAfterAssets,
            "Preview solvency should match live liquidation after staged forfeiture"
        );
    }

    function test_PreviewLiquidation_ExcludesReservedExecutionBountyFromReachableCollateral() public {
        address trader = address(0xAB1406);
        address account = trader;
        _fundTrader(trader, 350e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 100e18, 3e6, type(uint256).max, false);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 102_500_000);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);

        assertGt(reservation.executionBountyAssets, 0, "Setup must create clearinghouse-reserved execution bounty");
        assertEq(
            preview.reachableCollateralAssets,
            snapshot.terminalPriceCollectibleCapAssets,
            "Liquidation preview must use only the exact PnL pledge/claim price-loss cap"
        );
        assertEq(
            snapshot.liquidationReachableSettlementAssets,
            snapshot.settlementBalanceAssets - reservation.executionBountyAssets,
            "Account-ledger terminal reachability must exclude reserved execution bounty"
        );
        assertLt(
            preview.reachableCollateralAssets,
            snapshot.liquidationReachableSettlementAssets,
            "Generic free settlement must remain outside the exact terminal price-loss cap"
        );
        assertEq(
            snapshot.executionBountyReserveAssets,
            reservation.executionBountyAssets,
            "Expanded account ledger must continue to report execution reservation outside liquidation reachability"
        );
    }

}

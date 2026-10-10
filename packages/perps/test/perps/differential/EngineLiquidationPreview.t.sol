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
        assertEq(preview.liquidationChargeUsdc, 10_000_000, "Charge must cap at the entry-time liquidation reserve");
        assertEq(preview.keeperBountyUsdc, 5_000_000, "Keeper should receive exactly half the reserved charge");
        assertEq(preview.protocolLiquidationFeeUsdc, 0, "Protocol fee should default to zero");
        assertEq(preview.lpLiquidationFeeUsdc, 5_000_000, "LPs should receive exactly half the reserved charge");
        assertEq(
            preview.keeperBountyUsdc + preview.protocolLiquidationFeeUsdc + preview.lpLiquidationFeeUsdc,
            preview.liquidationChargeUsdc,
            "Liquidation charge allocation should conserve value"
        );
        assertLe(preview.liquidationChargeUsdc, uint256(preview.equityUsdc));
    }

    function test_PreviewLiquidation_PreservesExistingTraderClaimOnPositivePhysicalResidual() public {
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

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 30e6);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 100_000_000);

        assertTrue(preview.liquidatable, "Preview should not revert for positive physical residual");
        assertGt(preview.keeperBountyUsdc, 0, "Dedicated liquidation reserve should fund a keeper bounty");
        assertGt(preview.settlementRetainedUsdc, 0, "Unused PnL pledge should remain as terminal settlement");
        assertEq(preview.freshTraderPayoutUsdc, 30e6, "Preview should surface the exact positive price PnL");
        assertEq(
            preview.existingTraderClaimConsumedUsdc,
            0,
            "Positive physical residual should not consume legacy trader claim"
        );
        assertEq(
            preview.existingTraderClaimRemainingUsdc, 10e6, "Preview should keep the legacy trader claim outstanding"
        );
        assertEq(
            preview.immediatePayoutUsdc,
            0,
            "Current preview should keep the physical payout as a trader claim when the existing claim remains untouched"
        );
        assertEq(
            preview.traderClaimBalanceUsdc,
            10e6 + preview.freshTraderPayoutUsdc,
            "Trader claim should reflect the untouched existing claim plus the fresh claim amount in the current preview model"
        );
        assertEq(preview.badDebtUsdc, 0, "Positive residual should not report bad debt");

        vm.prank(keeper);
        bytes[] memory liquidationPriceData = new bytes[](1);
        liquidationPriceData[0] = abi.encode(uint256(100_000_000));
        router.executeLiquidation(account, liquidationPriceData);

        uint256 liveEffective = pool.totalAssets();
        uint256 traderClaimTotal = engine.totalTraderClaimBalanceUsdc();
        liveEffective = liveEffective > traderClaimTotal ? liveEffective - traderClaimTotal : 0;

        assertEq(
            clearinghouse.balanceUsdc(account),
            preview.settlementRetainedUsdc + preview.immediatePayoutUsdc,
            "Live settlement must conserve retained collateral plus any immediate payout"
        );
        assertEq(
            engine.traderClaimBalanceUsdc(account),
            10e6 + preview.freshTraderPayoutUsdc,
            "Live liquidation should preserve the old trader claim plus the fresh claim amount"
        );
        assertEq(
            preview.effectiveAssetsAfterUsdc,
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
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, keeper, beforeSnapshot);
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterSnapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertGe(
            observed.protocolLiquidationFeeUsdc,
            reservationBefore.executionBountyUsdc,
            "Treasury inflow should include the forfeited execution reservation"
        );
        observed.protocolLiquidationFeeUsdc -= reservationBefore.executionBountyUsdc;
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            engine.traderClaimBalanceUsdc(account),
            preview.traderClaimBalanceUsdc,
            "Preview trader claim should match live liquidation after staged forfeiture"
        );
        assertEq(preview.badDebtUsdc, 0, "Staged forfeiture must not recreate a protocol debt ledger");
        assertEq(
            afterSnapshot.protocolTreasuryBalanceUsdc - beforeSnapshot.protocol.protocolTreasuryBalanceUsdc,
            reservationBefore.executionBountyUsdc + preview.protocolLiquidationFeeUsdc,
            "Live liquidation should book forfeited reservations and the configured protocol liquidation fee"
        );
        assertEq(
            observed.effectiveAssetsAfterUsdc,
            preview.effectiveAssetsAfterUsdc,
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
            router.commitOrder(CfdTypes.Side.LONG, 1000e18, 0, type(uint256).max, true);
        }
        clearinghouse.withdraw(account, 70e6);
        vm.stopPrank();

        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 102_500_000);
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);

        assertGt(reservation.executionBountyUsdc, 0, "Setup must create clearinghouse-reserved execution bounty");
        assertEq(
            preview.reachableCollateralUsdc,
            snapshot.terminalPriceCollectibleCapUsdc,
            "Liquidation preview must use only the exact PnL pledge/claim price-loss cap"
        );
        assertEq(
            snapshot.liquidationReachableSettlementUsdc,
            snapshot.settlementBalanceUsdc - reservation.executionBountyUsdc,
            "Account-ledger terminal reachability must exclude reserved execution bounty"
        );
        assertLt(
            preview.reachableCollateralUsdc,
            snapshot.liquidationReachableSettlementUsdc,
            "Generic free settlement must remain outside the exact terminal price-loss cap"
        );
        assertEq(
            snapshot.executionBountyReserveUsdc,
            reservation.executionBountyUsdc,
            "Expanded account ledger must continue to report execution reservation outside liquidation reachability"
        );
    }

}

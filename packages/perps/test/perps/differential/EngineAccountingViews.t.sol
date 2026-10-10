// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

import {HousePoolEngineViewTypes} from "@plether/perps/interfaces/HousePoolEngineViewTypes.sol";

import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";

import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";

import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {CfdEngineTestBase} from "../shared/CfdEngineTestBase.sol";

contract EngineAccountingViewsTest is CfdEngineTestBase {

    using stdStorage for StdStorage;

    function test_GetAccountCollateralView_ReturnsCurrentBuckets() public {
        address trader = address(0xAB10);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 7900 * 1e6, type(uint256).max, false);

        ICfdEngineTypes.AccountCollateralView memory viewData = engineAccountLens.getAccountCollateralView(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertEq(viewData.settlementBalanceUsdc, clearinghouse.balanceUsdc(account));
        assertEq(viewData.lockedMarginUsdc, clearinghouse.lockedMarginUsdc(account));
        assertEq(viewData.activePositionMarginUsdc, positionMargin);
        assertEq(viewData.otherLockedMarginUsdc, viewData.lockedMarginUsdc - positionMargin);
        assertEq(viewData.freeSettlementUsdc, _freeSettlementUsdc(account));
        assertEq(viewData.closeReachableUsdc, _freeSettlementUsdc(account));
        assertEq(viewData.liquidationReachableSettlementUsdc, _terminalReachableUsdc(account));
        assertEq(viewData.terminalPriceCollectibleCapUsdc, terminalNavBook.curveOf(account).effectiveCapUsdcAtoms);
        assertEq(viewData.accountEquityUsdc, clearinghouse.getAccountEquityUsdc(account));
        assertEq(viewData.freeBuyingPowerUsdc, clearinghouse.getFreeBuyingPowerUsdc(account));
        assertEq(viewData.traderClaimBalanceUsdc, 0);
    }

    function test_GetPositionView_ReturnsLivePositionState() public {
        address trader = address(0xAB11);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.LONG));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.marginUsdc, positionMargin);
        assertGt(viewData.unrealizedPnlUsdc, 0);
    }

    function test_GetProtocolAccountingSnapshot_ReflectsCanonicalLedgerState() public {
        address trader = address(0xAB13);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory housePoolSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        uint256 expectedNetPhysicalAssetsUsdc = snapshot.poolAssetsUsdc > snapshot.protocolTreasuryBalanceUsdc
            ? snapshot.poolAssetsUsdc - snapshot.protocolTreasuryBalanceUsdc
            : 0;
        uint256 settlementBufferUsdc =
            SolvencyAccountingLib.settlementBufferTargetUsdc(snapshot.maxLiabilityUsdc, engine.settlementBufferBps());
        uint256 expectedWithdrawalReservedUsdc =
            snapshot.maxLiabilityUsdc + snapshot.totalTraderClaimBalanceUsdc + settlementBufferUsdc;
        uint256 expectedFreeUsdc = snapshot.poolAssetsUsdc > expectedWithdrawalReservedUsdc
            ? snapshot.poolAssetsUsdc - expectedWithdrawalReservedUsdc
            : 0;

        assertEq(snapshot.poolAssetsUsdc, pool.totalAssets());
        assertEq(snapshot.netPhysicalAssetsUsdc, expectedNetPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability());
        assertEq(snapshot.withdrawalReservedUsdc, expectedWithdrawalReservedUsdc);
        assertEq(snapshot.freeUsdc, expectedFreeUsdc);
        assertEq(snapshot.protocolTreasuryBalanceUsdc, clearinghouse.balanceUsdc(engine.protocolTreasury()));
        assertEq(snapshot.totalTraderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, (_maxLiability() > 0));
        assertEq(snapshot.poolAssetsUsdc, viewData.poolAssetsUsdc);
        assertEq(housePoolSnapshot.physicalAssetsUsdc, snapshot.poolAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, viewData.maxLiabilityUsdc);
        assertEq(snapshot.withdrawalReservedUsdc, viewData.withdrawalReservedUsdc);
        assertEq(snapshot.freeUsdc, viewData.freeUsdc);
        assertEq(snapshot.protocolTreasuryBalanceUsdc, viewData.protocolTreasuryBalanceUsdc);
        assertEq(snapshot.totalTraderClaimBalanceUsdc, viewData.totalTraderClaimBalanceUsdc);
        assertEq(snapshot.degradedMode, viewData.degradedMode);
        assertEq(snapshot.hasLiveLiability, viewData.hasLiveLiability);
        assertEq(snapshot.netPhysicalAssetsUsdc, housePoolSnapshot.netPhysicalAssetsUsdc);
        assertEq(snapshot.maxLiabilityUsdc, housePoolSnapshot.maxLiabilityUsdc);
        assertEq(snapshot.totalTraderClaimBalanceUsdc, housePoolSnapshot.traderClaimBalanceUsdc);
    }

    function test_ProtocolAccountingSnapshot_IgnoresUnaccountedPoolDonationUntilAccounted() public {
        _fundJunior(address(0xB0B), 500_000e6);
        uint256 accountedBefore = pool.totalAssets();

        usdc.mint(address(pool), 100_000e6);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeAccount =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw pool balance should include the donation");
        assertEq(
            pool.totalAssets(), accountedBefore, "Canonical pool assets should ignore the donation until accounted"
        );
        assertEq(beforeAccount.poolAssetsUsdc, accountedBefore, "Protocol snapshot should follow canonical assets");
        assertEq(
            houseBefore.netPhysicalAssetsUsdc, accountedBefore, "HousePool snapshot should ignore unaccounted donations"
        );

        pool.accountExcess();

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory afterAccount =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseAfter =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(
            pool.totalAssets(), accountedBefore + 100_000e6, "Explicit accounting should raise canonical pool assets"
        );
        assertEq(
            afterAccount.poolAssetsUsdc,
            accountedBefore + 100_000e6,
            "Protocol snapshot should reflect explicit accounting"
        );
        assertEq(
            houseAfter.netPhysicalAssetsUsdc,
            accountedBefore + 100_000e6,
            "HousePool snapshot should reflect explicit accounting"
        );
    }

    function test_GetAccountLedgerView_ReflectsCompactCrossContractState() public {
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 12_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        vm.startPrank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 0, false);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        vm.stopPrank();

        AccountLensViewTypes.AccountLedgerView memory ledgerView = engineAccountLens.getAccountLedgerView(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

        assertEq(ledgerView.settlementBalanceUsdc, buckets.settlementBalanceUsdc);
        assertEq(ledgerView.freeSettlementUsdc, buckets.freeSettlementUsdc);
        assertEq(ledgerView.activePositionMarginUsdc, buckets.activePositionMarginUsdc);
        assertEq(ledgerView.otherLockedMarginUsdc, buckets.otherLockedMarginUsdc);
        assertEq(ledgerView.executionBountyReserveUsdc, reservation.executionBountyUsdc);
        assertEq(ledgerView.committedMarginUsdc, reservation.committedMarginUsdc);
        assertEq(ledgerView.traderClaimBalanceUsdc, engine.traderClaimBalanceUsdc(account));
        assertEq(ledgerView.pendingOrderCount, router.pendingOrderCounts(account));
    }

    function test_GetAccountLedgerSnapshot_ReflectsExpandedAccountHealthState() public {
        address trader = address(0xAB16);
        address account = trader;
        _fundTrader(trader, 12_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.AccountCollateralView memory collateralView =
            engineAccountLens.getAccountCollateralView(account);
        (uint256 sizeStored, uint256 marginStored, uint256 entryPriceStored,, CfdTypes.Side sideStored,,) =
            engine.positions(account);
        IMarginClearinghouse.LockedMarginBuckets memory lockedBuckets = clearinghouse.getLockedMarginBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

        assertEq(snapshot.settlementBalanceUsdc, collateralView.settlementBalanceUsdc);
        assertEq(snapshot.freeSettlementUsdc, collateralView.freeSettlementUsdc);
        assertEq(snapshot.activePositionMarginUsdc, collateralView.activePositionMarginUsdc);
        assertEq(snapshot.otherLockedMarginUsdc, collateralView.otherLockedMarginUsdc);
        assertEq(snapshot.positionMarginBucketUsdc, lockedBuckets.positionMarginUsdc);
        assertEq(snapshot.committedOrderMarginBucketUsdc, lockedBuckets.committedOrderMarginUsdc);
        assertEq(snapshot.reservedSettlementBucketUsdc, lockedBuckets.reservedSettlementUsdc);
        assertEq(snapshot.executionBountyReserveUsdc, reservation.executionBountyUsdc);
        assertEq(snapshot.committedMarginUsdc, reservation.committedMarginUsdc);
        assertEq(snapshot.traderClaimBalanceUsdc, collateralView.traderClaimBalanceUsdc);
        assertEq(snapshot.pendingOrderCount, reservation.pendingOrderCount);
        assertEq(snapshot.closeReachableUsdc, collateralView.closeReachableUsdc);
        assertEq(snapshot.liquidationReachableSettlementUsdc, collateralView.liquidationReachableSettlementUsdc);
        assertEq(snapshot.terminalPriceCollectibleCapUsdc, collateralView.terminalPriceCollectibleCapUsdc);
        assertEq(snapshot.terminalPriceCollectibleCapUsdc, terminalNavBook.curveOf(account).effectiveCapUsdcAtoms);
        assertEq(snapshot.accountEquityUsdc, collateralView.accountEquityUsdc);
        assertEq(snapshot.freeBuyingPowerUsdc, collateralView.freeBuyingPowerUsdc);
        assertTrue(snapshot.hasPosition);
        assertEq(uint256(snapshot.side), uint256(sideStored));
        assertEq(snapshot.size, sizeStored);
        assertEq(snapshot.margin, marginStored);
        assertEq(snapshot.entryPrice, entryPriceStored);
    }

    function test_GetHousePoolInputSnapshot_ReflectsCurrentAccountingState() public {
        address trader = address(0xAB14);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status = engineProtocolLens.getHousePoolStatusSnapshot();
        ICfdEngineTypes.TerminalNavSnapshot memory terminalSnapshot = engine.terminalNavSnapshot();
        uint256 protocolTreasuryBalanceUsdc = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 expectedNetPhysicalAssetsUsdc =
            pool.totalAssets() > protocolTreasuryBalanceUsdc ? pool.totalAssets() - protocolTreasuryBalanceUsdc : 0;

        assertEq(
            snapshot.physicalAssetsUsdc, pool.totalAssets(), "Snapshot physical assets must match canonical pool assets"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            expectedNetPhysicalAssetsUsdc,
            "Treasury clearinghouse fees should be excluded from pool net assets"
        );
        assertEq(snapshot.maxLiabilityUsdc, _maxLiability(), "Snapshot liability must match accessor");
        assertEq(
            snapshot.supplementalReservedUsdc,
            SolvencyAccountingLib.settlementBufferTargetUsdc(_maxLiability(), engine.settlementBufferBps()),
            "Snapshot supplemental reserve must match the configured settlement buffer"
        );
        assertEq(
            snapshot.terminalLpPriceDeltaUsdc,
            terminalSnapshot.terminalLpPriceDeltaUsdc,
            "Snapshot terminal LP price delta must match engine"
        );
        assertEq(
            snapshot.terminalNavBookVersion,
            terminalSnapshot.bookVersion,
            "Snapshot terminal NAV book version must match engine"
        );
        assertEq(
            snapshot.traderClaimBalanceUsdc, engine.totalTraderClaimBalanceUsdc(), "Snapshot payout must match storage"
        );
        assertTrue(snapshot.markFreshnessRequired, "Open directional liability should require fresh marks");
        assertEq(
            snapshot.maxMarkStaleness,
            pool.markStalenessLimit(),
            "Live-market snapshot should use HousePool's configured limit"
        );
        assertEq(status.lastMarkTime, engine.lastMarkTime(), "Status snapshot mark timestamp must match engine state");
        assertEq(status.oracleFrozen, engine.isOracleFrozen(), "Status snapshot frozen flag must match engine state");
        assertEq(status.degradedMode, engine.degradedMode(), "Status snapshot degraded flag must match engine state");
    }

    function test_GetHousePoolInputSnapshot_UsesFrozenOracleFreshnessLimit() public {
        uint256 saturdayFrozen = 1_710_021_600;
        address trader = address(0xAB15);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.SHORT, 100_000e18, 9000e6, 1e8);

        vm.warp(saturdayFrozen);
        assertTrue(engine.isOracleFrozen(), "Test setup should be inside a frozen oracle window");

        HousePoolEngineViewTypes.HousePoolInputSnapshot memory snapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());
        HousePoolEngineViewTypes.HousePoolStatusSnapshot memory status = engineProtocolLens.getHousePoolStatusSnapshot();
        assertTrue(snapshot.markFreshnessRequired, "Open liability should still require freshness in frozen mode");
        assertEq(
            snapshot.maxMarkStaleness,
            engine.fadMaxStaleness(),
            "Frozen-oracle snapshot should use the relaxed engine staleness bound"
        );
        assertEq(status.lastMarkTime, engine.lastMarkTime(), "Frozen status snapshot must carry mark timestamp");
        assertTrue(status.oracleFrozen, "Frozen status snapshot should report frozen oracle mode");
        assertEq(status.degradedMode, engine.degradedMode(), "Frozen status degraded flag must match engine state");
    }

}

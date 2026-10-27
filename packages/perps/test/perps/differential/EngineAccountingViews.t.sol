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
        assertEq(viewData.settlementBalanceAssets, clearinghouse.balanceAssets(account));
        assertEq(viewData.lockedMarginAssets, clearinghouse.lockedMarginAssets(account));
        assertEq(viewData.activePositionMarginAssets, positionMargin);
        assertEq(viewData.otherLockedMarginAssets, viewData.lockedMarginAssets - positionMargin);
        assertEq(viewData.freeSettlementAssets, _freeSettlementAssets(account));
        assertEq(viewData.closeReachableAssets, _freeSettlementAssets(account));
        assertEq(viewData.liquidationReachableSettlementAssets, _terminalReachableAssets(account));
        assertEq(viewData.terminalPriceCollectibleCapAssets, terminalNavBook.curveOf(account).effectiveCapAssetAtoms);
        assertEq(viewData.accountEquityAssets, clearinghouse.getAccountEquityAssets(account));
        assertEq(viewData.freeBuyingPowerAssets, clearinghouse.getFreeBuyingPowerAssets(account));
        assertEq(viewData.traderClaimBalanceAssets, 0);
    }

    function test_GetPositionView_ReturnsLivePositionState() public {
        address trader = address(0xAB11);
        address account = trader;
        _fundTrader(trader, 10_000 * 1e6);
        _open(account, CfdTypes.Side.LONG, 100_000 * 1e18, 2000 * 1e6, 1e8);

        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(90_000_000, uint64(vm.getBlockTimestamp()));

        PerpsViewTypes.PositionView memory viewData = _publicPosition(account);
        (, uint256 positionMargin,,,,,) = engine.positions(account);
        assertTrue(viewData.exists);
        assertEq(uint256(viewData.side), uint256(CfdTypes.Side.LONG));
        assertEq(viewData.size, 100_000 * 1e18);
        assertEq(viewData.entryPrice, 1e8);
        assertEq(viewData.marginAssets, positionMargin);
        assertGt(viewData.unrealizedPnlAssets, 0);
    }

    function test_GetProtocolAccountingSnapshot_ReflectsCanonicalLedgerState() public {
        address trader = address(0xAB13);
        address account = trader;
        _fundTrader(trader, 11_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 9000e6);

        _close(account, CfdTypes.Side.LONG, 100_000e18, 80_000_000);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory snapshot =
            engineProtocolLens.getProtocolAccountingSnapshot();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory viewData =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory housePoolSnapshot =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        uint256 settlementBufferAssets = SolvencyAccountingLib.settlementBufferTargetAssets(
            snapshot.maxLiabilityAssets, engine.settlementBufferBps()
        );
        uint256 expectedWithdrawalReservedAssets =
            snapshot.maxLiabilityAssets + snapshot.totalTraderClaimBalanceAssets + settlementBufferAssets;
        uint256 expectedFreeAssets = snapshot.poolAssets > expectedWithdrawalReservedAssets
            ? snapshot.poolAssets - expectedWithdrawalReservedAssets
            : 0;

        assertEq(snapshot.poolAssets, pool.totalAssets());
        assertEq(snapshot.netPhysicalAssets, pool.totalAssets());
        assertEq(snapshot.maxLiabilityAssets, _maxLiability());
        assertEq(snapshot.withdrawalReservedAssets, expectedWithdrawalReservedAssets);
        assertEq(snapshot.freeAssets, expectedFreeAssets);
        assertEq(snapshot.protocolTreasuryBalanceAssets, clearinghouse.balanceAssets(engine.protocolTreasury()));
        assertEq(snapshot.totalTraderClaimBalanceAssets, engine.totalTraderClaimBalanceAssets());
        assertEq(snapshot.degradedMode, engine.degradedMode());
        assertEq(snapshot.hasLiveLiability, (_maxLiability() > 0));
        assertEq(snapshot.poolAssets, viewData.poolAssets);
        assertEq(housePoolSnapshot.physicalAssets, snapshot.poolAssets);
        assertEq(snapshot.maxLiabilityAssets, viewData.maxLiabilityAssets);
        assertEq(snapshot.withdrawalReservedAssets, viewData.withdrawalReservedAssets);
        assertEq(snapshot.freeAssets, viewData.freeAssets);
        assertEq(snapshot.protocolTreasuryBalanceAssets, viewData.protocolTreasuryBalanceAssets);
        assertEq(snapshot.totalTraderClaimBalanceAssets, viewData.totalTraderClaimBalanceAssets);
        assertEq(snapshot.degradedMode, viewData.degradedMode);
        assertEq(snapshot.hasLiveLiability, viewData.hasLiveLiability);
        assertEq(snapshot.netPhysicalAssets, housePoolSnapshot.netPhysicalAssets);
        assertEq(snapshot.maxLiabilityAssets, housePoolSnapshot.maxLiabilityAssets);
        assertEq(snapshot.totalTraderClaimBalanceAssets, housePoolSnapshot.traderClaimBalanceAssets);
    }

    function test_ProtocolAccountingSnapshot_IgnoresUnaccountedPoolDonationUntilAccounted() public {
        _fundJunior(address(0xB0B), 500_000e6);
        uint256 accountedBefore = pool.totalAssets();

        settlementToken.mint(address(pool), 100_000e6);

        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory beforeAccount =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePoolEngineViewTypes.HousePoolInputSnapshot memory houseBefore =
            engineProtocolLens.getHousePoolInputSnapshot(pool.markStalenessLimit());

        assertEq(pool.rawAssets(), accountedBefore + 100_000e6, "Raw pool balance should include the donation");
        assertEq(
            pool.totalAssets(), accountedBefore, "Canonical pool assets should ignore the donation until accounted"
        );
        assertEq(beforeAccount.poolAssets, accountedBefore, "Protocol snapshot should follow canonical assets");
        assertEq(
            houseBefore.netPhysicalAssets, accountedBefore, "HousePool snapshot should ignore unaccounted donations"
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
            afterAccount.poolAssets, accountedBefore + 100_000e6, "Protocol snapshot should reflect explicit accounting"
        );
        assertEq(
            houseAfter.netPhysicalAssets,
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
        IMarginClearinghouse.AccountAssetBuckets memory buckets = clearinghouse.getAccountAssetBuckets(account);
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);

        assertEq(ledgerView.settlementBalanceAssets, buckets.settlementBalanceAssets);
        assertEq(ledgerView.freeSettlementAssets, buckets.freeSettlementAssets);
        assertEq(ledgerView.activePositionMarginAssets, buckets.activePositionMarginAssets);
        assertEq(ledgerView.otherLockedMarginAssets, buckets.otherLockedMarginAssets);
        assertEq(ledgerView.executionBountyReserveAssets, reservation.executionBountyAssets);
        assertEq(ledgerView.committedMarginAssets, reservation.committedMarginAssets);
        assertEq(ledgerView.traderClaimBalanceAssets, engine.traderClaimBalanceAssets(account));
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

        assertEq(snapshot.settlementBalanceAssets, collateralView.settlementBalanceAssets);
        assertEq(snapshot.freeSettlementAssets, collateralView.freeSettlementAssets);
        assertEq(snapshot.activePositionMarginAssets, collateralView.activePositionMarginAssets);
        assertEq(snapshot.otherLockedMarginAssets, collateralView.otherLockedMarginAssets);
        assertEq(snapshot.positionMarginBucketAssets, lockedBuckets.positionMarginAssets);
        assertEq(snapshot.committedOrderMarginBucketAssets, lockedBuckets.committedOrderMarginAssets);
        assertEq(snapshot.reservedSettlementBucketAssets, lockedBuckets.reservedSettlementAssets);
        assertEq(snapshot.executionBountyReserveAssets, reservation.executionBountyAssets);
        assertEq(snapshot.committedMarginAssets, reservation.committedMarginAssets);
        assertEq(snapshot.traderClaimBalanceAssets, collateralView.traderClaimBalanceAssets);
        assertEq(snapshot.pendingOrderCount, reservation.pendingOrderCount);
        assertEq(snapshot.closeReachableAssets, collateralView.closeReachableAssets);
        assertEq(snapshot.liquidationReachableSettlementAssets, collateralView.liquidationReachableSettlementAssets);
        assertEq(snapshot.terminalPriceCollectibleCapAssets, collateralView.terminalPriceCollectibleCapAssets);
        assertEq(snapshot.terminalPriceCollectibleCapAssets, terminalNavBook.curveOf(account).effectiveCapAssetAtoms);
        assertEq(snapshot.accountEquityAssets, collateralView.accountEquityAssets);
        assertEq(snapshot.freeBuyingPowerAssets, collateralView.freeBuyingPowerAssets);
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

        assertEq(
            snapshot.physicalAssets, pool.totalAssets(), "Snapshot physical assets must match canonical pool assets"
        );
        assertEq(
            snapshot.netPhysicalAssets,
            pool.totalAssets(),
            "Treasury is already outside pool custody and must not be subtracted"
        );
        assertEq(snapshot.maxLiabilityAssets, _maxLiability(), "Snapshot liability must match accessor");
        assertEq(
            snapshot.supplementalReservedAssets,
            SolvencyAccountingLib.settlementBufferTargetAssets(_maxLiability(), engine.settlementBufferBps()),
            "Snapshot supplemental reserve must match the configured settlement buffer"
        );
        assertEq(
            snapshot.terminalLpPriceDeltaAssets,
            terminalSnapshot.terminalLpPriceDeltaAssets,
            "Snapshot terminal LP price delta must match engine"
        );
        assertEq(
            snapshot.terminalNavBookVersion,
            terminalSnapshot.bookVersion,
            "Snapshot terminal NAV book version must match engine"
        );
        assertEq(
            snapshot.traderClaimBalanceAssets,
            engine.totalTraderClaimBalanceAssets(),
            "Snapshot payout must match storage"
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

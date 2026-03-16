// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {IMarginClearinghouse} from "../../../src/perps/interfaces/IMarginClearinghouse.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";

contract PerpEconomicConservationInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.cancelCloseOrder.selector;
        selectors[4] = handler.executeNextOrderModelled.selector;
        selectors[5] = handler.liquidate.selector;
        selectors[6] = handler.claimDeferredClearerBounty.selector;
        selectors[7] = handler.createDeferredTraderPayout.selector;
        selectors[8] = handler.claimDeferredPayout.selector;
        selectors[9] = handler.fundVault.selector;
        selectors[10] = handler.setRouterPayoutFailureMode.selector;
        selectors[11] = handler.setVaultAssets.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_KnownActorAndProtocolBalancesConserveUsdcSupply() public view {
        assertEq(
            _knownBalancesSum(),
            usdc.totalSupply(),
            "Known actors and protocol contracts must conserve total USDC supply"
        );
    }

    function invariant_ClearinghouseCustodyMatchesTrackedAccountBalances() public view {
        uint256 trackedBalances;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            trackedBalances += clearinghouse.balanceUsdc(_accountId(handler.actorAt(i)));
        }

        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse custody must equal tracked account settlement balances"
        );
    }

    function invariant_WithdrawalReserveIncludesKnownDeferredLiabilities() public view {
        uint256 expectedReserved = engine.getMaxLiability() + engine.accumulatedFeesUsdc()
            + engine.totalDeferredPayoutUsdc() + engine.totalDeferredClearerBountyUsdc();

        int256 fundingLiability = engine.getLiabilityOnlyFundingPnl();
        if (fundingLiability > 0) {
            expectedReserved += uint256(fundingLiability);
        }

        assertEq(
            engine.getWithdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, fees, and deferred obligations"
        );
    }

    function invariant_TrackedAccountBucketsReconcileSettlementBalances() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            uint256 protectedMargin = size > 0 ? margin : 0;

            IMarginClearinghouse.AccountUsdcBuckets memory buckets =
                clearinghouse.getAccountUsdcBuckets(accountId, protectedMargin);

            assertEq(
                buckets.totalLockedMarginUsdc,
                buckets.activePositionMarginUsdc + buckets.otherLockedMarginUsdc,
                "Tracked account locked margin buckets must reconcile"
            );
            assertEq(
                buckets.settlementBalanceUsdc,
                buckets.totalLockedMarginUsdc + buckets.freeSettlementUsdc,
                "Tracked account settlement balance must equal locked plus free buckets"
            );
            assertEq(
                buckets.settlementBalanceUsdc,
                clearinghouse.balanceUsdc(accountId),
                "Tracked account bucket settlement must equal clearinghouse balance"
            );
        }
    }

    function invariant_HousePoolInputSnapshotMatchesGlobalLedgerBuckets() public view {
        ICfdEngine.HousePoolInputSnapshot memory snapshot = engine.getHousePoolInputSnapshot(60 seconds);
        ICfdEngine.ProtocolAccountingSnapshot memory protocolSnapshot = engine.getProtocolAccountingSnapshot();
        uint256 vaultAssetsUsdc = vault.totalAssets();
        uint256 feesUsdc = engine.accumulatedFeesUsdc();

        assertEq(protocolSnapshot.vaultAssetsUsdc, vaultAssetsUsdc, "Protocol snapshot vault assets mismatch");
        assertEq(protocolSnapshot.accumulatedFeesUsdc, feesUsdc, "Protocol snapshot fees mismatch");
        assertEq(protocolSnapshot.accumulatedBadDebtUsdc, engine.accumulatedBadDebtUsdc(), "Protocol snapshot bad debt mismatch");
        assertEq(protocolSnapshot.withdrawalReservedUsdc, engine.getWithdrawalReservedUsdc(), "Protocol snapshot withdrawal reserve mismatch");
        assertEq(protocolSnapshot.freeUsdc, engine.getProtocolAccountingView().freeUsdc, "Protocol snapshot free USDC mismatch");
        assertEq(snapshot.protocolFeesUsdc, feesUsdc, "House-pool snapshot fees must match engine fees");
        assertEq(snapshot.deferredTraderPayoutUsdc, engine.totalDeferredPayoutUsdc(), "House-pool snapshot deferred trader payout mismatch");
        assertEq(
            snapshot.deferredClearerBountyUsdc,
            engine.totalDeferredClearerBountyUsdc(),
            "House-pool snapshot deferred clearer bounty mismatch"
        );
        assertEq(snapshot.maxLiabilityUsdc, engine.getMaxLiability(), "House-pool snapshot max liability mismatch");
        assertEq(
            snapshot.withdrawalFundingLiabilityUsdc,
            engine.getLiabilityOnlyFundingPnl(),
            "House-pool snapshot withdrawal funding liability mismatch"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc,
            vaultAssetsUsdc > feesUsdc ? vaultAssetsUsdc - feesUsdc : 0,
            "House-pool snapshot net physical assets must match vault assets net of fees"
        );
        assertEq(
            snapshot.netPhysicalAssetsUsdc + snapshot.protocolFeesUsdc,
            vaultAssetsUsdc > feesUsdc ? vaultAssetsUsdc : feesUsdc,
            "House-pool snapshot physical asset decomposition mismatch"
        );
        assertEq(protocolSnapshot.netPhysicalAssetsUsdc, snapshot.netPhysicalAssetsUsdc, "Protocol snapshot net assets mismatch");
        assertEq(protocolSnapshot.maxLiabilityUsdc, snapshot.maxLiabilityUsdc, "Protocol snapshot max liability mismatch");
        assertEq(
            protocolSnapshot.totalDeferredPayoutUsdc,
            snapshot.deferredTraderPayoutUsdc,
            "Protocol snapshot deferred trader payout mismatch"
        );
        assertEq(
            protocolSnapshot.totalDeferredClearerBountyUsdc,
            snapshot.deferredClearerBountyUsdc,
            "Protocol snapshot deferred clearer bounty mismatch"
        );
    }

    function invariant_HousePoolStatusSnapshotMatchesEngineState() public view {
        ICfdEngine.HousePoolStatusSnapshot memory snapshot = engine.getHousePoolStatusSnapshot();

        assertEq(snapshot.lastMarkTime, engine.lastMarkTime(), "House-pool status last mark time mismatch");
        assertEq(snapshot.oracleFrozen, engine.isOracleFrozen(), "House-pool status oracle frozen mismatch");
        assertEq(snapshot.degradedMode, engine.degradedMode(), "House-pool status degraded mode mismatch");
    }

    function invariant_BadDebtOnlyRemainsAfterTrackedAccountsExhaustReachableValue() public view {
        uint256 badDebtUsdc = engine.accumulatedBadDebtUsdc();
        if (badDebtUsdc == 0) {
            return;
        }

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated || badDebtUsdc <= snapshot.badDebtUsdc) {
                continue;
            }

            assertEq(handler.accountRouterEscrow(accountId), 0, "Bad debt cannot coexist with tracked router escrow");
            assertEq(clearinghouse.balanceUsdc(accountId), 0, "Bad debt cannot coexist with tracked clearinghouse balance");
            assertEq(engine.deferredPayoutUsdc(accountId), 0, "Bad debt cannot coexist with deferred trader payout claims");
        }
    }

    function invariant_GhostTrackedDeferredTraderPayoutsMatchEngine() public view {
        uint256 ghostTotalDeferredTraderPayouts;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostDeferredPayoutUsdc = handler.deferredTraderPayoutSnapshot(accountId);
            uint256 liveDeferredPayoutUsdc = engine.deferredPayoutUsdc(accountId);

            assertEq(
                ghostDeferredPayoutUsdc,
                liveDeferredPayoutUsdc,
                "Ghost tracked deferred trader payout must match engine storage"
            );
            ghostTotalDeferredTraderPayouts += ghostDeferredPayoutUsdc;
        }

        assertEq(
            handler.totalDeferredTraderPayoutSnapshot(),
            ghostTotalDeferredTraderPayouts,
            "Ghost deferred trader payout total must match tracked account sum"
        );
        assertEq(
            engine.totalDeferredPayoutUsdc(),
            ghostTotalDeferredTraderPayouts,
            "Engine deferred payout total must match tracked ghost sum"
        );
    }

    function _knownBalancesSum() internal view returns (uint256 totalBalances) {
        totalBalances += usdc.balanceOf(address(this));
        totalBalances += usdc.balanceOf(address(handler));
        totalBalances += usdc.balanceOf(address(engine));
        totalBalances += usdc.balanceOf(address(clearinghouse));
        totalBalances += usdc.balanceOf(address(router));
        totalBalances += usdc.balanceOf(address(vault));

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            totalBalances += usdc.balanceOf(handler.actorAt(i));
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }
}

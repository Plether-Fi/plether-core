// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";

contract PositionProtectionViewsStub is IPositionProtectionViews {

    mapping(address => uint64) internal activeProtectionIds;
    mapping(uint64 => PositionProtectionTypes.PositionProtectionView) internal protections;

    function positionProtectionBook() external view returns (address book) {
        return address(this);
    }

    function setActivePositionProtectionId(
        address account,
        uint64 protectionId
    ) external {
        activeProtectionIds[account] = protectionId;
    }

    function activePositionProtectionId(
        address account
    ) external view returns (uint64 protectionId) {
        return activeProtectionIds[account];
    }

    function setPositionProtection(
        PositionProtectionTypes.PositionProtectionView calldata protection
    ) external {
        protections[protection.protectionId] = protection;
    }

    function getPositionProtection(
        uint64 protectionId
    ) external view returns (PositionProtectionTypes.PositionProtectionView memory protection) {
        return protections[protectionId];
    }

}

contract PerpsPublicLensTest is BasePerpTest {

    uint64 internal constant SATURDAY_NOON = 1_710_021_600;
    address internal constant LENS_LP = address(0x1E45);

    function test_GetTraderAccount_UsesNetEquityAndEngineAwareWithdrawable() public {
        address trader = address(0xA11CE);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        vm.warp(block.timestamp + engine.engineMarkStalenessLimit() + 1);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertGt(clearinghouse.getFreeBuyingPowerUsdc(account), 0, "setup should leave free buying power");
        assertEq(
            viewData.equityUsdc,
            snapshot.netEquityUsdc > 0 ? uint256(snapshot.netEquityUsdc) : 0,
            "public equity should use floored net economic equity"
        );
        assertEq(
            viewData.withdrawableUsdc,
            engineAccountLens.getWithdrawableUsdc(account),
            "lens should use account-lens withdrawability"
        );
        assertEq(viewData.withdrawableUsdc, 0, "withdrawable should zero when engine withdraws are stale-blocked");
    }

    function test_GetTraderAccount_WithdrawableMatchesEngineAndActualWithdrawBound() public {
        address trader = address(0xBEEF);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(105_000_000, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertGt(withdrawableUsdc, 0, "setup should produce a positive withdrawable amount");
        assertEq(
            withdrawableUsdc,
            clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc,
            "A healthy isolated position should expose all free settlement"
        );
        assertEq(
            viewData.withdrawableUsdc, withdrawableUsdc, "lens should delegate withdrawability to the account lens"
        );

        vm.prank(trader);
        clearinghouse.withdraw(account, withdrawableUsdc);

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(account, 1);
    }

    function test_GetTraderAccount_FlatAccountUsesSettlementEquity() public {
        address trader = address(0xF1A7);
        address account = trader;

        _fundTrader(trader, 12_345e6);

        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertEq(viewData.equityUsdc, 12_345e6, "flat accounts should report settlement equity");
        assertEq(viewData.withdrawableUsdc, 12_345e6, "flat accounts should expose full engine withdrawability");
        assertFalse(viewData.hasOpenPosition, "flat account should not report an open position");
    }

    function test_GetPosition_PopulatesMaintenanceMargin() public {
        address trader = address(0xB0B);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.SHORT, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));

        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(account);
        assertEq(
            viewData.maintenanceMarginUsdc,
            _maintenanceMarginUsdc(viewData.size, engine.lastMarkPrice()),
            "position view should expose the live maintenance margin requirement"
        );
    }

    function test_GetPosition_MirrorsAccountLensPositionState() public {
        address trader = address(0xB0B3);
        address account = trader;

        _fundTrader(trader, 20_000e6);
        _open(account, CfdTypes.Side.SHORT, 80_000e18, 8000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(95_000_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 14 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.PositionView memory viewData = publicLens.getPosition(account);

        assertEq(viewData.exists, snapshot.hasPosition, "Public position existence should match account lens");
        assertEq(uint8(viewData.side), uint8(snapshot.side), "Public position side should match account lens");
        assertEq(viewData.size, snapshot.size, "Public position size should match account lens");
        assertEq(viewData.entryPrice, snapshot.entryPrice, "Public position entry price should match account lens");
        assertEq(viewData.marginUsdc, snapshot.margin, "Public position margin should match account lens");
        assertEq(
            viewData.unrealizedPnlUsdc,
            snapshot.unrealizedPnlUsdc,
            "Public unrealized pnl should match carry-aware account lens state"
        );
        assertEq(
            viewData.liquidatable,
            snapshot.liquidatable,
            "Public liquidatable flag should match carry-aware account lens state"
        );
    }

    function test_GetActivePositionProtection_ForwardsRouterRecord() public {
        address account = address(0xA11CE);
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory expected;
        expected.protectionId = 7;
        expected.parentOrderId = 3;
        expected.account = account;
        expected.side = CfdTypes.Side.SHORT;
        expected.size = 42_000e18;
        expected.takeProfitTriggerPrice = 120_000_000;
        expected.stopLossTriggerPrice = 80_000_000;
        expected.triggerBountyUsdc = 200_000;
        expected.executionBountyUsdc = 200_000;
        expected.armedAt = 1_720_000_000;
        expected.armedBlock = 12_345;
        expected.status = PositionProtectionTypes.PositionProtectionStatus.Armed;
        protectionViews.setPositionProtection(expected);
        protectionViews.setActivePositionProtectionId(account, expected.protectionId);

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getActivePositionProtection(account);

        assertEq(
            keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "active protection should pass through"
        );
    }

    function test_GetActivePositionProtection_ReturnsNoneWhenAccountHasNoProtection() public {
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getActivePositionProtection(address(0xB0B));

        assertEq(actual.protectionId, 0, "missing active protection should have no id");
        assertEq(
            uint8(actual.status),
            uint8(PositionProtectionTypes.PositionProtectionStatus.None),
            "missing active protection should report None"
        );
    }

    function test_GetPositionProtection_ForwardsTerminalHistoryById() public {
        address account = address(0xCAFE);
        PositionProtectionViewsStub protectionViews = new PositionProtectionViewsStub();
        PerpsPublicLens protectionLens =
            new PerpsPublicLens(address(engineAccountLens), address(engine), address(protectionViews), address(pool));

        PositionProtectionTypes.PositionProtectionView memory expected;
        expected.protectionId = 9;
        expected.linkedOrderId = 11;
        expected.account = account;
        expected.side = CfdTypes.Side.LONG;
        expected.size = 10_000e18;
        expected.takeProfitTriggerPrice = 90_000_000;
        expected.stopLossTriggerPrice = 110_000_000;
        expected.armedAt = 1_720_100_000;
        expected.armedBlock = 12_678;
        expected.triggerMarkPrice = 90_000_000;
        expected.triggerPublishTime = 1_720_100_015;
        expected.triggeredLeg = PositionProtectionTypes.PositionProtectionTriggerLeg.TakeProfit;
        expected.status = PositionProtectionTypes.PositionProtectionStatus.Executed;
        protectionViews.setPositionProtection(expected);

        PositionProtectionTypes.PositionProtectionView memory actual =
            protectionLens.getPositionProtection(expected.protectionId);

        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)), "terminal history should pass through");
    }

    function test_GetTraderAccount_UsesCarryAwareNetEquity() public {
        address trader = address(0xB0B1);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertLt(
            snapshot.netEquityUsdc,
            int256(snapshot.accountEquityUsdc),
            "Carry-aware lens equity should be below raw settlement equity"
        );
        assertEq(
            viewData.equityUsdc,
            snapshot.netEquityUsdc > 0 ? uint256(snapshot.netEquityUsdc) : 0,
            "Public equity should inherit floored carry-aware net equity"
        );
    }

    function test_GetTraderAccount_WithdrawableDropsToZeroAfterLargeLiveCarryAccrual() public {
        address trader = address(0xB0B4);
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.warp(block.timestamp + 30 * 365 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertEq(withdrawableUsdc, 0, "Account lens withdrawable should drop to zero after large live carry accrual");
        assertEq(viewData.withdrawableUsdc, withdrawableUsdc, "Public lens withdrawable should match the account lens");

        vm.prank(trader);
        vm.expectRevert();
        clearinghouse.withdraw(account, 1);
    }

    function test_GetTraderAccount_WithdrawableDecreasesUnderLiveCarryAccrual() public {
        address trader = address(0xB0B5);
        address account = trader;

        _fundTrader(trader, 5000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 1700e6, 1e8);

        uint256 withdrawableBeforeCarry = engineAccountLens.getWithdrawableUsdc(account);
        assertGt(withdrawableBeforeCarry, 0, "Setup should start with positive withdrawable headroom");

        vm.warp(block.timestamp + 5 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 withdrawableUsdc = engineAccountLens.getWithdrawableUsdc(account);
        PerpsViewTypes.TraderAccountView memory viewData = publicLens.getTraderAccount(account);

        assertLt(withdrawableUsdc, withdrawableBeforeCarry, "Live carry accrual should reduce withdrawable headroom");
        assertEq(viewData.withdrawableUsdc, withdrawableUsdc, "Public lens withdrawable should match the account lens");

        if (withdrawableUsdc > 0) {
            vm.prank(trader);
            clearinghouse.withdraw(account, withdrawableUsdc);

            vm.prank(trader);
            vm.expectRevert();
            clearinghouse.withdraw(account, 1);
        }
    }

    function test_IsLiquidatable_UsesCarryAwareLensState() public {
        address trader = address(0xB0B2);
        address account = trader;

        _fundTrader(trader, 1000e6);
        _open(account, CfdTypes.Side.LONG, 50_000e18, 900e6, 1e8);

        assertFalse(publicLens.isLiquidatable(account), "Setup should start above maintenance before carry accrues");

        vm.prank(address(router));
        engine.updateMarkPrice(100_500_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 2 * 365 days);

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot = engineAccountLens.getAccountLedgerSnapshot(account);
        assertTrue(
            snapshot.liquidatable, "Account lens should become liquidatable once carry erodes maintenance headroom"
        );
        assertTrue(publicLens.isLiquidatable(account), "Public lens should inherit carry-aware liquidatability");
    }

    function test_GetLpStatus_UsesActualFrozenWindowFreshness() public {
        address trader = address(0xCAFE);
        address account = trader;

        _fundTrader(trader, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_NOON - 4 days));

        PerpsViewTypes.LpStatusView memory viewData = publicLens.getLpStatus();
        assertFalse(pool.getPoolLiquidityView().markFresh, "setup should make the frozen mark stale");
        assertFalse(viewData.oracleFresh, "LP status should mirror the actual house-pool freshness policy");
    }

    function test_PublicLpViews_ExposeSettlementHoldWithoutDisablingDepositsOrTrading() public {
        PerpsViewTypes.TrancheView memory trancheBefore = publicLens.getJuniorTranche();
        PerpsViewTypes.LpStatusView memory lpStatusBefore = publicLens.getLpStatus();
        PerpsViewTypes.TrancheQueueView memory queueBefore = publicLens.getTrancheQueues(false);
        PerpsViewTypes.ProtocolStatusView memory protocolBefore = publicLens.getProtocolStatus();

        assertTrue(trancheBefore.depositEnabled, "setup should accept Junior deposit requests");
        assertTrue(trancheBefore.withdrawEnabled, "setup should permit redemption funding");
        assertTrue(lpStatusBefore.tradingActive, "setup should have active trading");
        assertTrue(lpStatusBefore.withdrawalLive, "setup should have live LP settlement");
        assertTrue(queueBefore.settlementLive, "setup queue settlement should be live");
        assertTrue(protocolBefore.withdrawalLive, "setup protocol withdrawal funding should be live");
        assertFalse(lpStatusBefore.lpEpochSettlementPaused);
        assertFalse(queueBefore.lpEpochSettlementPaused);
        assertFalse(protocolBefore.lpEpochSettlementPaused);

        pool.pauseLpEpochSettlement();

        PerpsViewTypes.TrancheView memory trancheHeld = publicLens.getJuniorTranche();
        PerpsViewTypes.LpStatusView memory lpStatusHeld = publicLens.getLpStatus();
        PerpsViewTypes.TrancheQueueView memory queueHeld = publicLens.getTrancheQueues(false);
        PerpsViewTypes.ProtocolStatusView memory protocolHeld = publicLens.getProtocolStatus();

        assertTrue(trancheHeld.depositEnabled, "settlement hold must not disable deposit requests");
        assertFalse(trancheHeld.withdrawEnabled, "settlement hold must disable new redemption funding");
        assertTrue(lpStatusHeld.tradingActive, "settlement hold must not disable trading");
        assertFalse(lpStatusHeld.withdrawalLive, "LP status must report settlement funding unavailable");
        assertFalse(queueHeld.settlementLive, "queue view must report settlement unavailable");
        assertFalse(queueHeld.poolPaused, "settlement hold must remain distinct from LP-entry pause");
        assertTrue(lpStatusHeld.lpEpochSettlementPaused);
        assertTrue(queueHeld.lpEpochSettlementPaused);
        assertTrue(protocolHeld.lpEpochSettlementPaused);
        assertTrue(protocolHeld.tradingActive, "protocol view must keep trading active");
        assertFalse(protocolHeld.withdrawalLive, "protocol view must report redemption funding unavailable");

        pool.unpauseLpEpochSettlement();

        assertFalse(publicLens.getLpStatus().lpEpochSettlementPaused, "release must clear LP status hold flag");
        assertFalse(
            publicLens.getTrancheQueues(false).lpEpochSettlementPaused, "release must clear tranche queue hold flag"
        );
        assertFalse(
            publicLens.getProtocolStatus().lpEpochSettlementPaused, "release must clear protocol status hold flag"
        );
        assertTrue(publicLens.getJuniorTranche().withdrawEnabled, "release must restore redemption funding liveness");
    }

    function test_GetSeniorTranche_ExposesFrozenLpFeeWhenOracleFrozen() public {
        _fundSenior(address(0xA11CE), 100_000e6);

        vm.warp(SATURDAY_NOON);
        assertTrue(engine.isOracleFrozen(), "setup should be inside a frozen-oracle window");

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(SATURDAY_NOON - 3 hours));

        PerpsViewTypes.TrancheView memory viewData = publicLens.getSeniorTranche();

        assertTrue(viewData.oracleFrozen, "Senior tranche view should expose the frozen-oracle flag");
        assertEq(viewData.frozenLpFeeBps, 25, "Senior tranche view should expose the active frozen LP fee");
    }

    function test_GetTranches_ExposeRawAndEffectiveSupplyAtDefaultZeroMaintenanceFee() public view {
        PerpsViewTypes.TrancheView memory senior = publicLens.getSeniorTranche();
        PerpsViewTypes.TrancheView memory junior = publicLens.getJuniorTranche();

        assertEq(senior.totalShares, seniorVault.totalSupply(), "Senior raw supply should match ERC20 supply");
        assertEq(
            senior.effectiveTotalShares,
            senior.totalShares,
            "Senior effective supply should always equal its raw supply"
        );
        assertEq(senior.pendingMaintenanceFeeShares, 0, "Senior should never report pending maintenance shares");
        assertEq(senior.maintenanceFeeAprBps, 0, "Senior should never report a maintenance fee rate");
        assertEq(senior.maintenanceFeeRecipient, address(0), "Senior should never report a maintenance recipient");
        assertEq(
            senior.sharePrice,
            (senior.totalAssetsUsdc * 1e18) / senior.effectiveTotalShares,
            "Senior price should use its effective supply"
        );

        assertEq(junior.totalShares, juniorVault.totalSupply(), "Junior raw supply should match ERC20 supply");
        assertEq(
            junior.effectiveTotalShares,
            junior.totalShares,
            "Default-zero Junior effective supply should equal raw supply"
        );
        assertEq(junior.pendingMaintenanceFeeShares, 0, "Default Junior fee should have no pending shares");
        assertEq(junior.maintenanceFeeAprBps, 0, "Default Junior fee rate should be zero");
        assertEq(junior.maintenanceFeeRecipient, address(0), "Default Junior fee recipient should be unset");
        assertEq(
            junior.sharePrice,
            (junior.totalAssetsUsdc * 1e18) / junior.effectiveTotalShares,
            "Default Junior price should use effective supply"
        );
    }

    function test_GetJuniorTranche_PricesAgainstEffectiveSupplyIncludingPendingMaintenanceFee() public {
        uint256 feeAprBps = 750;
        address feeRecipient = address(0xFEE);

        juniorVault.proposeMaintenanceFeeConfig(feeAprBps, feeRecipient);
        vm.warp(juniorVault.maintenanceFeeConfigActivationTime());
        juniorVault.finalizeMaintenanceFeeConfig();
        vm.warp(juniorVault.maintenanceFeeCheckpointBoundary() + 2 hours);

        uint256 rawSupply = juniorVault.totalSupply();
        uint256 pendingFeeShares = juniorVault.pendingMaintenanceFeeShares();
        uint256 effectiveSupply = juniorVault.accruedTotalSupply();
        assertGt(pendingFeeShares, 0, "Setup should produce uncheckpointed Junior fee shares");

        PerpsViewTypes.TrancheView memory viewData = publicLens.getJuniorTranche();

        assertEq(viewData.totalShares, rawSupply, "Lens must preserve raw ERC20 supply");
        assertEq(viewData.effectiveTotalShares, effectiveSupply, "Lens must expose fee-accrued supply");
        assertEq(viewData.pendingMaintenanceFeeShares, pendingFeeShares, "Lens must expose pending fee dilution");
        assertEq(viewData.maintenanceFeeAprBps, feeAprBps, "Lens must expose the active fee rate");
        assertEq(viewData.maintenanceFeeRecipient, feeRecipient, "Lens must expose the active fee recipient");
        assertEq(
            viewData.sharePrice,
            (viewData.totalAssetsUsdc * 1e18) / effectiveSupply,
            "Junior price must use effective rather than raw supply"
        );
        assertLt(
            viewData.sharePrice,
            (viewData.totalAssetsUsdc * 1e18) / rawSupply,
            "Pending dilution should reduce the reported Junior share price"
        );
    }

    function test_GetJuniorTranche_DoesNotChargeFrozenFeeDuringFadOnlyShoulder() public {
        uint256 sunday2110 = 1_710_105_000;
        vm.warp(sunday2110);

        assertTrue(engine.isFadWindow(), "setup should remain inside FAD");
        assertFalse(engine.isOracleFrozen(), "setup should be after the oracle-frozen window");

        PerpsViewTypes.TrancheView memory viewData = publicLens.getJuniorTranche();

        assertFalse(viewData.oracleFrozen, "Junior tranche view should report the live oracle state");
        assertEq(viewData.frozenLpFeeBps, 0, "FAD alone should not activate the frozen LP fee");
    }

    function test_GetTrancheQueuesAndLpRequestState_TracksPendingAndClaimableWork() public {
        uint256 depositAssets = 25_000e6;
        (uint256 requestId, uint256 redeemShares) = _createMatchedJuniorRequests(depositAssets);

        PerpsViewTypes.TrancheQueueView memory pendingQueue = publicLens.getTrancheQueues(false);
        assertEq(pendingQueue.vault, address(juniorVault));
        assertEq(pendingQueue.currentEpoch, pool.currentLpEpoch());
        assertEq(pendingQueue.cutoffEpoch, pendingQueue.currentEpoch);
        (uint256 nextRequestEpoch, uint256 nextRequestCutoffTime) = juniorVault.getRequestEpochWindow();
        assertEq(pendingQueue.nextRequestEpoch, nextRequestEpoch, "lens must use the vault's request epoch");
        assertEq(
            pendingQueue.nextRequestCutoffTime, nextRequestCutoffTime, "lens must use the vault's next request cutoff"
        );
        assertGt(pendingQueue.nextRequestEpoch, pendingQueue.currentEpoch, "request epoch must remain future");
        assertGt(pendingQueue.nextRequestCutoffTime, block.timestamp, "request cutoff must remain future");

        PerpsViewTypes.TrancheQueueView memory seniorQueue = publicLens.getTrancheQueues(true);
        assertEq(seniorQueue.nextRequestEpoch, pendingQueue.nextRequestEpoch, "tranche request epochs must match");
        assertEq(
            seniorQueue.nextRequestCutoffTime, pendingQueue.nextRequestCutoffTime, "tranche request cutoffs must match"
        );
        assertEq(pendingQueue.depositHeadEpoch, 0, "future deposits must not appear as matured work");
        assertEq(pendingQueue.depositHeadAssets, 0);
        assertEq(pendingQueue.redeemHeadEpoch, 0, "future redemptions must not appear as matured work");
        assertEq(pendingQueue.redeemHeadShares, 0);
        assertFalse(pendingQueue.depositBacklog);
        assertFalse(pendingQueue.redeemBacklog);
        assertTrue(pendingQueue.settlementLive);
        assertFalse(pendingQueue.poolPaused);

        PerpsViewTypes.LpRequestStateView memory pendingDeposit =
            publicLens.getLpRequestState(false, requestId, LENS_LP);
        assertEq(pendingDeposit.vault, address(juniorVault));
        assertEq(pendingDeposit.requestId, requestId);
        assertEq(pendingDeposit.controller, LENS_LP);
        assertEq(pendingDeposit.pendingDepositAssets, depositAssets);
        assertEq(
            pendingDeposit.pendingDepositSharesEstimate,
            juniorVault.estimateDepositShares(depositAssets),
            "lens must use the vault's live deposit estimate"
        );
        assertEq(pendingDeposit.claimableDepositAssets, 0);
        assertEq(pendingDeposit.claimableDepositShares, 0);
        assertEq(pendingDeposit.refundableDepositAssets, 0);

        PerpsViewTypes.LpRequestStateView memory pendingRedeem =
            publicLens.getLpRequestState(false, requestId, address(this));
        assertEq(pendingRedeem.pendingRedeemShares, redeemShares);
        assertEq(
            pendingRedeem.pendingRedeemAssetsEstimate,
            juniorVault.estimateRedeemAssets(redeemShares),
            "lens must use the vault's live redeem estimate"
        );
        assertEq(pendingRedeem.claimableRedeemShares, 0);
        assertEq(pendingRedeem.claimableRedeemAssets, 0);
        assertEq(pendingRedeem.refundableRedeemShares, 0);
        assertFalse(pendingRedeem.redeemRefundPending);

        _warpToLpEpoch(requestId);
        _refreshPoolMark();

        PerpsViewTypes.TrancheQueueView memory maturedQueue = publicLens.getTrancheQueues(false);
        assertEq(maturedQueue.depositHeadEpoch, requestId);
        assertEq(maturedQueue.depositHeadAssets, depositAssets);
        assertEq(maturedQueue.redeemHeadEpoch, requestId);
        assertEq(maturedQueue.redeemHeadShares, redeemShares);
        assertTrue(maturedQueue.depositBacklog);
        assertTrue(maturedQueue.redeemBacklog);

        _settleLpEpochForTest();

        PerpsViewTypes.TrancheQueueView memory settledQueue = publicLens.getTrancheQueues(false);
        assertEq(settledQueue.depositHeadEpoch, 0);
        assertEq(settledQueue.depositHeadAssets, 0);
        assertEq(settledQueue.redeemHeadEpoch, 0);
        assertEq(settledQueue.redeemHeadShares, 0);
        assertFalse(settledQueue.depositBacklog);
        assertFalse(settledQueue.redeemBacklog);

        PerpsViewTypes.LpRequestStateView memory claimableDeposit =
            publicLens.getLpRequestState(false, requestId, LENS_LP);
        assertEq(claimableDeposit.pendingDepositAssets, 0);
        assertEq(claimableDeposit.pendingDepositSharesEstimate, 0);
        assertEq(claimableDeposit.claimableDepositAssets, depositAssets);
        assertGt(claimableDeposit.claimableDepositShares, 0);
        assertEq(claimableDeposit.refundableDepositAssets, 0);

        PerpsViewTypes.LpRequestStateView memory claimableRedeem =
            publicLens.getLpRequestState(false, requestId, address(this));
        assertEq(claimableRedeem.pendingRedeemShares, 0);
        assertEq(claimableRedeem.pendingRedeemAssetsEstimate, 0);
        assertEq(claimableRedeem.claimableRedeemShares, redeemShares);
        assertGt(claimableRedeem.claimableRedeemAssets, 0);
        assertEq(claimableRedeem.refundableRedeemShares, 0);
        assertFalse(claimableRedeem.redeemRefundPending);
    }

    function test_GetTrancheQueuesAndLpRequestState_TracksRefundableWork() public {
        uint256 depositAssets = 25_000e6;
        (uint256 requestId, uint256 redeemShares) = _createMatchedJuniorRequests(depositAssets);
        _warpToLpEpoch(requestId);

        vm.prank(address(pool));
        assertEq(juniorVault.finalizeDepositEpochFromPool(requestId, 0), depositAssets);
        vm.prank(address(pool));
        assertEq(juniorVault.refundRedeemEpochRemainder(requestId, redeemShares), redeemShares);

        PerpsViewTypes.TrancheQueueView memory queue = publicLens.getTrancheQueues(false);
        assertEq(queue.depositHeadEpoch, 0, "rejected deposits must leave the settlement queue");
        assertEq(queue.depositHeadAssets, 0);
        assertEq(queue.redeemHeadEpoch, 0, "refundable redemptions must leave the settlement queue");
        assertEq(queue.redeemHeadShares, 0);
        assertFalse(queue.depositBacklog);
        assertFalse(queue.redeemBacklog);

        PerpsViewTypes.LpRequestStateView memory refundableDeposit =
            publicLens.getLpRequestState(false, requestId, LENS_LP);
        assertEq(refundableDeposit.pendingDepositAssets, 0);
        assertEq(refundableDeposit.pendingDepositSharesEstimate, 0);
        assertEq(refundableDeposit.claimableDepositAssets, 0);
        assertEq(refundableDeposit.claimableDepositShares, 0);
        assertEq(refundableDeposit.refundableDepositAssets, depositAssets);

        PerpsViewTypes.LpRequestStateView memory refundableRedeem =
            publicLens.getLpRequestState(false, requestId, address(this));
        assertEq(refundableRedeem.pendingRedeemShares, 0);
        assertEq(refundableRedeem.pendingRedeemAssetsEstimate, 0);
        assertEq(refundableRedeem.claimableRedeemShares, 0);
        assertEq(refundableRedeem.claimableRedeemAssets, 0);
        assertEq(refundableRedeem.refundableRedeemShares, redeemShares);
        assertTrue(refundableRedeem.redeemRefundPending);
    }

    function _createMatchedJuniorRequests(
        uint256 depositAssets
    ) internal returns (uint256 requestId, uint256 redeemShares) {
        uint256 cooldownEnd = juniorVault.lastDepositTime(address(this)) + juniorVault.DEPOSIT_COOLDOWN();
        if (block.timestamp < cooldownEnd) {
            vm.warp(cooldownEnd);
        }

        usdc.mint(LENS_LP, depositAssets);
        vm.startPrank(LENS_LP);
        usdc.approve(address(juniorVault), depositAssets);
        requestId = IAsyncTrancheVault(address(juniorVault)).requestDeposit(depositAssets, LENS_LP, LENS_LP);
        vm.stopPrank();

        redeemShares = juniorVault.balanceOf(address(this)) / 10;
        assertGt(redeemShares, 0, "base fixture must provide redeemable Junior shares");
        vm.prank(address(this));
        uint256 redeemRequestId =
            IAsyncTrancheVault(address(juniorVault)).requestRedeem(redeemShares, address(this), address(this));
        assertEq(redeemRequestId, requestId, "deposit and redeem must use the same request window");
    }

    function _warpToLpEpoch(
        uint256 epochId
    ) internal {
        uint256 epochStart = pool.lpEpochStart(epochId);
        if (block.timestamp < epochStart) {
            vm.warp(epochStart);
        }
    }

    function _refreshPoolMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

}

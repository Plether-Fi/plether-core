// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.39;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";

import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

contract OrderRouterLiquidationReservationTest is BasePerpTest {

    address trader = address(0xC10A);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 9,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_ExecuteLiquidation_CreditsImmediateKeeperBountyToClearinghouse() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        uint256 keeperSettlementBefore = clearinghouse.balanceAssets(address(this));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, address(this));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);

        assertEq(
            clearinghouse.balanceAssets(address(this)) - keeperSettlementBefore,
            preview.keeperBountyAssets,
            "Immediate liquidation bounty should credit the keeper clearinghouse balance"
        );
    }

    function test_ExecuteLiquidation_CreditsKeeperBountyEvenWhenPoolPayoutFails() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 900e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);
        LiquidationParitySnapshot memory beforeSnapshot = _captureLiquidationParitySnapshot(account, address(this));

        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(pool.payOut.selector, address(clearinghouse), preview.keeperBountyAssets),
            abi.encodeWithSignature("Error(string)", "pool illiquid")
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        LiquidationParityObserved memory observed = _observeLiquidationParity(account, address(this), beforeSnapshot);
        _assertLiquidationPreviewMatchesObserved(preview, observed, beforeSnapshot.protocol.degradedMode);
        assertEq(
            observed.keeperSettlementAssets,
            preview.keeperBountyAssets,
            "Keeper bounty should settle directly inside the clearinghouse"
        );
    }

    function test_ExecuteLiquidation_RetainsOpenBountiesAndReservations() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 1500e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        clearinghouse.withdraw(account, 70e6);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 200e6, CAP_PRICE, false);
        }
        vm.stopPrank();

        assertEq(
            settlementToken.balanceOf(address(router)), 0, "Router should not custody open-order bounty reservation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets,
            _executionBountyReserve(1) * queuedOrderCount,
            "Clearinghouse should reserve the shielded open-order bounty reservation"
        );
        assertEq(
            router.pendingOrderCounts(account),
            queuedOrderCount,
            "Queued open orders should remain pending before liquidation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 150_000_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still clear the underwater position");
        assertEq(
            router.getAccountReservations(account).executionBountyAssets,
            _executionBountyReserve(1) * queuedOrderCount,
            "Opening bounties remain funded after liquidation"
        );
        assertEq(router.pendingOrderCounts(account), queuedOrderCount, "Opening orders remain queued");
        assertEq(
            preview.reachableCollateralAssets,
            snapshotBefore.activePositionMarginAssets + snapshotBefore.traderClaimBalanceAssets,
            "Price-loss reachability should include only PnL pledge and same-account claims"
        );
        assertGt(
            snapshotBefore.liquidationReachableSettlementAssets,
            preview.reachableCollateralAssets,
            "Setup should retain non-price-risk settlement outside liquidation reachability"
        );
        assertEq(router.nextExecuteId(), 1, "Liquidation keeps the first opening order at the global queue head");
        assertEq(
            clearinghouse.balanceAssets(account),
            snapshotBefore.settlementBalanceAssets - preview.seizedCollateralAssets - preview.keeperBountyAssets
                - preview.protocolLiquidationFeeAssets,
            "Surviving opening bounties remain in trader custody"
        );
    }

    function test_ExecuteLiquidation_RetainedReservationDoesNotChangePoolDepth() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 1500e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        clearinghouse.withdraw(account, 70e6);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 200e6, CAP_PRICE, false);
        }
        vm.stopPrank();

        ICfdEngineAdminHost.EngineFreshnessConfig memory freshnessConfig = _engineFreshnessConfig();
        freshnessConfig.engineMarkStalenessLimit = 90 days;
        engineAdmin.proposeFreshnessConfig(freshnessConfig);
        vm.warp(engineAdmin.freshnessConfigActivationTime() + 1);
        engineAdmin.finalizeFreshnessConfig();

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        settlementToken.transfer(address(0xDEAD), poolAssets - 25e6);

        vm.warp(block.timestamp + 60 days);
        while (engine.isOracleFrozen()) {
            vm.warp(block.timestamp + 1 days);
        }
        uint256 canonicalDepthBefore = pool.totalAssets();

        ICfdEngineTypes.LiquidationPreview memory expectedPreview =
            engineLens.simulateLiquidation(account, 195_000_000, canonicalDepthBefore);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(195_000_000));

        uint256 keeperBefore = clearinghouse.balanceAssets(address(this));
        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(
            clearinghouse.balanceAssets(address(this)) - keeperBefore,
            expectedPreview.keeperBountyAssets,
            "Liquidation bounty should use clearinghouse reachability with retained open reservations"
        );
    }

    function test_ExecuteLiquidation_ForfeitsReservedCloseBountiesBeforeClearingOrders() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 350e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        clearinghouse.withdraw(account, 68e6);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, 0, true);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, 0, true);
        vm.stopPrank();

        assertEq(
            settlementToken.balanceOf(address(router)),
            0,
            "Router should not custody prefunded close-order bounty reservation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementAssets,
            0,
            "Clearinghouse should reserve prefunded close-order bounty reservation"
        );

        AccountLensViewTypes.AccountLedgerSnapshot memory snapshotBefore =
            engineAccountLens.getAccountLedgerSnapshot(account);
        uint256 poolAssetsBefore = pool.totalAssets();
        uint256 treasuryBefore = clearinghouse.balanceAssets(engine.protocolTreasury());

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(102_500_000));

        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(snapshotBefore.executionBountyReserveAssets, 0, "Unpaid close orders do not reserve settlement");
        assertEq(router.pendingOrderCounts(account), 0, "Liquidation should clear queued close orders");
        assertEq(_executionBountyReserve(1), 0, "Liquidation should forfeit the first close-order bounty reservation");
        assertEq(_executionBountyReserve(2), 0, "Liquidation should forfeit the second close-order bounty reservation");
        assertEq(
            settlementToken.balanceOf(address(router)),
            0,
            "Router should not retain close-order bounty reservation after liquidation"
        );
        assertEq(
            pool.excessAssets(), 0, "Forfeited close-order bounty reservation should not remain quarantined as excess"
        );
        assertEq(
            clearinghouse.balanceAssets(engine.protocolTreasury()) - treasuryBefore,
            0,
            "Forfeited close-order bounty reservation should transfer into treasury margin"
        );
        assertGe(
            pool.totalAssets(),
            poolAssetsBefore,
            "Liquidation settlement should not quarantine forfeited bounty as pool excess"
        );
    }

    function test_ExecuteLiquidation_PreservesQueuedOpenRecords() public {
        _startRecordingLogs();
        address account = trader;
        _fundTrader(trader, 1500e6);

        _open(account, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        clearinghouse.withdraw(account, 70e6);
        uint256 queuedOrderCount = 5;
        for (uint256 i = 0; i < queuedOrderCount; i++) {
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 200e6, CAP_PRICE, false);
        }
        vm.stopPrank();

        uint256 traderAssetsBefore = settlementToken.balanceOf(trader);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(account, priceData);

        assertEq(router.nextExecuteId(), 1, "Liquidation should leave the first opening order at the queue head");
        assertEq(router.pendingOrderCounts(account), queuedOrderCount, "All opening records remain pending");
        assertEq(
            router.getAccountReservations(account).executionBountyAssets,
            _executionBountyReserve(1) * queuedOrderCount,
            "All opening bounties remain reserved"
        );

        assertEq(
            settlementToken.balanceOf(trader),
            traderAssetsBefore,
            "Liquidation does not move trader funds directly to the wallet"
        );
        assertEq(
            settlementToken.balanceOf(address(router)), 0, "Router does not hold the retained clearinghouse reservation"
        );
    }

    function test_ExecuteLiquidation_KeepsBothAccountsPendingOpensInFifoOrder() public {
        _startRecordingLogs();
        address traderAccount = trader;
        address otherTrader = address(0xC10B);
        address otherAccount = otherTrader;

        _fundTrader(trader, 900e6);
        _fundTrader(otherTrader, 2000e6);

        _open(traderAccount, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        clearinghouse.withdraw(traderAccount, 70e6);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 200e6, CAP_PRICE, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 200e6, CAP_PRICE, false);
        vm.stopPrank();

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, CAP_PRICE, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, CAP_PRICE, false);
        vm.stopPrank();

        assertEq(router.pendingOrderCounts(traderAccount), 2, "Liquidated account should start with two queued orders");
        assertEq(
            router.pendingOrderCounts(otherAccount), 2, "Unrelated account should start with its own queued orders"
        );

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(traderAccount, priceData);

        assertEq(
            router.pendingOrderCounts(traderAccount), 2, "Liquidation should retain the liquidated account's opens"
        );
        assertEq(router.pendingOrderCounts(otherAccount), 2, "Unrelated account queue should remain intact");

        IOrderRouterAccounting.PendingOrderView[] memory traderPending = _pendingOrders(traderAccount);
        assertEq(traderPending[0].orderId, 1, "Liquidated account keeps its first order id");
        assertEq(traderPending[1].orderId, 2, "Liquidated account keeps its second order id");
        assertEq(router.nextExecuteId(), 1, "Global FIFO head remains the first opening order");

        IOrderRouterAccounting.PendingOrderView[] memory otherPending = _pendingOrders(otherAccount);
        assertEq(otherPending.length, 2, "Per-account traversal should still expose unrelated pending orders");
        assertEq(otherPending[0].orderId, 3, "Unrelated account should retain FIFO order ids after cleanup");
        assertEq(otherPending[1].orderId, 4, "Unrelated account queue should preserve its tail order");
    }

    function test_ExecuteLiquidation_ClearsCloseButKeepsOpeningOrder() public {
        _fundTrader(trader, 900e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        vm.startPrank(trader);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, 0, true);
        uint64 openId = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 150_000_000, false);
        vm.stopPrank();

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(150_000_000));
        _ensureLaterOracleTime();
        router.executeLiquidation(trader, priceData);

        assertEq(
            uint8(router.lifecycleBook().terminalOutcome(closeId).reason),
            uint8(OrderV3Types.TerminalReason.AccountLiquidated),
            "Stale close gets a liquidation receipt"
        );
        assertEq(router.pendingOrderCounts(trader), 1, "Opening order remains pending");
        assertEq(router.nextExecuteId(), openId, "Global queue advances only past the stale close");
        router.lifecycleBook().validateBountyFunding(openId);

        OrderV3Types.ExecutionResult memory result = router.executeOrder(openId, _mockPythUpdateData(150_000_000));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 reopenedSize,,,,,,) = engine.positions(trader);
        assertEq(reopenedSize, 10_000e18, "Retained independent open can execute after liquidation");
    }

    function test_OpeningEquityFloorCannotUseLiquidatablePositionPledgeAtCommit() public {
        _fundTrader(trader, 900e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        OrderV3Types.OrderRequest memory request = _fundedOpenRequest();
        request.clientOrderId = keccak256("independent-open-equity");
        request.bounds.minPostPositionEquityAssets = 200e6;
        // $200 own margin minus $4 execution fee and $9 liquidation reserve.
        uint256 ownEquityAssets = 187e6;
        assertLt(ownEquityAssets, request.bounds.minPostPositionEquityAssets);

        uint64 nextId = router.nextCommitId();
        vm.expectPartialRevert(ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector);
        vm.prank(trader);
        router.commitOrder(request);
        assertEq(router.nextCommitId(), nextId, "Rejected order never enters the queue");
        assertEq(router.pendingOrderCounts(trader), 0);
        assertEq(router.getAccountReservations(trader).committedMarginAssets, 0);

        request.bounds.minPostPositionEquityAssets = ownEquityAssets;
        vm.prank(trader);
        uint64 orderId = router.commitOrder(request);
        policyEvaluator.assessCommittedOrder(address(engine), orderId, address(this), 1e8);
    }

    function test_SmallIncreaseCannotBorrowExistingLiquidationReserveAtCommit() public {
        _fundTrader(trader, 900e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);

        uint64 nextId = router.nextCommitId();
        vm.expectRevert(abi.encodeWithSignature("OrderRouter__PredictableOpenInvalid(uint8)", uint8(6)));
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 500e18, 700_000, CAP_PRICE, false);
        assertEq(router.nextCommitId(), nextId);
        assertEq(router.pendingOrderCounts(trader), 0);

        vm.prank(trader);
        uint64 fundedOrder = router.commitOrder(CfdTypes.Side.LONG, 500e18, 10e6, CAP_PRICE, false);
        policyEvaluator.assessCommittedOrder(address(engine), fundedOrder, address(this), 1e8);
    }

    function test_QueuedOpposingCloseStillChecksOpenFundingAndAllowsFundedReplacement() public {
        _fundTrader(trader, 900e6);
        _open(trader, CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8);
        vm.prank(trader);
        uint64 closeId = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, type(uint256).max, true);

        OrderV3Types.OrderRequest memory request = _fundedOpenRequest();
        request.clientOrderId = keccak256("close-then-independent-open");
        request.side = CfdTypes.Side.SHORT;
        request.targetPrice = type(uint256).max;
        ICfdEngineTypes.OpenPreview memory preview =
            engineLens.previewOpen(trader, request.side, request.sizeDelta, request.marginDelta, 1e8);
        assertEq(uint8(preview.invalidReason), uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING));

        uint64 nextId = router.nextCommitId();
        request.bounds.minPostPositionEquityAssets = 188e6; // Own equity is $187 after fee and reserve.
        vm.expectPartialRevert(ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector);
        vm.prank(trader);
        router.commitOrder(request);

        request.bounds.minPostPositionEquityAssets = 187e6;
        request.bounds.maxPostLeverageBps = 1;
        vm.expectPartialRevert(ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector);
        vm.prank(trader);
        router.commitOrder(request);
        assertEq(router.nextCommitId(), nextId, "Rejected replacements never enter the queue");
        assertEq(router.pendingOrderCounts(trader), 1, "Only the close remains pending");
        assertEq(router.getAccountReservations(trader).committedMarginAssets, 0);

        request.bounds.maxPostLeverageBps = type(uint32).max;
        vm.prank(trader);
        uint64 openId = router.commitOrder(request);
        _ensureLaterOracleTime();
        router.executeOrder(closeId, _mockPythUpdateData(1e8));
        OrderV3Types.ExecutionResult memory result = router.executeOrder(openId, _mockPythUpdateData(1e8));
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(trader);
        assertEq(size, 10_000e18);
        assertEq(uint8(side), uint8(CfdTypes.Side.SHORT));
    }

    function _fundedOpenRequest() private view returns (OrderV3Types.OrderRequest memory request) {
        request.side = CfdTypes.Side.LONG;
        request.sizeDelta = 10_000e18;
        request.marginDelta = 200e6;
        request.targetPrice = 1;
        request.bounds = OrderV3Types.ExecutionBounds({
            submitBy: uint64(block.timestamp + router.maxExecutionWindowSeconds()),
            executionWindowSeconds: uint32(router.maxExecutionWindowSeconds()),
            allowedExecutionModes: 7,
            expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
            maxExecutionBountyAssets: type(uint256).max,
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceAssets: 0,
            minPostPositionEquityAssets: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function test_CommitClose_UsesOnlyAccountLocalQueuedPositionProjection() public {
        _startRecordingLogs();
        address traderAccount = trader;
        address otherTrader = address(0xC10C);

        _fundTrader(trader, 2000e6);
        _fundTrader(otherTrader, 2000e6);
        _open(traderAccount, CfdTypes.Side.LONG, 20_000e18, 500e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 5000e18, 0, type(uint256).max, true);

        vm.startPrank(otherTrader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, CAP_PRICE, false);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, CAP_PRICE, false);
        vm.stopPrank();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 15_000e18, 0, type(uint256).max, true);

        IOrderRouterAccounting.PendingOrderView[] memory traderPending = _pendingOrders(traderAccount);
        assertEq(traderPending.length, 2, "Trader should be able to queue closes using only its own pending orders");
        assertEq(traderPending[0].sizeDelta, 5000e18, "First close should remain queued");
        assertEq(traderPending[1].sizeDelta, 15_000e18, "Second close should consume only the trader's residual size");
    }

}

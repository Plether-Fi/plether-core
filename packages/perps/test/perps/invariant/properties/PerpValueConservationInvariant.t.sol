// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {PositionRiskAccountingLib} from "@plether/perps/libraries/PositionRiskAccountingLib.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";

contract PerpValueConservationHandler is RecordedOrderReceipts {

    error UnexpectedCloseResult(OrderV3Types.ExecutionResult result);

    MockSettlementToken internal immutable settlementToken;
    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    OrderRouter internal immutable router;
    HousePool internal immutable pool;
    TrancheVault internal immutable juniorVault;
    MockPyth internal immutable mockPyth;

    bytes32 internal constant BASE_PYTH_FEED_A = bytes32(uint256(1));
    bytes32 internal constant BASE_PYTH_FEED_B = bytes32(uint256(2));

    address internal constant FULL_CLOSE_TRADER = address(0xA11CE01);
    address internal constant FULL_CLOSE_COUNTERPARTY = address(0xB0B01);
    address internal constant FAILED_CLOSE_KEEPER = address(0xC0FFEE01);
    address internal constant LONG_TRADER = address(0xB01102);
    address internal constant SHORT_TRADER = address(0xBEA202);
    address internal constant JUNIOR_ATTACKER = address(0xBAD02);
    address internal constant CARRY_TRADER = address(0xCA2203);

    bool public failedCloseExtractedMargin;
    bool public neutralMtmCreatedLpProfit;
    bool public checkpointForgaveHistoricalCarry;
    bool public pendingRevenueDisappeared;

    uint256 public failedCloseKeeperGainAssets;
    uint256 public neutralMtmLpProfitAssets;
    uint256 public forgivenCarryAssets;
    uint256 public disappearedRevenueAssets;
    uint256 public successfulCloseExecutions;
    uint256 public slippageCloseRejections;
    uint256 public completedNeutralRounds;
    uint256 public completedCarryCheckpoints;
    uint256 public completedRecapReconciliations;

    constructor(
        MockSettlementToken settlementToken_,
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        OrderRouter router_,
        HousePool pool_,
        TrancheVault juniorVault_,
        MockPyth mockPyth_
    ) {
        settlementToken = settlementToken_;
        engine = engine_;
        clearinghouse = clearinghouse_;
        router = router_;
        pool = pool_;
        juniorVault = juniorVault_;
        mockPyth = mockPyth_;
    }

    function failedFullCloseCannotExtractMargin(
        uint256 executionPriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 keeperGain;

        _fundTrader(FULL_CLOSE_TRADER, 5000e6);
        _fundTrader(FULL_CLOSE_COUNTERPARTY, 50_000e6);
        _open(FULL_CLOSE_TRADER, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(FULL_CLOSE_COUNTERPARTY, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        uint256 executionPrice = bound(executionPriceFuzz, 1.8e8, 1.99e8);
        vm.warp(uint256(engine.lastMarkTime()) + 1);
        vm.prank(address(router));
        engine.updateMarkPrice(executionPrice, uint64(vm.getBlockTimestamp()));

        uint256 keeperSettlementBefore = clearinghouse.balanceAssets(FAILED_CLOSE_KEEPER);
        bool expectSlippage = executionPriceFuzz % 2 == 0;
        // The two equal basket weights independently floor each half of an odd mock price.
        uint256 targetPrice = (executionPrice / 2) * 2 - (expectSlippage ? 1 : 0);

        assertEq(
            clearinghouse.getFreeBuyingPowerAssets(FULL_CLOSE_TRADER), 0, "fixture leaves no free settlement for close"
        );
        vm.prank(FULL_CLOSE_TRADER);
        uint64 orderId = LegacyOrderRouterHarness(payable(address(router)))
            .commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, targetPrice, true);
        (, uint256 marginAfterCommit,,,,,) = engine.positions(FULL_CLOSE_TRADER);
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, orderId);
        bytes[] memory priceData = _mockPythUpdateData(executionPrice);
        _startRecordingLogs();
        vm.prank(FAILED_CLOSE_KEEPER);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, priceData);
        if (
            result.orderId != orderId || result.pendingReason != OrderV3Types.PendingReason.None
                || result.status
                    != (expectSlippage ? OrderV3Types.LifecycleStatus.Failed : OrderV3Types.LifecycleStatus.Executed)
                || result.terminalReason
                    != (expectSlippage ? OrderV3Types.TerminalReason.Slippage : OrderV3Types.TerminalReason.Executed)
                || result.receiptHash == bytes32(0)
        ) {
            revert UnexpectedCloseResult(result);
        }
        keeperGain = clearinghouse.balanceAssets(FAILED_CLOSE_KEEPER) - keeperSettlementBefore;
        violation = _closeBountyViolation(orderId, reservation, marginAfterCommit, expectSlippage, keeperGain);

        vm.revertToState(snapshot);
        if (expectSlippage) {
            ++slippageCloseRejections;
        } else {
            ++successfulCloseExecutions;
        }
        if (violation) {
            failedCloseExtractedMargin = true;
            failedCloseKeeperGainAssets = keeperGain;
        }
    }

    function _closeBountyViolation(
        uint64 orderId,
        IMarginClearinghouse.BountyReservation memory reservation,
        uint256 marginAfterCommit,
        bool failed,
        uint256 keeperGain
    ) internal returns (bool) {
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(FULL_CLOSE_TRADER);
        OrderV3Types.OrderReceipt memory receipt = _verifiedReceipt(router.lifecycleBook(), orderId);
        uint256 expectedPaid = failed ? 0 : reservation.amountAssets;
        uint256 expectedRefunded = failed ? reservation.amountAssets : 0;
        OrderV3Types.BountyDisposition expectedDisposition = OrderV3Types.BountyDisposition.None;
        // This fixture leaves no free collateral and the close bounty is zero. A failed close must
        // preserve the pledge; a successful close cannot pay an execution bounty to the keeper.
        return reservation.account != FULL_CLOSE_TRADER
            || reservation.state != IMarginClearinghouse.BountyReservationState.Active
            || reservation.freeFundedAssets != 0 || reservation.amountAssets != 0 || keeperGain != expectedPaid
            || receipt.bountyDisposition != expectedDisposition || receipt.bounty.bountyPaidAssets != expectedPaid
            || receipt.bounty.bountyRefundedAssets != expectedRefunded || receipt.bounty.bountyForfeitedAssets != 0
            || receipt.bountyRecipient != address(0)
            || (failed
                    ? sizeAfter != 100_000e18 || marginAfter != marginAfterCommit + reservation.amountAssets
                    : sizeAfter != 0);
    }

    function neutralMtmCannotCreateLpDepositWithdrawProfit(
        uint256 sizeFuzz,
        uint256 depositFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 profit;

        uint256 size = bound(sizeFuzz, 500, 3000) * CfdTypes.SIZE_QUANTUM;
        uint256 depositAssets = bound(depositFuzz, 10_000e6, 300_000e6);

        (violation, profit) = _runNeutralMtmAttack(size, depositAssets);

        vm.revertToState(snapshot);
        ++completedNeutralRounds;
        if (violation) {
            neutralMtmCreatedLpProfit = true;
            neutralMtmLpProfitAssets = profit;
        }
    }

    function _runNeutralMtmAttack(
        uint256 size,
        uint256 depositAssets
    ) private returns (bool violation, uint256 profit) {
        _fundTrader(LONG_TRADER, 50_000e6);
        _fundTrader(SHORT_TRADER, 50_000e6);
        _open(LONG_TRADER, CfdTypes.Side.LONG, size, 10_000e6, 1e8);
        _open(SHORT_TRADER, CfdTypes.Side.SHORT, size, 10_000e6, 1e8);

        assertEq(_unrealizedTraderPnl(), 0, "paired fixture must start with neutral price PnL");

        uint256 shares = _depositJuniorForNeutralMtm(depositAssets);
        uint256 contemporaneousPoolInflow = _closeNeutralPairAndMeasureInflow(size);
        uint256 finalBalance = _redeemNeutralJuniorShares(shares);

        // Neutral positions may still pay ordinary close/carry revenue into the pool while the async
        // request matures. That revenue is legitimate LP yield; only extraction beyond the attacker's
        // contribution plus all contemporaneous pool inflow can have come from legacy claimant capital.
        uint256 maximumConservedBalance = depositAssets + contemporaneousPoolInflow;
        violation = finalBalance > maximumConservedBalance;
        profit = violation ? finalBalance - maximumConservedBalance : 0;
    }

    function _depositJuniorForNeutralMtm(
        uint256 depositAssets
    ) private returns (uint256 shares) {
        settlementToken.mint(JUNIOR_ATTACKER, depositAssets);
        vm.startPrank(JUNIOR_ATTACKER);
        settlementToken.approve(address(juniorVault), depositAssets);
        uint256 depositRequestId = juniorVault.requestDeposit(depositAssets, JUNIOR_ATTACKER, JUNIOR_ATTACKER);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(depositRequestId));
        uint256 depositMarkPrice = engine.lastMarkPrice();
        router.settleLpEpoch(_mockPythUpdateData(depositMarkPrice == 0 ? 1e8 : depositMarkPrice));

        uint256 claimableDepositAssets = juniorVault.claimableDepositRequest(depositRequestId, JUNIOR_ATTACKER);
        vm.prank(JUNIOR_ATTACKER);
        return juniorVault.claimDeposit(depositRequestId, claimableDepositAssets, JUNIOR_ATTACKER, JUNIOR_ATTACKER);
    }

    function _closeNeutralPairAndMeasureInflow(
        uint256 size
    ) private returns (uint256 contemporaneousPoolInflow) {
        uint256 poolAssetsBeforeCloses = pool.totalAssets();
        _close(LONG_TRADER, CfdTypes.Side.LONG, size, 1e8);
        _close(SHORT_TRADER, CfdTypes.Side.SHORT, size, 1e8);
        uint256 poolAssetsAfterCloses = pool.totalAssets();
        return poolAssetsAfterCloses > poolAssetsBeforeCloses ? poolAssetsAfterCloses - poolAssetsBeforeCloses : 0;
    }

    function _redeemNeutralJuniorShares(
        uint256 shares
    ) private returns (uint256 finalBalance) {
        uint256 cooldownEnd = juniorVault.lastDepositTime(JUNIOR_ATTACKER) + juniorVault.DEPOSIT_COOLDOWN();
        if (block.timestamp < cooldownEnd) {
            vm.warp(cooldownEnd);
        }
        vm.prank(JUNIOR_ATTACKER);
        uint256 redeemRequestId = juniorVault.requestRedeem(shares, JUNIOR_ATTACKER, JUNIOR_ATTACKER);

        vm.warp(juniorVault.depositEpochStart(redeemRequestId));
        uint256 redeemMarkPrice = engine.lastMarkPrice();
        router.settleLpEpoch(_mockPythUpdateData(redeemMarkPrice == 0 ? 1e8 : redeemMarkPrice));

        assertEq(
            juniorVault.claimableRedeemRequest(redeemRequestId, JUNIOR_ATTACKER),
            shares,
            "funded fixture must redeem all requested shares"
        );
        vm.prank(JUNIOR_ATTACKER);
        juniorVault.claimRedeem(redeemRequestId, shares, JUNIOR_ATTACKER, JUNIOR_ATTACKER);
        return settlementToken.balanceOf(JUNIOR_ATTACKER);
    }

    function timedCheckpointCannotForgiveHistoricalCarry(
        uint256 elapsedFuzz,
        uint256 checkpointPriceFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 forgiven;

        _fundTrader(CARRY_TRADER, 150_000e6);
        _open(CARRY_TRADER, CfdTypes.Side.LONG, 200_000e18, 100_000e6, 1e8);

        uint256 balanceBeforeCheckpoint = clearinghouse.balanceAssets(CARRY_TRADER);
        uint256 elapsed = bound(elapsedFuzz, 7 days, 60 days);
        uint256 checkpointPrice = bound(checkpointPriceFuzz, 0.4e8, 0.7e8);

        vm.warp(block.timestamp + elapsed);
        vm.prank(address(router));
        engine.updateMarkPrice(checkpointPrice, uint64(vm.getBlockTimestamp()));
        uint256 minimumHistoricalCarryAssets = _pendingIndexedCarryAssets(CARRY_TRADER);

        settlementToken.mint(CARRY_TRADER, 1);
        vm.startPrank(CARRY_TRADER);
        settlementToken.approve(address(clearinghouse), 1);
        clearinghouse.deposit(CARRY_TRADER, 1);
        vm.stopPrank();

        uint256 balanceAfterCheckpoint = clearinghouse.balanceAssets(CARRY_TRADER);
        uint256 maxAllowedBalance = balanceBeforeCheckpoint + 1 - minimumHistoricalCarryAssets;
        violation = balanceAfterCheckpoint > maxAllowedBalance;
        forgiven = violation ? balanceAfterCheckpoint - maxAllowedBalance : 0;

        vm.revertToState(snapshot);
        ++completedCarryCheckpoints;
        if (violation) {
            checkpointForgaveHistoricalCarry = true;
            forgivenCarryAssets = forgiven;
        }
    }

    function recapRevenueReconcileCannotDropClaimantValue(
        uint256 recapFuzz,
        uint256 revenueFuzz
    ) external {
        uint256 snapshot = vm.snapshotState();
        bool violation;
        uint256 disappeared;

        settlementToken.burn(address(pool), pool.rawAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal() + pool.juniorPrincipal(), 0, "empty pool must reach a complete principal wipe");
        {
            uint256 recapitalizationAssets = bound(recapFuzz, 1e6, 5000e6);
            uint256 revenueAssets = bound(revenueFuzz, 1e6, 5000e6);
            settlementToken.mint(address(pool), recapitalizationAssets + revenueAssets);

            vm.startPrank(address(engine));
            pool.recordClaimantInflow(
                recapitalizationAssets,
                IHousePool.ClaimantInflowKind.Recapitalization,
                IHousePool.ClaimantInflowCashMode.CashArrived
            );
            pool.recordClaimantInflow(
                revenueAssets, IHousePool.ClaimantInflowKind.Revenue, IHousePool.ClaimantInflowCashMode.CashArrived
            );
            vm.stopPrank();

            uint256 claimantLedgerBefore = _claimantLedgerAssets();
            vm.prank(address(juniorVault));
            pool.reconcile();
            uint256 claimantLedgerAfter = _claimantLedgerAssets();
            violation = claimantLedgerAfter < claimantLedgerBefore;
            disappeared = violation ? claimantLedgerBefore - claimantLedgerAfter : 0;
        }

        vm.revertToState(snapshot);
        ++completedRecapReconciliations;
        if (violation) {
            pendingRevenueDisappeared = true;
            disappearedRevenueAssets = disappeared;
        }
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        settlementToken.mint(trader, amount);
        vm.startPrank(trader);
        settlementToken.approve(address(clearinghouse), amount);
        clearinghouse.deposit(trader, amount);
        vm.stopPrank();
    }

    function _open(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price
    ) internal {
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: margin,
                targetPrice: price,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: false
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function _close(
        address account,
        CfdTypes.Side side,
        uint256 size,
        uint256 price
    ) internal {
        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: size,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: side,
                isClose: true
            }),
            price,
            depth,
            uint64(block.timestamp)
        );
    }

    function _mockPythUpdateData(
        uint256 price
    ) internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = BASE_PYTH_FEED_A;
        feedIds[1] = BASE_PYTH_FEED_B;
        mockPyth.setAllUniquePrices(feedIds, int64(uint64(price)), 0, int32(-8), block.timestamp, block.timestamp - 1);

        updateData = new bytes[](1);
        updateData[0] = abi.encode(price);
    }

    function _unrealizedTraderPnl() internal view returns (int256) {
        uint256 price = engine.lastMarkPrice();
        (uint256 longMaxProfit, uint256 longOi, uint256 longEntryNotional,) = engine.sides(uint8(CfdTypes.Side.LONG));
        longMaxProfit;
        (uint256 shortMaxProfit, uint256 shortOi, uint256 shortEntryNotional,) =
            engine.sides(uint8(CfdTypes.Side.SHORT));
        shortMaxProfit;
        int256 longPnl = (int256(longEntryNotional) - int256(longOi * price)) / int256(1e20);
        int256 shortPnl = (int256(shortOi * price) - int256(shortEntryNotional)) / int256(1e20);
        return longPnl + shortPnl;
    }

    function _claimantLedgerAssets() internal view returns (uint256) {
        return pool.seniorPrincipal() + pool.juniorPrincipal() + pool.unassignedAssets()
            + pool.pendingRecapitalizationAssets() + pool.pendingTradingRevenueAssets();
    }

    function _pendingIndexedCarryAssets(
        address account
    ) internal view returns (uint256) {
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return 0;
        }
        (uint256 borrowBaseAssets, uint256 startIndex,) = engine.positionCarryState(account);
        if (borrowBaseAssets == 0) {
            return 0;
        }
        uint256 endIndex = _currentSideCarryIndex(side);
        if (endIndex <= startIndex) {
            return 0;
        }
        return PositionRiskAccountingLib.computeIndexedCarryAssets(borrowBaseAssets, endIndex - startIndex);
    }

    function _currentSideCarryIndex(
        CfdTypes.Side side
    ) internal view returns (uint256 index) {
        uint256 sideIndex = uint256(side);
        (,,,,, uint256 baseCarryBps,,,,) = engine.riskParams();
        index = PositionRiskAccountingLib.computeCurrentCarryIndex(
            engine.sideCarryIndex(sideIndex),
            engine.sideCarryTimestamp(sideIndex),
            block.timestamp,
            engine.sideBorrowBaseAssets(sideIndex),
            pool.totalAssets(),
            baseCarryBps
        );
    }

}

contract PerpValueConservationInvariantTest is BasePerpTest {

    PerpValueConservationHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpValueConservationHandler(
            settlementToken, engine, clearinghouse, router, pool, juniorVault, baseMockPyth
        );

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.failedFullCloseCannotExtractMargin.selector;
        selectors[1] = handler.neutralMtmCannotCreateLpDepositWithdrawProfit.selector;
        selectors[2] = handler.timedCheckpointCannotForgiveHistoricalCarry.selector;
        selectors[3] = handler.recapRevenueReconcileCannotDropClaimantValue.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_AllBoundedScenariosReachTheirIntendedOutcomes() public {
        handler.failedFullCloseCannotExtractMargin(180_000_000); // Explicit terminal Slippage rejection.
        handler.failedFullCloseCannotExtractMargin(180_000_001); // Price satisfies the full-close limit.
        handler.neutralMtmCannotCreateLpDepositWithdrawProfit(500, 10_000e6);
        handler.timedCheckpointCannotForgiveHistoricalCarry(7 days, 0.5e8);
        handler.recapRevenueReconcileCannotDropClaimantValue(100e6, 200e6);
        assertEq(handler.slippageCloseRejections(), 1);
        assertEq(handler.successfulCloseExecutions(), 1);
        assertEq(handler.completedNeutralRounds(), 1);
        assertEq(handler.completedCarryCheckpoints(), 1);
        assertEq(handler.completedRecapReconciliations(), 1);
        _assertAllInvariants();
    }

    function test_UnexpectedDependencyRevertsCannotBecomeSkippedScenarios() public {
        bytes[] memory failures = new bytes[](4);
        failures[0] = hex"decafbad";
        failures[1] = bytes("");
        failures[2] = abi.encodeWithSignature("Error(string)", "injected dependency failure");
        failures[3] = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        for (uint256 path; path < 4; ++path) {
            for (uint256 i; i < failures.length; ++i) {
                _assertDependencyRevertIsFatal(path, failures[i]);
            }
        }
        assertEq(handler.slippageCloseRejections(), 0, "reverted scenarios cannot count as covered");
        assertEq(handler.completedCarryCheckpoints(), 0);
        assertEq(handler.completedRecapReconciliations(), 0);
    }

    function _assertDependencyRevertIsFatal(
        uint256 path,
        bytes memory reason
    ) private {
        address dependency;
        bytes memory callData;
        if (path == 0) {
            dependency = address(router);
            callData = abi.encodeWithSelector(bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")));
        } else if (path == 1) {
            dependency = address(router);
            callData = abi.encodeWithSelector(router.executeOrder.selector);
        } else if (path == 2) {
            dependency = address(clearinghouse);
            callData = abi.encodeCall(clearinghouse.deposit, (address(0xCA2203), 1));
        } else {
            dependency = address(pool);
            callData = abi.encodeCall(pool.reconcile, ());
        }
        vm.mockCallRevert(dependency, callData, reason);
        vm.expectRevert();
        if (path < 2) {
            handler.failedFullCloseCannotExtractMargin(180_000_000);
        } else if (path == 2) {
            handler.timedCheckpointCannotForgiveHistoricalCarry(7 days, 0.5e8);
        } else {
            handler.recapRevenueReconcileCannotDropClaimantValue(100e6, 200e6);
        }
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    function test_ReturnedEngineAndReceiptFailuresCannotCountAsSuccessfulCalls() public {
        for (uint256 i; i < 2; ++i) {
            OrderV3Types.ExecutionResult memory result = OrderV3Types.ExecutionResult({
                orderId: 1,
                status: OrderV3Types.LifecycleStatus.Pending,
                terminalReason: OrderV3Types.TerminalReason.None,
                pendingReason: i == 0
                    ? OrderV3Types.PendingReason.EngineFailure
                    : OrderV3Types.PendingReason.ReceiptFailure,
                receiptHash: bytes32(0)
            });
            vm.mockCall(address(router), abi.encodeWithSelector(router.executeOrder.selector), abi.encode(result));
            vm.expectRevert(abi.encodeWithSelector(PerpValueConservationHandler.UnexpectedCloseResult.selector, result));
            handler.failedFullCloseCannotExtractMargin(180_000_001);
            vm.clearMockedCalls();
        }
        assertEq(handler.successfulCloseExecutions(), 0);
        assertEq(handler.slippageCloseRejections(), 0);
    }

    function _assertInvariant_FailedExecutionCannotExtractActiveMargin() internal view {
        assertFalse(handler.failedCloseExtractedMargin(), "Failed close changed pledge or paid a zero-bounty keeper");
    }

    function _assertInvariant_NeutralMtmCannotCreateLpProfit() internal view {
        assertFalse(handler.neutralMtmCreatedLpProfit(), "Neutral MTM deposit/withdraw sequence created LP profit");
    }

    function _assertInvariant_CarryCheckpointsCannotForgiveHistory() internal view {
        assertFalse(handler.checkpointForgaveHistoricalCarry(), "Timed carry checkpoint forgave historical carry");
    }

    function _assertInvariant_PendingRevenueCannotDisappear() internal view {
        assertFalse(handler.pendingRevenueDisappeared(), "Pending revenue disappeared during recap/reconcile");
    }

    function invariant_SnapshotScenariosPreserveValueOwnership() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_FailedExecutionCannotExtractActiveMargin();
        _assertInvariant_NeutralMtmCannotCreateLpProfit();
        _assertInvariant_CarryCheckpointsCannotForgiveHistory();
        _assertInvariant_PendingRevenueCannotDisappear();
    }

}

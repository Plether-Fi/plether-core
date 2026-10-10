// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

/// @dev These campaigns deliberately submit economically invalid actions. Only documented business errors are
///      classified; malformed data, unknown codes, Error(string), and Panic(uint256) always fail the campaign.
abstract contract PerpActionHandler is Test {

    uint256 public ghost_commitAttempts;
    uint256 public ghost_committedOrders;
    uint256 public ghost_expectedCommitRejections;
    uint256 public ghost_successfulExecutions;
    uint256 public ghost_expectedExecutionRejections;
    uint256 public ghost_expectedLiquidationRejections;
    uint256 public ghost_expectedLpRejections;
    mapping(bytes4 => uint256) public ghost_rejectionsBySelector;

    error UnexpectedActionRevert(bytes reason);
    error UnexpectedPendingExecution(OrderV3Types.PendingReason reason);

    function _tryCommit(
        LegacyOrderRouterHarness router,
        address actor,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 price,
        bool isClose
    ) internal returns (bool committed, uint64 orderId) {
        ++ghost_commitAttempts;
        vm.prank(actor);
        try router.commitOrder(side, size, margin, price, isClose) returns (uint64 id) {
            ++ghost_committedOrders;
            return (true, id);
        } catch (bytes memory reason) {
            if (!_isExpectedCommitRejection(reason, isClose)) {
                revert UnexpectedActionRevert(reason);
            }
            ++ghost_expectedCommitRejections;
            ++ghost_rejectionsBySelector[bytes4(reason)];
        }
    }

    function _isExpectedCommitRejection(
        bytes memory reason,
        bool isClose
    ) private pure returns (bool) {
        bytes4 selector = bytes4(reason);
        if (reason.length == 36) {
            uint256 code;
            assembly ("memory-safe") { code := mload(add(reason, 36)) }
            if (selector == IOrderRouterErrors.OrderRouter__CommitValidation.selector) {
                return code == 11;
            }
            if (!isClose && selector == IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector) {
                // Named OpenRevertCode values allowed by these bounded, lot-aligned adversarial inputs.
                return code == uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.LIQUIDATION_RESERVE_UNFUNDED)
                    || code == uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED);
            }
        }
        if (isClose && reason.length == 100) {
            return selector == ICfdEngineTypes.CfdEngine__InsufficientCloseOrderBountyBacking.selector;
        }
        if (reason.length != 4) {
            return false;
        }
        if (selector == IOrderRouterErrors.OrderRouter__TooManyPendingOrders.selector) {
            return true;
        }
        if (isClose) {
            return selector == IOrderRouterErrors.OrderRouter__NoQueuedPosition.selector
                || selector == IOrderRouterErrors.OrderRouter__SideMismatch.selector
                || selector == IOrderRouterErrors.OrderRouter__SizeExceedsQueued.selector;
        }
        return selector == IOrderRouterErrors.OrderRouter__DegradedMode.selector
            || selector == IOrderRouterErrors.OrderRouter__CloseOnlyWindow.selector
            || selector == IOrderRouterErrors.OrderRouter__VaultRiskBlocked.selector
            || selector == IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector
            || selector == MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector;
    }

    function _tryExecute(
        LegacyOrderRouterHarness router,
        uint64 orderId,
        bytes[] memory data
    ) internal {
        try router.executeOrder(orderId, data) returns (OrderV3Types.ExecutionResult memory result) {
            _checkPendingReason(result.pendingReason);
            if (result.status == OrderV3Types.LifecycleStatus.Executed) {
                ++ghost_successfulExecutions;
            }
        } catch (bytes memory reason) {
            // A previous nonterminal FIFO head can legitimately prevent the newly submitted order executing.
            if (reason.length != 4 || bytes4(reason) != IOrderRouterErrors.OrderRouter__OrderNotQueueHead.selector) {
                revert UnexpectedActionRevert(reason);
            }
            ++ghost_expectedExecutionRejections;
            ++ghost_rejectionsBySelector[bytes4(reason)];
        }
    }

    function _checkPendingReason(
        OrderV3Types.PendingReason reason
    ) internal pure {
        if (reason == OrderV3Types.PendingReason.EngineFailure || reason == OrderV3Types.PendingReason.ReceiptFailure) {
            revert UnexpectedPendingExecution(reason);
        }
    }

    function _classifyLiquidationRevert(
        bytes memory reason,
        bool injectedPayoutFailure
    ) internal {
        bool solvent = reason.length == 4 && bytes4(reason) == ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector;
        if (!solvent && !(injectedPayoutFailure && keccak256(reason) == keccak256(bytes("pool illiquid")))) {
            revert UnexpectedActionRevert(reason);
        }
        ++ghost_expectedLiquidationRejections;
        ++ghost_rejectionsBySelector[bytes4(reason)];
    }

    function _trySettleLpEpoch(
        LegacyOrderRouterHarness router,
        bytes[] memory data
    ) internal {
        try router.settleLpEpoch(data) {}
        catch (bytes memory reason) {
            // Available USDC can still be below the amount required to fund one redeem share, or deposits held
            // by the frozen calendar. Deterministic tests separately require eligible epochs to make progress.
            if (reason.length != 4 || bytes4(reason) != IHousePool.HousePool__NoLpEpochProgress.selector) {
                revert UnexpectedActionRevert(reason);
            }
            ++ghost_expectedLpRejections;
            ++ghost_rejectionsBySelector[bytes4(reason)];
        }
    }

}

contract PerpHandler is PerpActionHandler {

    MockUSDC public usdc;
    CfdEngine public engine;
    CfdEngineLens public engineLens;
    HousePool public pool;
    MarginClearinghouse public clearinghouse;
    LegacyOrderRouterHarness public router;
    TrancheVault public juniorVault;

    address[3] public traders;
    address public lp;

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalLpDeposited;
    uint256 public ghost_liquidationCount;
    uint256 public ghost_tradeCount;
    uint256 public ghost_totalLpWithdrawn;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        MarginClearinghouse _clearinghouse,
        LegacyOrderRouterHarness _router,
        TrancheVault _juniorVault
    ) {
        usdc = _usdc;
        engine = _engine;
        engineLens = new CfdEngineLens(address(_engine));
        pool = _pool;
        clearinghouse = _clearinghouse;
        router = _router;
        juniorVault = _juniorVault;

        traders[0] = address(0x1001);
        traders[1] = address(0x1002);
        traders[2] = address(0x1003);
        lp = address(0x2001);
    }

    function depositAndTrade(
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginFuzz,
        uint256 priceFuzz
    ) external {
        address trader = traders[ghost_tradeCount % 3];
        address account = trader;

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);
        sizeFuzz = bound(sizeFuzz, 10, 1000) * CfdTypes.SIZE_QUANTUM;
        marginFuzz = bound(marginFuzz, 100e6, 10_000e6);

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;

        usdc.mint(trader, marginFuzz);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), marginFuzz);
        clearinghouse.deposit(account, marginFuzz);
        vm.stopPrank();
        ghost_totalDeposited += marginFuzz;

        (bool committed, uint64 commitId) = _tryCommit(router, trader, side, sizeFuzz, marginFuzz, priceFuzz, false);
        if (!committed) {
            return;
        }
        _tryExecute(router, commitId, _nextBlockPriceData(priceFuzz));

        ghost_tradeCount++;
    }

    function closeTrade(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        address account = trader;

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);

        (bool committed, uint64 commitId) = _tryCommit(router, trader, side, size, 0, priceFuzz, true);
        if (committed) {
            _tryExecute(router, commitId, _nextBlockPriceData(priceFuzz));
        }
    }

    function liquidate(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        address account = trader;

        (uint256 size,,,,,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.3e8, 1.7e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(priceFuzz);

        try router.executeLiquidation(account, priceData) {
            ghost_liquidationCount++;
        } catch (bytes memory reason) {
            _classifyLiquidationRevert(reason, false);
        }
    }

    function depositLP(
        uint256 amountFuzz
    ) external {
        uint256 maxAssets = juniorVault.maxRequestDeposit(lp);
        if (maxAssets < 1000e6) {
            return;
        }
        uint256 upperBound = maxAssets < 100_000e6 ? maxAssets : 100_000e6;
        uint256 assets = bound(amountFuzz, 1000e6, upperBound);

        usdc.mint(lp, assets);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), assets);
        juniorVault.requestDeposit(assets, lp, lp);
        vm.stopPrank();

        ghost_totalLpDeposited += assets;
    }

    function withdrawLP(
        uint256 amountFuzz
    ) external {
        uint256 maxShares = juniorVault.maxRequestRedeem(lp);
        if (maxShares == 0) {
            return;
        }

        uint256 shares = bound(amountFuzz, 1, maxShares);
        if (juniorVault.estimateRedeemAssets(shares) < pool.minTrancheDepositUsdc() && shares < maxShares) {
            shares = maxShares;
        }

        vm.prank(lp);
        juniorVault.requestRedeem(shares, lp, lp);
    }

    function advanceLpEpoch(
        uint8 epochsFuzz
    ) external {
        uint256 epochs = bound(uint256(epochsFuzz), 1, 3);
        vm.warp(pool.lpEpochStart(pool.currentLpEpoch() + epochs));
    }

    function refreshLpMark() external {
        _refreshLpMark();
    }

    function settleLpEpoch() external {
        if (engine.degradedMode()) {
            return;
        }
        _refreshLpMark();
        if (!_hasSettleableJuniorLpWork()) {
            return;
        }
        uint256 markPrice = engine.lastMarkPrice();
        _trySettleLpEpoch(router, _nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
    }

    function claimLpDeposit() external {
        uint256 requestId = juniorVault.controllerDepositHead(lp);
        if (requestId == 0) {
            return;
        }

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, lp);
        if (claimableAssets != 0) {
            vm.prank(lp);
            juniorVault.claimDeposit(requestId, claimableAssets, lp, lp);
            return;
        }

        if (juniorVault.refundableDepositRequest(requestId, lp) != 0) {
            vm.prank(lp);
            juniorVault.cancelPendingDeposit(requestId, lp, lp);
        }
    }

    function claimLpWithdrawal() external {
        uint256 requestId = juniorVault.controllerRedeemHead(lp);
        if (requestId == 0) {
            return;
        }

        uint256 claimableShares = juniorVault.claimableRedeemRequest(requestId, lp);
        if (claimableShares != 0) {
            vm.prank(lp);
            ghost_totalLpWithdrawn += juniorVault.claimRedeem(requestId, claimableShares, lp, lp);
        }

        if (juniorVault.redeemRefundPending(requestId, lp)) {
            vm.prank(lp);
            juniorVault.claimRedeemRefund(requestId, lp, lp);
        }
    }

    function _refreshLpMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        router.updateMarkPrice(_nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
    }

    function _nextBlockPriceData(
        uint256 price
    ) internal returns (bytes[] memory priceData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
    }

    function _hasSettleableJuniorLpWork() internal view returns (bool) {
        uint256 cutoffEpoch = pool.currentLpEpoch();
        (, uint256 redeemShares) = juniorVault.getMaturedRedeemHead(cutoffEpoch);
        if (redeemShares != 0 && pool.getFreeUSDC() != 0) {
            return true;
        }

        (, uint256 depositAssets) = juniorVault.getMaturedDepositHead(cutoffEpoch);
        return depositAssets != 0 && !pool.paused() && pool.canAcceptTrancheDeposits(false);
    }

}

contract PerpInvariantTest is BasePerpTest {

    PerpHandler handler;
    uint256 seniorHighWaterMark;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 200_000e6;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpHandler(usdc, engine, pool, clearinghouse, router, juniorVault);

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            _fundTrader(trader, 10_000e6);
        }

        seniorHighWaterMark = pool.seniorPrincipal();

        targetContract(address(handler));
    }

    function test_MainHandlerClassifiesRejectedCommitAndStillExecutesValidOrders() public {
        handler.depositAndTrade(0, 10, 100e6, 1e8);
        assertEq(handler.ghost_expectedCommitRejections(), 1);
        assertEq(handler.ghost_committedOrders(), 0);
        handler.depositAndTrade(0, 100, 2000e6, 1e8);
        assertEq(handler.ghost_successfulExecutions(), 1);
        handler.closeTrade(0, 1e8);
        assertEq(handler.ghost_successfulExecutions(), 2);
        _assertAllInvariants();
    }

    function test_MainHandlerEligibleLpEpochMustMakeProgress() public {
        handler.depositLP(2500e6);
        handler.advanceLpEpoch(1);
        handler.settleLpEpoch();
        handler.claimLpDeposit();
        assertGt(juniorVault.balanceOf(handler.lp()), 0);
        assertEq(handler.ghost_expectedLpRejections(), 0);
        _assertAllInvariants();
    }

    function test_MainHandlerDoesNotHideMalformedOrUnknownCommitFailures() public {
        bytes[] memory reasons = new bytes[](4);
        reasons[0] = abi.encodeWithSignature("Error(string)", "unexpected fixture failure");
        reasons[1] = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        reasons[2] =
            abi.encodeWithSelector(IOrderRouterErrors.OrderRouter__PredictableOpenInvalid.selector, uint256(255));
        reasons[3] = abi.encodePacked(IOrderRouterErrors.OrderRouter__TooManyPendingOrders.selector, bytes1(0));
        bytes memory commitSelector =
            abi.encodePacked(bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")));
        for (uint256 i; i < reasons.length; ++i) {
            vm.mockCallRevert(address(router), commitSelector, reasons[i]);
            vm.expectRevert(abi.encodeWithSelector(PerpActionHandler.UnexpectedActionRevert.selector, reasons[i]));
            handler.depositAndTrade(0, 100, 2000e6, 1e8);
            vm.clearMockedCalls();
        }
    }

    function _assertInvariant_GlobalSolvency() internal view {
        uint256 effectiveAssets = pool.totalAssets();

        int256 cappedLegacySpread = int256(0);
        if (cappedLegacySpread < 0) {
            effectiveAssets += uint256(-cappedLegacySpread);
        } else if (cappedLegacySpread > 0) {
            effectiveAssets =
                effectiveAssets > uint256(cappedLegacySpread) ? effectiveAssets - uint256(cappedLegacySpread) : 0;
        }

        if (!engine.degradedMode()) {
            assertGe(effectiveAssets, _maxLiability(), "Non-degraded engine must cover worst-case liability");
        }
    }

    function _assertInvariant_TranchePriority() internal {
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 currentSenior = pool.seniorPrincipal();
        if (currentSenior < seniorHighWaterMark) {
            assertEq(pool.juniorPrincipal(), 0, "Junior must be wiped before senior takes losses");
        }
        if (currentSenior > seniorHighWaterMark) {
            seniorHighWaterMark = currentSenior;
        }
    }

    function _assertInvariant_SeniorHighWaterMarkBlocksJuniorExtractionWhileImpaired() internal {
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 currentSenior = pool.seniorPrincipal();
        uint256 highWaterMark = pool.seniorHighWaterMark();
        if (currentSenior > 0 && currentSenior < highWaterMark) {
            assertEq(pool.juniorPrincipal(), 0, "Junior principal must stay zero while senior is partially impaired");
            assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior withdrawals must stay blocked while senior is impaired");
        }
    }

    function _assertInvariant_NoNegativePrincipal() internal {
        vm.prank(address(juniorVault));
        pool.reconcile();
        if (pool.lastReconcileTime() != block.timestamp) {
            return;
        }

        uint256 claimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 terminalAssets = pool.totalAssets();
        ICfdEngineTypes.TerminalNavSnapshot memory terminal = engine.terminalNavSnapshot();
        uint256 terminalLiabilities = terminal.totalTraderClaimsUsdc;
        if (terminal.terminalLpPriceDeltaUsdc >= 0) {
            terminalAssets += uint256(terminal.terminalLpPriceDeltaUsdc);
        } else {
            terminalLiabilities += uint256(-(terminal.terminalLpPriceDeltaUsdc + 1)) + 1;
        }
        uint256 terminalEquity = terminalAssets > terminalLiabilities ? terminalAssets - terminalLiabilities : 0;
        assertLe(claimed, terminalEquity, "Freshly reconciled principal cannot exceed exact terminal LP equity");
    }

    function _assertInvariant_FeesWithinClearinghouseTreasury() internal view {
        uint256 fees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            fees,
            "Accumulated fees must equal the treasury clearinghouse balance"
        );
        assertLe(fees, usdc.balanceOf(address(clearinghouse)), "Treasury fees must be clearinghouse-custodied");
    }

    function _assertInvariant_WithdrawalAccountingMatchesEngineReserve() internal view {
        uint256 poolAssets = pool.totalAssets();
        uint256 reserved = _withdrawalReservedUsdc();
        uint256 expectedFree = poolAssets > reserved ? poolAssets - reserved : 0;

        assertEq(pool.getFreeUSDC(), expectedFree, "HousePool free USDC must match engine withdrawal reserve");
        assertLe(pool.getFreeUSDC(), poolAssets, "Free USDC cannot exceed physical assets");
    }

    function _assertInvariant_HousePoolPendingStateMatchesReconcileFirstState() internal {
        (uint256 pendingSenior, uint256 pendingJunior, uint256 pendingMaxSenior, uint256 pendingMaxJunior) =
            pool.getPendingTrancheState();

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), pendingSenior, "Pending senior principal must match reconcile-first state");
        assertEq(pool.juniorPrincipal(), pendingJunior, "Pending junior principal must match reconcile-first state");
        assertEq(
            pool.getMaxSeniorWithdraw(),
            pendingMaxSenior,
            "Pending senior withdraw cap must match reconcile-first state"
        );
        assertEq(
            pool.getMaxJuniorWithdraw(),
            pendingMaxJunior,
            "Pending junior withdraw cap must match reconcile-first state"
        );
    }

    function _assertInvariant_LiveLiabilityFlagMatchesDirectionalExposure() internal view {
        bool hasLiveLiability = (_maxLiability() > 0);
        bool hasDirectionalLiability = _maxLiability() > 0;
        assertEq(hasLiveLiability, hasDirectionalLiability, "Live-liability flag must match nonzero bounded liability");
    }

    function _assertInvariant_PendingKeeperReservesBackedByClearinghouseReservations() internal view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router must not custody queued keeper reserves");
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            uint256 protectedActionReserveUsdc =
                clearinghouse.vpiRebateReserveUsdc(account) + _pendingExecutionBountyUsdc(account);
            assertEq(
                clearinghouse.actionReserveUsdc(account),
                protectedActionReserveUsdc,
                "Action reserve must exactly back negative VPI and pending keeper bounties"
            );
        }
    }

    function _assertInvariant_ClearinghouseBalanceMatchesTrackedAccounts() internal view {
        uint256 trackedBalances =
            clearinghouse.balanceUsdc(address(handler)) + clearinghouse.balanceUsdc(engine.protocolTreasury());
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            trackedBalances += clearinghouse.balanceUsdc(account);
        }

        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse USDC custody must equal tracked trader balances"
        );
    }

    function _assertInvariant_KnownActorUsdcConservation() internal view {
        uint256 actorBalances =
            usdc.balanceOf(address(handler)) + usdc.balanceOf(handler.lp()) + usdc.balanceOf(address(this));
        for (uint256 i = 0; i < 3; i++) {
            actorBalances += usdc.balanceOf(handler.traders(i));
        }

        uint256 contractBalances = usdc.balanceOf(address(pool)) + usdc.balanceOf(address(router))
            + usdc.balanceOf(address(clearinghouse)) + usdc.balanceOf(address(seniorVault))
            + usdc.balanceOf(address(juniorVault));

        uint256 expectedSupply = usdc.totalSupply();
        assertEq(
            actorBalances + contractBalances,
            expectedSupply,
            "Known actors plus protocol contracts must conserve the minted USDC supply"
        );
    }

    function _assertInvariant_AggregateOIMatchesPositions() internal view {
        uint256 sumLongSize;
        uint256 sumShortSize;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            address account = trader;
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
            if (size > 0) {
                if (side == CfdTypes.Side.LONG) {
                    sumLongSize += size;
                } else {
                    sumShortSize += size;
                }
            }
        }

        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), sumLongSize, "Long OI must match sum of long positions");
        assertEq(_sideOpenInterest(CfdTypes.Side.SHORT), sumShortSize, "Short OI must match sum of short positions");
    }

    function _assertInvariant_LivePositionsRemainSingleDirectionAndBounded() internal view {
        uint256 capPrice = engine.CAP_PRICE();

        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView =
                engineAccountLens.getAccountLedgerSnapshot(account);
            (uint256 size, uint256 margin, uint256 entryPrice, uint256 maxProfitUsdc, CfdTypes.Side side,,) =
                engine.positions(account);

            assertEq(positionView.hasPosition, size > 0, "Position view existence must match stored size");
            if (size == 0) {
                assertEq(margin, 0, "Empty positions must not retain margin");
                assertEq(entryPrice, 0, "Empty positions must not retain entry price");
                assertEq(positionView.unrealizedPnlUsdc, 0, "Empty positions must not retain bounded profit");
                continue;
            }

            assertTrue(
                side == CfdTypes.Side.LONG || side == CfdTypes.Side.SHORT,
                "Live positions must encode exactly one directional side"
            );

            _assertExactProfitEnvelope(account, size, maxProfitUsdc, side, capPrice);
        }
    }

    function _assertExactProfitEnvelope(
        address account,
        uint256 size,
        uint256 maxProfitUsdc,
        CfdTypes.Side side,
        uint256 capPrice
    ) internal view {
        uint256 lots = CfdMath.sizeToLots(size);
        assertEq(
            maxProfitUsdc,
            CfdMath.calculateExactMaxProfit(lots, engine.positionEntryCostUsdcAtoms(account), side, capPrice),
            "Stored max profit must match the exact entry-cost payoff envelope"
        );
        assertLe(maxProfitUsdc, lots * capPrice, "Live positions must remain bounded by CAP");
    }

    function _assertInvariant_EntryNotionalsMatchPositions() internal view {
        uint256 sumLongNotional;
        uint256 sumShortNotional;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            address account = trader;
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
            if (size > 0) {
                uint256 exactEntryNotional = engine.positionEntryCostUsdcAtoms(account) * CfdMath.USDC_TO_TOKEN_SCALE;
                if (side == CfdTypes.Side.LONG) {
                    sumLongNotional += exactEntryNotional;
                } else {
                    sumShortNotional += exactEntryNotional;
                }
            }
        }

        assertEq(_sideEntryNotional(CfdTypes.Side.LONG), sumLongNotional, "Long entry notional must match positions");
        assertEq(_sideEntryNotional(CfdTypes.Side.SHORT), sumShortNotional, "Short entry notional must match positions");
    }

    function _assertInvariant_PositionMarginsBackedByClearinghouse() internal view {
        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            address account = trader;
            (uint256 size, uint256 margin,,,,,) = engine.positions(account);
            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
            uint256 locked = clearinghouse.lockedMarginUsdc(account);

            if (size > 0) {
                assertGe(locked, margin, "Clearinghouse must back position margin");
            }

            assertGe(
                locked,
                margin + reservation.committedMarginUsdc,
                "Locked margin must back open-position margin plus pending committed margin"
            );
        }
    }

    function _assertInvariant_GlobalSideMarginsMatchPositions() internal view {
        uint256 sumLongMargin;
        uint256 sumShortMargin;

        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            (uint256 size, uint256 margin,,, CfdTypes.Side side,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }
            if (side == CfdTypes.Side.LONG) {
                sumLongMargin += margin;
            } else {
                sumShortMargin += margin;
            }
        }

        assertEq(
            _sideTotalMargin(CfdTypes.Side.LONG),
            sumLongMargin,
            "Long side margin mirror must equal live long position margins"
        );
        assertEq(
            _sideTotalMargin(CfdTypes.Side.SHORT),
            sumShortMargin,
            "Short side margin mirror must equal live short position margins"
        );
    }

    function _assertInvariant_LivePositionsRetainMinimumLiquidationReserve() internal view {
        (,,,,,, uint256 minBountyUsdc,,,) = engine.riskParams();
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            (uint256 size,,,,,,) = engine.positions(account);
            if (size == 0) {
                continue;
            }
            assertGe(
                clearinghouse.liquidationReserveUsdc(account),
                minBountyUsdc,
                "Every live position must retain the dedicated minimum liquidation reserve"
            );
        }
    }

    function _assertInvariant_ClearinghouseBucketsConserveTrackedState() internal view {
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);

            assertEq(
                buckets.settlementBalanceUsdc,
                buckets.freeSettlementUsdc + buckets.totalLockedMarginUsdc,
                "Settlement buckets must sum to tracked balance"
            );
            assertEq(
                buckets.totalLockedMarginUsdc,
                buckets.activePositionMarginUsdc + buckets.otherLockedMarginUsdc,
                "Locked buckets must split into active and other locked margin"
            );
            assertEq(
                clearinghouse.lockedMarginUsdc(account),
                buckets.totalLockedMarginUsdc,
                "Bucket view must match locked margin storage"
            );
        }
    }

    function _assertInvariant_TraderOwnedCollateralRemainsTerminallyReachable() internal view {
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);

            assertEq(
                _terminalReachableUsdc(account),
                buckets.settlementBalanceUsdc,
                "All trader-owned settlement collateral should remain terminally reachable"
            );
        }
    }

    function _assertInvariant_CommittedMarginOwnershipAccountingConservesQueuedExposure() internal view {
        uint64 nextCommitId = router.nextCommitId();

        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            uint256 rawQueuedCommitted;

            for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
                OrderRouterDebugLens.OrderRecord memory record = _orderRecord(orderId);
                if (record.core.account != account || record.core.sizeDelta == 0) {
                    continue;
                }
                rawQueuedCommitted += _remainingCommittedMargin(orderId);
            }

            IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
            assertEq(
                reservation.committedMarginUsdc,
                rawQueuedCommitted,
                "Account reservation must equal the residual committed margin stored on queued orders"
            );
        }
    }

    function _assertInvariant_ProtocolAccountingViewMatchesAccessors() internal view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(protocolView.poolAssetsUsdc, pool.totalAssets(), "Protocol view pool assets must match pool assets");
        assertEq(protocolView.maxLiabilityUsdc, _maxLiability(), "Protocol view liability must match accessor");
        assertEq(
            protocolView.withdrawalReservedUsdc,
            _withdrawalReservedUsdc(),
            "Protocol view withdrawal reserve must match accessor"
        );
        assertEq(
            protocolView.protocolTreasuryBalanceUsdc,
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            "Protocol view fees must match accessor"
        );
        assertEq(
            protocolView.totalTraderClaimBalanceUsdc,
            engine.totalTraderClaimBalanceUsdc(),
            "Protocol view trader trader claims must match storage"
        );
    }

    function _assertInvariant_WithdrawalReserveIncludesTraderClaimLiabilities() internal view {
        uint256 maxLiability = _maxLiability();
        uint256 expectedReserved = maxLiability + engine.totalTraderClaimBalanceUsdc()
            + SolvencyAccountingLib.settlementBufferTargetUsdc(maxLiability, engine.settlementBufferBps());

        assertEq(
            _withdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, trader claims, and settlement headroom"
        );
    }

    function _assertInvariant_PoolLiquidityViewMatchesProtocolAccounting() internal view {
        IHousePool.PoolLiquidityView memory poolView = pool.getPoolLiquidityView();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(poolView.totalAssetsUsdc, protocolView.poolAssetsUsdc, "Pool and engine must agree on pool assets");
        assertEq(
            poolView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on withdrawal reserves"
        );
        assertEq(poolView.freeUsdc, protocolView.freeUsdc, "Pool free USDC must match engine accounting view");
    }

    function _assertInvariant_LiquidationPreviewMatchesPositionView() internal view {
        uint256 oraclePrice = engine.lastMarkPrice();
        if (oraclePrice == 0) {
            return;
        }

        uint256 poolDepth = pool.totalAssets();
        for (uint256 i = 0; i < 3; i++) {
            address account = handler.traders(i);
            PerpsViewTypes.PositionView memory positionView = _publicPosition(account);
            if (!positionView.exists) {
                continue;
            }

            ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
            assertEq(
                preview.liquidatable, positionView.liquidatable, "Liquidation preview must match live position view"
            );
        }
    }

    function _pendingExecutionBountyUsdc(
        address account
    ) private view returns (uint256 pendingExecutionBountyUsdc) {
        uint64 nextCommitId = router.nextCommitId();
        for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
            OrderRouterDebugLens.OrderRecord memory record = _orderRecord(orderId);
            if (
                record.status == IOrderRouterAccounting.OrderStatus.Pending && record.core.account == account
                    && record.core.sizeDelta != 0
            ) {
                pendingExecutionBountyUsdc += record.executionBountyUsdc;
            }
        }
    }

    function invariant_ProtocolSolvencyPositionsAndCustodyReconcile() public {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal {
        assertEq(
            handler.ghost_commitAttempts(), handler.ghost_committedOrders() + handler.ghost_expectedCommitRejections()
        );
        _assertInvariant_GlobalSolvency();
        _assertInvariant_TranchePriority();
        _assertInvariant_SeniorHighWaterMarkBlocksJuniorExtractionWhileImpaired();
        _assertInvariant_NoNegativePrincipal();
        _assertInvariant_FeesWithinClearinghouseTreasury();
        _assertInvariant_WithdrawalAccountingMatchesEngineReserve();
        _assertInvariant_HousePoolPendingStateMatchesReconcileFirstState();
        _assertInvariant_LiveLiabilityFlagMatchesDirectionalExposure();
        _assertInvariant_PendingKeeperReservesBackedByClearinghouseReservations();
        _assertInvariant_ClearinghouseBalanceMatchesTrackedAccounts();
        _assertInvariant_KnownActorUsdcConservation();
        _assertInvariant_AggregateOIMatchesPositions();
        _assertInvariant_LivePositionsRemainSingleDirectionAndBounded();
        _assertInvariant_EntryNotionalsMatchPositions();
        _assertInvariant_PositionMarginsBackedByClearinghouse();
        _assertInvariant_GlobalSideMarginsMatchPositions();
        _assertInvariant_LivePositionsRetainMinimumLiquidationReserve();
        _assertInvariant_ClearinghouseBucketsConserveTrackedState();
        _assertInvariant_TraderOwnedCollateralRemainsTerminallyReachable();
        _assertInvariant_CommittedMarginOwnershipAccountingConservesQueuedExposure();
        _assertInvariant_ProtocolAccountingViewMatchesAccessors();
        _assertInvariant_WithdrawalReserveIncludesTraderClaimLiabilities();
        _assertInvariant_PoolLiquidityViewMatchesProtocolAccounting();
        _assertInvariant_LiquidationPreviewMatchesPositionView();
    }

}

contract AdversarialPerpHandler is PerpActionHandler, RecordedOrderReceipts {

    struct PendingBatchOrder {
        uint64 orderId;
        address account;
        uint256 bountyUsdc;
        uint256 committedMarginUsdc;
    }

    struct BatchObservation {
        uint64 head;
        uint256 keeperBalanceUsdc;
        PendingBatchOrder[] orders;
    }

    MockUSDC public usdc;
    CfdEngine public engine;
    CfdEngineLens public engineLens;
    HousePool public pool;
    MarginClearinghouse public clearinghouse;
    LegacyOrderRouterHarness public router;
    TrancheVault public juniorVault;

    address[4] public actors;
    address public lp;
    address public sink;

    uint256 public ghost_batchAttempts;
    uint256 public ghost_batchAdvances;
    uint256 public ghost_batchExecutedOrders;
    uint256 public ghost_batchFailedOrders;
    uint256 public ghost_batchTerminalOrders;
    uint256 public ghost_batchBlockedAttempts;
    uint256 public ghost_batchBountyCreditsUsdc;
    OrderV3Types.PendingReason public ghost_lastBatchStopReason;
    uint256 public ghost_executedOrders;
    uint256 public ghost_starvationEvents;
    uint256 public ghost_failSoftLiquidations;
    uint256 public ghost_lastRetryableSlippageBatch;
    uint64 public ghost_lastRetryableSlippageOrderId;
    uint64 public ghost_lastRetryableSlippageBeforeExecuteId;
    uint64 public ghost_lastRetryableSlippageAfterExecuteId;
    uint8 public ghost_lastRetryableSlippageOrderStatus;
    uint256 public ghost_lastRetryableSlippageReservationUsdc;
    uint256 public ghost_lastRetryableSlippageRouterBalanceUsdc;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        MarginClearinghouse _clearinghouse,
        LegacyOrderRouterHarness _router,
        TrancheVault _juniorVault
    ) {
        usdc = _usdc;
        engine = _engine;
        engineLens = new CfdEngineLens(address(_engine));
        pool = _pool;
        clearinghouse = _clearinghouse;
        router = _router;
        juniorVault = _juniorVault;

        actors[0] = address(0x3001);
        actors[1] = address(0x3002);
        actors[2] = address(0x3003);
        actors[3] = address(0x3004);
        lp = address(0x4001);
        sink = address(0xDEAD);
    }

    function _account(
        address actor
    ) internal pure returns (address) {
        return actor;
    }

    function _seedTrader(
        address actor,
        uint256 amount
    ) internal {
        address account = _account(actor);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _seedLp(
        uint256 amount
    ) internal returns (uint256 requestId) {
        if (juniorVault.maxRequestDeposit(lp) < amount) {
            return 0;
        }

        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), type(uint256).max);
        requestId = juniorVault.requestDeposit(amount, lp, lp);
        vm.stopPrank();
    }

    function seedActors(
        uint256 amountFuzz
    ) external {
        uint256 amount = bound(amountFuzz, 1000e6, 50_000e6);
        for (uint256 i = 0; i < actors.length; i++) {
            _seedTrader(actors[i], amount);
        }
    }

    function openPosition(
        uint256 actorIdx,
        uint8 sideRaw,
        uint256 sizeFuzz,
        uint256 marginFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        address account = _account(actor);
        uint256 size = bound(sizeFuzz, 10, 250) * CfdTypes.SIZE_QUANTUM;
        uint256 margin = bound(marginFuzz, 200e6, 5000e6);

        if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < margin + 1e6) {
            _seedTrader(actor, margin + 5e6);
        }

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;

        (bool committed, uint64 commitId) = _tryCommit(router, actor, side, size, margin, 1e8, false);
        if (!committed) {
            return;
        }
        uint64 beforeExecute = router.nextExecuteId();
        _tryExecute(router, commitId, _nextBlockPriceData(1e8));
        _recordExecutedOrders(beforeExecute, router.nextExecuteId());
    }

    function spamInvalidOrders(
        uint256 actorIdx,
        uint256 countFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        address account = _account(actor);
        uint256 count = bound(countFuzz, 1, 6);

        if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < count * 101e6) {
            _seedTrader(actor, count * 150e6);
        }

        for (uint256 i = 0; i < count; i++) {
            _tryCommit(router, actor, CfdTypes.Side.LONG, 1000e18, 100e6, 2e8, false);
        }
    }

    function queueBadClose(
        uint256 actorIdx
    ) external {
        address actor = actors[actorIdx % actors.length];
        address account = _account(actor);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        _tryCommit(router, actor, side, size, 0, 90_000_000, true);
    }

    function starveLiquidity(
        uint256 amountFuzz
    ) external {
        uint256 poolAssets = pool.totalAssets();
        // Keep the configured $1 minimum drain feasible while preserving the $10 residual floor.
        if (poolAssets < 11e6) {
            return;
        }

        uint256 amount = bound(amountFuzz, 1e6, poolAssets - 10e6);
        vm.prank(address(pool));
        usdc.transfer(sink, amount);
        ghost_starvationEvents++;
    }

    function replenishLiquidity(
        uint256 amountFuzz
    ) external {
        uint256 amount = bound(amountFuzz, 1000e6, 100_000e6);
        uint256 requestId = _seedLp(amount);
        if (requestId == 0) {
            return;
        }

        uint256 maturity = pool.lpEpochStart(requestId);
        if (block.timestamp < maturity) {
            vm.warp(maturity);
        }
        _settleLpEpoch();
        _claimLpDeposit();
    }

    function advanceLpEpoch(
        uint8 epochsFuzz
    ) external {
        uint256 epochs = bound(uint256(epochsFuzz), 1, 3);
        vm.warp(pool.lpEpochStart(pool.currentLpEpoch() + epochs));
    }

    function refreshLpMark() external {
        _refreshLpMark();
    }

    function settleLpEpoch() external {
        _settleLpEpoch();
    }

    function claimLpDeposit() external {
        _claimLpDeposit();
    }

    function _settleLpEpoch() internal {
        if (engine.degradedMode()) {
            return;
        }
        _refreshLpMark();
        if (!_hasSettleableJuniorLpWork()) {
            return;
        }
        uint256 markPrice = engine.lastMarkPrice();
        _trySettleLpEpoch(router, _nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
    }

    function _claimLpDeposit() internal {
        uint256 requestId = juniorVault.controllerDepositHead(lp);
        if (requestId == 0) {
            return;
        }

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, lp);
        if (claimableAssets != 0) {
            vm.prank(lp);
            juniorVault.claimDeposit(requestId, claimableAssets, lp, lp);
            return;
        }

        if (juniorVault.refundableDepositRequest(requestId, lp) != 0) {
            vm.prank(lp);
            juniorVault.cancelPendingDeposit(requestId, lp, lp);
        }
    }

    function _refreshLpMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        router.updateMarkPrice(_nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
    }

    function _hasSettleableJuniorLpWork() internal view returns (bool) {
        uint256 cutoffEpoch = pool.currentLpEpoch();
        (, uint256 redeemShares) = juniorVault.getMaturedRedeemHead(cutoffEpoch);
        if (redeemShares != 0 && pool.getFreeUSDC() != 0) {
            return true;
        }

        (, uint256 depositAssets) = juniorVault.getMaturedDepositHead(cutoffEpoch);
        return depositAssets != 0 && !pool.paused() && pool.canAcceptTrancheDeposits(false);
    }

    function processBatch(
        uint256 maxOrdersFuzz,
        uint256 oraclePriceFuzz
    ) external {
        address actor = actors[ghost_batchAttempts % actors.length];
        address account = _account(actor);

        if (clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc < 2005e6) {
            _seedTrader(actor, 2500e6);
        }

        CfdTypes.Side side = CfdTypes.Side.LONG;
        (uint256 size,,,, CfdTypes.Side existingSide,,) = engine.positions(account);
        if (size > 0) {
            side = existingSide;
        }

        (bool committed,) = _tryCommit(router, actor, side, 10_000e18, 2000e6, 1e8, false);
        // Existing pending work should still be processed when admission of the extra order is rejected.
        if (!committed && _countPendingOrders() == 0) {
            return;
        }

        uint256 pending = _countPendingOrders();
        uint256 batchSize = bound(maxOrdersFuzz, 1, pending);
        uint256 oraclePrice = bound(oraclePriceFuzz, 99_000_000, 101_000_000);

        ghost_batchAttempts++;
        uint64 beforeExecute = router.nextExecuteId();
        uint64 lastCommittedOrderId = router.nextCommitId() - 1;
        uint256 candidateMaxOrderId = uint256(beforeExecute) + batchSize - 1;
        uint64 maxOrderId =
            candidateMaxOrderId < lastCommittedOrderId ? uint64(candidateMaxOrderId) : lastCommittedOrderId;
        bytes[] memory priceData = _nextBlockPriceData(oraclePrice);

        bool retryableSlippageAtHead;
        if (beforeExecute < router.nextCommitId()) {
            OrderRouterDebugLens.OrderRecord memory headRecord = _orderRecord(beforeExecute);
            if (uint8(headRecord.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
                retryableSlippageAtHead = !_checkSlippage(headRecord.core, oraclePrice);
                if (retryableSlippageAtHead) {
                    ghost_lastRetryableSlippageOrderId = beforeExecute;
                    ghost_lastRetryableSlippageBeforeExecuteId = beforeExecute;
                }
            }
        }
        BatchObservation memory beforeBatch = _snapshotBatch(maxOrderId, batchSize);
        _startRecordingLogs();
        OrderV3Types.BatchResult memory batchResult = router.executeOrderBatch(maxOrderId, priceData);
        _checkPendingReason(batchResult.stopReason);
        ghost_lastBatchStopReason = batchResult.stopReason;
        _verifyBatchOutcomes(beforeBatch, batchResult);
        uint64 afterExecute = router.nextExecuteId();

        if (retryableSlippageAtHead) {
            OrderRouterDebugLens.OrderRecord memory postRecord = _orderRecord(ghost_lastRetryableSlippageOrderId);
            if (uint8(postRecord.status) == uint8(IOrderRouterAccounting.OrderStatus.Failed)) {
                ghost_lastRetryableSlippageBatch++;
                ghost_lastRetryableSlippageAfterExecuteId = afterExecute;
                ghost_lastRetryableSlippageOrderStatus = uint8(postRecord.status);
                ghost_lastRetryableSlippageReservationUsdc = postRecord.executionBountyUsdc;
                ghost_lastRetryableSlippageRouterBalanceUsdc = usdc.balanceOf(address(router));
            }
        }

        if (afterExecute != beforeExecute) {
            ghost_batchAdvances++;
        }
    }

    function _snapshotBatch(
        uint64 maxOrderId,
        uint256 batchSize
    ) internal view returns (BatchObservation memory observed) {
        observed.head = router.nextExecuteId();
        observed.keeperBalanceUsdc = clearinghouse.balanceUsdc(address(this));
        observed.orders = new PendingBatchOrder[](batchSize);
        uint64 cursor = observed.head;
        uint256 count;
        while (cursor != 0 && cursor <= maxOrderId) {
            OrderRouterDebugLens.OrderRecord memory record = _orderRecord(cursor);
            assertEq(uint8(record.status), uint8(IOrderRouterAccounting.OrderStatus.Pending));
            observed.orders[count++] = PendingBatchOrder({
                orderId: cursor,
                account: record.core.account,
                bountyUsdc: record.executionBountyUsdc,
                committedMarginUsdc: clearinghouse.getOrderReservation(cursor).remainingAmountUsdc
            });
            cursor = record.nextGlobalOrderId;
        }
    }

    function _verifyBatchOutcomes(
        BatchObservation memory beforeBatch,
        OrderV3Types.BatchResult memory result
    ) internal {
        uint256 terminalCount;
        uint256 keeperCreditUsdc;
        for (uint256 i; i < beforeBatch.orders.length; ++i) {
            PendingBatchOrder memory pending = beforeBatch.orders[i];
            if (pending.orderId == 0) {
                break;
            }
            OrderV3Types.LifecycleStatus status = router.lifecycleBook().lifecycleStatus(pending.orderId);
            if (status == OrderV3Types.LifecycleStatus.Pending) {
                continue;
            }
            assertTrue(
                status == OrderV3Types.LifecycleStatus.Executed || status == OrderV3Types.LifecycleStatus.Failed,
                "Pending order must remain pending or acquire a terminal outcome"
            );
            keeperCreditUsdc += _verifyTerminalBatchOrder(pending);
            ++terminalCount;
            if (status == OrderV3Types.LifecycleStatus.Executed) {
                ++ghost_batchExecutedOrders;
                ++ghost_executedOrders;
            } else {
                ++ghost_batchFailedOrders;
            }
        }
        assertEq(result.terminalCount, terminalCount, "Batch result must count observed terminal transitions");
        assertEq(result.nextOrderId, router.nextExecuteId(), "Batch result must report the actual queue head");
        assertEq(
            clearinghouse.balanceUsdc(address(this)),
            beforeBatch.keeperBalanceUsdc + keeperCreditUsdc,
            "Terminal bounty credits must equal independently snapshotted reservations"
        );
        ghost_batchTerminalOrders += terminalCount;
        ghost_batchBountyCreditsUsdc += keeperCreditUsdc;
        if (terminalCount == 0) {
            // Eligibility depends on time, oracle availability, regime and gas. A documented nonterminal stop is
            // legitimate; silently doing nothing or releasing a still-pending order's custody is not.
            assertTrue(result.stopReason != OrderV3Types.PendingReason.None, "Blocked batch must explain its stop");
            assertEq(router.nextExecuteId(), beforeBatch.head, "Nonterminal stop must preserve the queue head");
            PendingBatchOrder memory head = beforeBatch.orders[0];
            assertEq(
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, head.orderId).amountUsdc,
                head.bountyUsdc,
                "Nonterminal stop must preserve the head bounty"
            );
            assertEq(
                clearinghouse.getOrderReservation(head.orderId).remainingAmountUsdc,
                head.committedMarginUsdc,
                "Nonterminal stop must preserve the head margin"
            );
            ++ghost_batchBlockedAttempts;
        } else {
            assertTrue(router.nextExecuteId() != beforeBatch.head, "Terminal outcomes must advance the FIFO head");
        }
    }

    function _verifyTerminalBatchOrder(
        PendingBatchOrder memory pending
    ) internal returns (uint256 keeperCreditUsdc) {
        OrderV3Types.CompactOutcome memory receipt = _verifiedOutcome(router.lifecycleBook(), pending.orderId);
        assertEq(receipt.account, pending.account);
        assertEq(receipt.executor, address(this));
        assertEq(receipt.bountyUsdc, pending.bountyUsdc, "Receipt must account for the original bounty reservation");
        if (pending.bountyUsdc == 0) {
            assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.None));
            assertEq(receipt.bountyRecipient, address(0));
        } else if (receipt.reason == OrderV3Types.TerminalReason.RiskOff) {
            assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.RefundedToAccount));
            assertEq(receipt.bountyRecipient, pending.account);
        } else {
            // This handler creates ordinary orders. It never creates protection attempts or liquidates within a batch.
            assertEq(uint8(receipt.bountyDisposition), uint8(OrderV3Types.BountyDisposition.Paid));
            assertEq(receipt.bountyRecipient, address(this));
            keeperCreditUsdc = pending.bountyUsdc;
        }
        IMarginClearinghouse.BountyReservation memory bounty =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, pending.orderId);
        assertEq(bounty.amountUsdc, 0, "Terminal order cannot retain a bounty reservation");
        assertEq(uint8(bounty.state), uint8(IMarginClearinghouse.BountyReservationState.Settled));
        IMarginClearinghouse.OrderReservation memory margin = clearinghouse.getOrderReservation(pending.orderId);
        assertEq(margin.remainingAmountUsdc, 0, "Terminal order cannot retain committed margin");
        assertTrue(margin.status != IMarginClearinghouse.ReservationStatus.Active);
    }

    function _checkSlippage(
        CfdTypes.Order memory order,
        uint256 executionPrice
    ) internal pure returns (bool) {
        if (order.targetPrice == 0) {
            return true;
        }
        if (order.isClose) {
            if (order.side == CfdTypes.Side.LONG) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.LONG) {
            return executionPrice >= order.targetPrice;
        }
        return executionPrice <= order.targetPrice;
    }

    function _countPendingOrders() internal view returns (uint256 pending) {
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            if (uint8(_orderRecord(orderId).status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
                pending++;
            }
        }
    }

    function _recordExecutedOrders(
        uint64 beforeExecute,
        uint64 afterExecute
    ) internal returns (uint256 executedOrders) {
        uint64 upperBound = afterExecute == 0 ? router.nextCommitId() : afterExecute;
        for (uint64 orderId = beforeExecute; orderId < upperBound; orderId++) {
            if (_orderRecord(orderId).status == IOrderRouterAccounting.OrderStatus.Executed) {
                ghost_executedOrders++;
                executedOrders++;
            }
        }
    }

    function _nextBlockPriceData(
        uint256 price
    ) internal returns (bytes[] memory priceData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        priceData = new bytes[](1);
        priceData[0] = abi.encode(price);
    }

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouterDebugLens.OrderRecord memory record) {
        return OrderRouterDebugLens.loadOrderRecord(vm, router, orderId);
    }

    function liquidateWithPayoutFailure(
        uint256 actorIdx,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        address account = _account(actor);
        (uint256 size,,,,,,) = engine.positions(account);
        if (size == 0) {
            return;
        }

        uint256 oraclePrice = bound(priceFuzz, 80_000_000, 125_000_000);
        bytes[] memory priceData = _nextBlockPriceData(oraclePrice);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, oraclePrice);
        if (!preview.liquidatable || preview.keeperBountyUsdc == 0) {
            return;
        }

        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("pool illiquid"));

        try router.executeLiquidation(account, priceData) {
            ghost_failSoftLiquidations++;
        } catch (bytes memory reason) {
            _classifyLiquidationRevert(reason, true);
        }

        vm.clearMockedCalls();
    }

}

contract AdversarialPerpInvariantTest is BasePerpTest {

    AdversarialPerpHandler handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialSeniorDeposit() internal pure override returns (uint256) {
        return 200_000e6;
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 500_000e6;
    }

    function setUp() public override {
        super.setUp();

        handler = new AdversarialPerpHandler(usdc, engine, pool, clearinghouse, router, juniorVault);
        handler.seedActors(10_000e6);

        targetContract(address(handler));
    }

    function test_AdversarialHandlerPreservesRejectedSpamAndValidExecution() public {
        handler.spamInvalidOrders(0, 6);
        assertEq(handler.ghost_expectedCommitRejections(), 6);
        assertEq(handler.ghost_committedOrders(), 0);
        handler.openPosition(0, 0, 100, 2000e6);
        assertEq(handler.ghost_successfulExecutions(), 1);
        handler.processBatch(1, 1e8);
        assertGt(handler.ghost_batchExecutedOrders(), 0);
        _assertAllInvariants();
    }

    function test_AdversarialStarvedBatchesSettleFailuresAndBountiesWithoutSuccessfulExecution() public {
        handler.starveLiquidity(pool.totalAssets() - 10e6);
        assertEq(pool.totalAssets(), 10e6);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        uint256 treasuryBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256[4] memory balancesBefore;
        for (uint256 i; i < 4; ++i) {
            balancesBefore[i] = clearinghouse.balanceUsdc(handler.actors(i));
        }
        for (uint256 i; i < 33; ++i) {
            // Stale marks defer predictable-open validation to execution. Each batch refreshes the mark, so age it
            // again before the next admitted attempt; the pool remains starved throughout all 33 batches.
            vm.warp(vm.getBlockTimestamp() + router.pletherOracle().getOrderExecutionPolicy(false).maxStaleness + 1);
            handler.processBatch(1, 1e8);
            assertEq(
                uint8(router.lifecycleBook().terminalOutcome(uint64(i + 1)).reason),
                uint8(OrderV3Types.TerminalReason.PlannerRejected),
                "Starved attempts must reach and fail execution assessment, not merely miss their slippage limit"
            );
            assertEq(pool.totalAssets(), 10e6, "No batch replenishes starved pool cash");
        }
        _assertAllInvariants();
        assertEq(handler.ghost_batchAttempts(), 33);
        assertEq(handler.ghost_batchAdvances(), 33);
        assertEq(handler.ghost_batchTerminalOrders(), 33);
        assertEq(handler.ghost_batchFailedOrders(), 33);
        assertEq(handler.ghost_batchExecutedOrders(), 0);
        assertEq(handler.ghost_batchBlockedAttempts(), 0);
        assertEq(handler.ghost_batchBountyCreditsUsdc(), 33 * 200_000);
        assertEq(clearinghouse.balanceUsdc(address(handler)), 33 * 200_000);
        assertEq(clearinghouse.balanceUsdc(engine.protocolTreasury()), treasuryBefore);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore);
        assertEq(router.nextExecuteId(), 0);
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(clearinghouse.balanceUsdc(actor), balancesBefore[i] - (i == 0 ? 9 : 8) * 200_000);
            assertEq(clearinghouse.lockedMarginUsdc(actor), 0);
            assertEq(clearinghouse.totalBountyReservationsUsdc(actor), 0);
            assertEq(router.pendingOrderCounts(actor), 0);
        }
    }

    function test_AdversarialCloseOnlyBatchPreservesPendingHeadAndReservations() public {
        uint256 beforeFad = 1_729_283_399;
        vm.warp(beforeFad);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(beforeFad));
        address actor = handler.actors(0);
        vm.prank(actor);
        uint64 orderId = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 2000e6, 1e8, false);
        uint256 balanceBefore = clearinghouse.balanceUsdc(actor);
        uint256 custodyBefore = usdc.balanceOf(address(clearinghouse));
        vm.warp(beforeFad + 1);
        assertTrue(engine.isFadWindow());
        handler.processBatch(1, 1e8);
        assertEq(handler.ghost_batchAttempts(), 1);
        assertEq(handler.ghost_batchBlockedAttempts(), 1);
        assertEq(uint8(handler.ghost_lastBatchStopReason()), uint8(OrderV3Types.PendingReason.CloseOnly));
        assertEq(handler.ghost_batchAdvances(), 0);
        assertEq(handler.ghost_batchTerminalOrders(), 0);
        assertEq(router.nextExecuteId(), orderId);
        assertEq(uint8(router.lifecycleBook().lifecycleStatus(orderId)), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(clearinghouse.getOrderReservation(orderId).remainingAmountUsdc, 2000e6);
        assertEq(clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, orderId).amountUsdc, 200_000);
        assertEq(clearinghouse.balanceUsdc(actor), balanceBefore);
        assertEq(clearinghouse.balanceUsdc(address(handler)), 0);
        assertEq(usdc.balanceOf(address(clearinghouse)), custodyBefore);
        _assertAllInvariants();
    }

    function test_AdversarialStarvationHandlesSubMinimumRemainingCapacity() public {
        uint256 initialAssets = pool.totalAssets();
        handler.starveLiquidity(initialAssets - 10e6 - 1);
        assertEq(pool.totalAssets(), 10e6 + 1);
        handler.starveLiquidity(1e6);
        assertEq(pool.totalAssets(), 10e6 + 1);
        assertEq(handler.ghost_starvationEvents(), 1);
    }

    function test_AdversarialHandlerDoesNotHideUnexpectedExecutionFailure() public {
        bytes memory reason = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        vm.mockCallRevert(address(router), abi.encodePacked(router.executeOrder.selector), reason);
        vm.expectRevert(abi.encodeWithSelector(PerpActionHandler.UnexpectedActionRevert.selector, reason));
        handler.openPosition(0, 0, 100, 2000e6);
    }

    function _assertInvariant_AdversarialReservationStaysBacked() internal view {
        _assertActionReserveBacking();
    }

    function _assertInvariant_AdversarialBatchProcessingRemainsLive() internal view {
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();
        assertLe(nextExecuteId, nextCommitId, "Queue pointers must remain ordered");
        assertEq(
            handler.ghost_batchAttempts(),
            handler.ghost_batchAdvances() + handler.ghost_batchBlockedAttempts(),
            "Every batch must advance terminal work or preserve a legitimately blocked head"
        );
        assertEq(
            handler.ghost_batchTerminalOrders(),
            handler.ghost_batchExecutedOrders() + handler.ghost_batchFailedOrders(),
            "Every observed terminal transition must be classified"
        );
        assertGe(
            handler.ghost_batchTerminalOrders(),
            handler.ghost_batchAdvances(),
            "Every queue advance must have at least one authenticated terminal receipt"
        );
    }

    function _assertInvariant_AdversarialViewsStayConsistent() internal view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();
        IHousePool.PoolLiquidityView memory poolView = pool.getPoolLiquidityView();

        assertEq(poolView.totalAssetsUsdc, protocolView.poolAssetsUsdc, "Pool and engine must agree on assets");
        assertEq(poolView.freeUsdc, protocolView.freeUsdc, "Pool and engine must agree on free liquidity");
        assertEq(
            poolView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on reserved liquidity"
        );
    }

    function _assertInvariant_AdversarialSlippageFailureClearsHeadAndReserve() internal view {
        if (handler.ghost_lastRetryableSlippageBatch() == 0) {
            return;
        }

        assertEq(
            handler.ghost_lastRetryableSlippageOrderStatus(),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "Terminal slippage failure must mark the head order failed"
        );
        assertEq(
            handler.ghost_lastRetryableSlippageReservationUsdc(),
            0,
            "Terminal slippage failure must clear reserved bounty"
        );
        assertEq(
            handler.ghost_lastRetryableSlippageRouterBalanceUsdc(),
            0,
            "Router must not custody bounty reserves after slippage failure"
        );
    }

    function _assertInvariant_GlobalQueueLinksRemainConsistent() internal view {
        uint64 nextCommitId = router.nextCommitId();
        uint64 headOrderId = router.nextExecuteId();
        uint64 traversed;
        uint64 cursor = headOrderId;
        uint64 expectedPrev;
        uint256 pendingCount;

        for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
            if (uint8(_orderRecord(orderId).status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
                pendingCount++;
            }
        }

        if (pendingCount == 0) {
            assertTrue(
                headOrderId == 0 || headOrderId >= nextCommitId, "Empty queue should not expose a live head pointer"
            );
            return;
        }

        while (cursor != 0 && cursor < nextCommitId && traversed <= pendingCount) {
            OrderRouterDebugLens.OrderRecord memory record = _orderRecord(cursor);
            assertEq(
                uint8(record.status),
                uint8(IOrderRouterAccounting.OrderStatus.Pending),
                "Global queue must only traverse pending orders"
            );
            assertEq(record.prevGlobalOrderId, expectedPrev, "Global queue prev links must remain consistent");
            expectedPrev = cursor;
            cursor = record.nextGlobalOrderId;
            traversed++;
        }

        assertEq(traversed, pendingCount, "Global queue traversal must cover every pending order exactly once");
    }

    function _assertInvariant_AdversarialClearinghouseReservesOnlyPendingKeeperReserves() internal view {
        _assertActionReserveBacking();
    }

    function _assertInvariant_AdversarialQueuedKeeperReserveNeverReturnsToTraderCollateral() internal view {
        for (uint256 i = 0; i < 4; i++) {
            address account = handler.actors(i);
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(account);
            assertEq(buckets.freeSettlementUsdc + buckets.totalLockedMarginUsdc, buckets.settlementBalanceUsdc);
        }
    }

    function _assertActionReserveBacking() private view {
        assertEq(usdc.balanceOf(address(router)), 0, "Router must not custody adversarial keeper reserves");
        for (uint256 i = 0; i < 4; i++) {
            address account = handler.actors(i);
            uint256 protectedActionReserveUsdc =
                clearinghouse.vpiRebateReserveUsdc(account) + _pendingExecutionBountyUsdc(account);
            assertEq(
                clearinghouse.actionReserveUsdc(account),
                protectedActionReserveUsdc,
                "Action reserve must exactly back negative VPI and pending keeper bounties"
            );
        }
    }

    function _pendingExecutionBountyUsdc(
        address account
    ) private view returns (uint256 pendingExecutionBountyUsdc) {
        uint64 nextCommitId = router.nextCommitId();
        for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
            OrderRouterDebugLens.OrderRecord memory record = _orderRecord(orderId);
            if (
                record.status == IOrderRouterAccounting.OrderStatus.Pending && record.core.account == account
                    && record.core.sizeDelta != 0
            ) {
                pendingExecutionBountyUsdc += record.executionBountyUsdc;
            }
        }
    }

    function invariant_AdversarialQueueProgressAndReservationsStayConsistent() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        assertEq(
            handler.ghost_commitAttempts(), handler.ghost_committedOrders() + handler.ghost_expectedCommitRejections()
        );
        _assertInvariant_AdversarialReservationStaysBacked();
        _assertInvariant_AdversarialBatchProcessingRemainsLive();
        _assertInvariant_AdversarialViewsStayConsistent();
        _assertInvariant_AdversarialSlippageFailureClearsHeadAndReserve();
        _assertInvariant_GlobalQueueLinksRemainConsistent();
        _assertInvariant_AdversarialClearinghouseReservesOnlyPendingKeeperReserves();
        _assertInvariant_AdversarialQueuedKeeperReserveNeverReturnsToTraderCollateral();
    }

}

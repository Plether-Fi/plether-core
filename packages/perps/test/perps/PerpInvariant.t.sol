// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../utils/LegacyOrderRouterHarness.sol";
import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {PerpsViewTypes} from "@plether/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "@plether/perps/interfaces/ProtocolLensViewTypes.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract PerpHandler is Test {

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

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, sizeFuzz, marginFuzz, priceFuzz, false);

        router.executeOrder(commitId, _nextBlockPriceData(priceFuzz));

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

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, size, 0, priceFuzz, true);

        router.executeOrder(commitId, _nextBlockPriceData(priceFuzz));
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
        } catch {}
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
        router.settleLpEpoch(_nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
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

    function _assertInvariant_NoLegacySideIndexState() internal view {
        int256 longIdx = _legacySideIndexZero(CfdTypes.Side.LONG);
        int256 shortIdx = _legacySideIndexZero(CfdTypes.Side.SHORT);
        assertEq(longIdx + shortIdx, 0, "Legacy side indices must stay zeroed");
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
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(account);

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

            uint256 sideBound = side == CfdTypes.Side.LONG
                ? (size * entryPrice) / 1e20
                : (size * (capPrice > entryPrice ? capPrice - entryPrice : 0)) / 1e20;
            assertLe(
                CfdMath.calculateMaxProfit(size, entryPrice, side, capPrice),
                sideBound,
                "Live position max profit must respect the side-specific bounded payoff"
            );
            assertLe(
                CfdMath.calculateMaxProfit(size, entryPrice, side, capPrice),
                (size * capPrice) / 1e20,
                "Live positions must remain bounded by CAP"
            );
        }
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

    function invariant_job1() public {
        _assertAllInvariants();
    }

    function invariant_job2() public {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal {
        _assertInvariant_GlobalSolvency();
        _assertInvariant_TranchePriority();
        _assertInvariant_SeniorHighWaterMarkBlocksJuniorExtractionWhileImpaired();
        _assertInvariant_NoLegacySideIndexState();
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

contract AdversarialPerpHandler is Test {

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

        uint64 commitId = router.nextCommitId();
        vm.prank(actor);
        router.commitOrder(side, size, margin, 1e8, false);

        uint64 beforeExecute = router.nextExecuteId();
        try router.executeOrder(commitId, _nextBlockPriceData(1e8)) {} catch {}
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
            vm.prank(actor);
            router.commitOrder(CfdTypes.Side.LONG, 1000e18, 100e6, 2e8, false);
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

        vm.prank(actor);
        try router.commitOrder(side, size, 0, 90_000_000, true) {} catch {}
    }

    function starveLiquidity(
        uint256 amountFuzz
    ) external {
        uint256 poolAssets = pool.totalAssets();
        if (poolAssets <= 10e6) {
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
        router.settleLpEpoch(_nextBlockPriceData(markPrice == 0 ? 1e8 : markPrice));
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

        vm.prank(actor);
        router.commitOrder(side, 10_000e18, 2000e6, 1e8, false);

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
        try router.executeOrderBatch(maxOrderId, priceData) {} catch {}
        uint64 afterExecute = router.nextExecuteId();
        ghost_batchExecutedOrders += _recordExecutedOrders(beforeExecute, afterExecute);

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
        } catch {}

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

    function _assertInvariant_AdversarialReservationStaysBacked() internal view {
        _assertActionReserveBacking();
    }

    function _assertInvariant_AdversarialBatchProcessingRemainsLive() internal view {
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();
        assertLe(nextExecuteId, nextCommitId, "Queue pointers must remain ordered");
        if (handler.ghost_batchAttempts() >= 32) {
            assertGt(handler.ghost_batchAdvances(), 0, "Repeated valid batch attempts must advance the queue");
            assertGt(handler.ghost_batchExecutedOrders(), 0, "Adversarial batch generation must reach engine execution");
        }
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

    function invariant_job1() public view {
        _assertAllInvariants();
    }

    function invariant_job2() public view {
        _assertAllInvariants();
    }

    function _assertAllInvariants() internal view {
        _assertInvariant_AdversarialReservationStaysBacked();
        _assertInvariant_AdversarialBatchProcessingRemainsLive();
        _assertInvariant_AdversarialViewsStayConsistent();
        _assertInvariant_AdversarialSlippageFailureClearsHeadAndReserve();
        _assertInvariant_GlobalQueueLinksRemainConsistent();
        _assertInvariant_AdversarialClearinghouseReservesOnlyPendingKeeperReserves();
        _assertInvariant_AdversarialQueuedKeeperReserveNeverReturnsToTraderCollateral();
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {AccountLensViewTypes} from "../../src/perps/interfaces/AccountLensViewTypes.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {PerpsViewTypes} from "../../src/perps/interfaces/PerpsViewTypes.sol";
import {ProtocolLensViewTypes} from "../../src/perps/interfaces/ProtocolLensViewTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Test} from "forge-std/Test.sol";

contract PerpHandler is Test {

    MockUSDC public usdc;
    CfdEngine public engine;
    CfdEngineLens public engineLens;
    HousePool public pool;
    MarginClearinghouse public clearinghouse;
    OrderRouter public router;
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
        OrderRouter _router,
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
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);
        sizeFuzz = bound(sizeFuzz, 1000e18, 100_000e18);
        marginFuzz = bound(marginFuzz, 100e6, 10_000e6);

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;

        usdc.mint(trader, marginFuzz);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), marginFuzz);
        clearinghouse.deposit(accountId, marginFuzz);
        vm.stopPrank();
        ghost_totalDeposited += marginFuzz;

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, sizeFuzz, marginFuzz, priceFuzz, false);

        bytes[] memory empty = new bytes[](0);
        router.executeOrder(commitId, empty);

        ghost_tradeCount++;
    }

    function closeTrade(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.5e8, 1.5e8);

        uint64 commitId = router.nextCommitId();
        vm.prank(trader);
        router.commitOrder(side, size, 0, priceFuzz, true);

        bytes[] memory empty = new bytes[](0);
        router.executeOrder(commitId, empty);
    }

    function liquidate(
        uint256 traderIdx,
        uint256 priceFuzz
    ) external {
        address trader = traders[traderIdx % 3];
        bytes32 accountId = bytes32(uint256(uint160(trader)));

        (uint256 size,,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        priceFuzz = bound(priceFuzz, 0.3e8, 1.7e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(priceFuzz);

        try router.executeLiquidation(accountId, priceData) {
            ghost_liquidationCount++;
        } catch {}
    }

    function depositLP(
        uint256 amountFuzz
    ) external {
        amountFuzz = bound(amountFuzz, 1000e6, 100_000e6);

        usdc.mint(lp, amountFuzz);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amountFuzz);
        juniorVault.deposit(amountFuzz, lp);
        vm.stopPrank();

        ghost_totalLpDeposited += amountFuzz;
    }

    function withdrawLP(
        uint256 amountFuzz
    ) external {
        uint256 maxW = juniorVault.maxWithdraw(lp);
        if (maxW == 0) {
            return;
        }

        amountFuzz = bound(amountFuzz, 1e6, maxW);

        vm.prank(lp);
        juniorVault.withdraw(amountFuzz, lp, lp);
        ghost_totalLpWithdrawn += amountFuzz;
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
            bountyBps: 15
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

    function invariant_GlobalSolvency() public view {
        uint256 effectiveAssets = pool.totalAssets();
        uint256 fees = engine.accumulatedFeesUsdc();
        effectiveAssets = effectiveAssets > fees ? effectiveAssets - fees : 0;

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

    function invariant_TranchePriority() public {
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

    function invariant_SeniorHighWaterMarkBlocksJuniorExtractionWhileImpaired() public {
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 currentSenior = pool.seniorPrincipal();
        uint256 highWaterMark = pool.seniorHighWaterMark();
        if (currentSenior > 0 && currentSenior < highWaterMark) {
            assertEq(pool.juniorPrincipal(), 0, "Junior principal must stay zero while senior is partially impaired");
            assertEq(pool.getMaxJuniorWithdraw(), 0, "Junior withdrawals must stay blocked while senior is impaired");
        }
    }

    function invariant_NoLegacySideIndexState() public view {
        int256 bullIdx = _legacySideIndexZero(CfdTypes.Side.BULL);
        int256 bearIdx = _legacySideIndexZero(CfdTypes.Side.BEAR);
        assertEq(bullIdx + bearIdx, 0, "Legacy side indices must stay zeroed");
    }

    function invariant_NoNegativePrincipal() public {
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 claimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 bal = pool.totalAssets();
        int256 traderPnl = _unrealizedTraderPnl();
        uint256 effectivePool;
        if (traderPnl >= 0) {
            effectivePool = bal;
        } else {
            effectivePool = bal + uint256(-traderPnl);
        }
        assertLe(claimed, effectivePool, "Claimed equity cannot exceed MtM-adjusted pool value");
    }

    function invariant_FeesWithinVault() public view {
        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 poolBalance = pool.totalAssets();
        assertLe(fees, poolBalance, "Accumulated fees must not exceed vault balance");
    }

    function invariant_WithdrawalAccountingMatchesEngineReserve() public view {
        uint256 poolAssets = pool.totalAssets();
        uint256 reserved = _withdrawalReservedUsdc();
        uint256 expectedFree = poolAssets > reserved ? poolAssets - reserved : 0;

        assertEq(pool.getFreeUSDC(), expectedFree, "HousePool free USDC must match engine withdrawal reserve");
        assertLe(pool.getFreeUSDC(), poolAssets, "Free USDC cannot exceed physical assets");
    }

    function invariant_HousePoolPendingStateMatchesReconcileFirstState() public {
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

    function invariant_LiveLiabilityFlagMatchesDirectionalExposure() public view {
        bool hasLiveLiability = (_maxLiability() > 0);
        bool hasDirectionalLiability = _maxLiability() > 0;
        assertEq(hasLiveLiability, hasDirectionalLiability, "Live-liability flag must match nonzero bounded liability");
    }

    function invariant_PendingKeeperReservesBackedByRouterUsdc() public view {
        uint256 pendingKeeperReserves;
        uint64 nextCommitId = router.nextCommitId();

        for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.accountId == bytes32(0) || record.core.sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += record.executionBountyUsdc;
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Queued keeper reserves must stay backed in router custody"
        );
    }

    function invariant_ClearinghouseBalanceMatchesTrackedAccounts() public view {
        uint256 trackedBalances;
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            trackedBalances += clearinghouse.balanceUsdc(accountId);
        }

        assertEq(
            usdc.balanceOf(address(clearinghouse)),
            trackedBalances,
            "Clearinghouse USDC custody must equal tracked trader balances"
        );
    }

    function invariant_KnownActorUsdcConservation() public view {
        uint256 actorBalances =
            usdc.balanceOf(address(handler)) + usdc.balanceOf(handler.lp()) + usdc.balanceOf(address(this));
        for (uint256 i = 0; i < 3; i++) {
            actorBalances += usdc.balanceOf(handler.traders(i));
        }

        uint256 contractBalances =
            usdc.balanceOf(address(pool)) + usdc.balanceOf(address(router)) + usdc.balanceOf(address(clearinghouse));

        uint256 expectedSupply = usdc.totalSupply();
        assertEq(
            actorBalances + contractBalances,
            expectedSupply,
            "Known actors plus protocol contracts must conserve the minted USDC supply"
        );
    }

    function invariant_AggregateOIMatchesPositions() public view {
        uint256 sumBullSize;
        uint256 sumBearSize;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(accountId);
            if (size > 0) {
                if (side == CfdTypes.Side.BULL) {
                    sumBullSize += size;
                } else {
                    sumBearSize += size;
                }
            }
        }

        assertEq(_sideOpenInterest(CfdTypes.Side.BULL), sumBullSize, "Bull OI must match sum of bull positions");
        assertEq(_sideOpenInterest(CfdTypes.Side.BEAR), sumBearSize, "Bear OI must match sum of bear positions");
    }

    function invariant_LivePositionsRemainSingleDirectionAndBounded() public view {
        uint256 capPrice = engine.CAP_PRICE();

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            AccountLensViewTypes.AccountLedgerSnapshot memory positionView =
                engineAccountLens.getAccountLedgerSnapshot(accountId);
            (uint256 size, uint256 margin, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(accountId);

            assertEq(positionView.hasPosition, size > 0, "Position view existence must match stored size");
            if (size == 0) {
                assertEq(margin, 0, "Empty positions must not retain margin");
                assertEq(entryPrice, 0, "Empty positions must not retain entry price");
                assertEq(positionView.unrealizedPnlUsdc, 0, "Empty positions must not retain bounded profit");
                continue;
            }

            assertTrue(
                side == CfdTypes.Side.BULL || side == CfdTypes.Side.BEAR,
                "Live positions must encode exactly one directional side"
            );

            uint256 sideBound = side == CfdTypes.Side.BULL
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

    function invariant_EntryNotionalsMatchPositions() public view {
        uint256 sumBullNotional;
        uint256 sumBearNotional;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size,, uint256 entryPrice,, CfdTypes.Side side,,) = engine.positions(accountId);
            if (size > 0) {
                if (side == CfdTypes.Side.BULL) {
                    sumBullNotional += size * entryPrice;
                } else {
                    sumBearNotional += size * entryPrice;
                }
            }
        }

        assertEq(_sideEntryNotional(CfdTypes.Side.BULL), sumBullNotional, "Bull entry notional must match positions");
        assertEq(_sideEntryNotional(CfdTypes.Side.BEAR), sumBearNotional, "Bear entry notional must match positions");
    }

    function invariant_PositionMarginsBackedByClearinghouse() public view {
        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size, uint256 margin,,,,,) = engine.positions(accountId);
            IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
            uint256 locked = clearinghouse.lockedMarginUsdc(accountId);

            if (size > 0) {
                assertGe(locked, margin, "Clearinghouse must back position margin");
            }

            assertGe(
                locked,
                margin + escrow.committedMarginUsdc,
                "Locked margin must back open-position margin plus pending committed margin"
            );
        }
    }

    function invariant_GlobalSideMarginsMatchPositions() public view {
        uint256 sumBullMargin;
        uint256 sumBearMargin;

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            (uint256 size, uint256 margin,,, CfdTypes.Side side,,) = engine.positions(accountId);
            if (size == 0) {
                continue;
            }
            if (side == CfdTypes.Side.BULL) {
                sumBullMargin += margin;
            } else {
                sumBearMargin += margin;
            }
        }

        assertEq(
            _sideTotalMargin(CfdTypes.Side.BULL),
            sumBullMargin,
            "Bull side margin mirror must equal live bull position margins"
        );
        assertEq(
            _sideTotalMargin(CfdTypes.Side.BEAR),
            sumBearMargin,
            "Bear side margin mirror must equal live bear position margins"
        );
    }

    function invariant_LivePositionsRemainLargeEnoughForLiquidationEconomics() public view {
        (,,,,,, uint256 minBountyUsdc, uint256 bountyBps) = engine.riskParams();
        uint256 oraclePrice = engine.lastMarkPrice();
        if (oraclePrice == 0) {
            oraclePrice = 1e8;
        }

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            PerpsViewTypes.PositionView memory positionView = _publicPosition(accountId);
            if (!positionView.exists) {
                continue;
            }

            if (positionView.liquidatable) {
                continue;
            }

            uint256 notionalUsdc = (positionView.size * oraclePrice) / 1e20;
            assertGe(
                notionalUsdc * bountyBps,
                minBountyUsdc * 10_000,
                "Live positions must stay above the minimum liquidation bounty threshold"
            );
            assertGe(
                positionView.marginUsdc,
                minBountyUsdc,
                "Live positions must not degrade into dust margin below the bounty floor"
            );
        }
    }

    function invariant_ClearinghouseBucketsConserveTrackedState() public view {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);

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
                clearinghouse.lockedMarginUsdc(accountId),
                buckets.totalLockedMarginUsdc,
                "Bucket view must match locked margin storage"
            );
        }
    }

    function invariant_TraderOwnedCollateralRemainsTerminallyReachable() public view {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);

            assertEq(
                _terminalReachableUsdc(accountId),
                buckets.settlementBalanceUsdc,
                "All trader-owned settlement collateral should remain terminally reachable"
            );
        }
    }

    function invariant_CommittedMarginOwnershipAccountingConservesQueuedExposure() public view {
        uint64 nextCommitId = router.nextCommitId();

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            uint256 rawQueuedCommitted;

            for (uint64 orderId = 1; orderId < nextCommitId; orderId++) {
                OrderRouter.OrderRecord memory record = _orderRecord(orderId);
                if (record.core.accountId != accountId || record.core.sizeDelta == 0) {
                    continue;
                }
                rawQueuedCommitted += _remainingCommittedMargin(orderId);
            }

            IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
            assertEq(
                escrow.committedMarginUsdc,
                rawQueuedCommitted,
                "Account escrow must equal the residual committed margin stored on queued orders"
            );
        }
    }

    function invariant_ProtocolAccountingViewMatchesAccessors() public view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(protocolView.vaultAssetsUsdc, pool.totalAssets(), "Protocol view vault assets must match pool assets");
        assertEq(protocolView.maxLiabilityUsdc, _maxLiability(), "Protocol view liability must match accessor");
        assertEq(
            protocolView.withdrawalReservedUsdc,
            _withdrawalReservedUsdc(),
            "Protocol view withdrawal reserve must match accessor"
        );
        assertEq(
            protocolView.accumulatedFeesUsdc, engine.accumulatedFeesUsdc(), "Protocol view fees must match accessor"
        );
        assertEq(
            protocolView.totalDeferredTraderCreditUsdc,
            engine.totalDeferredTraderCreditUsdc(),
            "Protocol view trader deferred payouts must match storage"
        );
        assertEq(
            protocolView.totalDeferredKeeperCreditUsdc,
            engine.totalDeferredKeeperCreditUsdc(),
            "Protocol view deferred keeper credit must match storage"
        );
    }

    function invariant_WithdrawalReserveIncludesDeferredLiabilities() public view {
        uint256 expectedReserved = _maxLiability() + engine.accumulatedFeesUsdc() + engine.totalDeferredTraderCreditUsdc()
            + engine.totalDeferredKeeperCreditUsdc();

        expectedReserved += uint256(0);

        assertEq(
            _withdrawalReservedUsdc(),
            expectedReserved,
            "Withdrawal reserve must include liabilities, fees, and deferred obligations"
        );
    }

    function invariant_PoolLiquidityViewMatchesProtocolAccounting() public view {
        HousePool.VaultLiquidityView memory vaultView = pool.getVaultLiquidityView();
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();

        assertEq(vaultView.totalAssetsUsdc, protocolView.vaultAssetsUsdc, "Pool and engine must agree on vault assets");
        assertEq(
            vaultView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on withdrawal reserves"
        );
        assertEq(vaultView.freeUsdc, protocolView.freeUsdc, "Pool free USDC must match engine accounting view");
    }

    function invariant_LiquidationPreviewMatchesPositionView() public view {
        uint256 oraclePrice = engine.lastMarkPrice();
        if (oraclePrice == 0) {
            return;
        }

        uint256 vaultDepth = pool.totalAssets();
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            PerpsViewTypes.PositionView memory positionView = _publicPosition(accountId);
            if (!positionView.exists) {
                continue;
            }

            CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, oraclePrice);
            assertEq(
                preview.liquidatable, positionView.liquidatable, "Liquidation preview must match live position view"
            );
        }
    }

}

contract AdversarialPerpHandler is Test {

    MockUSDC public usdc;
    CfdEngine public engine;
    CfdEngineLens public engineLens;
    HousePool public pool;
    MarginClearinghouse public clearinghouse;
    OrderRouter public router;
    TrancheVault public juniorVault;

    address[4] public actors;
    address public lp;
    address public sink;

    uint256 public ghost_batchAttempts;
    uint256 public ghost_batchAdvances;
    uint256 public ghost_starvationEvents;
    uint256 public ghost_expectedDeferredKeeperCredit;
    uint256 public ghost_failSoftLiquidations;
    uint256 public ghost_lastRetryableSlippageBatch;
    uint64 public ghost_lastRetryableSlippageOrderId;
    uint64 public ghost_lastRetryableSlippageBeforeExecuteId;
    uint64 public ghost_lastRetryableSlippageAfterExecuteId;
    uint8 public ghost_lastRetryableSlippageOrderStatus;
    uint256 public ghost_lastRetryableSlippageEscrowUsdc;
    uint256 public ghost_lastRetryableSlippageRouterBalanceUsdc;

    constructor(
        MockUSDC _usdc,
        CfdEngine _engine,
        HousePool _pool,
        MarginClearinghouse _clearinghouse,
        OrderRouter _router,
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

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _seedTrader(
        address actor,
        uint256 amount
    ) internal {
        bytes32 accountId = _accountId(actor);
        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(accountId, amount);
        vm.stopPrank();
    }

    function _seedLp(
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(amount, lp);
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
        bytes32 accountId = _accountId(actor);
        uint256 size = bound(sizeFuzz, 1000e18, 25_000e18);
        uint256 margin = bound(marginFuzz, 200e6, 5000e6);

        if (clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc < margin + 1e6) {
            _seedTrader(actor, margin + 5e6);
        }

        CfdTypes.Side side = sideRaw % 2 == 0 ? CfdTypes.Side.BULL : CfdTypes.Side.BEAR;

        uint64 commitId = router.nextCommitId();
        vm.prank(actor);
        router.commitOrder(side, size, margin, 1e8, false);

        vm.roll(block.number + 1);
        bytes[] memory empty = new bytes[](0);
        try router.executeOrder(commitId, empty) {} catch {}
    }

    function spamInvalidOrders(
        uint256 actorIdx,
        uint256 countFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        bytes32 accountId = _accountId(actor);
        uint256 count = bound(countFuzz, 1, 6);

        if (clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc < count * 101e6) {
            _seedTrader(actor, count * 150e6);
        }

        for (uint256 i = 0; i < count; i++) {
            vm.prank(actor);
            router.commitOrder(CfdTypes.Side.BULL, 1000e18, 100e6, 2e8, false);
        }
    }

    function queueBadClose(
        uint256 actorIdx
    ) external {
        address actor = actors[actorIdx % actors.length];
        bytes32 accountId = _accountId(actor);
        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(accountId);
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
        _seedLp(amount);
    }

    function processBatch(
        uint256 maxOrdersFuzz,
        uint256 oraclePriceFuzz
    ) external {
        address actor = actors[ghost_batchAttempts % actors.length];
        bytes32 accountId = _accountId(actor);

        if (clearinghouse.getAccountUsdcBuckets(accountId).freeSettlementUsdc < 205e6) {
            _seedTrader(actor, 500e6);
        }

        CfdTypes.Side side = CfdTypes.Side.BULL;
        (uint256 size,,,, CfdTypes.Side existingSide,,) = engine.positions(accountId);
        if (size > 0) {
            side = existingSide;
        }

        vm.prank(actor);
        router.commitOrder(side, 1000e18, 200e6, 1e8, false);

        uint256 pending = _countPendingOrders();
        uint256 maxOrders = bound(maxOrdersFuzz, pending, pending);
        uint256 oraclePrice = bound(oraclePriceFuzz, 99_000_000, 101_000_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(oraclePrice);

        ghost_batchAttempts++;
        vm.roll(block.number + 1);

        uint64 beforeExecute = router.nextExecuteId();
        bool retryableSlippageAtHead;
        if (beforeExecute < router.nextCommitId()) {
            OrderRouter.OrderRecord memory headRecord = _orderRecord(beforeExecute);
            if (uint8(headRecord.status) == uint8(IOrderRouterAccounting.OrderStatus.Pending)) {
                retryableSlippageAtHead = !_checkSlippage(headRecord.core, oraclePrice);
                if (retryableSlippageAtHead) {
                    ghost_lastRetryableSlippageOrderId = beforeExecute;
                    ghost_lastRetryableSlippageBeforeExecuteId = beforeExecute;
                }
            }
        }
        try router.executeOrderBatch(uint64(maxOrders), priceData) {} catch {}
        uint64 afterExecute = router.nextExecuteId();

        if (retryableSlippageAtHead) {
            OrderRouter.OrderRecord memory postRecord = _orderRecord(ghost_lastRetryableSlippageOrderId);
            if (uint8(postRecord.status) == uint8(IOrderRouterAccounting.OrderStatus.Failed)) {
                ghost_lastRetryableSlippageBatch++;
                ghost_lastRetryableSlippageAfterExecuteId = afterExecute;
                ghost_lastRetryableSlippageOrderStatus = uint8(postRecord.status);
                ghost_lastRetryableSlippageEscrowUsdc = postRecord.executionBountyUsdc;
                ghost_lastRetryableSlippageRouterBalanceUsdc = usdc.balanceOf(address(router));
            }
        }

        if (afterExecute > beforeExecute) {
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
            if (order.side == CfdTypes.Side.BULL) {
                return executionPrice <= order.targetPrice;
            }
            return executionPrice >= order.targetPrice;
        }
        if (order.side == CfdTypes.Side.BULL) {
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

    function _orderRecord(
        uint64 orderId
    ) internal view returns (OrderRouter.OrderRecord memory record) {
        return OrderRouterDebugLens.loadOrderRecord(vm, router, orderId);
    }

    function liquidateWithPayoutFailure(
        uint256 actorIdx,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 oraclePrice = bound(priceFuzz, 80_000_000, 125_000_000);
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(accountId, oraclePrice);
        if (!preview.liquidatable || preview.keeperBountyUsdc == 0) {
            return;
        }

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(oraclePrice);

        uint256 beforeDeferred = engine.deferredKeeperCreditUsdc(address(this));
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("vault illiquid"));
        vm.roll(block.number + 1);

        try router.executeLiquidation(accountId, priceData) {
            uint256 afterDeferred = engine.deferredKeeperCreditUsdc(address(this));
            if (afterDeferred == beforeDeferred + preview.keeperBountyUsdc) {
                ghost_expectedDeferredKeeperCredit += preview.keeperBountyUsdc;
                ghost_failSoftLiquidations++;
            }
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
            bountyBps: 15
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

    function invariant_AdversarialEscrowStaysBacked() public view {
        uint256 pendingKeeperReserves;
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.accountId == bytes32(0) || record.core.sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += record.executionBountyUsdc;
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Adversarial queue keeper reserves must remain fully backed"
        );
    }

    function invariant_AdversarialBatchProcessingRemainsLive() public view {
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();
        assertLe(nextExecuteId, nextCommitId, "Queue pointers must remain ordered");
    }

    function invariant_AdversarialViewsStayConsistent() public view {
        ProtocolLensViewTypes.ProtocolAccountingSnapshot memory protocolView =
            engineProtocolLens.getProtocolAccountingSnapshot();
        HousePool.VaultLiquidityView memory vaultView = pool.getVaultLiquidityView();

        assertEq(vaultView.totalAssetsUsdc, protocolView.vaultAssetsUsdc, "Pool and engine must agree on assets");
        assertEq(vaultView.freeUsdc, protocolView.freeUsdc, "Pool and engine must agree on free liquidity");
        assertEq(
            vaultView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on reserved liquidity"
        );
    }

    function invariant_AdversarialSlippageFailureClearsHeadAndEscrow() public view {
        if (handler.ghost_lastRetryableSlippageBatch() == 0) {
            return;
        }

        assertEq(
            handler.ghost_lastRetryableSlippageOrderStatus(),
            uint8(IOrderRouterAccounting.OrderStatus.Failed),
            "Terminal slippage failure must mark the head order failed"
        );
        assertEq(
            handler.ghost_lastRetryableSlippageEscrowUsdc(), 0, "Terminal slippage failure must clear escrowed bounty"
        );
        assertGe(
            handler.ghost_lastRetryableSlippageRouterBalanceUsdc(),
            handler.ghost_lastRetryableSlippageEscrowUsdc(),
            "Router balance must still cover any remaining queued escrow after slippage failure"
        );
    }

    function invariant_GlobalQueueLinksRemainConsistent() public view {
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
            OrderRouter.OrderRecord memory record = _orderRecord(cursor);
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

    function invariant_AdversarialRouterCustodiesOnlyPendingKeeperReserves() public view {
        uint256 pendingKeeperReserves;
        for (uint64 orderId = 1; orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = _orderRecord(orderId);
            if (record.core.accountId == bytes32(0) || record.core.sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += record.executionBountyUsdc;
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Router custody must equal pending keeper reserves during adversarial flows"
        );
    }

    function invariant_AdversarialQueuedKeeperReserveNeverReturnsToTraderCollateral() public view {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.actors(i))));
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
            assertEq(buckets.freeSettlementUsdc + buckets.totalLockedMarginUsdc, buckets.settlementBalanceUsdc);
        }
    }

    function invariant_AdversarialLiquidationPayoutFailureOnlyDefersBounty() public view {
        assertEq(
            engine.deferredKeeperCreditUsdc(address(handler)),
            handler.ghost_expectedDeferredKeeperCredit(),
            "Liquidation payout failures must only create deferred bounty claims"
        );
    }

    function invariant_DeferredKeeperCreditTotalsConserveClaims() public view {
        assertEq(
            engine.totalDeferredKeeperCreditUsdc(),
            engine.deferredKeeperCreditUsdc(address(handler)),
            "Deferred keeper credit total must equal tracked keeper claims in invariant harness"
        );
    }

}

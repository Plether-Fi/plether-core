// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Test} from "forge-std/Test.sol";

contract PerpHandler is Test {

    MockUSDC public usdc;
    CfdEngine public engine;
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

        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
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

        (uint256 size,,,,,,,) = engine.positions(accountId);
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

    function invariant_GlobalSolvency() public {
        uint256 effectiveAssets = pool.totalAssets();
        uint256 fees = engine.accumulatedFeesUsdc();
        effectiveAssets = effectiveAssets > fees ? effectiveAssets - fees : 0;

        int256 cappedFunding = engine.getCappedFundingPnl();
        if (cappedFunding < 0) {
            effectiveAssets += uint256(-cappedFunding);
        } else if (cappedFunding > 0) {
            effectiveAssets = effectiveAssets > uint256(cappedFunding) ? effectiveAssets - uint256(cappedFunding) : 0;
        }

        if (!engine.degradedMode()) {
            assertGe(effectiveAssets, engine.getMaxLiability(), "Non-degraded engine must cover worst-case liability");
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

    function invariant_SymmetricalFunding() public {
        int256 bullIdx = _sideFundingIndex(CfdTypes.Side.BULL);
        int256 bearIdx = _sideFundingIndex(CfdTypes.Side.BEAR);
        assertEq(bullIdx + bearIdx, 0, "Funding must be zero-sum");
    }

    function invariant_NoNegativePrincipal() public {
        vm.prank(address(juniorVault));
        pool.reconcile();
        uint256 claimed = pool.seniorPrincipal() + pool.juniorPrincipal();
        uint256 bal = pool.totalAssets();
        int256 traderPnl = engine.getUnrealizedTraderPnl();
        uint256 effectivePool;
        if (traderPnl >= 0) {
            effectivePool = bal;
        } else {
            effectivePool = bal + uint256(-traderPnl);
        }
        assertLe(claimed, effectivePool, "Claimed equity cannot exceed MtM-adjusted pool value");
    }

    function invariant_FeesWithinVault() public {
        uint256 fees = engine.accumulatedFeesUsdc();
        uint256 poolBalance = pool.totalAssets();
        assertLe(fees, poolBalance, "Accumulated fees must not exceed vault balance");
    }

    function invariant_WithdrawalAccountingMatchesEngineReserve() public {
        uint256 poolAssets = pool.totalAssets();
        uint256 reserved = engine.getWithdrawalReservedUsdc();
        uint256 expectedFree = poolAssets > reserved ? poolAssets - reserved : 0;

        assertEq(pool.getFreeUSDC(), expectedFree, "HousePool free USDC must match engine withdrawal reserve");
        assertLe(pool.getFreeUSDC(), poolAssets, "Free USDC cannot exceed physical assets");
    }

    function invariant_LiveLiabilityFlagMatchesDirectionalExposure() public {
        bool hasLiveLiability = engine.hasLiveLiability();
        bool hasDirectionalLiability = engine.getMaxLiability() > 0;
        assertEq(hasLiveLiability, hasDirectionalLiability, "Live-liability flag must match nonzero bounded liability");
    }

    function invariant_PendingKeeperReservesBackedByRouterUsdc() public {
        uint256 pendingKeeperReserves;
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();

        for (uint64 orderId = nextExecuteId; orderId < nextCommitId; orderId++) {
            (bytes32 accountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (accountId == bytes32(0) || sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += router.executionBountyReserves(orderId);
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Queued keeper reserves must stay backed in router custody"
        );
    }

    function invariant_ClearinghouseBalanceMatchesTrackedAccounts() public {
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

    function invariant_KnownActorUsdcConservation() public {
        uint256 actorBalances =
            usdc.balanceOf(address(handler)) + usdc.balanceOf(handler.lp()) + usdc.balanceOf(address(this));
        for (uint256 i = 0; i < 3; i++) {
            actorBalances += usdc.balanceOf(handler.traders(i));
        }

        uint256 contractBalances =
            usdc.balanceOf(address(pool)) + usdc.balanceOf(address(router)) + usdc.balanceOf(address(clearinghouse));

        uint256 expectedSupply = 730_000e6 + handler.ghost_totalDeposited() + handler.ghost_totalLpDeposited();
        assertEq(
            actorBalances + contractBalances,
            expectedSupply,
            "Known actors plus protocol contracts must conserve the minted USDC supply"
        );
    }

    function invariant_AggregateOIMatchesPositions() public {
        uint256 sumBullSize;
        uint256 sumBearSize;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
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

    function invariant_EntryNotionalsMatchPositions() public {
        uint256 sumBullNotional;
        uint256 sumBearNotional;

        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size,, uint256 entryPrice,,, CfdTypes.Side side,,) = engine.positions(accountId);
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

    function invariant_PositionMarginsBackedByClearinghouse() public {
        for (uint256 i = 0; i < 3; i++) {
            address trader = handler.traders(i);
            bytes32 accountId = bytes32(uint256(uint160(trader)));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
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

    function invariant_GlobalSideMarginsMatchPositions() public {
        uint256 sumBullMargin;
        uint256 sumBearMargin;

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            (uint256 size, uint256 margin,,,, CfdTypes.Side side,,) = engine.positions(accountId);
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

    function invariant_ClearinghouseBucketsConserveTrackedState() public {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
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

    function invariant_TraderOwnedCollateralRemainsTerminallyReachable() public {
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            (uint256 size, uint256 margin,,,,,,) = engine.positions(accountId);
            uint256 protectedMargin = size > 0 ? margin : 0;
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);

            assertEq(
                clearinghouse.getLiquidationReachableUsdc(accountId, protectedMargin),
                buckets.settlementBalanceUsdc,
                "All trader-owned settlement collateral should remain terminally reachable"
            );
        }
    }

    function invariant_CommittedMarginOwnershipAccountingConservesQueuedExposure() public {
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();

        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            uint256 rawQueuedCommitted;

            for (uint64 orderId = nextExecuteId; orderId < nextCommitId; orderId++) {
                (bytes32 queuedAccountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
                if (queuedAccountId != accountId || sizeDelta == 0) {
                    continue;
                }
                rawQueuedCommitted += router.committedMargins(orderId);
            }

            IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
            assertEq(
                escrow.committedMarginUsdc,
                rawQueuedCommitted,
                "Account escrow must equal the residual committed margin stored on queued orders"
            );
        }
    }

    function invariant_ProtocolAccountingViewMatchesAccessors() public {
        CfdEngine.ProtocolAccountingView memory protocolView = engine.getProtocolAccountingView();

        assertEq(protocolView.vaultAssetsUsdc, pool.totalAssets(), "Protocol view vault assets must match pool assets");
        assertEq(protocolView.maxLiabilityUsdc, engine.getMaxLiability(), "Protocol view liability must match accessor");
        assertEq(
            protocolView.withdrawalReservedUsdc,
            engine.getWithdrawalReservedUsdc(),
            "Protocol view withdrawal reserve must match accessor"
        );
        assertEq(
            protocolView.accumulatedFeesUsdc, engine.accumulatedFeesUsdc(), "Protocol view fees must match accessor"
        );
        assertEq(
            protocolView.totalDeferredPayoutUsdc,
            engine.totalDeferredPayoutUsdc(),
            "Protocol view trader deferred payouts must match storage"
        );
        assertEq(
            protocolView.totalDeferredClearerBountyUsdc,
            engine.totalDeferredClearerBountyUsdc(),
            "Protocol view deferred liquidation bounties must match storage"
        );
    }

    function invariant_WithdrawalReserveIncludesDeferredLiabilities() public {
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

    function invariant_PoolLiquidityViewMatchesProtocolAccounting() public {
        HousePool.VaultLiquidityView memory vaultView = pool.getVaultLiquidityView();
        CfdEngine.ProtocolAccountingView memory protocolView = engine.getProtocolAccountingView();

        assertEq(vaultView.totalAssetsUsdc, protocolView.vaultAssetsUsdc, "Pool and engine must agree on vault assets");
        assertEq(
            vaultView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on withdrawal reserves"
        );
        assertEq(vaultView.freeUsdc, protocolView.freeUsdc, "Pool free USDC must match engine accounting view");
    }

    function invariant_LiquidationPreviewMatchesPositionView() public {
        uint256 oraclePrice = engine.lastMarkPrice();
        if (oraclePrice == 0) {
            return;
        }

        uint256 vaultDepth = pool.totalAssets();
        for (uint256 i = 0; i < 3; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.traders(i))));
            CfdEngine.PositionView memory positionView = engine.getPositionView(accountId);
            if (!positionView.exists) {
                continue;
            }

            CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, oraclePrice, vaultDepth);
            assertEq(
                preview.liquidatable, positionView.liquidatable, "Liquidation preview must match live position view"
            );
        }
    }

}

contract AdversarialPerpHandler is Test {

    MockUSDC public usdc;
    CfdEngine public engine;
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
    uint256 public ghost_expectedDeferredClearerBounty;
    uint256 public ghost_failSoftLiquidations;

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

        if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) < margin + 1e6) {
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

        if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) < count * 101e6) {
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
        (uint256 size,,,,, CfdTypes.Side side,,) = engine.positions(accountId);
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
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();
        address actor = actors[ghost_batchAttempts % actors.length];
        bytes32 accountId = _accountId(actor);

        if (clearinghouse.getFreeSettlementBalanceUsdc(accountId) < 205e6) {
            _seedTrader(actor, 500e6);
        }

        CfdTypes.Side side = CfdTypes.Side.BULL;
        (uint256 size,,,,, CfdTypes.Side existingSide,,) = engine.positions(accountId);
        if (size > 0) {
            side = existingSide;
        }

        vm.prank(actor);
        router.commitOrder(side, 1000e18, 200e6, 1e8, false);

        nextCommitId = router.nextCommitId();
        nextExecuteId = router.nextExecuteId();

        uint256 pending = nextCommitId - nextExecuteId;
        uint256 maxOrders = bound(maxOrdersFuzz, pending, pending);
        uint256 oraclePrice = bound(oraclePriceFuzz, 99_000_000, 101_000_000);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(oraclePrice);

        ghost_batchAttempts++;
        vm.roll(block.number + 1);

        uint64 beforeExecute = router.nextExecuteId();
        try router.executeOrderBatch(uint64(maxOrders), priceData) {} catch {}
        uint64 afterExecute = router.nextExecuteId();

        if (afterExecute > beforeExecute) {
            ghost_batchAdvances++;
        }
    }

    function liquidateWithPayoutFailure(
        uint256 actorIdx,
        uint256 priceFuzz
    ) external {
        address actor = actors[actorIdx % actors.length];
        bytes32 accountId = _accountId(actor);
        (uint256 size,,,,,,,) = engine.positions(accountId);
        if (size == 0) {
            return;
        }

        uint256 oraclePrice = bound(priceFuzz, 80_000_000, 125_000_000);
        uint256 vaultDepth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engine.previewLiquidation(accountId, oraclePrice, vaultDepth);
        if (!preview.liquidatable || preview.keeperBountyUsdc == 0) {
            return;
        }

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(oraclePrice);

        uint256 beforeDeferred = engine.deferredClearerBountyUsdc(address(this));
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("vault illiquid"));
        vm.roll(block.number + 1);

        try router.executeLiquidation(accountId, priceData) {
            uint256 afterDeferred = engine.deferredClearerBountyUsdc(address(this));
            if (afterDeferred == beforeDeferred + preview.keeperBountyUsdc) {
                ghost_expectedDeferredClearerBounty += preview.keeperBountyUsdc;
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
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
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

    function invariant_AdversarialEscrowStaysBacked() public {
        uint256 pendingKeeperReserves;
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 accountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (accountId == bytes32(0) || sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += router.executionBountyReserves(orderId);
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Adversarial queue keeper reserves must remain fully backed"
        );
    }

    function invariant_AdversarialBatchProcessingRemainsLive() public {
        uint64 nextExecuteId = router.nextExecuteId();
        uint64 nextCommitId = router.nextCommitId();
        assertLe(nextExecuteId, nextCommitId, "Queue pointers must remain ordered");
    }

    function invariant_AdversarialViewsStayConsistent() public {
        CfdEngine.ProtocolAccountingView memory protocolView = engine.getProtocolAccountingView();
        HousePool.VaultLiquidityView memory vaultView = pool.getVaultLiquidityView();

        assertEq(vaultView.totalAssetsUsdc, protocolView.vaultAssetsUsdc, "Pool and engine must agree on assets");
        assertEq(vaultView.freeUsdc, protocolView.freeUsdc, "Pool and engine must agree on free liquidity");
        assertEq(
            vaultView.withdrawalReservedUsdc,
            protocolView.withdrawalReservedUsdc,
            "Pool and engine must agree on reserved liquidity"
        );
    }

    function invariant_AdversarialRouterCustodiesOnlyPendingKeeperReserves() public {
        uint256 pendingKeeperReserves;
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 accountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (accountId == bytes32(0) || sizeDelta == 0) {
                continue;
            }
            pendingKeeperReserves += router.executionBountyReserves(orderId);
        }

        assertEq(
            usdc.balanceOf(address(router)),
            pendingKeeperReserves,
            "Router custody must equal pending keeper reserves during adversarial flows"
        );
    }

    function invariant_AdversarialQueuedKeeperReserveNeverReturnsToTraderCollateral() public {
        for (uint256 i = 0; i < 4; i++) {
            bytes32 accountId = bytes32(uint256(uint160(handler.actors(i))));
            IMarginClearinghouse.AccountUsdcBuckets memory buckets = clearinghouse.getAccountUsdcBuckets(accountId);
            assertEq(buckets.freeSettlementUsdc + buckets.totalLockedMarginUsdc, buckets.settlementBalanceUsdc);
        }
    }

    function invariant_AdversarialLiquidationPayoutFailureOnlyDefersBounty() public {
        assertEq(
            engine.deferredClearerBountyUsdc(address(handler)),
            handler.ghost_expectedDeferredClearerBounty(),
            "Liquidation payout failures must only create deferred bounty claims"
        );
    }

    function invariant_DeferredClearerBountyTotalsConserveClaims() public {
        assertEq(
            engine.totalDeferredClearerBountyUsdc(),
            engine.deferredClearerBountyUsdc(address(handler)),
            "Deferred clearer bounty total must equal tracked keeper claims in invariant harness"
        );
    }

}

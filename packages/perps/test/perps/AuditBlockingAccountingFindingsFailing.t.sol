// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterDebugLens} from "../utils/OrderRouterDebugLens.sol";

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineProtocolLens} from "@plether/perps/CfdEngineProtocolLens.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdMath} from "@plether/perps/CfdMath.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PerpsPublicLens} from "@plether/perps/PerpsPublicLens.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {CfdEnginePlanLib} from "@plether/perps/libraries/CfdEnginePlanLib.sol";
import {CfdEngineSnapshotsLib} from "@plether/perps/libraries/CfdEngineSnapshotsLib.sol";
import {MarginClearinghouseAccountingLib} from "@plether/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {SolvencyAccountingLib} from "@plether/perps/libraries/SolvencyAccountingLib.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract AuditBlockingAccountingFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);

    function test_H1_PlannerAppliedStateMustNotConsumeProtectedResidualMargin() public {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(60e6, 20e6, 30e6, 0);

        MarginClearinghouseAccountingLib.SettlementConsumption memory plan =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, 20e6, 40e6);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, 20e6, plan);

        assertEq(plan.freeSettlementConsumedUsdc, 10e6, "Plan should consume free settlement first");
        assertEq(plan.activeMarginConsumedUsdc, 0, "Protected residual margin must not be attributed as consumed");
        assertEq(
            plan.otherLockedMarginConsumedUsdc, 0, "Partial-close view must keep queued committed margin unreachable"
        );
        assertEq(
            mutation.settlementDebitUsdc, 10e6, "Applied settlement debit should stop at reachable free settlement"
        );
        assertEq(
            mutation.otherLockedMarginUnlockedUsdc,
            0,
            "Queued committed margin must remain locked in partial-close planning"
        );
    }

}

contract CfdEngineSolvencyTimingHarness is CfdEngine {

    constructor(
        address usdc,
        address clearinghouse,
        uint256 capPrice,
        CfdTypes.RiskParams memory params,
        uint256 frozenCloseSpreadBps
    ) CfdEngine(usdc, clearinghouse, capPrice, params, frozenCloseSpreadBps) {}

    function previewEffectiveAssetsWithoutMarginSync(
        CfdTypes.Order memory order
    )
        external
        returns (
            uint256 staleEffectiveAssets,
            uint256 syncedEffectiveAssets,
            uint256 staleSideMargin,
            uint256 syncedSideMargin
        )
    {
        order;
        staleEffectiveAssets = 0;
        syncedEffectiveAssets = 0;
        staleSideMargin = 0;
        syncedSideMargin = 0;
    }

}

contract AuditBlockingAccountingFindingsFailing_SolvencyTiming is BasePerpTest {

    address longTraderA = address(0xB011);
    address longTraderB = address(0xB012);
    address shortTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
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

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngineSolvencyTimingHarness(
            address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), FROZEN_CLOSE_SPREAD_BPS
        );
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlementSidecar = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlementSidecar), address(engineAdmin));
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        engineProtocolLens = new CfdEngineProtocolLens(address(engine));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));
        baseMockPyth = new MockPyth();
        bytes32[] memory baseFeedIds = _basePythFeedIds();
        baseMockPyth.setAllPrices(baseFeedIds, int64(100_000_000), int32(-8), SETUP_TIMESTAMP);

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        router = _deployLegacyOrderRouter(
            address(engine),
            address(engineLens),
            address(pool),
            address(
                new PletherOracle(
                    address(engine),
                    address(pool),
                    address(baseMockPyth),
                    baseFeedIds,
                    _basePythWeights(),
                    _basePythBasePrices(),
                    _basePythInversions()
                )
            )
        );
        _syncRouterAdmin();
        engine.setOrderRouter(address(router));
        publicLens = new PerpsPublicLens(address(engineAccountLens), address(engine), address(router), address(pool));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
    }

    function test_H2_SolvencyCheckInputsMustMatchCommittedPostOpSideMargins() public {
        _fundTrader(longTraderA, 15_000e6);
        _fundTrader(longTraderB, 400_000e6);
        _fundTrader(shortTrader, 100_000e6);

        address longIdA = longTraderA;
        address longIdB = longTraderB;
        address shortAccount = shortTrader;

        _open(longIdA, CfdTypes.Side.LONG, 390_000e18, 6500e6, 1e8);
        _open(longIdB, CfdTypes.Side.LONG, 10_000e18, 300_000e6, 1e8);
        _open(shortAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEngineSolvencyTimingHarness harness = CfdEngineSolvencyTimingHarness(address(engine));
        (
            uint256 staleEffectiveAssets,
            uint256 syncedEffectiveAssets,
            uint256 staleLongMargin,
            uint256 syncedLongMargin
        ) = harness.previewEffectiveAssetsWithoutMarginSync(
            CfdTypes.Order({
                account: longIdA,
                sizeDelta: 390_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.LONG,
                isClose: true
            })
        );

        assertEq(
            staleLongMargin,
            syncedLongMargin,
            "Solvency/degraded checks must use the same side margins that would be committed after carry realization"
        );
        assertEq(
            staleEffectiveAssets,
            syncedEffectiveAssets,
            "Solvency effective assets must not depend on stale in-flight side-margin totals"
        );
    }

}

contract AuditBlockingAccountingFindingsFailing_PartialCloseWithCommittedMargin is BasePerpTest {

    address trader = address(0xC106);
    address counterparty = address(0xBEA2);
    address constant KEEPER = address(0xC0FFEE);

    function test_H1_PartialCloseWithPendingOrderDoesNotRevert() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertGt(committedBefore, 0, "Should have committed margin from pending open order");

        uint256 freeSettlement = _freeSettlementUsdc(account);
        assertLt(freeSettlement, 1100e6, "Free settlement should be small after committing margin");

        _close(account, CfdTypes.Side.LONG, 50_000e18, 1.05e8);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 50_000e18, "Partial close should leave half the position");
    }

    function test_H1_PartialCloseLossLeavesQueuedCommittedMarginUntouched() public {
        address account = trader;
        address counterAccount = counterparty;

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertEq(committedBefore, 4000e6, "Committed margin should match order margin delta");
        uint256 pnlPledgeBefore = clearinghouse.pnlPledgeUsdc(account);

        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(account, 50_000e18, 1.08e8);

        assertTrue(preview.valid, "Dedicated price collateral should fund the partial-close loss");
        assertEq(preview.realizedPnlUsdc, -4000e6, "Fixture should realize a four-thousand USDC price loss");
        assertEq(
            preview.remainingMargin,
            pnlPledgeBefore / 2,
            "The retained half-position should keep its proportional dedicated PnL pledge"
        );
        assertEq(preview.badDebtUsdc, 0, "Any price-loss tail beyond the close slice's cap is a writeoff, not debt");

        _close(account, CfdTypes.Side.LONG, 50_000e18, 1.08e8);

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(sizeAfter, preview.remainingSize, "Live partial close should match the accepted preview");
        assertEq(marginAfter, preview.remainingMargin, "Live PnL pledge should match the accepted preview");
        assertEq(
            _remainingCommittedMargin(1),
            committedBefore,
            "Exact price settlement must not consume a queued order's committed margin"
        );
    }

    function test_H1_PartialClosePlannerViewKeepsQueuedCommittedMarginUnreachable() public {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(900e6, 100e6, 4000e6, 0);

        assertEq(
            buckets.settlementBalanceUsdc,
            0,
            "Planner partial-close view should exclude queued committed margin from settlement"
        );
        assertEq(buckets.freeSettlementUsdc, 0, "Excluded queued committed margin must not reappear as free settlement");
        assertEq(buckets.otherLockedMarginUsdc, 0, "Partial-close view should treat other locked margin as unreachable");
    }

}

contract AuditBlockingAccountingFindingsFailing_ReservedBounty is BasePerpTest {

    address trader = address(0xC200);
    address counterparty = address(0xBEA3);
    address constant KEEPER = address(0xC0FFEE);

    function _setupFullyUtilized() internal returns (address account, address counterAccount) {
        account = trader;
        counterAccount = counterparty;

        _fundTrader(trader, 5000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(account), 0, "Trader should be fully utilized before commit");
    }

    function _setupCloseBountyBacked() internal returns (address account, address counterAccount) {
        account = trader;
        counterAccount = counterparty;

        _fundTrader(trader, 5001e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        assertEq(
            _freeSettlementUsdc(account), 1e6, "Setup should leave one USDC of free settlement before close reservation"
        );
    }

    function test_H2_FullyUtilizedTraderCannotFundCloseOrderFromPositionMargin() public {
        (address account,) = _setupFullyUtilized();

        (, uint256 marginBefore,,,,,) = engine.positions(account);

        vm.prank(trader);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InsufficientFreeEquity.selector);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore, "Rejected close order must preserve the account's PnL pledge");
        assertEq(router.pendingOrderCounts(account), 0, "Rejected close order must not enter the FIFO queue");
        assertEq(router.nextCommitId(), 1, "Rejected close order must not consume an order id");
    }

    function test_H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        uint64 headOrderId = router.nextExecuteId();
        uint256 reservedBounty = _executionBountyReserve(headOrderId);
        uint256 freeSettlement = _freeSettlementUsdc(account);

        assertGe(
            reservedBounty + freeSettlement,
            200_000,
            "Head close order should be economically backed the moment it enters FIFO"
        );
        assertEq(
            _orderRecord(headOrderId).executionBountyUsdc,
            200_000,
            "Close orders should reserve the full bounty in clearinghouse custody"
        );
    }

    function test_H2_SlippageFailedHeadCloseCreditsKeeperInClearinghouseOnly() public {
        _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 90_000_000, true);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);

        bytes[] memory priceData = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(keeperBounty, 0, "Terminal slippage miss should not pay the keeper wallet");
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            200_000,
            "Terminal slippage miss should credit the clearer in clearinghouse custody"
        );
        assertEq(router.nextExecuteId(), 0, "Single queued slippage miss should clear the current head");
        assertEq(_executionBountyReserve(1), 0, "Reserved close bounty should be consumed on terminal slippage");
    }

    function test_H2_ExpiredHeadCloseMustStillPayKeeper() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: 60,
            orderExecutionStalenessLimit: router.pletherOracle().orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.pletherOracle().liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: router.pletherOracle().basketMaxConfidenceRatioBps(),
            orderSettlementWindow: router.pletherOracle().orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.pletherOracle().maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.pletherOracle().adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            positionProtectionCommitsEnabled: router.positionProtectionCommitsEnabled(),
            positionProtectionTriggerBountyUsdc: router.positionProtectionTriggerBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.warp(block.timestamp + 61);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        bytes[] memory priceData = _mockPythUpdateData();

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(
            keeperBounty, 0, "Expired head close should credit the clearer in clearinghouse custody, not the wallet"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            200_000,
            "Expired head close should still pay the configured bounty to the clearer"
        );

        assertEq(
            _freeSettlementUsdc(account),
            800_000,
            "Only the committed close bounty slice should leave prefunded free settlement"
        );
    }

    function test_H2_LiquidationWithQueuedCloseOrderTransfersOnlyReservedBounty() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.96e8);
        assertTrue(preview.liquidatable, "Setup should be liquidatable at the execution price");
        uint256 reservedSettlementBefore = clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc;
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 routerBalanceBefore = usdc.balanceOf(address(router));
        assertEq(reservedSettlementBefore, 200_000, "Queued close bounty should be reserved in clearinghouse custody");
        assertEq(routerBalanceBefore, 0, "Router should not custody queued close bounties");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.96e8));

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Position should be liquidated");

        assertEq(
            usdc.balanceOf(address(router)),
            routerBalanceBefore,
            "Router should remain out of bounty custody on liquidation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            0,
            "Queued close bounty reservation should be cleared on liquidation"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Keeper should receive only the liquidation bounty as a clearinghouse credit"
        );

        OrderRouterDebugLens.OrderRecord memory record = _orderRecord(1);
        assertEq(record.executionBountyUsdc, 0, "Reserved bounty should be cleared on liquidation");
    }

    function test_H2_OpenOrderStillRevertsWhenFullyUtilized() public {
        _setupFullyUtilized();

        vm.prank(trader);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.LONG, 1e18, 0, type(uint256).max, false);
    }

}

contract AuditBlockingAccountingFindingsFailing_StaleSeniorCoupon is BasePerpTest {

    address seniorLp = address(0xA11CE);
    address juniorLp = address(0xB0B);

    function test_L1_FinalizeSeniorRate_StaleMarkMustNotApplyRateChange() public {
        address trader = address(0x3333);
        address traderAccount = trader;

        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        IHousePool.PoolConfig memory config = _currentPoolConfig();
        config.seniorRateBps = 1600;
        pool.proposePoolConfig(config);
        vm.warp(block.timestamp + 48 hours + 121);
        vm.expectRevert(IHousePool.HousePool__MarkPriceStale.selector);
        pool.finalizePoolConfig();

        assertEq(pool.seniorRateBps(), 800, "Rejected stale finalization should leave the prior coupon rate in place");
    }

}

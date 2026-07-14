// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Audit-history file: tests prefixed with `obsolete_` preserve superseded findings for context only.
// They are intentionally not statements about the live carry model or current accounting semantics.

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "@plether/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouter} from "@plether/perps/interfaces/IOrderRouter.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract AuditConfirmedFindingsFailing_StaleKeeperFee is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function test_C1_ExpiredOpenBatchExecutionPaysClearerFromReservedBounty() public {
        uint256 t0 = 2_000_000_000;
        vm.warp(t0);
        vm.roll(100);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        vm.warp(t0 + 61);
        vm.roll(200);
        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), t0 + 1, t0);

        uint256 keeperBalanceBefore = _settlementBalance(keeper);
        uint256 aliceBalanceBefore = _settlementBalance(alice);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(1, updateData);

        assertEq(
            _settlementBalance(keeper) - keeperBalanceBefore,
            pending.executionBountyUsdc,
            "Expired open orders should pay the clearer so bad head orders remain economical to prune"
        );
        assertEq(
            aliceBalanceBefore - _settlementBalance(alice),
            pending.executionBountyUsdc,
            "Expired open orders should consume the submitting trader's reserved bounty"
        );
    }

    function test_C1_BatchMixedExpiredAndSuccessPaysReservedBounties() public {
        _fundTrader(alice, 50_000e6);

        uint256 t0 = 2_000_000_000;

        vm.warp(t0);
        vm.roll(100);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 10);
        vm.roll(200);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 10);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 10);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 61);
        vm.roll(300);
        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), t0 + 11, t0);

        (IOrderRouterAccounting.PendingOrderView memory firstPending, uint64 nextAfterFirst) =
            router.getPendingOrderView(1);
        (IOrderRouterAccounting.PendingOrderView memory secondPending,) = router.getPendingOrderView(nextAfterFirst);

        uint256 keeperUsdcBefore = _settlementBalance(keeper);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(
            _settlementBalance(keeper) - keeperUsdcBefore,
            400_000,
            "Batch execution should compensate the clearer from both reserved order bounties"
        );
        assertGt(firstPending.executionBountyUsdc, 0, "Expired open should still have reserved a positive bounty");
        assertGt(
            secondPending.executionBountyUsdc, 0, "Queued successor open should still have reserved a positive bounty"
        );
    }

    function test_C1_StaleSingleExecuteRefundsUserNotKeeper() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 keeperBalanceBefore = keeper.balance;

        vm.warp(1001);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, updateData);

        assertEq(keeper.balance, keeperBalanceBefore, "Keeper should not collect fee when cancelling a stale order");
    }

}

contract AuditConfirmedFindingsFailing_OutOfOrderMarkCancellation is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function test_H2_OlderButFreshSingleExecutionMustLeaveOrderPending() public {
        vm.warp(1000);
        vm.roll(100);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, 1020);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.warp(1025);
        vm.roll(101);
        vm.prank(keeper);
        router.executeOrder(1, updateData);

        assertEq(router.nextExecuteId(), 0, "Historical execution should consume the order");
        assertEq(engine.lastMarkTime(), 1020, "Historical execution must not roll back the live mark");
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore, "Keeper reward is credited in clearinghouse settlement");
    }

    function test_H2_OlderButFreshBatchExecutionMustLeaveQueuedOrdersPending() public {
        vm.warp(1000);
        vm.roll(100);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 20_000e18, 500e6, 1e8, false);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, 1020);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.warp(1025);
        vm.roll(101);
        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(router.nextExecuteId(), 0, "Batch historical execution should consume covered orders");
        assertEq(engine.lastMarkTime(), 1020, "Batch historical execution must not roll back the live mark");
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore, "Keeper reward is credited in clearinghouse settlement");
    }

}

contract AuditConfirmedFindingsFailing_HwmRouteConsistency is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_PostWipeoutRequiresExplicitRecapForHwmReset() public {
        uint256 seedAssets = 50_000e6;
        uint256 recapAmount = 10_000e6;
        address seed = address(0xBEEF);

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(pool), seedAssets);
        pool.initializeSeedPosition(true, seedAssets, seed);

        usdc.burn(address(pool), pool.totalAssets());
        vm.prank(address(juniorVault));
        pool.reconcile();

        usdc.mint(address(seniorVault), recapAmount);
        vm.startPrank(address(seniorVault));
        usdc.approve(address(pool), recapAmount);
        vm.expectRevert(IHousePool.HousePool__SeniorImpaired.selector);
        pool.depositSenior(recapAmount);
        vm.stopPrank();

        usdc.mint(address(pool), recapAmount);
        vm.prank(address(engine));
        pool.recordClaimantInflow(
            recapAmount, IHousePool.ClaimantInflowKind.Recapitalization, IHousePool.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(juniorVault));
        pool.reconcile();

        assertEq(pool.seniorPrincipal(), recapAmount, "Explicit recapitalization should restore senior principal");
        assertEq(pool.seniorHighWaterMark(), recapAmount, "Explicit recapitalization should reset the HWM");
    }

}

contract AuditConfirmedFindingsFailing_TrancheCooldownGrief is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_H1_ThirdPartyDustDepositToExistingHolderReverts() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        uint256 minimumDeposit = pool.minTrancheDepositUsdc();
        usdc.mint(attacker, minimumDeposit);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), minimumDeposit);
        vm.expectRevert(TrancheVault.TrancheVault__ThirdPartyDepositForExistingHolder.selector);
        juniorVault.deposit(minimumDeposit, alice);
        vm.stopPrank();
    }

}

contract AuditConfirmedFindingsFailing_RiskParams is BasePerpTest {

    function obsolete_M1_ProposeRiskParamsRejectsEqualKinkAndMaxSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        params.maxSkewRatio = params.maxSkewRatio;
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

    function obsolete_M1_ProposeRiskParamsRejectsZeroKinkSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

    function obsolete_M1_ProposeRiskParamsRejectsKinkAboveMaxSkew() public {
        CfdTypes.RiskParams memory params = _riskParams();
        ICfdEngineAdminHost.EngineRiskConfig memory config;
        config.riskParams = params;
        config.executionFeeBps = engine.executionFeeBps();
        vm.expectRevert();
        engineAdmin.proposeRiskConfig(config);
    }

}

contract AuditConfirmedFindingsFailing_LegacySpreadReserve is BasePerpTest {

    address bullTrader = address(0xB011);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function obsolete_C2_GetFreeUsdcMustReserveCappedLegacySpreadLiability() public {
        _fundJunior(address(this), 1_000_000e6);

        _fundTrader(bullTrader, 20_000e6);
        _fundTrader(bearTrader, 100_000e6);

        address bullAccount = bullTrader;
        address bearAccount = bearTrader;

        _open(bullAccount, CfdTypes.Side.BULL, 400_000e18, 10_000e6, 1e8);
        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        (uint256 bullSize, uint256 bullMargin, uint256 bullEntryPrice,, CfdTypes.Side bullSide,,) =
            engine.positions(bullAccount);
        (uint256 bearSize, uint256 bearMargin, uint256 bearEntryPrice,, CfdTypes.Side bearSide,,) =
            engine.positions(bearAccount);

        CfdTypes.Position memory bullPos = CfdTypes.Position({
            size: bullSize,
            margin: bullMargin,
            entryPrice: bullEntryPrice,
            maxProfitUsdc: 0,
            side: bullSide,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });
        CfdTypes.Position memory bearPos = CfdTypes.Position({
            size: bearSize,
            margin: bearMargin,
            entryPrice: bearEntryPrice,
            maxProfitUsdc: 0,
            side: bearSide,
            lastUpdateTime: 0,
            lastCarryTimestamp: 0,
            vpiAccrued: 0
        });

        int256 bullLegacySpread = 0;
        int256 bearLegacySpread = 0;
        assertLt(bullLegacySpread, -int256(bullMargin), "Setup must make bull legacy-spread debt exceed backing margin");
        assertGt(bearLegacySpread, 0, "Setup must leave the bear side owed legacy spread");

        int256 cappedLegacySpread = bearLegacySpread;
        assertGt(cappedLegacySpread, 0, "Positive legacy-spread liabilities should be fully reserved");

        uint256 bal = usdc.balanceOf(address(pool));
        uint256 maxLiability = _sideMaxProfit(CfdTypes.Side.BULL);
        uint256 pendingFees = clearinghouse.balanceUsdc(engine.protocolTreasury());
        uint256 expectedReserved = maxLiability + pendingFees + uint256(cappedLegacySpread);
        uint256 expectedFree = bal > expectedReserved ? bal - expectedReserved : 0;

        assertEq(
            pool.getFreeUSDC(),
            expectedFree,
            "Free USDC should reserve positive legacy-spread liabilities without netting against uncollectible debt"
        );
    }

}

contract AuditConfirmedFindingsFailing_EntryNotionalRounding is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1,
            bountyBps: 10
        });
    }

    function test_H2_ScalingLargePositionWithDustIncreaseUsesResultingNotionalFloor() public {
        address account = address(uint160(1));
        _fundTrader(account, 10_000e6);

        vm.startPrank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: 1000e18,
                marginDelta: 2000e6,
                targetPrice: 150_000_001,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 1,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            150_000_001,
            pool.totalAssets(),
            uint64(block.timestamp)
        );

        engine.processOrderTyped(
            CfdTypes.Order({
                account: account,
                sizeDelta: 1,
                marginDelta: 0,
                targetPrice: 150_000_000,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 2,
                side: CfdTypes.Side.BULL,
                isClose: false
            }),
            150_000_000,
            pool.totalAssets(),
            uint64(block.timestamp)
        );
        vm.stopPrank();

        (uint256 size,, uint256 entryPrice,,,,) = engine.positions(account);
        assertEq(size, 1000e18 + 1, "Same-side dust increase should grow an already-valid live position");
        assertEq(
            _sideEntryNotional(CfdTypes.Side.BULL),
            size * entryPrice,
            "Side entry notional must stay aligned with the resulting live position"
        );
    }

}

contract AuditConfirmedFindingsFailing_OpenSkewCap is BasePerpTest {

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.15e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10
        });
    }

    function test_C3_OpenSkewCapMustUseSingleSizeDelta() public {
        address bearTrader = address(0xBEA2);
        address bullTrader = address(0xB011);

        address bearAccount = bearTrader;
        address bullAccount = bullTrader;

        _fundTrader(bearTrader, 60_000e6);
        _fundTrader(bullTrader, 120_000e6);

        _open(bearAccount, CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8);
        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        _open(bullAccount, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        (uint256 bullSize,,,,,,) = engine.positions(bullAccount);
        assertEq(bullSize, 200_000e18, "Open-path skew cap should use the intended post-trade skew");
    }

}

contract AuditConfirmedFindingsFailing_KeeperReserveLiquidation is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C4_KeeperFeeReserveMustReduceLiquidationEquity() public {
        address account = trader;
        _fundTrader(trader, 200e6);

        _open(account, CfdTypes.Side.BULL, 10_000e18, 160e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0, true);

        uint256 poolDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(account, 100_530_000, poolDepth, uint64(block.timestamp), address(this));
    }

}

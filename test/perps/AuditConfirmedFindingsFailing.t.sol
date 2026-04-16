// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

// Audit-history file: tests prefixed with `obsolete_` preserve superseded findings for context only.
// They are intentionally not statements about the live carry model or current accounting semantics.

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {ICfdEngineAdminHost} from "../../src/perps/interfaces/ICfdEngineAdminHost.sol";
import {ICfdEngine} from "../../src/perps/interfaces/ICfdEngine.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {ICfdVault} from "../../src/perps/interfaces/ICfdVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        engine.setVault(address(pool));

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
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function test_C1_BatchExecuteShouldRefundUserNotKeeper() public {
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
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 61);

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
            _settlementBalance(alice) - aliceBalanceBefore,
            0,
            "Expired open orders should not refund the reserved bounty to the submitting trader"
        );
    }

    function test_C1_BatchMixedSuccessOnlyPaysKeeperForSuccessful() public {
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
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 61);

        (IOrderRouterAccounting.PendingOrderView memory firstPending, uint64 nextAfterFirst) = router.getPendingOrderView(1);
        (IOrderRouterAccounting.PendingOrderView memory secondPending,) = router.getPendingOrderView(nextAfterFirst);

        uint256 keeperUsdcBefore = _settlementBalance(keeper);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(
            _settlementBalance(keeper) - keeperUsdcBefore,
            firstPending.executionBountyUsdc + secondPending.executionBountyUsdc,
            "Batch execution should pay the keeper for both expired and successful head orders"
        );
    }

    function test_C1_StaleSingleExecuteShouldRefundUserNotKeeper() public {
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
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
        engine.setVault(address(pool));

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
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 9));
        router.executeOrder(1, updateData);

        assertEq(router.nextExecuteId(), 1, "Out-of-order keeper input must not consume the order");
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore, "Keeper must not be paid for an out-of-order mark");
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
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 9));
        router.executeOrderBatch(2, updateData);

        assertEq(router.nextExecuteId(), 1, "Batch execution must not burn queued orders on out-of-order marks");
        assertEq(
            usdc.balanceOf(keeper), keeperUsdcBefore, "Keeper must not be paid for failed out-of-order batch execution"
        );
    }

}

contract AuditConfirmedFindingsFailing_HwmRouteConsistency is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function _initialSeniorSeedDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_M1_PostWipeoutRecapPathMustMatchDepositPathHwmSemantics() public {
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
        pool.depositSenior(recapAmount);
        vm.stopPrank();

        uint256 depositRouteHwm = pool.seniorHighWaterMark();
        assertEq(depositRouteHwm, recapAmount, "Deposit route should establish the baseline post-wipeout HWM");

        HousePool recapPool = new HousePool(address(usdc), address(engine));
        TrancheVault recapSeniorVault =
            new TrancheVault(IERC20(address(usdc)), address(recapPool), true, "Plether Senior LP", "seniorUSDC");
        TrancheVault recapJuniorVault =
            new TrancheVault(IERC20(address(usdc)), address(recapPool), false, "Plether Junior LP", "juniorUSDC");
        recapPool.setSeniorVault(address(recapSeniorVault));
        recapPool.setJuniorVault(address(recapJuniorVault));

        usdc.mint(address(this), seedAssets);
        usdc.approve(address(recapPool), seedAssets);
        recapPool.initializeSeedPosition(true, seedAssets, seed);

        usdc.burn(address(recapPool), recapPool.totalAssets());
        vm.prank(address(recapJuniorVault));
        recapPool.reconcile();

        usdc.mint(address(recapPool), recapAmount);
        vm.prank(address(engine));
        recapPool.recordClaimantInflow(
            recapAmount, ICfdVault.ClaimantInflowKind.Recapitalization, ICfdVault.ClaimantInflowCashMode.CashArrived
        );
        vm.prank(address(recapJuniorVault));
        recapPool.reconcile();

        assertEq(
            recapPool.seniorHighWaterMark(),
            depositRouteHwm,
            "Governance recap and direct deposit should share the same post-wipeout HWM semantics"
        );
    }

}

contract AuditConfirmedFindingsFailing_TrancheCooldownGrief is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_H1_ThirdPartyDustDepositToExistingHolderMustNotResetVictimCooldown() public {
        _fundJunior(alice, 100_000e6);

        vm.warp(block.timestamp + 50 minutes);

        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(juniorVault), 1);
        juniorVault.deposit(1, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 11 minutes);
        vm.prank(alice);
        juniorVault.withdraw(100_000e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 100_000e6, "Victim should be able to withdraw after their original cooldown");
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

        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _open(bullId, CfdTypes.Side.BULL, 400_000e18, 10_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        (uint256 bullSize, uint256 bullMargin, uint256 bullEntryPrice,, CfdTypes.Side bullSide,,) =
            engine.positions(bullId);
        (uint256 bearSize, uint256 bearMargin, uint256 bearEntryPrice,, CfdTypes.Side bearSide,,) =
            engine.positions(bearId);

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
        uint256 pendingFees = engine.accumulatedFeesUsdc();
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

    function test_H2_ScalingLargePositionWithDustIncreaseUsesTypedFailure() public {
        bytes32 accountId = bytes32(uint256(1));
        _fundTrader(address(uint160(uint256(accountId))), 10_000e6);

        vm.startPrank(address(router));
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: accountId,
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

        uint256 depth = pool.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(ICfdEngine.CfdEngine__TypedOrderFailure.selector, 1, 3, false));
        engine.processOrderTyped(
            CfdTypes.Order({
                accountId: accountId,
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
            depth,
            uint64(block.timestamp)
        );
        vm.stopPrank();
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

        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));
        bytes32 bullId = bytes32(uint256(uint160(bullTrader)));

        _fundTrader(bearTrader, 60_000e6);
        _fundTrader(bullTrader, 120_000e6);

        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8);
        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        _open(bullId, CfdTypes.Side.BULL, 100_000e18, 20_000e6, 1e8);

        (uint256 bullSize,,,,,,) = engine.positions(bullId);
        assertEq(bullSize, 200_000e18, "Open-path skew cap should use the intended post-trade skew");
    }

}

contract AuditConfirmedFindingsFailing_KeeperReserveLiquidation is BasePerpTest {

    address trader = address(0xA11CE);

    function test_C4_KeeperFeeReserveMustReduceLiquidationEquity() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 200e6);

        _open(accountId, CfdTypes.Side.BULL, 10_000e18, 160e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 0, 0, true);

        uint256 vaultDepth = pool.totalAssets();
        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(accountId, 100_530_000, vaultDepth, uint64(block.timestamp));
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";

import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";

import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";

import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract KeeperFeeRefundTest is RecordedOrderReceipts {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    LegacyOrderRouterHarness router;
    OrderRouterAdmin routerAdmin;
    MockPyth mockPyth;
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] basePrices;
    bool[] inversions;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    function _accountOf(
        address account
    ) internal pure returns (address) {
        return account;
    }

    function _settlementBalance(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.balanceUsdc(_accountOf(account));
    }

    receive() external payable {}

    function _mockPythUpdateData() internal returns (bytes[] memory updateData) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 publishTime = _mockHistoricalPublishTime();
        mockPyth.setAllUniquePrices(
            feedIds, int64(100_000_000), 0, int32(-8), publishTime, publishTime == 0 ? 0 : publishTime - 1
        );
        updateData = new bytes[](1);
        updateData[0] = abi.encode(uint256(1e8));
    }

    function _mockHistoricalPublishTime() internal view returns (uint256 publishTime) {
        publishTime = block.timestamp;
        uint64 nextOrderId = router.nextExecuteId();
        if (nextOrderId == 0) {
            return publishTime;
        }

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(nextOrderId);
        uint256 candidate = uint256(pending.commitTime) + 1;
        if (pending.orderId != 0 && candidate <= block.timestamp) {
            publishTime = candidate;
        }
    }

    function _missingHistoricalUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = abi.encode(uint256(1e8));
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        uint256 requestId = juniorVault.requestDeposit(amount, lp, lp);
        vm.stopPrank();

        vm.warp(pool.lpEpochStart(requestId));
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
        pool.settleLpEpoch(0, 0);

        uint256 claimableAssets = juniorVault.claimableDepositRequest(requestId, lp);
        vm.prank(lp);
        juniorVault.claimDeposit(requestId, claimableAssets, lp, lp);
    }

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _configureBroadSeniorCapacity() internal {
        IHousePool.PoolConfig memory config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: type(uint256).max - 1,
            maxSeniorShareBps: 9999
        });
        pool.proposePoolConfig(config);
        _warpPastTimelock();
        pool.finalizePoolConfig();
    }

    function _bootstrapSeededLifecycle() internal {
        uint256 seedAmount = 1000e6;
        usdc.mint(address(this), seedAmount * 2);
        usdc.approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        engine.setTerminalNavBook(address(new TerminalNavBookV2(address(engine), uint32(CAP_PRICE))));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(bytes32(uint256(1)));
        feedIds.push(bytes32(uint256(2)));
        weights.push(0.5e18);
        weights.push(0.5e18);
        basePrices.push(1e8);
        basePrices.push(1e8);
        inversions.push(false);
        inversions.push(false);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);

        CfdEngineLens testEngineLens = new CfdEngineLens(address(engine));
        PletherOracle testOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, basePrices, inversions
        );
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new LegacyOrderRouterHarness(
            address(engine),
            address(testEngineLens),
            address(pool),
            address(testOracle),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(router), predictedRouter);
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));

        _configureBroadSeniorCapacity();
        IOrderRouterAdminHost.RouterConfig memory config;
        config.maxExecutionWindowSeconds = 300;
        config.orderExecutionStalenessLimit = router.pletherOracle().orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = router.pletherOracle().liquidationStalenessLimit();
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalUsdc = router.minOpenNotionalUsdc();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyUsdc = router.minOpenOrderExecutionBountyUsdc();
        config.maxOpenOrderExecutionBountyUsdc = router.maxOpenOrderExecutionBountyUsdc();
        config.closeOrderExecutionBountyUsdc = router.closeOrderExecutionBountyUsdc();
        config.positionProtectionTriggerBountyUsdc = router.positionProtectionTriggerBountyUsdc();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
        routerAdmin.proposeRouterConfig(config);
        _warpPastTimelock();
        clearinghouse.setEngine(address(engine));
        routerAdmin.finalizeRouterConfig();
        _bootstrapSeededLifecycle();

        _fundJunior(bob, 1_000_000e6);
        assertEq(router.openOrderExecutionBountyBps(), 1);
        assertEq(router.maxOpenOrderExecutionBountyUsdc(), 200_000);
    }

    function test_ExpiredOrderCreditsClearerAndReleasesMargin() public {
        _runExpiryCleanup(1, false, true);
    }

    function test_ExpiredHeadOrderPrunesWithoutHistoricalOracle() public {
        _runExpiryCleanup(1, false, false);
    }

    function test_BatchExpiredHeadOrdersPruneWithoutHistoricalOracle() public {
        _runExpiryCleanup(2, true, false);
    }

    function test_OpenSlippagePaysReservedBountyToClearer() public {
        _startRecordingLogs();
        _fundJunior(bob, 1_000_000e6);
        _depositTrader(50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1.5e8, false);
        uint256 cashBefore = usdc.balanceOf(address(clearinghouse));
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        bytes[] memory priceData = _mockPythUpdateData();
        vm.prank(keeper);
        router.executeOrder(1, priceData);
        assertEq(_settlementBalance(alice), 50_000e6 - 200_000, "only the stored bounty leaves trader settlement");
        assertEq(_settlementBalance(keeper), 200_000, "clearer receives the full reserved bounty");
        assertEq(
            _settlementBalance(engine.protocolTreasury()), treasuryBefore, "slippage bounty is not protocol revenue"
        );
        assertEq(usdc.balanceOf(address(clearinghouse)), cashBefore, "slippage cleanup preserves physical custody");
        assertEq(usdc.balanceOf(address(pool)), poolBefore, "rejected open cannot move pool cash");
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0, "rejected open cannot create a position");
        _assertTerminalCleanup(1, OrderV3Types.TerminalReason.Slippage);
        _assertCleanupReplayRejected(1, false);
    }

    function test_CloseSlippageFailPaysFreeBackedBountyToKeeper() public {
        _startRecordingLogs();
        address account = alice;
        usdc.mint(alice, 251_500_000);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), 251_500_000);
        clearinghouse.deposit(account, 251_500_000);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 250e6, 1e8, false);
        bytes[] memory openPrice = _mockPythUpdateData();
        router.executeOrder(1, openPrice);

        uint256 freeSettlementBefore = clearinghouse.getAccountUsdcBuckets(account).freeSettlementUsdc;
        assertEq(
            freeSettlementBefore, 1_300_000, "Setup should leave only partial free settlement before the close commit"
        );

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0.8e8, true);

        uint256 keeperUsdcBefore = _settlementBalance(keeper);
        uint256 protocolFeesBefore = clearinghouse.balanceUsdc(engine.protocolTreasury());
        bytes[] memory closePrice = _mockPythUpdateData();
        vm.prank(keeper);
        router.executeOrder(2, closePrice);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 10_000e18, "Terminal slippage failure should leave the position open");
        assertEq(
            _settlementBalance(keeper) - keeperUsdcBefore,
            200_000,
            "Terminal close slippage should still pay the clearer through the carry-aware settlement path"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()) - protocolFeesBefore,
            0,
            "Terminal close slippage should not additionally route bounty value to protocol fees in this path"
        );
        assertEq(usdc.balanceOf(alice), 0, "Trader wallet should not receive free-backed close bounty refunds");
        _assertTerminalCleanup(2, OrderV3Types.TerminalReason.Slippage);
        _assertCleanupReplayRejected(2, false);
    }

    function test_BatchExpiryCreditsEachStoredBountyExactlyOnce() public {
        _runExpiryCleanup(2, true, true);
    }

    function _depositTrader(
        uint256 amount
    ) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(alice, amount);
        vm.stopPrank();
    }

    function _runExpiryCleanup(
        uint64 count,
        bool batch,
        bool historicalDataAvailable
    ) internal {
        _startRecordingLogs();
        _depositTrader(50_000e6);
        for (uint64 id; id < count; ++id) {
            vm.prank(alice);
            router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        }
        assertEq(router.getAccountReservations(alice).committedMarginUsdc, uint256(count) * 1000e6);
        assertEq(router.getAccountReservations(alice).executionBountyUsdc, uint256(count) * 200_000);
        uint256 cashBefore = usdc.balanceOf(address(clearinghouse));
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = _settlementBalance(engine.protocolTreasury());
        uint256 parseCallsBefore = mockPyth.parseUniqueCallCount();
        vm.warp(block.timestamp + 301);
        vm.roll(block.number + 1);
        bytes[] memory data = historicalDataAvailable ? _mockPythUpdateData() : _missingHistoricalUpdateData();
        vm.prank(keeper);
        if (batch) {
            router.executeOrderBatch(count, data);
        } else {
            router.executeOrder(count, data);
        }

        assertEq(
            _settlementBalance(alice),
            50_000e6 - uint256(count) * 200_000,
            "only stored bounties debit trader settlement"
        );
        assertEq(_settlementBalance(keeper), uint256(count) * 200_000, "each expired order pays the clearer once");
        assertEq(_settlementBalance(engine.protocolTreasury()), treasuryBefore, "expiry does not fund protocol fees");
        assertEq(usdc.balanceOf(address(clearinghouse)), cashBefore, "expiry only transfers internal cash ownership");
        assertEq(usdc.balanceOf(address(pool)), poolBefore, "expiry does not route physical cash to the pool");
        assertEq(usdc.balanceOf(alice), 0, "reservation release does not send USDC to the trader wallet");
        assertEq(usdc.balanceOf(keeper), 0, "keeper entitlement remains in clearinghouse custody");
        assertEq(mockPyth.parseUniqueCallCount(), parseCallsBefore, "expiry bypasses historical oracle parsing");
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0, "expired opens cannot create a position");
        for (uint64 id = 1; id <= count; ++id) {
            _assertTerminalCleanup(id, OrderV3Types.TerminalReason.Expired);
        }
        _assertCleanupReplayRejected(count, batch);
    }

    function _assertTerminalCleanup(
        uint64 id,
        OrderV3Types.TerminalReason reason
    ) internal {
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), id);
        assertEq(outcome.account, alice);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(reason));
        assertEq(uint8(outcome.bountyDisposition), uint8(OrderV3Types.BountyDisposition.Paid));
        assertEq(outcome.executor, keeper);
        assertEq(outcome.bountyRecipient, keeper);
        assertEq(outcome.bountyUsdc, 200_000, "configured stored execution bounty");
        assertEq(router.lifecycleBook().pendingIntent(id).account, address(0));
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(id);
        assertEq(pending.committedMarginUsdc, 0);
        assertEq(pending.executionBountyUsdc, 0);
        IOrderRouterAccounting.AccountReservationView memory reserves = router.getAccountReservations(alice);
        assertEq(reserves.committedMarginUsdc, 0);
        assertEq(reserves.executionBountyUsdc, 0);
        assertEq(reserves.pendingOrderCount, 0);
        assertEq(router.accountHeadOrderId(alice), 0);
        assertEq(router.nextExecuteId(), 0);
    }

    function _assertCleanupReplayRejected(
        uint64 id,
        bool batch
    ) internal {
        uint256 traderBefore = _settlementBalance(alice);
        uint256 keeperBefore = _settlementBalance(keeper);
        bytes32 hashBefore = router.lifecycleBook().terminalOutcome(id).receiptHash;
        vm.expectRevert(IOrderRouterErrors.OrderRouter__NoOrdersToExecute.selector);
        vm.prank(keeper);
        if (batch) {
            router.executeOrderBatch(id, new bytes[](0));
        } else {
            router.executeOrder(id, new bytes[](0));
        }
        assertEq(_settlementBalance(alice), traderBefore, "terminal order cannot debit the trader twice");
        assertEq(_settlementBalance(keeper), keeperBefore, "terminal order cannot pay the clearer twice");
        assertEq(
            router.lifecycleBook().terminalOutcome(id).receiptHash, hashBefore, "terminal receipt remains immutable"
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;
import {RecordedOrderReceipts} from "../../../utils/RecordedOrderReceipts.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";

import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";

import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract VpiImrBypassTest is RecordedOrderReceipts {

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
    address carol = address(0x333);

    function _settlementBalance(
        address account
    ) internal view returns (uint256) {
        return clearinghouse.balanceUsdc(account);
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
            vpiFactor: 1e18,
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
        clearinghouse.setEngine(address(engine));
        _bootstrapSeededLifecycle();
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

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        address account = trader;
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(account, amount);
        vm.stopPrank();
    }

    function _orderStatus(
        uint64 orderId
    ) internal view returns (IOrderRouterAccounting.OrderStatus) {
        return OrderRouterDebugLens.loadOrderStatus(vm, router, orderId);
    }

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

    // A stale commit mark defers economic admission to execution. This test only proves queue admission;
    // it does not prove a rebate can fund the isolated PnL pledge required by the execution-time IMR check.
    function test_VpiRebateCanSatisfyReachableCollateralProjection() public {
        _startRecordingLogs();
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);
        vm.warp(block.timestamp + router.pletherOracle().orderExecutionStalenessLimit() + 1);

        address eve = address(0xE222);
        address eveAccount = eve;

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        vm.stopPrank();

        assertEq(clearinghouse.balanceUsdc(eveAccount), 1e6, "Trader only funds the reserved execution bounty");

        vm.prank(eve);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 1e8, false);

        assertEq(router.nextCommitId(), 3, "Rebate-backed open should remain committable under the planner");
    }

    function test_TypedUserInvalidOpenPaysClearer() public {
        _startRecordingLogs();
        address eve = address(0xE223);
        address eveAccount = eve;

        vm.startPrank(eve);
        usdc.mint(eve, 1e6);
        usdc.approve(address(clearinghouse), 1e6);
        clearinghouse.deposit(eveAccount, 1e6);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 1e8, false);
        vm.stopPrank();

        uint256 keeperBefore = _settlementBalance(address(this));
        bytes[] memory priceData = _mockPythUpdateData();
        router.executeOrder(1, priceData);

        assertEq(
            clearinghouse.balanceUsdc(address(this)) - keeperBefore,
            200_000,
            "Typed user-invalid open should pay the clearer as clearinghouse credit"
        );
        assertEq(
            uint256(OrderRouterDebugLens.loadRawOrderRecord(vm, router, 1).status),
            uint256(IOrderRouterAccounting.OrderStatus.None),
            "terminal order should be deleted from Router storage"
        );
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 1);
        assertEq(uint8(outcome.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(outcome.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(
            usdc.balanceOf(address(router)), 0, "Router should not retain consumed user-invalid bounty reservation"
        );
    }

}

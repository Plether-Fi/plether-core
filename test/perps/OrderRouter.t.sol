// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

contract OrderRouterTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    function test_UnbrickableQueue_OnEngineRevert() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        juniorVault.withdraw(1_000_000 * 1e6, bob, bob);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory emptyPayload;
        router.executeOrder(1, emptyPayload);

        assertEq(router.nextExecuteId(), 2, "Queue MUST increment even if Engine reverts");

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should not exist");

        assertEq(clearinghouse.balances(accountId, address(usdc)), 10_000 * 1e6, "Clearinghouse balance untouched");
    }

    function test_WithdrawalFirewall() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(engine.globalBullMaxProfit(), 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

        uint256 freeUsdc = pool.getFreeUSDC();
        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(fees, 30_000_000, "Exec fee = 6bps of $50k notional");
        assertGt(freeUsdc, 949_000 * 1e6, "Free USDC should be ~$950k (pool - maxLiab - fees)");
        assertLt(freeUsdc, 951_000 * 1e6, "Free USDC bounded above");

        uint256 bobMaxWithdraw = juniorVault.maxWithdraw(bob);
        assertEq(bobMaxWithdraw, freeUsdc, "LP should only be able to withdraw unencumbered capital");
    }

    function test_ZeroSizeCommit_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__ZeroSize.selector);
        router.commitOrder(CfdTypes.Side.BULL, 0, 500 * 1e6, 1e8, false);
    }

    function test_ExecuteNonPendingOrder_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.expectRevert(OrderRouter.OrderRouter__OrderNotPending.selector);
        router.executeOrder(2, empty);
    }

    function test_StrictFIFO_OutOfOrder_Reverts() public {
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__FIFOViolation.selector);
        router.executeOrder(2, empty);
    }

    function test_BatchExecution_AllSucceed() public {
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.deal(carol, 10 ether);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), address(usdc), 10_000 * 1e6);
        vm.stopPrank();

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(carol);
        router.commitOrder{value: 0.02 ether}(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperBefore = address(this).balance;
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 4, "All 3 orders should be processed");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 aliceSize,,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 15_000 * 1e18, "Alice should have 15k BULL");

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 carolSize,,,,,,,) = engine.positions(carolId);
        assertEq(carolSize, 10_000 * 1e18, "Carol should have 10k BEAR");

        uint256 keeperAfter = address(this).balance;
        assertEq(keeperAfter - keeperBefore, 0.04 ether, "Keeper should receive all keeper fees");
    }

    function test_BatchExecution_MixedResults() public {
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.5e8, false);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrderBatch(3, empty);

        assertEq(router.nextExecuteId(), 4, "All 3 should be consumed");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 15_000 * 1e18, "Orders 1 and 3 succeed, order 2 cancelled");
    }

    function test_BatchExecution_NoOrders_Reverts() public {
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__NoOrdersToExecute.selector);
        router.executeOrderBatch(0, empty);
    }

    function test_BatchExecution_UncommittedMaxId_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__MaxOrderIdNotCommitted.selector);
        router.executeOrderBatch(5, empty);
    }

    function test_BatchExecution_SingleETHTransfer() public {
        vm.prank(alice);
        router.commitOrder{value: 0.05 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder{value: 0.05 ether}(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        bytes[] memory empty;
        uint256 keeperBefore = address(this).balance;
        router.executeOrderBatch{value: 0.1 ether}(2, empty);
        uint256 keeperAfter = address(this).balance;

        assertEq(keeperAfter - keeperBefore, 0.1 ether, "Keeper net gain = sum of keeper fees");
    }

}

contract OrderRouterPythTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
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

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        vm.warp(1);
    }

    function test_MevCheck_RevertsInsteadOfCancelling() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order stays in queue for honest keeper");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setAllPrices(feedIds, int64(105_000_000), int32(-8), 1001);
        vm.warp(1050);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        assertEq(
            clearinghouse.balances(accountId, address(usdc)), 10_000 * 1e6, "Balance untouched after slippage cancel"
        );
    }

    function test_InsufficientPythFee_Reverts() public {
        vm.warp(1000);
        mockPyth.setFee(1 ether);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory data = new bytes[](1);
        data[0] = hex"00";

        vm.warp(1050);
        vm.expectRevert(OrderRouter.OrderRouter__InsufficientPythFee.selector);
        router.executeOrder(1, data);
    }

    function test_LiquidationStaleness_15SecBoundary() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2000);

        vm.warp(2016);
        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(accountId, empty);

        vm.warp(2015);
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        router.executeLiquidation(accountId, empty);
    }

    function test_Slippage_OpenDirections() public {
        address trader2 = address(0x444);
        usdc.mint(trader2, 10_000 * 1e6);
        vm.startPrank(trader2);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(trader2))), address(usdc), 10_000 * 1e6);
        vm.stopPrank();

        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1001);
        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "BULL open at favorable price should succeed");

        vm.warp(2000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2001);
        vm.warp(2050);
        router.executeOrder(2, empty);

        bytes32 trader2Id = bytes32(uint256(uint160(trader2)));
        (size,,,,,,,) = engine.positions(trader2Id);
        assertGt(size, 0, "BEAR open at favorable price should succeed");

        vm.warp(3000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3001);
        vm.warp(3050);
        router.executeOrder(3, empty);

        (size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "BULL open at adverse price should be rejected");

        vm.warp(4000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 4001);
        vm.warp(4050);
        router.executeOrder(4, empty);

        (size,,,,,,,) = engine.positions(trader2Id);
        assertEq(size, 10_000 * 1e18, "BEAR open at adverse price should be rejected");
    }

    function test_Slippage_CloseOrders_Protected() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertTrue(size > 0, "Position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        router.executeOrder(2, empty);

        (size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Close should be rejected by slippage check");
    }

    function test_BatchExecution_MEVCheckPerOrder() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1005);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1010);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 300 * 1e6, 1e8, false);

        vm.warp(1050);

        bytes[] memory empty;
        router.executeOrderBatch(2, empty);

        assertEq(router.nextExecuteId(), 2, "Batch breaks at MEV-stale order, leaving it in queue");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "Only order 1 should execute");
    }

    function test_C1_MevDetected_RevertsEntireTx() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder{value: 0.1 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);

        vm.warp(1050);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order preserved for honest keeper");
        assertEq(router.keeperFees(1), 0.1 ether, "Keeper fee preserved");
    }

    function test_BatchExecution_StalePrice_Reverts() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1000);
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrderBatch(1, empty);
    }

    function test_BasketMath_WeightedAverage() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(110_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(90_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Basket at $1.00 should pass slippage for target $1.00");
    }

    function test_BasketMath_UnequalWeights() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_A;
        ids[1] = FEED_B;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.7e18;
        w[1] = 0.3e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 1e8;
        b[1] = 1e8;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, new bool[](2));

        mockPyth.setPrice(FEED_A, int64(120_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(80_000_000), int32(-8), 1001);

        (uint256 price, uint256 minPt) = harness.computeBasketPrice();
        assertEq(price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(minPt, 1001, "minPublishTime should be weakest link");
    }

    function test_WeakestLink_Timestamp_MEV() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 999);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Weakest-link stale feed reverts, order preserved");
    }

    function test_WeakestLink_Staleness() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1001);
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrderBatch(1, empty);
    }

    function test_Slippage_ClampedBeforeCheck_BullClose() public {
        vm.warp(1000);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "BULL position should exist");

        vm.warp(2000);
        mockPyth.setAllPrices(feedIds, int64(250_000_000), int32(-8), 2001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 240_000_000, true);

        vm.warp(2050);
        router.executeOrder(2, empty);

        (size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "BULL close should succeed against clamped price");
    }

}

contract BasketPriceHarness is OrderRouter {

    constructor(
        address _pyth,
        bytes32[] memory _feedIds,
        uint256[] memory _quantities,
        uint256[] memory _basePrices,
        bool[] memory _inversions
    ) OrderRouter(address(1), address(1), _pyth, _feedIds, _quantities, _basePrices, _inversions) {}

    function computeBasketPrice() external view returns (uint256, uint256) {
        return _computeBasketPrice();
    }

}

contract NormalizePythHarness is OrderRouter {

    constructor()
        OrderRouter(
            address(1), address(1), address(0), new bytes32[](0), new uint256[](0), new uint256[](0), new bool[](0)
        )
    {}

    function normalizePythPrice(
        int64 price,
        int32 expo
    ) external pure returns (uint256) {
        return _normalizePythPrice(price, expo);
    }

}

contract NormalizePythFuzzTest is Test {

    NormalizePythHarness harness;

    function setUp() public {
        harness = new NormalizePythHarness();
    }

    function testFuzz_NormalizePythPrice(
        int64 rawPrice,
        int32 expo
    ) public view {
        vm.assume(rawPrice > 0);
        expo = int32(bound(int256(expo), -18, 18));

        uint256 result = harness.normalizePythPrice(rawPrice, expo);

        if (expo == -8) {
            assertEq(result, uint256(uint64(rawPrice)), "Identity at expo=-8");
        }

        if (expo > -8) {
            assertGe(result, uint256(uint64(rawPrice)), "Upscaling must not shrink value");
        }
    }

}

contract FadStalenessTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    uint256 constant FRIDAY_18UTC = 604_951_200;
    uint256 constant SATURDAY_NOON = 605_016_000;
    uint256 constant SUNDAY_21UTC = 605_134_800;
    uint256 constant MONDAY_NOON = 605_188_800;
    uint256 constant WEDNESDAY_NOON = 605_361_600;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
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

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();

        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();

        vm.warp(FRIDAY_18UTC);
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_18UTC + 1);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(FRIDAY_18UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        require(size == 10_000 * 1e18, "setUp: position not opened");
    }

    function _currentTimestamp() internal view returns (uint256 ts) {
        assembly {
            ts := timestamp()
        }
    }

    function _addFadDays(
        uint256[] memory timestamps
    ) internal {
        engine.proposeAddFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeAddFadDays();
    }

    function _removeFadDays(
        uint256[] memory timestamps
    ) internal {
        engine.proposeRemoveFadDays(timestamps);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeRemoveFadDays();
    }

    function _setFadMaxStaleness(
        uint256 val
    ) internal {
        engine.proposeFadMaxStaleness(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeFadMaxStaleness();
    }

    function _setFadRunway(
        uint256 val
    ) internal {
        engine.proposeFadRunway(val);
        vm.warp(_currentTimestamp() + 48 hours + 1);
        engine.finalizeFadRunway();
    }

    function test_FadWindow_CloseOrder_BlockedDuringFrozen() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_OpenOrder_BlockedDuringFrozen() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_MevCheckMoot_FrozenReverts() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_ExcessStaleness_FrozenReverts() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrder(2, empty);
    }

    function test_FadWindow_Liquidation_AcceptsStalePrice() public {
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), FRIDAY_18UTC + 1);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = new bytes[](0);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        router.executeLiquidation(aliceId, empty);

        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Liquidation should succeed during FAD with stale price");
    }

    function test_FadWindow_Liquidation_ExcessStaleness_Reverts() public {
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        bytes[] memory empty = new bytes[](0);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(aliceId, empty);
    }

    function test_FadBatch_BlockedDuringFrozen() public {
        vm.warp(SATURDAY_NOON);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrderBatch(2, empty);
    }

    function test_FadBatch_ExcessStaleness_FrozenReverts() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 4 days);

        vm.warp(SATURDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(SATURDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrderBatch(2, empty);
    }

    function test_Weekday_StalenessUnchanged() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 1);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        vm.warp(WEDNESDAY_NOON + 62);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "61s stale on weekday should cancel");
    }

    function test_Weekday_OpenOrder_Allowed() public {
        address carol = address(0x333);
        usdc.mint(carol, 10_000 * 1e6);
        vm.startPrank(carol);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(carol))), address(usdc), 10_000 * 1e6);
        vm.stopPrank();

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 1);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.8e8, false);

        vm.warp(WEDNESDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,,,) = engine.positions(carolId);
        assertGt(size, 0, "Weekday open orders should work normally");
    }

    function test_Admin_AddFadDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow(), "Wednesday should be FAD after admin override");
    }

    function test_Admin_RemoveFadDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow());

        _removeFadDays(timestamps);

        vm.warp(WEDNESDAY_NOON);
        assertFalse(engine.isFadWindow(), "FAD override should be removed");
    }

    function test_Admin_SetFadMaxStaleness() public {
        assertEq(engine.fadMaxStaleness(), 3 days);
        _setFadMaxStaleness(5 days);
        assertEq(engine.fadMaxStaleness(), 5 days);
    }

    function test_Admin_SetFadMaxStaleness_ZeroReverts() public {
        vm.expectRevert(CfdEngine.CfdEngine__ZeroStaleness.selector);
        engine.proposeFadMaxStaleness(0);
    }

    function test_Admin_AddFadDays_NonOwner_Reverts() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;

        vm.prank(alice);
        vm.expectRevert();
        engine.proposeAddFadDays(timestamps);
    }

    function test_Admin_EmptyDays_Reverts() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert(CfdEngine.CfdEngine__EmptyDays.selector);
        engine.proposeAddFadDays(empty);
    }

    function test_AdminFadDay_BlockedDuringFrozen() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = MONDAY_NOON;
        _addFadDays(timestamps);

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), MONDAY_NOON - 14 hours);

        vm.warp(MONDAY_NOON);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(MONDAY_NOON + 50);
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(OrderRouter.OrderRouter__OracleFrozen.selector);
        router.executeOrder(2, empty);
    }

    function test_FridayGap_MevCheckStillActive() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        uint256 publishTime = FRIDAY_20UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 30);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "MEV check must block stale-price close during Friday gap");
    }

    function test_FridayGap_FreshPriceStillWorks() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close with fresh price should succeed during Friday gap");
    }

    function test_FridayGap_OpenStillBlocked() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(FRIDAY_20UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        assertEq(router.nextExecuteId(), 3);
        assertEq(router.claimableEth(alice), 0, "Failed order fee goes to keeper, not user");
    }

    function test_FridayGap_StalenessStill60s() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(FRIDAY_20UTC + 63);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "60s staleness must apply during Friday gap");
    }

    function test_FridayGap_LiquidationStaleness15s() public {
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), FRIDAY_20UTC);

        vm.warp(FRIDAY_20UTC + 16);
        bytes[] memory empty = new bytes[](0);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(aliceId, empty);
    }

    function test_SundayDst_OracleUnfrozenAt21() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 1);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close should succeed at Sunday 21:00 with fresh price");
    }

    function test_SundayDst_MevEnforcedAt21() public {
        uint256 publishTime = SUNDAY_21UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 30);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "MEV check must block stale close at Sunday 21:00");
    }

    function test_SundayDst_StillFadAt21() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 1);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        assertEq(router.nextExecuteId(), 3);
        assertEq(router.claimableEth(alice), 0, "Failed order fee goes to keeper, not user");
    }

    function test_SundayDst_WinterStalenessRejects() public {
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SATURDAY_NOON - 12 hours);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "Winter stale price correctly rejected at Sunday 21:00");
    }

    function test_Runway_FadActivatesBeforeHoliday() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 tuesdayJustOutside = wednesdayMidnight - 3 hours - 1;

        vm.warp(tuesdayJustOutside);
        assertFalse(engine.isFadWindow(), "Before runway: FAD should be inactive");

        uint256 tuesdayRunwayStart = wednesdayMidnight - 3 hours;
        vm.warp(tuesdayRunwayStart);
        assertTrue(engine.isFadWindow(), "At runway start: FAD should be active");

        uint256 tuesday22 = wednesdayMidnight - 2 hours;
        vm.warp(tuesday22);
        assertTrue(engine.isFadWindow(), "During runway: FAD should be active");
    }

    function test_Runway_OracleFrozenOnlyOnHolidayDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;

        vm.warp(wednesdayMidnight - 3 hours);
        assertTrue(engine.isFadWindow());

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), wednesdayMidnight - 3 hours + 1);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(wednesdayMidnight - 3 hours + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);
        assertEq(router.claimableEth(alice), 0, "Failed order fee goes to keeper, not user");

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), wednesdayMidnight - 3 hours + 51);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(wednesdayMidnight - 3 hours + 100);
        router.executeOrder(3, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close with fresh price works during runway");
    }

    function test_Runway_MevStillEnforcedDuringRunway() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 runwayTime = wednesdayMidnight - 2 hours;

        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), runwayTime - 60);

        vm.warp(runwayTime);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        vm.warp(runwayTime + 30);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "MEV check must block stale price during runway");
    }

    function test_Runway_SetFadRunway() public {
        assertEq(engine.fadRunwaySeconds(), 3 hours);
        _setFadRunway(6 hours);
        assertEq(engine.fadRunwaySeconds(), 6 hours);
    }

    function test_Runway_TooLong_Reverts() public {
        vm.expectRevert(CfdEngine.CfdEngine__RunwayTooLong.selector);
        engine.proposeFadRunway(25 hours);
    }

    function test_Runway_ZeroDisablesLookahead() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);
        _setFadRunway(0);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;

        vm.warp(wednesdayMidnight - 3 hours);
        assertFalse(engine.isFadWindow(), "Zero runway disables lookahead");

        vm.warp(WEDNESDAY_NOON);
        assertTrue(engine.isFadWindow(), "Holiday day itself still FAD");
    }

}

contract InversionTest is Test {

    MockPyth mockPyth;
    bytes32 constant FEED_JPY = bytes32(uint256(0xAA));
    bytes32 constant FEED_EUR = bytes32(uint256(0xBB));

    function setUp() public {
        mockPyth = new MockPyth();
    }

    function test_H03_InvertedFeedUsesCorrectPrice() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 638_163;
        bool[] memory inv = new bool[](1);
        inv[0] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);
        (uint256 price,) = harness.computeBasketPrice();

        uint256 expectedNorm = uint256(1e11) / 156_700;
        uint256 expectedBasket = (expectedNorm * 1e18) / (uint256(638_163) * 1e10);
        assertEq(price, expectedBasket, "Inverted JPY should produce correct basket price");
    }

    function test_H03_InversionsLengthMismatchReverts() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_JPY;
        ids[1] = FEED_EUR;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 1e8;
        b[1] = 1e8;
        bool[] memory inv = new bool[](1);

        vm.expectRevert(OrderRouter.OrderRouter__LengthMismatch.selector);
        new BasketPriceHarness(address(mockPyth), ids, w, b, inv);
    }

    function test_H03_MixedInversionsComputeCorrectBasket() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_EUR;
        ids[1] = FEED_JPY;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 108_000_000;
        b[1] = 638_163;
        bool[] memory inv = new bool[](2);
        inv[0] = false;
        inv[1] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_EUR, int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);

        (uint256 price,) = harness.computeBasketPrice();

        assertApproxEqAbs(price, 100_000_000, 100, "Mixed basket at base prices should be ~$1.00");
    }

    function test_H03_OracleEquivalence_SamePricesSameBasket() public {
        uint256[] memory w = new uint256[](4);
        w[0] = 0.4e18;
        w[1] = 0.2e18;
        w[2] = 0.25e18;
        w[3] = 0.15e18;

        int256 eurUsd8 = 108_000_000;
        int256 jpyUsd8 = 638_163;
        int256 gbpUsd8 = 126_000_000;
        int256 chfUsd8 = 113_636_363;

        uint256[] memory basePrices = new uint256[](4);
        basePrices[0] = uint256(eurUsd8);
        basePrices[1] = uint256(jpyUsd8);
        basePrices[2] = uint256(gbpUsd8);
        basePrices[3] = uint256(chfUsd8);

        address[] memory feeds = new address[](4);
        feeds[0] = address(new MockOracle(eurUsd8, "EUR/USD"));
        feeds[1] = address(new MockOracle(jpyUsd8, "JPY/USD"));
        feeds[2] = address(new MockOracle(gbpUsd8, "GBP/USD"));
        feeds[3] = address(new MockOracle(chfUsd8, "CHF/USD"));

        BasketOracle basket = new BasketOracle(feeds, w, basePrices, 500, 2e8, address(this));
        (, int256 chainlinkPrice,,,) = basket.latestRoundData();

        bytes32[] memory pythIds = new bytes32[](4);
        pythIds[0] = bytes32(uint256(0x01));
        pythIds[1] = bytes32(uint256(0x02));
        pythIds[2] = bytes32(uint256(0x03));
        pythIds[3] = bytes32(uint256(0x04));

        bool[] memory inv = new bool[](4);
        inv[0] = false;
        inv[1] = true;
        inv[2] = false;
        inv[3] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), pythIds, w, basePrices, inv);

        mockPyth.setPrice(pythIds[0], int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[1], int64(15_670), int32(-2), 1001);
        mockPyth.setPrice(pythIds[2], int64(126_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[3], int64(8800), int32(-4), 1001);

        (uint256 pythPrice,) = harness.computeBasketPrice();

        assertApproxEqAbs(
            uint256(chainlinkPrice), pythPrice, 100, "BasketOracle and OrderRouter must agree within rounding"
        );
    }

}

contract OrderRouterAuditTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    // Regression: Finding-5 — close orders bypass slippage
    function test_CloseBypassesSlippage() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 0, 0.9e8, true);

        bytes[] memory pythData = new bytes[](1);
        pythData[0] = abi.encode(uint256(1.5e8));
        router.executeOrder(2, pythData);

        bytes32 carolAccount = bytes32(uint256(uint160(carol)));
        (uint256 size,,,,,,,) = engine.positions(carolAccount);
        assertGt(size, 0, "Close at bad price should have been rejected by slippage check");
    }

    // Regression: Finding-6 — missing chainId guard
    function test_MissingChainIdGuard() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(carol, 50_000 * 1e6);

        vm.chainId(1);

        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;

        vm.expectRevert(OrderRouter.OrderRouter__MockModeDisabled.selector);
        router.executeOrder(1, empty);
    }

    // Regression: H-02 — stale order executes via executeOrder
    function test_StaleOrderExecutesViaExecuteOrder() public {
        router.proposeMaxOrderAge(300);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        uint64 commitId = router.nextCommitId();
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 600);

        router.executeOrder(commitId, priceData);

        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Expired order must not execute via executeOrder");
    }

    // Regression: H-03 — zero fee commit should revert
    function test_ZeroFeeCommitShouldRevert() public {
        router.proposeMinKeeperFee(0.001 ether);
        _warpForward(48 hours + 1);
        router.finalizeMinKeeperFee();
        _fundTrader(alice, 10_000e6);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__InsufficientKeeperFee.selector);
        router.commitOrder{value: 0}(CfdTypes.Side.BULL, 1000e18, 1000e6, 1e8, false);
    }

    // Regression: H-03 — close order allowed while paused
    function test_CloseOrderAllowedWhilePaused() public {
        _fundJunior(bob, 500_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 10_000 * 1e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Position should be open");

        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.commitOrder(CfdTypes.Side.BULL, 1000 * 1e18, 1000 * 1e6, 1e8, false);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, size, 0, 0, true);

        router.unpause();
        router.executeOrder(2, empty);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Position should be fully closed");
    }

}

// Regression: H-03
contract StaleOrderExpiryTest is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address spammer = address(0x666);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        router.proposeMaxOrderAge(300);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();
    }

    // Regression: H-03
    function test_StaleSpamOrdersAutoSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        assertEq(router.nextExecuteId(), 1);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        router.executeOrder(6, empty);

        assertEq(router.nextExecuteId(), 7, "Queue advanced past spam + real order");
    }

    // Regression: H-03
    function test_FreshOrdersNotSkipped() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 2);
    }

    // Regression: H-03
    function test_SpammerFeeConfiscatedOnExpiry() public {
        vm.deal(spammer, 1 ether);
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);

        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(2, empty);

        assertEq(router.claimableEth(spammer), 0, "Expired order fee not refunded to user");
        assertGt(router.claimableEth(keeper), 0, "Keeper receives expired order fee via claimable");
    }

    // Regression: H-03
    function test_BatchSkipsStaleOrders() public {
        _fundJunior(bob, 1_000_000 * 1e6);
        _fundTrader(alice, 50_000 * 1e6);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 1000 * 1e6, 1e8, false);
        }

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000 * 1e18, 10_000 * 1e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        router.executeOrderBatch(4, empty);

        assertEq(router.nextExecuteId(), 5, "Batch advanced past stale + real order");
    }

    // Regression: H-03
    function test_SetMaxOrderAge_OnlyOwner() public {
        vm.prank(spammer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, spammer));
        router.proposeMaxOrderAge(600);

        router.proposeMaxOrderAge(600);
        _warpForward(48 hours + 1);
        router.finalizeMaxOrderAge();
        assertEq(router.maxOrderAge(), 600);
    }

    // Regression: H-01
    function test_ExpiredOrderFeeRefundedToUser_ViaSkip() public {
        vm.deal(spammer, 1 ether);
        vm.prank(spammer);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        address keeper = address(0x999);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(2, empty);

        assertEq(router.claimableEth(spammer), 0, "Expired order fee not refunded to user");
        assertGt(router.claimableEth(keeper), 0, "Keeper receives expired order fee via claimable");
    }

}

contract MarkPriceStalenessTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        pool.setJuniorVault(address(juniorVault));
        pool.setSeniorVault(address(seniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        vm.warp(144 hours + 4);
        clearinghouse.finalizeOperator();

        vm.warp(SETUP_TIMESTAMP);
    }

    function test_UpdateMarkPrice_RevertsOnStaleOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 120);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.updateMarkPrice(updateData);
    }

    function test_UpdateMarkPrice_AcceptsFreshOracle() public {
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 30);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);
        assertEq(engine.lastMarkPrice(), 1e8);
    }

}

// Regression: H-02
contract StalenessGriefTest is BasePerpTest {

    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    address alice = address(0x111);
    address bob = address(0x222);
    address attacker = address(0x666);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC");
        pool.setJuniorVault(address(juniorVault));
        pool.setSeniorVault(address(seniorVault));
        engine.setVault(address(pool));

        mockPyth = new MockPyth();
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        vm.warp(144 hours + 4);
        clearinghouse.finalizeOperator();

        vm.warp(SETUP_TIMESTAMP);
    }

    // Regression: H-02
    function test_StaleOracleCancelsOrderInsteadOfReverting() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);

        vm.warp(block.timestamp + 120);

        bytes[] memory empty;
        vm.prank(attacker);
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "stale oracle gracefully cancels order instead of reverting");
    }

}

// Regression: C-05
contract VpiImrBypassTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 1e18,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    // Regression: C-03 / C-05 — IMR check uses pos.margin (post-fee, includes VPI rebate)
    // With vpiFactor=1e18 the skew-reducing rebate exceeds IMR, so the position
    // legitimately opens with VPI-funded margin even though marginDelta is zero.
    function test_VpiRebateSatisfiesIMR_ZeroRiskPosition() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        assertEq(clearinghouse.balances(aliceAccount, address(usdc)), 0, "Alice starts with zero USDC");

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 1e8, false);
        router.executeOrder(2, empty);

        (uint256 size, uint256 margin,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position opens: VPI rebate provides sufficient margin");
        assertGt(margin, 0, "Position margin funded entirely by VPI rebate");
    }

}

// Regression: H-01
contract KeeperFeeRefundTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function setUp() public {
        vm.warp(1_709_532_000);
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));
        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        router.proposeMaxOrderAge(300);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
        router.finalizeMaxOrderAge();
    }

    // Regression: H-01
    function test_ExpiredOrderFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(1, empty);

        assertEq(router.claimableEth(alice), 0, "User fee is not refunded on failure");
        assertGt(keeper.balance, 0, "Keeper receives fee for processing expired order");
    }

    // Regression: H-01
    function test_SlippageFailFeeRefundedToUser() public {
        usdc.mint(bob, 1_000_000e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), 1_000_000e6);
        juniorVault.deposit(1_000_000e6, bob);
        vm.stopPrank();

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        usdc.mint(alice, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), 50_000e6);
        clearinghouse.deposit(accountId, address(usdc), 50_000e6);
        vm.stopPrank();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1.5e8, false);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        assertEq(router.claimableEth(alice), 0, "User fee is not refunded on slippage failure");
        assertGt(keeper.balance, 0, "Keeper receives fee for processing failed order");
    }

    // Regression: H-01
    function test_BatchExpiredFeeRefundedToUser() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        vm.warp(block.timestamp + 301);

        bytes[] memory empty;
        router.executeOrderBatch(1, empty);

        assertEq(router.claimableEth(alice), 0, "User fee is not refunded on batch expiry");
        assertGt(address(this).balance, 0, "Keeper receives fee for processing expired batch order");
    }

}

// Regression: H-02
contract WeekendArbitrageTest is Test {

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    MarginClearinghouse clearinghouse;
    OrderRouter router;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0x111);
    address bob = address(0x222);
    address keeper = address(0x999);

    receive() external payable {}

    function _warpPastTimelock() internal {
        vm.warp(block.timestamp + 48 hours + 1);
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        juniorVault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundTrader(
        address trader,
        uint256 amount
    ) internal {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(clearinghouse), amount);
        clearinghouse.deposit(accountId, address(usdc), amount);
        vm.stopPrank();
    }

    function setUp() public {
        vm.warp(1_709_100_000);
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0.15e18,
            maxApy: 3.0e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 15
        });

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router =
            new OrderRouter(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        clearinghouse.proposeWithdrawGuard(address(engine));
        _warpPastTimelock();
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();

        clearinghouse.proposeOperator(address(engine), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        _warpPastTimelock();
        clearinghouse.finalizeOperator();
    }

    // Regression: H-02
    function test_CloseOrderExecutesAtStaleFridayPrice() public {
        _fundJunior(bob, 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 20_000e6, 0, false);
        vm.warp(block.timestamp + 1);
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp);
        router.executeOrder(1, updateData);

        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should be open");

        uint256 ts = block.timestamp;
        uint256 dayOfWeek = ((ts / 86_400) + 4) % 7;
        uint256 daysToSaturday = (6 + 7 - dayOfWeek) % 7;
        if (daysToSaturday == 0) {
            daysToSaturday = 7;
        }
        uint256 saturdayNoon = ts + (daysToSaturday * 86_400) - (ts % 86_400) + 12 hours;
        vm.warp(saturdayNoon);

        uint256 fridayPublishTime = saturdayNoon - 18 hours;
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), fridayPublishTime);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 100_000e18, 0, 0, true);

        vm.expectRevert();
        router.executeOrder(2, updateData);
    }

}

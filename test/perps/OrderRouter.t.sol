// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PythStructs} from "../../src/interfaces/IPyth.sol";
import {BasketOracle} from "../../src/oracles/BasketOracle.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockOracle} from "../utils/MockOracle.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {

    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

}

contract MockPyth {

    struct MockPrice {
        int64 price;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => MockPrice) public prices;
    uint256 public mockFee;

    function setPrice(
        bytes32 feedId,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        prices[feedId] = MockPrice(_price, _expo, _publishTime);
    }

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            prices[feedIds[i]] = MockPrice(_price, _expo, _publishTime);
        }
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory) {
        MockPrice memory p = prices[id];
        return PythStructs.Price({price: p.price, conf: 0, expo: p.expo, publishTime: p.publishTime});
    }

    function setFee(
        uint256 _fee
    ) external {
        mockFee = _fee;
    }

    function getUpdateFee(
        bytes[] calldata
    ) external view returns (uint256) {
        return mockFee;
    }

    function updatePriceFeeds(
        bytes[] calldata
    ) external payable {}

}

contract OrderRouterTest is Test {

    receive() external payable {}

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    function setUp() public {
        usdc = new MockUSDC();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
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

        clearinghouse = new MarginClearinghouse(address(usdc));
        clearinghouse.proposeAssetConfig(address(usdc), 6, 10_000, address(0));
        uint256 t = block.timestamp + 48 hours + 1;
        vm.warp(t);
        clearinghouse.finalizeAssetConfig();

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
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

        clearinghouse.proposeWithdrawGuard(address(engine));
        clearinghouse.proposeOperator(address(engine), true);
        t += 48 hours + 1;
        vm.warp(t);
        clearinghouse.finalizeWithdrawGuard();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        t += 48 hours + 1;
        vm.warp(t);
        clearinghouse.finalizeOperator();
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        // Fund LP (Bob) with $1 Million
        usdc.mint(bob, 1_000_000 * 1e6);
        vm.startPrank(bob);
        usdc.approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000 * 1e6, bob);
        vm.stopPrank();

        // Fund Trader (Alice): deposit to clearinghouse
        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(clearinghouse), type(uint256).max);
        clearinghouse.deposit(bytes32(uint256(uint160(alice))), address(usdc), 10_000 * 1e6);
        vm.deal(alice, 10 ether);
        vm.stopPrank();
    }

    function test_UnbrickableQueue_OnEngineRevert() public {
        // Bob withdraws all Vault funds so Solvency check will fail
        vm.warp(block.timestamp + 1 hours); // past deposit cooldown
        vm.prank(bob);
        juniorVault.withdraw(1_000_000 * 1e6, bob, bob);

        // Alice commits a trade (no USDC escrowed, just the order)
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        // Keeper executes. Engine will REVERT inside the Try/Catch
        bytes[] memory emptyPayload;
        router.executeOrder(1, emptyPayload);

        // Queue MUST advance even if Engine reverts
        assertEq(router.nextExecuteId(), 2, "Queue MUST increment even if Engine reverts");

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should not exist");

        // Alice's clearinghouse balance is untouched (nothing was escrowed)
        assertEq(clearinghouse.balances(accountId, address(usdc)), 10_000 * 1e6, "Clearinghouse balance untouched");
    }

    function test_WithdrawalFirewall() public {
        // Alice commits and executes a trade
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 50_000 * 1e18, 1000 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        // 50k BULL at $1.00 with CAP=$2: maxProfit = 50k * $1.00 = $50k
        assertEq(engine.globalBullMaxProfit(), 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

        // Pool started with $1M, received VPI+execFee from trade.
        // execFee = 50k * 6bps = $30. freeUSDC = totalAssets - maxLiab - pendingFees
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
        // Order 1: Valid BULL
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        // Order 2: BULL open with bad slippage (targetPrice $1.50, execution at $1.00 is too low)
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.5e8, false);

        // Order 3: Another valid BULL
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

        // Keeper spent 0.1 ETH msg.value, received back 0.2 ETH (0.1 refund + 0.1 keeper fees), net +0.1
        assertEq(keeperAfter - keeperBefore, 0.1 ether, "Keeper net gain = sum of keeper fees");
    }

}

contract OrderRouterPythTest is Test {

    receive() external payable {}

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    function setUp() public {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
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

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
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
        clearinghouse.proposeOperator(address(engine), true);
        uint256 t = block.timestamp + 48 hours + 1;
        vm.warp(t);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        t += 48 hours + 1;
        vm.warp(t);
        clearinghouse.finalizeOperator();

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

        // publishTime 999 < commitTime 1000 → MEV detected
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 1, "Order stays in queue for honest keeper");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        // BEAR open slippage: exec <= target required. 1.05e8 > 1e8 → fails
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

        // BULL open: wants HIGH entry. Target $0.90 → exec $1.00 >= $0.90 → succeeds
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 1001);
        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "BULL open at favorable price should succeed");

        // BEAR open: wants LOW entry. Target $1.10 → exec $1.00 <= $1.10 → succeeds
        vm.warp(2000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 2001);
        vm.warp(2050);
        router.executeOrder(2, empty);

        bytes32 trader2Id = bytes32(uint256(uint160(trader2)));
        (size,,,,,,,) = engine.positions(trader2Id);
        assertGt(size, 0, "BEAR open at favorable price should succeed");

        // BULL open: adverse. Target $1.10, exec $1.00 → $1.00 >= $1.10 false → rejected
        vm.warp(3000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 3001);
        vm.warp(3050);
        router.executeOrder(3, empty);

        (size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "BULL open at adverse price should be rejected");

        // BEAR open: adverse. Target $0.90, exec $1.00 → $1.00 <= $0.90 false → rejected
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

        // Close BEAR at targetPrice=1.5e8 but Pyth price=1e8
        // BEAR slippage: 1e8 >= 1.5e8? No → order cancelled
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

        // Order 1: committed at t=1000, price published at t=1005 → valid (1005 > 1000)
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1010);

        // Order 2: committed at t=1010, price published at t=1005 → stale (1005 <= 1010)
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
        // Set oracle price published at t=999, BEFORE commit at t=1000 → MEV
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), 999);

        // Alice commits with 0.1 ETH keeper fee
        vm.prank(alice);
        router.commitOrder{value: 0.1 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);

        // Keeper executes with no Pyth update - stale price triggers revert (not cancel)
        vm.warp(1050);
        bytes[] memory empty;
        vm.prank(keeper);
        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, empty);

        // Order stays in queue, fee stays in mapping
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

        // FEED_A=$1.10, FEED_B=$0.90, 50/50 weights, $1.00 base → basket=$1.00
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
        // 70/30 weights: FEED_A=$1.20, FEED_B=$0.80, base $1.00
        // basket = (1.20 * 0.70) / 1.00 + (0.80 * 0.30) / 1.00 = 0.84 + 0.24 = 1.08
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
        // 120_000_000 * 0.7e18 / (1e8 * 1e10) = 84_000_000
        // 80_000_000 * 0.3e18 / (1e8 * 1e10) = 24_000_000
        // total = 108_000_000 = $1.08
        assertEq(price, 108_000_000, "70/30 basket should compute $1.08");
        assertEq(minPt, 1001, "minPublishTime should be weakest link");
    }

    function test_WeakestLink_Timestamp_MEV() public {
        vm.warp(1000);

        // FEED_A fresh, FEED_B stale (publishTime < commitTime)
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

        // FEED_A fresh, FEED_B >60s old
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

        // Oracle jumps to $2.50, above CAP ($2.00). Engine clamps to $2.00.
        // User sets targetPrice=$2.40 — acceptable since clamped price is $2.00.
        // Bug: if slippage checked unclamped $2.50 <= $2.40 → false → wrongly rejected.
        // Fix: slippage checks clamped $2.00 <= $2.40 → true → correctly accepted.
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

contract FadStalenessTest is Test {

    receive() external payable {}

    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    TrancheVault juniorVault;
    OrderRouter router;
    MarginClearinghouse clearinghouse;
    MockPyth mockPyth;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    // Timestamps verified against isFadWindow's dayOfWeek = ((ts/86400)+4)%7
    uint256 constant FRIDAY_18UTC = 604_951_200; // dayOfWeek=5, hour=18 → NOT FAD
    uint256 constant SATURDAY_NOON = 605_016_000; // dayOfWeek=6 → FAD
    uint256 constant SUNDAY_21UTC = 605_134_800; // dayOfWeek=0, hour=21 → summer FX re-open
    uint256 constant MONDAY_NOON = 605_188_800; // dayOfWeek=1 → NOT FAD
    uint256 constant WEDNESDAY_NOON = 605_361_600; // dayOfWeek=3 → NOT FAD

    function setUp() public {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
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

        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
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
        clearinghouse.proposeOperator(address(engine), true);
        vm.warp(48 hours + 2);
        clearinghouse.finalizeAssetConfig();
        clearinghouse.finalizeWithdrawGuard();
        clearinghouse.finalizeOperator();

        clearinghouse.proposeOperator(address(router), true);
        vm.warp(96 hours + 3);
        clearinghouse.finalizeOperator();

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

        // Open BULL position on Friday before FAD (basket=$0.80, not $1.00)
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
        // Move price against BULL: basket $0.80 → $0.86 (BULL loses ~$600, wipes $500 margin)
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
        // On Wednesday, >60s stale should still cancel
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), WEDNESDAY_NOON + 1);

        vm.warp(WEDNESDAY_NOON);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 5000 * 1e18, 0, 0, true);

        // publishTime=WEDNESDAY_NOON+1, execution at WEDNESDAY_NOON+62 → staleness=61 > 60
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

    // ==========================================
    // ADMIN FAD DAY OVERRIDES
    // ==========================================

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

    // ==========================================
    // FRIDAY 19:00-22:00 GAP (FAD active, oracle NOT frozen)
    // ==========================================

    function test_FridayGap_MevCheckStillActive() public {
        // Friday 20:00 UTC: FAD is active but Pyth is still publishing (markets open until ~22:00)
        // dayOfWeek=5, hour=20 => isFadWindow=true, _isOracleFrozen=false
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        // Price published at 19:30 (before the close order at 20:00)
        uint256 publishTime = FRIDAY_20UTC - 30 minutes;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), publishTime);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        // Keeper tries to execute with the 19:30 price (publishTime < commitTime)
        // MEV check MUST still catch this since oracle is not frozen
        vm.warp(FRIDAY_20UTC + 30);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "MEV check must block stale-price close during Friday gap");
    }

    function test_FridayGap_FreshPriceStillWorks() public {
        // Friday 20:00 UTC: close order with a fresh price should succeed
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        // Fresh price published after commit
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
        // Friday 20:00 UTC: open orders blocked by FAD even though oracle is live
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(FRIDAY_20UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        assertEq(router.nextExecuteId(), 3);
        assertGt(router.claimableEth(alice), 0, "User must be refunded on FAD rejection");
    }

    function test_FridayGap_StalenessStill60s() public {
        // Friday 20:00 UTC: 60s staleness should still apply (oracle is not frozen)
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;

        // Price 61s stale at execution time, but publishTime > commitTime
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), FRIDAY_20UTC + 1);

        vm.warp(FRIDAY_20UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        // Execute 62s after publishTime => staleness = 61 > 60
        vm.warp(FRIDAY_20UTC + 63);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "60s staleness must apply during Friday gap");
    }

    function test_FridayGap_LiquidationStaleness15s() public {
        // Friday 20:00 UTC: liquidation staleness should still be 15s (not relaxed)
        uint256 FRIDAY_20UTC = FRIDAY_18UTC + 2 hours;
        mockPyth.setAllPrices(feedIds, int64(86_000_000), int32(-8), FRIDAY_20UTC);

        vm.warp(FRIDAY_20UTC + 16);
        bytes[] memory empty = new bytes[](0);
        bytes32 aliceId = bytes32(uint256(uint160(alice)));

        vm.expectRevert(OrderRouter.OrderRouter__MevOraclePriceTooStale.selector);
        router.executeLiquidation(aliceId, empty);
    }

    // ==========================================
    // SUNDAY DST GAP (21:00-22:00 UTC)
    // ==========================================

    function test_SundayDst_OracleUnfrozenAt21() public {
        // Sunday 21:00 UTC: summer FX markets re-open, Pyth publishes live prices
        // _isOracleFrozen must return false so MEV checks are enforced
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 1);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 0, 0, true);

        // Fresh price (publishTime > commitTime) => MEV check passes, close succeeds
        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Close should succeed at Sunday 21:00 with fresh price");
    }

    function test_SundayDst_MevEnforcedAt21() public {
        // Sunday 21:00 UTC: stale price must be caught by MEV check (not bypassed)
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
        // Sunday 21:00 UTC: isFadWindow() still true (< 22), so opens are blocked
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), SUNDAY_21UTC + 1);

        vm.warp(SUNDAY_21UTC);

        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(SUNDAY_21UTC + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);

        assertEq(router.nextExecuteId(), 3);
        assertGt(router.claimableEth(alice), 0, "User must be refunded on FAD rejection");
    }

    function test_SundayDst_WinterStalenessRejects() public {
        // Sunday 21:00 UTC in winter: Pyth hasn't woken up yet, price is ~47h stale
        // _isOracleFrozen=false => 60s staleness check kicks in => rejects correctly
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

    // ==========================================
    // ADMIN HOLIDAY DELEVERAGE RUNWAY
    // ==========================================

    function test_Runway_FadActivatesBeforeHoliday() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        // Tuesday 20:59 UTC: 3h01m before midnight => outside runway
        uint256 tuesdayBeforeRunway = WEDNESDAY_NOON - 12 hours - 1; // 23:59:59 minus 3h = 20:59:59
        // More precisely: Wednesday midnight = WEDNESDAY_NOON - 12 hours (noon - 12h = midnight)
        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;
        uint256 tuesdayJustOutside = wednesdayMidnight - 3 hours - 1;

        vm.warp(tuesdayJustOutside);
        assertFalse(engine.isFadWindow(), "Before runway: FAD should be inactive");

        // Tuesday 21:00 UTC: exactly 3h before midnight => inside runway
        uint256 tuesdayRunwayStart = wednesdayMidnight - 3 hours;
        vm.warp(tuesdayRunwayStart);
        assertTrue(engine.isFadWindow(), "At runway start: FAD should be active");

        // Tuesday 22:00 UTC: 2h before midnight => inside runway, oracle NOT frozen
        uint256 tuesday22 = wednesdayMidnight - 2 hours;
        vm.warp(tuesday22);
        assertTrue(engine.isFadWindow(), "During runway: FAD should be active");
    }

    function test_Runway_OracleFrozenOnlyOnHolidayDay() public {
        uint256[] memory timestamps = new uint256[](1);
        timestamps[0] = WEDNESDAY_NOON;
        _addFadDays(timestamps);

        uint256 wednesdayMidnight = WEDNESDAY_NOON - 12 hours;

        // Tuesday 21:00: FAD active (runway) but oracle NOT frozen
        vm.warp(wednesdayMidnight - 3 hours);
        assertTrue(engine.isFadWindow());

        // Open order should be rejected (FAD close-only)
        mockPyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), wednesdayMidnight - 3 hours + 1);
        vm.prank(alice);
        router.commitOrder{value: 0.01 ether}(CfdTypes.Side.BEAR, 5000 * 1e18, 300 * 1e6, 0.8e8, false);

        vm.warp(wednesdayMidnight - 3 hours + 50);
        bytes[] memory empty = new bytes[](0);
        router.executeOrder(2, empty);
        assertGt(router.claimableEth(alice), 0, "User must be refunded on FAD rejection");

        // Close order with fresh price should succeed (MEV check still active)
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

        // Stale price (publishTime before commitTime)
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

        // Tuesday 21:00: with zero runway, FAD should NOT activate
        vm.warp(wednesdayMidnight - 3 hours);
        assertFalse(engine.isFadWindow(), "Zero runway disables lookahead");

        // Wednesday itself still works
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
        // USD/JPY = 156.70 (expo=-3 → raw price 156700 * 10^-3)
        // Inverted: JPY/USD = 10^(8-(-3)) / 156700 = 10^11 / 156700 = 638,163
        // That's $0.00638163 in 8 decimals
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = FEED_JPY;
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 638_163; // base price is ~$0.00638 (JPY/USD at launch)
        bool[] memory inv = new bool[](1);
        inv[0] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);
        (uint256 price,) = harness.computeBasketPrice();

        uint256 expectedNorm = uint256(1e11) / 156_700; // = 638,163
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
        bool[] memory inv = new bool[](1); // wrong length

        vm.expectRevert(OrderRouter.OrderRouter__LengthMismatch.selector);
        new BasketPriceHarness(address(mockPyth), ids, w, b, inv);
    }

    function test_H03_MixedInversionsComputeCorrectBasket() public {
        // Feed 0: EUR/USD direct, $1.08 (expo=-8, raw=108_000_000)
        // Feed 1: USD/JPY inverted, 156.70 (expo=-3, raw=156_700) → JPY/USD = 638_163
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = FEED_EUR;
        ids[1] = FEED_JPY;
        uint256[] memory w = new uint256[](2);
        w[0] = 0.5e18;
        w[1] = 0.5e18;
        uint256[] memory b = new uint256[](2);
        b[0] = 108_000_000; // EUR/USD base = $1.08
        b[1] = 638_163; // JPY/USD base = $0.00638163
        bool[] memory inv = new bool[](2);
        inv[0] = false;
        inv[1] = true;

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), ids, w, b, inv);

        mockPyth.setPrice(FEED_EUR, int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_JPY, int64(156_700), int32(-3), 1001);

        (uint256 price,) = harness.computeBasketPrice();

        // EUR component: exact (direct, no rounding)
        // JPY component: slight rounding from integer division in inversion
        // Total ≈ $1.00 within integer rounding tolerance
        assertApproxEqAbs(price, 100_000_000, 100, "Mixed basket at base prices should be ~$1.00");
    }

    function test_H03_OracleEquivalence_SamePricesSameBasket() public {
        // Real-world FX rates:
        //   EUR/USD = 1.0800  (direct in both oracles)
        //   USD/JPY = 156.70  (Chainlink provides JPY/USD=0.00638; Pyth provides USD/JPY=156.70 inverted)
        //   GBP/USD = 1.2600  (direct in both)
        //   USD/CHF = 0.8800  (Chainlink provides CHF/USD=1.1364; Pyth provides USD/CHF=0.88 inverted)

        // Weights: 40% EUR, 20% JPY, 25% GBP, 15% CHF
        uint256[] memory w = new uint256[](4);
        w[0] = 0.4e18;
        w[1] = 0.2e18;
        w[2] = 0.25e18;
        w[3] = 0.15e18;

        // --- Chainlink prices (all XXX/USD, 8 decimals) ---
        int256 eurUsd8 = 108_000_000; // $1.08
        int256 jpyUsd8 = 638_163; // $0.00638163 (= 1/156.70, truncated)
        int256 gbpUsd8 = 126_000_000; // $1.26
        int256 chfUsd8 = 113_636_363; // $1.13636363 (= 1/0.88, truncated)

        // Base prices = same as current prices so basket ≈ $1.00
        uint256[] memory basePrices = new uint256[](4);
        basePrices[0] = uint256(eurUsd8);
        basePrices[1] = uint256(jpyUsd8);
        basePrices[2] = uint256(gbpUsd8);
        basePrices[3] = uint256(chfUsd8);

        // --- BasketOracle (Chainlink) ---
        address[] memory feeds = new address[](4);
        feeds[0] = address(new MockOracle(eurUsd8, "EUR/USD"));
        feeds[1] = address(new MockOracle(jpyUsd8, "JPY/USD"));
        feeds[2] = address(new MockOracle(gbpUsd8, "GBP/USD"));
        feeds[3] = address(new MockOracle(chfUsd8, "CHF/USD"));

        BasketOracle basket = new BasketOracle(feeds, w, basePrices, 500, 2e8, address(this));
        (, int256 chainlinkPrice,,,) = basket.latestRoundData();

        // --- OrderRouter (Pyth) ---
        // Pyth feeds: EUR/USD direct, USD/JPY inverted, GBP/USD direct, USD/CHF inverted
        bytes32[] memory pythIds = new bytes32[](4);
        pythIds[0] = bytes32(uint256(0x01));
        pythIds[1] = bytes32(uint256(0x02));
        pythIds[2] = bytes32(uint256(0x03));
        pythIds[3] = bytes32(uint256(0x04));

        bool[] memory inv = new bool[](4);
        inv[0] = false; // EUR/USD direct
        inv[1] = true; // USD/JPY inverted
        inv[2] = false; // GBP/USD direct
        inv[3] = true; // USD/CHF inverted

        // Pyth prices — direct feeds use expo=-8 (same scale as Chainlink)
        // Inverted feeds use their natural Pyth expo
        // EUR/USD: 1.0800 → price=108000000, expo=-8
        // USD/JPY: 156.70 → price=15670, expo=-2
        // GBP/USD: 1.2600 → price=126000000, expo=-8
        // USD/CHF: 0.8800 → price=8800, expo=-4

        // For inverted feeds, OrderRouter computes: 10^(8-expo) / price
        // USD/JPY: 10^(8-(-2)) / 15670 = 10^10 / 15670 = 638,163 ✓
        // USD/CHF: 10^(8-(-4)) / 8800 = 10^12 / 8800 = 113,636,363 ✓

        BasketPriceHarness harness = new BasketPriceHarness(address(mockPyth), pythIds, w, basePrices, inv);

        mockPyth.setPrice(pythIds[0], int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[1], int64(15_670), int32(-2), 1001);
        mockPyth.setPrice(pythIds[2], int64(126_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[3], int64(8800), int32(-4), 1001);

        (uint256 pythPrice,) = harness.computeBasketPrice();

        // Integer division in _invertPythPrice introduces ≤1 unit rounding per inverted feed.
        // With 2 inverted feeds at 15-20% weight each, max error < 100 units out of 1e8 (~0.0001%).
        assertApproxEqAbs(
            uint256(chainlinkPrice), pythPrice, 100, "BasketOracle and OrderRouter must agree within rounding"
        );
    }

}

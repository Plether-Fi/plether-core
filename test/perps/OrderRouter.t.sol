// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
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

    int64 public mockPrice;
    int32 public mockExpo;
    uint256 public mockPublishTime;

    function setPrice(
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        mockPrice = _price;
        mockExpo = _expo;
        mockPublishTime = _publishTime;
    }

    function getPriceUnsafe(
        bytes32
    ) external view returns (PythStructs.Price memory) {
        return PythStructs.Price({price: mockPrice, conf: 0, expo: mockExpo, publishTime: mockPublishTime});
    }

    uint256 public mockFee;

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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(address(engine), address(pool), address(0), bytes32(0));

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
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
        (uint256 size,,,,,,) = engine.positions(accountId);
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

        uint256 maxLiability = engine.globalBullMaxProfit();
        uint256 freeUsdc = pool.getFreeUSDC();

        uint256 fees = engine.accumulatedFeesUsdc();
        assertEq(freeUsdc, pool.totalAssets() - maxLiability - fees, "Firewall locks Max Liability + pending fees");
        assertEq(maxLiability, 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

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
        (uint256 aliceSize,,,,,,) = engine.positions(aliceId);
        assertEq(aliceSize, 15_000 * 1e18, "Alice should have 15k BULL");

        bytes32 carolId = bytes32(uint256(uint160(carol)));
        (uint256 carolSize,,,,,,) = engine.positions(carolId);
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
        (uint256 size,,,,,,) = engine.positions(aliceId);
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

        // Keeper sent 0.1 ETH msg.value, gets back 0.1 ETH + 0.1 ETH keeper fees
        assertEq(keeperAfter - keeperBefore, 0.1 ether, "Keeper receives all keeper fees + msg.value refund");
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

    uint256 constant CAP_PRICE = 2e8;
    address alice = address(0x111);
    address bob = address(0x222);

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

        clearinghouse = new MarginClearinghouse();
        clearinghouse.supportAsset(address(usdc), 6, 10_000, address(0));

        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, params);
        pool = new HousePool(address(usdc), address(engine));
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(address(engine), address(pool), address(mockPyth), bytes32(0));

        clearinghouse.setOperator(address(engine), true);
        clearinghouse.setOperator(address(router), true);
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

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

    function test_Staleness_CancelsGracefully() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        // publishTime 999 < commitTime 1000 → stale
        mockPyth.setPrice(int64(100_000_000), int32(-8), 999);
        vm.warp(1050);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        assertEq(router.nextExecuteId(), 2, "Queue should advance after stale cancel");

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "No position should be opened");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        // BEAR open slippage: exec <= target required. 1.05e8 > 1e8 → fails
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setPrice(int64(105_000_000), int32(-8), 1001);
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
        mockPyth.setPrice(int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));

        mockPyth.setPrice(int64(100_000_000), int32(-8), 2000);

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

        mockPyth.setPrice(int64(100_000_000), int32(-8), 1001);
        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "BULL open at favorable price should succeed");

        // BEAR open: wants LOW entry. Target $1.10 → exec $1.00 <= $1.10 → succeeds
        vm.warp(2000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setPrice(int64(100_000_000), int32(-8), 2001);
        vm.warp(2050);
        router.executeOrder(2, empty);

        bytes32 trader2Id = bytes32(uint256(uint160(trader2)));
        (size,,,,,,) = engine.positions(trader2Id);
        assertGt(size, 0, "BEAR open at favorable price should succeed");

        // BULL open: adverse. Target $1.10, exec $1.00 → $1.00 >= $1.10 false → rejected
        vm.warp(3000);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1.1e8, false);

        mockPyth.setPrice(int64(100_000_000), int32(-8), 3001);
        vm.warp(3050);
        router.executeOrder(3, empty);

        (size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "BULL open at adverse price should be rejected");

        // BEAR open: adverse. Target $0.90, exec $1.00 → $1.00 <= $0.90 false → rejected
        vm.warp(4000);
        vm.prank(trader2);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 0.9e8, false);

        mockPyth.setPrice(int64(100_000_000), int32(-8), 4001);
        vm.warp(4050);
        router.executeOrder(4, empty);

        (size,,,,,,) = engine.positions(trader2Id);
        assertEq(size, 10_000 * 1e18, "BEAR open at adverse price should be rejected");
    }

    function test_Slippage_CloseOrders_Protected() public {
        vm.warp(1000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(accountId);
        assertTrue(size > 0, "Position should exist");

        // Close BEAR at targetPrice=1.5e8 but Pyth price=1e8
        // BEAR slippage: 1e8 >= 1.5e8? No → order cancelled
        vm.warp(2000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 2001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        router.executeOrder(2, empty);

        (size,,,,,,) = engine.positions(accountId);
        assertGt(size, 0, "Close should be rejected by slippage check");
    }

    function test_BatchExecution_MEVCheckPerOrder() public {
        vm.warp(1000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 1005);

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

        assertEq(router.nextExecuteId(), 3, "Both orders consumed");

        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 10_000 * 1e18, "Only order 1 should execute, order 2 MEV-cancelled");
    }

    function test_C1_CancelledOrder_RefundsUser_NotKeeper() public {
        vm.warp(1000);
        // Set oracle price published at t=999, BEFORE commit at t=1000 → stale
        mockPyth.setPrice(int64(100_000_000), int32(-8), 999);

        // Alice commits with 0.1 ETH keeper fee
        vm.prank(alice);
        router.commitOrder{value: 0.1 ether}(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        address keeper = address(0xBEEF);
        vm.deal(keeper, 1 ether);
        uint256 keeperBalBefore = keeper.balance;

        // Keeper executes with no Pyth update — stale price triggers cancellation
        vm.warp(1050);
        bytes[] memory empty;
        vm.prank(keeper);
        router.executeOrder(1, empty);

        // Keeper should NOT receive Alice's 0.1 ETH fee
        assertEq(keeper.balance, keeperBalBefore, "Keeper should not profit from cancellation");

        // Alice should be able to claim her refunded ETH
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        uint256 aliceClaimable = router.claimableEth(alice);
        assertEq(aliceClaimable, 0.1 ether, "Alice's keeper fee should be refundable");
    }

    function test_BatchExecution_StalePrice_Reverts() public {
        vm.warp(1000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        vm.warp(1000);
        bytes[] memory empty;
        vm.expectRevert(OrderRouter.OrderRouter__OraclePriceTooStale.selector);
        router.executeOrderBatch(1, empty);
    }

}

contract NormalizePythHarness is OrderRouter {

    constructor() OrderRouter(address(1), address(1), address(0), bytes32(0)) {}

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

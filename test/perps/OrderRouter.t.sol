// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {IPyth, OrderRouter} from "../../src/perps/OrderRouter.sol";
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
    ) external view returns (IPyth.Price memory) {
        return IPyth.Price({price: mockPrice, conf: 0, expo: mockExpo, publishTime: mockPublishTime});
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
        (uint256 size,,,,,) = engine.positions(accountId);
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

        assertEq(freeUsdc, pool.totalAssets() - maxLiability, "Firewall locks only Max Liability");
        assertEq(maxLiability, 50_000 * 1e6, "Max liability = $50k for 50k BULL at $1.00");

        uint256 bobMaxWithdraw = juniorVault.maxWithdraw(bob);
        assertEq(bobMaxWithdraw, freeUsdc, "LP should only be able to withdraw unencumbered capital");
    }

    function test_ZeroSizeCommit_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("OrderRouter: Size must be > 0");
        router.commitOrder(CfdTypes.Side.BULL, 0, 500 * 1e6, 1e8, false);
    }

    function test_ExecuteNonPendingOrder_Reverts() public {
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);

        bytes[] memory empty;
        router.executeOrder(1, empty);

        vm.expectRevert("OrderRouter: Order not pending");
        router.executeOrder(2, empty);
    }

    function test_StrictFIFO_OutOfOrder_Reverts() public {
        vm.startPrank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        router.commitOrder(CfdTypes.Side.BULL, 10_000 * 1e18, 500 * 1e6, 1e8, false);
        vm.stopPrank();

        bytes[] memory empty;
        vm.expectRevert("OrderRouter: Strict FIFO violation");
        router.executeOrder(2, empty);
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
        (uint256 size,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "No position should be opened");
    }

    function test_Slippage_CancelsGracefully() public {
        vm.warp(1000);

        // BEAR slippage: executionPrice >= targetPrice. 0.95e8 < 1e8 → fails
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        mockPyth.setPrice(int64(95_000_000), int32(-8), 1001);
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
        vm.expectRevert("OrderRouter: Insufficient Pyth fee");
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
        vm.expectRevert("MEV: Oracle price too stale");
        router.executeLiquidation(accountId, empty);

        vm.warp(2015);
        vm.expectRevert("CfdEngine: Position is solvent");
        router.executeLiquidation(accountId, empty);
    }

    function test_Slippage_CloseOrders_Bypass() public {
        vm.warp(1000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 1001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 500 * 1e6, 100_000_000, false);

        vm.warp(1050);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        bytes32 accountId = bytes32(uint256(uint160(alice)));
        (uint256 size,,,,,) = engine.positions(accountId);
        assertTrue(size > 0, "Position should exist");

        // Close order: BEAR at targetPrice=1.5e8 but Pyth price=1e8
        // BEAR slippage: 1e8 >= 1.5e8? No → would fail. But isClose=true → bypasses
        vm.warp(2000);
        mockPyth.setPrice(int64(100_000_000), int32(-8), 2001);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000 * 1e18, 0, 150_000_000, true);

        vm.warp(2050);
        router.executeOrder(2, empty);

        (size,,,,,) = engine.positions(accountId);
        assertEq(size, 0, "Position should be closed despite slippage");
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

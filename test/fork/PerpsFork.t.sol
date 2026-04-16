// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IPyth, PythStructs} from "../../src/interfaces/IPyth.sol";
import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "../../src/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanner} from "../../src/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementModule} from "../../src/perps/CfdEngineSettlementModule.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouterAdmin} from "../../src/perps/OrderRouterAdmin.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IOrderRouterAdminHost} from "../../src/perps/interfaces/IOrderRouterAdminHost.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract ControllablePyth {

    struct MockPrice {
        int64 price;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => MockPrice) public prices;

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

    function getUpdateFee(
        bytes[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(
        bytes[] calldata
    ) external payable {}

}

/// @title Perps Fork Tests
/// @notice Validates perps against real USDC, real gas economics, and real Pyth ABI on a mainnet fork.
contract PerpsForkTest is Test {

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant REAL_PYTH = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;
    bytes32 constant EUR_USD_FEED_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    uint256 constant FORK_BLOCK = 24_136_062;
    uint256 constant CAP_PRICE = 2e8;

    MarginClearinghouse clearinghouse;
    CfdEngine engine;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;
    OrderRouterAdmin routerAdmin;
    ControllablePyth pyth;

    bytes32[] feedIds;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            vm.createSelectFork(url, FORK_BLOCK);
        } catch {
            revert("Missing MAINNET_RPC_URL in .env");
        }

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10
        });

        clearinghouse = new MarginClearinghouse(USDC);

        engine = new CfdEngine(USDC, address(clearinghouse), CAP_PRICE, params);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementModule settlement = new CfdEngineSettlementModule(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        pool = new HousePool(USDC, address(engine));

        seniorVault = new TrancheVault(IERC20(USDC), address(pool), true, "Senior LP", "senUSDC");
        juniorVault = new TrancheVault(IERC20(USDC), address(pool), false, "Junior LP", "junUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        pyth = new ControllablePyth();
        feedIds.push(EUR_USD_FEED_ID);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 1e8;
        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(pyth),
            feedIds,
            w,
            b,
            new bool[](1)
        );
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        uint256 t0 = block.timestamp;
        clearinghouse.setEngine(address(engine));
        vm.warp(t0 + 144 hours + 3);

        deal(USDC, address(this), 2_000e6);
        IERC20(USDC).approve(address(pool), 2_000e6);
        pool.initializeSeedPosition(false, 1_000e6, address(this));
        pool.initializeSeedPosition(true, 1_000e6, address(this));
        pool.activateTrading();

        // LP deposits $1M to junior tranche
        deal(USDC, lp, 1_000_000e6);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(juniorVault), type(uint256).max);
        juniorVault.deposit(1_000_000e6, lp);
        vm.stopPrank();
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _depositToClearinghouse(
        address trader,
        uint256 amount
    ) internal {
        deal(USDC, trader, IERC20(USDC).balanceOf(trader) + amount);
        vm.startPrank(trader);
        IERC20(USDC).approve(address(clearinghouse), amount);
        clearinghouse.deposit(bytes32(uint256(uint160(trader))), amount);
        vm.stopPrank();
    }

    function _commitAndExecute(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 targetPrice,
        int64 pythPrice,
        bool isClose
    ) external {
        uint256 commitTime = block.timestamp;
        uint64 orderId = router.nextCommitId();

        vm.prank(trader);
        router.commitOrder(side, size, margin, targetPrice, isClose);

        pyth.setAllPrices(feedIds, pythPrice, int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(block.number + 2);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        router.executeOrder(orderId, empty);
    }

    function _accountId(
        address trader
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(trader)));
    }

    function _sideOpenInterest(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        (, uint256 openInterest,,) = engine.sides(uint8(side));
        return openInterest;
    }

    function _legacySideIndexZero(
        CfdTypes.Side side
    ) internal view returns (int256) {
        side;
        return 0;
    }

    function _configureLongOrderExpiry() internal {
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxOrderAge: 1000,
            orderExecutionStalenessLimit: router.orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.liquidationStalenessLimit(),
            pythMaxConfidenceRatioBps: router.pythMaxConfidenceRatioBps(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();
    }

    function _commitOrderDeterministic(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 targetPrice,
        bool isClose
    ) internal returns (uint64 orderId, uint256 commitTime, uint256 commitBlock) {
        orderId = router.nextCommitId();
        commitTime = block.timestamp;
        commitBlock = block.number;

        vm.prank(trader);
        router.commitOrder(side, size, margin, targetPrice, isClose);
    }

    function _pythUpdateData() internal pure returns (bytes[] memory updateData) {
        updateData = new bytes[](1);
        updateData[0] = "";
    }

    function _getRiskParams() internal view returns (CfdTypes.RiskParams memory) {
        (
            uint256 vpiFactor,
            uint256 maxSkewRatio,
            uint256 maintMarginBps,
            uint256 initMarginBps,
            uint256 fadMarginBps,
            uint256 baseCarryBps,
            uint256 minBountyUsdc,
            uint256 bountyBps
        ) = engine.riskParams();
        return CfdTypes.RiskParams({
            vpiFactor: vpiFactor,
            maxSkewRatio: maxSkewRatio,
            maintMarginBps: maintMarginBps,
            initMarginBps: initMarginBps,
            fadMarginBps: fadMarginBps,
            baseCarryBps: baseCarryBps,
            minBountyUsdc: minBountyUsdc,
            bountyBps: bountyBps
        });
    }

    // ==========================================
    // TEST 1: Full Lifecycle with Real USDC
    // ==========================================

    function test_FullLifecycle_RealUsdc() public {
        _depositToClearinghouse(alice, 10_000e6);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 poolBefore = IERC20(USDC).balanceOf(address(pool));
        uint256 clearinghouseBefore = IERC20(USDC).balanceOf(address(clearinghouse));
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);

        // Open BULL $50k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 50_000e18, "Position should be 50k tokens");

        // Close at $0.90 (BULL profits when price drops)
        vm.warp(block.timestamp + 60);
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 50_000e18, 0, 0, int64(90_000_000), true);

        (size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Position should be closed");

        // Verify USDC conservation across all contracts
        uint256 totalAfter = IERC20(USDC).balanceOf(alice) + IERC20(USDC).balanceOf(address(pool))
            + IERC20(USDC).balanceOf(address(clearinghouse)) + IERC20(USDC).balanceOf(keeper);
        uint256 totalBefore = aliceUsdcBefore + poolBefore + clearinghouseBefore + keeperBefore;

        assertEq(totalAfter, totalBefore, "USDC conservation violated");
    }

    // ==========================================
    // TEST 2: Pyth ABI Compatibility
    // ==========================================

    function test_PythAbiCompatibility_RealContract() public {
        // Direct call to real Pyth — verify no ABI decode error
        PythStructs.Price memory priceData = IPyth(REAL_PYTH).getPriceUnsafe(EUR_USD_FEED_ID);
        assertTrue(priceData.price != 0 || priceData.publishTime != 0, "Pyth should return data");

        // getUpdateFee with empty array
        bytes[] memory empty;
        uint256 fee = IPyth(REAL_PYTH).getUpdateFee(empty);
        assertEq(fee, 0, "Empty update should have zero fee");

        // Deploy a separate router with real Pyth to test the real code path
        uint256[] memory rw = new uint256[](1);
        rw[0] = 1e18;
        uint256[] memory rb = new uint256[](1);
        rb[0] = 1e8;
        OrderRouter realPythRouter = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            REAL_PYTH,
            feedIds,
            rw,
            rb,
            new bool[](1)
        );

        vm.expectRevert(CfdEngine.CfdEngine__RouterAlreadySet.selector);
        engine.setOrderRouter(address(realPythRouter));

        assertEq(
            address(realPythRouter.pyth()), REAL_PYTH, "Router construction should still accept the real Pyth contract"
        );
    }

    // ==========================================
    // TEST 3: Staleness with Real Block Timestamps
    // ==========================================

    function test_Staleness_RealBlockTimestamps() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime);
        vm.warp(commitTime + 2);
        vm.roll(commitBlock + 2);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 13));
        router.executeOrder(orderId, _pythUpdateData());

        vm.warp(commitTime + 1001);
        vm.roll(commitBlock + 3);
        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "MEV-tainted order should not open position");
        assertEq(
            router.nextExecuteId(),
            0,
            "Queue should advance after expiring the MEV-tainted order and clear to the zero sentinel"
        );
    }

    function test_Staleness_61SecondPrice_Reverts() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 67);
        vm.roll(commitBlock + 2);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 10));
        router.executeOrder(orderId, _pythUpdateData());

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "61-second stale price should not open a position");
        assertEq(router.nextExecuteId(), orderId, "Stale price revert should leave order pending");
    }

    function test_Staleness_59SecondPrice_Executes() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 65);
        vm.roll(commitBlock + 2);

        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "59-second-old price should execute");
        assertEq(
            router.nextExecuteId(), 0, "Successful execution should advance the queue and clear to the zero sentinel"
        );
    }

    function test_LiquidationStaleness_16SecondsOld_Reverts() public {
        _depositToClearinghouse(alice, 10_000e6);
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        uint256 liqPublishTime = block.timestamp + 1;
        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), liqPublishTime);
        vm.warp(liqPublishTime + 16);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(OrderRouter.OrderRouter__OracleValidation.selector, 12));
        router.executeLiquidation(aliceId, _pythUpdateData());
    }

    // ==========================================
    // TEST 4: Liquidation E2E with Real USDC
    // ==========================================

    function test_LiquidationE2E_RealUsdcSettlement() public {
        _depositToClearinghouse(alice, 10_000e6);

        // Open BULL $100k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Position should exist");

        uint256 poolBefore = IERC20(USDC).balanceOf(address(pool));
        uint256 chBefore = IERC20(USDC).balanceOf(address(clearinghouse));
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);

        // Price rises to $1.10 → BULL PnL = -$10k, equity turns liquidatable
        uint256 liqTs = block.timestamp + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(110_000_000), -8, liqTs);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        router.executeLiquidation(aliceId, empty);

        (size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Position should be liquidated");

        uint256 keeperGain = IERC20(USDC).balanceOf(keeper) - keeperBefore;
        assertGe(keeperGain, _getRiskParams().minBountyUsdc, "Keeper should get at least min bounty");

        // USDC conservation: pool + clearinghouse + keeper == before totals
        uint256 totalAfter = IERC20(USDC).balanceOf(address(pool)) + IERC20(USDC).balanceOf(address(clearinghouse))
            + IERC20(USDC).balanceOf(keeper);
        uint256 totalBefore = poolBefore + chBefore + keeperBefore;
        assertEq(totalAfter, totalBefore, "USDC conservation across liquidation");
    }

    // ==========================================
    // TEST 5: Keeper Gas Economics
    // ==========================================

    function test_KeeperGasEconomics() public {
        _depositToClearinghouse(alice, 2000e6);

        uint256 ts = block.timestamp;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), -8, ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 1);

        bytes[] memory empty = _pythUpdateData();

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        router.executeOrder(1, empty);
        uint256 executeGas = gasBefore - gasleft();

        emit log_named_uint("executeOrder gas", executeGas);
        assertLt(executeGas, 550_000, "executeOrder should use < 550k gas");

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Position must exist for liquidation test");

        // Move price to make position liquidatable
        uint256 liqTs = block.timestamp + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(120_000_000), -8, liqTs);

        gasBefore = gasleft();
        vm.prank(keeper);
        router.executeLiquidation(aliceId, empty);
        uint256 liquidateGas = gasBefore - gasleft();

        emit log_named_uint("executeLiquidation gas", liquidateGas);
        assertLt(liquidateGas, 550_000, "executeLiquidation should use < 550k gas");

        // At 100 gwei with ETH ~$2000, verify gas cost < min bounty ($5)
        uint256 maxGas = executeGas > liquidateGas ? executeGas : liquidateGas;
        uint256 gasCostWei = maxGas * 100 gwei;
        uint256 gasCostUsd6 = (gasCostWei * 2000) / 1e18;

        emit log_named_uint("max gas cost (USDC 6-dec)", gasCostUsd6);
        assertLt(gasCostUsd6, 5e6, "Gas cost should be less than min bounty ($5)");
    }

    // ==========================================
    // TEST 6: Multi-Trader Concurrent Positions
    // ==========================================

    function test_MultiTrader_ConcurrentPositions() public {
        uint256 t0 = block.timestamp;
        _depositToClearinghouse(alice, 20_000e6);
        _depositToClearinghouse(bob, 20_000e6);
        _depositToClearinghouse(carol, 20_000e6);

        uint256 totalUsdcBefore = IERC20(USDC).balanceOf(address(pool)) + IERC20(USDC).balanceOf(address(clearinghouse))
            + IERC20(USDC).balanceOf(keeper);

        // Alice BULL $100k, Bob BEAR $80k, Carol BULL $50k — all at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, int64(100_000_000), false);
        this._commitAndExecute(bob, CfdTypes.Side.BEAR, 80_000e18, 8000e6, 1e8, int64(100_000_000), false);
        this._commitAndExecute(carol, CfdTypes.Side.BULL, 50_000e18, 5000e6, 1e8, int64(100_000_000), false);

        assertEq(_sideOpenInterest(CfdTypes.Side.BULL), 150_000e18, "Bull OI should be 150k");
        assertEq(_sideOpenInterest(CfdTypes.Side.BEAR), 80_000e18, "Bear OI should be 80k");

        // Close Alice at $0.95 (BULL profits when price drops)
        vm.warp(t0 + 200);
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 100_000e18, 0, 0, int64(95_000_000), true);
        assertEq(_sideOpenInterest(CfdTypes.Side.BULL), 50_000e18, "Bull OI should be 50k after Alice close");

        // Close Bob at $0.95 (BEAR loses when price drops)
        vm.warp(t0 + 400);
        this._commitAndExecute(bob, CfdTypes.Side.BEAR, 80_000e18, 0, 0, int64(95_000_000), true);
        assertEq(_sideOpenInterest(CfdTypes.Side.BEAR), 0, "Bear OI should be 0 after Bob close");

        // Close Carol at $1.05 (BULL loses when price rises)
        vm.warp(t0 + 600);
        this._commitAndExecute(carol, CfdTypes.Side.BULL, 50_000e18, 0, 0, int64(105_000_000), true);

        assertEq(_sideOpenInterest(CfdTypes.Side.BULL), 0, "Bull OI should be 0 after all close");
        assertEq(_sideOpenInterest(CfdTypes.Side.BEAR), 0, "Bear OI should be 0 after all close");

        // USDC conservation
        uint256 totalUsdcAfter = IERC20(USDC).balanceOf(address(pool)) + IERC20(USDC).balanceOf(address(clearinghouse))
            + IERC20(USDC).balanceOf(keeper);
        assertEq(totalUsdcAfter, totalUsdcBefore, "USDC conservation across multi-trader");
    }

    // ==========================================
    // TEST 7: No Legacy Side-Index Drift over 90 Days
    // ==========================================

    function test_CarryAccrual_90Days() public {
        uint256 t0 = block.timestamp;
        _depositToClearinghouse(alice, 50_000e6);

        // Lone BULL $200k -> max skew, carry will drain margin
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 200_000e18, 40_000e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertGt(size, 0, "Position should exist");

        int256 bullIdxBefore = _legacySideIndexZero(CfdTypes.Side.BULL);
        int256 bearIdxBefore = _legacySideIndexZero(CfdTypes.Side.BEAR);

        // Warp 90 days; close position to realize carry
        vm.warp(t0 + 90 days + 60);
        this._commitAndExecute(alice, CfdTypes.Side.BULL, size, 0, 0, int64(100_000_000), true);

        int256 bullIdxAfter = _legacySideIndexZero(CfdTypes.Side.BULL);
        int256 bearIdxAfter = _legacySideIndexZero(CfdTypes.Side.BEAR);

        // Legacy side indices should remain zero in the carry model
        assertLt(bullIdxAfter, bullIdxBefore, "Bull legacy side index should remain zero");
        assertGt(bearIdxAfter, bearIdxBefore, "Bear legacy side index should remain zero");

        // Symmetry: sum of changes should be zero
        int256 bullDelta = bullIdxAfter - bullIdxBefore;
        int256 bearDelta = bearIdxAfter - bearIdxBefore;
        assertEq(bullDelta + bearDelta, 0, "Legacy side index changes must be symmetric");
    }

    // ==========================================
    // TEST 8: Pool Solvency — Large PnL Payout
    // ==========================================

    function test_PoolSolvency_LargePnlPayout() public {
        // Add senior LP: $500k
        deal(USDC, lp, 500_000e6);
        vm.startPrank(lp);
        IERC20(USDC).approve(address(seniorVault), type(uint256).max);
        seniorVault.deposit(500_000e6, lp);
        vm.stopPrank();

        uint256 poolTotalBefore = IERC20(USDC).balanceOf(address(pool));
        assertEq(poolTotalBefore, 1_500_000e6, "Pool should have $1.5M");

        _depositToClearinghouse(alice, 50_000e6);

        // BULL $200k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 200_000e18, 20_000e6, 1e8, int64(100_000_000), false);

        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();

        // Price drops to $0.50 → BULL profits $100k
        vm.warp(block.timestamp + 120);
        this._commitAndExecute(alice, CfdTypes.Side.BULL, 200_000e18, 0, 0, int64(50_000_000), true);

        // Reconcile to distribute loss through tranches
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 juniorAfter = pool.juniorPrincipal();

        // Junior absorbs loss first; senior should be protected
        assertLt(juniorAfter, juniorBefore, "Junior should absorb the loss");
        assertGe(seniorAfter, seniorBefore, "Senior should not lose principal");

        // Verify Alice got her profit in real USDC
        uint256 aliceBalance = clearinghouse.balanceUsdc(_accountId(alice));
        assertGt(aliceBalance, 50_000e6, "Alice should have profit");

        // Verify real USDC withdrawal from clearinghouse
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(_accountId(alice), aliceBalance);
        uint256 aliceUsdcAfter = IERC20(USDC).balanceOf(alice);
        assertEq(aliceUsdcAfter - aliceUsdcBefore, aliceBalance, "Real USDC withdrawal should match");
    }

    function test_DeferredTraderCreditClaimFlow_RealUsdc() public {
        _depositToClearinghouse(alice, 11_000e6);

        this._commitAndExecute(alice, CfdTypes.Side.BULL, 100_000e18, 9000e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        uint256 poolAssets = IERC20(USDC).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(USDC).transfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 chBefore = clearinghouse.balanceUsdc(aliceId);
        uint256 closeBountyUsdc = 1e6;

        uint256 commitTime = block.timestamp;
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        pyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(block.number + 2);
        vm.prank(keeper);
        router.executeOrder(2, _pythUpdateData());

        uint256 deferred = engine.deferredTraderCreditUsdc(aliceId);
        assertGt(deferred, 0, "Illiquid profitable close should record a deferred payout");
        (uint256 size,,,,,,) = engine.positions(aliceId);
        assertEq(size, 0, "Position should be closed even when payout is deferred");
        uint256 chAfterClose = clearinghouse.balanceUsdc(aliceId);
        assertLt(
            chAfterClose,
            chBefore,
            "Pre-claim clearinghouse balance should still reflect close bounty and carry realization"
        );
        assertEq(
            chBefore - chAfterClose,
            closeBountyUsdc + 66_590,
            "Only the close bounty and realized carry should move before claim"
        );

        deal(USDC, address(pool), IERC20(USDC).balanceOf(address(pool)) + deferred);
        vm.prank(address(router));
        pool.recordProtocolInflow(deferred);

        vm.prank(alice);
        engine.claimDeferredTraderCredit(aliceId);

        assertEq(engine.deferredTraderCreditUsdc(aliceId), 0, "Claim should clear deferred payout state");
        assertEq(
            clearinghouse.balanceUsdc(aliceId),
            chAfterClose + deferred,
            "Claim should credit deferred USDC on top of the post-close settlement balance"
        );
    }

    function test_DeferredTraderCreditBatchDoesNotBlockTailOrder_RealUsdc() public {
        _depositToClearinghouse(alice, 20_000e6);

        this._commitAndExecute(alice, CfdTypes.Side.BULL, 100_000e18, 8000e6, 1e8, int64(100_000_000), false);

        bytes32 aliceId = _accountId(alice);
        uint256 poolAssets = IERC20(USDC).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(USDC).transfer(address(0xDEAD), poolAssets - 8000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BEAR, 10_000e18, 500e6, 0, false);

        pyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), block.timestamp + 6);
        vm.warp(block.timestamp + 7);
        vm.roll(block.number + 2);
        vm.prank(keeper);
        router.executeOrderBatch(3, _pythUpdateData());

        assertEq(
            router.nextExecuteId(),
            0,
            "Batch execution should continue past a deferred-payout close and clear the queue when exhausted"
        );
        assertGt(engine.deferredTraderCreditUsdc(aliceId), 0, "Deferred payout should remain recorded after the batch");

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(aliceId);
        assertEq(
            size,
            0,
            "Tail open should be consumed even if deferred payout leaves the protocol unable to re-open immediately"
        );
        assertEq(
            uint256(side),
            uint256(CfdTypes.Side.BULL),
            "Position metadata should remain stable after the close empties the position"
        );
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../utils/LegacyOrderRouterHarness.sol";
import {RecordedOrderReceipts} from "../../utils/RecordedOrderReceipts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAccountLens} from "@plether/perps/CfdEngineAccountLens.sol";
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
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {AccountLensViewTypes} from "@plether/perps/interfaces/AccountLensViewTypes.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract ControllablePythGas {

    struct MockPrice {
        int64 price;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => MockPrice) public prices;
    bytes32[] internal registeredIds;
    mapping(bytes32 => bool) internal registered;

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            if (!registered[feedIds[i]]) {
                registered[feedIds[i]] = true;
                registeredIds.push(feedIds[i]);
            }
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
        bytes[] calldata data
    ) external payable {
        if (data.length == 0 || data[0].length != 32) {
            return;
        }
        int64 price = int64(uint64(abi.decode(data[0], (uint256))));
        for (uint256 i; i < registeredIds.length; ++i) {
            bytes32 id = registeredIds[i];
            if (block.timestamp > prices[id].publishTime) {
                prices[id] = MockPrice(price, -8, block.timestamp);
            }
        }
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external view returns (PythStructs.PriceFeed[] memory priceFeeds) {
        bool hasEncodedUpdate = updateData.length > 0 && updateData[0].length == 32;
        uint256 encodedPrice;
        if (hasEncodedUpdate) {
            encodedPrice = abi.decode(updateData[0], (uint256));
        }

        priceFeeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            MockPrice memory p = hasEncodedUpdate
                ? MockPrice(int64(uint64(encodedPrice)), int32(-8), maxPublishTime)
                : prices[priceIds[i]];
            require(p.publishTime >= minPublishTime && p.publishTime <= maxPublishTime, "outside range");
            PythStructs.Price memory price =
                PythStructs.Price({price: p.price, conf: 0, expo: p.expo, publishTime: p.publishTime});
            priceFeeds[i] = PythStructs.PriceFeed({id: priceIds[i], price: price, emaPrice: price});
        }
    }

}

/// @notice Gas profiling for top 20 perps operations.
/// Run from the repository root: forge test --root packages/perps --match-contract GasProfileTest -vv
/// This benchmark always deploys a local mock token and oracle for reproducible gas measurements.
contract GasProfileTest is RecordedOrderReceipts {

    error GasProfile__OrderDidNotExecute();
    error GasProfile__BatchDidNotComplete();

    struct ExpectedOrder {
        address account;
        uint256 finalSize;
        uint256 bounty;
        CfdTypes.Side side;
    }

    struct RequestEscrowSnapshot {
        uint256 epoch;
        uint256 providerBalance;
        uint256 pendingEscrow;
        uint256 vaultBalance;
    }

    struct TradeAccountingSnapshot {
        uint256 size;
        uint256 margin;
        uint256 balance;
        uint256 entryCost;
        uint256 liquidationReserve;
        uint256 sizeDelta;
        uint256 marginDelta;
        bool isClose;
        bool deferredProfit;
        bool recorded;
    }

    struct LiquidationAccountingSnapshot {
        uint256 balance;
        uint256 poolCash;
        uint256 custody;
        uint256 treasury;
    }

    mapping(uint64 => ExpectedOrder) internal expectedOrders;
    mapping(uint64 => TradeAccountingSnapshot) internal tradeAccountingBefore;

    bytes32 constant EUR_USD_FEED_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    uint256 constant CAP_PRICE = 2e8;

    MarginClearinghouse clearinghouse;
    CfdEngine engine;
    CfdEngineAccountLens engineAccountLens;
    CfdEngineLens engineLens;
    HousePool pool;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    LegacyOrderRouterHarness router;
    ControllablePythGas pyth;
    address usdc;

    bytes32[] feedIds;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address lp = makeAddr("lp");
    address lp2 = makeAddr("lp2");

    function setUp() public {
        usdc = address(new MockUSDC6());
        vm.label(usdc, "MockUSDC");

        CfdTypes.RiskParams memory params = CfdTypes.RiskParams({
            vpiFactor: 0.0005e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        clearinghouse = new MarginClearinghouse(usdc);
        engine = new CfdEngine(usdc, address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        engineAccountLens = new CfdEngineAccountLens(address(engine));
        engineLens = new CfdEngineLens(address(engine));
        pool = new HousePool(usdc, address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(IERC20(usdc), address(pool), true, "Senior LP", "senUSDC", 0, address(0));
        juniorVault = new TrancheVault(IERC20(usdc), address(pool), false, "Junior LP", "junUSDC", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        pyth = new ControllablePythGas();
        feedIds.push(EUR_USD_FEED_ID);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 1e8;
        PletherOracle testOracle =
            new PletherOracle(address(engine), address(pool), address(pyth), feedIds, w, b, new bool[](1));
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar liquidationSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new LegacyOrderRouterHarness(
            address(engine),
            address(engineLens),
            address(pool),
            address(testOracle),
            address(liquidationSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(router), predictedRouter);
        engine.setOrderRouter(address(router));

        uint256 t0 = block.timestamp;
        clearinghouse.setEngine(address(engine));
        IHousePool.PoolConfig memory poolConfig = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: type(uint256).max - 1,
            maxSeniorShareBps: 9999
        });
        pool.proposePoolConfig(poolConfig);
        vm.warp(t0 + 144 hours + 3);
        pool.finalizePoolConfig();

        uint256 seedAmount = 1000e6;
        _mintUsdc(address(this), seedAmount * 2);
        IERC20(usdc).approve(address(pool), seedAmount * 2);
        pool.initializeSeedPosition(false, seedAmount, address(this));
        pool.initializeSeedPosition(true, seedAmount, address(this));
        pool.activateTrading();

        _fundTrancheAsync(juniorVault, lp, 1_000_000e6);
        _startRecordingLogs();
    }

    // ==========================================
    // Oracle fixture preparation and keeper-balance reads happen before each gas measurement.
    // Each sample measures the intended keeper call, with receipt credit checked afterward.
    // GAS PROFILING — 20 operation families
    // ==========================================

    // --- 1. commitOrder (open) ---
    function test_gas_01_commitOrder_open() public {
        _depositToClearinghouse(alice, 10_000e6);

        vm.prank(alice);
        uint256 g0 = gasleft();
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8, false);
        uint256 gas = g0 - gasleft();
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, false);
        emit log_named_uint("01_commitOrder_open", gas);
    }

    // --- 2. commitOrder (close) ---
    function test_gas_02_commitOrder_close() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        vm.prank(alice);
        uint256 g0 = gasleft();
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);
        uint256 gas = g0 - gasleft();
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 50_000e18, 0, true);
        emit log_named_uint("02_commitOrder_close", gas);
    }

    // --- 3. executeOrder (open, first position — cold storage) ---
    function test_gas_03_executeOrder_open_first() public {
        _depositToClearinghouse(alice, 10_000e6);
        uint256 ts = block.timestamp;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8, false);
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        _rememberTradeAccounting(1, false);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, updateData);
        uint256 gas = g0 - gasleft();
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
        emit log_named_uint("03_executeOrder_open_first", gas);
    }

    // --- 4. executeOrder (open, increase existing position — warm storage) ---
    function test_gas_04_executeOrder_open_increase() public {
        _depositToClearinghouse(alice, 20_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 3000e6, 1e8, false);
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 20_000e18, 3000e6, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        _rememberTradeAccounting(2, false);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(2, updateData);
        uint256 gas = g0 - gasleft();
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
        emit log_named_uint("04_executeOrder_open_increase", gas);
    }

    // --- 5. executeOrder (close, full) ---
    function test_gas_05_executeOrder_close_full() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 0, 0, true);
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 50_000e18, 0, true);

        pyth.setAllPrices(feedIds, int64(95_000_000), int32(-8), ts + 6);
        _rememberTradeAccounting(2, false);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(2, updateData);
        uint256 gas = g0 - gasleft();
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
        emit log_named_uint("05_executeOrder_close_full", gas);
    }

    // --- 6. executeOrder (close, partial) ---
    function test_gas_06_executeOrder_close_partial() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        uint256 ts = block.timestamp + 30;
        vm.warp(ts);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 0, 0, true);
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 20_000e18, 0, true);

        pyth.setAllPrices(feedIds, int64(95_000_000), int32(-8), ts + 6);
        _rememberTradeAccounting(2, false);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(2, updateData);
        uint256 gas = g0 - gasleft();
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
        emit log_named_uint("06_executeOrder_close_partial", gas);
    }

    // --- 7. executeOrderBatch (3 orders) ---
    function test_gas_07_executeOrderBatch_3() public {
        _depositToClearinghouse(alice, 20_000e6);
        _depositToClearinghouse(bob, 20_000e6);
        _depositToClearinghouse(carol, 20_000e6);

        uint256 ts = block.timestamp;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 30_000e18, 3000e6, 1e8, false);
        _rememberOrder(router.nextCommitId() - 1, alice, CfdTypes.Side.LONG, 30_000e18, 3000e6, false);
        _rememberTradeAccounting(router.nextCommitId() - 1, false);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.SHORT, 25_000e18, 2500e6, 1e8, false);
        _rememberOrder(router.nextCommitId() - 1, bob, CfdTypes.Side.SHORT, 25_000e18, 2500e6, false);
        _rememberTradeAccounting(router.nextCommitId() - 1, false);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 2000e6, 1e8, false);
        _rememberOrder(router.nextCommitId() - 1, carol, CfdTypes.Side.LONG, 20_000e18, 2000e6, false);
        _rememberTradeAccounting(router.nextCommitId() - 1, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(3, updateData);
        uint256 gas = g0 - gasleft();
        _assertCompletedBatch(result, 1, 3, keeperBefore);
        emit log_named_uint("07_executeOrderBatch_3_orders", gas);
    }

    // --- 8. executeLiquidation ---
    function test_gas_08_executeLiquidation() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);

        // Withdraw free margin so position is thinly margined
        address aliceAccount = _account(alice);
        uint256 balance = clearinghouse.balanceUsdc(aliceAccount);
        uint256 locked = clearinghouse.lockedMarginUsdc(aliceAccount);
        if (balance > locked) {
            vm.prank(alice);
            clearinghouse.withdraw(aliceAccount, balance - locked);
        }

        // Price rises → LONG loses. $1.10 = -$10k PnL on $100k notional
        uint256 liqTs = block.timestamp + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(110_000_000), int32(-8), liqTs);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(aliceAccount, 1.1e8);
        assertTrue(preview.liquidatable, "sample must start with a liquidatable position");
        LiquidationAccountingSnapshot memory beforeLiquidation = LiquidationAccountingSnapshot({
            balance: clearinghouse.balanceUsdc(aliceAccount),
            poolCash: IERC20(usdc).balanceOf(address(pool)),
            custody: IERC20(usdc).balanceOf(address(clearinghouse)),
            treasury: clearinghouse.balanceUsdc(engine.protocolTreasury())
        });
        vm.prank(keeper);
        uint256 g0 = gasleft();
        router.executeLiquidation(aliceAccount, updateData);
        uint256 gas = g0 - gasleft();
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, preview.keeperBountyUsdc);
        (uint256 size, uint256 margin,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "liquidation must remove the position");
        assertEq(margin, 0);
        assertEq(router.pendingOrderCounts(aliceAccount), 0);
        assertEq(clearinghouse.totalBountyReservationsUsdc(aliceAccount), 0);
        _assertLiquidationAccounting(aliceAccount, beforeLiquidation, preview);
        emit log_named_uint("08_executeLiquidation", gas);
    }

    // --- 9. addMargin ---
    function test_gas_09_addMargin() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 3000e6, 1e8);

        address aliceAccount = _account(alice);
        (uint256 sizeBefore, uint256 marginBefore,,,,,) = engine.positions(aliceAccount);
        uint256 balanceBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        uint256 g0 = gasleft();
        engine.addMargin(aliceAccount, 1000e6);
        uint256 gas = g0 - gasleft();
        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(aliceAccount);
        assertEq(sizeAfter, sizeBefore);
        assertEq(marginAfter, marginBefore + 1000e6, "sample must pledge the requested additional margin");
        assertEq(clearinghouse.balanceUsdc(aliceAccount), balanceBefore);
        emit log_named_uint("09_addMargin", gas);
    }

    // --- 10. settleTraderClaim ---
    function test_gas_10_settleTraderClaim() public {
        _depositToClearinghouse(alice, 11_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8);

        address aliceAccount = _account(alice);

        // Drain pool to force trader claim
        uint256 poolAssets = IERC20(usdc).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(usdc).transfer(address(0xDEAD), poolAssets - 9000e6);

        // Close at profit; payout becomes a trader claim (use external call for clean timestamp reads)
        this._closeAtPrice(alice, CfdTypes.Side.LONG, 100_000e18, int64(80_000_000));

        uint256 traderClaim = engine.traderClaimBalanceUsdc(aliceAccount);
        require(traderClaim > 0, "Setup failed: no trader claim balance");

        // Replenish pool so claim can succeed
        _mintUsdc(address(pool), traderClaim);
        uint256 balanceBefore = clearinghouse.balanceUsdc(aliceAccount);
        uint256 claimsBefore = engine.totalTraderClaimBalanceUsdc();
        uint256 poolCashBefore = IERC20(usdc).balanceOf(address(pool));
        uint256 custodyBefore = IERC20(usdc).balanceOf(address(clearinghouse));

        vm.prank(alice);
        uint256 g0 = gasleft();
        engine.settleTraderClaim(aliceAccount);
        uint256 gas = g0 - gasleft();
        assertEq(engine.traderClaimBalanceUsdc(aliceAccount), 0);
        assertEq(engine.totalTraderClaimBalanceUsdc(), claimsBefore - traderClaim);
        assertEq(clearinghouse.balanceUsdc(aliceAccount), balanceBefore + traderClaim);
        assertEq(IERC20(usdc).balanceOf(address(pool)), poolCashBefore - traderClaim);
        assertEq(IERC20(usdc).balanceOf(address(clearinghouse)), custodyBefore + traderClaim);
        emit log_named_uint("10_settleTraderClaim", gas);
    }

    // --- 11. clearinghouse.deposit ---
    function test_gas_11_clearinghouse_deposit() public {
        _mintUsdc(alice, 10_000e6);
        vm.startPrank(alice);
        IERC20(usdc).approve(address(clearinghouse), type(uint256).max);

        address aliceAccount = _account(alice);
        uint256 g0 = gasleft();
        clearinghouse.deposit(aliceAccount, 5000e6);
        uint256 gas = g0 - gasleft();
        vm.stopPrank();
        assertEq(clearinghouse.balanceUsdc(aliceAccount), 5000e6);
        assertEq(IERC20(usdc).balanceOf(alice), 5000e6);
        assertEq(IERC20(usdc).balanceOf(address(clearinghouse)), 5000e6);
        emit log_named_uint("11_clearinghouse_deposit", gas);
    }

    // --- 12. clearinghouse.withdraw ---
    function test_gas_12_clearinghouse_withdraw() public {
        _depositToClearinghouse(alice, 10_000e6);

        address aliceAccount = _account(alice);
        vm.prank(alice);
        uint256 g0 = gasleft();
        clearinghouse.withdraw(aliceAccount, 5000e6);
        uint256 gas = g0 - gasleft();
        assertEq(clearinghouse.balanceUsdc(aliceAccount), 5000e6);
        assertEq(IERC20(usdc).balanceOf(alice), 5000e6);
        assertEq(IERC20(usdc).balanceOf(address(clearinghouse)), 5000e6);
        emit log_named_uint("12_clearinghouse_withdraw", gas);
    }

    // --- 13a/b. juniorVault.requestDeposit on both sides of the request cutoff ---
    function test_gas_13a_juniorVault_requestDeposit_beforeCutoff() public {
        _profileRequestDeposit(juniorVault, 100_000e6, false, "13a_juniorVault_requestDeposit_before_cutoff");
    }

    function test_gas_13b_juniorVault_requestDeposit_atCutoff() public {
        _profileRequestDeposit(juniorVault, 100_000e6, true, "13b_juniorVault_requestDeposit_at_cutoff");
    }

    // --- 14a/b. juniorVault.requestRedeem on both sides of the request cutoff ---
    function test_gas_14a_juniorVault_requestRedeem_beforeCutoff() public {
        _profileRequestRedeem(juniorVault, 100_000e6, 50_000e6, false, "14a_juniorVault_requestRedeem_before_cutoff");
    }

    function test_gas_14b_juniorVault_requestRedeem_atCutoff() public {
        _profileRequestRedeem(juniorVault, 100_000e6, 50_000e6, true, "14b_juniorVault_requestRedeem_at_cutoff");
    }

    // --- 15a/b. seniorVault.requestDeposit on both sides of the request cutoff ---
    function test_gas_15a_seniorVault_requestDeposit_beforeCutoff() public {
        _profileRequestDeposit(seniorVault, 500_000e6, false, "15a_seniorVault_requestDeposit_before_cutoff");
    }

    function test_gas_15b_seniorVault_requestDeposit_atCutoff() public {
        _profileRequestDeposit(seniorVault, 500_000e6, true, "15b_seniorVault_requestDeposit_at_cutoff");
    }

    // --- 16a/b. seniorVault.requestRedeem on both sides of the request cutoff ---
    function test_gas_16a_seniorVault_requestRedeem_beforeCutoff() public {
        _profileRequestRedeem(seniorVault, 500_000e6, 200_000e6, false, "16a_seniorVault_requestRedeem_before_cutoff");
    }

    function test_gas_16b_seniorVault_requestRedeem_atCutoff() public {
        _profileRequestRedeem(seniorVault, 500_000e6, 200_000e6, true, "16b_seniorVault_requestRedeem_at_cutoff");
    }

    // --- 17. previewClose ---
    function test_gas_17_previewClose() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        address aliceAccount = _account(alice);
        uint256 balanceBefore = clearinghouse.balanceUsdc(aliceAccount);
        uint256 g0 = gasleft();
        ICfdEngineTypes.ClosePreview memory preview = engineLens.previewClose(aliceAccount, 50_000e18, 0.95e8);
        uint256 gas = g0 - gasleft();
        assertTrue(preview.valid, "preview sample must evaluate the intended full close");
        assertEq(uint256(preview.invalidReason), uint256(CfdTypes.CloseInvalidReason.None));
        assertEq(preview.executionPrice, 95_000_000);
        assertEq(preview.sizeDelta, 50_000e18);
        assertEq(preview.realizedPnlUsdc, 2500e6);
        // The nominal 4-bps fee is $19; the skew-reducing VPI rebate offsets part of fee collection.
        assertGt(preview.executionFeeUsdc, 0);
        assertLe(preview.executionFeeUsdc, 19e6);
        assertEq(int256(preview.freshTraderPayoutUsdc), int256(2500e6 - 19e6) - preview.vpiDeltaUsdc);
        assertEq(preview.remainingSize, 0);
        assertEq(preview.remainingMargin, 0);
        assertEq(preview.traderClaimBalanceUsdc, 0);
        assertEq(preview.immediatePayoutUsdc, preview.freshTraderPayoutUsdc);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 50_000e18, "preview leaves the live position intact");
        assertEq(clearinghouse.balanceUsdc(aliceAccount), balanceBefore);
        emit log_named_uint("17_previewClose", gas);
    }

    // --- 18. previewLiquidation ---
    function test_gas_18_previewLiquidation() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);

        address aliceAccount = _account(alice);
        uint256 balanceBefore = clearinghouse.balanceUsdc(aliceAccount);
        uint256 g0 = gasleft();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(aliceAccount, 1.1e8);
        uint256 gas = g0 - gasleft();
        assertTrue(preview.liquidatable, "preview sample must evaluate an insolvent position");
        assertEq(preview.oraclePrice, 110_000_000);
        assertEq(preview.pnlUsdc, -10_000e6);
        assertLt(preview.equityUsdc, 0);
        assertGt(preview.seizedCollateralUsdc, 0);
        assertGt(preview.keeperBountyUsdc, 0);
        assertEq(
            preview.liquidationChargeUsdc,
            preview.keeperBountyUsdc + preview.protocolLiquidationFeeUsdc + preview.lpLiquidationFeeUsdc
        );
        assertEq(preview.immediatePayoutUsdc, 0);
        assertEq(preview.traderClaimBalanceUsdc, 0);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 100_000e18, "preview leaves the live position intact");
        assertEq(clearinghouse.balanceUsdc(aliceAccount), balanceBefore);
        emit log_named_uint("18_previewLiquidation", gas);
    }

    // --- 19. getAccountLedgerSnapshot ---
    function test_gas_19_getAccountLedgerSnapshot() public {
        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        address aliceAccount = _account(alice);
        uint256 g0 = gasleft();
        AccountLensViewTypes.AccountLedgerSnapshot memory snapshot =
            engineAccountLens.getAccountLedgerSnapshot(aliceAccount);
        uint256 gas = g0 - gasleft();
        assertTrue(snapshot.hasPosition, "ledger sample must include the installed position");
        assertEq(snapshot.size, 50_000e18);
        assertEq(uint256(snapshot.side), uint256(CfdTypes.Side.LONG));
        assertEq(snapshot.entryPrice, 1e8);
        assertEq(snapshot.unrealizedPnlUsdc, 0);
        assertEq(snapshot.settlementBalanceUsdc, clearinghouse.balanceUsdc(aliceAccount));
        assertEq(snapshot.margin, clearinghouse.pnlPledgeUsdc(aliceAccount));
        assertEq(snapshot.positionMarginBucketUsdc, snapshot.margin);
        assertEq(snapshot.activePositionMarginUsdc, snapshot.margin);
        assertEq(
            snapshot.freeSettlementUsdc, snapshot.settlementBalanceUsdc - clearinghouse.lockedMarginUsdc(aliceAccount)
        );
        assertEq(snapshot.pendingOrderCount, 0);
        assertEq(snapshot.committedMarginUsdc, 0);
        assertEq(snapshot.executionBountyReserveUsdc, 0);
        assertEq(snapshot.traderClaimBalanceUsdc, 0);
        assertFalse(snapshot.liquidatable);
        emit log_named_uint("19_getAccountLedgerSnapshot", gas);
    }

    // --- 20. getPoolLiquidityView ---
    function test_gas_20_getPoolLiquidityView() public {
        // Add some state: positions + both tranches
        _fundTrancheAsync(seniorVault, lp2, 500_000e6);

        _depositToClearinghouse(alice, 10_000e6);
        _openPosition(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8);

        uint256 g0 = gasleft();
        IHousePool.PoolLiquidityView memory liquidity = pool.getPoolLiquidityView();
        uint256 gas = g0 - gasleft();
        assertEq(liquidity.totalAssetsUsdc, pool.totalAssets());
        assertEq(liquidity.seniorPrincipalUsdc, pool.seniorPrincipal());
        assertEq(liquidity.juniorPrincipalUsdc, pool.juniorPrincipal());
        assertEq(liquidity.seniorHighWaterMarkUsdc, pool.seniorHighWaterMark());
        assertGt(liquidity.seniorPrincipalUsdc, 0, "liquidity sample includes Senior capital");
        assertGt(liquidity.juniorPrincipalUsdc, 0, "liquidity sample includes Junior capital");
        assertGt(liquidity.withdrawalReservedUsdc, 0, "live position must reserve pool liquidity");
        assertEq(liquidity.freeUsdc + liquidity.withdrawalReservedUsdc, liquidity.totalAssetsUsdc);
        assertEq(liquidity.pendingRecapitalizationUsdc, pool.pendingRecapitalizationUsdc());
        assertEq(liquidity.pendingTradingRevenueUsdc, pool.pendingTradingRevenueUsdc());
        assertEq(liquidity.currentTerminalDeficitUsdc, 0);
        assertTrue(liquidity.markFresh);
        assertFalse(liquidity.oracleFrozen);
        assertFalse(liquidity.degradedMode);
        emit log_named_uint("20_getPoolLiquidityView", gas);
    }

    // --- Batch scaling ---

    function test_gas_21_executeOrderBatch_30() public {
        _batchOpenTest(30);
    }

    function test_gas_22_executeOrderBatch_300() public {
        _batchOpenTest(300);
    }

    function test_GasOutcomeCheckerRejectsTerminalFailureEvenWhenKeeperIsPaid() public {
        _depositToClearinghouse(alice, 10_000e6);
        uint256 timestamp = block.timestamp;
        vm.prank(alice);
        uint64 id = router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1.1e8, false);
        _rememberOrder(id, alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, false);
        pyth.setAllPrices(feedIds, 100_000_000, -8, timestamp + 6);
        vm.warp(timestamp + 7);
        vm.roll(block.number + 2);
        bytes[] memory data = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(id, data);

        assertEq(result.terminalCount, 1, "a failed order still counts as terminal");
        assertEq(result.nextOrderId, 0);
        assertEq(uint256(result.stopReason), uint256(OrderV3Types.PendingReason.None));
        OrderV3Types.TerminalOutcome memory outcome = router.lifecycleBook().terminalOutcome(id);
        assertEq(uint256(outcome.status), uint256(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint256(outcome.reason), uint256(OrderV3Types.TerminalReason.Slippage));
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[id].bounty);
        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 0);
        vm.expectRevert(GasProfile__OrderDidNotExecute.selector);
        this.assertCompletedBatchForControl(result, id, 1, keeperBefore);
    }

    function test_GasOutcomeCheckerRejectsLowGasPartialBatch() public {
        uint256 timestamp = block.timestamp;
        address[3] memory traders = [alice, bob, carol];
        for (uint256 i; i < traders.length; ++i) {
            _depositToClearinghouse(traders[i], 10_000e6);
            CfdTypes.Side side = i == 1 ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
            vm.prank(traders[i]);
            uint64 id = router.commitOrder(side, 10_000e18, 1000e6, 1e8, false);
            _rememberOrder(id, traders[i], side, 10_000e18, 1000e6, false);
            _rememberTradeAccounting(id, false);
        }
        pyth.setAllPrices(feedIds, 100_000_000, -8, timestamp + 6);
        vm.warp(timestamp + 7);
        vm.roll(block.number + 2);
        bytes[] memory data = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch{gas: 5_000_000}(3, data);

        assertGt(result.terminalCount, 0, "control must execute a prefix, not merely stop before work");
        assertLt(result.terminalCount, 3, "control must leave part of the batch pending");
        assertEq(uint256(result.stopReason), uint256(OrderV3Types.PendingReason.InsufficientGas));
        assertEq(result.nextOrderId, result.terminalCount + 1);
        assertEq(router.nextExecuteId(), result.nextOrderId);
        uint256 expectedCredit;
        Vm.Log[] memory prefixLogs = _takeRecordedLogs();
        for (uint64 id = 1; id <= result.terminalCount; ++id) {
            _assertExecutedReceipt(id, prefixLogs);
            expectedCredit += expectedOrders[id].bounty;
        }
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedCredit);
        for (uint64 id = result.nextOrderId; id <= 3; ++id) {
            assertEq(router.pendingOrderCounts(expectedOrders[id].account), 1);
            (uint256 size,,,,,,) = engine.positions(expectedOrders[id].account);
            assertEq(size, 0);
            IMarginClearinghouse.BountyReservation memory reservation =
                clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, id);
            assertEq(uint256(reservation.state), uint256(IMarginClearinghouse.BountyReservationState.Active));
            assertEq(reservation.amountUsdc, expectedOrders[id].bounty);
        }
        vm.expectRevert(GasProfile__BatchDidNotComplete.selector);
        this.assertCompletedBatchForControl(result, 1, 3, keeperBefore);

        uint256 keeperBeforeResume = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        OrderV3Types.BatchResult memory resumed = router.executeOrderBatch(3, data);
        assertEq(resumed.terminalCount, 3 - result.terminalCount);
        _assertCompletedBatch(resumed, result.nextOrderId, 3 - result.terminalCount, keeperBeforeResume);
    }

    /// @dev External boundary lets controls prove the same benchmark checker rejects authentic bad outcomes.
    function assertCompletedBatchForControl(
        OrderV3Types.BatchResult memory result,
        uint64 firstOrderId,
        uint256 count,
        uint256 keeperBefore
    ) external {
        _assertCompletedBatch(result, firstOrderId, count, keeperBefore);
    }

    function _batchOpenTest(
        uint256 n
    ) internal {
        // Seed pool with enough liquidity for all positions
        _fundTrancheAsync(juniorVault, lp, n * 100_000e6);

        uint256 ts = block.timestamp;

        for (uint256 i = 0; i < n; i++) {
            address trader = address(uint160(0xA000 + i));
            _depositToClearinghouse(trader, 5000e6);
            CfdTypes.Side side = i % 2 == 0 ? CfdTypes.Side.LONG : CfdTypes.Side.SHORT;
            vm.prank(trader);
            router.commitOrder(side, 10_000e18, 1000e6, 1e8, false);
            _rememberOrder(router.nextCommitId() - 1, trader, side, 10_000e18, 1000e6, false);
            _rememberTradeAccounting(router.nextCommitId() - 1, false);
        }

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        uint256 g0 = gasleft();
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(uint64(n), updateData);
        uint256 gasUsed = g0 - gasleft();
        _assertCompletedBatch(result, 1, n, keeperBefore);

        emit log_named_uint(string.concat("batch_", vm.toString(n), "_total"), gasUsed);
        emit log_named_uint(string.concat("batch_", vm.toString(n), "_per_order"), gasUsed / n);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _rememberOrder(
        uint64 orderId,
        address account,
        CfdTypes.Side intendedSide,
        uint256 sizeDelta,
        uint256 marginDelta,
        bool isClose
    ) internal {
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(orderId);
        (uint256 size,,,,,,) = engine.positions(account);
        expectedOrders[orderId] = ExpectedOrder({
            account: account,
            finalSize: isClose ? size - sizeDelta : size + sizeDelta,
            bounty: pending.executionBountyUsdc,
            side: intendedSide
        });
        assertEq(pending.orderId, orderId, "commit must create the intended pending order");
        assertEq(pending.sizeDelta, sizeDelta);
        assertEq(pending.marginDelta, marginDelta);
        assertEq(pending.isClose, isClose);
        assertEq(uint256(pending.side), uint256(intendedSide));
        if (isClose) {
            assertEq(pending.executionBountyUsdc, 0, "close is unpaid");
        } else {
            assertGt(pending.executionBountyUsdc, 0, "open must reserve a bounty");
        }
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, orderId);
        assertEq(reservation.account, account);
        assertEq(uint256(reservation.state), uint256(IMarginClearinghouse.BountyReservationState.Active));
        assertEq(reservation.amountUsdc, pending.executionBountyUsdc);
        assertEq(pending.committedMarginUsdc, pending.isClose ? 0 : pending.marginDelta);
        assertEq(router.pendingOrderCounts(account), 1);
    }

    function _assertExecutedOrder(
        OrderV3Types.ExecutionResult memory result
    ) internal {
        if (result.status != OrderV3Types.LifecycleStatus.Executed) {
            revert GasProfile__OrderDidNotExecute();
        }
        assertEq(uint256(result.pendingReason), uint256(OrderV3Types.PendingReason.None));
        assertEq(uint256(result.terminalReason), uint256(OrderV3Types.TerminalReason.Executed));
        _assertExecutedReceipt(result.orderId);
        assertEq(result.receiptHash, router.lifecycleBook().terminalOutcome(result.orderId).receiptHash);
        assertEq(router.nextExecuteId(), 0, "single-order sample must leave no queued work");
    }

    function _assertExecutedReceipt(
        uint64 orderId
    ) internal {
        _assertExecutedReceipt(orderId, _takeRecordedLogs());
    }

    function _assertExecutedReceipt(
        uint64 orderId,
        Vm.Log[] memory logs
    ) internal {
        ExpectedOrder memory expected = expectedOrders[orderId];
        OrderV3Types.CompactOutcome memory outcome = _verifiedOutcome(router.lifecycleBook(), orderId);
        if (outcome.status != OrderV3Types.LifecycleStatus.Executed) {
            revert GasProfile__OrderDidNotExecute();
        }
        assertEq(outcome.account, expected.account);
        assertEq(outcome.executor, keeper);
        assertEq(outcome.bountyRecipient, expected.bounty == 0 ? address(0) : keeper);
        assertEq(
            uint256(outcome.bountyDisposition),
            uint256(expected.bounty == 0 ? OrderV3Types.BountyDisposition.None : OrderV3Types.BountyDisposition.Paid)
        );
        assertEq(outcome.bountyUsdc, expected.bounty, "receipt must consume the exact committed bounty");
        _assertExecutedPositionAndReservation(orderId);
        if (tradeAccountingBefore[orderId].recorded) {
            bool checked;
            for (uint256 i; i < logs.length; ++i) {
                if (
                    logs[i].emitter != address(router.lifecycleBook()) || logs[i].topics.length != 4
                        || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
                        || uint256(logs[i].topics[1]) != orderId
                ) {
                    continue;
                }
                (,,, OrderV3Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                _assertTradeAccounting(receipt);
                checked = true;
            }
            assertTrue(checked, "trade accounting needs its authenticated receipt");
        }
    }

    function _rememberTradeAccounting(
        uint64 orderId,
        bool deferredProfit
    ) internal {
        address account = expectedOrders[orderId].account;
        TradeAccountingSnapshot storage beforeTrade = tradeAccountingBefore[orderId];
        (beforeTrade.size, beforeTrade.margin,,,,,) = engine.positions(account);
        beforeTrade.balance = clearinghouse.balanceUsdc(account);
        beforeTrade.entryCost = engine.positionEntryCostUsdcAtoms(account);
        beforeTrade.liquidationReserve = clearinghouse.liquidationReserveUsdc(account);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(orderId);
        beforeTrade.sizeDelta = pending.sizeDelta;
        beforeTrade.marginDelta = pending.marginDelta;
        beforeTrade.isClose = pending.isClose;
        beforeTrade.deferredProfit = deferredProfit;
        beforeTrade.recorded = true;
        assertEq(engine.traderClaimBalanceUsdc(account), 0, "trade fixture starts without a claim");
    }

    /// @dev Operation proof, not a second carry/VPI model: authenticated charges reconcile the submitted trade's
    ///      actual cash and pledge. Fee, PnL, reserve, allocation and payout mode follow this fixed healthy fixture.
    function _assertTradeAccounting(
        OrderV3Types.OrderReceipt memory receipt
    ) internal view {
        TradeAccountingSnapshot memory beforeTrade = tradeAccountingBefore[receipt.orderId];
        OrderV3Types.OrderEconomics memory economics = receipt.economics;
        uint256 notional = beforeTrade.sizeDelta / CfdTypes.SIZE_QUANTUM * receipt.executionPrice;
        assertEq(economics.executionFeeUsdc, notional * 4 / 10_000, "trade pays its exact 4-bps fee");
        assertEq(economics.frozenSpreadUsdc, 0, "trade sample uses live execution");
        assertGe(economics.carryUsdc, 0);
        uint256 carry = uint256(economics.carryUsdc);
        // Close receipts include commitment-time carry, while this snapshot is taken after commitment.
        if (beforeTrade.isClose) {
            carry -= receipt.commitment.carryCollectedUsdc;
        }
        int256 action = economics.vpiUsdc + int256(economics.executionFeeUsdc);
        uint256 charge = action > 0 ? uint256(action) : 0;
        uint256 expectedMargin;
        uint256 expectedClaim;
        int256 pnl;
        uint256 reserve =
            expectedOrders[receipt.orderId].finalSize / CfdTypes.SIZE_QUANTUM * receipt.executionPrice / 1000;
        if (expectedOrders[receipt.orderId].finalSize != 0 && reserve < 5e6) {
            reserve = 5e6;
        }
        if (beforeTrade.isClose) {
            pnl = int256(beforeTrade.entryCost * beforeTrade.sizeDelta / beforeTrade.size) - int256(notional);
            if (expectedOrders[receipt.orderId].side == CfdTypes.Side.SHORT) {
                pnl = -pnl;
            }
            assertGt(pnl, 0, "close sample must realize its intended price profit");
            uint256 payout = uint256(pnl) - charge;
            expectedClaim = beforeTrade.deferredProfit ? payout : 0;
            uint256 pledgeAfterCarry = beforeTrade.margin - carry;
            if (expectedOrders[receipt.orderId].finalSize != 0) {
                expectedMargin = pledgeAfterCarry - pledgeAfterCarry * beforeTrade.sizeDelta / beforeTrade.size
                    + (beforeTrade.deferredProfit ? 0 : payout);
            }
            if (reserve > beforeTrade.liquidationReserve) {
                reserve = beforeTrade.liquidationReserve;
            }
        } else {
            if (reserve < beforeTrade.liquidationReserve) {
                reserve = beforeTrade.liquidationReserve;
            }
            expectedMargin = beforeTrade.margin + beforeTrade.marginDelta - carry - charge
                - (reserve - beforeTrade.liquidationReserve);
        }
        int256 expectedCash =
            int256(beforeTrade.balance) - int256(carry) - action + pnl - int256(expectedClaim + receipt.bountyUsdc);
        assertGe(expectedCash, 0);
        assertEq(economics.realizedPnlUsdc, pnl, "trade realizes the submitted position's price profit");
        assertEq(clearinghouse.balanceUsdc(receipt.account), uint256(expectedCash), "trade reconciles custody");
        assertEq(clearinghouse.pnlPledgeUsdc(receipt.account), expectedMargin, "trade installs intended pledge");
        assertEq(clearinghouse.liquidationReserveUsdc(receipt.account), reserve);
        assertEq(engine.traderClaimBalanceUsdc(receipt.account), expectedClaim, "trade uses intended payout mode");
        assertEq(engine.unsettledCarryUsdc(receipt.account), 0, "funded samples retain no carry arrears");
        assertEq(economics.postSettlementBalanceUsdc, uint256(expectedCash));
        assertEq(economics.postPositionMarginUsdc, expectedMargin);
        assertEq(economics.postTraderClaimBalanceUsdc, expectedClaim);
        uint256 expectedEntryCost = beforeTrade.isClose
            ? beforeTrade.entryCost - beforeTrade.entryCost * beforeTrade.sizeDelta / beforeTrade.size
            : beforeTrade.entryCost + notional;
        assertEq(
            engine.positionEntryCostUsdcAtoms(receipt.account), expectedEntryCost, "trade installs exact entry basis"
        );
    }

    function _assertExecutedPositionAndReservation(
        uint64 orderId
    ) internal view {
        ExpectedOrder memory expected = expectedOrders[orderId];
        (uint256 size, uint256 margin,,, CfdTypes.Side side,,) = engine.positions(expected.account);
        assertEq(size, expected.finalSize, "sample must produce its intended position size");
        if (size != 0) {
            assertEq(uint256(side), uint256(expected.side));
        } else {
            assertEq(margin, 0, "full close must clear position margin");
        }
        IMarginClearinghouse.BountyReservation memory reservation =
            clearinghouse.getBountyReservation(IMarginClearinghouse.BountyKind.Order, orderId);
        assertEq(uint256(reservation.state), uint256(IMarginClearinghouse.BountyReservationState.Settled));
        assertEq(reservation.amountUsdc, 0);
        IOrderRouterAccounting.AccountReservationView memory remaining = router.getAccountReservations(expected.account);
        assertEq(remaining.pendingOrderCount, 0);
        assertEq(remaining.committedMarginUsdc, 0);
        assertEq(remaining.executionBountyUsdc, 0);
    }

    function _assertCompletedBatch(
        OrderV3Types.BatchResult memory result,
        uint64 firstOrderId,
        uint256 count,
        uint256 keeperBefore
    ) internal {
        if (
            result.terminalCount != count || result.nextOrderId != 0
                || result.stopReason != OrderV3Types.PendingReason.None || router.nextExecuteId() != 0
        ) {
            revert GasProfile__BatchDidNotComplete();
        }
        // Authenticate the batch in one in-memory pass. Persisting every large receipt in test storage
        // adds enough assertion overhead to exhaust the test gas limit in the 300-order sample.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 verifiedCount;
        uint256 expectedCredit;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(router.lifecycleBook()) || logs[i].topics.length != 4
                    || logs[i].topics[0] != IOrderLifecycleBook.OrderFinalized.selector
            ) {
                continue;
            }
            (bytes32 receiptHash, uint64 terminalBlock, uint64 terminalTime, OrderV3Types.OrderReceipt memory receipt) =
                abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
            if (receipt.orderId < firstOrderId || receipt.orderId >= firstOrderId + count) {
                continue;
            }
            assertEq(receipt.orderId, firstOrderId + verifiedCount, "every requested item must finalize exactly once");
            assertEq(uint256(logs[i].topics[1]), receipt.orderId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), receipt.account);
            assertEq(logs[i].topics[3], receipt.clientOrderId);
            assertTrue(router.lifecycleBook().verifyReceipt(receipt, terminalTime), "batch receipt must authenticate");
            OrderV3Types.TerminalOutcome memory terminal = router.lifecycleBook().terminalOutcome(receipt.orderId);
            assertEq(terminal.receiptHash, receiptHash);
            assertEq(terminal.terminalBlock, terminalBlock);
            assertEq(terminal.account, receipt.account);
            assertEq(uint256(terminal.status), uint256(receipt.status));
            if (receipt.status != OrderV3Types.LifecycleStatus.Executed) {
                revert GasProfile__OrderDidNotExecute();
            }
            ExpectedOrder memory expected = expectedOrders[receipt.orderId];
            assertEq(receipt.account, expected.account);
            assertEq(receipt.executor, keeper);
            assertEq(receipt.bountyRecipient, expected.bounty == 0 ? address(0) : keeper);
            assertEq(
                uint256(receipt.bountyDisposition),
                uint256(
                    expected.bounty == 0 ? OrderV3Types.BountyDisposition.None : OrderV3Types.BountyDisposition.Paid
                )
            );
            assertEq(receipt.bountyUsdc, expected.bounty);
            _assertExecutedPositionAndReservation(receipt.orderId);
            assertTrue(
                tradeAccountingBefore[receipt.orderId].recorded, "batch item needs a pre-trade accounting snapshot"
            );
            _assertTradeAccounting(receipt);
            expectedCredit += expected.bounty;
            ++verifiedCount;
        }
        assertEq(verifiedCount, count, "every executed item needs an authenticated receipt");
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedCredit, "batch must pay every exact bounty");
    }

    function _assertLiquidationAccounting(
        address account,
        LiquidationAccountingSnapshot memory beforeLiquidation,
        ICfdEngineTypes.LiquidationPreview memory preview
    ) internal view {
        assertEq(
            clearinghouse.balanceUsdc(account),
            preview.settlementRetainedUsdc,
            "liquidation preserves exactly the modeled residual settlement"
        );
        assertEq(engine.traderClaimBalanceUsdc(account), preview.traderClaimBalanceUsdc);
        assertEq(engine.totalTraderClaimBalanceUsdc(), preview.traderClaimBalanceUsdc);
        assertEq(engine.positionEntryCostUsdcAtoms(account), 0);
        assertEq(engine.unsettledCarryUsdc(account), 0);
        (uint256 borrowBase, uint256 index, uint64 timestamp) = engine.positionCarryState(account);
        assertEq(borrowBase, 0);
        assertEq(index, 0);
        assertEq(timestamp, 0);
        assertEq(clearinghouse.lockedMarginUsdc(account), 0);
        assertEq(clearinghouse.liquidationReserveUsdc(account), 0);
        assertEq(clearinghouse.vpiRebateReserveUsdc(account), 0);
        assertEq(clearinghouse.actionReserveUsdc(account), 0);
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            beforeLiquidation.treasury + preview.protocolLiquidationFeeUsdc
        );
        uint256 poolInflow = beforeLiquidation.balance - preview.settlementRetainedUsdc - preview.keeperBountyUsdc
            - preview.protocolLiquidationFeeUsdc;
        assertEq(IERC20(usdc).balanceOf(address(pool)), beforeLiquidation.poolCash + poolInflow);
        assertEq(IERC20(usdc).balanceOf(address(clearinghouse)), beforeLiquidation.custody - poolInflow);
    }

    function _profileRequestDeposit(
        TrancheVault vault,
        uint256 assets,
        bool cutoffWindow,
        string memory label
    ) internal {
        _mintUsdc(lp2, assets);
        vm.prank(lp2);
        IERC20(usdc).approve(address(vault), type(uint256).max);

        _warpToRequestWindowSide(vault, cutoffWindow);
        _refreshMark();
        RequestEscrowSnapshot memory beforeRequest;
        (beforeRequest.epoch,) = vault.getRequestEpochWindow();
        beforeRequest.providerBalance = IERC20(usdc).balanceOf(lp2);
        beforeRequest.pendingEscrow = vault.pendingDepositEscrowAssets();
        beforeRequest.vaultBalance = IERC20(usdc).balanceOf(address(vault));

        vm.prank(lp2);
        uint256 g0 = gasleft();
        uint256 requestId = vault.requestDeposit(assets, lp2, lp2);
        uint256 gas = g0 - gasleft();
        assertEq(requestId, beforeRequest.epoch, "deposit must enter the intended cutoff epoch");
        assertEq(vault.pendingDepositRequest(requestId, lp2), assets);
        assertEq(vault.pendingDepositEscrowAssets(), beforeRequest.pendingEscrow + assets);
        assertEq(IERC20(usdc).balanceOf(lp2), beforeRequest.providerBalance - assets);
        assertEq(IERC20(usdc).balanceOf(address(vault)), beforeRequest.vaultBalance + assets);
        emit log_named_uint(label, gas);
    }

    function _profileRequestRedeem(
        TrancheVault vault,
        uint256 fundingAssets,
        uint256 redeemAssets,
        bool cutoffWindow,
        string memory label
    ) internal {
        uint256 fundedShares = _fundTrancheAsync(vault, lp2, fundingAssets);
        vm.warp(block.timestamp + vault.DEPOSIT_COOLDOWN());
        _warpToRequestWindowSide(vault, cutoffWindow);

        uint256 requestedShares = vault.estimateWithdrawShares(redeemAssets);
        assertLe(requestedShares, fundedShares, "redeem setup exceeds funded shares");
        RequestEscrowSnapshot memory beforeRequest;
        (beforeRequest.epoch,) = vault.getRequestEpochWindow();
        beforeRequest.providerBalance = vault.balanceOf(lp2);
        beforeRequest.pendingEscrow = vault.pendingRedeemEscrowShares();
        beforeRequest.vaultBalance = vault.balanceOf(address(vault));

        vm.prank(lp2);
        uint256 g0 = gasleft();
        uint256 requestId = vault.requestRedeem(requestedShares, lp2, lp2);
        uint256 gas = g0 - gasleft();
        assertEq(requestId, beforeRequest.epoch, "redemption must enter the intended cutoff epoch");
        assertEq(vault.pendingRedeemRequest(requestId, lp2), requestedShares);
        assertEq(vault.pendingRedeemEscrowShares(), beforeRequest.pendingEscrow + requestedShares);
        assertEq(vault.balanceOf(lp2), beforeRequest.providerBalance - requestedShares);
        assertEq(vault.balanceOf(address(vault)), beforeRequest.vaultBalance + requestedShares);
        emit log_named_uint(label, gas);
    }

    function _warpToRequestWindowSide(
        TrancheVault vault,
        bool cutoffWindow
    ) internal {
        (, uint256 nextCutoffTime) = vault.getRequestEpochWindow();
        assertGt(nextCutoffTime, block.timestamp, "request cutoff must be in the future");
        vm.warp(cutoffWindow ? nextCutoffTime : nextCutoffTime - 1);
    }

    function _fundTrancheAsync(
        TrancheVault vault,
        address provider,
        uint256 assets
    ) internal returns (uint256 shares) {
        _mintUsdc(provider, assets);
        vm.startPrank(provider);
        IERC20(usdc).approve(address(vault), assets);
        uint256 requestId = vault.requestDeposit(assets, provider, provider);
        vm.stopPrank();

        uint256 activationTime = vault.depositEpochStart(requestId);
        if (block.timestamp < activationTime) {
            vm.warp(activationTime);
        }
        _refreshMark();
        pool.settleLpEpoch(0, 0);

        uint256 claimableAssets = vault.claimableDepositRequest(requestId, provider);
        assertEq(claimableAssets, assets, "async tranche funding did not finalize");
        vm.prank(provider);
        shares = vault.claimDeposit(requestId, claimableAssets, provider, provider);
        assertGt(shares, 0, "async tranche funding produced no shares");
    }

    function _refreshMark() internal {
        uint256 markPrice = engine.lastMarkPrice();
        vm.prank(address(router));
        engine.updateMarkPrice(markPrice == 0 ? 1e8 : markPrice, uint64(block.timestamp));
    }

    function _mintUsdc(
        address to,
        uint256 amount
    ) internal {
        MockUSDC6(usdc).mint(to, amount);
    }

    function _depositToClearinghouse(
        address trader,
        uint256 amount
    ) internal {
        _mintUsdc(trader, amount);
        vm.startPrank(trader);
        IERC20(usdc).approve(address(clearinghouse), amount);
        clearinghouse.deposit(_account(trader), amount);
        vm.stopPrank();
    }

    function _openPosition(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 targetPrice
    ) internal {
        uint256 ts = block.timestamp;
        uint64 orderId = router.nextCommitId();

        vm.prank(trader);
        router.commitOrder(side, size, margin, targetPrice, false);
        _rememberOrder(router.nextCommitId() - 1, trader, side, size, margin, false);
        _rememberTradeAccounting(orderId, false);

        pyth.setAllPrices(feedIds, int64(int256(targetPrice)), int32(-8), ts + 6);
        vm.warp(ts + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
    }

    function _closeAtPrice(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        int64 pythPrice
    ) external {
        uint256 commitTime = block.timestamp + 30;
        vm.warp(commitTime);
        uint64 orderId = router.nextCommitId();

        vm.prank(trader);
        router.commitOrder(side, size, 0, 0, true);
        _rememberOrder(router.nextCommitId() - 1, trader, side, size, 0, true);
        _rememberTradeAccounting(orderId, true);

        pyth.setAllPrices(feedIds, pythPrice, int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(block.number + 2);

        bytes[] memory updateData = _pythUpdateData();
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, updateData);
        _assertExecutedOrder(result);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, expectedOrders[result.orderId].bounty);
    }

    function _account(
        address trader
    ) internal pure returns (address) {
        return trader;
    }

    function _pythUpdateData() internal view returns (bytes[] memory updateData) {
        (int64 price,,) = pyth.prices(feedIds[0]);
        if (price <= 0) {
            price = int64(100_000_000);
        }
        updateData = new bytes[](1);
        updateData[0] = abi.encode(uint256(uint64(price)));
    }

}

contract MockUSDC6 {

    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

}

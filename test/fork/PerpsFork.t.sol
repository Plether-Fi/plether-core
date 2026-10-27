// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ForkTrancheFunding} from "./helpers/ForkTrancheFunding.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdEngineAdmin} from "@plether/perps/CfdEngineAdmin.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdEnginePlanner} from "@plether/perps/CfdEnginePlanner.sol";
import {CfdEngineSettlementSidecar} from "@plether/perps/CfdEngineSettlementSidecar.sol";
import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Perps Fork Tests
/// @notice Exercises current perps with real USDC, MockPyth scenarios, and a real-Pyth ABI smoke check.
contract PerpsForkTest is ForkTrancheFunding {

    using SafeERC20 for IERC20;

    address constant settlementToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
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
    MockPyth pyth;

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
            minBountyAssets: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });

        clearinghouse = new MarginClearinghouse(settlementToken);

        engine = new CfdEngine(settlementToken, address(clearinghouse), CAP_PRICE, params, 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(settlementToken, address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault =
            new TrancheVault(IERC20(settlementToken), address(pool), true, "Senior LP", "senAssets", 0, address(0));
        juniorVault =
            new TrancheVault(IERC20(settlementToken), address(pool), false, "Junior LP", "junAssets", 0, address(0));
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        pyth = new MockPyth();
        feedIds.push(EUR_USD_FEED_ID);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e18;
        uint256[] memory b = new uint256[](1);
        b[0] = 1e8;
        CfdEngineLens lens = new CfdEngineLens(address(engine));
        PletherOracle oracle =
            new PletherOracle(address(engine), address(pool), address(pyth), feedIds, w, b, new bool[](1));
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), routerDependencyNonce + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new OrderRouter(
            address(engine),
            address(lens),
            address(pool),
            address(oracle),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(router), predictedRouter, "router prediction");
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));

        uint256 t0 = vm.getBlockTimestamp();
        clearinghouse.setEngine(address(engine));
        pool.proposePoolConfig(
            IHousePool.PoolConfig({
                seniorRateBps: pool.seniorRateBps(),
                markStalenessLimit: pool.markStalenessLimit(),
                seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
                juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
                maxSeniorExposureAssets: type(uint256).max - 1,
                maxSeniorShareBps: 9999
            })
        );
        vm.warp(t0 + 144 hours + 3);
        pool.finalizePoolConfig();

        deal(settlementToken, address(this), 2000e6);
        IERC20(settlementToken).approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();

        // LP deposits $1M to junior tranche
        _fundForkTranche(juniorVault, engine, lp, 1_000_000e6);
    }

    // ==========================================
    // HELPERS
    // ==========================================

    function _depositToClearinghouse(
        address trader,
        uint256 amount
    ) internal {
        deal(settlementToken, trader, IERC20(settlementToken).balanceOf(trader) + amount);
        vm.startPrank(trader);
        IERC20(settlementToken).approve(address(clearinghouse), amount);
        clearinghouse.deposit(trader, amount);
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
        uint256 commitTime = vm.getBlockTimestamp();
        uint64 orderId = router.nextCommitId();

        OrderV3Types.OrderRequest memory request1 = _orderRequest(trader, side, size, margin, targetPrice, isClose);
        vm.prank(trader);
        router.commitOrder(request1);

        pyth.setAllPrices(feedIds, pythPrice, int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(vm.getBlockNumber() + 2);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, empty);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed), "fixture order must execute");
    }

    function _account(
        address trader
    ) internal pure returns (address) {
        return trader;
    }

    function _sideOpenInterest(
        CfdTypes.Side side
    ) internal view returns (uint256) {
        (, uint256 openInterest,,) = engine.sides(uint8(side));
        return openInterest;
    }

    function _configureLongOrderExpiry() internal {
        IOrderRouterAdminHost.RouterConfig memory config;
        config.maxExecutionWindowSeconds = 1000;
        config.orderExecutionStalenessLimit = router.pletherOracle().orderExecutionStalenessLimit();
        config.liquidationStalenessLimit = router.pletherOracle().liquidationStalenessLimit();
        config.basketMaxConfidenceRatioBps = router.pletherOracle().basketMaxConfidenceRatioBps();
        config.orderSettlementWindow = router.pletherOracle().orderSettlementWindow();
        config.maxComponentPublishTimeDivergence = router.pletherOracle().maxComponentPublishTimeDivergence();
        config.adverseConfidenceMultiplierBps = router.pletherOracle().adverseConfidenceMultiplierBps();
        config.minOpenNotionalAssets = router.minOpenNotionalAssets();
        config.openOrderExecutionBountyBps = router.openOrderExecutionBountyBps();
        config.minOpenOrderExecutionBountyAssets = router.minOpenOrderExecutionBountyAssets();
        config.maxOpenOrderExecutionBountyAssets = router.maxOpenOrderExecutionBountyAssets();
        config.positionProtectionTriggerBountyAssets = router.positionProtectionTriggerBountyAssets();
        config.maxPendingOrders = router.maxPendingOrders();
        config.minEngineGas = router.minEngineGas();
        config.maxPruneOrdersPerCall = router.maxPruneOrdersPerCall();
        routerAdmin.proposeRouterConfig(config);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
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
        commitTime = vm.getBlockTimestamp();
        commitBlock = vm.getBlockNumber();

        OrderV3Types.OrderRequest memory request2 = _orderRequest(trader, side, size, margin, targetPrice, isClose);
        vm.prank(trader);
        router.commitOrder(request2);
    }

    function _orderRequest(
        address trader,
        CfdTypes.Side side,
        uint256 size,
        uint256 margin,
        uint256 targetPrice,
        bool isClose
    ) internal view returns (OrderV3Types.OrderRequest memory request) {
        if (targetPrice == 0) {
            targetPrice = isClose
                ? (side == CfdTypes.Side.LONG ? type(uint256).max : 1)
                : (side == CfdTypes.Side.LONG ? 1 : type(uint256).max);
        }
        request = OrderV3Types.OrderRequest({
            clientOrderId: keccak256(
                abi.encode("PerpsForkTest", block.chainid, address(router), trader, router.nextCommitId())
            ),
            side: side,
            sizeDelta: size,
            marginDelta: margin,
            targetPrice: targetPrice,
            isClose: isClose,
            bounds: OrderV3Types.ExecutionBounds({
                submitBy: uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds()),
                executionWindowSeconds: uint32(
                    uint256(uint64(vm.getBlockTimestamp() + router.maxExecutionWindowSeconds()))
                        - vm.getBlockTimestamp()
                ),
                allowedExecutionModes: 7,
                expectedConfigHash: router.lifecycleBook().currentExecutionConfigHash(),
                maxExecutionBountyAssets: type(uint256).max,
                maxExecutionNotionalAssets: type(uint256).max,
                maxGrossAccountDebitAssets: type(uint256).max,
                maxActionChargeAssets: type(uint256).max,
                maxExplicitFeesAssets: type(uint256).max,
                maxPostPositionSize: type(uint256).max,
                minPostSettlementBalanceAssets: 0,
                minPostPositionEquityAssets: 0,
                maxPostLeverageBps: type(uint32).max
            })
        });
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
            uint256 minBountyAssets,
            uint256 bountyBps,
            uint256 keeperShareBps,
            uint256 protocolShareBps
        ) = engine.riskParams();
        return CfdTypes.RiskParams({
            vpiFactor: vpiFactor,
            maxSkewRatio: maxSkewRatio,
            maintMarginBps: maintMarginBps,
            initMarginBps: initMarginBps,
            fadMarginBps: fadMarginBps,
            baseCarryBps: baseCarryBps,
            minBountyAssets: minBountyAssets,
            bountyBps: bountyBps,
            keeperShareBps: keeperShareBps,
            protocolShareBps: protocolShareBps
        });
    }

    // ==========================================
    // TEST 1: Full Lifecycle with Real USDC
    // ==========================================

    function test_FullLifecycle_RealAssets() public {
        _depositToClearinghouse(alice, 10_000e6);

        uint256 aliceAssetsBefore = IERC20(settlementToken).balanceOf(alice);
        uint256 poolBefore = IERC20(settlementToken).balanceOf(address(pool));
        uint256 clearinghouseBefore = IERC20(settlementToken).balanceOf(address(clearinghouse));
        uint256 keeperBefore = clearinghouse.balanceAssets(keeper);

        // Open LONG $50k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 50_000e18, "Position should be 50k tokens");

        // Close at $0.90 (LONG profits when price drops).
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.recordLogs();
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 50_000e18, 0, 0, int64(90_000_000), true);
        OrderV3Types.OrderReceipt memory receipt = _receipt(vm.getRecordedLogs(), 2);
        assertEq(receipt.economics.realizedPnlAssets, 5000e6, "50k tokens gain ten cents each");
        assertEq(receipt.economics.executionFeeAssets, 18e6, "four basis points on the 45k close notional");
        assertEq(engine.traderClaimBalanceAssets(aliceAccount), 0, "solvent pool pays the profit immediately");
        uint256 settlement = clearinghouse.balanceAssets(aliceAccount);
        // $10,000 deposit + $5,000 profit - $20 open fee - $18 close fee - $0.20 bounty.
        // The $1 envelope allows the small time-dependent carry and VPI rounding, not a missing fee or payout.
        assertApproxEqAbs(settlement, 14_961_800_000, 1e6, "trader receives the independently priced profit");
        assertApproxEqAbs(
            poolBefore - IERC20(settlementToken).balanceOf(address(pool)), 5000e6, 1e6, "pool funds the profit"
        );
        assertEq(clearinghouse.balanceAssets(keeper) - keeperBefore, 200_000, "only the capped open bounty is paid");

        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Position should be closed");

        // Verify USDC conservation across all contracts
        uint256 totalAfter = IERC20(settlementToken).balanceOf(alice) + IERC20(settlementToken).balanceOf(address(pool))
            + IERC20(settlementToken).balanceOf(address(clearinghouse)) + IERC20(settlementToken).balanceOf(keeper);
        uint256 totalBefore = aliceAssetsBefore + poolBefore + clearinghouseBefore + keeperBefore;

        assertEq(totalAfter, totalBefore, "USDC conservation violated");
        vm.prank(alice);
        clearinghouse.withdraw(aliceAccount, settlement);
        assertEq(
            IERC20(settlementToken).balanceOf(alice) - aliceAssetsBefore, settlement, "profit is withdrawable real USDC"
        );
        assertEq(clearinghouse.balanceAssets(aliceAccount), 0);
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
        CfdEngineLens realPythLens = new CfdEngineLens(address(engine));
        PletherOracle realPythOracle =
            new PletherOracle(address(engine), address(pool), REAL_PYTH, feedIds, rw, rb, new bool[](1));
        CfdOrderPolicyEvaluator realPythEvaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar realPythExecutionSidecar = new OrderRouterExecutionSidecar();
        uint64 routerDependencyNonce = vm.getNonce(address(this));
        address predictedRouter = vm.computeCreateAddress(address(this), routerDependencyNonce + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        OrderRouter realPythRouter = new OrderRouter(
            address(engine),
            address(realPythLens),
            address(pool),
            address(realPythOracle),
            address(keeperSidecar),
            address(realPythEvaluator),
            address(realPythExecutionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(realPythRouter), predictedRouter, "router prediction");

        vm.expectRevert(ICfdEngineTypes.CfdEngine__RouterAlreadySet.selector);
        engine.setOrderRouter(address(realPythRouter));

        assertEq(
            address(realPythRouter.pletherOracle().pyth()),
            REAL_PYTH,
            "Router construction should still accept the real Pyth contract"
        );
    }

    // ==========================================
    // TEST 3: Staleness with Real Block Timestamps
    // ==========================================

    function test_Staleness_RealBlockTimestamps() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime);
        vm.warp(commitTime + 2);
        vm.roll(commitBlock + 2);

        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory pending = router.executeOrder(orderId, _pythUpdateData());
        assertEq(uint8(pending.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(pending.pendingReason), uint8(OrderV3Types.PendingReason.HistoricalPriceUnavailable));

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime + 1);
        vm.warp(commitTime + 1001);
        vm.roll(commitBlock + 3);
        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "MEV-tainted order should not open position");
        assertEq(
            router.nextExecuteId(),
            0,
            "Queue should advance after expiring the MEV-tainted order and clear to the zero sentinel"
        );
    }

    function test_HistoricalPrice_61SecondsOld_ExecutesWithinDeadline() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 67);
        vm.roll(commitBlock + 2);

        // Historical execution uses the post-commit signed window, not live mark age.
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(orderId, _pythUpdateData());
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        (uint256 size,,,,,,) = engine.positions(_account(alice));
        assertEq(size, 10_000e18);
        assertEq(router.nextExecuteId(), 0);
    }

    function test_Staleness_59SecondPrice_Executes() public {
        _configureLongOrderExpiry();
        _depositToClearinghouse(alice, 10_000e6);

        (uint64 orderId, uint256 commitTime, uint256 commitBlock) =
            _commitOrderDeterministic(alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);

        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 65);
        vm.roll(commitBlock + 2);

        vm.prank(keeper);
        router.executeOrder(orderId, _pythUpdateData());

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "59-second-old price should execute");
        assertEq(
            router.nextExecuteId(), 0, "Successful execution should advance the queue and clear to the zero sentinel"
        );
    }

    function test_LiquidationStaleness_16SecondsOld_Reverts() public {
        _depositToClearinghouse(alice, 10_000e6);
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        uint256 liqPublishTime = vm.getBlockTimestamp() + 1;
        pyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), liqPublishTime);
        vm.warp(liqPublishTime + 16);

        vm.prank(keeper);
        // The live parser rejects the stale batch before Oracle post-parse validation.
        vm.expectRevert(bytes("outside range"));
        router.executeLiquidation(aliceAccount, _pythUpdateData());
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 10_000e18, "stale liquidation must leave the position untouched");
    }

    // ==========================================
    // TEST 4: Liquidation E2E with Real USDC
    // ==========================================

    function test_LiquidationE2E_RealAssetsSettlement() public {
        _depositToClearinghouse(alice, 10_000e6);

        // Open LONG $100k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should exist");

        uint256 poolBefore = IERC20(settlementToken).balanceOf(address(pool));
        uint256 chBefore = IERC20(settlementToken).balanceOf(address(clearinghouse));
        uint256 keeperWalletBefore = IERC20(settlementToken).balanceOf(keeper);
        uint256 keeperBefore = clearinghouse.balanceAssets(keeper);

        // Price rises to $1.10 → LONG PnL = -$10k, equity turns liquidatable
        uint256 liqTs = vm.getBlockTimestamp() + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(110_000_000), -8, liqTs);

        bytes[] memory empty = _pythUpdateData();
        vm.prank(keeper);
        router.executeLiquidation(aliceAccount, empty);

        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Position should be liquidated");

        uint256 keeperGain = clearinghouse.balanceAssets(keeper) - keeperBefore;
        CfdTypes.RiskParams memory params = _getRiskParams();
        uint256 minimumKeeperShare = (params.minBountyAssets * params.keeperShareBps) / 10_000;
        assertGe(
            keeperGain, minimumKeeperShare, "Keeper should get at least the configured share of the minimum charge"
        );

        // USDC conservation: pool + clearinghouse + keeper == before totals
        uint256 totalAfter = IERC20(settlementToken).balanceOf(address(pool))
            + IERC20(settlementToken).balanceOf(address(clearinghouse)) + IERC20(settlementToken).balanceOf(keeper);
        uint256 totalBefore = poolBefore + chBefore + keeperWalletBefore;
        assertEq(totalAfter, totalBefore, "USDC conservation across liquidation");
    }

    // ==========================================
    // TEST 5: Keeper Gas Economics
    // ==========================================

    function test_KeeperBountyPaymentsAndMeasuredGas() public {
        _depositToClearinghouse(alice, 2000e6);

        uint256 ts = vm.getBlockTimestamp();
        OrderV3Types.OrderRequest memory request3 =
            _orderRequest(alice, CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(request3);

        pyth.setAllPrices(feedIds, int64(100_000_000), -8, ts + 6);
        vm.warp(ts + 7);
        vm.roll(vm.getBlockNumber() + 1);

        bytes[] memory empty = _pythUpdateData();

        uint256 expectedBounty = router.lifecycleBook().pendingIntent(1).executionBountyAssets;
        uint256 keeperBefore = clearinghouse.balanceAssets(keeper);
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        router.executeOrder(1, empty);
        uint256 executeGas = gasBefore - gasleft();

        emit log_named_uint("executeOrder gas", executeGas);
        assertEq(
            clearinghouse.balanceAssets(keeper) - keeperBefore, expectedBounty, "execution pays the reserved bounty"
        );

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position must exist for liquidation test");

        // Move price to make position liquidatable
        uint256 liqTs = vm.getBlockTimestamp() + 60;
        vm.warp(liqTs);
        pyth.setAllPrices(feedIds, int64(120_000_000), -8, liqTs);

        keeperBefore = clearinghouse.balanceAssets(keeper);
        gasBefore = gasleft();
        vm.prank(keeper);
        router.executeLiquidation(aliceAccount, empty);
        uint256 liquidateGas = gasBefore - gasleft();

        emit log_named_uint("executeLiquidation gas", liquidateGas);
        uint256 liquidationBounty = clearinghouse.balanceAssets(keeper) - keeperBefore;
        assertGt(liquidationBounty, 0, "liquidation must compensate the keeper");
        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "measured liquidation must close the position");

        // Gas is an observed cost, not a promise of profitability at arbitrary gas prices.
        // At the illustrative 2,000 USD/ETH price, preserve USDC's six decimal places.
        uint256 ethPriceAssets = 2000e6;
        emit log_named_uint("order break-even gas price (wei)", expectedBounty * 1e18 / (executeGas * ethPriceAssets));
        emit log_named_uint(
            "liquidation break-even gas price (wei)", liquidationBounty * 1e18 / (liquidateGas * ethPriceAssets)
        );
    }

    // ==========================================
    // TEST 6: Multi-Trader Concurrent Positions
    // ==========================================

    function test_MultiTrader_ConcurrentPositions() public {
        uint256 t0 = vm.getBlockTimestamp();
        _depositToClearinghouse(alice, 20_000e6);
        _depositToClearinghouse(bob, 20_000e6);
        _depositToClearinghouse(carol, 20_000e6);

        uint256 totalAssetsBefore = IERC20(settlementToken).balanceOf(address(pool))
            + IERC20(settlementToken).balanceOf(address(clearinghouse)) + IERC20(settlementToken).balanceOf(keeper);

        // Alice LONG $100k, Bob SHORT $80k, Carol LONG $50k — all at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, int64(100_000_000), false);
        this._commitAndExecute(bob, CfdTypes.Side.SHORT, 80_000e18, 8000e6, 1e8, int64(100_000_000), false);
        this._commitAndExecute(carol, CfdTypes.Side.LONG, 50_000e18, 5000e6, 1e8, int64(100_000_000), false);

        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 150_000e18, "Long OI should be 150k");
        assertEq(_sideOpenInterest(CfdTypes.Side.SHORT), 80_000e18, "Short OI should be 80k");

        // Close Alice at $0.95 (LONG profits when price drops)
        vm.warp(t0 + 200);
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 100_000e18, 0, 0, int64(95_000_000), true);
        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 50_000e18, "Long OI should be 50k after Alice close");

        // Close Bob at $0.95 (SHORT loses when price drops)
        vm.warp(t0 + 400);
        this._commitAndExecute(bob, CfdTypes.Side.SHORT, 80_000e18, 0, 0, int64(95_000_000), true);
        assertEq(_sideOpenInterest(CfdTypes.Side.SHORT), 0, "Short OI should be 0 after Bob close");

        // Close Carol at $1.05 (LONG loses when price rises)
        vm.warp(t0 + 600);
        this._commitAndExecute(carol, CfdTypes.Side.LONG, 50_000e18, 0, 0, int64(105_000_000), true);

        assertEq(_sideOpenInterest(CfdTypes.Side.LONG), 0, "Long OI should be 0 after all close");
        assertEq(_sideOpenInterest(CfdTypes.Side.SHORT), 0, "Short OI should be 0 after all close");

        // USDC conservation
        uint256 totalAssetsAfter = IERC20(settlementToken).balanceOf(address(pool))
            + IERC20(settlementToken).balanceOf(address(clearinghouse)) + IERC20(settlementToken).balanceOf(keeper);
        assertEq(totalAssetsAfter, totalAssetsBefore, "USDC conservation across multi-trader");
    }

    // ==========================================
    // TEST 7: Indexed Carry Accrues over 90 Days
    // ==========================================

    function test_CarryAccrual_90Days() public {
        uint256 t0 = vm.getBlockTimestamp();
        _depositToClearinghouse(alice, 50_000e6);

        // Lone LONG $200k -> max skew, carry will drain margin
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 200_000e18, 40_000e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertGt(size, 0, "Position should exist");

        uint256 longIndexBefore = engine.sideCarryIndex(uint8(CfdTypes.Side.LONG));
        uint256 snapshot = vm.snapshotState();
        this._commitAndExecute(alice, CfdTypes.Side.LONG, size, 0, 0, int64(100_000_000), true);
        uint256 immediateCloseBalance = clearinghouse.balanceAssets(aliceAccount);
        assertTrue(vm.revertToState(snapshot));

        // Same position and price, with only elapsed time changed: realized carry must
        // increase the long-side index and reduce settlement proceeds relative to the control.
        vm.warp(t0 + 90 days + 60);
        this._commitAndExecute(alice, CfdTypes.Side.LONG, size, 0, 0, int64(100_000_000), true);
        assertGt(engine.sideCarryIndex(uint8(CfdTypes.Side.LONG)), longIndexBefore);
        assertLt(clearinghouse.balanceAssets(aliceAccount), immediateCloseBalance);
        (size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "carry must be realized by a completed close");
    }

    // ==========================================
    // TEST 8: Pool Solvency — Large PnL Payout
    // ==========================================

    function test_PoolSolvency_LargePnlPayout() public {
        // Add senior LP: $500k
        _fundForkTranche(seniorVault, engine, lp, 500_000e6);

        uint256 poolTotalBefore = IERC20(settlementToken).balanceOf(address(pool));
        assertEq(poolTotalBefore, 1_502_000e6, "Pool includes $1.5M LP deposits and $2k seed liquidity");

        _depositToClearinghouse(alice, 50_000e6);

        // LONG $200k at $1.00
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 200_000e18, 20_000e6, 1e8, int64(100_000_000), false);

        uint256 seniorBefore = pool.seniorPrincipal();
        uint256 juniorBefore = pool.juniorPrincipal();

        // Price drops to $0.50 → LONG profits $100k
        vm.warp(vm.getBlockTimestamp() + 120);
        this._commitAndExecute(alice, CfdTypes.Side.LONG, 200_000e18, 0, 0, int64(50_000_000), true);

        // Reconcile to distribute loss through tranches
        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 seniorAfter = pool.seniorPrincipal();
        uint256 juniorAfter = pool.juniorPrincipal();

        // Junior absorbs loss first; senior should be protected
        assertLt(juniorAfter, juniorBefore, "Junior should absorb the loss");
        assertGe(seniorAfter, seniorBefore, "Senior should not lose principal");

        // Verify Alice got her profit in real USDC
        uint256 aliceBalance = clearinghouse.balanceAssets(_account(alice));
        assertGt(aliceBalance, 50_000e6, "Alice should have profit");

        // Verify real USDC withdrawal from clearinghouse
        uint256 aliceAssetsBefore = IERC20(settlementToken).balanceOf(alice);
        vm.prank(alice);
        clearinghouse.withdraw(_account(alice), aliceBalance);
        uint256 aliceAssetsAfter = IERC20(settlementToken).balanceOf(alice);
        assertEq(aliceAssetsAfter - aliceAssetsBefore, aliceBalance, "Real USDC withdrawal should match");
    }

    function test_TraderClaimSettlementFlow_RealAssets() public {
        _depositToClearinghouse(alice, 11_000e6);

        this._commitAndExecute(alice, CfdTypes.Side.LONG, 100_000e18, 9000e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        uint256 poolAssets = IERC20(settlementToken).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(settlementToken).safeTransfer(address(0xDEAD), poolAssets - 9000e6);

        uint256 chBefore = clearinghouse.balanceAssets(aliceAccount);

        uint256 commitTime = vm.getBlockTimestamp();
        OrderV3Types.OrderRequest memory request4 = _orderRequest(alice, CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        vm.prank(alice);
        router.commitOrder(request4);
        assertEq(router.lifecycleBook().pendingIntent(2).executionBountyAssets, 0, "V3 closes have no cash bounty");
        pyth.setAllPrices(feedIds, int64(80_000_000), int32(-8), commitTime + 6);
        vm.warp(commitTime + 7);
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(keeper);
        router.executeOrder(2, _pythUpdateData());

        uint256 traderClaim = engine.traderClaimBalanceAssets(aliceAccount);
        assertGt(traderClaim, 0, "Illiquid profitable close should record a trader claim");
        (uint256 size,,,,,,) = engine.positions(aliceAccount);
        assertEq(size, 0, "Position should be closed even when payout becomes a trader claim");
        uint256 chAfterClose = clearinghouse.balanceAssets(aliceAccount);
        assertLt(
            chAfterClose,
            chBefore,
            "Pre-claim clearinghouse balance should still reflect close bounty and carry realization"
        );
        assertEq(
            chBefore - chAfterClose, 1011, "Seven seconds of 5% annual carry on the 91k borrow basis; no close bounty"
        );

        deal(settlementToken, address(pool), IERC20(settlementToken).balanceOf(address(pool)) + traderClaim);
        // The fixture drained already-accounted cash. Restoring it creates no new
        // excess revenue, so it must not be booked a second time with accountExcess.
        assertEq(pool.excessAssets(), 0, "refill restores already-accounted cash");

        vm.prank(alice);
        engine.settleTraderClaim(aliceAccount);

        assertEq(engine.traderClaimBalanceAssets(aliceAccount), 0, "Claim should clear trader claim state");
        assertEq(
            clearinghouse.balanceAssets(aliceAccount),
            chAfterClose + traderClaim,
            "Claim settlement should credit owed USDC on top of the post-close settlement balance"
        );
    }

    function test_TraderClaimBatchDoesNotBlockTailOrder_RealAssets() public {
        _depositToClearinghouse(alice, 20_000e6);

        this._commitAndExecute(alice, CfdTypes.Side.LONG, 100_000e18, 8000e6, 1e8, int64(100_000_000), false);

        address aliceAccount = _account(alice);
        uint256 poolAssets = IERC20(settlementToken).balanceOf(address(pool));
        vm.prank(address(pool));
        IERC20(settlementToken).safeTransfer(address(0xDEAD), poolAssets - 8000e6);

        uint256 firstCommitTime = vm.getBlockTimestamp();
        OrderV3Types.OrderRequest memory request5 = _orderRequest(alice, CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        vm.prank(alice);
        router.commitOrder(request5);

        vm.warp(vm.getBlockTimestamp() + 10);
        vm.roll(vm.getBlockNumber() + 1);
        OrderV3Types.OrderRequest memory request6 =
            _orderRequest(alice, CfdTypes.Side.SHORT, 10_000e18, 500e6, 0, false);
        vm.prank(alice);
        router.commitOrder(request6);

        uint256 secondCommitTime = vm.getBlockTimestamp();
        uint256 tailBounty = router.lifecycleBook().pendingIntent(3).executionBountyAssets;
        uint256 keeperBefore = clearinghouse.balanceAssets(keeper);
        assertEq(clearinghouse.getOrderReservation(3).remainingAmountAssets, 500e6);
        MockPyth.FeedUpdate[] memory updates = new MockPyth.FeedUpdate[](2 * feedIds.length);
        for (uint256 i; i < feedIds.length; ++i) {
            updates[i] = MockPyth.FeedUpdate(
                feedIds[i], MockPyth.MockPrice(80_000_000, 0, -8, firstCommitTime + 1, firstCommitTime)
            );
            updates[i + feedIds.length] = MockPyth.FeedUpdate(
                feedIds[i], MockPyth.MockPrice(80_000_000, 0, -8, secondCommitTime + 1, secondCommitTime)
            );
        }
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(updates);
        vm.warp(secondCommitTime + 7);
        vm.roll(vm.getBlockNumber() + 2);
        vm.recordLogs();
        vm.prank(keeper);
        OrderV3Types.BatchResult memory result = router.executeOrderBatch(3, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(result.terminalCount, 2, "each order must resolve its own post-commit tick");
        OrderV3Types.OrderReceipt memory closeReceipt = _receipt(logs, 2);
        assertEq(uint8(closeReceipt.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(uint8(closeReceipt.reason), uint8(OrderV3Types.TerminalReason.Executed));
        OrderV3Types.OrderReceipt memory tailReceipt = _receipt(logs, 3);
        assertEq(uint8(tailReceipt.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(tailReceipt.reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(tailReceipt.failure.selector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
        assertEq(
            tailReceipt.failure.category,
            uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated)
        );
        assertEq(tailReceipt.failure.code, uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED));
        assertEq(tailReceipt.bounty.bountyPaidAssets, tailBounty);
        assertEq(tailReceipt.bounty.bountyRefundedAssets, 0);
        assertEq(tailReceipt.bounty.bountyForfeitedAssets, 0);
        assertEq(clearinghouse.balanceAssets(keeper) - keeperBefore, tailBounty);
        IMarginClearinghouse.OrderReservation memory reservation = clearinghouse.getOrderReservation(3);
        assertEq(uint8(reservation.status), uint8(IMarginClearinghouse.ReservationStatus.Released));
        assertEq(reservation.remainingAmountAssets, 0);
        assertEq(clearinghouse.getAccountReservationSummary(aliceAccount).activeCommittedOrderMarginAssets, 0);
        assertEq(clearinghouse.totalBountyReservationsAssets(aliceAccount), 0);
        assertEq(router.pendingOrderCounts(aliceAccount), 0);

        assertEq(
            router.nextExecuteId(),
            0,
            "Batch execution should continue past a trader-claim close and clear the queue when exhausted"
        );
        assertGt(
            engine.traderClaimBalanceAssets(aliceAccount), 0, "Trader claim should remain recorded after the batch"
        );

        (uint256 size,,,, CfdTypes.Side side,,) = engine.positions(aliceAccount);
        assertEq(
            size,
            0,
            "Tail open should be consumed even if trader claim leaves the protocol unable to re-open immediately"
        );
        assertEq(
            uint256(side),
            uint256(CfdTypes.Side.LONG),
            "Position metadata should remain stable after the close empties the position"
        );
    }

    function _receipt(
        Vm.Log[] memory logs,
        uint64 id
    ) internal view returns (OrderV3Types.OrderReceipt memory receipt) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(router.lifecycleBook()) && logs[i].topics.length == 4
                    && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector
                    && uint256(logs[i].topics[1]) == id
            ) {
                (bytes32 hash,, uint64 time, OrderV3Types.OrderReceipt memory found) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV3Types.OrderReceipt));
                assertEq(found.orderId, id);
                assertEq(found.account, address(uint160(uint256(logs[i].topics[2]))));
                assertEq(found.clientOrderId, logs[i].topics[3]);
                assertEq(router.lifecycleBook().terminalOutcome(id).receiptHash, hash);
                assertTrue(router.lifecycleBook().verifyReceipt(found, time), "receipt authenticates");
                receipt = found;
                ++count;
            }
        }
        assertEq(count, 1, "exactly one authenticated receipt per order");
    }

}

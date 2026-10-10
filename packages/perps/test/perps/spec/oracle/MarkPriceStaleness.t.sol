// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";

import {CfdOrderPolicyEvaluator} from "@plether/perps/CfdOrderPolicyEvaluator.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";

import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";

import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";

import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";

import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

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
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1 * 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        engine.setTerminalNavBook(address(new TerminalNavBookV2(address(engine), uint32(engine.CAP_PRICE()))));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Junior LP", "jUSDC", 0, address(0));
        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Senior LP", "sUSDC", 0, address(0));
        pool.setJuniorVault(address(juniorVault));
        pool.setSeniorVault(address(seniorVault));
        engine.setPool(address(pool));

        mockPyth = new MockPyth();
        mockPyth.setSynchronizeLegacyUniquePrices(true);
        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        engineLens = new CfdEngineLens(address(engine));
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        router = _deployLegacyOrderRouter(address(engine), address(engineLens), address(pool), address(pletherOracle));
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
    }

    function test_UpdateMarkPrice_RevertsOnStaleOracle() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 120);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.updateMarkPrice(updateData);
    }

    function test_UpdateMarkPrice_RevertsOnFutureOracle() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp + 1);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.updateMarkPrice(updateData);

        assertEq(engine.lastMarkTime(), 0, "Future oracle publication must not update the cached mark");
    }

    function test_UpdateMarkPrice_AcceptsFreshOracle() public {
        _startRecordingLogs();
        mockPyth.setAllPrices(feedIds, int64(100_000_000), int32(-8), block.timestamp - 30);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        router.updateMarkPrice(updateData);
        assertEq(engine.lastMarkPrice(), 1e8);
    }

    function test_Constructor_ZeroEngineLensReverts() public {
        _startRecordingLogs();
        PletherOracle testOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidEngineLens.selector);
        new OrderRouter(
            address(engine),
            address(0),
            address(pool),
            address(testOracle),
            address(keeperSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
    }

}

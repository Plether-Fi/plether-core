// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#oracle-and-freshness-policy

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
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
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract FuturePublishDelayTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_FuturePublishTimeRejectedBeforeDelayBypass() public {
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 110);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 110);

        vm.warp(104);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        vm.roll(block.number + 1);
        vm.warp(105);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, updateData);

        assertEq(router.nextExecuteId(), 1, "Future publish time must leave the order pending");
    }

}

contract StoredMarkOrderingTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_OlderEligibleTickTerminatesOrderWithoutRollingBackCachedMark() public {
        vm.warp(1000);
        vm.roll(100);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, 1020);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        uint256 expectedBounty = _executionBountyReserve(1);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.warp(1025);
        vm.roll(101);
        vm.prank(keeper);
        router.executeOrder(1, updateData);

        assertEq(router.nextExecuteId(), 0, "Historical execution should consume the order");
        assertEq(engine.lastMarkTime(), 1020, "Historical execution must not roll back the live mark");
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore, "Execution must preserve keeper wallet USDC");

        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            expectedBounty,
            "Terminal execution credits all reserved bounties"
        );
        assertEq(router.pendingOrderCounts(alice), 0);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_OlderEligibleTickTerminatesBatchWithoutRollingBackCachedMark() public {
        vm.warp(1000);
        vm.roll(100);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 20_000e18, 500e6, 1e8, false);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, 1020);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        uint256 keeperUsdcBefore = usdc.balanceOf(keeper);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        uint256 expectedBounty = _executionBountyReserve(1) + _executionBountyReserve(2);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.warp(1025);
        vm.roll(101);
        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(router.nextExecuteId(), 0, "Batch historical execution should consume covered orders");
        assertEq(engine.lastMarkTime(), 1020, "Batch historical execution must not roll back the live mark");
        assertEq(usdc.balanceOf(keeper), keeperUsdcBefore, "Execution must preserve keeper wallet USDC");

        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            expectedBounty,
            "Terminal execution credits all reserved bounties"
        );
        assertEq(router.pendingOrderCounts(alice), 0);
    }

}

contract TerminalEconomicStateOracleTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_UpdateMarkPriceMustRejectOlderPublishTime() public {
        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector);
        engine.updateMarkPrice(1.0e8, uint64(block.timestamp - 30));
    }

}

contract FreshPostCommitTickTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_FreshPriceAfterCommitIsAllowed() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1006);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1006);

        vm.warp(1006);
        vm.roll(block.number + 1);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        router.executeOrder(1, updateData);

        address account = alice;
        (uint256 size,,,,,,) = engine.positions(account);
        assertGt(size, 0, "Fresh price after commit should execute");
    }

}

contract MarkPublicationTimestampTest is BasePerpTest {

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_UpdateMarkUsesPublishTime() public {
        _fundTrader(address(0xAAA), 10_000 * 1e6);
        address traderAccount = address(0xAAA);
        _open(traderAccount, CfdTypes.Side.LONG, 50_000 * 1e18, 5000 * 1e6, 1e8);

        _warpForward(50);

        // An update published before lastMarkTime is rejected even when submitted later.
        uint64 vaaTime = engine.lastMarkTime() - 1;
        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector);
        engine.updateMarkPrice(0.8e8, vaaTime);
    }

}

contract SameBlockTickOrderingTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;

    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), _initialJuniorDeposit());

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_SameBlockPublishAfterCommitReturnsPending() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1001);

        vm.warp(1001);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, updateData);

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));
        assertEq(router.nextExecuteId(), 1, "Same-block execution must leave the FIFO head pending");
    }

}

contract PostCommitTimestampBoundsTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), _initialJuniorDeposit());
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_SameBlockPublishAfterCommitReturnsPending() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1005);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1005);

        vm.warp(1005);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, updateData);

        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV3Types.PendingReason.SameBlock));
        assertEq(router.nextExecuteId(), 1, "Same-block execution must leave the FIFO head pending");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_FutureDatedVaaShouldNotPanic() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1002);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1002);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, updateData);
    }

}

contract CrossBlockPostCommitTickTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        baseMockPyth = mockPyth;

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), _initialJuniorDeposit());
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_CrossBlockPublishAfterCommitExecutesWhenPublishTimeIsAfterCommit() public {
        uint256 commitTime = block.timestamp;

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        uint256 publishTime = commitTime + 1;
        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), publishTime, commitTime);

        vm.warp(publishTime);
        vm.roll(block.number + 1);
        bytes[] memory empty = new bytes[](1);
        empty[0] = "";

        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 10_000e18, "Fresh post-commit publish time should execute the order");
        assertEq(
            engine.lastMarkTime(), publishTime, "Execution should advance the mark to the post-commit publish time"
        );
    }

}

contract HistoricalTickSafetyTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();
        baseMockPyth = mockPyth;

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = _deployLegacyOrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(
                new PletherOracle(
                    address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
                )
            )
        );
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_ExecuteOrderRejectsStaleOracleWithoutFreshUpdateData() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        vm.warp(1016);
        vm.roll(block.number + 1);

        bytes[] memory noUpdateData;
        vm.expectRevert(IPletherOracle.PletherOracle__MissingUpdateData.selector);
        router.executeOrder(1, noUpdateData);
        assertEq(router.nextExecuteId(), 1, "Stale oracle execution must preserve the pending FIFO head");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_ExecutingOlderOrderCannotRollbackMarkPriceForWithdrawal() public {
        address trader = address(0xB0B);
        address account = trader;
        _fundTrader(trader, 1500e6);
        vm.deal(trader, 1 ether);
        _open(account, CfdTypes.Side.LONG, 20_000e18, 1000e6, 100_000_000);

        uint64 commitTime = uint64(block.timestamp + 1000);
        uint64 stalePublishTime = commitTime + 6;
        uint64 freshPublishTime = commitTime + 56;

        vm.warp(commitTime);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 1000e18, 0, 0, true);

        mockPyth.setPrice(FEED_A, int64(150_000_000), int32(-8), freshPublishTime);
        mockPyth.setPrice(FEED_B, int64(150_000_000), int32(-8), freshPublishTime);

        vm.warp(freshPublishTime);
        vm.roll(block.number + 1);
        bytes[] memory empty = new bytes[](1);
        empty[0] = "";
        router.updateMarkPrice(empty);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), stalePublishTime, commitTime);

        vm.roll(block.number + 1);
        vm.prank(trader);
        router.executeOrder(1, empty);

        assertEq(
            engine.lastMarkTime(), freshPublishTime, "Older execution payload must not roll back the engine mark time"
        );

        vm.prank(trader);
        vm.expectRevert(ICfdEngineTypes.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(account, 500e6);
    }

}

contract StaleExecutionReservationTest is Test {

    MockUSDC usdc;
    MockPyth mockPyth;
    CfdEngine engine;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    LegacyOrderRouterHarness router;
    OrderRouterAdmin routerAdmin;

    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    uint256 constant CAP_PRICE = 2e8;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    receive() external payable {}

    function setUp() public {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = new CfdEngine(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams(), 50);
        CfdEnginePlanner planner = new CfdEnginePlanner();
        CfdEngineSettlementSidecar settlement = new CfdEngineSettlementSidecar(address(engine));
        CfdEngineAdmin engineAdmin = new CfdEngineAdmin(address(engine), address(this));
        engine.setDependencies(address(planner), address(settlement), address(engineAdmin));
        TerminalNavBookV2 terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        bytes32[] memory feedIds = new bytes32[](2);
        uint256[] memory weights = new uint256[](2);
        uint256[] memory bases = new uint256[](2);
        bool[] memory inversions = new bool[](2);
        feedIds[0] = FEED_A;
        feedIds[1] = FEED_B;
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        bases[0] = 1e8;
        bases[1] = 1e8;

        CfdOrderPolicyEvaluator evaluator = new CfdOrderPolicyEvaluator();
        OrderRouterExecutionSidecar executionSidecar = new OrderRouterExecutionSidecar();
        CfdEngineLens testEngineLens = new CfdEngineLens(address(engine));
        PletherOracle testOracle =
            new PletherOracle(address(engine), address(pool), address(mockPyth), feedIds, weights, bases, inversions);
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        OrderLifecycleBook lifecycleBook =
            new OrderLifecycleBook(predictedRouter, address(engine), address(clearinghouse), address(pool));
        OrderRouterLiquidationBatchSidecar liquidationSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new LegacyOrderRouterHarness(
            address(engine),
            address(testEngineLens),
            address(pool),
            address(testOracle),
            address(liquidationSidecar),
            address(evaluator),
            address(executionSidecar),
            address(lifecycleBook)
        );
        assertEq(address(router), predictedRouter);
        routerAdmin = OrderRouterAdmin(router.admin());
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        pool.initializeSeedPosition(false, 1000e6, address(this));
        pool.initializeSeedPosition(true, 1000e6, address(this));
        pool.activateTrading();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);

        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    function _riskParams() internal pure returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
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
    }

    function _bypassAllTimelocks() internal {
        clearinghouse.setEngine(address(engine));

        IHousePool.PoolConfig memory config = IHousePool.PoolConfig({
            seniorRateBps: pool.seniorRateBps(),
            markStalenessLimit: pool.markStalenessLimit(),
            seniorFrozenLpFeeBps: pool.seniorFrozenLpFeeBps(),
            juniorFrozenLpFeeBps: pool.juniorFrozenLpFeeBps(),
            maxSeniorExposureUsdc: type(uint256).max - 1,
            maxSeniorShareBps: 9999
        });
        pool.proposePoolConfig(config);
        vm.warp(pool.poolConfigActivationTime());
        pool.finalizePoolConfig();
        vm.warp(1_709_532_000);
    }

    function _fundJunior(
        address lp,
        uint256 amount
    ) internal {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(juniorVault), amount);
        uint256 requestId = juniorVault.requestDeposit(amount, lp);
        vm.stopPrank();

        vm.warp(juniorVault.depositEpochStart(requestId));
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));
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

    /// @dev spec; source: ACCOUNTING_SPEC.md#oracle-and-freshness-policy.
    function test_StaleOracleKeepsOrderPendingWithoutBountyDistribution() public {
        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxExecutionWindowSeconds: 3600,
            orderExecutionStalenessLimit: router.pletherOracle().orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.pletherOracle().liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: router.pletherOracle().basketMaxConfidenceRatioBps(),
            orderSettlementWindow: router.pletherOracle().orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.pletherOracle().maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.pletherOracle().adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            positionProtectionTriggerBountyUsdc: router.positionProtectionTriggerBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        uint256 t0 = 2_000_000_000;
        vm.warp(t0);
        vm.roll(100);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 61);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 keeperUsdcBefore = clearinghouse.balanceUsdc(keeper);
        uint256 traderBefore = clearinghouse.balanceUsdc(alice);
        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(alice);

        vm.warp(t0 + 61);
        vm.roll(101);
        vm.prank(keeper);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, updateData);

        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperUsdcBefore,
            0,
            "Keeper should not collect the reserve on stale oracle input"
        );

        assertEq(clearinghouse.balanceUsdc(alice), traderBefore);
        assertEq(clearinghouse.lockedMarginUsdc(alice), lockedBefore);
        assertEq(router.nextExecuteId(), 1, "Stale execution must not terminally dequeue the order");
    }

}

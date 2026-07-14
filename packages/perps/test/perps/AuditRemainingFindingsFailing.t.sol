// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract AuditRemainingFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_H1_UserCanAddMarginWithoutChangingSize() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);
        _open(account, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        (, uint256 marginBefore,,,,,) = engine.positions(account);
        vm.prank(alice);
        engine.addMargin(account, 500e6);

        (, uint256 margin,,,,,) = engine.positions(account);
        assertEq(margin, marginBefore + 500e6, "User should be able to add margin without changing size");
    }

    function test_M1_ExecutionFeesAreProtocolRevenue() public {
        address account = alice;
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(account, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertGe(equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP equity");
        assertLe(
            equityAfter - equityBefore, 1000, "LP equity delta should be limited to incidental one-second senior yield"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            80e6,
            "Open and close execution fees should both accrue as protocol revenue"
        );
    }

    function test_H2_LiquidationMustRespectFreeUsdcCollateral() public {
        address account = alice;
        _fundTrader(alice, 1000e6);
        _open(account, CfdTypes.Side.BULL, 20_000e18, 312e6, 1e8);
        uint256 poolDepth = pool.totalAssets();

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(account, 99_500_000, poolDepth, uint64(block.timestamp), address(this));
    }

    function test_H3_RouterCannotTransferReservedSettlement() public {
        address account = alice;
        _fundTrader(alice, 1000e6);

        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(account, 100e6);

        vm.prank(address(router));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.transferReservedSettlement(account, attacker, 100e6);
    }

}

contract AuditRemainingFindingsFailing_MevDrift is BasePerpTest {

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
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
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

    function test_H2_CrossBlockPublishAfterCommitExecutesWhenPublishTimeIsAfterCommit() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), 1001, 1000);

        vm.warp(1001);
        vm.roll(block.number + 1);
        bytes[] memory empty = new bytes[](1);
        empty[0] = "";

        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(alice);
        assertEq(size, 10_000e18, "Fresh post-commit publish time should execute the order");
        assertEq(engine.lastMarkTime(), 1001, "Execution should advance the mark to the post-commit publish time");
    }

}

contract AuditRemainingFindingsFailing_StaleOracleExecution is BasePerpTest {

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
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setPool(address(pool));

        feedIds.push(FEED_A);
        feedIds.push(FEED_B);
        weights.push(0.5e18);
        weights.push(0.5e18);
        bases.push(1e8);
        bases.push(1e8);

        router = new OrderRouter(
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

    function test_M3_ExecuteOrderRejectsStaleOracleWithoutFreshUpdateData() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        vm.warp(1016);
        vm.roll(block.number + 1);

        bytes[] memory noUpdateData;
        vm.expectRevert(IPletherOracle.PletherOracle__MissingUpdateData.selector);
        router.executeOrder(1, noUpdateData);
        assertEq(router.nextExecuteId(), 1, "Stale oracle execution must preserve the pending FIFO head");
    }

    function test_C2_ExecutingOlderOrderCannotRollbackMarkPriceForWithdrawal() public {
        address trader = address(0xB0B);
        address account = trader;
        _fundTrader(trader, 1500e6);
        vm.deal(trader, 1 ether);
        _open(account, CfdTypes.Side.BULL, 20_000e18, 1000e6, 100_000_000);

        uint64 commitTime = uint64(block.timestamp + 1000);
        uint64 stalePublishTime = commitTime + 6;
        uint64 freshPublishTime = commitTime + 56;

        vm.warp(commitTime);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1000e18, 0, 0, true);

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

contract AuditRemainingFindingsFailing_CarryPathDependence is BasePerpTest {

    address alice = address(0xA11CE);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5 * 1e6,
            bountyBps: 10
        });
    }

    function test_M4_CarryRealizationShouldBePathIndependent() public {
        address account = alice;
        _fundTrader(alice, 150_000e6);
        _open(account, CfdTypes.Side.BULL, 200_000e18, 100_120e6, 1e8);

        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(120_000_000, uint64(block.timestamp));
        _close(account, CfdTypes.Side.BULL, 200_000e18, 120_000_000);
        uint256 markThenTradeBalance = clearinghouse.balanceUsdc(account);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 days);
        _close(account, CfdTypes.Side.BULL, 200_000e18, 120_000_000);
        uint256 tradeOnlyBalance = clearinghouse.balanceUsdc(account);

        assertEq(tradeOnlyBalance, markThenTradeBalance, "Carry realization should not depend on update-vs-trade path");
    }

}

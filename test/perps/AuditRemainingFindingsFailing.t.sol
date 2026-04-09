// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditRemainingFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    function test_H1_UserCanAddMarginWithoutChangingSize() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);
        vm.prank(alice);
        engine.addMargin(accountId, 500e6);

        (, uint256 margin,,,,,,) = engine.positions(accountId);
        assertEq(margin, marginBefore + 500e6, "User should be able to add margin without changing size");
    }

    function test_M1_ExecutionFeesAreProtocolRevenue() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertEq(equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP equity");
        assertEq(
            engine.accumulatedFeesUsdc(), 80e6, "Open and close execution fees should both accrue as protocol revenue"
        );
    }

    function test_H2_LiquidationMustRespectFreeUsdcCollateral() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 1000e6);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 312e6, 1e8);
        uint256 vaultDepth = pool.totalAssets();

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__PositionIsSolvent.selector);
        engine.liquidatePosition(accountId, 99_500_000, vaultDepth, uint64(block.timestamp));
    }

    function test_H3_OperatorCannotSeizeToArbitraryRecipient() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 1000e6);

        vm.prank(address(router));
        vm.expectRevert();
        clearinghouse.seizeUsdc(accountId, 100e6, attacker);
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
            new OrderRouter(address(engine), address(new CfdEngineLens(address(engine))), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), _initialJuniorDeposit());
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    function test_H2_CrossBlockPublishAfterCommitMustRevert() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1001);

        vm.warp(1001);
        bytes[] memory empty;

        vm.expectRevert();
        router.executeOrder(1, empty);
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
            new OrderRouter(address(engine), address(new CfdEngineLens(address(engine))), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2));
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    function test_M3_ExecuteOrderMustRequireFreshPythUpdateData() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1010);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1010);

        vm.warp(1050);
        vm.roll(block.number + 1);

        bytes[] memory empty;
        vm.expectRevert();
        router.executeOrder(1, empty);
    }

    function test_C2_ExecutingOlderOrderCannotRollbackMarkPriceForWithdrawal() public {
        address trader = address(0xB0B);
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        _fundTrader(trader, 1500e6);
        vm.deal(trader, 1 ether);
        _open(accountId, CfdTypes.Side.BULL, 20_000e18, 1000e6, 100_000_000);

        uint64 commitTime = uint64(block.timestamp + 1000);
        uint64 stalePublishTime = commitTime + 6;
        uint64 freshPublishTime = commitTime + 56;

        vm.warp(commitTime);
        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 0, 0, true);

        mockPyth.setPrice(FEED_A, int64(150_000_000), int32(-8), freshPublishTime);
        mockPyth.setPrice(FEED_B, int64(150_000_000), int32(-8), freshPublishTime);

        vm.warp(freshPublishTime);
        vm.roll(block.number + 1);
        bytes[] memory empty = new bytes[](1);
        empty[0] = "";
        router.updateMarkPrice(empty);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), stalePublishTime);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), stalePublishTime);

        vm.roll(block.number + 1);
        vm.prank(trader);
        vm.expectRevert(OrderRouter.OrderRouter__OraclePublishTimeOutOfOrder.selector);
        router.executeOrder(1, empty);

        assertEq(
            engine.lastMarkTime(), freshPublishTime, "Older execution payload must not roll back the engine mark time"
        );

        vm.prank(trader);
        vm.expectRevert(CfdEngine.CfdEngine__WithdrawBlockedByOpenPosition.selector);
        clearinghouse.withdraw(accountId, 500e6);
    }

}

contract AuditRemainingFindingsFailing_FundingPathDependence is BasePerpTest {

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
            bountyBps: 15
        });
    }

    function test_M4_FundingSettlementShouldBePathIndependent() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 150_000e6);
        _open(accountId, CfdTypes.Side.BULL, 200_000e18, 100_120e6, 1e8);

        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(router));
        engine.updateMarkPrice(120_000_000, uint64(block.timestamp));
        _close(accountId, CfdTypes.Side.BULL, 200_000e18, 120_000_000);
        uint256 markThenTradeBalance = clearinghouse.balanceUsdc(accountId);

        vm.revertToState(snap);

        vm.warp(block.timestamp + 1 days);
        _close(accountId, CfdTypes.Side.BULL, 200_000e18, 120_000_000);
        uint256 tradeOnlyBalance = clearinghouse.balanceUsdc(accountId);

        assertEq(tradeOnlyBalance, markThenTradeBalance, "Funding accrual should not depend on update-vs-trade path");
    }

}

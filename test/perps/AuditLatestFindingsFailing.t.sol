// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditLatestFindingsFailing_Core is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_C1_RealizedBadDebtShouldNotBeDoubleCountedInMtM() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        bytes32 winnerId = bytes32(uint256(uint160(winner)));
        bytes32 loserId = bytes32(uint256(uint160(loser)));

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerId, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserId, CfdTypes.Side.BULL, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserId, 1e8, depth, uint64(block.timestamp));

        assertGt(engine.accumulatedBadDebtUsdc(), 0, "Setup must realize bad debt");

        uint256 price = engine.lastMarkPrice();
        int256 bullPnl =
            (int256(_sideEntryNotional(CfdTypes.Side.BULL)) - int256(_sideOpenInterest(CfdTypes.Side.BULL) * price))
                / int256(1e20);
        int256 bearPnl =
            (int256(_sideOpenInterest(CfdTypes.Side.BEAR) * price) - int256(_sideEntryNotional(CfdTypes.Side.BEAR)))
                / int256(1e20);

        uint256 expectedMtm = 0;
        if (bullPnl > 0) {
            expectedMtm += uint256(bullPnl);
        }
        if (bearPnl > 0) {
            expectedMtm += uint256(bearPnl);
        }

        assertEq(_vaultMtmAdjustment(), expectedMtm, "Realized bad debt should already be priced into MtM");
    }

    function test_H1_MarginOnlyUpdateViaRouterReverts() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        (bool ok,) = address(router)
            .call(abi.encodeWithSelector(router.commitOrder.selector, CfdTypes.Side.BULL, 0, 500e6, 1e8, false));
        assertFalse(ok, "Margin-only updates must be rejected at commit time");
    }

    function test_M1_ExecutionFeesAccrueToProtocolNotLpEquity() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(aliceId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertEq(
            equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP distributable equity"
        );
        assertEq(
            engine.accumulatedFeesUsdc(), 80e6, "Open and close execution fees should both accrue as protocol revenue"
        );
    }

    function test_M2_WipedTrancheRejectsNewDeposits() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        address recapLp = address(0xCAFE);
        usdc.mint(recapLp, 10_000e6);

        vm.startPrank(recapLp);
        usdc.approve(address(seniorVault), type(uint256).max);
        vm.expectRevert(TrancheVault.TrancheVault__TerminallyWiped.selector);
        seniorVault.deposit(10_000e6, recapLp);
        vm.stopPrank();
    }

    function test_I1_CloseWithMarginDeltaMustRevert() public {
        bytes32 aliceId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 50_000e6);
        _open(aliceId, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        (bool ok,) = address(router)
            .call(abi.encodeWithSelector(router.commitOrder.selector, CfdTypes.Side.BULL, 20_000e18, 500e6, 0, true));
        assertFalse(ok, "Close orders with positive marginDelta must be rejected");
    }

}

contract AuditLatestFindingsFailing_VPI is BasePerpTest {

    address alice = address(0x111);
    address bob = address(0x222);
    address carol = address(0x333);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.01e18,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C2_DepthManipulationShouldNotBeProfitable() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.BEAR, 200_000e18, 40_000e6, 1e8, false);
        bytes[] memory empty;
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000e6);
        bytes32 aliceAccount = bytes32(uint256(uint160(alice)));
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, empty);

        _fundJunior(bob, 9_000_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);
        bytes[] memory closePrice = new bytes[](1);
        closePrice[0] = abi.encode(uint256(1e8));
        router.executeOrder(3, closePrice);

        uint256 aliceBalAfter = clearinghouse.balanceUsdc(aliceAccount);

        assertLe(aliceBalAfter, aliceBalBefore, "Depth manipulation round-trip must not produce positive PnL");
    }

}

contract AuditLatestFindingsFailing_MevDrift is BasePerpTest {

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

        router = new OrderRouter(
            address(engine),
            address(new CfdEngineLens(address(engine))),
            address(pool),
            address(mockPyth),
            feedIds,
            weights,
            bases,
            new bool[](2)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), _initialJuniorDeposit());

        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    function test_H2_CrossBlockPublishAfterCommitReverts() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1001);

        vm.warp(1001);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(OrderRouter.OrderRouter__MevDetected.selector);
        router.executeOrder(1, updateData);
    }

}

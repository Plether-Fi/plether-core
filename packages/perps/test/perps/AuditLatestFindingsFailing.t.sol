// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_C1_PriceWriteoffShouldNotBeDoubleCountedInExactTerminalNav() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.LONG, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.LONG, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(loserAccount, 1e8);
        assertLt(preview.pnlUsdc, 0, "Setup must realize a trader price loss");
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(loserAccount).terminalPriceCollectibleCapUsdc;
        assertGt(priceLossUsdc, collectibleCapUsdc, "Setup must contain a diagnostic price-loss writeoff");
        assertEq(preview.badDebtUsdc, 0, "Written-off price tails must not become protocol debt");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        assertEq(
            _poolMtmAdjustment(),
            50_000e6,
            "Exact NAV must include only the surviving winner's marked gain, not the written-off price tail"
        );
    }

    function test_H1_MarginOnlyUpdateViaRouterReverts() public {
        address aliceAccount = alice;
        _fundTrader(alice, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        (bool ok,) = address(router)
            .call(
                abi.encodeWithSelector(
                    bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")),
                    CfdTypes.Side.LONG,
                    0,
                    500e6,
                    1e8,
                    false
                )
            );
        assertFalse(ok, "Margin-only updates must be rejected at commit time");
    }

    function test_M1_ExecutionFeesAccrueToProtocolNotLpEquity() public {
        address aliceAccount = alice;
        _fundTrader(alice, 50_000e6);

        uint256 equityBefore = pool.seniorPrincipal() + pool.juniorPrincipal();

        _open(aliceAccount, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        bytes[] memory priceData = _mockPythUpdateData(1e8);
        vm.roll(block.number + 1);
        router.executeOrder(1, priceData);

        vm.prank(address(juniorVault));
        pool.reconcile();

        uint256 equityAfter = pool.seniorPrincipal() + pool.juniorPrincipal();
        assertGe(
            equityAfter, equityBefore, "User-funded close-order bounties should not reduce LP distributable equity"
        );
        assertEq(
            clearinghouse.balanceUsdc(engine.protocolTreasury()),
            80e6,
            "Open and close execution fees should both accrue as protocol revenue"
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
        seniorVault.requestDeposit(10_000e6, recapLp);
        vm.stopPrank();
    }

    function test_I1_CloseWithMarginDeltaMustRevert() public {
        address aliceAccount = alice;
        _fundTrader(alice, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 20_000e18, 5000e6, 1e8);

        vm.prank(alice);
        (bool ok,) = address(router)
            .call(
                abi.encodeWithSelector(
                    bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")),
                    CfdTypes.Side.LONG,
                    20_000e18,
                    500e6,
                    0,
                    true
                )
            );
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
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function test_C2_DepthManipulationShouldNotBeProfitable() public {
        _fundJunior(bob, 1_000_000e6);

        _fundTrader(carol, 50_000e6);
        vm.prank(carol);
        router.commitOrder(CfdTypes.Side.SHORT, 200_000e18, 40_000e6, 1e8, false);
        bytes[] memory empty = _mockPythUpdateData();
        router.executeOrder(1, empty);

        _fundTrader(alice, 50_000e6);
        address aliceAccount = alice;
        uint256 aliceBalBefore = clearinghouse.balanceUsdc(aliceAccount);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        router.executeOrder(2, _mockPythUpdateData(1e8));

        usdc.mint(address(pool), 9_000_000e6);
        vm.prank(address(engine));
        pool.recordProtocolInflow(9_000_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);
        bytes[] memory closePrice = _mockPythUpdateData(1e8);
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
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

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

    function test_H2_SameBlockPublishAfterCommitReturnsPending() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1001);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 1001);

        vm.warp(1001);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        OrderV2Types.ExecutionResult memory result = router.executeOrder(1, updateData);

        assertEq(uint8(result.status), uint8(OrderV2Types.LifecycleStatus.Pending));
        assertEq(uint8(result.pendingReason), uint8(OrderV2Types.PendingReason.SameBlock));
        assertEq(router.nextExecuteId(), 1, "Same-block execution must leave the FIFO head pending");
    }

}

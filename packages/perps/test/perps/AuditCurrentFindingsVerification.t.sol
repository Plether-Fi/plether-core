// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {OrderRouterLiquidationBatchSidecar} from "@plether/perps/OrderRouterLiquidationBatchSidecar.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract AuditCurrentFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_C3_DiagnosticPriceWriteoffShouldNotBeDoubleCounted() public {
        address winner = address(0xAAA1);
        address loser = address(0xBBB1);
        address winnerAccount = winner;
        address loserAccount = loser;

        _fundTrader(winner, 200_000e6);
        _fundTrader(loser, 2000e6);

        _open(winnerAccount, CfdTypes.Side.BULL, 100_000e18, 100_000e6, 1.5e8);
        _open(loserAccount, CfdTypes.Side.BULL, 100_000e18, 1000e6, 0.5e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(loserAccount, 1e8);
        uint256 priceLossUsdc = uint256(-preview.pnlUsdc);
        uint256 collectibleCapUsdc =
            engineAccountLens.getAccountLedgerSnapshot(loserAccount).terminalPriceCollectibleCapUsdc;
        assertGt(priceLossUsdc, collectibleCapUsdc, "Setup must contain an uncollectible terminal price tail");
        assertEq(preview.badDebtUsdc, 0, "V2 price tails are diagnostic writeoffs, not protocol debt");

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        assertEq(
            _poolMtmAdjustment(),
            50_000e6,
            "Exact terminal NAV should retain only the surviving winner liability after the loser's writeoff"
        );
    }

    function test_H1_UpdateMarkPriceMustRejectOlderPublishTime() public {
        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector);
        engine.updateMarkPrice(1.0e8, uint64(block.timestamp - 30));
    }

    function test_H2_SeniorHighWaterMarkMustSurviveFullWipeout() public {
        _fundSenior(alice, 100_000e6);
        _fundJunior(bob, 100_000e6);

        uint256 total = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), total);

        vm.prank(address(juniorVault));
        pool.reconcile();

        assertGt(pool.seniorHighWaterMark(), 0, "Senior recovery rights should survive wipeout");
    }

}

contract AuditCurrentFindingsFailing_BountyCap is BasePerpTest {

    address internal constant ACCOUNT_ID = address(uint160(1234));

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            maintMarginBps: 10,
            initMarginBps: ((10) * 15) / 10,
            fadMarginBps: 1000,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 1000,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    function test_M2_KeeperBountyShouldUseExplicitSubsidyModel() public {
        address trader = ACCOUNT_ID;
        _fundTrader(trader, 100e6);

        _open(ACCOUNT_ID, CfdTypes.Side.BULL, CfdTypes.SIZE_QUANTUM, 12e6, 1e8);

        uint256 freeSettlementUsdc = _freeSettlementUsdc(ACCOUNT_ID);
        vm.prank(trader);
        clearinghouse.withdraw(ACCOUNT_ID, freeSettlementUsdc);

        vm.warp(1_709_971_200); // Saturday during FAD
        uint256 depth = pool.totalAssets();
        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(ACCOUNT_ID, 1.01e8);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(ACCOUNT_ID);
        assertTrue(preview.liquidatable, "FAD maintenance must make the positive-equity fixture liquidatable");
        assertEq(
            preview.liquidationChargeUsdc,
            liquidationReserveBefore,
            "Liquidation charge must be capped by the dedicated reserve"
        );

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(ACCOUNT_ID, 1.01e8, depth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Keeper bounty must match the dedicated-reserve preview");
        assertEq(
            bounty,
            (liquidationReserveBefore * _riskParams().keeperShareBps) / 10_000,
            "Keeper must receive only its configured share of the funded liquidation reserve"
        );
    }

}

contract AuditCurrentFindingsVerifiedInvalid is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_C2_ZeroSizeMarginUpdateRejectedAtCommit() public {
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 0, 500e6, 1e8, false);
    }

    function test_M1_WipedTrancheRejectsOrdinaryRecapitalizationDeposits() public {
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

}

contract AuditCurrentFindingsVerifiedInvalid_Mev is BasePerpTest {

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

        engineLens = new CfdEngineLens(address(engine));
        pletherOracle = new PletherOracle(
            address(engine), address(pool), address(mockPyth), feedIds, weights, bases, new bool[](2)
        );
        address predictedRouter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        OrderRouterLiquidationBatchSidecar keeperSidecar = new OrderRouterLiquidationBatchSidecar(predictedRouter);
        router = new OrderRouter(
            address(engine), address(engineLens), address(pool), address(pletherOracle), address(keeperSidecar)
        );
        assertEq(address(router), predictedRouter);
        engine.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _bootstrapSeededLifecycle();
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 10 ether);
    }

    function test_C1_FreshPriceAfterCommitIsAllowed() public {
        vm.warp(1000);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 500e6, 1e8, false);

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

contract AuditCurrentFindingsVerifiedInvalid_RebateIlliquidity is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0.05e18,
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
        return 2_000_000e6;
    }

    function test_M1_RebateIlliquidityIsTypedAsSolvencyInvalidation() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 200_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 300_000e18, 50_000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 2000e6);

        uint8 code = engineLens.previewOpenRevertCode(
            bobAccount, CfdTypes.Side.BEAR, 300_000e18, 10_000e6, 1e8, uint64(block.timestamp)
        );
        assertEq(
            code,
            uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED),
            "rebate-bearing opens must surface their independent VPI-reserve funding failure"
        );
    }

    function test_M1_RebateIlliquidityPaysClearerBounty() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 200_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 300_000e18, 50_000e6, 1e8);

        _fundTrader(bob, 20_000e6);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.BEAR, 300_000e18, 10_000e6, 1e8, false);

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 2000e6);

        address keeperAccount = address(this);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeperAccount);
        uint256 bobSettlementBefore = clearinghouse.balanceUsdc(bobAccount);
        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(bobAccount);
        assertEq(size, 0, "rebate-bearing open should not execute once pool cash is insufficient");
        assertEq(
            clearinghouse.balanceUsdc(keeperAccount) - keeperBefore,
            pending.executionBountyUsdc,
            "keeper should receive the reserved bounty on typed solvency invalidation under current policy"
        );
        assertEq(
            bobSettlementBefore - clearinghouse.balanceUsdc(bobAccount),
            pending.executionBountyUsdc,
            "user should pay the reserved bounty under current failure policy"
        );
    }

}

contract AuditCurrentFindingsFuturePublishSafety is BasePerpTest {

    address alice = address(0xA11CE);

    function test_FutureLastMarkTime_DoesNotBreakWithdrawGuardOrReconcile() public {
        address aliceAccount = alice;

        _fundSenior(address(0xBEEF), 100_000e6);
        _fundTrader(alice, 50_000e6);
        _open(aliceAccount, CfdTypes.Side.BULL, 20_000e18, 5000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp + 5));

        vm.prank(address(clearinghouse));
        engine.checkWithdraw(aliceAccount);

        vm.prank(address(juniorVault));
        pool.reconcile();
    }

}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEngineLens} from "../../src/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditCurrentFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function test_C3_RealizedBadDebtShouldNotBeDoubleCounted() public {
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

        uint256 depth = pool.totalAssets();
        vm.prank(address(router));
        engine.liquidatePosition(loserAccount, 1e8, depth, uint64(block.timestamp), address(this));

        assertEq(_vaultMtmAdjustment(), 75_000e6, "MtM should use the conservative post-liquidation envelope");
    }

    function test_H1_UpdateMarkPriceMustRejectOlderPublishTime() public {
        vm.prank(address(router));
        engine.updateMarkPrice(1.1e8, uint64(block.timestamp));

        vm.prank(address(router));
        vm.expectRevert(CfdEngine.CfdEngine__MarkPriceOutOfOrder.selector);
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
            bountyBps: 1000
        });
    }

    function test_M2_KeeperBountyShouldUseExplicitSubsidyModel() public {
        address trader = ACCOUNT_ID;
        _fundTrader(trader, 100e6);

        _open(ACCOUNT_ID, CfdTypes.Side.BULL, 100e18, 6e6, 1e8);

        vm.prank(trader);
        clearinghouse.withdraw(ACCOUNT_ID, 94e6);

        vm.warp(1_709_971_200); // Saturday during FAD
        uint256 depth = pool.totalAssets();
        CfdEngine.LiquidationPreview memory preview = engineLens.previewLiquidation(ACCOUNT_ID, 1.01e8);

        vm.prank(address(router));
        uint256 bounty = engine.liquidatePosition(ACCOUNT_ID, 1.01e8, depth, uint64(block.timestamp), address(this));

        assertEq(bounty, preview.keeperBountyUsdc, "Keeper bounty should use the explicit subsidy model");
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
        seniorVault.deposit(10_000e6, recapLp);
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
            bountyBps: 10
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
            uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
            "rebate-drained opens should surface the fee-drain typed failure before execution"
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
        bytes[] memory empty;
        vm.roll(block.number + 1);
        router.executeOrder(1, empty);

        (uint256 size,,,,,,) = engine.positions(bobAccount);
        assertEq(size, 0, "rebate-bearing open should not execute once vault cash is insufficient");
        assertEq(
            clearinghouse.balanceUsdc(keeperAccount) - keeperBefore,
            pending.executionBountyUsdc,
            "keeper should receive the reserved bounty on typed solvency invalidation under current policy"
        );
        assertEq(
            clearinghouse.balanceUsdc(bobAccount) - bobSettlementBefore,
            0,
            "user should not receive a refund under current policy"
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

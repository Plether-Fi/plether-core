// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdEnginePlanTypes} from "../../src/perps/CfdEnginePlanTypes.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "../../src/perps/interfaces/IOrderRouterAccounting.sol";
import {CfdEnginePlanLib} from "../../src/perps/libraries/CfdEnginePlanLib.sol";
import {CfdEngineSnapshotsLib} from "../../src/perps/libraries/CfdEngineSnapshotsLib.sol";
import {MarginClearinghouseAccountingLib} from "../../src/perps/libraries/MarginClearinghouseAccountingLib.sol";
import {SolvencyAccountingLib} from "../../src/perps/libraries/SolvencyAccountingLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BasePerpTest} from "./BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AuditBlockingAccountingFindingsFailing is BasePerpTest {

    address alice = address(0xA11CE);

    function test_H1_PlannerAppliedStateMustNotConsumeProtectedResidualMargin() public {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(60e6, 20e6, 30e6, 0);

        MarginClearinghouseAccountingLib.SettlementConsumption memory plan =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, 20e6, 40e6);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, 20e6, plan);

        assertEq(plan.freeSettlementConsumedUsdc, 10e6, "Plan should consume free settlement first");
        assertEq(plan.activeMarginConsumedUsdc, 0, "Protected residual margin must not be attributed as consumed");
        assertEq(
            plan.otherLockedMarginConsumedUsdc,
            30e6,
            "Plan should consume queued committed margin after free settlement"
        );
        assertEq(
            buckets.totalLockedMarginUsdc - mutation.positionMarginUnlockedUsdc
                - mutation.otherLockedMarginUnlockedUsdc,
            20e6,
            "Applied locked margin should equal surviving protected residual margin"
        );
    }

}

contract CfdEngineSolvencyTimingHarness is CfdEngine {

    constructor(
        address usdc,
        address clearinghouse,
        uint256 capPrice,
        CfdTypes.RiskParams memory params
    ) CfdEngine(usdc, clearinghouse, capPrice, params) {}

    function previewEffectiveAssetsAfterFundingWithoutMarginSync(
        CfdTypes.Order memory order
    )
        external
        returns (
            uint256 staleEffectiveAssets,
            uint256 syncedEffectiveAssets,
            uint256 staleSideMargin,
            uint256 syncedSideMargin
        )
    {
        CfdTypes.Position storage pos = positions[order.accountId];
        uint256 marginBefore = pos.margin;
        CfdTypes.Side marginSide = pos.side;

        CfdEnginePlanTypes.RawSnapshot memory snap =
            _buildRawSnapshot(order.accountId, lastMarkPrice, vault.totalAssets(), 0);
        snap.vaultCashUsdc = vault.totalAssets();
        CfdEnginePlanTypes.FundingDelta memory fd =
            CfdEnginePlanLib.planFunding(snap, lastMarkPrice, 0, order.isClose, order.sizeDelta == pos.size);
        _applyFundingAndMark(
            fd.bullFundingIndexDelta,
            fd.bearFundingIndexDelta,
            fd.fundingAbsSkewUsdc,
            fd.newLastFundingTime,
            fd.newLastMarkPrice,
            fd.newLastMarkTime
        );
        _applyFundingSettlement(fd, order.accountId, pos);

        uint256 marginAfter = pos.margin;
        uint256 provisionalBullMargin = sides[uint256(CfdTypes.Side.BULL)].totalMargin;
        uint256 provisionalBearMargin = sides[uint256(CfdTypes.Side.BEAR)].totalMargin;
        if (marginAfter > marginBefore) {
            if (marginSide == CfdTypes.Side.BULL) {
                provisionalBullMargin += marginAfter - marginBefore;
            } else {
                provisionalBearMargin += marginAfter - marginBefore;
            }
        } else if (marginBefore > marginAfter) {
            if (marginSide == CfdTypes.Side.BULL) {
                provisionalBullMargin -= marginBefore - marginAfter;
            } else {
                provisionalBearMargin -= marginBefore - marginAfter;
            }
        }

        _syncTotalSideMargin(marginSide, marginBefore, marginAfter);

        staleSideMargin = sides[uint256(marginSide)].totalMargin;
        syncedSideMargin = marginSide == CfdTypes.Side.BULL ? provisionalBullMargin : provisionalBearMargin;

        (int256 bullFunding, int256 bearFunding) = _computeGlobalFundingPnl();
        CfdEngineSnapshotsLib.FundingSnapshot memory staleFunding = CfdEngineSnapshotsLib.buildFundingSnapshot(
            bullFunding,
            bearFunding,
            sides[uint256(CfdTypes.Side.BULL)].totalMargin,
            sides[uint256(CfdTypes.Side.BEAR)].totalMargin
        );
        CfdEngineSnapshotsLib.FundingSnapshot memory syncedFunding = CfdEngineSnapshotsLib.buildFundingSnapshot(
            bullFunding, bearFunding, provisionalBullMargin, provisionalBearMargin
        );

        staleEffectiveAssets =
        SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            staleFunding.solvencyFunding,
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        )
        .effectiveAssetsUsdc;
        syncedEffectiveAssets =
        SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            syncedFunding.solvencyFunding,
            totalDeferredPayoutUsdc,
            totalDeferredClearerBountyUsdc
        )
        .effectiveAssetsUsdc;
    }

}

contract AuditBlockingAccountingFindingsFailing_SolvencyTiming is BasePerpTest {

    address bullTraderA = address(0xB011);
    address bullTraderB = address(0xB012);
    address bearTrader = address(0xBEA2);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 1e18,
            maxApy: 5e18,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 5e6,
            bountyBps: 15
        });
    }

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        usdc = new MockUSDC();
        clearinghouse = new MarginClearinghouse(address(usdc));

        engine = new CfdEngineSolvencyTimingHarness(address(usdc), address(clearinghouse), CAP_PRICE, _riskParams());
        pool = new HousePool(address(usdc), address(engine));

        seniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC");
        juniorVault = new TrancheVault(IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC");
        pool.setSeniorVault(address(seniorVault));
        pool.setJuniorVault(address(juniorVault));
        engine.setVault(address(pool));

        router = new OrderRouter(
            address(engine),
            address(pool),
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0),
            new bool[](0)
        );
        engine.setOrderRouter(address(router));
        pool.setOrderRouter(address(router));

        _bypassAllTimelocks();
        _fundJunior(address(this), 1_000_000e6);
    }

    function test_H2_SolvencyCheckInputsMustMatchCommittedPostOpSideMargins() public {
        _fundTrader(bullTraderA, 15_000e6);
        _fundTrader(bullTraderB, 400_000e6);
        _fundTrader(bearTrader, 100_000e6);

        bytes32 bullIdA = bytes32(uint256(uint160(bullTraderA)));
        bytes32 bullIdB = bytes32(uint256(uint160(bullTraderB)));
        bytes32 bearId = bytes32(uint256(uint160(bearTrader)));

        _open(bullIdA, CfdTypes.Side.BULL, 390_000e18, 6500e6, 1e8);
        _open(bullIdB, CfdTypes.Side.BULL, 10_000e18, 300_000e6, 1e8);
        _open(bearId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.warp(block.timestamp + 180 days);
        vm.prank(address(router));
        engine.updateMarkPrice(1e8, uint64(block.timestamp));

        CfdEngineSolvencyTimingHarness harness = CfdEngineSolvencyTimingHarness(address(engine));
        (
            uint256 staleEffectiveAssets,
            uint256 syncedEffectiveAssets,
            uint256 staleBullMargin,
            uint256 syncedBullMargin
        ) = harness.previewEffectiveAssetsAfterFundingWithoutMarginSync(
            CfdTypes.Order({
                accountId: bullIdA,
                sizeDelta: 390_000e18,
                marginDelta: 0,
                targetPrice: 0,
                commitTime: uint64(block.timestamp),
                commitBlock: uint64(block.number),
                orderId: 0,
                side: CfdTypes.Side.BULL,
                isClose: true
            })
        );

        assertEq(
            staleBullMargin,
            syncedBullMargin,
            "Solvency/degraded checks must use the same side margins that would be committed after funding settlement"
        );
        assertEq(
            staleEffectiveAssets,
            syncedEffectiveAssets,
            "Solvency effective assets must not depend on stale in-flight side-margin totals"
        );
    }

}

contract AuditBlockingAccountingFindingsFailing_PartialCloseWithCommittedMargin is BasePerpTest {

    address trader = address(0xC106);
    address counterparty = address(0xBEA2);
    address constant KEEPER = address(0xC0FFEE);

    function test_H1_PartialCloseWithPendingOrderDoesNotRevert() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        bytes32 counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = router.committedMargins(1);
        assertGt(committedBefore, 0, "Should have committed margin from pending open order");

        uint256 freeSettlement = clearinghouse.getFreeSettlementBalanceUsdc(accountId);
        assertLt(freeSettlement, 1100e6, "Free settlement should be small after committing margin");

        _close(accountId, CfdTypes.Side.BULL, 50_000e18, 1.05e8);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 50_000e18, "Partial close should leave half the position");
    }

    function test_H1_PartialCloseLossConsumesCommittedMarginReservation() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        bytes32 counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = router.committedMargins(1);
        assertEq(committedBefore, 4000e6, "Committed margin should match order margin delta");

        uint256 settlementBefore = clearinghouse.balanceUsdc(accountId);

        // Close at 1.08e8 (basket up → BULL loss). 50k of 100k position.
        // BULL PnL = (entryBasket - exitBasket) * size = (1e8 - 1.08e8) * 50k
        // This loss exceeds free settlement, forcing consumption of committed margin.
        _close(accountId, CfdTypes.Side.BULL, 50_000e18, 1.08e8);

        uint256 settlementAfter = clearinghouse.balanceUsdc(accountId);
        uint256 committedAfter = router.committedMargins(1);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 50_000e18, "Partial close should leave half the position");
        assertLt(settlementAfter, settlementBefore, "Settlement balance should decrease from loss");
        assertLt(committedAfter, committedBefore, "Committed margin reservation should be partially consumed by loss");
    }

}

contract AuditBlockingAccountingFindingsFailing_DeferredBounty is BasePerpTest {

    address trader = address(0xC200);
    address counterparty = address(0xBEA3);
    address constant KEEPER = address(0xC0FFEE);

    function _setupFullyUtilized() internal returns (bytes32 accountId, bytes32 counterId) {
        accountId = bytes32(uint256(uint160(trader)));
        counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 5000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        assertEq(
            clearinghouse.getFreeSettlementBalanceUsdc(accountId), 0, "Trader should be fully utilized before commit"
        );
    }

    function test_H2_FullyUtilizedTraderCanSubmitAndExecuteCloseOrder() public {
        (bytes32 accountId,) = _setupFullyUtilized();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        OrderRouter.OrderRecord memory record = router.getOrderRecord(1);
        assertTrue(record.bountyDeferred, "Close order bounty should be deferred when free settlement is 0");
        assertEq(record.executionBountyUsdc, 1e6, "Deferred bounty amount should be 1 USDC");
        assertEq(router.executionBountyReserves(1), 0, "Router should not custody deferred bounty");

        IOrderRouterAccounting.AccountEscrowView memory escrow = router.getAccountEscrow(accountId);
        assertEq(escrow.executionBountyUsdc, 0, "Deferred bounty must not appear in account escrow view");

        uint256 routerBalanceBefore = usdc.balanceOf(address(router));
        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Close should have fully closed the position");

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(keeperBounty, 1e6, "Keeper should receive the deferred bounty from freed margin");

        assertEq(
            usdc.balanceOf(address(router)),
            routerBalanceBefore,
            "Router USDC balance should be unchanged (deferred bounty bypasses router custody)"
        );

        record = router.getOrderRecord(1);
        assertFalse(record.bountyDeferred, "Deferred flag should be cleared after collection");
        assertEq(record.executionBountyUsdc, 0, "Bounty amount should be zeroed after collection");
    }

    function test_H2_ExpiredDeferredCloseForfeitsKeeperBounty() public {
        (bytes32 accountId,) = _setupFullyUtilized();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        assertTrue(router.getOrderRecord(1).bountyDeferred, "Should be deferred");

        router.proposeMaxOrderAge(60);
        vm.warp(block.timestamp + 48 hours + 1);
        router.finalizeMaxOrderAge();

        vm.warp(block.timestamp + 61);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(keeperBounty, 0, "Expired deferred close should forfeit keeper bounty");

        assertEq(
            clearinghouse.getFreeSettlementBalanceUsdc(accountId),
            0,
            "Trader margin should remain untouched after expired close"
        );
    }

    function test_H2_LiquidationWithDeferredCloseOrderDoesNotOverTransfer() public {
        (bytes32 accountId,) = _setupFullyUtilized();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        assertTrue(router.getOrderRecord(1).bountyDeferred, "Should be deferred");

        uint256 routerBalanceBefore = usdc.balanceOf(address(router));

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.96e8));

        vm.prank(KEEPER);
        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Position should be liquidated");

        assertEq(
            usdc.balanceOf(address(router)),
            routerBalanceBefore,
            "Router should not transfer USDC it doesnt hold for deferred bounties"
        );

        OrderRouter.OrderRecord memory record = router.getOrderRecord(1);
        assertEq(record.executionBountyUsdc, 0, "Deferred bounty should be cleared on liquidation");
    }

    function test_H2_OpenOrderStillRevertsWhenFullyUtilized() public {
        _setupFullyUtilized();

        vm.prank(trader);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 0, type(uint256).max, false);
    }

}

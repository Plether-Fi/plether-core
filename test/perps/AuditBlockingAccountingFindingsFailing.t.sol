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
            MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(60e6, 20e6, 30e6, 0);

        MarginClearinghouseAccountingLib.SettlementConsumption memory plan =
            MarginClearinghouseAccountingLib.planTerminalLossConsumption(buckets, 20e6, 40e6);
        MarginClearinghouseAccountingLib.BucketMutation memory mutation =
            MarginClearinghouseAccountingLib.applyTerminalLossMutation(buckets, 20e6, plan);

        assertEq(plan.freeSettlementConsumedUsdc, 10e6, "Plan should consume free settlement first");
        assertEq(plan.activeMarginConsumedUsdc, 0, "Protected residual margin must not be attributed as consumed");
        assertEq(
            plan.otherLockedMarginConsumedUsdc, 0, "Partial-close view must keep queued committed margin unreachable"
        );
        assertEq(
            mutation.settlementDebitUsdc, 10e6, "Applied settlement debit should stop at reachable free settlement"
        );
        assertEq(
            mutation.otherLockedMarginUnlockedUsdc,
            0,
            "Queued committed margin must remain locked in partial-close planning"
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
        order;
        staleEffectiveAssets = 0;
        syncedEffectiveAssets = 0;
        staleSideMargin = 0;
        syncedSideMargin = 0;
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
        _bootstrapSeededLifecycle();
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

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertGt(committedBefore, 0, "Should have committed margin from pending open order");

        uint256 freeSettlement = _freeSettlementUsdc(accountId);
        assertLt(freeSettlement, 1100e6, "Free settlement should be small after committing margin");

        _close(accountId, CfdTypes.Side.BULL, 50_000e18, 1.05e8);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 50_000e18, "Partial close should leave half the position");
    }

    function test_H1_PartialCloseLossMustNotConsumeQueuedCommittedMargin() public {
        bytes32 accountId = bytes32(uint256(uint160(trader)));
        bytes32 counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 10_000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 4000e6, type(uint256).max, false);

        uint256 committedBefore = _remainingCommittedMargin(1);
        assertEq(committedBefore, 4000e6, "Committed margin should match order margin delta");

        CfdEngine.ClosePreview memory preview = engineLens.previewClose(accountId, 50_000e18, 1.08e8);

        assertFalse(preview.valid, "Preview should reject a partial close that would need queued committed margin");
        assertEq(
            uint8(preview.invalidReason),
            uint8(CfdTypes.CloseInvalidReason.PartialCloseUnderwater),
            "Preview should use the underwater partial-close invalid reason"
        );
    }

    function test_H1_PartialClosePlannerViewKeepsQueuedCommittedMarginUnreachable() public {
        IMarginClearinghouse.AccountUsdcBuckets memory buckets =
            MarginClearinghouseAccountingLib.buildPartialCloseUsdcBuckets(900e6, 100e6, 4000e6, 0);

        assertEq(
            buckets.settlementBalanceUsdc,
            0,
            "Planner partial-close view should exclude queued committed margin from settlement"
        );
        assertEq(buckets.freeSettlementUsdc, 0, "Excluded queued committed margin must not reappear as free settlement");
        assertEq(buckets.otherLockedMarginUsdc, 0, "Partial-close view should treat other locked margin as unreachable");
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
            _freeSettlementUsdc(accountId), 0, "Trader should be fully utilized before commit"
        );
    }

    function _setupCloseBountyBacked() internal returns (bytes32 accountId, bytes32 counterId) {
        accountId = bytes32(uint256(uint160(trader)));
        counterId = bytes32(uint256(uint160(counterparty)));

        _fundTrader(trader, 5001e6);
        _fundTrader(counterparty, 50_000e6);
        _open(accountId, CfdTypes.Side.BULL, 100_000e18, 5000e6, 1e8);
        _open(counterId, CfdTypes.Side.BEAR, 100_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(accountId), 1e6, "Close bounty should be prefunded");
    }

    function test_H2_FullyUtilizedTraderCanSubmitCloseOrderAgainstPositionMargin() public {
        (bytes32 accountId,) = _setupFullyUtilized();

        (, uint256 marginBefore,,,,,,) = engine.positions(accountId);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,,) = engine.positions(accountId);
        assertEq(_executionBountyReserve(1), 1e6, "Close order should still escrow the keeper bounty");
        assertEq(marginAfter, marginBefore - 1e6, "Fully utilized close should source bounty from position margin");
    }

    function test_H2_HeadCloseOrderMustBeEconomicallyBackedAtCommit() public {
        (bytes32 accountId,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint64 headOrderId = router.nextExecuteId();
        uint256 reservedBounty = _executionBountyReserve(headOrderId);
        uint256 freeSettlement = _freeSettlementUsdc(accountId);

        assertGe(
            reservedBounty + freeSettlement,
            router.quoteCloseOrderExecutionBountyUsdc(),
            "Head close order should be economically backed the moment it enters FIFO"
        );
        assertEq(
            _orderRecord(headOrderId).executionBountyUsdc,
            router.quoteCloseOrderExecutionBountyUsdc(),
            "Close orders should escrow the full bounty in router custody"
        );
    }

    function test_H2_SlippageFailedHeadCloseMustSkipWithoutPayingKeeper() public {
        _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 90_000_000, true);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1e8));

        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(keeperBounty, 0, "Terminal slippage miss should not pay the keeper bounty");
        assertEq(router.nextExecuteId(), 0, "Single queued slippage miss should clear the current head");
        assertEq(_executionBountyReserve(1), 0, "Escrowed close bounty should be refunded on terminal slippage");
    }

    function test_H2_ExpiredHeadCloseMustStillPayKeeper() public {
        (bytes32 accountId,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

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
        assertEq(keeperBounty, 1e6, "Expired head close should still pay the keeper bounty");

        assertEq(
            _freeSettlementUsdc(accountId),
            0,
            "Escrowed close bounty should be consumed from prefunded free settlement"
        );
    }

    function test_H2_LiquidationWithQueuedCloseOrderTransfersOnlyEscrowedBounty() public {
        (bytes32 accountId,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.BULL, 100_000e18, 0, 0, true);

        uint256 routerBalanceBefore = usdc.balanceOf(address(router));

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.96e8));

        vm.prank(KEEPER);
        router.executeLiquidation(accountId, priceData);

        (uint256 sizeAfter,,,,,,,) = engine.positions(accountId);
        assertEq(sizeAfter, 0, "Position should be liquidated");

        assertEq(
            usdc.balanceOf(address(router)),
            routerBalanceBefore - 1e6,
            "Router should transfer exactly the escrowed close bounty on liquidation"
        );

        OrderRouter.OrderRecord memory record = _orderRecord(1);
        assertEq(record.executionBountyUsdc, 0, "Deferred bounty should be cleared on liquidation");
    }

    function test_H2_OpenOrderStillRevertsWhenFullyUtilized() public {
        _setupFullyUtilized();

        vm.prank(trader);
        vm.expectRevert();
        router.commitOrder(CfdTypes.Side.BULL, 1e18, 0, type(uint256).max, false);
    }

}

contract AuditBlockingAccountingFindingsFailing_StaleSeniorYield is BasePerpTest {

    address seniorLp = address(0xA11CE);
    address juniorLp = address(0xB0B);

    function test_L1_FinalizeSeniorRate_StaleMarkMustNotAccrueYield() public {
        address trader = address(0x3333);
        bytes32 traderId = bytes32(uint256(uint160(trader)));

        _fundSenior(seniorLp, 200_000e6);
        _fundJunior(juniorLp, 200_000e6);
        _fundTrader(trader, 50_000e6);
        _open(traderId, CfdTypes.Side.BULL, 100_000e18, 10_000e6, 1e8);

        uint256 unpaidBefore = pool.unpaidSeniorYield();

        pool.proposeSeniorRate(1600);
        vm.warp(block.timestamp + 48 hours + 121);
        pool.finalizeSeniorRate();

        assertEq(pool.unpaidSeniorYield(), unpaidBefore, "Stale-mark finalization should not accrue senior yield");
    }

}

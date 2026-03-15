// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../src/perps/CfdEngine.sol";
import {CfdMath} from "../../src/perps/CfdMath.sol";
import {CfdTypes} from "../../src/perps/CfdTypes.sol";
import {HousePool} from "../../src/perps/HousePool.sol";
import {MarginClearinghouse} from "../../src/perps/MarginClearinghouse.sol";
import {OrderRouter} from "../../src/perps/OrderRouter.sol";
import {TrancheVault} from "../../src/perps/TrancheVault.sol";
import {IMarginClearinghouse} from "../../src/perps/interfaces/IMarginClearinghouse.sol";
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
            MarginClearinghouseAccountingLib.buildAccountUsdcBuckets(60e6, 50e6, 20e6);

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
            mutation.resultingLockedMarginUsdc,
            20e6,
            "Applied locked margin should equal surviving protected residual margin"
        );
    }

    function test_H1_PhaseBoundary_PartialCloseThenCancelMustNotUnlockProtectedResidualMargin() public {
        bytes32 accountId = bytes32(uint256(uint160(alice)));
        _fundTrader(alice, 60e6);

        vm.prank(address(engine));
        clearinghouse.lockMargin(accountId, 20e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.BULL, 10_000e18, 30e6, 1e8, false);

        vm.prank(address(engine));
        router.noteCommittedMarginConsumed(accountId, 30e6);

        vm.prank(alice);
        vm.expectRevert(OrderRouter.OrderRouter__OpenOrdersAreBinding.selector);
        router.cancelOrder(1);

        assertGe(
            clearinghouse.lockedMarginUsdc(accountId),
            20e6,
            "Canceling queued collateral after a partial close must not unlock below the surviving protected position margin"
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

        _settleFunding(order, pos);

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
            totalDeferredLiquidationBountyUsdc
        )
        .effectiveAssetsUsdc;
        syncedEffectiveAssets =
        SolvencyAccountingLib.buildSolvencyState(
            vault.totalAssets(),
            accumulatedFeesUsdc,
            _maxLiability(),
            syncedFunding.solvencyFunding,
            totalDeferredPayoutUsdc,
            totalDeferredLiquidationBountyUsdc
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {MockSettlementToken} from "../../../utils/MockSettlementToken.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";
import {IPositionProtectionActions} from "@plether/perps/interfaces/IPositionProtectionActions.sol";
import {IPositionProtectionViews} from "@plether/perps/interfaces/IPositionProtectionViews.sol";
import {PositionProtectionTypes} from "@plether/perps/interfaces/PositionProtectionTypes.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Cross-feature stateful handler combining queued opens surviving liquidation (#151), protected margin
///         top-ups (#155), pending-open LP reserve protection (#157), armed/triggered PositionProtection,
///         async LP epoch settlement, and HousePool recapitalization/unassigned-reserve invariants (#139/#144/#160/#166).
contract PerpIntegratedLifecycleHandler is Test {

    uint256 internal constant INITIAL_MARK = 1e8;
    uint256 internal constant TRADER_CAPITAL = 250_000e6;
    uint256 internal constant LP_CAPITAL = 200_000e6;
    address internal constant KEEPER = address(0xBEEF01);
    address internal constant LP_SENIOR = address(0x10101);
    address internal constant LP_JUNIOR = address(0x10102);

    CfdEngine internal immutable engine;
    MarginClearinghouse internal immutable clearinghouse;
    HousePool internal immutable pool;
    TrancheVault internal immutable seniorVault;
    TrancheVault internal immutable juniorVault;
    LegacyOrderRouterHarness internal immutable router;
    TerminalNavBookV2 internal immutable terminalNavBook;
    MockSettlementToken internal immutable settlementToken;
    MockPyth internal immutable mockPyth;
    address internal immutable poolOwner;
    bytes32[] internal feedIds;

    uint256 public currentMark = INITIAL_MARK;
    uint256 public totalMintedToClearinghouse;
    uint256 public queuedOpens;
    uint256 public executedOrders;
    uint256 public topUpsWhileQueued;
    uint256 public protectionsArmed;
    uint256 public protectionsTriggered;
    uint256 public batchLiquidations;
    uint256 public retainedOpensSurvivedLiquidation;
    uint256 public lpEpochsSettled;
    uint256 public recapitalizations;

    constructor(
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        HousePool pool_,
        TrancheVault seniorVault_,
        TrancheVault juniorVault_,
        LegacyOrderRouterHarness router_,
        TerminalNavBookV2 terminalNavBook_,
        MockSettlementToken settlementToken_,
        MockPyth mockPyth_,
        address poolOwner_,
        bytes32[] memory feedIds_
    ) {
        engine = engine_;
        clearinghouse = clearinghouse_;
        pool = pool_;
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        router = router_;
        terminalNavBook = terminalNavBook_;
        settlementToken = settlementToken_;
        mockPyth = mockPyth_;
        poolOwner = poolOwner_;
        feedIds = feedIds_;

        for (uint256 i; i < 3; ++i) {
            address trader = traderAt(i);
            settlementToken.mint(trader, TRADER_CAPITAL);
            vm.startPrank(trader);
            settlementToken.approve(address(clearinghouse), TRADER_CAPITAL);
            clearinghouse.deposit(trader, TRADER_CAPITAL);
            vm.stopPrank();
            totalMintedToClearinghouse += TRADER_CAPITAL;
        }
        settlementToken.mint(LP_SENIOR, LP_CAPITAL);
        settlementToken.mint(LP_JUNIOR, LP_CAPITAL);
    }

    function traderAt(
        uint256 index
    ) public pure returns (address) {
        return address(uint160(0xA700 + (index % 3)));
    }

    function commitOpen(
        uint256 actorSeed,
        bool isShort,
        uint256 lotsSeed,
        uint256 marginMultiplierSeed
    ) external {
        address trader = traderAt(actorSeed);
        uint256 lots = bound(lotsSeed, 50, 400);
        uint256 size = lots * CfdTypes.SIZE_QUANTUM;
        uint256 notional = lots * currentMark;
        uint256 marginBps = bound(marginMultiplierSeed, 400, 2000);
        uint256 margin = (notional * marginBps) / 10_000;
        CfdTypes.Side side = isShort ? CfdTypes.Side.SHORT : CfdTypes.Side.LONG;
        uint256 targetPrice = isShort ? engine.CAP_PRICE() : 1;

        vm.prank(trader);
        try router.commitOrder(side, size, margin, targetPrice, false) returns (uint64) {
            ++queuedOpens;
        } catch {}
    }

    function commitClose(
        uint256 actorSeed,
        bool partialClose
    ) external {
        address trader = traderAt(actorSeed);
        (uint256 liveSize,,,, CfdTypes.Side side,,) = engine.positions(trader);
        if (liveSize == 0) {
            return;
        }
        uint256 closeSize = partialClose && liveSize >= 2 * CfdTypes.SIZE_QUANTUM ? liveSize / 2 : liveSize;
        closeSize = (closeSize / CfdTypes.SIZE_QUANTUM) * CfdTypes.SIZE_QUANTUM;
        if (closeSize == 0) {
            return;
        }
        uint256 targetPrice = side == CfdTypes.Side.LONG ? engine.CAP_PRICE() : 1;

        vm.prank(trader);
        try router.commitOrder(side, closeSize, 0, targetPrice, true) {} catch {}
    }

    function topUpMargin(
        uint256 actorSeed,
        uint256 amountSeed
    ) external {
        address trader = traderAt(actorSeed);
        (uint256 liveSize,,,,,,) = engine.positions(trader);
        if (liveSize == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 50e6, 2000e6);
        bool hadPending = router.pendingOrderCounts(trader) > 0;
        vm.prank(trader);
        try engine.addMargin(trader, amount) {
            if (hadPending) {
                ++topUpsWhileQueued;
            }
        } catch {}
    }

    function armOrTriggerProtection(
        uint256 actorSeed,
        bool triggerExisting
    ) external {
        address trader = traderAt(actorSeed);
        IPositionProtectionActions actions = IPositionProtectionActions(address(router.positionProtectionBook()));
        IPositionProtectionViews views = IPositionProtectionViews(address(router.positionProtectionBook()));
        uint64 activeId = views.activePositionProtectionId(trader);

        if (activeId != 0 && triggerExisting) {
            PositionProtectionTypes.PositionProtectionView memory viewData = views.getPositionProtection(activeId);
            if (viewData.status == PositionProtectionTypes.PositionProtectionStatus.Armed) {
                uint256 triggerPrice = viewData.stopLossTriggerPrice;
                bytes[] memory data = _pythUpdate(triggerPrice);
                vm.prank(KEEPER);
                try actions.triggerPositionProtection(activeId, data) {
                    currentMark = triggerPrice;
                    ++protectionsTriggered;
                } catch {}
            }
            return;
        }

        if (activeId != 0) {
            return;
        }
        (uint256 liveSize,,,, CfdTypes.Side side,,) = engine.positions(trader);
        if (liveSize == 0 || router.pendingOrderCounts(trader) > 0) {
            return;
        }

        PositionProtectionTypes.PositionProtectionParams memory params;
        if (side == CfdTypes.Side.LONG) {
            params.stopLossTriggerPrice = currentMark + 5_000_000;
            if (params.stopLossTriggerPrice >= engine.CAP_PRICE()) {
                return;
            }
        } else {
            if (currentMark <= 10_000_000) {
                return;
            }
            params.stopLossTriggerPrice = currentMark - 5_000_000;
        }
        params.closeLimits = PositionProtectionTypes.CloseFinancialLimits({
            maxExecutionNotionalAssets: type(uint256).max,
            maxGrossAccountDebitAssets: type(uint256).max,
            maxActionChargeAssets: type(uint256).max,
            maxExplicitFeesAssets: type(uint256).max
        });
        bytes[] memory refreshData = _pythUpdate(currentMark);
        try router.updateMarkPrice(refreshData) {} catch {}
        vm.prank(trader);
        try actions.createPositionProtection(params) returns (uint64) {
            ++protectionsArmed;
        } catch {}
    }

    function executeNextOrder(
        uint256 priceShiftSeed
    ) external {
        uint64 head = router.nextExecuteId();
        if (head == 0) {
            return;
        }
        uint256 nextPrice = _boundedPrice(priceShiftSeed);
        bytes[] memory data = _pythUpdate(nextPrice);
        vm.prank(KEEPER);
        try router.executeOrder(head, data) {
            currentMark = nextPrice;
            ++executedOrders;
        } catch {}
    }

    function moveMarkAndLiquidateBatch(
        uint256 priceSeed
    ) external {
        uint256 nextPrice = _boundedPrice(priceSeed);
        address[] memory accounts = new address[](3);
        uint256[3] memory pendingOpensBefore;
        uint256[3] memory sizesBefore;
        for (uint256 i; i < 3; ++i) {
            accounts[i] = traderAt(i);
            (sizesBefore[i],,,,,,) = engine.positions(accounts[i]);
            uint256 pending = router.pendingOrderCounts(accounts[i]);
            if (pending > 0 && router.pendingCloseSize(accounts[i]) == 0) {
                pendingOpensBefore[i] = pending;
            }
        }
        bytes[] memory data = _pythUpdate(nextPrice);
        vm.prank(KEEPER);
        try IPerpsKeeper(address(router)).executeLiquidationBatch(accounts, data) returns (uint256) {
            currentMark = nextPrice;
            ++batchLiquidations;
            for (uint256 i; i < 3; ++i) {
                (uint256 sizeAfter,,,,,,) = engine.positions(accounts[i]);
                if (sizesBefore[i] > 0 && sizeAfter == 0 && pendingOpensBefore[i] > 0) {
                    if (router.pendingOrderCounts(accounts[i]) >= pendingOpensBefore[i]) {
                        ++retainedOpensSurvivedLiquidation;
                    }
                }
            }
        } catch {}
    }

    function lpCycleAndSettleEpoch(
        bool isSenior,
        bool isRedeem,
        uint256 amountSeed
    ) external {
        TrancheVault vault = isSenior ? seniorVault : juniorVault;
        address lp = isSenior ? LP_SENIOR : LP_JUNIOR;
        if (!isRedeem) {
            uint256 wallet = settlementToken.balanceOf(lp);
            if (wallet >= 1000e6) {
                uint256 amt = bound(amountSeed, 1000e6, wallet > 25_000e6 ? 25_000e6 : wallet);
                vm.startPrank(lp);
                settlementToken.approve(address(vault), amt);
                try vault.requestDeposit(amt, lp, lp) {} catch {}
                vm.stopPrank();
            }
        } else {
            uint256 shares = vault.balanceOf(lp);
            if (shares > 0 && block.timestamp >= vault.lastDepositTime(lp) + vault.DEPOSIT_COOLDOWN()) {
                uint256 redeemShares = bound(amountSeed, 1, shares);
                vm.prank(lp);
                try vault.requestRedeem(redeemShares, lp, lp) {} catch {}
            }
        }

        vm.warp(block.timestamp + pool.LP_EPOCH_DURATION());
        bytes[] memory data = _pythUpdate(currentMark);
        vm.prank(KEEPER);
        try IPerpsKeeper(address(router)).settleLpEpoch(data) {
            ++lpEpochsSettled;
        } catch {}
    }

    function recapAndAssign(
        uint256 amountSeed,
        bool toSenior
    ) external {
        uint256 amount = bound(amountSeed, 500e6, 5000e6);
        settlementToken.mint(poolOwner, amount);
        vm.startPrank(poolOwner);
        settlementToken.approve(address(engine), amount);
        try engine.recapitalizePool(amount) {
            ++recapitalizations;
        } catch {}
        try pool.assignUnassignedAssets(toSenior, poolOwner) {} catch {}
        vm.stopPrank();
    }

    function assertInvariants() external view {
        // 1. Clearinghouse custody conservation across all traders, keeper, and treasury.
        uint256 accountedCustody =
            clearinghouse.balanceAssets(KEEPER) + clearinghouse.balanceAssets(engine.protocolTreasury());
        uint256 sumPositiveVpi;
        uint256 sumNegativeVpi;
        IPositionProtectionViews protectionViews = IPositionProtectionViews(address(router.positionProtectionBook()));

        for (uint256 i; i < 3; ++i) {
            address trader = traderAt(i);
            accountedCustody += clearinghouse.balanceAssets(trader);

            (uint256 size,,,,,, int256 vpiAccrued) = engine.positions(trader);
            if (size > 0) {
                if (vpiAccrued > 0) {
                    sumPositiveVpi += uint256(vpiAccrued);
                } else if (vpiAccrued < 0) {
                    sumNegativeVpi += uint256(-vpiAccrued);
                }
            }

            // Clearinghouse bucket conservation & protected top-up invariants (#155).
            uint256 pledge = clearinghouse.pnlPledgeAssets(trader);
            uint256 liqReserve = clearinghouse.liquidationReserveAssets(trader);
            uint256 vpiReserve = clearinghouse.vpiRebateReserveAssets(trader);
            uint256 actionReserve = clearinghouse.actionReserveAssets(trader);
            uint256 committedMargin = router.getAccountReservations(trader).committedMarginAssets;
            (uint256 protectedPledged, uint256 protectedReleased) = clearinghouse.protectedTopUps(trader);
            assertGe(actionReserve, vpiReserve, "action reserve must back VPI rebate reserve");
            assertEq(
                clearinghouse.lockedMarginAssets(trader),
                pledge + liqReserve + actionReserve + committedMargin + protectedReleased,
                "clearinghouse locked buckets must partition total locked margin"
            );

            assertLe(protectedPledged, pledge, "protected top-up pledge cannot exceed active pledge");
            if (router.pendingOrderCounts(trader) == 0) {
                assertEq(protectedPledged, 0, "drained queue must clear protected top-up pledge");
                assertEq(protectedReleased, 0, "drained queue must clear protected top-up released balance");
                assertEq(committedMargin, 0, "drained queue must hold zero committed order margin");
            }

            // PositionProtection consistency.
            uint64 activeId = protectionViews.activePositionProtectionId(trader);
            if (activeId != 0 && size == 0) {
                assertNotEq(
                    uint8(protectionViews.getPositionProtection(activeId).status),
                    uint8(PositionProtectionTypes.PositionProtectionStatus.Armed),
                    "flat account cannot retain an armed protection"
                );
            }
        }

        // Exact clearinghouse physical balance equals sum of all user/keeper/treasury accounts.
        assertEq(
            settlementToken.balanceOf(address(clearinghouse)),
            accountedCustody,
            "clearinghouse physical cash must match sum of account ledgers"
        );
        // Gross VPI aggregates match exact per-position sums (#140).
        assertEq(engine.totalPositiveVpiAccruedAssets(), sumPositiveVpi, "positive VPI aggregate mismatch");
        assertEq(engine.totalNegativeVpiAccruedAssets(), sumNegativeVpi, "negative VPI aggregate mismatch");

        // HousePool solvency & reserve invariants (#139/#144/#160/#166).
        assertGe(pool.rawAssets(), pool.accountedAssets(), "pool raw cash must cover canonical accounted assets");
        assertLe(pool.getFreeAssets(), pool.totalAssets(), "pool free assets cannot exceed total assets");
        assertLe(pool.getMaxSeniorWithdraw(), pool.seniorPrincipal(), "senior withdraw cap bounded by senior principal");
        assertLe(pool.getMaxJuniorWithdraw(), pool.juniorPrincipal(), "junior withdraw cap bounded by junior principal");
    }

    function _boundedPrice(
        uint256 seed
    ) private pure returns (uint256) {
        return bound(seed, 55_000_000, 145_000_000);
    }

    function _pythUpdate(
        uint256 price
    ) private returns (bytes[] memory data) {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        MockPyth.FeedUpdate[] memory ticks = new MockPyth.FeedUpdate[](feedIds.length);
        for (uint256 i; i < feedIds.length; ++i) {
            ticks[i] =
                MockPyth.FeedUpdate(feedIds[i], MockPyth.MockPrice(int64(uint64(price)), 0, -8, block.timestamp, 0));
        }
        data = new bytes[](1);
        data[0] = abi.encode(ticks);
    }

}

/// @notice Stateful cross-feature invariant campaign combining retained opens (#151), protected top-ups (#155),
///         pending-open LP reserves (#157), PositionProtection batch liquidations, and HousePool waterfall/recap.
contract PerpIntegratedLifecycleInvariantTest is BasePerpTest {

    PerpIntegratedLifecycleHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.vpiFactor = 0.005e18;
        params.baseCarryBps = 200;
    }

    function setUp() public override {
        super.setUp();
        _setSeniorCapacity(40_000_000e6, 8000);
        bytes32[] memory ids = _basePythFeedIds();
        handler = new PerpIntegratedLifecycleHandler(
            engine,
            clearinghouse,
            pool,
            seniorVault,
            juniorVault,
            router,
            terminalNavBook,
            settlementToken,
            baseMockPyth,
            address(this),
            ids
        );
        // Seed initial accepted oracle basket & one open position so every action can execute from step 1.
        router.updateMarkPrice(_mockPythUpdateData(1e8));
        handler.commitOpen(0, false, 100, 1000);
        handler.executeNextOrder(100_000_000);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.commitOpen.selector;
        selectors[1] = handler.commitClose.selector;
        selectors[2] = handler.topUpMargin.selector;
        selectors[3] = handler.armOrTriggerProtection.selector;
        selectors[4] = handler.executeNextOrder.selector;
        selectors[5] = handler.moveMarkAndLiquidateBatch.selector;
        selectors[6] = handler.lpCycleAndSettleEpoch.selector;
        selectors[7] = handler.recapAndAssign.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: quick.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    /// forge-config: audit.invariant.fail-on-revert = true
    function invariant_IntegratedLifecycleConservationAndSafety() public view {
        handler.assertInvariants();
    }

    function test_IntegratedLifecycleReachesRetainedOpenTopUpProtectionAndLpSettlement() public {
        // 1. Trader 0 has live LONG -> arm protection, then queue another trader's open + top-up while queued.
        handler.armOrTriggerProtection(0, false);
        assertGt(handler.protectionsArmed(), 0);

        // Trader 1 opens a thin LONG, queues a funded increase, and adds a protected top-up while queued.
        handler.commitOpen(1, false, 100, 400);
        handler.executeNextOrder(100_000_000);
        handler.commitOpen(1, false, 100, 600);
        handler.topUpMargin(1, 500e6);
        assertGt(handler.topUpsWhileQueued(), 0);

        // 2. LP settles an epoch while pending opens exist (#157 pending-open reserve protection).
        handler.lpCycleAndSettleEpoch(false, false, 10_000e6);
        assertGt(handler.lpEpochsSettled(), 0);

        // 3. Sharp adverse price move liquidates Trader 0 (with armed protection) and Trader 1 (whose queued open survives #151).
        handler.moveMarkAndLiquidateBatch(145_000_000);
        assertGt(handler.batchLiquidations(), 0);
        assertGt(handler.retainedOpensSurvivedLiquidation(), 0, "queued open must survive liquidation");

        // 4. Recapitalize & assign unassigned assets (#139/#144/#160/#166).
        handler.recapAndAssign(2000e6, false);
        assertGt(handler.recapitalizations(), 0);

        // 5. Drain remaining queued orders and verify every invariant holds.
        handler.executeNextOrder(100_000_000);
        handler.assertInvariants();
    }

}

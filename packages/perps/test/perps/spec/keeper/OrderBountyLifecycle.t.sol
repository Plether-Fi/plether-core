// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

// Category: spec. All cases assert current documented behavior and are expected to pass.
// Source of truth: packages/perps/ACCOUNTING_SPEC.md#pending-order-reservation-model

import {OrderRouterDebugLens} from "../../../utils/OrderRouterDebugLens.sol";
import {BasePerpTest} from "../../BasePerpTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CfdEngineLens} from "@plether/perps/CfdEngineLens.sol";
import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {HousePool} from "@plether/perps/HousePool.sol";
import {HousePoolRedemptionMathSidecar} from "@plether/perps/HousePoolRedemptionMathSidecar.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {TerminalNavBookV2} from "@plether/perps/TerminalNavBookV2.sol";
import {TrancheVault} from "@plether/perps/TrancheVault.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {IOrderRouterAdminHost} from "@plether/perps/interfaces/IOrderRouterAdminHost.sol";
import {IOrderRouterErrors} from "@plether/perps/interfaces/IOrderRouterErrors.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {MockUSDC} from "@plether/test-utils/MockUSDC.sol";

contract ConsumedCommitmentReleaseTest is BasePerpTest {

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExecutionReleaseMustNotUnlockConsumedCommittedMargin() public {
        address aliceAccount = alice;

        _fundTrader(alice, 50_000e6);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 350_000e18, 35_000e6, 1e8, false);

        // Exhaust free settlement so the live action charge reaches exactly the intended order margin.
        uint256 freeSettlement = clearinghouse.getFreeBuyingPowerUsdc(aliceAccount);
        vm.prank(aliceAccount);
        clearinghouse.withdraw(aliceAccount, freeSettlement);
        vm.prank(address(engine));
        clearinghouse.consumeActionCharge(aliceAccount, 35_000e6, 0, 35_000e6, address(engine), address(0), 0);

        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), 700_000e6);

        assertEq(
            _remainingCommittedMargin(1), 0, "Consumed committed margin should be charged to the queued order itself"
        );

        uint256 keeperBalanceBefore = clearinghouse.balanceUsdc(address(this));

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        vm.prank(address(this));
        router.executeOrder(1, empty);

        assertEq(_remainingCommittedMargin(1), 0, "Consumed committed margin must remain consumed");
        assertEq(
            clearinghouse.lockedMarginUsdc(aliceAccount),
            0,
            "Only the reserved execution bounty should be released on the failed execution"
        );
        assertEq(
            clearinghouse.balanceUsdc(address(this)) - keeperBalanceBefore,
            200_000,
            "Failed execution should pay the reserved bounty to the clearer"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExpiredOpenClearsQueueAndCreditsReservedBounty() public {
        _fundTrader(alice, 10_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 keeperBefore = clearinghouse.balanceUsdc(address(this));
        uint256 traderBefore = clearinghouse.balanceUsdc(alice);
        uint256 walletBefore = usdc.balanceOf(address(this));
        vm.warp(block.timestamp + router.maxExecutionWindowSeconds() + 1);
        bytes[] memory empty = _mockPythUpdateData();
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, empty);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        assertEq(router.nextExecuteId(), 0, "Expired head must leave the queue");
        assertEq(clearinghouse.balanceUsdc(address(this)) - keeperBefore, pending.executionBountyUsdc);
        assertEq(traderBefore - clearinghouse.balanceUsdc(alice), pending.executionBountyUsdc);
        assertEq(clearinghouse.lockedMarginUsdc(alice), 0, "Terminal cleanup releases all order reservations");
        assertEq(usdc.balanceOf(address(this)), walletBefore, "Bounty custody remains in the clearinghouse");
    }

}

contract PositionFundedCloseBountyTest is BasePerpTest {

    address trader = address(0xC200);
    address counterparty = address(0xBEA3);
    address constant KEEPER = address(0xC0FFEE);

    function _setupFullyUtilized() internal returns (address account, address counterAccount) {
        account = trader;
        counterAccount = counterparty;

        _fundTrader(trader, 5000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        assertEq(_freeSettlementUsdc(account), 0, "Trader should be fully utilized before commit");
    }

    function _setupCloseBountyBacked() internal returns (address account, address counterAccount) {
        account = trader;
        counterAccount = counterparty;

        _fundTrader(trader, 5001e6);
        _fundTrader(counterparty, 50_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterAccount, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        assertEq(
            _freeSettlementUsdc(account), 1e6, "Setup should leave one USDC of free settlement before close reservation"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FullyUtilizedTraderCanFundCloseOrderFromPositionMargin() public {
        (address account,) = _setupFullyUtilized();

        (, uint256 marginBefore,,,,,) = engine.positions(account);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        (, uint256 marginAfter,,,,,) = engine.positions(account);
        assertEq(marginAfter, marginBefore - router.closeOrderExecutionBountyUsdc(), "bounty reclassification is exact");
        assertEq(router.pendingOrderCounts(account), 1, "accepted close enters FIFO");
        assertEq(router.nextCommitId(), 2, "accepted close consumes one ID");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_HeadCloseOrderMustBeEconomicallyBackedAtCommit() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        uint64 headOrderId = router.nextExecuteId();
        uint256 reservedBounty = _executionBountyReserve(headOrderId);
        uint256 freeSettlement = _freeSettlementUsdc(account);

        assertGe(
            reservedBounty + freeSettlement,
            200_000,
            "Head close order should be economically backed the moment it enters FIFO"
        );
        assertEq(
            _orderRecord(headOrderId).executionBountyUsdc,
            200_000,
            "Close orders should reserve the full bounty in clearinghouse custody"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_SlippageFailedHeadCloseCreditsKeeperInClearinghouseOnly() public {
        _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 90_000_000, true);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);

        bytes[] memory priceData = _mockPythUpdateData();
        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(keeperBounty, 0, "Terminal slippage miss should not pay the keeper wallet");
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            200_000,
            "Terminal slippage miss should credit the clearer in clearinghouse custody"
        );
        assertEq(router.nextExecuteId(), 0, "Single queued slippage miss should clear the current head");
        assertEq(_executionBountyReserve(1), 0, "Reserved close bounty should be consumed on terminal slippage");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExpiredHeadCloseMustStillPayKeeper() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        IOrderRouterAdminHost.RouterConfig memory config = IOrderRouterAdminHost.RouterConfig({
            maxExecutionWindowSeconds: 60,
            orderExecutionStalenessLimit: router.pletherOracle().orderExecutionStalenessLimit(),
            liquidationStalenessLimit: router.pletherOracle().liquidationStalenessLimit(),
            basketMaxConfidenceRatioBps: router.pletherOracle().basketMaxConfidenceRatioBps(),
            orderSettlementWindow: router.pletherOracle().orderSettlementWindow(),
            maxComponentPublishTimeDivergence: router.pletherOracle().maxComponentPublishTimeDivergence(),
            adverseConfidenceMultiplierBps: router.pletherOracle().adverseConfidenceMultiplierBps(),
            minOpenNotionalUsdc: router.minOpenNotionalUsdc(),
            openOrderExecutionBountyBps: router.openOrderExecutionBountyBps(),
            minOpenOrderExecutionBountyUsdc: router.minOpenOrderExecutionBountyUsdc(),
            maxOpenOrderExecutionBountyUsdc: router.maxOpenOrderExecutionBountyUsdc(),
            closeOrderExecutionBountyUsdc: router.closeOrderExecutionBountyUsdc(),
            positionProtectionTriggerBountyUsdc: router.positionProtectionTriggerBountyUsdc(),
            maxPendingOrders: router.maxPendingOrders(),
            minEngineGas: router.minEngineGas(),
            maxPruneOrdersPerCall: router.maxPruneOrdersPerCall()
        });
        routerAdmin.proposeRouterConfig(config);
        vm.warp(block.timestamp + 48 hours + 1);
        routerAdmin.finalizeRouterConfig();

        vm.warp(block.timestamp + 61);

        uint256 keeperBalanceBefore = usdc.balanceOf(KEEPER);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        bytes[] memory priceData = _mockPythUpdateData();

        vm.prank(KEEPER);
        router.executeOrder(1, priceData);

        uint256 keeperBounty = usdc.balanceOf(KEEPER) - keeperBalanceBefore;
        assertEq(
            keeperBounty, 0, "Expired head close should credit the clearer in clearinghouse custody, not the wallet"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            200_000,
            "Expired head close should still pay the configured bounty to the clearer"
        );

        assertEq(
            _freeSettlementUsdc(account),
            800_000,
            "Only the committed close bounty slice should leave prefunded free settlement"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_LiquidationWithQueuedCloseOrderTransfersOnlyReservedBounty() public {
        (address account,) = _setupCloseBountyBacked();

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        ICfdEngineTypes.LiquidationPreview memory preview = engineLens.previewLiquidation(account, 1.96e8);
        assertTrue(preview.liquidatable, "Setup should be liquidatable at the execution price");
        uint256 reservedSettlementBefore = clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc;
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(KEEPER);
        uint256 routerBalanceBefore = usdc.balanceOf(address(router));
        assertEq(reservedSettlementBefore, 200_000, "Queued close bounty should be reserved in clearinghouse custody");
        assertEq(routerBalanceBefore, 0, "Router should not custody queued close bounties");

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(1.96e8));

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(KEEPER);
        router.executeLiquidation(account, priceData);

        (uint256 sizeAfter,,,,,,) = engine.positions(account);
        assertEq(sizeAfter, 0, "Position should be liquidated");

        assertEq(
            usdc.balanceOf(address(router)),
            routerBalanceBefore,
            "Router should remain out of bounty custody on liquidation"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            0,
            "Queued close bounty reservation should be cleared on liquidation"
        );
        assertEq(
            clearinghouse.balanceUsdc(KEEPER) - keeperSettlementBefore,
            preview.keeperBountyUsdc,
            "Keeper should receive only the liquidation bounty as a clearinghouse credit"
        );

        OrderRouterDebugLens.OrderRecord memory record = _orderRecord(1);
        assertEq(record.executionBountyUsdc, 0, "Reserved bounty should be cleared on liquidation");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_SubLotIncreaseRejectedOnFullyUtilizedAccount() public {
        _setupFullyUtilized();

        vm.prank(trader);
        vm.expectRevert(IOrderRouterErrors.OrderRouter__InvalidSizeQuantum.selector);
        router.commitOrder(CfdTypes.Side.LONG, 1e18, 0, type(uint256).max, false);
    }

}

contract ExpiredBatchBountiesTest is BasePerpTest {

    MockPyth mockPyth;
    bytes32 constant FEED_A = bytes32(uint256(1));
    bytes32 constant FEED_B = bytes32(uint256(2));
    bytes32[] feedIds;
    uint256[] weights;
    uint256[] bases;
    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() public override {
        usdc = new MockUSDC();
        mockPyth = new MockPyth();

        clearinghouse = new MarginClearinghouse(address(usdc));
        engine = _deployEngine(_riskParams());
        _syncEngineAdmin();
        terminalNavBook = new TerminalNavBookV2(address(engine), uint32(CAP_PRICE));
        engine.setTerminalNavBook(address(terminalNavBook));
        pool = new HousePool(address(usdc), address(engine), address(new HousePoolRedemptionMathSidecar()));

        seniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), true, "Plether Senior LP", "seniorUSDC", 0, address(0)
        );
        juniorVault = new TrancheVault(
            IERC20(address(usdc)), address(pool), false, "Plether Junior LP", "juniorUSDC", 0, address(0)
        );
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
        _fundJunior(address(this), 1_000_000e6);
        _fundTrader(alice, 50_000e6);
        vm.deal(alice, 1 ether);
        vm.deal(keeper, 1 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExpiredOpenBatchExecutionPaysClearerFromReservedBounty() public {
        uint256 t0 = 2_000_000_000;
        vm.warp(t0);
        vm.roll(100);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);

        vm.warp(t0 + 61);
        vm.roll(200);
        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), t0 + 1, t0);

        uint256 keeperBalanceBefore = _settlementBalance(keeper);
        uint256 aliceBalanceBefore = _settlementBalance(alice);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(1, updateData);

        assertEq(
            _settlementBalance(keeper) - keeperBalanceBefore,
            pending.executionBountyUsdc,
            "Expired open orders should pay the clearer so bad head orders remain economical to prune"
        );
        assertEq(
            aliceBalanceBefore - _settlementBalance(alice),
            pending.executionBountyUsdc,
            "Expired open orders should consume the submitting trader's reserved bounty"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_BatchMixedExpiredAndSuccessPaysReservedBounties() public {
        _fundTrader(alice, 50_000e6);

        uint256 t0 = 2_000_000_000;

        vm.warp(t0);
        vm.roll(100);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 10);
        vm.roll(200);
        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), t0 + 10);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), t0 + 10);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        vm.warp(t0 + 61);
        vm.roll(300);
        mockPyth.setAllUniquePrices(feedIds, int64(100_000_000), 0, int32(-8), t0 + 11, t0);

        (IOrderRouterAccounting.PendingOrderView memory firstPending, uint64 nextAfterFirst) =
            router.getPendingOrderView(1);
        (IOrderRouterAccounting.PendingOrderView memory secondPending,) = router.getPendingOrderView(nextAfterFirst);

        uint256 keeperUsdcBefore = _settlementBalance(keeper);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.prank(keeper);
        router.executeOrderBatch(2, updateData);

        assertEq(
            _settlementBalance(keeper) - keeperUsdcBefore,
            400_000,
            "Batch execution should compensate the clearer from both reserved order bounties"
        );
        assertGt(firstPending.executionBountyUsdc, 0, "Expired open should still have reserved a positive bounty");
        assertGt(
            secondPending.executionBountyUsdc, 0, "Queued successor open should still have reserved a positive bounty"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_StaleExecutionPreservesOrderAndReservedBounty() public {
        vm.warp(1000);

        mockPyth.setPrice(FEED_A, int64(100_000_000), int32(-8), 1000);
        mockPyth.setPrice(FEED_B, int64(100_000_000), int32(-8), 900);

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 500e6, 1e8, false);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 keeperBalanceBefore = clearinghouse.balanceUsdc(keeper);
        uint256 traderBalanceBefore = clearinghouse.balanceUsdc(alice);
        uint256 reservedBefore = clearinghouse.lockedMarginUsdc(alice);

        vm.warp(1001);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectPartialRevert(IPletherOracle.PletherOracle__StalePrice.selector);
        router.executeOrder(1, updateData);

        assertEq(clearinghouse.balanceUsdc(keeper), keeperBalanceBefore);
        assertEq(clearinghouse.balanceUsdc(alice), traderBalanceBefore);
        assertEq(clearinghouse.lockedMarginUsdc(alice), reservedBefore);
        assertEq(router.nextExecuteId(), 1, "Stale execution preserves the queued order");
    }

}

contract RebateAdmissionFailureTest is BasePerpTest {

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

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_RebateOpenPreviewIdentifiesUnfundedVpiReserve() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 200_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 2000e6);

        uint8 code = engineLens.previewOpenRevertCode(
            bobAccount, CfdTypes.Side.SHORT, 300_000e18, 10_000e6, 1e8, uint64(block.timestamp)
        );
        assertEq(
            code,
            uint8(CfdEnginePlanTypes.OpenRevertCode.VPI_REBATE_RESERVE_UNFUNDED),
            "rebate-bearing opens must surface their independent VPI-reserve funding failure"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FailedRebateOpenPaysReservedClearerBounty() public {
        address aliceAccount = alice;
        address bobAccount = bob;

        _fundTrader(alice, 200_000e6);
        _open(aliceAccount, CfdTypes.Side.LONG, 300_000e18, 50_000e6, 1e8);

        _fundTrader(bob, 20_000e6);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        router.commitOrder(CfdTypes.Side.SHORT, 300_000e18, 10_000e6, 1e8, false);

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
            "Terminal planner rejection pays the reserved bounty to the clearer"
        );
        assertEq(
            bobSettlementBefore - clearinghouse.balanceUsdc(bobAccount),
            pending.executionBountyUsdc,
            "user should pay the reserved bounty under current failure policy"
        );
    }

}

contract TerminalSlippageBountyTest is BasePerpTest {

    address spammer = address(0x666);
    address keeper = address(0x777);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000 * 1e6;
    }

    function setUp() public override {
        super.setUp();
        vm.deal(spammer, 10 ether);
        vm.deal(keeper, 10 ether);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_SlippageFailurePaysReservedBountyAsInternalCredit() public {
        _fundTrader(spammer, 10_000e6);
        vm.prank(spammer);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 1000e6, 1.5e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 traderBefore = clearinghouse.balanceUsdc(spammer);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        uint256 keeperEthBefore = keeper.balance;
        uint256 keeperWalletBefore = usdc.balanceOf(keeper);
        bytes[] memory updateData = _mockPythUpdateData();
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, updateData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Slippage));
        assertEq(router.nextExecuteId(), 0);
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, pending.executionBountyUsdc);
        assertEq(traderBefore - clearinghouse.balanceUsdc(spammer), pending.executionBountyUsdc);
        assertEq(clearinghouse.lockedMarginUsdc(spammer), 0);
        assertEq(keeper.balance, keeperEthBefore, "Execution bounty is not native ETH");
        assertEq(usdc.balanceOf(keeper), keeperWalletBefore, "Execution bounty is an internal settlement credit");
    }

}

contract PendingDepositLifecycleBountyTest is BasePerpTest {

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_UnderwaterFullCloseFreeFundedBountyCanCommitAndPaysKeeperOnFailure() public {
        address account = address(0xA11CE);
        address keeper = address(0xB0B);
        uint256 size = 100_000e18;

        _fundTrader(account, 2000e6);
        _open(account, CfdTypes.Side.LONG, size, 2000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(150_000_000, uint64(block.timestamp));

        _fundTrader(account, router.closeOrderExecutionBountyUsdc());
        uint256 accountBalanceBeforeCommit = clearinghouse.balanceUsdc(account);
        uint256 bountyUsdc = router.closeOrderExecutionBountyUsdc();

        vm.prank(account);
        router.commitOrder(CfdTypes.Side.LONG, size, 0, 100_000_000, true);

        bytes[] memory priceData = _mockPythUpdateData(150_000_000);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        assertEq(clearinghouse.balanceUsdc(keeper), bountyUsdc, "failed underwater full close should pay keeper");
        assertApproxEqAbs(
            clearinghouse.balanceUsdc(account),
            accountBalanceBeforeCommit - bountyUsdc,
            1000,
            "failed underwater full close should consume the free-funded bounty"
        );
        assertEq(
            clearinghouse.getLockedMarginBuckets(account).reservedSettlementUsdc,
            0,
            "reserved bounty bucket should be released"
        );
    }

}

contract PledgeFundedBountyIsolationTest is BasePerpTest {

    address trader = address(0xA11CE);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_KeeperReserveUsesPledgeButProtectsLiquidationReserve() public {
        address account = trader;
        _fundTrader(trader, 175e6);
        _open(account, CfdTypes.Side.LONG, 10_000e18, 175e6, 1e8);

        uint256 pledgeBefore = clearinghouse.pnlPledgeUsdc(account);
        uint256 liquidationReserveBefore = clearinghouse.liquidationReserveUsdc(account);
        assertEq(_freeSettlementUsdc(account), 0, "Setup must leave no free settlement for a close bounty");

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 0, 0, true);

        assertEq(
            clearinghouse.pnlPledgeUsdc(account),
            pledgeBefore - router.closeOrderExecutionBountyUsdc(),
            "Only the exact configured bounty leaves pledge"
        );
        assertEq(
            clearinghouse.liquidationReserveUsdc(account),
            liquidationReserveBefore,
            "Funded bounty reservation must preserve the dedicated liquidation reserve"
        );
        assertEq(router.pendingOrderCounts(account), 1, "Funded reservation enqueues a close");
    }

}

contract MinimumOrderBountyTest is BasePerpTest {

    address trader = address(0xD057);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory params) {
        params = super._riskParams();
        params.minBountyUsdc = 100_000;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_DustOrdersMustReserveMinimumKeeperReserve() public {
        _fundTrader(trader, 3e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100e18, 2e6, 0, false);

        address account = trader;
        IOrderRouterAccounting.AccountReservationView memory reservation = router.getAccountReservations(account);
        assertEq(
            reservation.executionBountyUsdc,
            10_000,
            "Dust orders should reserve the configured minimum execution bounty"
        );
    }

}

contract IlliquidPoolCloseBountyTest is BasePerpTest {

    address trader = address(0xC105);
    address keeper = address(0xBEEF);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ProfitableCloseMustNotBeDroppedWhenPoolLacksImmediateCash() public {
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 10_000e6);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "A profitable close should complete even when profit payout becomes a trader claim");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FreeSettlementFundsCommittedCloseBounty() public {
        address account = trader;
        _fundTrader(trader, 2001e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        assertEq(
            router.nextCommitId(), 2, "Close commits should still succeed when the trader prefunds the keeper bounty"
        );
        assertEq(_executionBountyReserve(1), 200_000, "Close commits should reserve the configured flat clearer bounty");
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_CloseKeeperRewardMustCreditFromReservedMarginDespiteVaultCashShortage() public {
        address account = trader;
        address keeperAccount = keeper;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        uint256 poolAssets = pool.totalAssets();
        vm.prank(address(pool));
        usdc.transfer(address(0xDEAD), poolAssets - 1);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(80_000_000));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeperAccount);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeOrder(1, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Close should still succeed even when execution bounty cash is unavailable");
        assertEq(
            clearinghouse.balanceUsdc(keeperAccount) - keeperSettlementBefore,
            200_000,
            "Illiquid close execution should still pay the keeper from clearinghouse-reserved bounty value"
        );
    }

}

contract TerminalActionLivenessTest is BasePerpTest {

    address trader = address(0x7100);
    address spammer = address(0x7101);
    address keeper = address(0x7102);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_LiquidationKeeperRewardMustCreditFromTraderMarginDespiteVaultCashShortage() public {
        address account = trader;
        _fundTrader(trader, 11_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        bytes[] memory priceData = new bytes[](1);
        priceData[0] = abi.encode(uint256(125_000_000));

        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.payOut.selector), bytes("pool illiquid"));

        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        router.executeLiquidation(account, priceData);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Liquidation should still succeed even when bounty cash is unavailable");
        assertGt(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            0,
            "Liquidation bounty should credit keeper settlement instead of reverting"
        );
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_TerminalCloseMustRemainExecutableUnderBoundedForeignQueue() public {
        address account = trader;
        _fundTrader(trader, 20_000e6);
        _fundTrader(spammer, 250_000e6);

        _open(account, CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        uint256 spamCount = 5;
        for (uint256 i = 0; i < spamCount; i++) {
            vm.prank(spammer);
            router.commitOrder(CfdTypes.Side.SHORT, 10_000e18, 1000e6, 2e8, false);
        }

        bytes[] memory empty = _mockPythUpdateData();
        vm.roll(block.number + 1);
        uint64 closeOrderId = router.nextExecuteId();
        router.executeOrder(closeOrderId, empty);

        (uint256 size,,,,,,) = engine.positions(account);
        assertEq(size, 0, "Terminal close should succeed even with the bounded foreign queued orders");
        assertEq(router.nextExecuteId(), closeOrderId + 1, "Queue head should advance after terminal close");
    }

}

contract MarginAndReservationAdmissionBountyTest is BasePerpTest {

    address alice = address(0xA11CE);
    address attacker = address(0xBAD);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_RouterCannotTransferReservedSettlement() public {
        address account = alice;
        _fundTrader(alice, 1000e6);

        vm.prank(address(router));
        clearinghouse.lockReservedSettlement(account, 100e6);

        vm.prank(address(router));
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__NotOperator.selector);
        clearinghouse.transferReservedSettlement(account, attacker, 100e6);
    }

}

contract InternalBountyCustodyTest is BasePerpTest {

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function _initialJuniorDeposit() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_ExpiredOrderCreditsInternalBountyWithoutWalletTransfer() public {
        _fundTrader(alice, 50_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 10_000e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(1);
        uint256 traderBefore = clearinghouse.balanceUsdc(alice);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        uint256 walletBefore = usdc.balanceOf(keeper);
        uint256 nativeBefore = keeper.balance;
        vm.warp(block.timestamp + router.maxExecutionWindowSeconds() + 1);
        bytes[] memory data = _mockPythUpdateData();
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, data);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, pending.executionBountyUsdc);
        assertEq(traderBefore - clearinghouse.balanceUsdc(alice), pending.executionBountyUsdc);
        assertEq(clearinghouse.lockedMarginUsdc(alice), 0);
        assertEq(router.nextExecuteId(), 0);
        assertEq(usdc.balanceOf(keeper), walletBefore);
        assertEq(keeper.balance, nativeBefore);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_SuccessAndExpiryBothCreditInternalBounties() public {
        _fundTrader(alice, 100_000e6);
        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory first,) = router.getPendingOrderView(1);
        uint256 keeperBefore = clearinghouse.balanceUsdc(keeper);
        uint256 walletBefore = usdc.balanceOf(keeper);
        bytes[] memory data = _mockPythUpdateData();
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory success = router.executeOrder(1, data);
        assertEq(uint8(success.status), uint8(OrderV3Types.LifecycleStatus.Executed));
        assertEq(clearinghouse.balanceUsdc(keeper) - keeperBefore, first.executionBountyUsdc);
        (uint256 openedSize,,,,,,) = engine.positions(alice);
        assertEq(openedSize, 50_000e18, "Success control must apply the position");

        vm.prank(alice);
        router.commitOrder(CfdTypes.Side.LONG, 50_000e18, 10_000e6, 1e8, false);
        (IOrderRouterAccounting.PendingOrderView memory second,) = router.getPendingOrderView(2);
        vm.warp(block.timestamp + router.maxExecutionWindowSeconds() + 1);
        data = _mockPythUpdateData();
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory expired = router.executeOrder(2, data);
        assertEq(uint8(expired.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(expired.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperBefore, first.executionBountyUsdc + second.executionBountyUsdc
        );
        assertEq(usdc.balanceOf(keeper), walletBefore, "Both bounties stay in clearinghouse custody");
        (uint256 finalSize,,,,,,) = engine.positions(alice);
        assertEq(finalSize, openedSize, "Expiry must not increase the position");
        assertEq(router.nextExecuteId(), 0);
    }

}

contract ReservedSettlementBehaviorBountyTest is BasePerpTest {

    address trader = address(0x111);
    address traderA = address(0xAAA1);
    address traderB = address(0xBBB1);
    address keeper = address(0x222);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_CommitMustLockMargin() public {
        _fundTrader(trader, 10_000 * 1e6);
        address account = trader;

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000 * 1e18, 5000 * 1e6, 1e8, false);

        vm.prank(trader);
        vm.expectRevert(MarginClearinghouse.MarginClearinghouse__InsufficientFreeEquity.selector);
        clearinghouse.withdraw(account, 9999 * 1e6);
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FailedSingleExecutePaysReservedUsdcBountyWithoutNativeEthTransfer() public {
        vm.deal(trader, 2 ether);
        vm.deal(keeper, 1 ether);

        _fundTrader(trader, 10_000 * 1e6);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 10_000 * 1e18, 200e6, 1.5e8, false);

        uint256 executionBountyUsdc = _executionBountyReserve(1);
        uint256 keeperEthBefore = keeper.balance;
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);
        uint256 traderSettlementBefore = clearinghouse.balanceUsdc(trader);
        bytes[] memory empty = _mockPythUpdateData();
        vm.prank(keeper);
        router.executeOrder(1, empty);

        assertEq(keeper.balance, keeperEthBefore, "Failed execution must not transfer native ETH to the keeper");
        assertEq(trader.balance, 2 ether, "Failed execution must not route a native ETH refund to the trader");
        assertEq(
            clearinghouse.balanceUsdc(keeper) - keeperSettlementBefore,
            executionBountyUsdc,
            "Terminal slippage failure must pay the separately reserved USDC bounty"
        );
        assertEq(
            traderSettlementBefore - clearinghouse.balanceUsdc(trader),
            executionBountyUsdc,
            "Failed order must forfeit only its reserved execution bounty"
        );
        assertEq(router.pendingOrderCounts(trader), 0, "Terminal failure must clear the queued order");
        assertEq(_executionBountyReserve(1), 0, "Terminal failure must clear the bounty attribution");
    }

}

contract SnapshottedCloseBountyTest is BasePerpTest {

    address trader = address(0xA11CE);
    address counterparty = address(0xB0B);
    address keeper = address(0xC0FFEE);

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 1e18,
            maintMarginBps: 100,
            initMarginBps: ((100) * 15) / 10,
            fadMarginBps: 300,
            baseCarryBps: 500,
            minBountyUsdc: 1e6,
            bountyBps: 10,
            keeperShareBps: 5000,
            protocolShareBps: 0
        });
    }

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_FailedFullClosePaysOnlyTheSnapshottedBackedBounty() public {
        _fundTrader(trader, 5000e6);
        _fundTrader(counterparty, 50_000e6);
        _open(trader, CfdTypes.Side.LONG, 100_000e18, 5000e6, 1e8);
        _open(counterparty, CfdTypes.Side.SHORT, 100_000e18, 50_000e6, 1e8);

        vm.prank(address(router));
        engine.updateMarkPrice(1.96e8, uint64(block.timestamp));

        (, uint256 marginBefore,,,,,) = engine.positions(trader);
        uint256 keeperSettlementBefore = clearinghouse.balanceUsdc(keeper);

        vm.prank(trader);
        (bool committed,) = address(router)
            .call(
                abi.encodeWithSelector(
                    bytes4(keccak256("commitOrder(uint8,uint256,uint256,uint256,bool)")),
                    CfdTypes.Side.LONG,
                    100_000e18,
                    0,
                    1.95e8,
                    true
                )
            );
        assertTrue(committed, "Fixture must reach backed close commitment");

        bytes[] memory priceData = _mockPythUpdateData(1.96e8);
        vm.prank(keeper);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(1, priceData);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Failed));
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Slippage));

        (uint256 sizeAfter, uint256 marginAfter,,,,,) = engine.positions(trader);
        assertEq(sizeAfter, 100_000e18, "The slippage-failed full close leaves the position open");
        assertEq(
            clearinghouse.balanceUsdc(keeper),
            keeperSettlementBefore + router.closeOrderExecutionBountyUsdc(),
            "Existing terminal failure policy pays exactly the backed bounty"
        );
        assertEq(
            marginAfter,
            marginBefore - router.closeOrderExecutionBountyUsdc(),
            "No pledge beyond the reservation is consumed"
        );
    }

}

contract BountyReserveFreeEquityTest is BasePerpTest {

    address trader = address(0xA11CE);

    /// @dev spec; source: ACCOUNTING_SPEC.md#pending-order-reservation-model.
    function test_CommitReserveMustNotReduceUsdcBelowLockedMargin() public {
        address account = trader;

        _fundTrader(trader, 10_000e6);
        _open(account, CfdTypes.Side.LONG, 100_000e18, 2000e6, 1e8);

        uint256 lockedBefore = clearinghouse.lockedMarginUsdc(account);
        uint256 freeBefore = clearinghouse.getFreeBuyingPowerUsdc(account);
        uint256 closeBounty = 1e6;

        vm.prank(trader);
        clearinghouse.withdraw(account, freeBefore - closeBounty);

        vm.prank(trader);
        router.commitOrder(CfdTypes.Side.LONG, 100_000e18, 0, 0, true);

        assertGe(
            clearinghouse.balanceUsdc(account),
            lockedBefore,
            "Close commits must not strip locked margin to fund keeper reserves"
        );
    }

}

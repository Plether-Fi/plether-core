// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {LegacyOrderRouterHarness} from "../../../utils/LegacyOrderRouterHarness.sol";
import {SourceBoundBountyFixture} from "../../shared/SourceBoundBountyFixture.sol";
import {CfdEngine} from "@plether/perps/CfdEngine.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {MarginClearinghouse} from "@plether/perps/MarginClearinghouse.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderRouterAccounting} from "@plether/perps/interfaces/IOrderRouterAccounting.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Fixed-price, zero-carry/VPI reference. All expected balances are derived from funding and action inputs.
contract ProtectedTopUpInvariantHandler is Test {

    uint256 private constant SIZE = 10_000e18;
    uint256 private constant PRICE = 1e8;
    uint256 private constant FUNDING = 100_000e6;
    uint256 private constant ORDER_MARGIN = 1000e6;
    uint256 private constant POSITION_VALUE = 10_000e6;
    uint256 private constant EXECUTION_FEE = 4e6; // 4 bps of position value.
    uint256 private constant LIQUIDATION_RESERVE = 10e6; // 10 bps of position value.
    uint256 private constant OPENING_BOUNTY = 0.2e6; // Opening bounty cap.
    uint256 private constant INITIAL_PLEDGE = ORDER_MARGIN - EXECUTION_FEE - LIQUIDATION_RESERVE;

    struct AccountModel {
        uint64 closeId;
        uint64 openId;
        bool live;
        uint256 custody;
        uint256 ordinaryPledge;
        uint256 pledged;
        uint256 released;
    }

    AccountModel[2] private accounts;
    address[2] private traders;
    CfdEngine private immutable engine;
    MarginClearinghouse private immutable clearinghouse;
    LegacyOrderRouterHarness private immutable router;
    MockPyth private immutable pyth;
    bytes32[] private feedIds;

    constructor(
        CfdEngine engine_,
        MarginClearinghouse clearinghouse_,
        LegacyOrderRouterHarness router_,
        MockPyth pyth_,
        bytes32[] memory feedIds_,
        address[2] memory traders_
    ) {
        engine = engine_;
        clearinghouse = clearinghouse_;
        router = router_;
        pyth = pyth_;
        feedIds = feedIds_;
        traders = traders_;
        for (uint256 i; i < 2; ++i) {
            accounts[i].custody = FUNDING;
        }
    }

    function queueRound(
        uint256 actorSeed,
        bool withFollower
    ) external {
        uint256 i = actorSeed % 2;
        AccountModel storage account = accounts[i];
        if (account.closeId != 0 || account.openId != 0) {
            return;
        }
        address trader = traders[i];
        if (account.live) {
            vm.prank(trader);
            account.closeId = router.commitOrder(CfdTypes.Side.LONG, SIZE, 0, 0, true);
        }
        if (
            !account.live
                || (withFollower && account.custody - _locked(account) >= ORDER_MARGIN + OPENING_BOUNTY + EXECUTION_FEE)
        ) {
            vm.prank(trader);
            account.openId = router.commitOrder(CfdTypes.Side.LONG, SIZE, ORDER_MARGIN, 0, false);
        }
    }

    function topUp(
        uint256 actorSeed,
        uint256 amountSeed
    ) external {
        uint256 i = actorSeed % 2;
        AccountModel storage account = accounts[i];
        if (!account.live || (account.closeId == 0 && account.openId == 0)) {
            return;
        }
        uint256 free = account.custody - _locked(account);
        if (free <= EXECUTION_FEE) {
            return;
        }
        // Cover the same-price close fee from ordinary free settlement in every modeled round.
        uint256 amount = bound(amountSeed, 1, free - EXECUTION_FEE);
        vm.prank(traders[i]);
        engine.addMargin(traders[i], amount);
        account.pledged += amount;
    }

    function executeHead() external {
        uint64 id = router.nextExecuteId();
        if (id == 0) {
            return;
        }
        uint256 i = id == accounts[0].closeId || id == accounts[0].openId ? 0 : 1;
        uint256 deadline = router.lifecycleBook().orderTiming(id).executionDeadline;
        if (vm.getBlockTimestamp() >= deadline) {
            _expire(accounts[i], id, deadline);
            return;
        }
        (IOrderRouterAccounting.PendingOrderView memory pending,) = router.getPendingOrderView(id);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 publishTime = uint256(pending.commitTime) + 1;
        pyth.setAllUniquePrices(feedIds, int64(uint64(PRICE)), 0, -8, publishTime, publishTime - 1);
        bytes[] memory update = new bytes[](1);
        update[0] = abi.encode(PRICE);
        OrderV3Types.ExecutionResult memory result = router.executeOrder(id, update);
        assertEq(result.orderId, id);
        assertEq(uint8(result.status), uint8(OrderV3Types.LifecycleStatus.Executed));

        AccountModel storage account = accounts[i];
        account.custody -= EXECUTION_FEE;
        if (id == account.closeId) {
            assertTrue(account.live);
            account.live = false;
            account.ordinaryPledge = 0;
            account.released += account.pledged;
            account.pledged = 0;
        } else {
            assertEq(id, account.openId);
            assertFalse(account.live);
            account.live = true;
            account.ordinaryPledge = INITIAL_PLEDGE;
            account.custody -= OPENING_BOUNTY;
        }
        _finish(account, id);
    }

    function expireTail(
        uint256 actorSeed
    ) external {
        AccountModel storage account = accounts[actorSeed % 2];
        uint64 id = account.openId != 0 ? account.openId : account.closeId;
        if (id != 0) {
            _expire(account, id, router.lifecycleBook().orderTiming(id).executionDeadline);
        }
    }

    function assertModel() external view {
        uint256 expectedSideExposure;
        for (uint256 i; i < 2; ++i) {
            AccountModel storage account = accounts[i];
            address trader = traders[i];
            IMarginClearinghouse.PnlIsolationBuckets memory buckets = clearinghouse.getPnlIsolationBuckets(trader);
            uint256 pendingCount = (account.closeId == 0 ? 0 : 1) + (account.openId == 0 ? 0 : 1);
            assertEq(router.pendingOrderCounts(trader), pendingCount);
            assertEq(router.accountHeadOrderId(trader), account.closeId == 0 ? account.openId : account.closeId);
            assertEq(buckets.protectedPledgeAssets, account.pledged);
            assertEq(buckets.protectedReleasedAssets, account.released);
            assertEq(buckets.pnlPledgeAssets, account.ordinaryPledge + account.pledged);
            assertEq(clearinghouse.eligiblePositionMarginAssets(trader), account.ordinaryPledge);
            assertEq(buckets.settlementBalanceAssets, account.custody);
            assertEq(buckets.totalLockedAssets, _locked(account));
            assertEq(buckets.freeSettlementAssets, account.custody - _locked(account));
            (uint256 size,,,,,,) = engine.positions(trader);
            assertEq(size, account.live ? SIZE : 0);
            (uint256 carryExposure,,) = engine.positionCarryState(trader);
            uint256 expectedExposure = account.live ? POSITION_VALUE : 0;
            assertEq(carryExposure, expectedExposure);
            expectedSideExposure += expectedExposure;
        }
        (uint256 sideExposure,,,) = engine.sides(uint8(CfdTypes.Side.LONG));
        assertEq(sideExposure, expectedSideExposure);
    }

    function _expire(
        AccountModel storage account,
        uint64 id,
        uint256 deadline
    ) private {
        if (vm.getBlockTimestamp() <= deadline) {
            vm.warp(deadline + 1);
        }
        OrderV3Types.ExecutionResult memory result = router.expireOrder(id);
        assertEq(result.orderId, id);
        assertEq(uint8(result.terminalReason), uint8(OrderV3Types.TerminalReason.Expired));
        if (id == account.openId) {
            account.custody -= OPENING_BOUNTY;
        }
        _finish(account, id);
    }

    function _finish(
        AccountModel storage account,
        uint64 id
    ) private {
        if (id == account.closeId) {
            account.closeId = 0;
        } else {
            assertEq(id, account.openId);
            account.openId = 0;
        }
        if (account.openId == 0 && account.closeId == 0) {
            account.ordinaryPledge += account.pledged;
            account.pledged = 0;
            account.released = 0;
        }
    }

    function _locked(
        AccountModel storage account
    ) private view returns (uint256) {
        uint256 position = account.live ? account.ordinaryPledge + LIQUIDATION_RESERVE : 0;
        uint256 opening = account.openId == 0 ? 0 : ORDER_MARGIN + OPENING_BOUNTY;
        return position + opening + account.pledged + account.released;
    }

}

contract PerpProtectedTopUpInvariantTest is SourceBoundBountyFixture {

    ProtectedTopUpInvariantHandler private handler;

    function setUp() public override {
        super.setUp();
        address[2] memory traders = [BOUNTY_TRADER, BOUNTY_OTHER];
        for (uint256 i; i < traders.length; ++i) {
            _fundTrader(traders[i], 100_000e6);
        }
        handler = new ProtectedTopUpInvariantHandler(
            engine, clearinghouse, router, baseMockPyth, _basePythFeedIds(), traders
        );
        handler.queueRound(0, false);
        handler.executeHead();
        handler.queueRound(0, true);
        handler.topUp(0, 1000e6);
        handler.queueRound(1, false);
        handler.assertModel();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.queueRound.selector;
        selectors[1] = handler.topUp.selector;
        selectors[2] = handler.executeHead.selector;
        selectors[3] = handler.expireTail.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_QueuedTopUpsReconcilePerAccountAcrossTerminalActions() public view {
        handler.assertModel();
    }

    function test_ModelReconcilesExecutionAndExpiryAcrossAccounts() public {
        handler.executeHead(); // Full close moves protected pledge into its released classification.
        handler.assertModel();
        handler.executeHead(); // The follower drains its account queue while the other account remains pending.
        handler.assertModel();
        handler.executeHead();
        handler.queueRound(1, false);
        handler.topUp(1, 1000e6);
        handler.expireTail(1); // Release the restriction while keeping collateral pledged to the live position.
        handler.assertModel();
    }

}

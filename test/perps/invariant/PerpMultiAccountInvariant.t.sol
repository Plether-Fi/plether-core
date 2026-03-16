// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {ICfdEngine} from "../../../src/perps/interfaces/ICfdEngine.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpMultiAccountInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.executeNextOrderBatch.selector;
        selectors[5] = handler.executeNextOrderModelled.selector;
        selectors[6] = handler.liquidate.selector;
        selectors[7] = handler.claimDeferredPayout.selector;
        selectors[8] = handler.claimDeferredClearerBounty.selector;
        selectors[9] = handler.createDeferredTraderPayout.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_SumOfPerAccountPendingCountsMatchesLiveOrders() public view {
        uint256 sumPending;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            sumPending += router.pendingOrderCounts(accountId);
        }

        assertEq(sumPending, _livePendingOrderCount(), "Per-account pending counts must sum to live pending orders");
    }

    function invariant_SumOfPerAccountPendingMarginCountsMatchesLiveMarginOrders() public view {
        uint256 sumMarginOrders;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            sumMarginOrders += handler.ghostPendingMarginOrderCount(accountId);
        }

        assertEq(
            sumMarginOrders, _liveMarginOrderCount(), "Per-account pending margin counts must sum to live margin orders"
        );
    }

    function invariant_LiveOrderOwnershipMatchesAccountLedgerCounts() public view {
        uint64 lastKnownOrderId = handler.lastKnownOrderId();
        uint256[] memory liveCounts = new uint256[](handler.actorCount());
        for (uint64 orderId = 1; orderId <= lastKnownOrderId; orderId++) {
            OrderRouter.OrderRecord memory record = router.getOrderRecord(orderId);
            if (uint256(record.status) != uint256(OrderRouter.OrderStatus.Pending)) {
                continue;
            }
            liveCounts[_actorIndex(record.core.accountId)]++;
        }

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            assertEq(
                liveCounts[i],
                router.pendingOrderCounts(accountId),
                "Live order ownership must match account pending count"
            );
            assertEq(
                liveCounts[i],
                engine.getAccountLedgerView(accountId).pendingOrderCount,
                "Account ledger pending count must match live ownership"
            );
        }
    }

    function invariant_DeferredClaimsRemainAccountIsolated() public view {
        uint256 aggregateDeferredPayouts;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            ICfdEngine.AccountLedgerView memory ledger = engine.getAccountLedgerView(accountId);
            aggregateDeferredPayouts += ledger.deferredPayoutUsdc;
        }

        assertEq(
            aggregateDeferredPayouts,
            engine.totalDeferredPayoutUsdc(),
            "Per-account deferred payouts must stay isolated and sum cleanly"
        );
    }

    function _livePendingOrderCount() internal view returns (uint256 count) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = router.getOrderRecord(orderId);
            if (uint256(record.status) == uint256(OrderRouter.OrderStatus.Pending)) {
                count++;
            }
        }
    }

    function _liveMarginOrderCount() internal view returns (uint256 count) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            OrderRouter.OrderRecord memory record = router.getOrderRecord(orderId);
            if (uint256(record.status) == uint256(OrderRouter.OrderStatus.Pending) && record.inMarginQueue) {
                count++;
            }
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _actorIndex(
        bytes32 accountId
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            if (_accountId(handler.actorAt(i)) == accountId) {
                return i;
            }
        }
        revert("unknown actor");
    }

}

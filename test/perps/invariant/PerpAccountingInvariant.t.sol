// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEngine} from "../../../src/perps/CfdEngine.sol";
import {CfdTypes} from "../../../src/perps/CfdTypes.sol";
import {OrderRouter} from "../../../src/perps/OrderRouter.sol";
import {BasePerpInvariantTest} from "./BasePerpInvariantTest.sol";
import {PerpGhostLedger} from "./ghost/PerpGhostLedger.sol";
import {PerpAccountingHandler} from "./handlers/PerpAccountingHandler.sol";

contract PerpAccountingInvariantTest is BasePerpInvariantTest {

    PerpAccountingHandler internal handler;

    function _riskParams() internal pure override returns (CfdTypes.RiskParams memory) {
        return CfdTypes.RiskParams({
            vpiFactor: 0,
            maxSkewRatio: 0.4e18,
            kinkSkewRatio: 0.25e18,
            baseApy: 0,
            maxApy: 0,
            maintMarginBps: 100,
            fadMarginBps: 300,
            minBountyUsdc: 1e6,
            bountyBps: 9
        });
    }

    function setUp() public override {
        super.setUp();

        handler = new PerpAccountingHandler(usdc, engine, clearinghouse, router, vault);
        handler.seedActors(50_000e6, 100_000e6);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.depositCollateral.selector;
        selectors[1] = handler.withdrawCollateral.selector;
        selectors[2] = handler.commitOpenOrder.selector;
        selectors[3] = handler.commitCloseOrder.selector;
        selectors[4] = handler.cancelCloseOrder.selector;
        selectors[5] = handler.executeNextOrderBatch.selector;
        selectors[6] = handler.liquidate.selector;
        selectors[7] = handler.claimDeferredClearerBounty.selector;
        selectors[8] = handler.setRouterPayoutFailureMode.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_RouterCustodyMatchesLiveExecutionBounties() public view {
        assertEq(
            usdc.balanceOf(address(router)),
            _sumPendingExecutionBounties(),
            "Router custody must equal live pending execution bounty reserves"
        );
    }

    function invariant_LiquidatedActorsHaveNoPendingOrders() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(router.pendingOrderCounts(accountId), 0, "Liquidated accounts must not keep pending orders");
        }
    }

    function invariant_LiquidatedActorsHaveNoLiveReserves() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertEq(handler.accountRouterEscrow(accountId), 0, "Liquidated accounts must not retain router-held escrow");
            assertEq(handler.accountLiveReserveCount(accountId), 0, "Liquidated accounts must not retain live reserves");
        }
    }

    function invariant_LiquidatedActorsCannotRecoverWalletUsdc() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actorAt(i);
            bytes32 accountId = _accountId(actor);
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated) {
                continue;
            }

            assertLe(usdc.balanceOf(actor), snapshot.walletUsdc, "Liquidated actors must not recover wallet USDC later");
        }
    }

    function invariant_BadDebtOnlyAppearsAfterAccountEscrowExhaustion() public view {
        uint256 currentBadDebt = engine.accumulatedBadDebtUsdc();
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            PerpGhostLedger.LiquidationSnapshot memory snapshot = handler.liquidationSnapshot(accountId);
            if (!snapshot.liquidated || currentBadDebt <= snapshot.badDebtUsdc) {
                continue;
            }

            assertEq(handler.accountRouterEscrow(accountId), 0, "Bad debt growth cannot coexist with same-account router escrow");
        }
    }

    function invariant_GhostCommittedMarginMatchesAccountEscrow() public view {
        uint256 ghostTotalCommittedMargin;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            bytes32 accountId = _accountId(handler.actorAt(i));
            uint256 ghostCommittedMargin = handler.committedMarginSnapshot(accountId);
            uint256 liveCommittedMargin = router.getAccountEscrow(accountId).committedMarginUsdc;

            assertEq(ghostCommittedMargin, liveCommittedMargin, "Ghost committed margin must match account escrow");
            ghostTotalCommittedMargin += ghostCommittedMargin;
        }

        assertEq(
            handler.totalCommittedMarginSnapshot(),
            ghostTotalCommittedMargin,
            "Ghost committed margin total must match tracked account sum"
        );
    }

    function invariant_GhostDeferredClearerBountyMatchesEngine() public view {
        uint256 ghostDeferredBounty = handler.deferredClearerBountySnapshot();
        uint256 liveDeferredBounty = engine.deferredClearerBountyUsdc(address(handler));

        assertEq(ghostDeferredBounty, liveDeferredBounty, "Ghost deferred clearer bounty must match engine storage");
        assertEq(
            handler.totalDeferredClearerBountySnapshot(),
            ghostDeferredBounty,
            "Ghost deferred clearer bounty total must match tracked clearer balance"
        );
    }

    function _sumPendingExecutionBounties() internal view returns (uint256 totalBounties) {
        for (uint64 orderId = router.nextExecuteId(); orderId < router.nextCommitId(); orderId++) {
            (bytes32 accountId, uint256 sizeDelta,,,,,,,) = router.orders(orderId);
            if (accountId == bytes32(0) || sizeDelta == 0) {
                continue;
            }
            totalBounties += router.executionBountyReserves(orderId);
        }
    }

    function _accountId(
        address actor
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }
}

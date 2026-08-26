// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "./BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IMarginClearinghouse} from "@plether/perps/interfaces/IMarginClearinghouse.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {IPerpsKeeper} from "@plether/perps/interfaces/IPerpsKeeper.sol";

/// @dev Delegates normal Book behavior to an exact copy of its original runtime, but exhausts all item gas when the
///      selected receipt is finalized. Installing this runtime with `vm.etch` preserves the original Book storage.
contract GasBurningLifecycleBookProxy {

    address internal immutable IMPLEMENTATION;
    uint64 internal immutable BURN_ORDER_ID;

    constructor(
        address implementation,
        uint64 burnOrderId
    ) {
        IMPLEMENTATION = implementation;
        BURN_ORDER_ID = burnOrderId;
    }

    fallback() external payable {
        if (msg.sig == IOrderLifecycleBook.finalize.selector) {
            uint64 orderId;
            assembly ("memory-safe") {
                orderId := calldataload(4)
            }
            if (orderId == BURN_ORDER_ID) {
                assembly ("memory-safe") {
                    for {} 1 {} { pop(gas()) }
                }
            }
        }

        address implementation = IMPLEMENTATION;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

}

/// @dev Batch caller whose refund callback consumes its entire 30,000-gas stipend and therefore must be deferred.
contract GasBurningBatchKeeper {

    receive() external payable {
        assembly ("memory-safe") {
            for {} 1 {} { pop(gas()) }
        }
    }

    function executeBatch(
        address router,
        uint64 maxOrderId,
        bytes[] calldata updateData
    ) external payable returns (OrderV2Types.BatchResult memory result) {
        return IPerpsKeeper(router).executeOrderBatch{value: msg.value}(maxOrderId, updateData);
    }

}

/// @notice Regression coverage for batch prefix durability under item OOG and refund-callback gas griefing.
contract OrderRouterV2BatchOogIsolationTest is BasePerpTest {

    address internal constant FIRST_TRADER = address(0xBA7C1001);
    address internal constant SECOND_TRADER = address(0xBA7C1002);
    uint256 internal constant REFUND_AMOUNT = 0.25 ether;

    function test_BatchItemOogAndRefundGasBurnCannotRollbackCompletedPrefix() public {
        _fundTrader(FIRST_TRADER, 2000e6);
        _fundTrader(SECOND_TRADER, 2000e6);

        vm.prank(FIRST_TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        vm.prank(SECOND_TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        uint64 firstOrderId = 1;
        uint64 secondOrderId = 2;

        routerAdmin.pause();
        _installGasBurningBookFinalization(secondOrderId);
        GasBurningBatchKeeper keeper = new GasBurningBatchKeeper();
        uint256 pythCallsBefore = baseMockPyth.updatePriceFeedsCallCount();

        vm.deal(address(this), REFUND_AMOUNT);
        OrderV2Types.BatchResult memory result =
            keeper.executeBatch{value: REFUND_AMOUNT, gas: 8_000_000}(address(router), secondOrderId, new bytes[](0));

        assertEq(result.terminalCount, 1, "the completed prefix must be reported");
        assertEq(result.nextOrderId, secondOrderId, "the OOG item must remain the returned cursor");
        assertEq(
            uint256(result.stopReason),
            uint256(OrderV2Types.PendingReason.EngineFailure),
            "an empty OOG revert must stop as a retryable dependency failure"
        );
        assertEq(router.nextExecuteId(), secondOrderId, "the global cursor must preserve the retryable item");

        OrderV2Types.CompactOutcome memory firstOutcome = router.lifecycleBook().outcome(firstOrderId);
        assertEq(
            uint256(firstOutcome.status),
            uint256(OrderV2Types.LifecycleStatus.Failed),
            "the first receipt must persist after the later OOG"
        );
        assertEq(
            uint256(firstOutcome.reason),
            uint256(OrderV2Types.TerminalReason.RiskOff),
            "the completed prefix must retain its exact terminal reason"
        );
        assertEq(firstOutcome.executor, address(keeper), "the prefix receipt must retain the external keeper");

        assertEq(
            uint256(router.lifecycleBook().lifecycleStatus(secondOrderId)),
            uint256(OrderV2Types.LifecycleStatus.Pending),
            "the OOG receipt finalization must roll back the complete second item"
        );
        assertEq(
            router.lifecycleBook().pendingIntent(secondOrderId).account,
            SECOND_TRADER,
            "the retryable intent must remain authoritative"
        );
        assertEq(
            uint256(clearinghouse.getOrderReservation(secondOrderId).status),
            uint256(IMarginClearinghouse.ReservationStatus.Active),
            "the retryable item's margin and bounty reservation must be restored"
        );
        assertEq(
            baseMockPyth.updatePriceFeedsCallCount(),
            pythCallsBefore,
            "risk-off terminalization and OOG isolation must remain oracle-independent"
        );

        assertEq(
            routerAdmin.claimableEth(address(keeper)),
            REFUND_AMOUNT,
            "the capped failing refund must be deferred without reverting the completed prefix"
        );
        assertEq(address(router).balance, 0, "the Router must not retain the deferred refund");
    }

    function _installGasBurningBookFinalization(
        uint64 burnOrderId
    ) internal {
        address book = address(router.lifecycleBook());
        address originalRuntime = address(0xB00C);
        vm.etch(originalRuntime, book.code);

        GasBurningLifecycleBookProxy proxy = new GasBurningLifecycleBookProxy(originalRuntime, burnOrderId);
        vm.etch(book, address(proxy).code);
    }

}

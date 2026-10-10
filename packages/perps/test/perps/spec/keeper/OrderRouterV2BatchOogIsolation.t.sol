// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {BasePerpTest} from "../../BasePerpTest.sol";
import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderRouterAdmin} from "@plether/perps/OrderRouterAdmin.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
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

/// @dev Defaults to exhausting the immediate refund stipend; claim tests can reject or accept deferred delivery.
contract GasBurningBatchKeeper {

    enum RefundMode {
        BurnGas,
        Reject,
        Accept
    }

    RefundMode public refundMode;
    uint256 public receivedEth;

    receive() external payable {
        if (refundMode == RefundMode.BurnGas) {
            assembly ("memory-safe") {
                for {} 1 {} { pop(gas()) }
            }
        }
        require(refundMode == RefundMode.Accept, "refund rejected");
        receivedEth += msg.value;
    }

    function setRefundMode(
        RefundMode mode
    ) external {
        refundMode = mode;
    }

    function claimRefund(
        OrderRouterAdmin admin
    ) external {
        admin.claimBalance(true);
    }

    function executeBatch(
        address router,
        uint64 maxOrderId,
        bytes[] calldata updateData
    ) external payable returns (OrderV3Types.BatchResult memory result) {
        return IPerpsKeeper(router).executeOrderBatch{value: msg.value}(maxOrderId, updateData);
    }

}

/// @notice Regression coverage for batch prefix durability under item OOG and refund-callback gas griefing.
contract OrderRouterV2BatchOogIsolationTest is BasePerpTest {

    address internal constant FIRST_TRADER = address(0xBA7C1001);
    address internal constant SECOND_TRADER = address(0xBA7C1002);
    uint256 internal constant REFUND_AMOUNT = 0.25 ether;

    function test_BatchItemOogAndRefundGasBurnCannotRollbackCompletedPrefix() public {
        _startRecordingLogs();
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
        OrderV3Types.BatchResult memory result =
            keeper.executeBatch{value: REFUND_AMOUNT, gas: 8_000_000}(address(router), secondOrderId, new bytes[](0));

        assertEq(result.terminalCount, 1, "the completed prefix must be reported");
        assertEq(result.nextOrderId, secondOrderId, "the OOG item must remain the returned cursor");
        assertEq(
            uint256(result.stopReason),
            uint256(OrderV3Types.PendingReason.EngineFailure),
            "an empty OOG revert must stop as a retryable dependency failure"
        );
        assertEq(router.nextExecuteId(), secondOrderId, "the global cursor must preserve the retryable item");

        OrderV3Types.CompactOutcome memory firstOutcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), firstOrderId);
        assertEq(
            uint256(firstOutcome.status),
            uint256(OrderV3Types.LifecycleStatus.Failed),
            "the first receipt must persist after the later OOG"
        );
        assertEq(
            uint256(firstOutcome.reason),
            uint256(OrderV3Types.TerminalReason.RiskOff),
            "the completed prefix must retain its exact terminal reason"
        );
        assertEq(firstOutcome.executor, address(keeper), "the prefix receipt must retain the external keeper");

        assertEq(
            uint256(router.lifecycleBook().lifecycleStatus(secondOrderId)),
            uint256(OrderV3Types.LifecycleStatus.Pending),
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
        assertEq(address(routerAdmin).balance, REFUND_AMOUNT, "the Admin must physically back the full deferred refund");
        assertEq(address(keeper).balance, 0, "the failing callback must not receive any ETH");
    }

    function test_DeferredAdminRefundIsBackedUntilBeneficiaryClaimsExactlyOnce() public {
        _startRecordingLogs();
        _fundTrader(FIRST_TRADER, 2000e6);
        vm.prank(FIRST_TRADER);
        router.commitOrder(CfdTypes.Side.LONG, 10_000e18, 1000e6, 1e8, false);
        routerAdmin.pause();

        GasBurningBatchKeeper keeper = new GasBurningBatchKeeper();
        vm.deal(address(this), REFUND_AMOUNT);
        OrderV3Types.BatchResult memory result =
            keeper.executeBatch{value: REFUND_AMOUNT}(address(router), 1, new bytes[](0));

        assertEq(result.terminalCount, 1, "the ordinary paused batch must reach terminal refund delivery");
        OrderV3Types.CompactOutcome memory outcome =
            _verifiedOutcome(IOrderLifecycleBook(address(router.lifecycleBook())), 1);
        assertEq(uint256(outcome.status), uint256(OrderV3Types.LifecycleStatus.Failed), "the order must terminalize");
        assertEq(uint256(outcome.reason), uint256(OrderV3Types.TerminalReason.RiskOff), "the pause must cause failure");
        assertEq(routerAdmin.claimableEth(address(keeper)), REFUND_AMOUNT, "only the refund beneficiary is credited");
        assertEq(address(routerAdmin).balance, REFUND_AMOUNT, "the entire obligation must have physical backing");
        assertEq(address(router).balance, 0, "deferred cash must leave the Router");
        assertEq(address(keeper).balance, 0, "the failed immediate callback must not retain cash");

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__NothingToClaim.selector);
        routerAdmin.claimBalance(true);
        assertEq(routerAdmin.claimableEth(address(keeper)), REFUND_AMOUNT, "another caller cannot consume the credit");
        assertEq(address(routerAdmin).balance, REFUND_AMOUNT, "another caller cannot consume the backing cash");

        keeper.setRefundMode(GasBurningBatchKeeper.RefundMode.Reject);
        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__EthTransferFailed.selector);
        keeper.claimRefund(routerAdmin);
        assertEq(routerAdmin.claimableEth(address(keeper)), REFUND_AMOUNT, "rejected delivery must restore the credit");
        assertEq(address(routerAdmin).balance, REFUND_AMOUNT, "rejected delivery must preserve physical backing");
        assertEq(address(keeper).balance, 0, "rejected delivery must not pay the beneficiary");
        assertEq(keeper.receivedEth(), 0, "a rejected claim must roll back the callback");

        keeper.setRefundMode(GasBurningBatchKeeper.RefundMode.Accept);
        keeper.claimRefund(routerAdmin);
        assertEq(routerAdmin.claimableEth(address(keeper)), 0, "successful delivery must consume the whole credit");
        assertEq(address(routerAdmin).balance, 0, "successful delivery must transfer the backing cash");
        assertEq(address(keeper).balance, REFUND_AMOUNT, "cash must reach the credited beneficiary");
        assertEq(keeper.receivedEth(), REFUND_AMOUNT, "the callback must receive the exact obligation");
        assertEq(address(this).balance, 0, "the funding caller must not receive the beneficiary's refund");

        vm.expectRevert(OrderRouterAdmin.OrderRouterAdmin__NothingToClaim.selector);
        keeper.claimRefund(routerAdmin);
        assertEq(routerAdmin.claimableEth(address(keeper)), 0, "a repeated claim must not recreate credit");
        assertEq(address(routerAdmin).balance, 0, "a repeated claim must not recreate backing cash");
        assertEq(address(keeper).balance, REFUND_AMOUNT, "the refund must be paid exactly once");
        assertEq(keeper.receivedEth(), REFUND_AMOUNT, "a repeated claim must not call the beneficiary again");
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Preserve detailed outcome assertions through authenticated event history.
abstract contract RecordedOrderReceipts is Test {

    mapping(address => mapping(uint64 => bytes)) private _recordedReceipts;
    bool private _recordingReceipts;

    function _cacheReceiptLogs(
        Vm.Log[] memory logs
    ) private {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == IOrderLifecycleBook.OrderFinalized.selector) {
                (,,, OrderV2Types.OrderReceipt memory receipt) =
                    abi.decode(logs[i].data, (bytes32, uint64, uint64, OrderV2Types.OrderReceipt));
                assertEq(uint256(logs[i].topics[1]), receipt.orderId);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), receipt.account);
                assertEq(logs[i].topics[3], receipt.clientOrderId);
                _recordedReceipts[logs[i].emitter][receipt.orderId] = logs[i].data;
            }
        }
    }

    function _startRecordingLogs() internal {
        if (_recordingReceipts) {
            _cacheReceiptLogs(vm.getRecordedLogs());
        }
        vm.recordLogs();
        _recordingReceipts = true;
    }

    function _takeRecordedLogs() internal returns (Vm.Log[] memory logs) {
        logs = vm.getRecordedLogs();
        _cacheReceiptLogs(logs);
    }

    function _verifiedOutcome(
        IOrderLifecycleBook book,
        uint64 orderId
    ) internal returns (OrderV2Types.CompactOutcome memory outcome) {
        OrderV2Types.TerminalOutcome memory summary = book.terminalOutcome(orderId);
        if (summary.status == OrderV2Types.LifecycleStatus.None) {
            return outcome;
        }
        _cacheReceiptLogs(vm.getRecordedLogs());
        bytes memory data = _recordedReceipts[address(book)][orderId];
        assertGt(data.length, 0, "missing terminal receipt event");
        (bytes32 receiptHash, uint64 terminalBlock, uint64 terminalTime, OrderV2Types.OrderReceipt memory receipt) =
            abi.decode(data, (bytes32, uint64, uint64, OrderV2Types.OrderReceipt));
        assertTrue(book.verifyReceipt(receipt, terminalTime), "unauthenticated terminal receipt");
        assertEq(summary.account, receipt.account);
        assertEq(summary.terminalBlock, terminalBlock);
        assertEq(uint8(summary.status), uint8(receipt.status));
        assertEq(uint8(summary.reason), uint8(receipt.reason));
        assertEq(summary.receiptHash, receiptHash);
        outcome.account = receipt.account;
        outcome.clientOrderId = receipt.clientOrderId;
        outcome.intentHash = receipt.intentHash;
        outcome.expectedConfigHash = receipt.expectedConfigHash;
        outcome.observedConfigHash = receipt.observedConfigHash;
        outcome.status = receipt.status;
        outcome.reason = receipt.reason;
        outcome.executionMode = receipt.executionMode;
        outcome.priceSource = receipt.priceSource;
        outcome.bountyDisposition = receipt.bountyDisposition;
        outcome.oraclePublishTime = receipt.oraclePublishTime;
        outcome.executor = receipt.executor;
        outcome.bountyRecipient = receipt.bountyRecipient;
        outcome.executionPrice = receipt.executionPrice;
        outcome.bountyUsdc = receipt.bountyUsdc;
        outcome.failureSelector = receipt.failure.selector;
        outcome.failureCategory = receipt.failure.category;
        outcome.failureCode = receipt.failure.code;
        outcome.failedConstraint = receipt.failure.constraint;
        outcome.revertDataHash = receipt.failure.revertDataHash;
        outcome.terminalBlock = terminalBlock;
        outcome.terminalTime = terminalTime;
        outcome.receiptHash = receiptHash;
    }

}

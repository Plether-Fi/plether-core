// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {Test} from "forge-std/Test.sol";

contract OrderLifecycleBookUnpinnedConfigTest is Test {

    address private constant ACCOUNT = address(0xA11CE);
    address private constant EXECUTOR = address(0xE7EC);
    bytes32 private constant OBSERVED_CONFIG_HASH = keccak256("observed-config");

    OrderLifecycleBook private book;

    function setUp() public {
        book = new OrderLifecycleBook(address(this), address(0xE001), address(0xC1EA), address(0xB001));
    }

    function test_UnpinnedInternalIntentAcceptsOracleReceiptAndRecordsObservedConfig() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("protected-child"), bytes32(0));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 1, request, 0);

        book.finalize(_executedReceipt(1, request, intentHash, OBSERVED_CONFIG_HASH));

        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(1);
        assertEq(terminalOutcome.expectedConfigHash, bytes32(0));
        assertEq(terminalOutcome.observedConfigHash, OBSERVED_CONFIG_HASH);
        assertEq(uint8(terminalOutcome.status), uint8(OrderV2Types.LifecycleStatus.Executed));
    }

    function test_PinnedIntentStillRejectsMismatchedOracleReceipt() public {
        bytes32 expectedConfigHash = keccak256("expected-config");
        OrderV2Types.OrderRequest memory request = _request(bytes32("pinned"), expectedConfigHash);
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 2, request, 0);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__InvalidTerminalOutcome.selector);
        book.finalize(_executedReceipt(2, request, intentHash, OBSERVED_CONFIG_HASH));
    }

    function _request(
        bytes32 clientOrderId,
        bytes32 expectedConfigHash
    ) private view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = clientOrderId;
        request.side = CfdTypes.Side.BULL;
        request.sizeDelta = 100e18;
        request.targetPrice = 1e8;
        request.bounds = OrderV2Types.ExecutionBounds({
            validUntil: uint64(block.timestamp + 1 hours),
            allowedExecutionModes: 1,
            expectedConfigHash: expectedConfigHash,
            maxExecutionBountyUsdc: 0,
            maxExecutionNotionalUsdc: type(uint256).max,
            maxGrossAccountDebitUsdc: type(uint256).max,
            maxActionChargeUsdc: type(uint256).max,
            maxExplicitFeesUsdc: type(uint256).max,
            maxPostPositionSize: type(uint256).max,
            minPostSettlementBalanceUsdc: 0,
            minPostPositionEquityUsdc: 0,
            maxPostLeverageBps: type(uint32).max
        });
    }

    function _executedReceipt(
        uint64 orderId,
        OrderV2Types.OrderRequest memory request,
        bytes32 intentHash,
        bytes32 observedConfigHash
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        receipt.orderId = orderId;
        receipt.account = ACCOUNT;
        receipt.clientOrderId = request.clientOrderId;
        receipt.intentHash = intentHash;
        receipt.expectedConfigHash = request.bounds.expectedConfigHash;
        receipt.observedConfigHash = observedConfigHash;
        receipt.status = OrderV2Types.LifecycleStatus.Executed;
        receipt.reason = OrderV2Types.TerminalReason.Executed;
        receipt.executionMode = OrderV2Types.ExecutionMode.Live;
        receipt.executor = EXECUTOR;
        receipt.priceSource = OrderV2Types.PriceSource.OracleExecution;
        receipt.executionPrice = 1e8;
        receipt.neutralMarkPrice = 1e8;
        receipt.poolDepthUsdc = 1e6;
        receipt.oraclePublishTime = 1;
        receipt.priceReachedEngine = true;
    }

}

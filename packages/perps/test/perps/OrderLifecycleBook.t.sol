// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderLifecycleBook} from "@plether/perps/OrderLifecycleBook.sol";
import {OrderV2Types} from "@plether/perps/OrderV2Types.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderLifecycleBook} from "@plether/perps/interfaces/IOrderLifecycleBook.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract OrderLifecycleBookTest is Test {

    address private constant ENGINE = address(0xE001);
    address private constant CLEARINGHOUSE = address(0xC1EA);
    address private constant HOUSE_POOL = address(0xB001);
    address private constant ACCOUNT = address(0xA11CE);
    address private constant OTHER_ACCOUNT = address(0xB0B);
    address private constant EXECUTOR = address(0xE7EC);
    uint256 private constant EXECUTION_BOUNTY_USDC = 1e6;
    address private constant POLICY_EVALUATOR = address(0xE0A1);
    address private constant EXECUTION_SIDECAR = address(0xEEC1);
    address private constant ORACLE = address(0x0ACE);
    address private constant ROUTER_ADMIN = address(0xADA1);
    address private constant PLANNER = address(0x91A4);
    address private constant SETTLEMENT_SIDECAR = address(0x51DE);
    address private constant TERMINAL_NAV_BOOK = address(0x7EAD);
    address private constant ENGINE_ADMIN = address(0xEADA);
    address private constant PROTOCOL_TREASURY = address(0x7EA5);

    OrderLifecycleBook private book;

    function setUp() public {
        book = new OrderLifecycleBook(address(this), ENGINE, CLEARINGHOUSE, HOUSE_POOL);
    }

    function test_ConstructorBindsExplicitRouterAndDependencies() public view {
        assertEq(book.ROUTER(), address(this));
        assertEq(book.ENGINE(), ENGINE);
        assertEq(book.CLEARINGHOUSE(), CLEARINGHOUSE);
        assertEq(book.HOUSE_POOL(), HOUSE_POOL);
        assertTrue(book.INTENT_TYPEHASH() != bytes32(0));
        assertTrue(book.RECEIPT_TYPEHASH() != bytes32(0));
    }

    function test_ConstructorRejectsEveryZeroDependency() public {
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroDependency.selector);
        new OrderLifecycleBook(address(0), ENGINE, CLEARINGHOUSE, HOUSE_POOL);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroDependency.selector);
        new OrderLifecycleBook(address(this), address(0), CLEARINGHOUSE, HOUSE_POOL);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroDependency.selector);
        new OrderLifecycleBook(address(this), ENGINE, address(0), HOUSE_POOL);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroDependency.selector);
        new OrderLifecycleBook(address(this), ENGINE, CLEARINGHOUSE, address(0));
    }

    function test_CurrentExecutionConfigHashCommitsToEveryCriticalIntegrationAndVersion() public {
        uint64 routerVersion = 17;
        uint64 engineVersion = 29;
        uint256 markStalenessLimit = 45 minutes;
        _mockConfig(routerVersion, engineVersion, markStalenessLimit);

        bytes memory routerConfig = abi.encode(
            book.CONFIG_SCHEMA_HASH(),
            block.chainid,
            address(book),
            address(this),
            ENGINE,
            CLEARINGHOUSE,
            HOUSE_POOL,
            POLICY_EVALUATOR,
            EXECUTION_SIDECAR,
            ORACLE,
            ROUTER_ADMIN,
            routerVersion
        );
        bytes memory engineConfig = abi.encode(
            PLANNER,
            SETTLEMENT_SIDECAR,
            TERMINAL_NAV_BOOK,
            ENGINE_ADMIN,
            engineVersion,
            PROTOCOL_TREASURY,
            markStalenessLimit
        );
        bytes32 expectedHash = keccak256(bytes.concat(routerConfig, engineConfig));
        assertEq(book.currentExecutionConfigHash(), expectedHash);

        _mockConfig(routerVersion + 1, engineVersion, markStalenessLimit);
        assertTrue(book.currentExecutionConfigHash() != expectedHash);

        _mockConfig(routerVersion, engineVersion, markStalenessLimit);
        vm.mockCall(ENGINE, abi.encodeWithSignature("terminalNavBook()"), abi.encode(address(0xBAD1)));
        assertTrue(book.currentExecutionConfigHash() != expectedHash);
    }

    function test_RegisterStoresPermanentClientIntentAndPendingPolicy() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("client-1"));

        (uint64 orderId, bytes32 intentHash, bool replayed) =
            book.registerPending(ACCOUNT, 17, request, EXECUTION_BOUNTY_USDC);

        assertEq(orderId, 17);
        assertFalse(replayed);
        assertEq(intentHash, book.hashOrderRequest(ACCOUNT, request));

        OrderV2Types.ClientIntent memory client = book.clientIntent(ACCOUNT, request.clientOrderId);
        assertEq(client.orderId, 17);
        assertEq(client.intentHash, intentHash);

        OrderV2Types.PendingIntent memory pending = book.pendingIntent(17);
        assertEq(pending.account, ACCOUNT);
        assertEq(pending.clientOrderId, request.clientOrderId);
        assertEq(pending.intentHash, intentHash);
        assertEq(pending.executionBountyUsdc, EXECUTION_BOUNTY_USDC);
        _assertBoundsEq(pending.bounds, request.bounds);
        _assertBoundsEq(book.pendingPolicy(17), request.bounds);

        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(17);
        assertEq(uint8(terminalOutcome.status), uint8(OrderV2Types.LifecycleStatus.None));
        assertEq(uint8(book.lifecycleStatus(17)), uint8(OrderV2Types.LifecycleStatus.Pending));
    }

    function test_HashOrderRequestMatchesCanonicalFlatEncoding() public view {
        OrderV2Types.OrderRequest memory request = _request(bytes32("canonical-hash"));
        OrderV2Types.ExecutionBounds memory bounds = request.bounds;
        bytes memory identityAndOrder = abi.encode(
            book.INTENT_TYPEHASH(),
            block.chainid,
            address(this),
            ACCOUNT,
            request.clientOrderId,
            uint8(request.side),
            request.sizeDelta,
            request.marginDelta,
            request.targetPrice,
            request.isClose
        );
        bytes memory financialPolicy = abi.encode(
            bounds.validUntil,
            bounds.allowedExecutionModes,
            bounds.expectedConfigHash,
            bounds.maxExecutionBountyUsdc,
            bounds.maxExecutionNotionalUsdc,
            bounds.maxGrossAccountDebitUsdc,
            bounds.maxActionChargeUsdc,
            bounds.maxExplicitFeesUsdc,
            bounds.maxPostPositionSize,
            bounds.minPostSettlementBalanceUsdc,
            bounds.minPostPositionEquityUsdc,
            bounds.maxPostLeverageBps
        );

        assertEq(book.hashOrderRequest(ACCOUNT, request), keccak256(bytes.concat(identityAndOrder, financialPolicy)));
    }

    function test_IntentRegisteredEventContainsFullOrderRequestPreimage() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("observable-preimage"));

        vm.recordLogs();
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 18, request, EXECUTION_BOUNTY_USDC);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory registrationLog;
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(book) && logs[i].topics.length != 0
                    && logs[i].topics[0] == IOrderLifecycleBook.IntentRegistered.selector
            ) {
                registrationLog = logs[i];
                found = true;
                break;
            }
        }

        assertTrue(found, "registration must emit its canonical Book event");
        assertEq(registrationLog.topics.length, 4, "all identity fields must remain indexed");
        assertEq(registrationLog.topics[1], bytes32(uint256(18)), "event order id must match");
        assertEq(registrationLog.topics[2], bytes32(uint256(uint160(ACCOUNT))), "event account must match");
        assertEq(registrationLog.topics[3], request.clientOrderId, "event client id must match");
        assertEq(
            registrationLog.data,
            abi.encode(intentHash, EXECUTION_BOUNTY_USDC, request),
            "event data must contain the exact complete request preimage"
        );

        (bytes32 emittedIntentHash, uint256 emittedBounty, OrderV2Types.OrderRequest memory emittedRequest) =
            abi.decode(registrationLog.data, (bytes32, uint256, OrderV2Types.OrderRequest));
        assertEq(emittedIntentHash, book.hashOrderRequest(ACCOUNT, emittedRequest));
        assertEq(emittedBounty, EXECUTION_BOUNTY_USDC);
        assertEq(
            keccak256(abi.encode(emittedRequest)), keccak256(abi.encode(request)), "decoded request must be lossless"
        );
    }

    function test_ResolveAndRegisterExactReplayAreNoOpsEvenAfterTerminal() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("retry-safe"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 8, request, EXECUTION_BOUNTY_USDC);

        (OrderV2Types.ClientIntentResolution resolution, uint64 resolvedOrderId, bytes32 resolvedHash) =
            book.resolveClientIntent(ACCOUNT, request);
        assertEq(uint8(resolution), uint8(OrderV2Types.ClientIntentResolution.ExactReplay));
        assertEq(resolvedOrderId, 8);
        assertEq(resolvedHash, intentHash);

        bool replayed;
        (resolvedOrderId, resolvedHash, replayed) =
            book.registerPending(ACCOUNT, 99, request, EXECUTION_BOUNTY_USDC + 1);
        assertEq(resolvedOrderId, 8);
        assertEq(resolvedHash, intentHash);
        assertTrue(replayed);

        book.finalize(_executedReceipt(8, ACCOUNT, request, intentHash));

        (resolvedOrderId, resolvedHash, replayed) = book.registerPending(ACCOUNT, 0, request, type(uint256).max);
        assertEq(resolvedOrderId, 8);
        assertEq(resolvedHash, intentHash);
        assertTrue(replayed);
        assertEq(book.pendingIntent(8).account, address(0));
    }

    function test_ConflictIsObservableAndRegistrationReverts() public {
        OrderV2Types.OrderRequest memory original = _request(bytes32("same-client"));
        (, bytes32 originalHash,) = book.registerPending(ACCOUNT, 4, original, EXECUTION_BOUNTY_USDC);
        OrderV2Types.OrderRequest memory conflicting = original;
        conflicting.bounds.maxExplicitFeesUsdc += 1;

        (OrderV2Types.ClientIntentResolution resolution, uint64 resolvedOrderId, bytes32 conflictingHash) =
            book.resolveClientIntent(ACCOUNT, conflicting);
        assertEq(uint8(resolution), uint8(OrderV2Types.ClientIntentResolution.Conflict));
        assertEq(resolvedOrderId, 4);
        assertTrue(conflictingHash != originalHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ClientIdConflict.selector,
                ACCOUNT,
                original.clientOrderId,
                originalHash,
                conflictingHash
            )
        );
        book.registerPending(ACCOUNT, 5, conflicting, EXECUTION_BOUNTY_USDC);
    }

    function test_ClientIdsAreNamespacedByAccountAndHashCommitsToAccount() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("shared-client"));
        (, bytes32 firstHash,) = book.registerPending(ACCOUNT, 1, request, EXECUTION_BOUNTY_USDC);
        (, bytes32 secondHash,) = book.registerPending(OTHER_ACCOUNT, 2, request, EXECUTION_BOUNTY_USDC);

        assertTrue(firstHash != secondHash);
        assertEq(book.clientIntent(ACCOUNT, request.clientOrderId).orderId, 1);
        assertEq(book.clientIntent(OTHER_ACCOUNT, request.clientOrderId).orderId, 2);
    }

    function test_RegisterRejectsUnauthorizedAndInvalidOrReusedIds() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("client"));

        vm.prank(address(0xBAD));
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__Unauthorized.selector);
        book.registerPending(ACCOUNT, 1, request, EXECUTION_BOUNTY_USDC);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroAccount.selector);
        book.registerPending(address(0), 1, request, EXECUTION_BOUNTY_USDC);

        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroOrderId.selector);
        book.registerPending(ACCOUNT, 0, request, EXECUTION_BOUNTY_USDC);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderLifecycleBook.OrderLifecycleBook__ExecutionBountyAboveBound.selector,
                request.bounds.maxExecutionBountyUsdc + 1,
                request.bounds.maxExecutionBountyUsdc
            )
        );
        book.registerPending(ACCOUNT, 1, request, request.bounds.maxExecutionBountyUsdc + 1);

        request.clientOrderId = bytes32(0);
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__ZeroClientOrderId.selector);
        book.registerPending(ACCOUNT, 1, request, EXECUTION_BOUNTY_USDC);

        OrderV2Types.OrderRequest memory first = _request(bytes32("first"));
        (, bytes32 firstHash,) = book.registerPending(ACCOUNT, 11, first, EXECUTION_BOUNTY_USDC);
        book.finalize(_executedReceipt(11, ACCOUNT, first, firstHash));

        OrderV2Types.OrderRequest memory second = _request(bytes32("second"));
        vm.expectRevert(abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__OrderIdAlreadyUsed.selector, 11));
        book.registerPending(ACCOUNT, 11, second, EXECUTION_BOUNTY_USDC);
    }

    function test_FinalizeExecutedDeletesPendingAndStoresVerifiableCompactOutcome() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("execute"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 21, request, EXECUTION_BOUNTY_USDC);
        OrderV2Types.OrderReceipt memory receipt = _executedReceipt(21, ACCOUNT, request, intentHash);

        vm.roll(987_654);
        vm.warp(1_900_000_000);
        bytes32 receiptHash = book.finalize(receipt);
        bytes32 expectedHash = keccak256(
            abi.encode(
                book.RECEIPT_TYPEHASH(),
                block.chainid,
                address(book),
                address(this),
                uint64(block.number),
                uint64(block.timestamp),
                receipt
            )
        );
        assertEq(receiptHash, expectedHash);
        assertEq(book.pendingIntent(21).account, address(0));
        assertEq(book.pendingPolicy(21).validUntil, 0);
        assertEq(uint8(book.lifecycleStatus(21)), uint8(OrderV2Types.LifecycleStatus.Executed));

        OrderV2Types.ClientIntent memory permanent = book.clientIntent(ACCOUNT, request.clientOrderId);
        assertEq(permanent.orderId, 21);
        assertEq(permanent.intentHash, intentHash);

        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(21);
        assertEq(terminalOutcome.account, ACCOUNT);
        assertEq(terminalOutcome.clientOrderId, request.clientOrderId);
        assertEq(terminalOutcome.intentHash, intentHash);
        assertEq(terminalOutcome.expectedConfigHash, request.bounds.expectedConfigHash);
        assertEq(uint8(terminalOutcome.status), uint8(OrderV2Types.LifecycleStatus.Executed));
        assertEq(uint8(terminalOutcome.reason), uint8(OrderV2Types.TerminalReason.Executed));
        assertEq(uint8(terminalOutcome.executionMode), uint8(OrderV2Types.ExecutionMode.Live));
        assertEq(uint8(terminalOutcome.priceSource), uint8(OrderV2Types.PriceSource.OracleExecution));
        assertEq(uint8(terminalOutcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.Paid));
        assertEq(terminalOutcome.terminalBlock, block.number);
        assertEq(terminalOutcome.terminalTime, block.timestamp);
        assertEq(terminalOutcome.oraclePublishTime, receipt.oraclePublishTime);
        assertEq(terminalOutcome.executor, EXECUTOR);
        assertEq(terminalOutcome.bountyRecipient, EXECUTOR);
        assertEq(terminalOutcome.executionPrice, receipt.executionPrice);
        assertEq(terminalOutcome.bountyUsdc, receipt.bountyUsdc);
        assertEq(terminalOutcome.observedConfigHash, receipt.observedConfigHash);
        assertEq(terminalOutcome.receiptHash, expectedHash);
    }

    function test_FinalizeFailedPersistsTypedFailureEvidence() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("constraint-fail"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 31, request, EXECUTION_BOUNTY_USDC);
        OrderV2Types.OrderReceipt memory receipt = _failedReceipt(31, ACCOUNT, request, intentHash);

        bytes32 receiptHash = book.finalize(receipt);
        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(31);
        assertEq(uint8(terminalOutcome.status), uint8(OrderV2Types.LifecycleStatus.Failed));
        assertEq(uint8(terminalOutcome.reason), uint8(OrderV2Types.TerminalReason.ConstraintViolation));
        assertEq(
            terminalOutcome.failureSelector,
            ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector
        );
        assertEq(terminalOutcome.failureCategory, 0);
        assertEq(terminalOutcome.failureCode, 0);
        assertEq(uint8(terminalOutcome.failedConstraint), uint8(OrderV2Types.ConstraintKind.GrossAccountDebit));
        assertEq(terminalOutcome.revertDataHash, keccak256("typed failure data"));
        assertEq(terminalOutcome.receiptHash, receiptHash);
    }

    function test_RiskOffReceiptRefundsExactStoredBountyToAccount() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("risk-off"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 35, request, EXECUTION_BOUNTY_USDC);
        OrderV2Types.OrderReceipt memory receipt = _failedReceipt(35, ACCOUNT, request, intentHash);
        receipt.reason = OrderV2Types.TerminalReason.RiskOff;
        receipt.executionMode = OrderV2Types.ExecutionMode.None;
        receipt.priceSource = OrderV2Types.PriceSource.None;
        receipt.executionPrice = 0;
        receipt.oraclePublishTime = 0;
        receipt.bountyDisposition = OrderV2Types.BountyDisposition.RefundedToAccount;
        receipt.bountyRecipient = ACCOUNT;
        delete receipt.failure;

        book.finalize(receipt);
        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(35);
        assertEq(uint8(terminalOutcome.reason), uint8(OrderV2Types.TerminalReason.RiskOff));
        assertEq(uint8(terminalOutcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.RefundedToAccount));
        assertEq(terminalOutcome.bountyRecipient, ACCOUNT);
        assertEq(terminalOutcome.bountyUsdc, EXECUTION_BOUNTY_USDC);
    }

    function test_FinalizeRejectsForgedReasonSpecificEvidence() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("semantic-guards"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 39, request, EXECUTION_BOUNTY_USDC);

        OrderV2Types.OrderReceipt memory receipt = _executedReceipt(39, ACCOUNT, request, intentHash);
        receipt.priceReachedEngine = false;
        _expectInvalidTerminal(receipt);

        receipt = _executedReceipt(39, ACCOUNT, request, intentHash);
        receipt.bountyRecipient = OTHER_ACCOUNT;
        _expectInvalidTerminal(receipt);

        receipt = _executedReceipt(39, ACCOUNT, request, intentHash);
        receipt.status = OrderV2Types.LifecycleStatus.Failed;
        receipt.reason = OrderV2Types.TerminalReason.ConfigMismatch;
        receipt.executionMode = OrderV2Types.ExecutionMode.None;
        receipt.priceSource = OrderV2Types.PriceSource.None;
        receipt.executionPrice = 0;
        receipt.oraclePublishTime = 0;
        receipt.priceReachedEngine = false;
        _expectInvalidTerminal(receipt);

        receipt = _failedReceipt(39, ACCOUNT, request, intentHash);
        receipt.failure.selector = bytes4(uint32(0xdeadbeef));
        _expectInvalidTerminal(receipt);

        book.finalize(_executedReceipt(39, ACCOUNT, request, intentHash));
    }

    function test_FinalizeAllowsZeroBountyOnlyWithNoDispositionOrRecipient() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("zero-bounty"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 40, request, 0);
        OrderV2Types.OrderReceipt memory receipt = _executedReceipt(40, ACCOUNT, request, intentHash);
        receipt.bountyUsdc = 0;
        receipt.bountyRecipient = address(0);
        receipt.bountyDisposition = OrderV2Types.BountyDisposition.None;

        book.finalize(receipt);
        OrderV2Types.CompactOutcome memory terminalOutcome = book.outcome(40);
        assertEq(uint8(terminalOutcome.bountyDisposition), uint8(OrderV2Types.BountyDisposition.None));
        assertEq(terminalOutcome.bountyRecipient, address(0));
    }

    function test_FinalizeRejectsUnauthorizedMissingMismatchedInvalidAndRepeatedTransitions() public {
        OrderV2Types.OrderRequest memory request = _request(bytes32("terminal-guards"));
        (, bytes32 intentHash,) = book.registerPending(ACCOUNT, 41, request, EXECUTION_BOUNTY_USDC);
        OrderV2Types.OrderReceipt memory receipt = _executedReceipt(41, ACCOUNT, request, intentHash);

        vm.prank(address(0xBAD));
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__Unauthorized.selector);
        book.finalize(receipt);

        OrderV2Types.OrderReceipt memory missing = _executedReceipt(41, ACCOUNT, request, intentHash);
        missing.orderId = 404;
        vm.expectRevert(abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__OrderNotPending.selector, 404));
        book.finalize(missing);

        OrderV2Types.OrderReceipt memory mismatched = _executedReceipt(41, ACCOUNT, request, intentHash);
        mismatched.intentHash = keccak256("wrong");
        vm.expectRevert(
            abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__ReceiptIdentityMismatch.selector, 41)
        );
        book.finalize(mismatched);

        OrderV2Types.OrderReceipt memory wrongBounty = _executedReceipt(41, ACCOUNT, request, intentHash);
        wrongBounty.bountyUsdc += 1;
        vm.expectRevert(
            abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__ReceiptIdentityMismatch.selector, 41)
        );
        book.finalize(wrongBounty);

        OrderV2Types.OrderReceipt memory invalid = _executedReceipt(41, ACCOUNT, request, intentHash);
        invalid.status = OrderV2Types.LifecycleStatus.Failed;
        invalid.reason = OrderV2Types.TerminalReason.Executed;
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__InvalidTerminalOutcome.selector);
        book.finalize(invalid);

        book.finalize(receipt);
        vm.expectRevert(abi.encodeWithSelector(IOrderLifecycleBook.OrderLifecycleBook__OrderNotPending.selector, 41));
        book.finalize(receipt);
    }

    function testFuzz_HashCommitsToEveryFinancialBound(
        uint256 replacement
    ) public view {
        OrderV2Types.OrderRequest memory request = _request(bytes32("hash-all-bounds"));
        bytes32 original = book.hashOrderRequest(ACCOUNT, request);
        vm.assume(replacement != request.bounds.maxGrossAccountDebitUsdc);
        request.bounds.maxGrossAccountDebitUsdc = replacement;
        assertTrue(book.hashOrderRequest(ACCOUNT, request) != original);
    }

    function _request(
        bytes32 clientOrderId
    ) private view returns (OrderV2Types.OrderRequest memory request) {
        request.clientOrderId = clientOrderId;
        request.side = CfdTypes.Side.BEAR;
        request.sizeDelta = 100e18;
        request.marginDelta = 250e6;
        request.targetPrice = 1.01e8;
        request.bounds = OrderV2Types.ExecutionBounds({
            validUntil: uint64(block.timestamp + 60),
            allowedExecutionModes: 3,
            expectedConfigHash: keccak256("config-v1"),
            maxExecutionBountyUsdc: 2e6,
            maxExecutionNotionalUsdc: 102e6,
            maxGrossAccountDebitUsdc: 260e6,
            maxActionChargeUsdc: 5e6,
            maxExplicitFeesUsdc: 3e6,
            maxPostPositionSize: 200e18,
            minPostSettlementBalanceUsdc: 10e6,
            minPostPositionEquityUsdc: 3e6,
            maxPostLeverageBps: 50_000
        });
    }

    function _executedReceipt(
        uint64 orderId,
        address account,
        OrderV2Types.OrderRequest memory request,
        bytes32 intentHash
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        receipt.orderId = orderId;
        receipt.account = account;
        receipt.clientOrderId = request.clientOrderId;
        receipt.intentHash = intentHash;
        receipt.expectedConfigHash = request.bounds.expectedConfigHash;
        receipt.observedConfigHash = request.bounds.expectedConfigHash;
        receipt.status = OrderV2Types.LifecycleStatus.Executed;
        receipt.reason = OrderV2Types.TerminalReason.Executed;
        receipt.executionMode = OrderV2Types.ExecutionMode.Live;
        receipt.executor = EXECUTOR;
        receipt.priceSource = OrderV2Types.PriceSource.OracleExecution;
        receipt.executionPrice = 1e8;
        receipt.neutralMarkPrice = 1e8;
        receipt.poolDepthUsdc = 50_000_000e6;
        receipt.oraclePublishTime = 1_700_000_001;
        receipt.priceReachedEngine = true;
        receipt.bountyUsdc = EXECUTION_BOUNTY_USDC;
        receipt.bountyRecipient = EXECUTOR;
        receipt.bountyDisposition = OrderV2Types.BountyDisposition.Paid;
        receipt.economics = OrderV2Types.OrderEconomics({
            executionNotionalUsdc: 100e6,
            realizedPnlUsdc: 0,
            vpiUsdc: 50_000,
            carryUsdc: 10_000,
            executionFeeUsdc: 100_000,
            frozenSpreadUsdc: 0,
            actionChargeAssessedUsdc: 160_000,
            actionChargeCollectedUsdc: 160_000,
            grossAccountDebitUsdc: 251_160_000,
            preSettlementBalanceUsdc: 1000e6,
            postSettlementBalanceUsdc: 748_840_000,
            preTraderClaimBalanceUsdc: 0,
            postTraderClaimBalanceUsdc: 0,
            postPositionSize: 100e18,
            postPositionMarginUsdc: 250e6,
            postPositionEquityUsdc: 249_840_000,
            postLeverageBps: 4002
        });
    }

    function _failedReceipt(
        uint64 orderId,
        address account,
        OrderV2Types.OrderRequest memory request,
        bytes32 intentHash
    ) private pure returns (OrderV2Types.OrderReceipt memory receipt) {
        receipt.orderId = orderId;
        receipt.account = account;
        receipt.clientOrderId = request.clientOrderId;
        receipt.intentHash = intentHash;
        receipt.expectedConfigHash = request.bounds.expectedConfigHash;
        receipt.observedConfigHash = request.bounds.expectedConfigHash;
        receipt.status = OrderV2Types.LifecycleStatus.Failed;
        receipt.reason = OrderV2Types.TerminalReason.ConstraintViolation;
        receipt.executionMode = OrderV2Types.ExecutionMode.Live;
        receipt.executor = EXECUTOR;
        receipt.priceSource = OrderV2Types.PriceSource.OracleExecution;
        receipt.executionPrice = 1e8;
        receipt.neutralMarkPrice = 1e8;
        receipt.poolDepthUsdc = 50_000_000e6;
        receipt.oraclePublishTime = 1_700_000_001;
        receipt.priceReachedEngine = false;
        receipt.bountyUsdc = EXECUTION_BOUNTY_USDC;
        receipt.bountyRecipient = EXECUTOR;
        receipt.bountyDisposition = OrderV2Types.BountyDisposition.Paid;
        receipt.failure = OrderV2Types.FailureDetails({
            selector: ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
            category: 0,
            code: 0,
            constraint: OrderV2Types.ConstraintKind.GrossAccountDebit,
            actual: 300e6,
            limit: request.bounds.maxGrossAccountDebitUsdc,
            revertDataHash: keccak256("typed failure data")
        });
    }

    function _assertBoundsEq(
        OrderV2Types.ExecutionBounds memory actual,
        OrderV2Types.ExecutionBounds memory expected
    ) private pure {
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(expected)));
    }

    function _expectInvalidTerminal(
        OrderV2Types.OrderReceipt memory receipt
    ) private {
        vm.expectRevert(IOrderLifecycleBook.OrderLifecycleBook__InvalidTerminalOutcome.selector);
        book.finalize(receipt);
    }

    function _mockConfig(
        uint64 routerVersion,
        uint64 engineVersion,
        uint256 markStalenessLimit
    ) private {
        vm.mockCall(address(this), abi.encodeWithSignature("policyEvaluator()"), abi.encode(POLICY_EVALUATOR));
        vm.mockCall(address(this), abi.encodeWithSignature("executionSidecar()"), abi.encode(EXECUTION_SIDECAR));
        vm.mockCall(address(this), abi.encodeWithSignature("pletherOracle()"), abi.encode(ORACLE));
        vm.mockCall(address(this), abi.encodeWithSignature("admin()"), abi.encode(ROUTER_ADMIN));
        vm.mockCall(ROUTER_ADMIN, abi.encodeWithSignature("activeConfigVersion()"), abi.encode(routerVersion));
        vm.mockCall(ENGINE, abi.encodeWithSignature("planner()"), abi.encode(PLANNER));
        vm.mockCall(ENGINE, abi.encodeWithSignature("settlementSidecar()"), abi.encode(SETTLEMENT_SIDECAR));
        vm.mockCall(ENGINE, abi.encodeWithSignature("terminalNavBook()"), abi.encode(TERMINAL_NAV_BOOK));
        vm.mockCall(ENGINE, abi.encodeWithSignature("admin()"), abi.encode(ENGINE_ADMIN));
        vm.mockCall(ENGINE, abi.encodeWithSignature("protocolTreasury()"), abi.encode(PROTOCOL_TREASURY));
        vm.mockCall(ENGINE_ADMIN, abi.encodeWithSignature("activeConfigVersion()"), abi.encode(engineVersion));
        vm.mockCall(HOUSE_POOL, abi.encodeWithSignature("markStalenessLimit()"), abi.encode(markStalenessLimit));
    }

}

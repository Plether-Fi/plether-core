// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdEnginePlanTypes} from "@plether/perps/CfdEnginePlanTypes.sol";
import {OrderRouterV3ExecutionSidecar} from "@plether/perps/OrderRouterV3ExecutionSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {ICfdEngineTypes} from "@plether/perps/interfaces/ICfdEngineTypes.sol";
import {ICfdOrderPolicyEvaluator} from "@plether/perps/interfaces/ICfdOrderPolicyEvaluator.sol";
import {IOrderRouterV3ExecutionHost} from "@plether/perps/interfaces/IOrderRouterV3ExecutionHost.sol";
import {Test} from "forge-std/Test.sol";

contract OrderRouterV3ExecutionSidecarHarness is OrderRouterV3ExecutionSidecar {

    function classify(
        bytes calldata revertData
    )
        external
        pure
        returns (bool terminal, OrderV3Types.TerminalReason reason, OrderV3Types.FailureDetails memory failure)
    {
        TerminalClassification memory classification = _classifyTypedFailure(revertData);
        return (classification.terminal, classification.reason, classification.failure);
    }

    function pendingReason(
        bytes calldata revertData
    ) external pure returns (OrderV3Types.PendingReason) {
        return _pendingReasonForRevert(revertData);
    }

}

contract OrderRouterV3ExecutionSidecarTest is Test {

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;

    OrderRouterV3ExecutionSidecarHarness internal sidecar;

    function setUp() public {
        sidecar = new OrderRouterV3ExecutionSidecarHarness();
    }

    function testProductionRuntimeFitsEip170() public {
        OrderRouterV3ExecutionSidecar productionSidecar = new OrderRouterV3ExecutionSidecar();
        assertLe(
            address(productionSidecar).code.length,
            EIP170_RUNTIME_CODE_LIMIT,
            "production execution sidecar must remain deployable"
        );
    }

    function testDirectStatefulCallsAreRejected() public {
        bytes[] memory updates = new bytes[](0);
        vm.expectRevert(OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__OnlyDelegateCall.selector);
        sidecar.executeOrder(1, updates);

        IOrderRouterV3ExecutionHost.ItemRequest memory request;
        vm.expectRevert(OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__OnlyDelegateCall.selector);
        sidecar.executeV3OrderItemFromSidecar(request);
    }

    function testExactPlannerFailureIsTerminal() public view {
        bytes memory revertData = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
            uint8(1),
            false
        );
        (bool terminal, OrderV3Types.TerminalReason reason, OrderV3Types.FailureDetails memory failure) =
            sidecar.classify(revertData);

        assertTrue(terminal);
        assertEq(uint8(reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(failure.selector, ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector);
        assertEq(failure.category, uint8(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid));
        assertEq(failure.code, 1);
        assertEq(failure.revertDataHash, keccak256(revertData));
    }

    function testExactClosePlannerFailureIsTerminal() public view {
        bytes memory revertData = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
            uint8(5),
            true
        );
        (bool terminal, OrderV3Types.TerminalReason reason, OrderV3Types.FailureDetails memory failure) =
            sidecar.classify(revertData);

        assertTrue(terminal);
        assertEq(uint8(reason), uint8(OrderV3Types.TerminalReason.PlannerRejected));
        assertEq(failure.code, 5);
    }

    function testMalformedPlannerFailureRemainsRetryable() public view {
        bytes memory exact = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
            uint8(1),
            false
        );
        bytes memory trailing = bytes.concat(exact, hex"00");
        (bool terminal,,) = sidecar.classify(trailing);
        assertFalse(terminal);

        bytes memory invalidBool = abi.encodePacked(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            bytes32(uint256(CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid)),
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
        (terminal,,) = sidecar.classify(invalidBool);
        assertFalse(terminal);

        bytes memory invalidOpenCode = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid,
            uint8(11),
            false
        );
        (terminal,,) = sidecar.classify(invalidOpenCode);
        assertFalse(terminal);

        bytes memory wrongCategory = abi.encodeWithSelector(
            ICfdEngineTypes.CfdEngine__TypedOrderFailure.selector,
            CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated,
            uint8(1),
            false
        );
        (terminal,,) = sidecar.classify(wrongCategory);
        assertFalse(terminal);
    }

    function testExactModeFailureIsTerminal() public view {
        bytes memory revertData = abi.encodeWithSelector(
            ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ExecutionModeDisallowed.selector,
            OrderV3Types.ExecutionMode.Frozen,
            uint8(3)
        );
        (bool terminal, OrderV3Types.TerminalReason reason, OrderV3Types.FailureDetails memory failure) =
            sidecar.classify(revertData);

        assertTrue(terminal);
        assertEq(uint8(reason), uint8(OrderV3Types.TerminalReason.ExecutionModeDisallowed));
        assertEq(failure.actual, uint256(OrderV3Types.ExecutionMode.Frozen));
        assertEq(failure.limit, 3);
        assertEq(failure.revertDataHash, keccak256(revertData));
    }

    function testExactConstraintFailureIsTerminal() public view {
        bytes memory revertData = abi.encodeWithSelector(
            ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__ConstraintViolation.selector,
            OrderV3Types.ConstraintKind.PostPositionEquity,
            uint256(40),
            uint256(50)
        );
        (bool terminal, OrderV3Types.TerminalReason reason, OrderV3Types.FailureDetails memory failure) =
            sidecar.classify(revertData);

        assertTrue(terminal);
        assertEq(uint8(reason), uint8(OrderV3Types.TerminalReason.ConstraintViolation));
        assertEq(uint8(failure.constraint), uint8(OrderV3Types.ConstraintKind.PostPositionEquity));
        assertEq(failure.actual, 40);
        assertEq(failure.limit, 50);
        assertEq(failure.revertDataHash, keccak256(revertData));
    }

    function testUnknownPanicAndEmptyFailuresRemainRetryable() public view {
        (bool terminal,,) = sidecar.classify(bytes(""));
        assertFalse(terminal);

        (terminal,,) = sidecar.classify(abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)));
        assertFalse(terminal);

        (terminal,,) = sidecar.classify(abi.encodeWithSelector(bytes4(keccak256("Unknown(uint256)")), uint256(1)));
        assertFalse(terminal);
    }

    function testBountyAccountingInvariantRemainsRetryable() public view {
        (bool terminal,,) = sidecar.classify(
            abi.encodeWithSelector(
                ICfdOrderPolicyEvaluator.CfdOrderPolicyEvaluator__InsufficientBountyBacking.selector, 0, 200_000
            )
        );
        assertFalse(terminal);
    }

    function testWrappedRetryablePendingReasonClassification() public view {
        bytes memory markFailure = abi.encodeWithSelector(
            OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__RetryableFailure.selector,
            address(0x1234),
            ICfdEngineTypes.CfdEngine__MarkPriceOutOfOrder.selector,
            uint256(4)
        );
        assertEq(uint8(sidecar.pendingReason(markFailure)), uint8(OrderV3Types.PendingReason.MarkPriceOutOfOrder));

        bytes memory gasFailure = abi.encodeWithSelector(
            OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__RetryableFailure.selector,
            address(0x1234),
            bytes4(keccak256("OrderRouter__InsufficientGas()")),
            uint256(0)
        );
        assertEq(uint8(sidecar.pendingReason(gasFailure)), uint8(OrderV3Types.PendingReason.InsufficientGas));

        bytes memory unknownFailure = abi.encodeWithSelector(
            OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__RetryableFailure.selector,
            address(0x1234),
            bytes4(keccak256("Unknown()")),
            uint256(4)
        );
        assertEq(uint8(sidecar.pendingReason(unknownFailure)), uint8(OrderV3Types.PendingReason.EngineFailure));

        bytes memory malformedSuccess = abi.encodeWithSelector(
            OrderRouterV3ExecutionSidecar.OrderRouterV3ExecutionSidecar__MalformedSuccess.selector,
            address(0x1234),
            uint256(32)
        );
        assertEq(uint8(sidecar.pendingReason(malformedSuccess)), uint8(OrderV3Types.PendingReason.EngineFailure));
    }

}

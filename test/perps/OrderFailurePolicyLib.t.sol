// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {CfdEnginePlanTypes} from "src/perps/CfdEnginePlanTypes.sol";
import {OrderFailurePolicyLib} from "src/perps/libraries/OrderFailurePolicyLib.sol";

contract OrderFailurePolicyLibTest is Test {

    struct PredictableOpenCase {
        CfdEnginePlanTypes.OpenFailurePolicyCategory category;
        bool expected;
    }

    struct PolicyCase {
        OrderFailurePolicyLib.FailureContext context;
        OrderFailurePolicyLib.FailedOrderBountyPolicy expected;
    }

    function test_IsPredictablyInvalidOpen_Matrix() public pure {
        PredictableOpenCase[3] memory cases = [
            PredictableOpenCase(CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable, true),
            PredictableOpenCase(CfdEnginePlanTypes.OpenFailurePolicyCategory.ExecutionTimeUserInvalid, false),
            PredictableOpenCase(
                CfdEnginePlanTypes.OpenFailurePolicyCategory.ExecutionTimeProtocolStateInvalidated, false
            )
        ];

        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(
                OrderFailurePolicyLib.isPredictablyInvalidOpen(cases[i].category),
                cases[i].expected,
                "predictable-open classification mismatch"
            );
        }
    }

    function test_FailureDomainForExecutionCategory_Matrix() public pure {
        assertEq(
            uint256(
                OrderFailurePolicyLib.failureDomainForExecutionCategory(
                    CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid
                )
            ),
            uint256(OrderFailurePolicyLib.FailureDomain.UserInvalid)
        );
        assertEq(
            uint256(
                OrderFailurePolicyLib.failureDomainForExecutionCategory(
                    CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated
                )
            ),
            uint256(OrderFailurePolicyLib.FailureDomain.ProtocolStateInvalidated)
        );
        assertEq(
            uint256(
                OrderFailurePolicyLib.failureDomainForExecutionCategory(
                    CfdEnginePlanTypes.ExecutionFailurePolicyCategory.None
                )
            ),
            uint256(OrderFailurePolicyLib.FailureDomain.Retryable)
        );
    }

    function test_BountyPolicyForFailure_Matrix() public pure {
        PolicyCase[7] memory cases;

        cases[0] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.RouterPolicy,
                OrderFailurePolicyLib.FailureDomain.ProtocolStateInvalidated,
                uint8(OrderFailurePolicyLib.RouterFailureCode.CloseOnlyFad),
                false,
                true,
                false,
                true,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.RefundUser
        });
        cases[1] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.EngineTyped,
                OrderFailurePolicyLib.FailureDomain.ProtocolStateInvalidated,
                uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED),
                false,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.RefundUser
        });
        cases[2] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.EngineTyped,
                OrderFailurePolicyLib.FailureDomain.UserInvalid,
                uint8(CfdEnginePlanTypes.OpenRevertCode.MARGIN_DRAINED_BY_FEES),
                false,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull
        });
        cases[3] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.EngineTyped,
                OrderFailurePolicyLib.FailureDomain.UserInvalid,
                1,
                true,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull
        });
        cases[4] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.Expired,
                OrderFailurePolicyLib.FailureDomain.Expired,
                0,
                false,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull
        });
        cases[5] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.Expired,
                OrderFailurePolicyLib.FailureDomain.Expired,
                0,
                true,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.ClearerFull
        });
        cases[6] = PolicyCase({
            context: _context(
                OrderFailurePolicyLib.FailureSource.RouterPolicy,
                OrderFailurePolicyLib.FailureDomain.Retryable,
                0,
                false,
                false,
                false,
                false,
                false
            ),
            expected: OrderFailurePolicyLib.FailedOrderBountyPolicy.None
        });

        for (uint256 i = 0; i < cases.length; i++) {
            assertEq(
                uint256(OrderFailurePolicyLib.bountyPolicyForFailure(cases[i].context)),
                uint256(cases[i].expected),
                "bounty-policy classification mismatch"
            );
        }
    }

    function _context(
        OrderFailurePolicyLib.FailureSource source,
        OrderFailurePolicyLib.FailureDomain domain,
        uint8 code,
        bool isClose,
        bool closeOnly,
        bool oracleFrozen,
        bool isFad,
        bool degradedMode
    ) internal pure returns (OrderFailurePolicyLib.FailureContext memory context) {
        context.failure = OrderFailurePolicyLib.RoutedFailure({domain: domain, code: code, isClose: isClose});
        context.source = source;
        context.closeOnly = closeOnly;
        context.oracleFrozen = oracleFrozen;
        context.isFad = isFad;
        context.degradedMode = degradedMode;
    }

}

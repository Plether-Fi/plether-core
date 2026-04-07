// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {CfdEnginePlanTypes} from "../CfdEnginePlanTypes.sol";

library OrderFailurePolicyLib {

    enum FailedOrderBountyPolicy {
        None,
        ClearerFull,
        RefundUser
    }

    enum FailureSource {
        RouterPolicy,
        EngineTyped,
        UntypedRevert,
        Expired
    }

    enum FailureDomain {
        UserInvalid,
        ProtocolStateInvalidated,
        Retryable,
        Expired
    }

    enum RouterFailureCode {
        None,
        CloseOnlyOracleFrozen,
        CloseOnlyFad,
        StaleOracle
    }

    struct RoutedFailure {
        FailureDomain domain;
        uint8 code;
        bool isClose;
    }

    struct FailureContext {
        RoutedFailure failure;
        FailureSource source;
        bool closeOnly;
        bool oracleFrozen;
        bool isFad;
        bool degradedMode;
    }

    function isPredictablyInvalidOpen(
        CfdEnginePlanTypes.OpenFailurePolicyCategory category
    ) internal pure returns (bool) {
        return category == CfdEnginePlanTypes.OpenFailurePolicyCategory.CommitTimeRejectable;
    }

    function failureDomainForExecutionCategory(
        CfdEnginePlanTypes.ExecutionFailurePolicyCategory category
    ) internal pure returns (FailureDomain) {
        if (category == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.ProtocolStateInvalidated) {
            return FailureDomain.ProtocolStateInvalidated;
        }

        if (category == CfdEnginePlanTypes.ExecutionFailurePolicyCategory.UserInvalid) {
            return FailureDomain.UserInvalid;
        }

        return FailureDomain.Retryable;
    }

    function bountyPolicyForFailure(
        FailureContext memory context
    ) internal pure returns (FailedOrderBountyPolicy) {
        if (context.failure.domain == FailureDomain.Retryable) {
            return FailedOrderBountyPolicy.None;
        }

        if (context.failure.isClose) {
            return FailedOrderBountyPolicy.ClearerFull;
        }

        if (context.failure.domain == FailureDomain.ProtocolStateInvalidated) {
            return FailedOrderBountyPolicy.RefundUser;
        }

        return FailedOrderBountyPolicy.ClearerFull;
    }

}

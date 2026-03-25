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
        CloseOnlyFad
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
        uint8 revertCode
    ) internal pure returns (bool) {
        return revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.MUST_CLOSE_OPPOSING)
            || revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.POSITION_TOO_SMALL)
            || revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.SKEW_TOO_HIGH)
            || revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.INSUFFICIENT_INITIAL_MARGIN)
            || revertCode == uint8(CfdEnginePlanTypes.OpenRevertCode.SOLVENCY_EXCEEDED);
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouterExecutionSidecar} from "@plether/perps/OrderRouterExecutionSidecar.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";

import {Test} from "forge-std/Test.sol";

contract OrderRouterExecutionSidecarHarness is OrderRouterExecutionSidecar {

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

abstract contract OrderRouterExecutionSidecarTestFixture is Test {

    uint256 internal constant EIP170_RUNTIME_CODE_LIMIT = 24_576;

    OrderRouterExecutionSidecarHarness internal sidecar;

    function setUp() public {
        sidecar = new OrderRouterExecutionSidecarHarness();
    }

}
